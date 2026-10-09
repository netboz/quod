-module(quod_physics_predicates).
-moduledoc "Governed live body queries and signed sample custody for physics.".
-include_lib("erlog/src/erlog_int.hrl").
-export([quod_predicate_module/0, load/1, physics_observation/3, signed_physics_request/3, current_signed_request/3]).
-export([physics_body_state/3, physics_motion_query/3, sample_physics/3]).
-export([physics_control_input/3,stage_input/3]).
-export([motion_answer/1]).
quod_predicate_module() -> true.
load(Est) ->
    Body = quod_predicates:register(Est, {physics_body_state, 3}, query, ?MODULE, physics_body_state),
    Motion = quod_predicates:register(Body, {physics_motion_query, 4}, query, ?MODULE, physics_motion_query),
    Sample = quod_predicates:register(Motion, {'$quod_sample_physics', 6}, query, ?MODULE, sample_physics),
    Input = quod_predicates:register(Sample,{physics_control_input,6},staging,?MODULE,physics_control_input),
    Stage = quod_predicates:register(Input,{'$quod_stage_physics_input',6},staging,?MODULE,stage_input),
    Observation = quod_predicates:register(Stage, {physics_observation, 1}, reaction,
                                           ?MODULE, physics_observation),
    Bound = quod_predicates:register(Observation, {current_signed_request, 2}, query, proof_bound,
                                    ?MODULE, current_signed_request),
    quod_predicates:register(Bound, {signed_physics_request, 3}, query, proof_bound,
                                      ?MODULE, signed_physics_request).

%% Policy runs as ordinary Prolog. An opaque proof-local handle prevents a
%% caller from jumping past it by invoking the native continuation directly.
physics_body_state({physics_body_state, W, B, Result}, Next, St) ->
    live_query({physics_body_state,W,B},Result,Next,St).
physics_motion_query({physics_motion_query, W, B, Query, Result}, Next, St) ->
    live_query({physics_motion_query,W,B,Query},Result,Next,St).

live_query(Action0, Result, Next, St = #est{bs = Bs,vn = Vn}) ->
    Action = erlog_int:dderef(Action0,Bs),
    W = element(2,Action), B = element(3,Action),
    case {quod_proof_session:read_only_state(St), quod_runtime_predicates:scope_identity(St)} of
        {true, {ok, {Ns, Anchor}}} when is_integer(B), B >= 0 ->
            case quod_wire_term:is_ground(Action) of
                true ->
                    {Handle, Bound} = quod_erlog_db_local_prove:register_action_request(
                        St, Action, {Ns, Anchor, W, B}),
                    {Policy,Limits} = case Action of
                        {physics_body_state,W,B} ->
                            {{physics_body_read_projection,W,B,{Vn},{Vn+1}},none};
                        {physics_motion_query,W,B,Q} ->
                            {{physics_motion_read_projection,W,B,Q,{Vn},{Vn+1},{Vn+2}},{Vn+2}}
                    end,
                    erlog_int:prove_body([Policy,
                        {'$quod_sample_physics',Handle,Action,{Vn},{Vn+1},Limits,Result} | Next],
                        Bound#est{vn = Vn+3});
                false -> erlog_int:fail(St)
            end;
        _ -> erlog_int:fail(St)
    end.

sample_physics({'$quod_sample_physics', H0, A0, F0, R0, L0, Result}, Next, St = #est{bs = Bs}) ->
    [Handle,Action,Frame,Revision,Limits] = erlog_int:dderef([H0,A0,F0,R0,L0],Bs),
    case {Frame,quod_erlog_db_local_prove:action_request(St,Handle,Action)} of
        {{physics_frame,World = {world_ref,Ns,Anchor,W},Authority,Epoch,Generation,Token,Structure},
         {ok,{Ns,Anchor,W,Body}}} ->
            Remaining = case quod_scope_session:remaining_ms() of
                {ok,Ms} -> Ms;
                error -> quod_proof_context:remaining_ms()
            end,
            Expected = #{fence => {World,Authority,Epoch,Generation},
                         incarnation => Token,structure => Structure},
            Value = case {quod_reg:where({physics_world,World}),Remaining} of
                {Pid,Timeout} when is_pid(Pid), Timeout > 0 ->
                    try read_physics(Pid,Expected,{Body,Revision},Action,Limits,Timeout,Frame)
                    catch exit:_ -> unavailable end;
                _ -> unavailable
            end,
            erlog_int:unify_prove_body(Result,Value,Next,St);
        _ -> erlog_int:fail(St)
    end.

read_physics(Pid, Expected, Body, {physics_body_state,_,_}, none, Timeout, Frame) ->
    case quod_physics:body_state(Pid,Expected,Body,Timeout) of
        {ok,Tick,{Id,Revision,world,P,Q,{Vx,Vy,Vz}}} ->
            {body_state,Frame,Tick,{body,Id,Revision},metres_seconds,
             pose({P,Q}),{velocity,Vx,Vy,Vz}};
        {error,unavailable} -> unavailable
    end;
read_physics(Pid, Expected, Body = {Id,Revision}, {physics_motion_query,_,_,Query}, Limits, Timeout, Frame) ->
    case quod_physics:motion_query(Pid,Expected,Body,Query,Limits,Timeout) of
        {ok,Tick,Answer} ->
            {motion_query,Frame,Tick,{body,Id,Revision},metres_seconds,motion_answer(Answer)};
        {error,unavailable} -> unavailable
    end.

pose({{X,Y,Z},{Qx,Qy,Qz,Qw}}) ->
    {pose,{vector,X,Y,Z},{quaternion,Qx,Qy,Qz,Qw}}.
motion_answer({clear,Pose,Checks}) -> {clear,pose(Pose),Checks};
motion_answer({clipped,Pose,Contacts,Checks}) ->
    {clipped,pose(Pose),[{contact,Id,{normal,X,Y,Z}} || {Id,{X,Y,Z}} <- Contacts],Checks};
motion_answer(Answer) -> Answer.

physics_control_input({physics_control_input,W,F,E,S,I,Result},Next,St = #est{bs = Bs,vn = Vn}) ->
    Action = erlog_int:dderef({physics_control_input,W,F,E,S,I},Bs),
    case {quod_wire_term:is_ground(Action),quod_runtime_predicates:scope_identity(St)} of
        {true,{ok,{Ns,Anchor}}} ->
            {Handle,Bound} = quod_erlog_db_local_prove:register_action_request(St,Action,{Ns,Anchor}),
            {physics_control_input,World,Frame,Epoch,Sequence,Input} = Action,
            erlog_int:prove_body([
                {physics_input_projection,World,Frame,Epoch,Sequence,Input,{Vn},{Vn+1},{Vn+2}},
                {'$quod_stage_physics_input',Handle,Action,{Vn},{Vn+1},{Vn+2},Result}|Next],
                Bound#est{vn = Vn+3});
        _ -> erlog_int:fail(St)
    end.

stage_input({'$quod_stage_physics_input',H0,A0,C0,L0,Q0,Result},Next,St = #est{bs = Bs}) ->
    [Handle,Action,Control,Lease,Limits] = erlog_int:dderef([H0,A0,C0,L0,Q0],Bs),
    case {Action,quod_erlog_db_local_prove:action_request(St,Handle,Action)} of
        {{physics_control_input,W,{control_frame,{physics_frame,World = {world_ref,Ns,Anchor,W},
              Authority,Epoch,Generation,Token,Structure},Registration},_,Seq,Input},{ok,{Ns,Anchor}}}
          when is_integer(Lease),Lease > 0 ->
            Expiry = case quod_scope_session:request_expiry() of
                error -> quod_proof_context:request_expiry();
                Value -> Value
            end,
            Expected = #{fence => {World,Authority,Epoch,Generation},incarnation => Token,
                         structure => Structure,registration => Registration},
            case {quod_reg:where({physics_world,World}),Expiry} of
                {Pid,{ok,E1}} when is_pid(Pid),is_integer(E1) ->
                    Effect = {physics_input,Pid,Expected,Control,Seq,{Input,Limits},
                              min(E1,quod_time:now_ms()+Lease)},
                    case quod_erlog_db_local_prove:stage_transient(St,Effect) of
                        {ok,Staged} -> erlog_int:unify_prove_body(Result,{queued,Seq},Next,Staged);
                        error -> erlog_int:fail(St)
                    end;
                _ -> erlog_int:fail(St)
            end;
        _ -> erlog_int:fail(St)
    end.

current_signed_request({current_signed_request, Bytes, Signature}, Next, St) ->
    Binding = case quod_scope_session:request_binding() of
        {ok, Value} -> Value;
        error -> quod_proof_context:request_binding()
    end,
    [B, S] = erlog_int:dderef([Bytes, Signature], St#est.bs),
    case quod_client_goal:verify(B, S) of
        {ok, #{request_digest := Digest}} when Binding =:= {agent_goal_v1, Digest} ->
            erlog_int:prove_body(Next, St);
        _ -> erlog_int:fail(St)
    end.

signed_physics_request({signed_physics_request, Goal0, B0, S0}, Next, St = #est{bs = Bs}) ->
    [Goal, B, S] = erlog_int:dderef([Goal0, B0, S0], Bs),
    {ok, GoalBlob} = quod_durable_term:encode_goal(Goal),
    case {quod_runtime_predicates:scope_identity(St), quod_client_goal:verify(B, S)} of
        {{ok, {Ns, Anchor}}, {ok, #{request := #{agent_namespace := Ns,
             agent_genesis_anchor := Anchor, mode := execute}, goal_blob := GoalBlob}}} ->
            erlog_int:prove_body(Next, St);
        _ -> erlog_int:fail(St)
    end.

physics_observation({physics_observation, Event}, Next, St) ->
    case quod_runtime_predicates:reaction_metadata(St) of
        {ok, #{physics := #{event := Owned}}} -> erlog_int:unify_prove_body(Event,Owned,Next,St);
        _ -> erlog_int:fail(St)
    end.

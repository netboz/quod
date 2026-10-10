-module(quod_physics_predicates).
-import(quod_predicates, [fail_reason/2]).
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
    case quod_wire_term:is_ground(Action) of
        false -> erlog_int:instantiation_error(St);
        true when not is_integer(B); B < 0 -> erlog_int:type_error(body_id,B,St);
        true ->
            case quod_proof_session:read_only_state(St) of
                false -> erlog_int:erlog_error(
                    {context_violation,element(1,Action),query,write_proof},St);
                true ->
                    case quod_runtime_predicates:scope_identity(St) of
                        error -> fail_reason({scope_identity_unavailable,W},St);
                        {ok,{Ns,Anchor}} ->
                            {Handle,Bound} = quod_erlog_db_local_prove:register_action_request(
                                St,Action,{Ns,Anchor,W,B}),
                            {Policy,Limits} = case Action of
                                {physics_body_state,W,B} ->
                                    {{physics_body_read_projection,W,B,{Vn},{Vn+1}},none};
                                {physics_motion_query,W,B,Q} ->
                                    {{physics_motion_read_projection,W,B,Q,{Vn},{Vn+1},{Vn+2}},{Vn+2}}
                            end,
                            erlog_int:prove_body([Policy,
                                {'$quod_sample_physics',Handle,Action,{Vn},{Vn+1},Limits,Result}|Next],
                                Bound#est{vn = Vn+3})
                    end
            end
    end.

sample_physics({'$quod_sample_physics', H0, A0, F0, R0, L0, Result}, Next, St = #est{bs = Bs}) ->
    [Handle,Action,Frame,Revision,Limits] = erlog_int:dderef([H0,A0,F0,R0,L0],Bs),
    case quod_erlog_db_local_prove:action_request(St,Handle,Action) of
        error -> erlog_int:domain_error(physics_request_handle,Handle,St);
        {ok,{Ns,Anchor,W,Body}} ->
            case quod_wire_term:is_ground(Frame) of
                true -> ok;
                false -> erlog_int:domain_error(physics_frame,Frame,St)
            end,
            case is_integer(Revision) andalso Revision > 0 of
                true -> ok;
                false -> erlog_int:domain_error(physics_body_revision,Revision,St)
            end,
            case Frame of
                {physics_frame,World = {world_ref,Ns,Anchor,W},Authority = {agent_instance_ref,Ns,Anchor,_},
                 Epoch,Generation,Token,Structure}
                  when is_integer(Epoch),Epoch > 0,is_integer(Generation),Generation > 0,
                       is_binary(Token),byte_size(Token) =:= 32,is_integer(Structure),Structure > 0 ->
                    case (Limits =:= none andalso element(1,Action) =:= physics_body_state)
                         orelse valid_limits(Limits) of
                        true -> ok;
                        false -> erlog_int:domain_error(physics_limits,Limits,St)
                    end,
                    Remaining = case quod_scope_session:remaining_ms() of
                        {ok,Ms} -> Ms;
                        error -> quod_proof_context:remaining_ms()
                    end,
                    Expected = #{fence => {World,Authority,Epoch,Generation},
                                 incarnation => Token,structure => Structure},
                    case quod_reg:where({physics_world,World}) of
                        undefined -> fail_reason({physics_world_unavailable,W},St);
                        _Pid when Remaining =< 0 -> fail_reason(expired,St);
                        Pid ->
                            Sample = try
                                {ok,read_physics(Pid,Expected,{Body,Revision},Action,Limits,Remaining,Frame)}
                            catch exit:_ -> {error,physics_owner_unavailable} end,
                            case Sample of
                                {ok,Value} -> erlog_int:unify_prove_body(Result,Value,Next,St);
                                {error,Reason} -> fail_reason({Reason,W},St)
                            end
                    end;
                _ -> erlog_int:domain_error(physics_frame,Frame,St)
            end;
        {ok,_} -> erlog_int:domain_error(physics_request_handle,Handle,St)
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
    case quod_wire_term:is_ground(Action) of
        false -> erlog_int:instantiation_error(St);
        true ->
            ok = quod_erlog_db_local_prove:require_transient_context(St),
            case quod_runtime_predicates:scope_identity(St) of
                error -> fail_reason({scope_identity_unavailable,element(2,Action)},St);
                {ok,{Ns,Anchor}} ->
                    {Handle,Bound} = quod_erlog_db_local_prove:register_action_request(St,Action,{Ns,Anchor}),
                    {physics_control_input,World,Frame,Epoch,Sequence,Input} = Action,
                    erlog_int:prove_body([
                        {physics_input_projection,World,Frame,Epoch,Sequence,Input,{Vn},{Vn+1},{Vn+2}},
                        {'$quod_stage_physics_input',Handle,Action,{Vn},{Vn+1},{Vn+2},Result}|Next],
                        Bound#est{vn = Vn+3})
            end
    end.

stage_input({'$quod_stage_physics_input',H0,A0,C0,L0,Q0,Result},Next,St = #est{bs = Bs}) ->
    [Handle,Action,Control,Lease,Limits] = erlog_int:dderef([H0,A0,C0,L0,Q0],Bs),
    case quod_erlog_db_local_prove:action_request(St,Handle,Action) of
        {ok,{Ns,Anchor}} ->
            ok = quod_erlog_db_local_prove:require_transient_context(St),
            case Action of
                {physics_control_input,W,{control_frame,
                    {physics_frame,World = {world_ref,Ns,Anchor,W},Authority = {agent_instance_ref,Ns,Anchor,_},
                     Epoch,Generation,Token,Structure},Registration},_,Seq,Input}
                  when is_integer(Epoch),Epoch > 0,is_integer(Generation),Generation > 0,
                       is_binary(Token),byte_size(Token) =:= 32,is_integer(Structure),Structure > 0 ->
                    case is_integer(Lease) andalso Lease > 0 of
                        false -> erlog_int:domain_error(physics_lease,Lease,St);
                        true ->
                            case valid_limits(Limits) of
                                true -> ok;
                                false -> erlog_int:domain_error(physics_limits,Limits,St)
                            end,
                            Expiry = case quod_scope_session:request_expiry() of
                                error -> quod_proof_context:request_expiry();
                                Value -> Value
                            end,
                            Expected = #{fence => {World,Authority,Epoch,Generation},incarnation => Token,
                                         structure => Structure,registration => Registration},
                            case Expiry of
                                {ok,E1} when is_integer(E1) ->
                                    case quod_reg:where({physics_world,World}) of
                                        undefined -> fail_reason({physics_world_unavailable,W},St);
                                        Pid ->
                                            Effect = {physics_input,Pid,Expected,Control,Seq,{Input,Limits},
                                                      min(E1,quod_time:now_ms()+Lease)},
                                            case quod_erlog_db_local_prove:stage_transient(St,Effect) of
                                                {ok,Staged} -> erlog_int:unify_prove_body(Result,{queued,Seq},Next,Staged);
                                                {error,Reason} -> fail_reason(Reason,St)
                                            end
                                    end;
                                _ -> erlog_int:erlog_error(
                                    {context_violation,physics_control_input,staging,unsigned},St)
                            end
                    end;
                _ -> erlog_int:domain_error(physics_frame,Action,St)
            end;
        _ -> erlog_int:domain_error(physics_request_handle,Handle,St)
    end.

valid_limits({query_limits,Skin,Tolerance,Slides,Checks}) ->
    is_integer(Skin) andalso Skin > 0 andalso is_integer(Tolerance)
    andalso Tolerance >= 0 andalso Tolerance < Skin
    andalso is_integer(Slides) andalso Slides > 0 andalso is_integer(Checks) andalso Checks > 0;
valid_limits({push_limits,Body,Revision,Impulse,Speed}) ->
    is_integer(Body) andalso Body >= 0 andalso is_integer(Revision) andalso Revision > 0
    andalso is_integer(Impulse) andalso Impulse > 0 andalso is_integer(Speed) andalso Speed > 0;
valid_limits(_) -> false.

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
    GoalBlob = case quod_durable_term:encode_goal(Goal) of
        {ok, Encoded} -> Encoded;
        {error, _} -> erlog_int:domain_error(signed_goal, Goal, St)
    end,
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

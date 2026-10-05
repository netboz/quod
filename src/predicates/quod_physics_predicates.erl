-module(quod_physics_predicates).
-moduledoc "Signed sample custody and immutable committed outcome checks for physics.".
-include_lib("erlog/src/erlog_int.hrl").
-export([quod_predicate_module/0, load/1, physics_observation/3, signed_physics_request/3, current_signed_request/3]).
quod_predicate_module() -> true.
load(Est) ->
    Observation = quod_predicates:register(Est, {physics_observation, 1}, reaction,
                                           ?MODULE, physics_observation),
    Bound = quod_predicates:register(Observation, {current_signed_request, 2}, query, proof_bound,
                                    ?MODULE, current_signed_request),
    quod_predicates:register(Bound, {signed_physics_request, 3}, query, proof_bound,
                                      ?MODULE, signed_physics_request).

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

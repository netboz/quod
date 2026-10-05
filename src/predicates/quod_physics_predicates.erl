-module(quod_physics_predicates).
-moduledoc "Pure signed-request binding for committed activation custody.".
-include_lib("erlog/src/erlog_int.hrl").
-export([quod_predicate_module/0, load/1, physics_activation_request/3, current_signed_request/3]).
quod_predicate_module() -> true.
load(Est) ->
    Bound = quod_predicates:register(Est, {current_signed_request, 2}, query, proof_bound,
                                    ?MODULE, current_signed_request),
    quod_predicates:register(Bound, {physics_activation_request, 5}, query, proof_bound,
                             ?MODULE, physics_activation_request).

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

physics_activation_request({physics_activation_request, W0, G0, T0, B0, S0}, Next, St = #est{bs = Bs}) ->
    [W, G, T, B, S] = erlog_int:dderef([W0, G0, T0, B0, S0], Bs),
    {ok, GoalBlob} = quod_durable_term:encode_goal({physics_activate, W, G, T}),
    case {quod_runtime_predicates:scope_identity(St), quod_client_goal:verify(B, S)} of
        {{ok, {Ns, Anchor}}, {ok, #{request := #{agent_namespace := Ns,
             agent_genesis_anchor := Anchor, mode := execute}, goal_blob := GoalBlob}}} ->
            erlog_int:prove_body(Next, St);
        _ -> erlog_int:fail(St)
    end.

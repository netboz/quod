-module(quod_agent_predicates).
-moduledoc """
Governed bridges for an ontology containing hosted agents. The containing
ontology explicitly declares this installed module; domain actions and policy remain Prolog.

`current_principal(-Principal)` reuses the authenticated-principal bridge.
Request signing uses the universal runtime bridge's exact proof scope; it
does not obtain identity from a live node observation.
""".

-include_lib("erlog/src/erlog_int.hrl").

-export([quod_predicate_module/0, load/1,
         sign_agent_request/3, reconcile_agent_hosts/3, reconcile_agent_observers/3,
         local_node_agent/3]).

quod_predicate_module() -> true.

-spec load(tuple()) -> tuple().
load(Est) ->
    WithPrincipal = quod_predicates:register(
                      Est, {current_principal, 1}, query, proof_bound,
                      quod_ontology_predicates, current_principal_predicate),
    WithLocalNode = quod_predicates:register(WithPrincipal, {local_node_agent, 1}, query,
                                             ?MODULE, local_node_agent),
    WithSigning = quod_predicates:register(WithLocalNode, {sign_agent_request, 2}, query,
                                           ?MODULE, sign_agent_request),
    WithHosting = quod_predicates:register(WithSigning, {reconcile_agent_hosts, 1}, query,
                                            ?MODULE, reconcile_agent_hosts),
    quod_predicates:register(WithHosting, {reconcile_agent_observers, 1}, query,
                              ?MODULE, reconcile_agent_observers).

-doc "Observe the installed local node identity; this is not committed proof authority.".
-spec local_node_agent(term(), term(), tuple()) -> term().
local_node_agent({local_node_agent, Node}, Next, St) ->
    case quod_node_actor:principal() of
        {ok, Principal} ->
            {ok, NodeRef} = quod_agent_ref:materialize_principal(Principal),
            erlog_int:unify_prove_body(Node, NodeRef, Next, St);
        _ -> erlog_int:fail(St)
    end.

-doc "Ask the existing resource owner to reconcile from its own committed selection.".
reconcile_agent_hosts({reconcile_agent_hosts, Scope}, Next, St) ->
    quod_runtime_predicates:request_resource(agent_hosts, Scope, Next, St).

reconcile_agent_observers({reconcile_agent_observers, Scope}, Next, St) ->
    quod_runtime_predicates:request_resource(agent_observers, Scope, Next, St).

-doc "Authorize one canonical request in a committed read-only session before releasing its signature.".
-spec sign_agent_request(term(), term(), tuple()) -> term().
sign_agent_request({sign_agent_request, Typed0, Signature}, Next, #est{bs = Bs} = St) ->
    case quod_proof_session:read_only_state(St) of
        true -> sign_typed(erlog_int:dderef(Typed0, Bs), Signature, Next, St);
        false -> erlog_int:fail(St)
    end.

sign_typed({agent_goal_v1, Network,
            {agent_instance_ref, Ns, Anchor, _} = AgentRef, InstanceText, Pub,
            Operation, Deadline, Mode, Parser, GoalText} = Typed, Signature, Next, St) ->
    Request = #{network_identity => Network, agent_namespace => Ns,
                agent_genesis_anchor => Anchor, agent_instance_text => InstanceText,
                signing_public_key => Pub, operation_id => Operation,
                not_after_ms => Deadline, mode => Mode, parser_version => Parser,
                goal_text => GoalText},
    case {quod_runtime_predicates:scope_identity(St),
          quod_client_goal:encode(Request), quod_node_actor:principal()} of
        {{ok, {Ns, Anchor}}, {ok, _}, {ok, NodePrincipal}} ->
            case {quod_agent_ref:from_text(Ns, Anchor, InstanceText, Parser),
                  quod_wire_term:encode_canonical(AgentRef),
                  quod_agent_ref:materialize_principal(NodePrincipal)} of
                {{ok, #{blob := Blob}}, {ok, Blob}, {ok, NodeRef}} ->
                    authorize_sign(Request, Typed, NodeRef, Signature, Next, St);
                _ -> erlog_int:fail(St)
            end;
        _ -> erlog_int:fail(St)
    end;
sign_typed(_, _Signature, _Next, St) -> erlog_int:fail(St).

authorize_sign(Request, Typed, NodeRef,
               Signature, Next, #est{vn = Vn} = St) ->
    %% All arguments except the engine-authenticated caller are ground. The
    %% existing interpreter evaluates the ordinary ontology policy against this
    %% immutable read-only session; no staged grant can authorize this release.
    Now = quod_time:mono_ms(),
    Remaining = case quod_scope_session:remaining_ms() of
        {ok, Budget} -> Budget;
        error -> quod_proof_context:remaining_ms()
    end,
    Deadline = Now + Remaining,
    Policy = {',', {current_principal, {Vn}},
              {can_sign_agent_request, {Vn}, NodeRef, Typed}},
    case quod_ask:authorization_result(Policy, St) of
        allowed ->
            case quod_agent_vault:sign(Request, Deadline) of
                {ok, _Bytes, Signed} ->
                    erlog_int:unify_prove_body(Signature, Signed, Next, St);
                {error, _} -> erlog_int:fail(St)
            end;
        _ -> erlog_int:fail(St)
    end.

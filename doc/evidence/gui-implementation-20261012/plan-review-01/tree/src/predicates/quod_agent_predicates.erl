-module(quod_agent_predicates).
-moduledoc """
Governed bridges for an ontology containing hosted agents. The containing
ontology explicitly declares this installed module; domain actions and policy remain Prolog.

`current_principal(-Principal)` reuses the authenticated-principal bridge.
Request signing uses the universal runtime bridge's exact proof scope; it
does not obtain identity from a live node observation.

Key preparation is an explicitly authorized read-only service over that same
scope. It retains stable encrypted custody without assigning or activating an
agent. The destination is explicit and its preparation policy is pure Prolog.
""".

-include_lib("erlog/src/erlog_int.hrl").

-export([quod_predicate_module/0, load/1,
         sign_agent_request/3, reconcile_agent_hosts/3, reconcile_agent_observers/3,
         local_node_agent/3, prepare_agent_key_custody/3]).

quod_predicate_module() -> true.

-spec load(tuple()) -> tuple().
load(Est) ->
    WithPrincipal = quod_predicates:register(
                      Est, {current_principal, 1}, query, proof_bound,
                      quod_ontology_predicates, current_principal_predicate),
    WithLocalNode = quod_predicates:register(WithPrincipal, {local_node_agent, 1}, query,
                                             ?MODULE, local_node_agent),
    WithCustody = quod_predicates:register(WithLocalNode, {prepare_agent_key_custody, 5}, query,
                                           ?MODULE, prepare_agent_key_custody),
    WithSigning = quod_predicates:register(WithCustody, {sign_agent_request, 2}, query,
                                           ?MODULE, sign_agent_request),
    WithHosting = quod_predicates:register(WithSigning, {reconcile_agent_hosts, 1}, query,
                                            ?MODULE, reconcile_agent_hosts),
    quod_predicates:register(WithHosting, {reconcile_agent_observers, 1}, query,
                              ?MODULE, reconcile_agent_observers).

-doc "Observe the installed local node identity; this is not committed proof authority.".
-spec local_node_agent(term(), term(), tuple()) -> term().
local_node_agent({local_node_agent, Node}, Next, St) ->
    case quod_node_actor:reference() of
        {ok, NodeRef} ->
            erlog_int:unify_prove_body(Node, NodeRef, Next, St);
        _ -> quod_predicates:fail_reason(node_actor_unavailable,St)
    end.

-doc "Ask the existing resource owner to reconcile from its own committed selection.".
reconcile_agent_hosts({reconcile_agent_hosts, Scope}, Next, St) ->
    quod_runtime_predicates:request_resource(agent_hosts, Scope, Next, St).

reconcile_agent_observers({reconcile_agent_observers, Scope}, Next, St) ->
    quod_runtime_predicates:request_resource(agent_observers, Scope, Next, St).

-doc "Prepare stable custody for an exact prior assignment, including none/0.".
prepare_agent_key_custody({prepare_agent_key_custody, A0, H0, E0, N0, K0}, Next,
                          St = #est{bs = Bs}) ->
    Context = quod_predicates:context(St),
    case quod_predicates:ctx_kind(Context) of
        proof -> ok;
        Kind -> erlog_int:erlog_error(
            {context_violation, prepare_agent_key_custody, query, Kind}, St)
    end,
    case quod_proof_session:read_only_state(St) of
        true -> ok;
        false -> erlog_int:erlog_error(
            {context_violation, prepare_agent_key_custody, query, write_proof}, St)
    end,
    [Agent, Host, Epoch, Node, Key] = erlog_int:dderef([A0,H0,E0,N0,K0], Bs),
    case quod_wire_term:is_ground([Agent,Host,Epoch,Node]) of
        true -> ok;
        false -> erlog_int:instantiation_error(St)
    end,
    case {Agent, Epoch, Key} of
        {{agent_instance_ref, Ns, <<_:256>> = Anchor, Instance}, E, {_}}
          when is_binary(Ns), byte_size(Ns) > 0, is_integer(E), E >= 0, E < (1 bsl 64) ->
            case quod_runtime_predicates:scope_identity(St) of
                {ok, {Ns, Anchor}} ->
                    case local_destination(Node) of
                        true -> authorize_custody(Agent, Instance, Host, Epoch, Node, Key, Next, St);
                        false -> quod_predicates:fail_reason(custody_destination_unavailable, St)
                    end;
                _ -> erlog_int:erlog_error(
                    {context_violation, prepare_agent_key_custody, query, foreign_scope}, St)
            end;
        _ -> erlog_int:domain_error(agent_key_preparation, {Agent,Host,Epoch,Node,Key}, St)
    end.

local_destination(Node) ->
    quod_node_actor:reference() =:= {ok, Node}.

authorize_custody(Agent, Instance, Host, Epoch, Node, Key, Next, St = #est{vn = Vn}) ->
    Blob = case quod_wire_term:encode_canonical(Agent) of
        {ok, Encoded} ->
            case quod_agent_ref:decode(Encoded) of
                {ok, _} -> Encoded;
                _ -> erlog_int:domain_error(agent_reference, Agent, St)
            end;
        _ -> erlog_int:domain_error(agent_reference, Agent, St)
    end,
    {succeed, PrincipalState} = erlog_int:prove_goal({current_principal, {Vn}}, St),
    Caller = erlog_int:dderef({Vn}, PrincipalState#est.bs),
    Policy = {agent_key_preparation, Caller, Instance, Host, Epoch, Node},
    case custody_policy(Policy, St) of
        allowed ->
            Deadline = case quod_scope_session:remaining_ms() of
                {ok, Remaining} -> quod_time:mono_ms() + Remaining;
                error -> quod_proof_context:deadline_ms()
            end,
            case quod_agent_vault:prepare(Blob, Epoch, Deadline) of
                {ok, PublicKey} ->
                    %% The installed destination may have withdrawn while the
                    %% vault was busy. Its staged key remains inert and reusable.
                    case local_destination(Node) of
                        true -> erlog_int:unify_prove_body(Key, PublicKey, Next, St);
                        false -> quod_predicates:fail_reason(custody_destination_unavailable, St)
                    end;
                {error, Reason} -> quod_predicates:fail_reason({agent_custody_unavailable, Reason}, St)
            end;
        denied -> erlog_int:fail(St);
        invalid -> erlog_int:erlog_error(invalid_custody_policy, St)
    end.

custody_policy(Policy, St) ->
    Context = quod_predicates:context(St),
    Strict = quod_predicates:with_chain(quod_predicates:policy_verdict_context(
        quod_predicates:ctx_ns(Context), quod_predicates:ctx_height(Context)),
        quod_predicates:ctx_chain(Context)),
    Committed = quod_predicates:set_context(quod_erlog_db_local_prove:committed_state(St), Strict),
    Wrapped = #est{db = #db{ref = Overlay}} = quod_erlog_db_local_prove:wrap_state(Committed,
        #{read_only => true, read_set => true, access_guard => quod_erlog_db_local_prove:access_guard(St)}),
    try quod_ask:authorization_result(Policy, Wrapped)
    after
        try quod_erlog_db_local_prove:absorb_read_set(St, quod_erlog_db_local_prove:get_read_set(Overlay))
        after quod_erlog_db_local_prove:cleanup_read_set(Wrapped) end
    end.

-doc "Authorize one canonical request in a committed read-only session before releasing its signature.".
-spec sign_agent_request(term(), term(), tuple()) -> term().
sign_agent_request({sign_agent_request, Typed0, Signature}, Next, #est{bs = Bs} = St) ->
    case quod_proof_session:read_only_state(St) of
        true -> sign_typed(erlog_int:dderef(Typed0, Bs), Signature, Next, St);
        false -> erlog_int:erlog_error({context_violation,sign_agent_request,query,write_proof},St)
    end.

sign_typed({agent_goal_v1, Network,
            {agent_instance_ref, Ns, Anchor, _} = AgentRef, InstanceText, Pub,
            Operation, Deadline, Mode, Parser, GoalText} = Typed, Signature, Next, St) ->
    Request = #{network_identity => Network, agent_namespace => Ns,
                agent_genesis_anchor => Anchor, agent_instance_text => InstanceText,
                signing_public_key => Pub, operation_id => Operation,
                not_after_ms => Deadline, mode => Mode, parser_version => Parser,
                goal_text => GoalText},
    case quod_wire_term:is_ground(Typed) of
        false -> erlog_int:instantiation_error(St);
        true ->
            case quod_client_goal:encode(Request) of
                {error,_} -> erlog_int:domain_error(agent_request,Typed,St);
                {ok,_} ->
                    case quod_runtime_predicates:scope_identity(St) of
                        error -> quod_predicates:fail_reason({scope_identity_unavailable,Ns},St);
                        {ok,{Ns,Anchor}} ->
                            case quod_node_actor:principal() of
                                {ok,NodePrincipal} ->
                                    case {quod_agent_ref:from_text(Ns,Anchor,InstanceText,Parser),
                                          quod_wire_term:encode_canonical(AgentRef),
                                          quod_agent_ref:materialize_principal(NodePrincipal)} of
                                        {{ok,#{blob := Blob}},{ok,Blob},{ok,NodeRef}} ->
                                            authorize_sign(Request,Typed,NodeRef,Signature,Next,St);
                                        _ -> erlog_int:domain_error(agent_request,Typed,St)
                                    end;
                                _ -> quod_predicates:fail_reason(node_actor_unavailable,St)
                            end;
                        {ok,_} -> erlog_int:erlog_error(
                            {context_violation,sign_agent_request,query,foreign_scope},St)
                    end
            end
    end;
sign_typed(Typed, _Signature, _Next, St) ->
    case quod_wire_term:is_ground(Typed) of
        false -> erlog_int:instantiation_error(St);
        true -> erlog_int:domain_error(agent_request,Typed,St)
    end.

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
                {error,Reason} -> quod_predicates:fail_reason({agent_signing_unavailable,Reason},St)
            end;
        denied -> erlog_int:fail(St);
        invalid -> erlog_int:erlog_error(invalid_signing_policy,St)
    end.

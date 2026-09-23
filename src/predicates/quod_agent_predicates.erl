-module(quod_agent_predicates).
-moduledoc """
Governed bridges for an ontology containing hosted agents. The containing
ontology explicitly pins this module; domain actions and policy remain Prolog.

`current_principal(-Principal)` reuses the authenticated-principal bridge.
`current_ontology_identity(-Namespace, -Anchor)` reads the current exact scope
from engine-owned proof context. Both are bounded proof-bound queries, not
node observations, and fail when their authenticated context is absent.
""".

-include_lib("erlog/src/erlog_int.hrl").

-export([quod_predicate_module/0, load/1, current_ontology_identity/3,
         current_request_expiry/3,
         sign_agent_request/3, project_agent_hosts/3, submit_agent_goal/3, local_node_agent/3]).

quod_predicate_module() -> true.

-spec load(tuple()) -> tuple().
load(Est) ->
    WithPrincipal = quod_predicates:register(
                      Est, {current_principal, 1}, query, proof_bound,
                      quod_ontology_predicates, current_principal_predicate),
    WithExpiry = quod_predicates:register(
      WithPrincipal, {current_request_expiry, 1}, query, proof_bound,
      ?MODULE, current_request_expiry),
    WithIdentity = quod_predicates:register(
      WithExpiry, {current_ontology_identity, 2}, query, proof_bound,
      ?MODULE, current_ontology_identity),
    WithLocalNode = quod_predicates:register(WithIdentity, {local_node_agent, 1}, query,
                                             ?MODULE, local_node_agent),
    WithSigning = quod_predicates:register(WithLocalNode, {sign_agent_request, 2}, query,
                                           ?MODULE, sign_agent_request),
    WithHosting = quod_predicates:register(WithSigning, {project_agent_hosts, 2}, projection,
                                           ?MODULE, project_agent_hosts),
    quod_predicates:register(WithHosting, {submit_agent_goal, 4}, reaction,
                             ?MODULE, submit_agent_goal).

-doc "Observe the installed local node identity; this is not committed proof authority.".
-spec local_node_agent(term(), term(), tuple()) -> term().
local_node_agent({local_node_agent, Node}, Next, St) ->
    case quod_node_actor:principal() of
        {ok, Principal} ->
            {ok, NodeRef} = quod_agent_ref:materialize_principal(Principal),
            erlog_int:unify_prove_body(Node, NodeRef, Next, St);
        _ -> erlog_int:fail(St)
    end.

-doc "Bind verified request metadata; no live clock observation enters the proof.".
current_request_expiry({current_request_expiry, Expiry}, Next, St) ->
    Bound = case quod_scope_session:request_expiry() of
        error -> quod_proof_context:request_expiry();
        ScopeExpiry -> ScopeExpiry
    end,
    case Bound of
        {ok, Value} -> erlog_int:unify_prove_body(Expiry, Value, Next, St);
        none -> erlog_int:fail(St)
    end.

-doc "Project committed host assignments into the existing runtime owner.".
project_agent_hosts({project_agent_hosts, Scope0, Hosts0}, Next, #est{bs = Bs} = St) ->
    Ctx = quod_predicates:context(St),
    [Scope, Hosts] = erlog_int:dderef([Scope0, Hosts0], Bs),
    case quod_runtime:project_agents(quod_predicates:ctx_ns(Ctx),
                                     quod_predicates:ctx_height(Ctx),
                                     quod_predicates:ctx_handler(Ctx), Scope, Hosts) of
        ok -> erlog_int:prove_body(Next, St);
        {error, Reason} -> throw({erlog_error, {agent_projection_failed, Reason}})
    end.

-doc "Submit bounded work only for the hosted executor selected by this reaction.".
submit_agent_goal({submit_agent_goal, Instance0, Mode0, Goal0, Timeout0}, Next, #est{bs = Bs} = St) ->
    [Instance, Mode, Goal, Timeout] = erlog_int:dderef([Instance0, Mode0, Goal0, Timeout0], Bs),
    Ctx = quod_predicates:context(St),
    case {quod_predicates:ctx_executor(Ctx), quod_wire_term:is_ground(Goal)} of
        {{agent, Instance, _, _} = Executor, true}
          when (Mode =:= read orelse Mode =:= execute), is_integer(Timeout),
               Timeout > 0, Timeout =< 60000 ->
            case quod_client_goal_parser:format(Goal) of
                {ok, _} ->
                    case quod_runtime:agent_request(quod_predicates:ctx_ns(Ctx),
                           quod_predicates:ctx_height(Ctx), Executor, Mode, Goal, Timeout) of
                        ok -> erlog_int:prove_body(Next, St);
                        {error, _} -> erlog_int:fail(St)
                    end;
                _ -> erlog_int:fail(St)
            end;
        _ -> erlog_int:fail(St)
    end.

-doc "Bind the exact identity of the executing proof scope without a live lookup.".
-spec current_ontology_identity(term(), term(), tuple()) -> term().
current_ontology_identity({current_ontology_identity, Namespace, Anchor}, Next, St) ->
    case scope_identity(St) of
        {ok, {Ns, Hash}} ->
            erlog_int:unify_prove_body([Namespace, Anchor], [Ns, Hash], Next, St);
        error -> erlog_int:fail(St)
    end.

scope_identity(St) ->
    Context = quod_predicates:context(St),
    case {quod_predicates:ctx_ns(Context), quod_predicates:ctx_chain(Context)} of
        {Ns, [{Ns, <<_:256>> = Hash} | _]} when is_binary(Ns), byte_size(Ns) > 0 ->
            {ok, {Ns, Hash}};
        _ -> error
    end.

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
    case {scope_identity(St), quod_client_goal:encode(Request), quod_node_actor:principal()} of
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

-module(quod_node_actor).
-moduledoc """
Construction, exact local binding, and verification for this physical node's
ontology-backed actor identity.

Creation remains the ordinary root `create_ontology/3` action.  This module
builds its options, stores the one bootstrap pointer through `quod_identity`,
and verifies the resulting durable facts. It owns no process, lifecycle path,
ACL evaluator, signer, route, or cache.
""".

-export([creation_options/4, reference/4, bind/4, principal/0, signed_goal/4, signed_goal/5,
         hosting_projection/5,
         bootstrap/0, verify/2]).
-ifdef(TEST).
-export([test_normalize_projection/3]).
-endif.

-spec creation_options(binary(), binary(), 1 | 2, <<_:256>>) ->
          {ok, [term()]} | {error, term()}.
creation_options(Namespace, InstanceText, ParserVersion,
                 <<_:256>> = PublicKey)
  when is_binary(Namespace), is_binary(InstanceText) ->
    case {quod_ontology:canonical_name(Namespace),
          quod_client_goal_parser:parse(InstanceText, ParserVersion)} of
        {{ok, Namespace},
         {ok, #{goal := InstanceTerm, variables := []}}} ->
            creation_terms(Namespace, InstanceTerm, PublicKey);
        _ ->
            {error, invalid_node_instance}
    end;
creation_options(_Namespace, _InstanceText, _ParserVersion, _PublicKey) ->
    {error, invalid_node_actor}.

-spec reference(binary(), <<_:256>>, binary(), 1 | 2) ->
          {ok, binary()} | {error, term()}.
reference(Namespace, <<_:256>> = Anchor, InstanceText, ParserVersion) ->
    case quod_agent_ref:from_text(
           Namespace, Anchor, InstanceText, ParserVersion) of
        {ok, #{blob := Blob}} -> {ok, Blob};
        {error, _} = Error -> Error
    end.

-doc """
Bind this node to an already-created ordinary ontology after verifying its
exact durable identity.  Creation itself remains the root action.
""".
-spec bind(binary(), <<_:256>>, binary(), 1 | 2) ->
          {ok, {agent, binary()}} | {error, term()}.
bind(Namespace, Anchor, InstanceText, ParserVersion) ->
    case {application:get_env(quod, identity_dir),
          application:get_env(quod, node_pubkey),
          reference(Namespace, Anchor, InstanceText, ParserVersion)} of
        {{ok, Dir}, {ok, <<_:256>> = PublicKey}, {ok, Blob}} ->
            case verify(Blob, PublicKey) of
                {ok, Principal} ->
                    case quod_identity:store_node_actor_pointer(Dir, Blob) of
                        ok ->
                            _ = catch quod_namespace_manager:adopt_node_actor(),
                            {ok, Principal};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {_, _, {error, _} = Error} -> Error;
        _ -> {error, node_identity_unavailable}
    end.

-doc "Return the currently verified common agent principal for this node.".
-spec principal() -> {ok, {agent, binary()}} | {error, unavailable}.
principal() ->
    case application:get_env(quod, node_actor_principal) of
        {ok, {agent, Blob} = Principal} when is_binary(Blob) ->
            {ok, Principal};
        _ ->
            {error, unavailable}
    end.

-doc """
Construct one ordinary signed goal under this node's installed agent identity.
The caller owns the operation id and expiry; this helper neither submits nor
retries it. Authorization remains the target ontology's ordinary ACL. It uses
the existing physical identity signer and never substitutes node authority for
another agent's signature.
""".
-spec signed_goal(read | execute, term(), <<_:256>>, pos_integer()) ->
          {ok, binary(), binary()} | {error, term()}.
signed_goal(Mode, Goal, <<_:256>> = Operation, Expiry)
  when (Mode =:= read orelse Mode =:= execute), is_integer(Expiry), Expiry > 0 ->
    signed_goal(Mode, Goal, Operation, Expiry, current);
signed_goal(_, _, _, _) -> {error, invalid_request}.

-doc "Construct a node request only while its explicit executor binding remains current.".
-spec signed_goal(read | execute, term(), <<_:256>>, pos_integer(), current | {term(), <<_:256>>}) ->
          {ok, binary(), binary()} | {error, term()}.
signed_goal(Mode, Goal, <<_:256>> = Operation, Expiry, Expected)
  when (Mode =:= read orelse Mode =:= execute), is_integer(Expiry), Expiry > 0 ->
    case {principal(), quod_ontology:network_identity(),
          application:get_env(quod, node_pubkey), application:get_env(quod, identity_key)} of
        {{ok, Principal}, {ok, Network}, {ok, PublicKey}, {ok, Signer}} ->
            {ok, {agent_instance_ref, Ns, Anchor, Instance}} =
                quod_agent_ref:materialize_principal(Principal),
            Ref = {agent_instance_ref, Ns, Anchor, Instance},
            case {Expected =:= current orelse Expected =:= {Ref, PublicKey},
                  quod_client_goal_parser:format(Instance), quod_client_goal_parser:format(Goal)} of
                {true, {ok, InstanceText}, {ok, GoalText}} ->
                    %% The canonical formatter emits version-2 binary terms.
                    Request = #{network_identity => Network, agent_namespace => Ns,
                      agent_genesis_anchor => Anchor, agent_instance_text => InstanceText,
                      signing_public_key => PublicKey, operation_id => Operation,
                      not_after_ms => Expiry, mode => Mode, parser_version => 2,
                      goal_text => GoalText},
                    case quod_client_goal:encode(Request) of
                        {ok, Bytes} -> {ok, Bytes, quod_identity:sign(Bytes, Signer)};
                        {error, _} = Error -> Error
                    end;
                {false, _, _} -> {error, stale_node_executor};
                _ -> {error, invalid_goal}
            end;
        _ -> {error, node_identity_unavailable}
    end;
signed_goal(_, _, _, _, _) -> {error, invalid_request}.

-doc "Validate and install one complete committed hosting projection.".
-spec hosting_projection(binary(), non_neg_integer(), term(), [term()], [term()]) ->
          ok | {error, term()}.
hosting_projection(Namespace, Height, Scope, Hosts0, Contacts0)
  when is_binary(Namespace), is_integer(Height), Height >= 0,
       is_list(Hosts0), is_list(Contacts0) ->
    case {principal(), quod_ontology:genesis_anchor(Namespace)} of
        {{ok, Principal}, {ok, Anchor}} ->
            case quod_agent_ref:materialize_principal(Principal) of
                {ok, {agent_instance_ref, Namespace, Anchor, _} = NodeRef} ->
                    case normalize_projection(NodeRef, Hosts0, Contacts0) of
                        {ok, Projection} ->
                            quod_namespace_manager:project_node_policy(
                              Namespace, Height, Scope, Projection);
                        {error, _} = Error -> Error
                    end;
                _ -> {error, node_actor_context_mismatch}
            end;
        %% A freshly created node actor runs its immutable founding handler
        %% before the local pointer can be bound. It has no authority to
        %% project yet, so leave the previous projection untouched.
        _ -> ok
    end;
hosting_projection(_, _, _, _, _) ->
    {error, malformed_node_hosting_projection}.

normalize_projection(NodeRef, Hosts0, Contacts0) ->
    case {normalize_hosts(NodeRef, Hosts0, #{}),
          normalize_contacts(NodeRef, Contacts0, #{})} of
        {{ok, Hosts}, {ok, Contacts}} ->
            {ok, #{hosts => Hosts, contacts => Contacts}};
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

normalize_hosts(_NodeRef, [], Acc) -> {ok, Acc};
normalize_hosts(NodeRef,
                [{host, NodeRef, Ns0, <<_:256>> = Anchor, Visibility} | Rest],
                Acc)
  when Visibility =:= private; Visibility =:= discoverable ->
    case quod_ontology:canonical_name(Ns0) of
        {ok, Ns} ->
            Row = #{namespace => Ns, anchor => Anchor,
                    visibility => Visibility},
            case maps:get(Ns, Acc, undefined) of
                undefined -> normalize_hosts(NodeRef, Rest, Acc#{Ns => Row});
                Row -> normalize_hosts(NodeRef, Rest, Acc);
                _ -> {error, {conflicting_hosting_fact, Ns}}
            end;
        _ -> {error, malformed_node_hosting_projection}
    end;
normalize_hosts(_, _, _) -> {error, malformed_node_hosting_projection}.

normalize_contacts(_NodeRef, [], Acc) -> {ok, Acc};
normalize_contacts(NodeRef,
                   [{contact, NodeRef, Ns0, <<_:256>> = Anchor,
                     HostNodeRef} | Rest], Acc) ->
    case {quod_ontology:canonical_name(Ns0), valid_agent_reference(HostNodeRef)} of
        {{ok, Ns}, true} ->
            Row = #{namespace => Ns, anchor => Anchor,
                    host_node_ref => HostNodeRef},
            Key = {Ns, HostNodeRef},
            case maps:get(Key, Acc, undefined) of
                undefined ->
                    normalize_contacts(NodeRef, Rest, Acc#{Key => Row});
                Row -> normalize_contacts(NodeRef, Rest, Acc);
                _ -> {error, {conflicting_host_contact, Ns}}
            end;
        _ -> {error, malformed_node_hosting_projection}
    end;
normalize_contacts(_, _, _) -> {error, malformed_node_hosting_projection}.

valid_agent_reference(Ref) ->
    case quod_wire_term:encode_canonical(Ref) of
        {ok, Blob} ->
            case quod_agent_ref:decode(Blob) of
                {ok, #{reference := Ref}} -> true;
                _ -> false
            end;
        _ -> false
    end.

-ifdef(TEST).
test_normalize_projection(NodeRef, Hosts, Contacts) ->
    normalize_projection(NodeRef, Hosts, Contacts).
-endif.

-doc "Load the exact local pointer and build its existing-ledger resume config.".
-spec bootstrap() ->
          none | {ok, binary(), map()} | {error, term()}.
bootstrap() ->
    case {application:get_env(quod, identity_dir),
          application:get_env(quod, node_pubkey)} of
        {{ok, Dir}, {ok, <<_:256>>}} ->
            case quod_identity:load_node_actor_pointer(Dir) of
                none -> none;
                {ok, Blob} -> bootstrap_pointer(Blob);
                {error, _} = Error -> Error
            end;
        _ -> none
    end.

bootstrap_pointer(Blob) ->
    case {quod_agent_ref:decode(Blob),
          application:get_env(quod, content_data_dir)} of
        {{ok, #{identity := {Namespace, Anchor}}}, {ok, DataDir}} ->
            case quod_ontology:prepare_local_resume(
                   Namespace, Anchor, DataDir) of
                {ok, Config} -> {ok, Blob, Config};
                {error, _} = Error -> Error
            end;
        {{error, _}, _} -> {error, invalid_node_actor_pointer};
        {_, undefined} -> {error, node_storage_unavailable}
    end.

-doc "Verify the exact anchored node instance and its sole active key.".
-spec verify(binary(), <<_:256>>) ->
          {ok, {agent, binary()}} | {error, term()}.
verify(Blob, <<_:256>> = PublicKey) ->
    case quod_agent_ref:decode(Blob) of
        {ok, #{identity := {Namespace, Anchor}, instance := Instance}} ->
            case quod_ontology:genesis_anchor(Namespace) of
                {ok, Anchor} -> verify_facts(Namespace, Instance, PublicKey, Blob);
                {ok, _Other} -> {error, node_actor_anchor_mismatch};
                {error, _} = Error -> Error
            end;
        {error, _} ->
            {error, invalid_node_actor_pointer}
    end;
verify(_Blob, _PublicKey) ->
    {error, invalid_node_actor_pointer}.

verify_facts(Namespace, Instance, PublicKey, Blob) ->
    Node = {'NodeActorInstance'},
    Nodes = {'NodeActorInstances'},
    Key = {'NodeActorKey'},
    Keys = {'NodeActorKeys'},
    Goal =
        {',',
         {findall, Node, {instance_of, node, Node}, Nodes},
         {findall, Key, {agent_key, Instance, Key, active}, Keys}},
    case quod_prolog:prove_ro(Namespace, Goal) of
        {ok, [Bindings], _Height} when is_map(Bindings) ->
            case {maps:get('NodeActorInstances', Bindings, malformed),
                  maps:get('NodeActorKeys', Bindings, malformed)} of
                {[Instance], [PublicKey]} -> {ok, {agent, Blob}};
                {[Instance], [_ | _]} ->
                    {error, node_actor_active_key_mismatch};
                {[Instance], []} -> {error, node_actor_inactive_key};
                {[_ | _], _} -> {error, node_actor_instance_mismatch};
                {[], _} -> {error, node_actor_instance_mismatch};
                _ -> {error, malformed_node_actor_identity}
            end;
        fail -> {error, node_actor_instance_mismatch};
        {fail, _} -> {error, node_actor_instance_mismatch};
        {error, _} = Error -> Error;
        _ -> {error, malformed_node_actor_identity}
    end.

creation_terms(Namespace, InstanceTerm0, PublicKey) ->
    ExecutionPath = filename:join(code:priv_dir(quod), "ontologies/node_execution.pl"),
    case {quod_wire_term:materialize_symbols(InstanceTerm0), file:read_file(ExecutionPath)} of
        {{ok, InstanceTerm}, {ok, ExecutionPolicy}} ->
            Terms =
                [{node_ontology, Namespace},
                 {instance_of, node, InstanceTerm},
                 {agent_key, InstanceTerm, PublicKey, active}],
            {ok, [{terms, Terms},
                  %% Source is chardata; retain its compact binary form on the
                  %% public goal and materialize characters only inside the
                  %% existing lifecycle parser.
                  {source, ExecutionPolicy},
                  {external_predicate_modules,
                   [quod_ontology_predicates]}]};
        {{error, _}, _} -> {error, invalid_node_instance};
        {_, {error, _}} -> {error, node_execution_policy_unavailable}
    end.

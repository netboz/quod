-module(quod_node_actor).
-moduledoc """
Construction, exact local binding, and verification for this physical node's
ontology-backed actor identity.

Creation remains the ordinary root `create_ontology/3` action under Prolog
policy. This module signs the request, retains the exact bootstrap pointer
through `quod_identity`, and verifies the resulting durable facts. It owns no process, lifecycle path,
ACL evaluator, signer, route, or cache.
""".

-export([reference/4, bind/4, principal/0, signed_goal/4, signed_goal/5,
         hosting_projection/5,
         bootstrap/0, verify/2, enroll/0]).
-ifdef(TEST).
-export([test_normalize_projection/3, test_resolved_retained/5]).
-endif.

-spec reference(binary(), <<_:256>>, binary(), 1 | 2 | 3) ->
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
-spec bind(binary(), <<_:256>>, binary(), 1 | 2 | 3) ->
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
-spec signed_goal(read | execute | control, term(), <<_:256>>, pos_integer()) ->
          {ok, binary(), binary()} | {error, term()}.
signed_goal(Mode, Goal, <<_:256>> = Operation, Expiry)
  when (Mode =:= read orelse Mode =:= execute orelse Mode =:= control), is_integer(Expiry), Expiry > 0 ->
    signed_goal(Mode, Goal, Operation, Expiry, current);
signed_goal(_, _, _, _) -> {error, invalid_request}.

-doc "Construct a node request only while its explicit executor binding remains current.".
-spec signed_goal(read | execute | control, term(), <<_:256>>, pos_integer(), current | {term(), <<_:256>>}) ->
          {ok, binary(), binary()} | {error, term()}.
signed_goal(Mode, Goal, <<_:256>> = Operation, Expiry, Expected)
  when (Mode =:= read orelse Mode =:= execute orelse Mode =:= control), is_integer(Expiry), Expiry > 0 ->
    case {principal(), quod_ontology:network_identity(),
          application:get_env(quod, node_pubkey), application:get_env(quod, identity_key)} of
        {{ok, Principal}, {ok, Network}, {ok, PublicKey}, {ok, Signer}} ->
            {ok, {agent_instance_ref, Ns, Anchor, Instance}} =
                quod_agent_ref:materialize_principal(Principal),
            Ref = {agent_instance_ref, Ns, Anchor, Instance},
            case Expected =:= current orelse Expected =:= {Ref, PublicKey} of
                true -> sign_goal(Ref, Goal, Network, PublicKey, Signer, Mode, Operation, Expiry);
                false -> {error, stale_node_executor}
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
        %% Identity readiness will wake the owning runtime. An unavailable
        %% governing identity is not a successfully installed projection.
        _ -> {error, node_actor_unavailable}
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
test_resolved_retained(Dir, Phase, Bytes, Sig, Resolution) ->
    resolved_retained(Dir, Phase, Bytes, Sig, Resolution).
-endif.

-doc "Load the exact local pointer and build its existing-ledger resume config.".
-spec bootstrap() ->
          none | {pending, none | binary()} | {ok, binary(), map()} | {error, term()}.
bootstrap() ->
    case {application:get_env(quod, identity_dir),
          application:get_env(quod, node_pubkey)} of
        {{ok, Dir}, {ok, <<_:256>>}} ->
            case quod_identity:load_node_actor_pointer(Dir) of
                none -> none;
                {ok, Blob} -> bootstrap_pointer(Blob);
                {pending, #{request := {Bytes, Sig}, reference := Ref}} ->
                    case quod_client_goal:verify(Bytes, Sig) of
                        {ok, #{request := #{signing_public_key := Key,
                                            network_identity := Network}}} ->
                            case {application:get_env(quod, node_pubkey),
                                  quod_ontology:network_identity()} of
                                {{ok, Key}, {ok, Network}} when Ref =:= none -> {pending, none};
                                {{ok, Key}, {ok, Network}} -> pending_bootstrap(Ref);
                                {{ok, Key}, {error, _}} -> {pending, none};
                                _ -> {error, node_enrollment_request_mismatch}
                            end;
                        _ -> {error, node_enrollment_request_mismatch}
                    end;
                {error, _} = Error -> Error
            end;
        _ -> none
    end.

pending_bootstrap(Blob) ->
    {ok, #{identity := {Ns, Anchor}}} = quod_agent_ref:decode(Blob),
    case quod_ontology:prepare_host_join(Ns, Anchor, []) of
        {ok, Config} -> {ok, Blob, Config};
        {error, unavailable} ->
            case quod_directory:validator_routes(Ns, Anchor) of
                {ok, Routes} when Routes =/= [] ->
                    Seeds = lists:usort([E || #{endpoint := E} <- Routes]),
                    case quod_ontology:prepare_host_join(Ns, Anchor, Seeds) of
                        {ok, Config} -> {ok, Blob, Config};
                        {error, _} = Error -> Error
                    end;
                _ -> {pending, Blob}
            end;
        {error, _} = Error -> Error
    end.

%% Called by the namespace manager's monitored worker. Custody is in node.actor,
%% policy in quod:node, and execution in the existing signed-goal ingress.
%% There is no request replay here: only the call which creates a custody row
%% may submit it. Every later call observes the original operation.
enroll() ->
    case {application:get_env(quod, identity_dir),
          application:get_env(quod, node_pubkey), quod_ontology:network_identity()} of
        {{ok, Dir}, {ok, <<_:256>> = Key}, {ok, Network}} ->
            case quod_identity:load_node_actor_pointer(Dir) of
                {ok, _} -> complete;
                none -> begin_enrollment(Dir, Key, Network);
                {pending, Pending} -> resume_enrollment(Dir, Key, Network, Pending);
                {error, _} = Error -> Error
            end;
        _ -> waiting
    end.

begin_enrollment(Dir, Key, Network) ->
    case enrollment_policy() of
        {ok, PolicyAnchor, Window} ->
            case allocated_identity(Key) of
                absent ->
                    Ref = {agent_instance_ref, <<"quod:node">>, PolicyAnchor, {enrolling, Key}},
                    {ok, Bytes, Sig} = sign_identity_goal(Ref, {enroll_node, {0}}, Network, Key, Window),
                    case quod_identity:begin_node_enrollment(Dir, Bytes, Sig) of
                        ok ->
                            submit_retained(Dir, enrollment, Bytes, Sig);
                        {error, _} = Error -> Error
                    end;
                {ok, _} -> {error, node_identity_pointer_missing};
                {error, _} = Error -> Error;
                _ -> waiting
            end;
        _ -> waiting
    end.

enrollment_policy() ->
    case quod_system_ontology:catalog() of
        {ok, _, Catalog, _} ->
            case [A || #{namespace := <<"quod:node">>, anchor := A} <- Catalog] of
                [Anchor] ->
                    case {quod_simplex:genesis_hash(<<"quod:node">>),
                          quod_prolog:prove_ro(<<"quod:node">>,
                            {node_enrollment_parameters, {'Window'}}),
                          quod_prolog:prove_ro(<<"quod:root">>,
                            {ontology_creation_policy, <<"quod:node">>, Anchor})} of
                        {Anchor, {ok, [#{'Window' := Window}], _}, {ok, [_], _}} ->
                            {ok, Anchor, Window};
                        _ -> waiting
                    end;
                _ -> waiting
            end;
        _ -> waiting
    end.

allocated_identity(Key) ->
    case quod_prolog:prove_ro(<<"quod:node">>,
        {findall, {'Ref'}, {node_identity_allocation, Key, {'Ref'}, {'_'}}, {'Rows'}}) of
        {ok, [#{'Rows' := []}], _} -> absent;
        {ok, [#{'Rows' := [Ref]}], _} ->
            case quod_wire_term:encode_canonical(Ref) of
                {ok, Blob} -> case quod_agent_ref:decode(Blob) of
                    {ok, _} -> {ok, Blob};
                    _ -> {error, invalid_node_allocation}
                end;
                _ -> {error, invalid_node_allocation}
            end;
        {ok, _, _} -> {error, conflicting_node_allocation};
        _ -> waiting
    end.

resume_enrollment(Dir, Key, Network,
                  #{request := {Bytes, Sig}, reference := Reference} = Pending) ->
    case quod_client_goal:verify(Bytes, Sig) of
        {ok, #{request := #{network_identity := Network, signing_public_key := Key,
                           agent_namespace := <<"quod:node">>,
                           agent_genesis_anchor := PolicyAnchor}}} ->
            case quod_ontology:genesis_anchor(<<"quod:node">>) of
                {ok, PolicyAnchor} -> resume_allocation(Dir, Key, Network, Reference, Pending);
                {ok, _} -> {error, node_enrollment_policy_mismatch};
                _ -> waiting
            end;
        _ -> {error, node_enrollment_request_mismatch}
    end.

resume_allocation(Dir, Key, Network, none, #{rejected := enrollment}) ->
    begin_enrollment(Dir, Key, Network);
resume_allocation(Dir, Key, Network, Reference, #{request := {Bytes, Sig}} = Pending) ->
    case Reference of
        none ->
            %% Resolution never resubmits. A committed allocation can
            %% become visible before the client completion is delivered.
            Resolution = quod_client_goal_ingress:resolve_operation(Bytes, Sig),
            case allocated_identity(Key) of
                {ok, Blob} ->
                    case quod_identity:retain_node_allocation(Dir, Blob) of
                        ok -> {allocated, Blob};
                        {error, _} = Error -> Error
                    end;
                absent -> resolved_retained(Dir, enrollment, Bytes, Sig, Resolution);
                Result -> Result
            end;
        Blob ->
            case allocated_identity(Key) of
                {ok, Blob} -> activate_node(Dir, Key, Network, Blob, Pending);
                {ok, _} -> {error, node_actor_identity_mismatch};
                absent -> {error, node_allocation_missing};
                Other -> Other
            end
    end.

activate_node(Dir, Key, Network, Blob, #{activation := Activation0, rejected := Rejected}) ->
    Activation = case Rejected of activation -> none; _ -> Activation0 end,
    case {principal(), verify(Blob, Key)} of
        {{ok, {agent, Blob}}, {ok, _}} ->
            {ok, #{identity := {Ns, Anchor}, reference := Ref}} = quod_agent_ref:decode(Blob),
            case quod_prolog:prove_ro(Ns, {hosts_ontology, Ref, Ns, Anchor, discoverable}) of
                {ok, [_], _} ->
                    case quod_identity:store_node_actor_pointer(Dir, Blob) of
                        ok -> complete;
                        {error, _} = Error -> Error
                    end;
                _ -> case Activation of
                    none -> case enrollment_policy() of
                        {ok, _, Window} ->
                            Goal = {host_ontology, Ref, Ns, Anchor, discoverable},
                            {ok, Bytes, Sig} = sign_identity_goal(Ref, Goal, Network, Key, Window),
                            case quod_identity:begin_node_activation(Dir, Bytes, Sig) of
                                ok -> submit_retained(Dir, activation, Bytes, Sig);
                                {error, _} = Error -> Error
                            end;
                        _ -> waiting
                    end;
                    {Bytes, Sig} ->
                        resolved_retained(Dir, activation, Bytes, Sig,
                            quod_client_goal_ingress:resolve_operation(Bytes, Sig))
                end
            end;
        _ -> {allocated, Blob}
    end.

submit_retained(Dir, Phase, Bytes, Sig) ->
    Result = quod_client_goal_ingress:submit(Bytes, Sig),
    case Result of
        %% Only the first dispatch reaches this branch. These errors precede
        %% execution; expiry observed later during recovery proves nothing.
        {error, Reason} when Reason =:= signed_target_unavailable;
                             Reason =:= signed_goal_unavailable;
                             Reason =:= node_identity_unavailable;
                             Reason =:= client_auth_unavailable;
                             Reason =:= client_goal_busy;
                             Reason =:= client_goal_rate_limited;
                             Reason =:= client_symbol_budget_exhausted;
                             Reason =:= atom_limit;
                             Reason =:= busy;
                             Reason =:= rebuilding;
                             Reason =:= client_cursor_unavailable;
                             Reason =:= invalid_signature;
                             Reason =:= invalid_request;
                             Reason =:= wrong_network;
                             Reason =:= wrong_target;
                             Reason =:= expired -> rejected_operation(Dir, Phase, Bytes, Sig);
        {error, {anchor_conflict, _}} -> rejected_operation(Dir, Phase, Bytes, Sig);
        {ok, _, {normalized, {failed, _}}} -> rejected_operation(Dir, Phase, Bytes, Sig);
        {ok, _, {normalized, fail}} -> rejected_operation(Dir, Phase, Bytes, Sig);
        _ -> {submitted, Result}
    end.

resolved_retained(Dir, Phase, Bytes, Sig,
                  {ok, _, {operation_outcome, _, #{status := Status, height := Height}}})
  when (Status =:= rejected orelse Status =:= aborted), is_integer(Height), Height > 0 ->
    %% The shared resolver binds the winning claim to these exact signed
    %% bytes and reads its installed/certified terminal outcome. A selected
    %% refused attempt, journal error, or absent claim is not this evidence.
    rejected_operation(Dir, Phase, Bytes, Sig);
resolved_retained(_Dir, _Phase, _Bytes, _Sig, _Resolution) -> unresolved.

rejected_operation(Dir, Phase, Bytes, Sig) ->
    case quod_identity:reject_node_operation(Dir, Phase, {Bytes, Sig}) of
        ok ->
            {ok, #{request := #{agent_namespace := Ns, agent_genesis_anchor := Anchor}}} =
                quod_client_goal:verify(Bytes, Sig),
            {refused, {Ns, Anchor}};
        {error, _} = Error -> Error
    end.

sign_identity_goal(Ref, Goal, Network, Key, Window) ->
    {ok, Signer} = application:get_env(quod, identity_key),
    sign_goal(Ref, Goal, Network, Key, Signer, execute,
              crypto:strong_rand_bytes(32), quod_time:now_ms() + Window).

sign_goal({agent_instance_ref, Ns, Anchor, Instance}, Goal, Network, Key,
          Signer, Mode, Operation, Expiry) ->
    case {quod_client_goal_parser:format(Instance), quod_client_goal_parser:format(Goal)} of
        {{ok, InstanceText}, {ok, GoalText}} ->
            Request = #{network_identity => Network, agent_namespace => Ns,
                        agent_genesis_anchor => Anchor, agent_instance_text => InstanceText,
                        signing_public_key => Key, operation_id => Operation,
                        not_after_ms => Expiry, mode => Mode,
                        parser_version => 3, goal_text => GoalText},
            case quod_client_goal:encode(Request) of
                {ok, Bytes} -> {ok, Bytes, quod_identity:sign(Bytes, Signer)};
                {error, _} = Error -> Error
            end;
        _ -> {error, invalid_goal}
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

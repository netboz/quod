-module(quod_fresh_systems).
-export([found/2, publish/2, add_policies/1, wait_principal/0, catalog/0,
         diagnose_enrollment/0, enrollment_evidence/0, delegate_signup/1,
         final_gate/0]).

found(Name, Dependencies) ->
    {Ns, File} = source(Name),
    {ok, not_hosted} = quod_ontology:local_state(Ns),
    Terms = terms(Name, Dependencies),
    Create = {create_ontology, Ns,
        [{source_file, list_to_binary(path(File))}, {terms, Terms},
         {external_predicate_modules, modules(Name)}], {'Anchor'}},
    {ok, [#{'Anchor' := Anchor}], _} =
        quod_prolog:execute(<<"quod:root">>, Create),
    ok = ready(Ns, 60000),
    Anchor = quod_simplex:genesis_hash(Ns),
    #{namespace => Ns, anchor => binary:encode_hex(Anchor),
      modules => verify_modules(Name)}.

modules(<<"gui">>) -> [quod_agent_predicates,quod_gui_predicates];
modules(_) -> [quod_agent_predicates].

verify_modules(Name) ->
    {Ns,_} = source(Name),
    {ok,[#{'Manifest' := Manifest}],_} = quod_prolog:prove_ro(
        Ns,{external_predicate_modules,{'Manifest'}}),
    Expected = modules(Name),
    Expected = [Module || {Module,<<_:256>>} <- Manifest],
    Expected.

publish(Name, Anchor) when is_binary(Anchor), byte_size(Anchor) =:= 32 ->
    {Ns, _} = source(Name),
    {ok, ready} = quod_ontology:local_state(Ns),
    Anchor = quod_simplex:genesis_hash(Ns),
    Published = case exact_rows(<<"quod:root">>, system_ontology, Ns) of
        [] ->
            {ok, [_], _} = quod_prolog:execute(<<"quod:root">>,
                {transaction, {assertz, {system_ontology, Ns, Anchor}}}),
            committed;
        [Anchor] -> already_committed;
        Other -> error({conflicting_system_catalogue, Ns, Other})
    end,
    #{namespace => Ns, anchor => binary:encode_hex(Anchor), published => Published}.

add_policies(Identities) when is_list(Identities), Identities =/= [] ->
    Missing = [{Ns, Anchor} || {Ns, Anchor} <- Identities,
                              policy_state(Ns, Anchor) =:= missing],
    case Missing of
        [] -> ok;
        _ ->
            Goals = [{assertz, {ontology_creation_policy, Ns, Anchor}}
                     || {Ns, Anchor} <- Missing],
            {ok, [_], _} = quod_prolog:execute(<<"quod:root">>,
                {transaction, conjunction(Goals)})
    end,
    #{creation_policies_committed => length(Missing),
      creation_policies_present => length(Identities)}.

wait_principal() ->
    true = quod_reg:subscribe({node_actor, node}),
    try await_principal(quod_time:mono_ms() + 60000)
    after quod_reg:unsubscribe({node_actor, node}) end.

catalog() ->
    {ok, Height, Descriptors, Rejected} = quod_system_ontology:catalog(),
    #{height => Height, descriptors => Descriptors, rejected => Rejected,
      principal => principal_text(quod_node_actor:principal())}.

diagnose_enrollment() ->
    #{client_auth => is_pid(whereis(quod_client_auth)),
      client_goal_router => is_pid(whereis(quod_client_goal_router)),
      network_identity => availability(quod_ontology:network_identity()),
      node_state => term_text(quod_ontology:local_state(<<"quod:node">>)),
      catalog => term_text(quod_system_ontology:catalog()),
      enrollment_parameters => term_text(quod_prolog:prove_ro(
          <<"quod:node">>, {node_enrollment_parameters, {'Window'}})),
      creation_policy => term_text(quod_prolog:prove_ro(
          <<"quod:root">>, {ontology_creation_policy, <<"quod:node">>, {'Anchor'}})),
      actor_bootstrap => bootstrap_class(quod_node_actor:bootstrap()),
      manager => quod_namespace_manager:stats()}.

enrollment_evidence() ->
    #{node_enrollment := complete} = Stats = quod_namespace_manager:stats(),
    {ok, {agent, Blob} = Principal} = quod_node_actor:principal(),
    {ok, Dir} = application:get_env(quod, identity_dir),
    {ok, Blob} = quod_identity:load_node_actor_pointer(Dir),
    {ok, #{identity := {Ns, Anchor}, reference := Ref}} = quod_agent_ref:decode(Blob),
    {ok, [_], Height} = quod_prolog:prove_ro(
        Ns, {hosts_ontology, Ref, Ns, Anchor, discoverable}),
    {ok, Ref} = quod_agent_ref:materialize_principal(Principal),
    #{manager => Stats, pointer => stored, self_hosting => committed,
      node_namespace => Ns, node_anchor => binary:encode_hex(Anchor),
      hosting_height => Height}.

delegate_signup(SignupAnchor)
  when is_binary(SignupAnchor), byte_size(SignupAnchor) =:= 32 ->
    SignupAnchor = quod_simplex:genesis_hash(<<"quod:signup">>),
    {ok, Principal} = quod_node_actor:principal(),
    {ok, {agent_instance_ref, NodeNs, _, _}} =
        quod_agent_ref:materialize_principal(Principal),
    Delegated = case exact_rows(NodeNs, ontology_hosting_policy, <<"quod:signup">>) of
        [] ->
            {ok, [_], _} = quod_prolog:execute(NodeNs,
                {transaction, {assertz, {ontology_hosting_policy,
                                         <<"quod:signup">>, SignupAnchor}}}),
            committed;
        [SignupAnchor] -> already_committed;
        Other -> error({conflicting_signup_hosting_policy, Other})
    end,
    #{delegated => Delegated, node_namespace => NodeNs,
      signup_anchor => binary:encode_hex(SignupAnchor)}.

final_gate() ->
    Expected = lists:sort([<<"quod:", Name/binary>> || Name <- [
        <<"agent">>, <<"environment">>, <<"environment:eidolons">>, <<"gui">>,
        <<"human_user">>, <<"lens">>, <<"licence">>, <<"lobby">>,
        <<"material">>, <<"material:eidolons">>, <<"measure">>, <<"modelling">>,
        <<"names">>, <<"node">>, <<"prolog">>, <<"prolog:eidolons">>,
        <<"rendering">>, <<"signup">>]]),
    {ok, Height, Descriptors, Rejected} = quod_system_ontology:catalog(),
    0 = map_size(Rejected),
    Expected = lists:sort([Ns || #{namespace := Ns} <- Descriptors]),
    [] = [{Ns, State} || #{namespace := Ns} <- Descriptors,
                         State <- [quod_ontology:local_state(Ns)],
                         State =/= {ok,ready}],
    Profiles = maps:from_list([{Ns,verify_modules(Name)} || <<"quod:",Name/binary>> = Ns <- Expected]),
    Enrollment = enrollment_evidence(),
    #{height => Height, system_ontologies => length(Descriptors),
      rejected => 0, all_ready => true, module_profiles => Profiles, enrollment => Enrollment}.

policy_state(Ns, Anchor) ->
    case exact_rows(<<"quod:root">>, ontology_creation_policy, Ns) of
        [] -> missing;
        [Anchor] -> present;
        Other -> error({conflicting_creation_policy, Ns, Other})
    end.

exact_rows(Ontology, Predicate, Namespace) ->
    Value = {'Value'}, Rows = {'Rows'},
    Goal = {findall, Value, {Predicate, Namespace, Value}, Rows},
    {ok, [#{'Rows' := Result}], _} = quod_prolog:prove_ro(Ontology, Goal),
    Result.

availability({ok, _}) -> available;
availability(Other) -> term_text(Other).

bootstrap_class(none) -> none;
bootstrap_class({pending, none}) -> pending_without_reference;
bootstrap_class({pending, _}) -> pending_with_reference;
bootstrap_class({ok, _, _}) -> ready;
bootstrap_class({error, Reason}) -> term_text({error, Reason}).

term_text(Term) -> iolist_to_binary(io_lib:format("~0p", [Term])).

source(<<"agent">>) -> {<<"quod:agent">>, "quod_agent.pl"};
source(<<"environment">>) -> {<<"quod:environment">>, "quod_environment.pl"};
source(<<"environment:eidolons">>) -> {<<"quod:environment:eidolons">>, "quod_environment_eidolons.pl"};
source(<<"gui">>) -> {<<"quod:gui">>, "quod_gui.pl"};
source(<<"human_user">>) -> {<<"quod:human_user">>, "quod_human_user.pl"};
source(<<"lens">>) -> {<<"quod:lens">>, "quod_lens.pl"};
source(<<"licence">>) -> {<<"quod:licence">>, "quod_licence.pl"};
source(<<"lobby">>) -> {<<"quod:lobby">>, "quod_lobby.pl"};
source(<<"material">>) -> {<<"quod:material">>, "quod_material.pl"};
source(<<"material:eidolons">>) -> {<<"quod:material:eidolons">>, "quod_material_eidolons.pl"};
source(<<"measure">>) -> {<<"quod:measure">>, "quod_measure.pl"};
source(<<"modelling">>) -> {<<"quod:modelling">>, "quod_modelling.pl"};
source(<<"names">>) -> {<<"quod:names">>, "quod_names.pl"};
source(<<"node">>) -> {<<"quod:node">>, "quod_node.pl"};
source(<<"prolog">>) -> {<<"quod:prolog">>, "quod_prolog.pl"};
source(<<"prolog:eidolons">>) -> {<<"quod:prolog:eidolons">>, "quod_prolog_eidolons.pl"};
source(<<"rendering">>) -> {<<"quod:rendering">>, "quod_rendering.pl"};
source(<<"signup">>) -> {<<"quod:signup">>, "quod_signup.pl"}.

terms(<<"lobby">>, Dependencies) ->
    Sources = [{lobby_source_file, list_to_binary(path(File))}
        || File <- ["lobby_instance.pl", "space.pl", "agent_instance.pl",
                    "quod_physics.pl", "space_view.pl", "voxel_world.pl", "voxel_world_view.pl",
                    "gui_instance.pl", "gui_question.pl", "voxel_world_gui.pl", "lobby_worlds.pl"]],
    Sources ++ Dependencies;
terms(<<"signup">>, Dependencies) ->
    Sources = [{user_source_file, list_to_binary(path(File))}
        || File <- ["human_user_instance.pl", "gui_hud.pl"]],
    {ok, Principal} = quod_node_actor:principal(),
    {ok, Node} = quod_agent_ref:materialize_principal(Principal),
    Sources ++ [{signup_host, Node} | Dependencies];
terms(<<"node">>, Dependencies) ->
    {ok, Template} = file:read_file(path("node_execution.pl")),
    [{node_identity_template, Template} | Dependencies];
terms(_, Dependencies) when is_list(Dependencies) -> Dependencies.

ready(Ns, Timeout) ->
    true = quod_reg:subscribe({runtime, Ns}),
    try await_ready(Ns, quod_time:mono_ms() + Timeout)
    after quod_reg:unsubscribe({runtime, Ns}) end.

await_ready(Ns, Deadline) ->
    case quod_ontology:local_state(Ns) of
        {ok, ready} -> ok;
        Other ->
            receive _ -> await_ready(Ns, Deadline)
            after max(0, Deadline - quod_time:mono_ms()) ->
                error({readiness_timeout, Ns, Other})
            end
    end.

await_principal(Deadline) ->
    case quod_node_actor:principal() of
        {ok, Principal} ->
            {ok, Ref} = quod_agent_ref:materialize_principal(Principal),
            #{principal => iolist_to_binary(io_lib:format("~p", [Ref]))};
        _ ->
            receive _ -> await_principal(Deadline)
            after max(0, Deadline - quod_time:mono_ms()) ->
                error(node_principal_timeout)
            end
    end.

principal_text({ok, Principal}) ->
    {ok, Ref} = quod_agent_ref:materialize_principal(Principal),
    iolist_to_binary(io_lib:format("~p", [Ref]));
principal_text(_) -> unavailable.

conjunction([Goal]) -> Goal;
conjunction([Goal | Rest]) -> {',', Goal, conjunction(Rest)}.
path(File) -> filename:join(["/opt/quod/priv", "ontologies", File]).

-module(quod_node_actor_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_proof_limits.hrl").

creation_options_are_ordinary_ontology_content_test() ->
    Namespace = <<"node:alpha">>,
    PublicKey = <<7:256>>,
    {ok, [{terms, Terms}, {source, Policy},
          {external_predicate_modules, [quod_ontology_predicates]}]} =
        quod_node_actor:creation_options(
          Namespace, <<"physical_node(alpha).">>, 2, PublicKey),
    ?assert(lists:member(
              {instance_of, node, {physical_node, alpha}}, Terms)),
    ?assert(lists:member(
              {agent_key, {physical_node, alpha}, PublicKey, active}, Terms)),
    ?assert(is_binary(Policy)),
    {ok, PolicyTerms} = erlog_io:read_string_terms(binary_to_list(Policy)),
    ?assert(lists:any(fun is_node_acl/1, PolicyTerms)),
    ?assert(lists:any(fun is_hosting_handler/1, PolicyTerms)).

node_actor_creation_goal_fits_the_shared_proof_bounds_test() ->
    Namespace = <<"quod:node-actor-0">>,
    {ok, Options} = quod_node_actor:creation_options(
                      Namespace, <<"physical_node(node_0).">>, 2, <<7:256>>),
    Goal = {create_ontology, Namespace, Options, {'Anchor'}},
    {ok, GoalBytes} = quod_wire_term:encode_canonical(Goal),
    ?assert(byte_size(GoalBytes) =< ?QUOD_MAX_NESTED_GOAL_BYTES),
    ?assertMatch({ok, _}, quod_durable_term:encode_goal(Goal)).

creation_options_reject_variables_test() ->
    ?assertEqual(
       {error, invalid_node_instance},
       quod_node_actor:creation_options(
         <<"node:bad">>, <<"physical_node(X).">>, 2, <<1:256>>)).

reference_is_the_common_agent_reference_test() ->
    Ns = <<"node:alpha">>,
    Anchor = <<2:256>>,
    {ok, Blob} = quod_node_actor:reference(
                   Ns, Anchor, <<"physical_node(alpha).">>, 2),
    ?assertMatch(
       {ok, #{identity := {Ns, Anchor},
              instance := {physical_node, alpha}}},
       quod_agent_ref:decode(Blob)).

reconcile_errors_use_a_closed_fatal_identity_set_test() ->
    ?assertEqual(
       pending,
       quod_namespace_manager:test_node_actor_result_class({error, busy})),
    ?assertEqual(
       pending,
       quod_namespace_manager:test_node_actor_result_class(
         {error, {ontology_unavailable, <<"node:alpha">>}})),
    ?assertEqual(
       {fatal, node_actor_anchor_mismatch},
       quod_namespace_manager:test_node_actor_result_class(
         {error, node_actor_anchor_mismatch})).

hosted_runtime_is_not_publishable_before_replay_ready_test() ->
    Anchor = <<8:256>>,
    ?assertNot(
       quod_namespace_manager:test_content_runtime_ready(
         {ok, Anchor}, #{role => validator, recovery => pulling})),
    ?assertNot(
       quod_namespace_manager:test_content_runtime_ready(
         {ok, Anchor}, #{role => joining, recovery => ready})),
    ?assertNot(
       quod_namespace_manager:test_content_runtime_ready(
         {error, genesis_mismatch},
         #{role => validator, recovery => ready})),
    ?assert(
       quod_namespace_manager:test_content_runtime_ready(
         {ok, Anchor}, #{role => validator, recovery => ready})),
    ?assert(
       quod_namespace_manager:test_content_runtime_ready(
         {ok, Anchor}, #{role => observer, recovery => ready})).

hosting_projection_rejects_ambiguous_visibility_test() ->
    NodeRef = node_ref(<<1:256>>),
    Anchor = <<2:256>>,
    ?assertEqual(
       {error, {conflicting_hosting_fact, <<"private:target">>}},
       quod_node_actor:test_normalize_projection(
         NodeRef,
         [{host, NodeRef, <<"private:target">>, Anchor, private},
          {host, NodeRef, <<"private:target">>, Anchor, discoverable}],
         [])).

hosting_projection_rejects_wrong_node_and_conflicting_anchor_test() ->
    NodeRef = node_ref(<<1:256>>),
    OtherRef = node_ref(<<2:256>>),
    Ns = <<"private:target">>,
    ?assertEqual(
       {error, malformed_node_hosting_projection},
       quod_node_actor:test_normalize_projection(
         NodeRef, [{host, OtherRef, Ns, <<3:256>>, private}], [])),
    ?assertEqual(
       {error, {conflicting_hosting_fact, Ns}},
       quod_node_actor:test_normalize_projection(
         NodeRef,
         [{host, NodeRef, Ns, <<3:256>>, private},
          {host, NodeRef, Ns, <<4:256>>, private}], [])).

private_contact_is_bound_to_its_exact_target_and_host_test() ->
    NodeRef = node_ref(<<1:256>>),
    HostRef = node_ref(<<2:256>>),
    Ns = <<"private:target">>,
    Anchor = <<3:256>>,
    ?assertMatch(
       {ok, #{hosts := #{}, contacts :=
                  #{{Ns, HostRef} :=
                        #{namespace := Ns, anchor := Anchor,
                          host_node_ref := HostRef}}}},
       quod_node_actor:test_normalize_projection(
         NodeRef, [], [{contact, NodeRef, Ns, Anchor, HostRef}])).

root_and_system_identity_outrank_conflicting_node_projection_test() ->
    Ns = <<"quod:system">>,
    Strong = #{Ns => #{genesis_hash => <<1:256>>}},
    Equal = #{Ns => #{genesis_hash => <<1:256>>, hosting_visibility => private}},
    Conflict = #{Ns => #{genesis_hash => <<2:256>>}},
    ?assertEqual(ok,
                 quod_namespace_manager:test_projection_conflicts(
                   Strong, #{}, Equal)),
    ?assertEqual(
       {error, {node_host_anchor_conflict, Ns}},
       quod_namespace_manager:test_projection_conflicts(
         Strong, #{}, Conflict)).

system_projection_rejects_an_earlier_conflicting_node_row_test() ->
    Ns = <<"quod:system">>,
    NodeConfig = #{genesis_hash => <<2:256>>},
    SystemConfig = #{genesis_hash => <<1:256>>, system_ontology => true},
    {Desired, Node, Retired, Conflict} =
        quod_namespace_manager:test_install_system_projection(
          #{}, #{Ns => SystemConfig}, #{Ns => NodeConfig}, #{}),
    ?assertEqual(#{Ns => SystemConfig}, Desired),
    ?assertEqual(#{}, Node),
    ?assertEqual(#{}, Retired),
    ?assertEqual({node_host_anchor_conflict, Ns}, Conflict).

removed_system_projection_becomes_retired_test() ->
    Ns = <<"quod:removed-system">>,
    Config = #{genesis_hash => <<3:256>>, system_ontology => true},
    {Desired, Node, Retired, Conflict} =
        quod_namespace_manager:test_install_system_projection(
          #{}, #{}, #{}, #{Ns => Config}),
    ?assertEqual(#{}, Desired),
    ?assertEqual(#{}, Node),
    ?assertEqual(#{Ns => Config}, Retired),
    ?assertEqual(none, Conflict).

removed_system_projection_does_not_flap_an_equal_node_host_test() ->
    Ns = <<"quod:shared-system">>,
    Config = #{genesis_hash => <<4:256>>},
    {Desired, _Node, Retired, none} =
        quod_namespace_manager:test_install_system_projection(
          #{}, #{}, #{Ns => Config},
          #{Ns => Config#{system_ontology => true}}),
    ?assertEqual([], quod_namespace_manager:test_retired_names(
                       Retired, #{Ns => self()}, Desired)).

node_ref(Key) ->
    {agent_instance_ref, <<"node:test">>, <<9:256>>,
     {physical_node, Key}}.

is_node_acl(
  {':-',
   {can_invoke, _,
    {agent_instance_ref, <<"node:alpha">>, _, {'Agent'}},
    _, <<"node:alpha">>},
   {instance_of, node, {'Agent'}}}) -> true;
is_node_acl(_) -> false.

is_hosting_handler(
  {state_handler, node_ontology_hosting,
   [{'/', hosts_ontology, 4}, {'/', knows_ontology_host, 4}], [],
   reconcile_node_ontology_hosting}) -> true;
is_hosting_handler(_) -> false.

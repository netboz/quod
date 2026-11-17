-module(quod_node_actor_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_proof_limits.hrl").

only_winning_terminal_negative_outcome_releases_custody_test() ->
    {Key, _} = Pair = quod_identity:generate(),
    {ok, Instance} = quod_client_goal_parser:format({enrolling, Key}),
    {ok, Bytes} = quod_client_goal:encode(#{network_identity => <<1:256>>,
        signing_public_key => Key, operation_id => crypto:strong_rand_bytes(32),
        agent_namespace => <<"quod:node">>, agent_genesis_anchor => <<2:256>>,
        agent_instance_text => Instance, mode => execute, parser_version => 3,
        not_after_ms => quod_time:now_ms() + 30000, goal_text => <<"enroll_node(Ref).">>}),
    Sig = quod_identity:sign(Bytes, quod_identity:key_term(Pair)),
    Dir = filename:join("/tmp", "quod-negative-enrollment-" ++
                        integer_to_list(erlang:unique_integer([positive]))),
    try
        ok = quod_identity:begin_node_enrollment(Dir, Bytes, Sig),
        {ok, Before} = file:read_file_info(filename:join(Dir, "node.actor")),
        %% These are trusted resolver result shapes, not forged certificate
        %% acceptance tests. The ingress suite covers exact claim binding.
        [begin
            ?assertEqual(unresolved, quod_node_actor:test_resolved_retained(
                Dir, enrollment, Bytes, Sig, Resolution)),
            ?assertEqual({ok, Before}, file:read_file_info(filename:join(Dir, "node.actor")))
         end || Resolution <- [
            {error, expired}, {error, operation_conflict},
            {ok, #{}, {operation_pending, pending}},
            {ok, #{}, {group_outcome, refused_attempt, #{status => aborted, height => 3}}},
            {ok, #{}, {operation_outcome, claimed, #{status => rejected, reason => operator_error}}},
            {ok, #{}, {operation_outcome, claimed, #{status => committed, height => 3}}}]],
        [?assertMatch({refused, {<<"quod:node">>, <<2:256>>}},
            quod_node_actor:test_resolved_retained(Dir, enrollment, Bytes, Sig,
                {ok, #{}, {operation_outcome, claimed, #{status => Status, height => 3}}}))
         || Status <- [rejected, aborted]],
        ?assertMatch({pending, #{rejected := enrollment}},
                     quod_identity:load_node_actor_pointer(Dir))
    after _ = file:del_dir_r(Dir) end.

node_identity_template_provides_protected_methods_test() ->
    {ok, Policy} = file:read_file(filename:join(code:priv_dir(quod), "ontologies/node_instance.pl")),
    {ok, PolicyTerms} = erlog_io:read_string_terms(binary_to_list(Policy)),
    ?assert(lists:any(fun is_node_acl/1, PolicyTerms)),
    ?assert(lists:any(fun is_hosting_projection/1, PolicyTerms)),
    ?assert(lists:any(fun is_recovery_reaction/1, PolicyTerms)).

node_reference_rejects_variables_test() ->
    ?assertEqual({error, invalid_agent_reference},
        quod_node_actor:reference(<<"node:bad">>, <<1:256>>, <<"physical_node(X).">>, 2)).

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
         {ok, Anchor}, #{role => joining, recovery => ready, prolog_ready => true})),
    ?assertNot(
       quod_namespace_manager:test_content_runtime_ready(
         {error, genesis_mismatch},
         #{role => validator, recovery => ready, prolog_ready => true})),
    ?assertNot(
       quod_namespace_manager:test_content_runtime_ready(
         {ok, Anchor}, #{role => validator, recovery => ready, prolog_ready => false})),
    ?assert(
       quod_namespace_manager:test_content_runtime_ready(
         {ok, Anchor}, #{role => validator, recovery => ready, prolog_ready => true})),
    ?assert(
       quod_namespace_manager:test_content_runtime_ready(
         {ok, Anchor}, #{role => observer, recovery => ready, prolog_ready => true})).

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
   {can_invoke, _, {'Principal'}, _, {'Namespace'}},
   {',', {node_ontology, {'Namespace'}},
         {node_instance_reference, {'Principal'}}}}) -> true;
is_node_acl(_) -> false.

is_hosting_projection(
  {':-', {node_ontology_hosting_projection, _, _}, _}) -> true;
is_hosting_projection(_) -> false.

is_recovery_reaction(
  {':-', {react_on, {observed,
    {agent_recovery_ready, _, _, _, _, _, _, _, _, _}}, _}, _}) -> true;
is_recovery_reaction(_) -> false.

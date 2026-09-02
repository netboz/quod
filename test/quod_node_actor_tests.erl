-module(quod_node_actor_tests).
-include_lib("eunit/include/eunit.hrl").

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
    {ok, [PolicyTerm]} = erlog_io:read_string_terms(Policy),
    ?assert(is_node_acl(PolicyTerm)).

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

is_node_acl(
  {':-',
   {can_invoke, _,
    {agent_instance_ref, <<"node:alpha">>, _, {'Agent'}},
    _, <<"node:alpha">>},
   {instance_of, node, {'Agent'}}}) -> true;
is_node_acl(_) -> false.

-module(quod_directory_generation_tests).

-include_lib("eunit/include/eunit.hrl").

signed_page_roundtrip_and_tamper_rejection_test() ->
    {Pub, Seed} = quod_identity:generate(),
    Signer = quod_identity:key_term({Pub, Seed}),
    Author = node_author(1),
    Hosted = [{<<"quod:a">>, anchor(2), validator, node},
              {<<"quod:b">>, anchor(3), observer, node}],
    {ok, Encoded} = quod_directory_generation:sign(
                      Author, Pub, {<<"node">>, 4555}, 7, 11, 2, true,
                      Hosted, Signer),
    {ok, Page} = quod_directory_generation:decode(Encoded),
    ?assertEqual(Author, quod_directory_generation:author(Page)),
    ?assertEqual(11, quod_directory_generation:generation(Page)),
    ?assertEqual(2, quod_directory_generation:page(Page)),
    ?assert(quod_directory_generation:last(Page)),
    ?assertEqual(Hosted, quod_directory_generation:hosted(Page)),
    LastByte = byte_size(Encoded) - 1,
    <<Prefix:LastByte/binary, Byte>> = Encoded,
    ?assertMatch({error, _}, quod_directory_generation:decode(
                              <<Prefix/binary, (Byte bxor 1)>>)).

page_has_no_ontology_population_cap_test() ->
    {Pub, Seed} = quod_identity:generate(),
    Signer = quod_identity:key_term({Pub, Seed}),
    %% This exceeds the deleted complete-record population limit.  The codec
    %% accepts whatever fits in one bounded page; further rows use more pages.
    Hosted = [{<<"n", N:16>>, anchor(N), validator, node}
              || N <- lists:seq(1, 64)],
    ?assertMatch(
       {ok, _},
       quod_directory_generation:sign(
         node_author(4), Pub, {<<"node">>, 4556}, 1, 1, 0, true,
         Hosted, Signer)).

large_generation_is_split_without_a_population_cap_test() ->
    {Pub, Seed} = quod_identity:generate(),
    Signer = quod_identity:key_term({Pub, Seed}),
    Hosted = [{<<"namespace-", N:32>>, anchor(N), validator, node}
              || N <- lists:seq(1, 1200)],
    {ok, EncodedPages} = quod_directory_generation:sign_generation(
                           node_author(44), Pub, {<<"node">>, 4556}, 1, 2,
                           Hosted, Signer),
    ?assert(length(EncodedPages) > 1),
    Pages = [begin {ok, Page} = quod_directory_generation:decode(Encoded), Page end
             || Encoded <- EncodedPages],
    Result = lists:foldl(
               fun(Page, undefined) ->
                       {pending, Assembly} =
                           quod_directory_generation:assemble(Page, undefined),
                       Assembly;
                  (Page, Assembly) ->
                       case quod_directory_generation:assemble(Page, Assembly) of
                           {pending, Next} -> Next;
                           {complete, Complete} -> {complete, Complete}
                       end
               end, undefined, Pages),
    {complete, Complete} = Result,
    ?assertEqual(Hosted, quod_directory_generation:hosted(Complete)).

noncanonical_and_wrong_author_pages_fail_closed_test() ->
    {Pub, Seed} = quod_identity:generate(),
    Signer = quod_identity:key_term({Pub, Seed}),
    ?assertEqual(
       {error, bad_generation},
       quod_directory_generation:sign(
         {node_actor, <<"not-an-agent-reference">>}, Pub,
         {<<"node">>, 4557}, 1, 1, 0, true, [], Signer)),
    ?assertEqual(
       {error, bad_generation},
       quod_directory_generation:sign(
         node_author(5), Pub, {<<"node">>, 4557}, 1, 1, 0, true,
         [{<<"b">>, anchor(1), validator, node},
          {<<"a">>, anchor(2), validator, node}], Signer)).

generation_is_invisible_until_every_page_is_present_test() ->
    {Pub, Seed} = quod_identity:generate(),
    Signer = quod_identity:key_term({Pub, Seed}),
    Author = node_author(6),
    P0 = page(Author, Pub, Signer, 3, 8, 0, false,
              [{<<"a">>, anchor(1), validator, node}]),
    P1 = page(Author, Pub, Signer, 3, 8, 1, true,
              [{<<"b">>, anchor(2), observer, node}]),
    {pending, A1} = quod_directory_generation:assemble(P1, undefined),
    {complete, Complete} = quod_directory_generation:assemble(P0, A1),
    ?assertEqual([{<<"a">>, anchor(1), validator, node},
                  {<<"b">>, anchor(2), observer, node}],
                 quod_directory_generation:hosted(Complete)).

newer_generation_discards_an_incomplete_older_one_test() ->
    {Pub, Seed} = quod_identity:generate(),
    Signer = quod_identity:key_term({Pub, Seed}),
    Author = node_author(7),
    Old = page(Author, Pub, Signer, 4, 9, 0, false,
               [{<<"a">>, anchor(1), validator, node}]),
    New0 = page(Author, Pub, Signer, 4, 10, 0, false,
               [{<<"b">>, anchor(2), validator, node}]),
    New1 = page(Author, Pub, Signer, 4, 10, 1, true, []),
    {pending, A1} = quod_directory_generation:assemble(Old, undefined),
    {pending, A2} = quod_directory_generation:assemble(New0, A1),
    ?assertEqual({error, stale_generation},
                 quod_directory_generation:assemble(Old, A2)),
    {complete, Complete} = quod_directory_generation:assemble(New1, A2),
    ?assertEqual([{<<"b">>, anchor(2), validator, node}],
                 quod_directory_generation:hosted(Complete)).

duplicate_or_cross_page_namespace_cannot_change_a_generation_test() ->
    {Pub, Seed} = quod_identity:generate(),
    Signer = quod_identity:key_term({Pub, Seed}),
    Author = node_author(8),
    P0 = page(Author, Pub, Signer, 5, 11, 0, false,
              [{<<"a">>, anchor(1), validator, node}]),
    P1 = page(Author, Pub, Signer, 5, 11, 1, true,
              [{<<"a">>, anchor(1), validator, node}]),
    {pending, A1} = quod_directory_generation:assemble(P0, undefined),
    ?assertEqual({pending, A1}, quod_directory_generation:assemble(P0, A1)),
    ?assertEqual({error, bad_generation},
                 quod_directory_generation:assemble(P1, A1)).

node_generation_requires_the_exact_active_key_and_host_facts_test() ->
    {Pub, Seed} = quod_identity:generate(),
    Signer = quod_identity:key_term({Pub, Seed}),
    Author = node_author(9),
    {node_actor, Blob} = Author,
    {ok, #{instance := Instance, reference := NodeRef}} =
        quod_agent_ref:decode(Blob),
    Page = page(Author, Pub, Signer, 6, 12, 0, true,
                [{<<"quod:a">>, anchor(1), validator, node}]),
    Good = #{{agent_key, 3} =>
                 [{{agent_key, Instance, Pub, active}, {[], false}}],
             {hosts_ontology, 4} =>
                 [{{hosts_ontology, NodeRef, <<"quod:a">>, anchor(1),
                                    discoverable}, {[], false}}]},
    ?assertEqual(ok,
                 quod_directory_generation:validate_node_projection(
                   Page, Good)),
    ?assertEqual(
       {error, unauthorized_generation},
       quod_directory_generation:validate_node_projection(
         Page, Good#{{agent_key, 3} =>
                         [{{agent_key, Instance, anchor(55), active},
                           {[], false}}]})),
    ?assertEqual(
       {error, unauthorized_generation},
       quod_directory_generation:validate_node_projection(
         Page, Good#{{hosts_ontology, 4} => []})).

descriptor_sources_are_checked_by_their_committed_owner_test() ->
    {Pub, Seed} = quod_identity:generate(),
    Signer = quod_identity:key_term({Pub, Seed}),
    RootAnchor = anchor(70), SystemAnchor = anchor(71),
    RootPage = page(
                 {root_bootstrap, RootAnchor, Pub}, Pub, Signer, 1, 1, 0, true,
                 [{<<"quod:root">>, RootAnchor, validator, bootstrap},
                  {<<"quod:system">>, SystemAnchor, validator, system}]),
    Catalog = [{<<"quod:system">>, SystemAnchor}],
    ?assertEqual(ok, quod_directory_generation:validate_projection(
                       RootPage, #{}, Catalog)),
    ?assertEqual(
       {error, unauthorized_generation},
       quod_directory_generation:validate_projection(RootPage, #{}, [])),
    NodePage = page(node_author(72), Pub, Signer, 1, 1, 0, true,
                    [{<<"quod:root">>, RootAnchor, validator, bootstrap}]),
    ?assertEqual(
       {error, unauthorized_generation},
       quod_directory_generation:validate_projection(NodePage, #{}, Catalog)),
    NodeSystemPage = page(
                       node_author(73), Pub, Signer, 1, 1, 0, true,
                       [{<<"quod:system">>, SystemAnchor, validator, system}]),
    ?assertEqual(
       {error, unauthorized_generation},
       quod_directory_generation:validate_projection(
         NodeSystemPage, #{}, Catalog)).

page(Author, Pub, Signer, Epoch, Generation, Index, Last, Hosted) ->
    {ok, Encoded} = quod_directory_generation:sign(
                      Author, Pub, {<<"node">>, 4558}, Epoch, Generation,
                      Index, Last, Hosted, Signer),
    {ok, Page} = quod_directory_generation:decode(Encoded),
    Page.

node_author(N) ->
    Ref = {agent_instance_ref, <<"quod:node">>, anchor(99),
           {node, <<N:32>>}},
    {ok, Blob} = quod_wire_term:encode_canonical(Ref),
    {node_actor, Blob}.

anchor(N) -> <<N:256>>.

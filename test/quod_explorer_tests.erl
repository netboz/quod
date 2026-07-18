-module(quod_explorer_tests).
-moduledoc false.
%% The explorer's pure surface: Prolog display rendering, transaction JSON, goal parsing,
%% and history paging over a real (temp-dir) ledger store. The listener/WS processes are
%% exercised live — they are thin cowboy glue over these functions.
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

%%%===================================================================
%%% prolog_text — display rendering
%%%===================================================================

render(T) -> unicode:characters_to_list(quod_explorer_http:prolog_text(T)).

render_plain_goal_test() ->
    ?assertEqual("capital(france, X)",
                 render({capital, france, {'X'}})).

render_colon_name_test() ->
    %% `:` names read as one token; other operators breathe.
    ?assertEqual("have_attribute(quod:animal, diet, X)",
                 render({have_attribute, {':', quod, animal}, diet, {'X'}})).

render_ask_test() ->
    ?assertEqual("animals::diet(dog, D)",
                 render({'::', animals, {diet, dog, {'D'}}})).

render_conjunction_test() ->
    ?assertEqual("assertz(capital(france, paris)), animals::diet(dog, D)",
                 render({',', {assertz, {capital, france, paris}},
                               {'::', animals, {diet, dog, {'D'}}}})).

render_string_test() ->
    %% A printable charlist is a Prolog string, not a byte list.
    ?assertEqual("peer_ready(\"10.0.0.1\", 14567)",
                 render({peer_ready, "10.0.0.1", 14567})).

render_pubkey_test() ->
    %% A 32-byte binary is an Ed25519 pubkey by convention — its short id, not 32 bytes.
    Pk = <<7:256>>,
    Expected = unicode:characters_to_list(quod_identity:short(Pk)),
    ?assertEqual("peer_admitted(" ++ Expected ++ ", x)",
                 render({peer_admitted, Pk, x})).

render_binary_test() ->
    ?assertEqual("f(<<\"hello\">>)", render({f, <<"hello">>})),
    ?assertEqual("f(<<0x0102>>)", render({f, <<1, 2>>})).

render_binary_escape_test() ->
    %% a printable binary carrying a quote/backslash must be escaped, like the charlist branch,
    %% so the display text is never malformed
    ?assertEqual("f(<<\"a\\\"b\\\\c\">>)", render({f, <<"a\"b\\c">>})).

render_list_and_var_test() ->
    ?assertEqual("member(X, [a, \"b c\", 3])",
                 render({member, {'X'}, [a, "b c", 3]})),
    ?assertEqual("f(_1)", render({f, {1}})).

render_quoted_atom_test() ->
    ?assertEqual("isa('My Dog', dog)", render({isa, 'My Dog', dog})).

%%%===================================================================
%%% parse_goal — the console's input path
%%%===================================================================

parse_goal_test() ->
    ?assertEqual({ok, {capital, france, {'X'}}},
                 quod_explorer_http:parse_goal(<<"capital(france, X)">>)),
    %% with or without the closing dot
    ?assertEqual({ok, {capital, france, {'X'}}},
                 quod_explorer_http:parse_goal(<<"capital(france, X).">>)),
    ?assertMatch({error, _}, quod_explorer_http:parse_goal(<<"capital(france">>)).

%%%===================================================================
%%% tx JSON + history paging over a real store
%%%===================================================================

tx(N) ->
    #transaction{tx_id = <<N:64>>, caller_ns = <<"ont:test">>,
                 goal = {assertz, {fact, N}}, result = #{},
                 diff = [{assert, {{fact, N}, true}}], read_check = #{},
                 author = <<N:256>>, submitted_at = 1000 + N, sig = none}.

entry(Slot, Txs) ->
    #entry{index = Slot, data = {batch, Txs}, timestamp = 2000 + Slot, cert = none}.

with_temp_store(Fun) ->
    Dir = filename:join("/tmp", "quod_explorer_eunit_" ++
                        integer_to_list(erlang:unique_integer([positive]))),
    {ok, Store0} = quod_ledger_store:open(<<"ont:test">>, Dir),
    try Fun(Store0) after file:del_dir_r(Dir) end.

paging_test() ->
    with_temp_store(fun(Store0) ->
        Entries = [entry(S, [tx(S * 10), tx(S * 10 + 1)]) || S <- lists:seq(1, 5)],
        {ok, Store} = quod_ledger_store:append(Store0, Entries),
        %% first page: newest first; the limit is block-granular (a block's transactions are
        %% never split across pages, so `next_before` stays a plain slot), hence 4 rows for 3
        #{txs := Page1, height := 5, next_before := Next} =
            quod_explorer_http:txs_page(Store, undefined, 3),
        ?assertEqual([5, 5, 4, 4], [maps:get(height, T) || T <- Page1]),
        ?assertEqual(4, Next),
        %% second page resumes below — slot 3 downward
        #{txs := Page2} = quod_explorer_http:txs_page(Store, Next, 100),
        ?assertEqual([3, 3, 2, 2, 1, 1], [maps:get(height, T) || T <- Page2]),
        %% the last page reports genesis reached
        ?assertMatch(#{next_before := null}, quod_explorer_http:txs_page(Store, Next, 100)),
        ok
    end).

find_tx_test() ->
    with_temp_store(fun(Store0) ->
        {ok, Store} = quod_ledger_store:append(
                          Store0, [entry(S, [tx(S)]) || S <- lists:seq(1, 4)]),
        WantId = quod_explorer_http:tx_id_text(<<3:64>>),
        ?assertMatch(#{tx := #{height := 3}, block := #{slot := 3}},
                     quod_explorer_http:find_tx(Store, WantId)),
        ?assertEqual(not_found, quod_explorer_http:find_tx(Store, <<"nope">>)),
        ok
    end).

tx_json_full_test() ->
    J = quod_explorer_http:tx_json_full(tx(7), entry(2, [tx(7)])),
    ?assertMatch(#{height := 2, time := 2002, ops := 1, read_predicates := 0,
                   ns := <<"ont:test">>, submitted_at := 1007}, J),
    ?assertEqual(<<"assertz(fact(7))">>, maps:get(goal, J)),
    ?assertEqual([#{op => assert, clause => <<"fact(7)">>}], maps:get(diff, J)),
    ?assertEqual(unsigned, maps:get(signature_status, J)),
    ?assertEqual(null, maps:get(signature, J)),
    %% the whole thing must be JSON-encodable
    ?assert(is_binary(quod_explorer_http:encode(J))).

signed_tx_json_test() ->
    {Pub, Seed} = quod_identity:generate(),
    Identity = #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})},
    T0 = (tx(8))#transaction{author = Pub},
    {ok, T} = quod_transaction:sign(<<"ont:test">>, T0, Identity),
    J = quod_explorer_http:tx_json_full(T, entry(2, [T])),
    ?assertEqual(verified, maps:get(signature_status, J)),
    ?assertEqual(128, byte_size(maps:get(signature, J))),
    ?assertEqual(genesis,
                 maps:get(signature_status,
                          quod_explorer_http:tx_json_full(tx(1), entry(1, [tx(1)])))).

compiled_clause_test() ->
    %% committed clauses carry erlog's COMPILED body `{Goals, HasCut}` — facts render head-only,
    %% rules with the familiar comma body (never the raw `{[],false}` internals)
    T = (tx(1))#transaction{diff = [{assert, {{fact, a}, {[], false}}},
                                    {retract, {{rule, {'X'}}, {[{peer_ready, {'X'}}], false}}}]},
    J = quod_explorer_http:tx_json_full(T, entry(1, [T])),
    ?assertEqual([#{op => assert, clause => <<"fact(a)">>},
                  #{op => retract, clause => <<"rule(X) :- peer_ready(X)">>}],
                 maps:get(diff, J)).

genesis_tx_id_test() ->
    %% genesis ids are readable text; live ids are raw bytes and hex out
    ?assertEqual(<<"genesis:ont:test">>, quod_explorer_http:tx_id_text(<<"genesis:ont:test">>)),
    ?assertEqual(<<"00000000000000ff">>, quod_explorer_http:tx_id_text(<<255:64>>)).

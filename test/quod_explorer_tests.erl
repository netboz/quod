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

outcome_unknown_is_pending_test() ->
    Ns = <<"quod:target">>,
    Anchor = <<7:256>>,
    TxId = <<8:256>>,
    ?assertEqual(
       {202, #{result => pending, ns => Ns,
               anchor => binary:encode_hex(Anchor, lowercase),
               tx_id => binary:encode_hex(TxId, lowercase)}},
       quod_explorer_http:prove_result(
         {error, {outcome_unknown,
                  {transaction, Ns, Anchor, TxId}}})).

group_commit_and_unknown_are_json_safe_test() ->
    Ns = <<"quod:origin">>,
    Anchor = <<31:256>>,
    Coordinator = <<32:256>>,
    Admission = <<33:256>>,
    GroupId = <<34:256>>,
    Ref = {group, Ns, Anchor, Coordinator, Admission, GroupId},
    Target = {<<"quod:target">>, <<35:256>>},
    {200, Committed} = quod_explorer_http:prove_result(
                         {ok, [#{'X' => linked}],
                          #{ref => Ref, height => 9,
                            participant_slots =>
                              [{{Ns, Anchor}, 8, 1},
                               {Target, 7, 2}]}}),
    ?assertEqual(ok, maps:get(result, Committed)),
    ?assertEqual(binary:encode_hex(GroupId, lowercase),
                 maps:get(group_id, Committed)),
    ?assertEqual(2, length(maps:get(participant_slots, Committed))),
    ?assert(is_binary(iolist_to_binary(json:encode(Committed)))),
    {202, Pending} = quod_explorer_http:prove_result(
                       {error, {outcome_unknown, Ref}}),
    ?assertEqual(pending, maps:get(result, Pending)),
    ?assertEqual(binary:encode_hex(Coordinator, lowercase),
                 maps:get(coordinator, Pending)).

invalid_action_is_a_bad_request_test() ->
    ?assertEqual(
       {400, #{error => invalid_action}},
       quod_explorer_http:prove_result({error, invalid_action})).

foreign_commit_is_json_safe_test() ->
    Ns = <<"quod:target">>,
    Anchor = <<12:256>>,
    TxId = <<13:256>>,
    Reply =
        {200, #{result => ok, bindings => [#{}], ns => Ns,
                anchor => binary:encode_hex(Anchor, lowercase),
                tx_id => binary:encode_hex(TxId, lowercase)}},
    ?assertEqual(
       Reply,
       quod_explorer_http:prove_result(
         {ok, [#{}], {transaction, Ns, Anchor, TxId}})),
    {200, JsonMap} = Reply,
    ?assert(is_binary(iolist_to_binary(json:encode(JsonMap)))).

transaction_id_parser_is_exact_test() ->
    TxId = <<9:256>>,
    ?assertEqual({ok, TxId}, quod_explorer_http:parse_tx_id(
                               binary:encode_hex(TxId, lowercase))),
    ?assertEqual({error, bad_tx_id},
                 quod_explorer_http:parse_tx_id(<<"printable-old-id">>)),
    ?assertEqual({error, bad_tx_id},
                 quod_explorer_http:parse_tx_id(binary:copy(<<"z">>, 64))).

outcome_json_test() ->
    Ns = <<"quod:target">>,
    Anchor = <<10:256>>,
    TxId = <<11:256>>,
    ?assertEqual(
       #{status => rejected, reason => conflict_retry, height => 73,
         ns => Ns, anchor => binary:encode_hex(Anchor, lowercase),
         tx_id => binary:encode_hex(TxId, lowercase)},
       quod_explorer_http:outcome_json(
         #{status => rejected, reason => conflict_retry, height => 73,
           ref => {transaction, Ns, Anchor, TxId}})).

compact_pending_outcome_json_test() ->
    Ns = <<"quod:target">>,
    Anchor = <<14:256>>,
    TxId = <<15:256>>,
    ?assertEqual(
       #{status => pending, ns => Ns,
         anchor => binary:encode_hex(Anchor, lowercase),
         tx_id => binary:encode_hex(TxId, lowercase)},
       quod_explorer_http:outcome_json(
         #{status => pending,
           ref => {transaction, Ns, Anchor, TxId}})).

failure_reasons_are_rendered_test() ->
    ?assertEqual(
       {200, #{result => fail,
               reasons => [<<"outer(bob)">>, <<"missing(bob)">>]}},
       quod_explorer_http:prove_result(
         {fail, [{outer, bob}, {missing, bob}]})).

%%%===================================================================
%%% summary committee observability
%%%===================================================================

committee_status_json_test() ->
    CommitteeId = crypto:hash(sha256, <<"committee-view">>),
    Fields = quod_explorer_http:committee_status_json(
               #{committee_id => CommitteeId}),
    ?assertEqual(
       #{committee_id => binary:encode_hex(CommitteeId, lowercase)},
       Fields),
    %% Assert the HTTP representation, not only the Erlang map.
    Decoded = json:decode(quod_explorer_http:encode(Fields)),
    ?assertMatch(<<_:64/binary>>, maps:get(<<"committee_id">>, Decoded)).

committee_status_invalid_values_fail_closed_test() ->
    ?assertEqual(
       #{committee_id => null},
       quod_explorer_http:committee_status_json(
         #{committee_id => <<"not-a-committee-id">>})),
    ?assertEqual(
       #{committee_id => null},
       quod_explorer_http:committee_status_json(#{})).

%%%===================================================================
%%% tx JSON + history paging over a real store
%%%===================================================================

tx(N) ->
    {ok, Goal} = quod_durable_term:encode_goal({assertz, {fact, N}}),
    {ok, Result} = quod_durable_term:encode_result(#{}),
    #transaction{tx_id = <<N:64>>, origin = {<<"ont:test">>, <<0:256>>},
                 goal = Goal, result = Result,
                 diff = [{assert, {{fact, N}, true}}], read_check = #{},
                 author = <<N:256>>, submitted_at = 1000 + N, sig = none}.

entry(Slot, Txs) ->
    #entry{index = Slot, data = {batch, Txs}, timestamp = 2000 + Slot, cert = none}.

stored_entry(Slot, Target, Txs) ->
    Signed = [signed_transaction(Target, Tx, {Slot, I})
              || {Tx, I} <- lists:zip(Txs, lists:seq(1, length(Txs)))],
    {ok, Entry} = quod_ledger:new_entry(
                    Slot, {batch, Signed}, 2000 + Slot, none),
    Entry.

signed_transaction({Ns, Anchor} = Target, Tx0, Salt) ->
    Seed = crypto:hash(sha256, term_to_binary({explorer_tx, Salt})),
    {Author, Seed} = crypto:generate_key(eddsa, ed25519, Seed),
    Signer = #{pubkey => Author,
               key => quod_identity:key_term({Author, Seed})},
    Tx = quod_transaction:bind_id(
           Target,
           Tx0#transaction{tx_id = <<>>, author = Author,
                           sig = none, signed_bytes = none}),
    {ok, Signed} = quod_transaction:sign(
                     {Ns, Anchor, Author}, Tx, Signer),
    Signed.

block_json_distinguishes_non_transaction_slots_test() ->
    Content = quod_explorer_http:block_json(<<"ont:test">>, entry(2, [tx(2)])),
    ?assertEqual(content, maps:get(kind, Content)),
    ?assertEqual(1, length(maps:get(txs, Content))),
    Noop = quod_explorer_http:block_json(
             <<"ont:test">>, #entry{index = 3, data = noop}),
    ?assertEqual(noop, maps:get(kind, Noop)),
    ?assertEqual([], maps:get(txs, Noop)),
    Invalid = quod_explorer_http:block_json(
                <<"ont:test">>, #entry{index = 4, data = {batch, []}}),
    ?assertEqual(invalid, maps:get(kind, Invalid)),
    ?assertEqual([], maps:get(txs, Invalid)),
    DtxEntry = #entry{index = 5, data = quod_ct:dtx_decision_payload()},
    Dtx = quod_explorer_http:block_json(<<"ont:test">>, DtxEntry),
    ?assertEqual(dtx_batch, maps:get(kind, Dtx)),
    ?assertEqual([], maps:get(txs, Dtx)),
    [Control] = maps:get(controls, Dtx),
    ?assertEqual(decision, maps:get(kind, Control)),
    ?assertEqual(abort, maps:get(verdict, Control)),
    ?assertEqual([<<"test_abort(dtx_fixture)">>], maps:get(reasons, Control)),
    ?assert(is_binary(quod_explorer_http:encode(Dtx))),
    ?assertEqual([], quod_explorer_http:entry_txs(DtxEntry)),
    [ControlRow] = quod_explorer_http:entry_rows(<<"ont:test">>, DtxEntry),
    ?assertMatch(#{row_type := control, row_id := <<"dtx:", _/binary>>,
                   height := 5, phase := decision,
                   control := #{kind := decision}}, ControlRow).

dtx_control_is_visible_in_paged_history_test() ->
    with_temp_store(fun(Store0) ->
        {ok, DtxEntry} = quod_ledger:new_entry(
                           2, quod_ct:dtx_decision_payload(), 2002, none),
        {ok, Store} = quod_ledger_store:append(
                        Store0,
                        [stored_entry(
                           1, {<<"ont:test">>, <<0:256>>}, [tx(1)]),
                         DtxEntry]),
        #{txs := [Row, _Content], height := 2, next_before := null} =
            quod_explorer_http:txs_page(Store, undefined, 10),
        ?assertMatch(#{row_type := control, height := 2, phase := decision,
                       control := #{kind := decision}}, Row),
        ok
    end).

websocket_emits_dtx_phase_and_suppresses_non_blocks_test() ->
    Ns = <<"ont:test">>,
    DtxEntry = #entry{index = 5, data = quod_ct:dtx_decision_payload()},
    {reply, {text, Frame}, state} =
        quod_explorer_ws:websocket_info(
          {committed, Ns, 5, DtxEntry}, state),
    ?assertNotEqual(nomatch, binary:match(Frame, <<"decision">>)),
    ?assertEqual(
       {ok, state},
       quod_explorer_ws:websocket_info(
         {committed, Ns, 6, #entry{index = 6, data = noop}}, state)),
    ?assertEqual(
       {ok, state},
       quod_explorer_ws:websocket_info(
         {committed, Ns, 7,
          #entry{index = 7, data = {batch, []}}}, state)).

websocket_refreshes_namespace_subscriptions_without_reconnect_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"ont:dynamic:",
           (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    true = quod_reg:subscribe({namespace_topology, node}),
    try
        {reply, {text, SyncFrame}, State1} =
            quod_explorer_ws:websocket_info(
              {namespace_topology, [Ns]}, #{namespaces => []}),
        ?assertNotEqual(nomatch, binary:match(SyncFrame, <<"sync">>)),
        Marker = {dynamic_namespace_subscription, Ns},
        _ = quod_reg:publish({committed, Ns}, Marker),
        receive Marker -> ok after 1000 -> error(subscription_missing) end,

        {reply, {text, _}, State2} =
            quod_explorer_ws:websocket_info(
              {namespace_topology, []}, State1),
        _ = quod_reg:publish({committed, Ns}, Marker),
        receive Marker -> error(subscription_not_removed)
        after 0 -> ok
        end,
        ok = quod_explorer_ws:terminate(normal, ignored, State2)
    after
        %% `terminate/3` normally owns this; tolerate an assertion exit.
        _ = catch quod_reg:unsubscribe({committed, Ns}),
        _ = catch quod_reg:unsubscribe({runtime, Ns}),
        _ = catch quod_reg:unsubscribe({namespace_topology, node})
    end.

malformed_effect_renders_as_invalid_without_crashing_test() ->
    Ns = <<"ont:test">>,
    T0 = tx(91),
    T = T0#transaction{effects = [{malformed_effect, 1}]},
    E = #entry{index = 91, data = {batch, [T]}, timestamp = 91},
    Json = quod_explorer_http:tx_json_full(Ns, T, E),
    ?assertEqual([invalid], maps:get(effect_operations, Json)),
    [Effect] = maps:get(effects, Json),
    ?assertEqual(invalid, maps:get(operation, Effect)),
    ?assertEqual(unavailable, maps:get(local_execution, Effect)),
    ?assert(is_binary(quod_explorer_http:encode(Json))).

with_temp_store(Fun) ->
    with_temp_store(<<"ont:test">>, Fun).

with_temp_store(Ns, Fun) ->
    Dir = filename:join("/tmp", "quod_explorer_eunit_" ++
                        integer_to_list(erlang:unique_integer([positive]))),
    {ok, Store0} = quod_ledger_store:open(Ns, Dir),
    try Fun(Store0) after file:del_dir_r(Dir) end.

finalize_row_reuses_its_certified_prepare_plan_test() ->
    Fixture = quod_ct:dtx_prepare_fixture(),
    {Ns, Anchor} = Target = maps:get(target, Fixture),
    PrepareControl = maps:get(prepare_control, Fixture),
    {ok, PrepareRef} = quod_dtx:certified_ref(
                         Ns, Anchor, 1, <<120:256>>,
                         quod_dtx:record_digest(PrepareControl), <<"qc">>),
    {ok, DecisionRef} = quod_dtx:certified_ref(
                          <<"ont:decision">>, <<121:256>>, 1, <<122:256>>,
                          <<123:256>>, <<"qc">>),
    {ok, Finalize} = quod_dtx:new_finalize(
                         quod_dtx:group_id(maps:get('begin', Fixture)),
                         DecisionRef, commit, PrepareRef, 2),
    {ok, FinalizeControl} = quod_dtx:sign_control(
                              Target, Finalize, maps:get(admission, Fixture),
                              2, 2, maps:get(signer, Fixture)),
    {ok, PrepareBlob} = quod_dtx:encode_control(PrepareControl),
    {ok, FinalizeBlob} = quod_dtx:encode_control(FinalizeControl),
    with_temp_store(
      Ns,
      fun(Store0) ->
          {ok, PrepareEntry} = quod_ledger:new_entry(
                                 1, {batch, [{dtx, PrepareBlob}]}, 1, none),
          {ok, FinalizeEntry} = quod_ledger:new_entry(
                                  2, {batch, [{dtx, FinalizeBlob}]}, 2, none),
          {ok, Store} = quod_ledger_store:append(
                          Store0, [PrepareEntry, FinalizeEntry]),
          #{txs := [FinalizeRow, _PrepareRow]} =
              quod_explorer_http:txs_page(Store, undefined, 10),
          FinalControl = maps:get(control, FinalizeRow),
          ?assertEqual(commit, maps:get(verdict, FinalControl)),
          AppliedPlan = maps:get(applied_plan, FinalControl),
          ?assertEqual(
             [#{op => assert, clause => <<"dtx_fixture(target)">>}],
             maps:get(diff, AppliedPlan)),
          ok
      end).

indexed_transaction_lookup_reads_exact_terminal_entry_test() ->
    Ns = <<"ont:indexed">>,
    Anchor = <<21:256>>,
    Dir = filename:join(
            "/tmp", "quod_explorer_indexed_" ++
                integer_to_list(erlang:unique_integer([positive]))),
    DataDir = filename:join(Dir, "data"),
    LedgerDir = filename:join(Dir, "ledger"),
    try
        T0 = tx(7),
        T1 = quod_transaction:bind_id(
               {Ns, Anchor},
               T0#transaction{
                 tx_id = <<>>, origin = {Ns, <<22:256>>},
                 proof_id = <<23:256>>, plan_digest = <<24:256>>,
                 author_seq = 1}),
        T = signed_transaction({Ns, Anchor}, T1, indexed),
        {ok, Store0} = quod_ledger_store:open(Ns, LedgerDir),
        {ok, Store1} = quod_ledger_store:append(
                         Store0,
                         [quod_ledger:noop_entry(1, none),
                          begin
                              {ok, Entry2} = quod_ledger:new_entry(
                                               2, {batch, [T]}, 2002, none),
                              Entry2
                          end]),
        ok = quod_ledger_store:close(Store1),
        {ok, Index0} = quod_outcome:open(
                         Ns, Anchor,
                         #{data_dir => DataDir, ledger_dir => LedgerDir,
                           outcome_backend => disk}),
        {new, Candidate, Index0a} = quod_outcome:classify(Index0, T),
        {new, _Stored, Index1} = quod_outcome:terminal(
                                   Index0a, 2, committed,
                                   {new, Candidate}),
        {ok, Index2} = quod_outcome:flush(Index1),
        IdText = binary:encode_hex(T#transaction.tx_id, lowercase),
        {ok, terminal, Detail} =
            quod_explorer_http:test_transaction_outcome(
              Ns, IdText, LedgerDir, LedgerDir),
        ?assertMatch(
           #{outcome := #{status := committed, height := 2,
                          goal := <<"assertz(fact(7))">>},
             tx := #{height := 2}, block := #{slot := 2}},
           Detail),
        ok = quod_outcome:close(Index2)
    after
        _ = file:del_dir_r(Dir)
    end.

paging_test() ->
    with_temp_store(fun(Store0) ->
        Entries = [stored_entry(
                     S, {<<"ont:test">>, <<0:256>>},
                     [tx(S * 10), tx(S * 10 + 1)])
                   || S <- lists:seq(1, 5)],
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

tx_json_full_test() ->
    J = quod_explorer_http:tx_json_full(
          <<"ont:target">>, tx(7), entry(2, [tx(7)])),
    ?assertMatch(#{height := 2, time := 2002, ops := 1, fact_ops := 1,
                   effect_count := 0,
                   effect_operations := [], effects := [],
                   root_facts_changed := true, read_predicates := 0,
                   ns := <<"ont:target">>, submitted_at := 1007}, J),
    ?assertEqual(<<"assertz(fact(7))">>, maps:get(goal, J)),
    ?assertEqual([#{op => assert, clause => <<"fact(7)">>}], maps:get(diff, J)),
    ?assertEqual(
       #{ns => <<"ont:test">>, anchor => binary:encode_hex(<<0:256>>, lowercase)},
       maps:get(origin, J)),
    ?assertEqual(null, maps:get(proof_id, J)),
    ?assertEqual(null, maps:get(plan_digest, J)),
    ?assertEqual(unsigned, maps:get(signature_status, J)),
    ?assertEqual(null, maps:get(signature, J)),
    %% the whole thing must be JSON-encodable
    ?assert(is_binary(quod_explorer_http:encode(J))).

event_tx_json_is_visible_without_claiming_a_fact_change_test() ->
    T = (tx(10))#transaction{diff = [{event, {alarm, disk}}]},
    J = quod_explorer_http:tx_json_full(
          <<"ont:root">>, T, entry(5, [T])),
    ?assertEqual(1, maps:get(ops, J)),
    ?assertEqual(0, maps:get(fact_ops, J)),
    ?assertEqual(false, maps:get(root_facts_changed, J)),
    ?assertEqual(
       [#{op => event, term => <<"alarm(disk)">>}],
       maps:get(diff, J)),
    ?assert(is_binary(quod_explorer_http:encode(J))).

effect_tx_json_is_explicit_and_does_not_claim_root_diff_test() ->
    Executor0 = <<77:256>>,
    Executor = case application:get_env(quod, node_pubkey) of
                   {ok, Executor0} -> <<78:256>>;
                   _ -> Executor0
               end,
    {ok, #{blob := AgentRef}} = quod_agent_ref:from_text(
                                  <<"agent:test">>, <<2:256>>,
                                  <<"human_user(test).">>, 1),
    Effect = {quod_direct_effect, 2, local_durable,
              ontology_lifecycle, create, <<1:256>>, Executor,
              {agent, AgentRef}, {<<"ont:new">>, <<3:256>>},
              <<4:256>>, <<5:256>>},
    T = (tx(9))#transaction{diff = [], effects = [Effect]},
    J = quod_explorer_http:tx_json_full(
          <<"ont:root">>, T, entry(4, [T])),
    ?assertEqual(false, maps:get(root_facts_changed, J)),
    ?assertEqual(1, maps:get(effect_count, J)),
    ?assertEqual([create], maps:get(effect_operations, J)),
    [Rendered] = maps:get(effects, J),
    ?assertMatch(#{operation := create,
                   actor := #{kind := agent, reference := _},
                   actor_authority := signed_agent_request,
                   local_execution := not_this_node}, Rendered),
    ?assertEqual(
       #{ns => <<"ont:new">>,
         anchor => binary:encode_hex(<<3:256>>, lowercase)},
       maps:get(target, Rendered)),
    ?assert(is_binary(quod_explorer_http:encode(J))).

signed_tx_json_test() ->
    {Pub, Seed} = quod_identity:generate(),
    Identity = #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})},
    T0 = (tx(8))#transaction{author = Pub},
    {ok, T} = quod_transaction:sign(
                {<<"ont:test">>, <<0:256>>, <<1:256>>}, T0, Identity),
    J = quod_explorer_http:tx_json_full(<<"ont:test">>, T, entry(2, [T])),
    ?assertEqual(verified, maps:get(signature_status, J)),
    ?assertEqual(128, byte_size(maps:get(signature, J))),
    ?assertEqual(genesis,
                 maps:get(signature_status,
                          quod_explorer_http:tx_json_full(
                            <<"ont:test">>, tx(1), entry(1, [tx(1)])))).

signed_agent_intent_is_rendered_from_the_transaction_test() ->
    Fixture = quod_ct:signed_dtx_begin_fixture(#{}),
    {Ns, Anchor} = maps:get(target, Fixture),
    Transaction = maps:get(transaction, Fixture),
    Json = quod_explorer_http:tx_json_full(
             Ns, Transaction, entry(2, [Transaction])),
    Request = maps:get(request, Json),
    ?assertEqual(verified, maps:get(status, Request)),
    ?assertMatch(
       #{kind := agent, identity := #{ns := Ns}, reference := _},
       maps:get(agent, Request)),
    ?assertEqual(
       binary:encode_hex(maps:get(request_digest, Fixture), lowercase),
       maps:get(request_digest, Request)),
    ?assertEqual(
       binary:encode_hex(maps:get(operation_id, Fixture), lowercase),
       maps:get(operation_id, Request)),
    ?assertMatch(
       #{kind := operation, ns := Ns,
         anchor := _AnchorHex, agent := #{kind := agent},
         operation_id := _},
       maps:get(operation_ref, Request)),
    ?assertEqual(
       #{kind => transaction, ns => Ns,
         anchor => binary:encode_hex(Anchor, lowercase),
         tx_id => quod_explorer_http:tx_id_text(
                    Transaction#transaction.tx_id)},
       maps:get(first_outcome, Request)),
    ?assertEqual(128, byte_size(maps:get(signature, Request))),
    ?assert(is_binary(quod_explorer_http:encode(Json))).

signed_agent_intent_is_rendered_once_from_the_origin_begin_test() ->
    Fixture = quod_ct:signed_dtx_begin_fixture(#{}),
    Control = maps:get(begin_control, Fixture),
    {ok, Blob} = quod_dtx:encode_control(Control),
    Json = quod_explorer_http:block_json(
             element(1, maps:get(target, Fixture)),
             #entry{index = 2, timestamp = 2,
                    data = {batch, [{dtx, Blob}]}}),
    [RenderedControl] = maps:get(controls, Json),
    Request = maps:get(request, RenderedControl),
    ?assertEqual('begin', maps:get(kind, RenderedControl)),
    ?assertEqual(2, maps:get(participant_count, RenderedControl)),
    Participants = maps:get(participants, RenderedControl),
    [Participant] =
        [Row || Row <- Participants,
                maps:get(ns, maps:get(target, Row)) =:=
                    element(1, maps:get(target, Fixture))],
    ?assertMatch(
       #{status := bound, diff_ops := 1, effect_count := 0,
         signer := #{pubkey := _}}, Participant),
    ?assertEqual(
       [#{op => assert, clause => <<"saved(ok)">>}],
       maps:get(diff, Participant)),
    ?assertEqual(
       binary:encode_hex(quod_dtx:digest(maps:get(plan, Fixture)), lowercase),
       maps:get(plan_digest, Participant)),
    ?assertEqual(verified, maps:get(status, Request)),
    ?assertEqual(
       binary:encode_hex(maps:get(request_digest, Fixture), lowercase),
       maps:get(request_digest, Request)),
    ?assertMatch(#{kind := group, group_id := _},
                 maps:get(first_outcome, Request)),
    ?assert(is_binary(quod_explorer_http:encode(Json))).

effect_bearing_dtx_plan_is_visible_as_bound_metadata_test() ->
    {Pub, Seed} = quod_identity:generate(),
    Signer = #{pubkey => Pub,
               key => quod_identity:key_term({Pub, Seed})},
    Target = {<<"ont:effect-participant">>, <<111:256>>},
    Principal = {node, Pub},
    {ok, Effect} = quod_effect:new(
                     create, Pub, Principal,
                     {<<"ont:created">>, <<112:256>>},
                     <<113:256>>, <<114:256>>),
    Core = #{target => Target, base_height => 1,
             proof_id => <<115:256>>, origin => Target,
             principal => Principal, request_binding => none,
             overlay_generation => 0, diff_ops => 0,
             read_functors => 0, effects_count => 1,
             conflict_descriptor =>
                 #{reads => [], writes => [],
                   custody => [quod_effect:target(Effect)]},
             diff => explorer_wire_blob([]),
             read_check => explorer_wire_blob([]),
             effects => explorer_wire_blob([Effect]),
             live_bridges => explorer_wire_blob([]),
             transcript => explorer_wire_blob([])},
    PlanBytes = term_to_binary(
                  {<<"quod.dtx.plan">>, 8, Core}, [deterministic]),
    Plan = {quod_plan, Core, Pub, quod_identity:sign(PlanBytes, Signer)},
    PlanDigest = quod_dtx:digest(Plan),
    {ok, PlanBlob} = quod_dtx:encode(Plan),
    OtherTarget = {<<"ont:effect-origin">>, <<118:256>>},
    OtherCore = Core#{target => OtherTarget, effects_count => 0,
                      conflict_descriptor =>
                          #{reads => [], writes => [], custody => []},
                      effects => explorer_wire_blob([])},
    OtherPlanBytes = term_to_binary(
                       {<<"quod.dtx.plan">>, 8, OtherCore}, [deterministic]),
    OtherPlan = {quod_plan, OtherCore, Pub,
                 quod_identity:sign(OtherPlanBytes, Signer)},
    OtherPlanDigest = quod_dtx:digest(OtherPlan),
    {ok, OtherPlanBlob} = quod_dtx:encode(OtherPlan),
    {ok, GoalBlob} = quod_durable_term:encode_goal({create, visible}),
    {ok, ResultBlob} = quod_durable_term:encode_result(#{}),
    {ok, Manifest} = quod_dtx:new_manifest(
                       #{proof_id => <<115:256>>,
                         coordinator =>
                             {element(1, Target), element(2, Target),
                              Pub, <<116:256>>},
                         nonce => <<117:256>>, principal => Principal,
                         goal => GoalBlob, result => ResultBlob,
                         request_binding => none,
                         participants =>
                             [{Target, PlanDigest},
                              {OtherTarget, OtherPlanDigest}]}),
    {ok, Attestation} = quod_dtx:attest_plan(
                          Target, Plan, Manifest, Signer),
    {ok, OtherAttestation} = quod_dtx:attest_plan(
                               OtherTarget, OtherPlan, Manifest, Signer),
    {ok, Begin} = quod_dtx:new_begin(
                    Manifest, none,
                    [{Target, PlanDigest, PlanBlob, Attestation},
                     {OtherTarget, OtherPlanDigest, OtherPlanBlob,
                      OtherAttestation}]),
    {ok, Control} = quod_dtx:sign_control(
                      Target, Begin, <<116:256>>, 1, 1, Signer),
    {ok, ControlBlob} = quod_dtx:encode_control(Control),
    Json = quod_explorer_http:block_json(
             element(1, Target),
             #entry{index = 1, timestamp = 1,
                    data = {batch, [{dtx, ControlBlob}]}}),
    [RenderedControl] = maps:get(controls, Json),
    [Participant] =
        [Row || Row <- maps:get(participants, RenderedControl),
                maps:get(ns, maps:get(target, Row)) =:= element(1, Target)],
    ?assertMatch(
       #{status := bound, diff_ops := 0, effect_count := 1,
         target := #{ns := <<"ont:effect-participant">>}},
       Participant),
    ?assertMatch(
       [#{operation := create, effect_id := _,
          target := #{ns := <<"ont:created">>},
          executor := #{pubkey := _},
          actor := #{kind := node},
          local_execution := _}],
       maps:get(effects, Participant)),
    ?assert(is_binary(quod_explorer_http:encode(Json))).

compiled_clause_test() ->
    %% committed clauses carry erlog's COMPILED body `{Goals, HasCut}` — facts render head-only,
    %% rules with the familiar comma body (never the raw `{[],false}` internals)
    T = (tx(1))#transaction{diff = [{assert, {{fact, a}, {[], false}}},
                                    {retract, {{rule, {'X'}}, {[{peer_ready, {'X'}}], false}}}]},
    J = quod_explorer_http:tx_json_full(<<"ont:test">>, T, entry(1, [T])),
    ?assertEqual([#{op => assert, clause => <<"fact(a)">>},
                  #{op => retract, clause => <<"rule(X) :- peer_ready(X)">>}],
                 maps:get(diff, J)).

printable_tx_id_test() ->
    %% Canonical 32-byte ids are always the exact hex accepted by lookup, even
    %% in the rare case that every hash byte happens to be printable.
    ?assertEqual(<<"client-readable">>,
                 quod_explorer_http:tx_id_text(<<"client-readable">>)),
    PrintableHash = binary:copy(<<"a">>, 32),
    ?assertEqual(binary:encode_hex(PrintableHash, lowercase),
                 quod_explorer_http:tx_id_text(PrintableHash)),
    ?assertEqual(
       <<"group:", (binary:encode_hex(PrintableHash, lowercase))/binary>>,
       quod_explorer_http:tx_id_text({group, PrintableHash})),
    ?assertEqual(<<"00000000000000ff">>, quod_explorer_http:tx_id_text(<<255:64>>)).

explorer_wire_blob(Term) ->
    {ok, Blob} = quod_wire_term:encode_canonical(Term),
    Blob.

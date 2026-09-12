-module(quod_explorer_tests).
-moduledoc false.
%% The explorer's pure surface: Prolog display rendering, transaction JSON, goal parsing,
%% and history paging over a real (temp-dir) ledger store. The listener/WS processes are
%% exercised live — they are thin cowboy glue over these functions.
-include_lib("eunit/include/eunit.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").
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
    stored_entry(Slot, {<<"ont:test">>, <<0:256>>}, Txs).

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
             <<"ont:test">>, quod_ledger:noop_entry(3, none)),
    ?assertEqual(noop, maps:get(kind, Noop)),
    ?assertEqual([], maps:get(txs, Noop)),
    ?assertEqual({error, bad_entry},
                 quod_ledger:new_entry(4, {batch, []}, 0, none)),
    {ok, DtxEntry} = quod_ledger:new_entry(5, quod_ct:dtx_decision_payload(), 0, none),
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
    {ok, DtxEntry} = quod_ledger:new_entry(5, quod_ct:dtx_decision_payload(), 0, none),
    {reply, {text, Frame}, state} =
        quod_explorer_ws:websocket_info(
          {committed, Ns, 5, DtxEntry}, state),
    ?assertNotEqual(nomatch, binary:match(Frame, <<"decision">>)),
    ?assertEqual(
       {ok, state},
       quod_explorer_ws:websocket_info(
         {committed, Ns, 6, quod_ledger:noop_entry(6, none)}, state)),
    ?assertEqual({error, bad_entry},
                 quod_ledger:new_entry(7, {batch, []}, 0, none)).

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
    %% Exercise the formatter's malformed argument, not a codec bypass.
    E = entry(91, [T0]),
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

explicit_history_mode_test() ->
    ?assertEqual({ok, live}, quod_explorer_http:history_mode(#{})),
    ?assertEqual({ok, live}, quod_explorer_http:history_mode(#{<<"mode">> => <<"live">>})),
    ?assertEqual({ok, offline}, quod_explorer_http:history_mode(#{<<"mode">> => <<"offline">>})),
    ?assertEqual({error, bad_mode}, quod_explorer_http:history_mode(#{<<"mode">> => true})),
    ?assertEqual({error, bad_mode}, quod_explorer_http:history_mode(#{<<"mode">> => <<"auto">>})).

configured_history_deadline_is_captured_once_test() ->
    with_explorer_budget(1234, fun() ->
        Before = quod_time:mono_ms(),
        Deadline = quod_explorer_http:read_deadline(),
        ?assert(Deadline >= Before + 1234),
        ?assert(Deadline =< quod_time:mono_ms() + 1234)
    end).

history_http_modes_and_status_contract_test() ->
    with_history_source(fun(Ns, Owner) ->
        {Results, Names} = trace_history_reads(fun() ->
            [history_http(txs, <<"ns=", Ns/binary>>, #{}),
             history_http(block, <<>>, #{ns => Ns, slot => <<"2">>})]
        end),
        ?assertMatch([{200, #{<<"height">> := 2}}, {200, #{<<"slot">> := 2}}], Results),
        ?assertEqual(2, length([ok || <<"quod.ledger.file_open">> <- Names])),
        ?assertNot(lists:member(<<"quod.ledger.index_scan">>, Names)),
        ?assertMatch({503, #{<<"error">> := <<"ontology_unreachable">>}},
                     history_http(block, <<"mode=offline">>, #{ns => Ns, slot => <<"2">>})),
        ?assertMatch({400, #{<<"error">> := <<"bad_mode">>}},
                     history_http(txs, <<"ns=", Ns/binary, "&mode=auto">>, #{})),
        stop_history_source(Owner),
        ?assertMatch({503, #{<<"error">> := <<"ontology_unreachable">>}},
                     history_http(txs, <<"ns=", Ns/binary>>, #{})),
        ?assertMatch({200, #{<<"height">> := 2}},
                     history_http(txs, <<"ns=", Ns/binary, "&mode=offline">>, #{})),
        ?assertMatch({404, #{<<"error">> := <<"not_found">>}},
                     history_http(block, <<"mode=offline">>, #{ns => Ns, slot => <<"99">>}))
    end).

http_owner_wait_uses_configured_deadline_test() ->
    with_explorer_budget(40, fun() ->
        with_history_source(fun(Ns, Owner) ->
            history_source_command(Owner, hold),
            ?assertMatch({503, #{<<"error">> := <<"ontology_unreachable">>}},
                         history_http(block, <<>>, #{ns => Ns, slot => <<"2">>})),
            receive {history_capture, Owner, _, _} -> ok
            after 1000 -> error(http_did_not_borrow_owner)
            end
        end)
    end).

expired_render_result_is_refused_and_handle_closed_test() ->
    with_history_source(fun(Ns, _Owner) ->
        Deadline = quod_time:mono_ms() + 40,
        Result = quod_explorer_http:with_history_store(
          Ns, live, Deadline,
          fun(Store) ->
              self() ! {borrowed_history_store, Store},
              receive after max(0, Deadline - quod_time:mono_ms() + 1) -> rendered end
          end, no_store),
        ?assertEqual({error, ontology_unreachable}, Result),
        receive {borrowed_history_store, Closed} ->
            ?assertMatch({'EXIT', _}, catch quod_ledger_store:read_at(Closed, 1))
        after 1000 -> error(reader_never_opened)
        end
    end).

history_http(Op, Qs, Bindings) ->
    {ok, _} = application:ensure_all_started(cowboy),
    Ref = make_ref(),
    Req = #{method => <<"GET">>, pid => self(), streamid => Ref,
            qs => Qs, bindings => Bindings},
    {ok, _, Op} = quod_explorer_http:init(Req, Op),
    Pid = self(),
    receive {{Pid, Ref}, {response, Status, _Headers, Body}} -> {Status, json:decode(Body)}
    after 1000 -> error(http_response_missing)
    end.

with_explorer_budget(Budget, Fun) ->
    Before = application:get_env(quod, explorer_read_budget_ms),
    application:set_env(quod, explorer_read_budget_ms, Budget),
    try Fun() after restore_explorer_env(explorer_read_budget_ms, Before) end.

restore_explorer_env(Key, undefined) -> application:unset_env(quod, Key);
restore_explorer_env(Key, {ok, Value}) -> application:set_env(quod, Key, Value).

live_history_reads_owner_snapshots_without_index_scans_test() ->
    with_history_source(fun(Ns, _Owner) ->
        {Pages, Names} = trace_history_reads(fun() ->
            [history_page(Ns, live, quod_time:mono_ms() + 1000) || _ <- lists:seq(1, 3)]
        end),
        ?assertEqual([2, 2, 2], [maps:get(height, Page) || Page <- Pages]),
        ?assertEqual(3, length([ok || <<"quod.ledger.file_open">> <- Names])),
        ?assertNot(lists:member(<<"quod.ledger.index_scan">>, Names))
    end).

live_history_snapshot_stays_bounded_across_append_test() ->
    with_history_source(fun(Ns, Owner) ->
        Page = quod_explorer_http:with_history_store(
          Ns, live, quod_time:mono_ms() + 1000,
          fun(Store) ->
              history_source_command(Owner, append),
              ?assertEqual(2, quod_ledger_store:last(Store)),
              ?assertEqual(not_found, quod_ledger_store:read_at(Store, 3)),
              quod_explorer_http:txs_page(Store, undefined, 10)
          end, no_store),
        ?assertMatch(#{height := 2}, Page),
        ?assertMatch(#{height := 3}, history_page(Ns, live, quod_time:mono_ms() + 1000))
    end).

busy_history_owner_never_falls_back_to_disk_test() ->
    with_history_source(fun(Ns, Owner) ->
        history_source_command(Owner, hold),
        {Result, Names} = trace_history_reads(fun() ->
            history_page(Ns, live, quod_time:mono_ms() + 40)
        end),
        ?assertEqual({error, ontology_unreachable}, Result),
        ?assertNot(lists:member(<<"quod.ledger.file_open">>, Names)),
        receive {history_capture, Owner, _From, _View} -> ok
        after 1000 -> error(capture_not_attempted)
        end
    end).

replaced_history_owner_cannot_publish_old_view_test() ->
    with_history_source(fun(Ns, Owner) ->
        history_source_command(Owner, hold),
        Parent = self(),
        {Reader, MRef} = spawn_monitor(fun() ->
            Parent ! {history_result, self(),
                      trace_history_reads(fun() ->
                          history_page(Ns, live, quod_time:mono_ms() + 2000)
                      end)}
        end),
        receive
            {history_capture, Owner, From, View} ->
                history_source_command(Owner, unregister),
                Replacement = spawn(fun() ->
                    true = quod_reg:reg({quod_simplex, Ns}),
                    Parent ! {replacement_ready, self()},
                    receive stop -> ok end
                end),
                try
                    receive {replacement_ready, Replacement} -> ok
                    after 1000 -> error(replacement_not_ready)
                    end,
                    Owner ! {reply_capture, From, View},
                    receive
                        {history_result, Reader, {Result, Names}} ->
                            ?assertEqual({error, ontology_unreachable}, Result),
                            ?assertNot(lists:member(<<"quod.ledger.file_open">>, Names))
                    after 1000 -> error(stale_capture_not_released)
                    end,
                    receive {'DOWN', MRef, process, Reader, normal} -> ok
                    after 1000 -> error(reader_not_reclaimed)
                    end
                after stop_history_source(Replacement)
                end
        after 1000 -> error(capture_not_held)
        end
    end).

history_owner_death_releases_parked_reader_test() ->
    with_history_source(fun(Ns, Owner) ->
        history_source_command(Owner, hold),
        Parent = self(),
        {Reader, MRef} = spawn_monitor(fun() ->
            Parent ! {history_result, self(), history_page(Ns, live, quod_time:mono_ms() + 60000)}
        end),
        receive {history_capture, Owner, _, _} -> ok
        after 1000 -> error(capture_not_held)
        end,
        stop_history_source(Owner),
        receive {history_result, Reader, Result} ->
            ?assertEqual({error, ontology_unreachable}, Result)
        after 1000 -> error(owner_death_waited_for_deadline)
        end,
        receive {'DOWN', MRef, process, Reader, normal} -> ok
        after 1000 -> error(reader_not_reclaimed)
        end
    end).

offline_history_is_explicit_and_refuses_running_owner_test() ->
    with_history_source(fun(Ns, Owner) ->
        {Refused, LiveNames} = trace_history_reads(fun() ->
            history_page(Ns, offline, quod_time:mono_ms() + 1000)
        end),
        ?assertEqual({error, ontology_unreachable}, Refused),
        ?assertNot(lists:member(<<"quod.ledger.file_open">>, LiveNames)),
        stop_history_source(Owner),
        {Missing, MissingNames} = trace_history_reads(fun() ->
            history_page(Ns, live, quod_time:mono_ms() + 1000)
        end),
        ?assertEqual({error, ontology_unreachable}, Missing),
        ?assertNot(lists:member(<<"quod.ledger.file_open">>, MissingNames)),
        {Page, OfflineNames} = trace_history_reads(fun() ->
            history_page(Ns, offline, quod_time:mono_ms() + 1000)
        end),
        ?assertMatch(#{height := 2}, Page),
        ?assertEqual(1, length([ok || <<"quod.ledger.index_scan">> <- OfflineNames]))
    end).

expired_history_read_opens_nothing_test() ->
    with_history_source(fun(Ns, _Owner) ->
        {Results, Names} = trace_history_reads(fun() ->
            [history_page(Ns, Mode, quod_time:mono_ms() - 1) || Mode <- [live, offline]]
        end),
        ?assertEqual([{error, ontology_unreachable}, {error, ontology_unreachable}], Results),
        ?assertNot(lists:member(<<"quod.ledger.file_open">>, Names))
    end).

history_reader_closes_snapshot_on_renderer_failure_test() ->
    with_history_source(fun(Ns, _Owner) ->
        ?assertError(deliberate_render_failure,
          quod_explorer_http:with_history_store(
            Ns, live, quod_time:mono_ms() + 1000,
            fun(Store) -> self() ! {borrowed_history_store, Store}, error(deliberate_render_failure) end,
            no_store)),
        receive
            {borrowed_history_store, Closed} ->
                ?assertMatch({'EXIT', _}, catch quod_ledger_store:read_at(Closed, 1))
        after 1000 -> error(reader_never_opened)
        end
    end).

history_page(Ns, Mode, Deadline) ->
    quod_explorer_http:with_history_store(
      Ns, Mode, Deadline, fun(Store) -> quod_explorer_http:txs_page(Store, undefined, 10) end,
      #{txs => [], height => 0, next_before => null}).

trace_history_reads(Fun) ->
    quod_trace_tests:with_tracer(fun() ->
        {Result, TraceId} = quod_trace:with_span(
                   otel_ctx:new(), <<"explorer.history.test">>, internal, #{},
                   fun(Span) -> {Fun(), otel_span:trace_id(Span)} end),
        {Result, history_span_names(TraceId, [])}
    end).

history_span_names(TraceId, Acc) ->
    receive {quod_test_span, #span{name = Name, trace_id = TraceId}} ->
        history_span_names(TraceId, [Name | Acc])
    after 0 -> lists:reverse(Acc)
    end.

history_read_counts_exclude_unrelated_request_test() ->
    with_history_source(fun(Ns, _Owner) ->
        {Page, Names} = trace_history_reads(fun() ->
            %% A real second ledger read under an independent SDK trace must
            %% not inflate this request's count. No fabricated exporter row.
            quod_trace:with_span(otel_ctx:new(), <<"unrelated.history">>, internal, #{},
              fun(_) -> history_page(Ns, live, quod_time:mono_ms() + 1000) end),
            history_page(Ns, live, quod_time:mono_ms() + 1000)
        end),
        ?assertMatch(#{height := 2}, Page),
        ?assertEqual(1, length([ok || <<"quod.ledger.file_open">> <- Names])),
        %% These exports deliberately belonged to no counted request.
        drain_unrelated_history_spans()
    end).

drain_unrelated_history_spans() ->
    receive {quod_test_span, #span{}} -> drain_unrelated_history_spans()
    after 0 -> ok
    end.

with_history_source(Fun) ->
    Suffix = integer_to_list(erlang:unique_integer([positive])),
    Ns = list_to_binary("ont:explorer-history:" ++ Suffix),
    with_history_source({Ns, <<0:256>>},
      [quod_ledger:noop_entry(I, none) || I <- [1, 2]], Fun).

with_history_source({Ns, _Anchor} = Identity, Entries, Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    Suffix = integer_to_list(erlang:unique_integer([positive])),
    Dir = filename:join("/tmp", "quod_explorer_history_" ++ Suffix),
    Previous = application:get_env(quod, content_storage_dirs),
    Storage = application:get_env(quod, content_storage_dirs, #{}),
    application:set_env(quod, content_storage_dirs,
                        Storage#{Ns => #{data => Dir, ledger => Dir}}),
    Parent = self(),
    Owner = spawn(fun() ->
        {ok, Store0} = quod_ledger_store:open(Ns, Dir),
        {ok, Store} = quod_ledger_store:append(Store0, Entries),
        try
            true = quod_reg:reg({quod_simplex, Ns}),
            Parent ! {history_source_ready, self()},
            history_source_loop(Identity, Store, Parent, ready)
        after quod_ledger_store:close(Store)
        end
    end),
    try
        receive {history_source_ready, Owner} -> ok
        after 2000 -> error(history_source_not_ready)
        end,
        Fun(Ns, Owner)
    after
        stop_history_source(Owner),
        case Previous of
            undefined -> application:unset_env(quod, content_storage_dirs);
            {ok, Value} -> application:set_env(quod, content_storage_dirs, Value)
        end,
        _ = file:del_dir_r(Dir)
    end.

history_source_loop({Ns, Anchor} = SourceIdentity, Store, Parent, Mode) ->
    receive
        {'$gen_call', From, {history_view, Identity, Requirement, Deadline}} ->
            State = quod_simplex:test_state(#{ns => Ns, genesis_hash => Anchor,
              store => Store, slot => quod_ledger_store:last(Store), last_applied => 0,
              sync => ready, prolog_ready => false}),
            View = quod_simplex:test_local_history_view(Identity, Requirement, Deadline, State),
            case Mode of
                ready -> gen:reply(From, View);
                hold -> Parent ! {history_capture, self(), From, View}
            end,
            history_source_loop(SourceIdentity, Store, Parent, ready);
        {reply_capture, From, View} ->
            gen:reply(From, View),
            history_source_loop(SourceIdentity, Store, Parent, Mode);
        {history_command, Caller, Ref, hold} ->
            Caller ! {history_command_done, Ref},
            history_source_loop(SourceIdentity, Store, Parent, hold);
        {history_command, Caller, Ref, unregister} ->
            true = gproc:unreg(quod_reg:name({quod_simplex, Ns})),
            Caller ! {history_command_done, Ref},
            history_source_loop(SourceIdentity, Store, Parent, Mode);
        {history_command, Caller, Ref, append} ->
            {ok, Next} = quod_ledger_store:append(
                           Store, [quod_ledger:noop_entry(quod_ledger_store:last(Store) + 1, none)]),
            Caller ! {history_command_done, Ref},
            history_source_loop(SourceIdentity, Next, Parent, Mode);
        stop -> ok
    end.

history_source_command(Owner, Command) ->
    Ref = make_ref(),
    Owner ! {history_command, self(), Ref, Command},
    receive {history_command_done, Ref} -> ok
    after 1000 -> error({history_command_timeout, Command})
    end.

stop_history_source(Owner) ->
    MRef = erlang:monitor(process, Owner),
    Owner ! stop,
    receive {'DOWN', MRef, process, Owner, _} -> ok
    after 1000 -> exit(Owner, kill),
                 receive {'DOWN', MRef, process, Owner, _} -> ok end
    end.

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
    {ok, PrepareEntry} = quod_ledger:new_entry(1, {batch, [{dtx, PrepareBlob}]}, 1, none),
    {ok, FinalizeEntry} = quod_ledger:new_entry(2, {batch, [{dtx, FinalizeBlob}]}, 2, none),
    with_history_source(Target, [PrepareEntry, FinalizeEntry],
      fun(Ns0, Owner) ->
          #{txs := [FinalizeRow, _PrepareRow]} =
              history_page(Ns0, live, quod_time:mono_ms() + 1000),
          FinalControl = maps:get(control, FinalizeRow),
          ?assertEqual(commit, maps:get(verdict, FinalControl)),
          AppliedPlan = maps:get(applied_plan, FinalControl),
          ?assertEqual(
             [#{op => assert, clause => <<"dtx_fixture(target)">>}],
             maps:get(diff, AppliedPlan)),
          {{reply, {text, Frame}, state}, Names} = trace_history_reads(fun() ->
              quod_explorer_ws:websocket_info({committed, Ns0, 2, FinalizeEntry}, state)
          end),
          #{<<"controls">> := [WsControl]} = json:decode(Frame),
          ?assertMatch(#{<<"applied_plan">> := #{<<"diff">> := [_]}}, WsControl),
          ?assertEqual(1, length([ok || <<"quod.ledger.file_open">> <- Names])),
          ?assertNot(lists:member(<<"quod.ledger.index_scan">>, Names)),
          stop_history_source(Owner),
          {{reply, {text, UnavailableFrame}, state}, MissingNames} = trace_history_reads(fun() ->
              quod_explorer_ws:websocket_info({committed, Ns0, 2, FinalizeEntry}, state)
          end),
          #{<<"controls">> := [MissingControl]} = json:decode(UnavailableFrame),
          ?assertNot(maps:is_key(<<"applied_plan">>, MissingControl)),
          ?assertNot(lists:member(<<"quod.ledger.file_open">>, MissingNames)),
          ok
      end).

pending_outcome_requires_same_anchored_owner_without_opening_reader_test() ->
    Ns = <<"ont:indexed-pending">>,
    IndexAnchor = <<21:256>>,
    T = quod_transaction:bind_id(
          {Ns, IndexAnchor}, (tx(8))#transaction{tx_id = <<>>, plan_digest = <<24:256>>}),
    IdText = binary:encode_hex(T#transaction.tx_id, lowercase),
    lists:foreach(fun(SourceAnchor) ->
        with_history_source({Ns, SourceAnchor}, [quod_ledger:noop_entry(1, none)],
          fun(Ns0, _Owner) ->
              #{Ns0 := #{ledger := Dir}} = application:get_env(quod, content_storage_dirs, #{}),
              {ok, Index0} = quod_outcome:open(Ns0, IndexAnchor,
                #{data_dir => Dir, ledger_dir => Dir, outcome_backend => disk}),
              {new, Index} = quod_outcome:admit(Index0, T),
              try
                  {Result, Names} = trace_history_reads(fun() ->
                      history_http(tx, <<>>, #{ns => Ns0, id => IdText})
                  end),
                  case SourceAnchor of
                      IndexAnchor -> ?assertMatch({202, #{<<"outcome">> := #{<<"status">> := <<"pending">>}}}, Result);
                      _ -> ?assertMatch({503, #{<<"error">> := <<"ontology_unreachable">>}}, Result)
                  end,
                  ?assertNot(lists:member(<<"quod.ledger.file_open">>, Names))
              after quod_outcome:close(Index)
              end
          end)
    end, [IndexAnchor, <<22:256>>]).

indexed_transaction_lookup_reads_exact_terminal_entry_test() ->
    Ns = <<"ont:indexed">>,
    Anchor = <<21:256>>,
    T0 = tx(7),
    T1 = quod_transaction:bind_id(
           {Ns, Anchor}, T0#transaction{tx_id = <<>>, origin = {Ns, <<22:256>>},
             proof_id = <<23:256>>, plan_digest = <<24:256>>, author_seq = 1}),
    T = signed_transaction({Ns, Anchor}, T1, indexed),
    {ok, Entry2} = quod_ledger:new_entry(2, {batch, [T]}, 2002, none),
    with_history_source({Ns, Anchor}, [quod_ledger:noop_entry(1, none), Entry2],
      fun(Ns0, Owner) ->
        #{Ns0 := #{data := DataDir, ledger := LedgerDir}} =
            application:get_env(quod, content_storage_dirs, #{}),
        {ok, Index0} = quod_outcome:open(
                         Ns0, Anchor,
                         #{data_dir => DataDir, ledger_dir => LedgerDir,
                           outcome_backend => disk}),
        {new, Candidate, Index0a} = quod_outcome:classify(Index0, T),
        {new, _Stored, Index1} = quod_outcome:terminal(
                                   Index0a, 2, committed,
                                   {new, Candidate}),
        {ok, Index2} = quod_outcome:flush(Index1),
        IdText = binary:encode_hex(T#transaction.tx_id, lowercase),
        try
            {{ok, terminal, Detail}, Names} = trace_history_reads(fun() ->
                quod_explorer_http:transaction_outcome(
                  Ns0, IdText, live, quod_time:mono_ms() + 1000)
            end),
            ?assertMatch(
               #{outcome := #{status := committed, height := 2,
                              goal := <<"assertz(fact(7))">>},
                 tx := #{height := 2}, block := #{slot := 2}}, Detail),
            ?assertEqual(1, length([ok || <<"quod.ledger.file_open">> <- Names])),
            ?assertNot(lists:member(<<"quod.ledger.index_scan">>, Names)),
            ?assertMatch({200, #{<<"tx">> := #{<<"height">> := 2}}},
                         history_http(tx, <<>>, #{ns => Ns0, id => IdText})),
            stop_history_source(Owner),
            ?assertMatch({503, #{<<"error">> := <<"ontology_unreachable">>}},
                         history_http(tx, <<>>, #{ns => Ns0, id => IdText})),
            ?assertMatch({200, #{<<"tx">> := #{<<"height">> := 2}}},
                         history_http(tx, <<"mode=offline">>, #{ns => Ns0, id => IdText}))
        after quod_outcome:close(Index2)
        end
      end).

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
    %% The formatter's effect shape is independent of ledger authentication;
    %% supply a codec-built slot for the metadata it reads.
    J = quod_explorer_http:tx_json_full(
          <<"ont:root">>, T, entry(4, [tx(9)])),
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
             Ns, Transaction, stored_entry(2, {Ns, Anchor}, [Transaction])),
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
    {ok, Entry} = quod_ledger:new_entry(2, {batch, [{dtx, Blob}]}, 2, none),
    Json = quod_explorer_http:block_json(
             element(1, maps:get(target, Fixture)), Entry),
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
    {ok, Entry} = quod_ledger:new_entry(1, {batch, [{dtx, ControlBlob}]}, 1, none),
    Json = quod_explorer_http:block_json(element(1, Target), Entry),
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

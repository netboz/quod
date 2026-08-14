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
    ?assertEqual(
       {ok, {create_ontology, "demo:console", [{terms, [{hello, world}]}]}},
       quod_explorer_http:parse_goal(
         <<"create_ontology(\"demo:console\", [terms([hello(world)])])">>)),
    ?assertMatch({error, _}, quod_explorer_http:parse_goal(<<"capital(france">>)).

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

proof_cursor_json_and_id_are_exact_test() ->
    CursorId = <<23:256>>,
    CursorText = binary:encode_hex(CursorId, lowercase),
    ?assertEqual(
       {200, #{result => solution, cursor => CursorText, height => 17,
               bindings => [#{<<"X">> => <<"second">>}]}},
       quod_explorer_http:cursor_result(
         {solution, CursorId, #{'X' => second}, 17})),
    ?assertEqual({ok, CursorId},
                 quod_explorer_http:parse_cursor_id(CursorText)),
    ?assertEqual(error,
                 quod_explorer_http:parse_cursor_id(<<"not-a-cursor">>)),
    ?assertEqual({200, #{result => stopped}},
                 quod_explorer_http:cursor_result({ok, stopped})),
    ?assertEqual({404, #{error => cursor_not_found}},
                 quod_explorer_http:cursor_result({error, not_found})).

%%%===================================================================
%%% cursor coordinator — exact ownership, races, and cleanup
%%%===================================================================

cursor_command_busy_and_solution_correlation_test() ->
    {CursorId, Engine, Worker, CallRef, State0} = cursor_state(none, none),
    Tag = make_ref(),
    {noreply, State1} = quod_explorer:handle_call(
                          {cursor_command, CursorId, next},
                          {self(), Tag}, State0),
    CommandRef = receive
        {worker_message, Worker,
         {quod_cursor_command, _Owner, CallRef, CursorId,
          SeenCommandRef, next}} -> SeenCommandRef
    after 1000 -> error(cursor_command_missing)
    end,
    ?assertMatch(
       {reply, {error, busy}, _},
       quod_explorer:handle_call(
         {cursor_command, CursorId, accept},
         {self(), make_ref()}, State1)),
    {noreply, State2} = quod_explorer:handle_info(
                          {quod_cursor_solution, Worker, CallRef, CursorId,
                           CommandRef, #{'X' => second}, 7}, State1),
    receive
        {Tag, {solution, CursorId, #{'X' := second}, 7}} -> ok
    after 1000 -> error(cursor_solution_reply_missing)
    end,
    #{CursorId := #{pending := none}} = maps:get(cursors, State2),
    {noreply, State3} = quod_explorer:handle_info(
                          {quod_proof_reply, Engine, CallRef, cursor_stopped},
                          State2),
    ?assertEqual(#{}, maps:get(cursors, State3)),
    stop_cursor_fixture(Engine, Worker).

cursor_stale_solution_kills_exact_worker_test() ->
    {CursorId, Engine, Worker, CallRef, State0} = cursor_state(none, none),
    WorkerMRef = monitor(process, Worker),
    {noreply, State1} = quod_explorer:handle_call(
                          {cursor_command, CursorId, next},
                          {self(), make_ref()}, State0),
    receive {worker_message, Worker, _} -> ok
    after 1000 -> error(cursor_command_missing)
    end,
    {noreply, State2} = quod_explorer:handle_info(
                          {quod_cursor_solution, Worker, CallRef, CursorId,
                           make_ref(), #{}, 7}, State1),
    ?assertEqual(#{}, maps:get(cursors, State2)),
    receive {'DOWN', WorkerMRef, process, Worker, killed} -> ok
    after 1000 -> error(stale_cursor_worker_survived)
    end,
    stop_cursor_fixture(Engine, undefined).

cursor_caller_down_cancels_next_but_detaches_accept_test() ->
    %% A vanished observer may safely cancel a read/Next.  Accept is different:
    %% it may already be durably submitted, so only the observer is detached.
    {NextId, NextEngine, NextWorker, _NextCallRef, NextState0} =
        cursor_state(none, none),
    NextWorkerMRef = monitor(process, NextWorker),
    NextCaller = spawn(fun cursor_fixture_loop/0),
    {noreply, NextState1} = quod_explorer:handle_call(
                              {cursor_command, NextId, next},
                              {NextCaller, make_ref()}, NextState0),
    receive {worker_message, NextWorker, _} -> ok
    after 1000 -> error(next_command_missing)
    end,
    NextCallerMRef = pending_caller_mref(NextId, NextState1),
    exit(NextCaller, kill),
    NextDown = receive
        {'DOWN', NextCallerMRef, process, NextCaller, killed} = NextDownMsg ->
            NextDownMsg
    after 1000 -> error(next_caller_down_missing)
    end,
    {noreply, NextState2} = quod_explorer:handle_info(NextDown, NextState1),
    ?assertEqual(#{}, maps:get(cursors, NextState2)),
    receive {'DOWN', NextWorkerMRef, process, NextWorker, killed} -> ok
    after 1000 -> error(next_worker_survived_caller)
    end,
    stop_cursor_fixture(NextEngine, undefined),

    {AcceptId, AcceptEngine, AcceptWorker, AcceptCallRef, AcceptState0} =
        cursor_state(none, none),
    AcceptCaller = spawn(fun cursor_fixture_loop/0),
    {noreply, AcceptState1} = quod_explorer:handle_call(
                                {cursor_command, AcceptId, accept},
                                {AcceptCaller, make_ref()}, AcceptState0),
    receive {worker_message, AcceptWorker, _} -> ok
    after 1000 -> error(accept_command_missing)
    end,
    AcceptCallerMRef = pending_caller_mref(AcceptId, AcceptState1),
    exit(AcceptCaller, kill),
    AcceptDown = receive
        {'DOWN', AcceptCallerMRef, process, AcceptCaller, killed} = AcceptDownMsg ->
            AcceptDownMsg
    after 1000 -> error(accept_caller_down_missing)
    end,
    {noreply, AcceptState2} =
        quod_explorer:handle_info(AcceptDown, AcceptState1),
    #{AcceptId := #{pending := detached_accept}} =
        maps:get(cursors, AcceptState2),
    ?assert(is_process_alive(AcceptWorker)),
    {noreply, AcceptState3} = quod_explorer:handle_info(
                               {quod_proof_reply, AcceptEngine,
                                AcceptCallRef, {ok, [#{}], 8}},
                               AcceptState2),
    ?assertEqual(#{}, maps:get(cursors, AcceptState3)),
    stop_cursor_fixture(AcceptEngine, AcceptWorker).

cursor_engine_down_preserves_exact_checkpoint_test() ->
    Ref = {transaction, <<"ont:test">>, <<41:256>>, <<42:256>>},
    lists:foreach(
      fun({Checkpoint, Expected}) ->
          Tag = make_ref(),
          CallerMRef = monitor(process, self()),
          Pending = {{self(), Tag}, CallerMRef, open},
          {CursorId, Engine, Worker, _CallRef, State0} =
              cursor_state(Pending, Checkpoint),
          EngineMRef = cursor_engine_mref(CursorId, State0),
          exit(Engine, kill),
          EngineDown = receive
              {'DOWN', EngineMRef, process, Engine, killed} = Down -> Down
          after 1000 -> error(cursor_engine_down_missing)
          end,
          {noreply, State1} =
              quod_explorer:handle_info(EngineDown, State0),
          receive {Tag, Expected} -> ok
          after 1000 -> error(cursor_engine_reply_missing)
          end,
          ?assertEqual(#{}, maps:get(cursors, State1)),
          stop_cursor_fixture(undefined, Worker)
      end,
      [{none, {error, ontology_unavailable}},
       {Ref, {error, {outcome_unknown, Ref}}}]).

cursor_terminate_preserves_detached_accept_worker_test() ->
    {ok, _} = application:ensure_all_started(cowboy),
    {CursorId, Engine, Worker, _CallRef, State0} =
        cursor_state(detached_accept, none),
    ?assertEqual(ok, quod_explorer:terminate(shutdown, State0)),
    ?assert(is_process_alive(Worker)),
    %% The terminated owner intentionally drops its volatile map; the engine
    %% owns the still-bounded worker until settlement or the proof deadline.
    ?assert(maps:is_key(CursorId, maps:get(cursors, State0))),
    stop_cursor_fixture(Engine, Worker).

cursor_state(Pending, Checkpoint) ->
    Parent = self(),
    Engine = spawn(fun cursor_fixture_loop/0),
    Worker = spawn(fun() -> cursor_worker_loop(Parent) end),
    EngineMRef = monitor(process, Engine),
    CursorId = crypto:strong_rand_bytes(32),
    CallRef = make_ref(),
    Cursor = #{engine => Engine, engine_mref => EngineMRef,
               call_ref => CallRef, worker => Worker,
               checkpoint => Checkpoint, pending => Pending},
    {CursorId, Engine, Worker, CallRef,
     #{cursors => #{CursorId => Cursor}}}.

cursor_worker_loop(Parent) ->
    receive
        stop -> ok;
        Message ->
            Parent ! {worker_message, self(), Message},
            cursor_worker_loop(Parent)
    end.

cursor_fixture_loop() ->
    receive stop -> ok end.

pending_caller_mref(CursorId, State) ->
    #{CursorId := #{pending := {_From, MRef, _Command}}} =
        maps:get(cursors, State),
    MRef.

cursor_engine_mref(CursorId, State) ->
    #{CursorId := #{engine_mref := MRef}} = maps:get(cursors, State),
    MRef.

stop_cursor_fixture(Engine, Worker) ->
    lists:foreach(
      fun(Pid) when is_pid(Pid) ->
              case is_process_alive(Pid) of
                  true -> Pid ! stop;
                  false -> ok
              end;
         (_) -> ok
      end, [Engine, Worker]).

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
    ?assertEqual(decision, maps:get(kind, Dtx)),
    ?assertEqual([], maps:get(txs, Dtx)),
    Control = maps:get(control, Dtx),
    ?assertEqual(decision, maps:get(kind, Control)),
    ?assertEqual(abort, maps:get(verdict, Control)),
    ?assertEqual([<<"test_abort(dtx_fixture)">>], maps:get(reasons, Control)),
    ?assert(is_binary(quod_explorer_http:encode(Dtx))),
    ?assertEqual([], quod_explorer_http:entry_txs(DtxEntry)).

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
    Dir = filename:join("/tmp", "quod_explorer_eunit_" ++
                        integer_to_list(erlang:unique_integer([positive]))),
    {ok, Store0} = quod_ledger_store:open(<<"ont:test">>, Dir),
    try Fun(Store0) after file:del_dir_r(Dir) end.

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
        T = quod_transaction:bind_id(
              {Ns, Anchor},
              T0#transaction{
                tx_id = <<>>, origin = {Ns, <<22:256>>},
                proof_id = <<23:256>>, plan_digest = <<24:256>>,
                author_seq = 1}),
        {ok, Store0} = quod_ledger_store:open(Ns, LedgerDir),
        {ok, Store1} = quod_ledger_store:append(
                         Store0,
                         [#entry{index = 1, data = noop,
                                 timestamp = 2001, cert = none},
                          #entry{index = 2, data = {batch, [T]},
                                 timestamp = 2002, cert = none}]),
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

tx_json_full_test() ->
    J = quod_explorer_http:tx_json_full(
          <<"ont:target">>, tx(7), entry(2, [tx(7)])),
    ?assertMatch(#{height := 2, time := 2002, ops := 1, effect_count := 0,
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

effect_tx_json_is_explicit_and_does_not_claim_root_diff_test() ->
    Executor0 = <<77:256>>,
    Executor = case application:get_env(quod, node_pubkey) of
                   {ok, Executor0} -> <<78:256>>;
                   _ -> Executor0
               end,
    Effect = {quod_direct_effect, 1, local_durable,
              ontology_lifecycle, create, <<1:256>>, Executor,
              {user, <<2:256>>}, {<<"ont:new">>, <<3:256>>},
              <<4:256>>, <<5:256>>},
    T = (tx(9))#transaction{diff = [], effects = [Effect]},
    J = quod_explorer_http:tx_json_full(
          <<"ont:root">>, T, entry(4, [T])),
    ?assertEqual(false, maps:get(root_facts_changed, J)),
    ?assertEqual(1, maps:get(effect_count, J)),
    ?assertEqual([create], maps:get(effect_operations, J)),
    [Rendered] = maps:get(effects, J),
    ?assertMatch(#{operation := create,
                   actor := #{kind := user},
                   actor_authority := author_node_claimed,
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

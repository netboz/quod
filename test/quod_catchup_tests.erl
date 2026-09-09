-module(quod_catchup_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").
-include("quod_proof_limits.hrl").
-include("quod_transport_limits.hrl").

%%%===================================================================
%%% quod_catchup:serve_blocks/4 — the catch-up server's read path (read a committed block+cert range from
%%% a read-only store view, clamped to the height, a per-request count cap, AND a byte budget so the
%%% response fits one quod_link frame). The over-the-wire request/response is exercised end-to-end by the
%%% multi-node join CT.
%%%===================================================================

setup() ->
    Dir = filename:join("/tmp", "quod_catchup_test_" ++
                        binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    Ns  = <<"catchup:test">>,
    {ok, S0} = quod_ledger_store:open(Ns, Dir),
    %% entry 5 carries a real #cert{} — proving the cert (de)serializes through the store frame, which is
    %% exactly what a joiner reads back to verify the block.
    Cert = #cert{kind = commit, slot = 5, block_hash = crypto:hash(sha256, <<"blk5">>),
                 sigs = [{<<1, 2, 3>>, <<4, 5, 6>>}]},
    Es = [entry(I, {batch, [tx(I)]}, 0, none)
          || I <- lists:seq(1, 4)]
         ++ [entry(5, {batch, [tx(5)]}, 0, Cert)],
    {ok, S1} = quod_ledger_store:append(S0, Es),
    Snapshot = quod_ledger_store:snapshot(S1),
    ok = quod_ledger_store:close(S1),
    {Dir, Ns, Cert, Snapshot}.

cleanup({Dir, _, _, _}) -> _ = file:del_dir_r(Dir), ok.

tx(I) -> #transaction{tx_id = integer_to_binary(I), origin = {<<"catchup:test">>, <<0:256>>},
                      diff = [{assert, {{fact, I}, true}}], read_check = #{},
                      author = <<"a">>, sig = none}.

entry(Index, Data, Timestamp, Cert) ->
    {ok, Entry} = quod_ledger:new_entry(Index, Data, Timestamp, Cert),
    Entry.

serve_blocks_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun({_Dir, Ns, Cert, Snapshot}) ->
         [ %% a sub-range in index order, with the server's committed height
           ?_assertMatch({ok, [#entry{index = 2}, #entry{index = 3}, #entry{index = 4}], 5},
                         quod_catchup:serve_blocks(Ns, Snapshot, 2, 4)),
           %% To is clamped to the committed height
           ?_assertMatch({ok, [#entry{index = 1} | _], 5}, quod_catchup:serve_blocks(Ns, Snapshot, 1, 1000)),
           ?_assertEqual(5, length(element(2, quod_catchup:serve_blocks(Ns, Snapshot, 1, 1000)))),
           %% From beyond the tail ⇒ empty (nothing to send); From clamped to ≥ 1
           ?_assertMatch({ok, [], 5}, quod_catchup:serve_blocks(Ns, Snapshot, 10, 20)),
           ?_assertMatch({ok, [#entry{index = 1} | _], 5}, quod_catchup:serve_blocks(Ns, Snapshot, 0, 3)),
           %% the persisted cert round-trips intact through the store frame
           ?_assertMatch({ok, [#entry{index = 5, cert = Cert}], 5}, quod_catchup:serve_blocks(Ns, Snapshot, 5, 5)),
           %% A snapshot for another namespace is never a serving capability.
           ?_assertEqual({error, wrong_namespace}, quod_catchup:serve_blocks(<<"nope:x">>, Snapshot, 1, 1)) ]
     end}.

%% The byte budget caps the response so it fits one quod_link frame (1 MiB) — a window of large blocks is
%% returned as a shorter prefix (the joiner loops for the rest), never an oversized frame that kills the link.
byte_cap_test() ->
    Dir = filename:join("/tmp", "quod_catchup_big_" ++ integer_to_list(erlang:unique_integer([positive]))),
    Ns  = <<"catchup:big">>,
    Big = binary:copy(<<0>>, 200 * 1024),   %% ~200 KiB payload per entry
    _ = file:del_dir_r(Dir),
    try
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        Es = [entry(I,
                    {batch,
                     [#transaction{tx_id = integer_to_binary(I), origin = {Ns, <<0:256>>},
                                   diff = [{assert, {{blob, I}, Big}}], read_check = #{},
                                   author = <<"a">>, sig = none}]},
                    0, none)
              || I <- lists:seq(1, 8)],      %% 8 × ~200 KiB = ~1.6 MiB total, over the ~900 KiB budget
        {ok, S1} = quod_ledger_store:append(S0, Es),
        Snapshot = quod_ledger_store:snapshot(S1),
        ok = quod_ledger_store:close(S1),
        {ok, Served, 8} = quod_catchup:serve_blocks(Ns, Snapshot, 1, 1000),
        ?assert(length(Served) >= 1),      %% always makes progress
        ?assert(length(Served) < 8),       %% but byte-capped below the full window
        Bytes = lists:sum(
                  [begin
                       {ok, Blob} = quod_ledger:encode_entry(E),
                       byte_size(Blob)
                   end || E <- Served]),
        ?assert(Bytes < 1024 * 1024)       %% the served entries fit under quod_link's 1 MiB frame cap
    after
        _ = file:del_dir_r(Dir)
    end.

count_cap_serves_a_contiguous_prefix_test() ->
    Dir = filename:join("/tmp", "quod_catchup_count_" ++
                        binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    Ns = <<"catchup:count">>,
    {ok, Store0} = quod_ledger_store:open(Ns, Dir),
    try
        Height = ?QUOD_MAX_FOREIGN_PAGE_ENTRIES + 10,
        Entries = [entry(I, noop, 0, none) || I <- lists:seq(1, Height)],
        {ok, Store} = quod_ledger_store:append(Store0, Entries),
        {ok, Page, Height} = quod_catchup:serve_blocks(
                              Ns, quod_ledger_store:snapshot(Store), 1, Height),
        ?assertEqual(lists:seq(1, ?QUOD_MAX_FOREIGN_PAGE_ENTRIES),
                     [E#entry.index || E <- Page])
    after
        quod_ledger_store:close(Store0),
        _ = file:del_dir_r(Dir)
    end.

%% The frame decoder owns only the four raw wire grammars. Entry vocabulary
%% is decoded once by the receiving consumer, never by the link.
four_raw_page_grammars_test() ->
    Ns = <<"catchup:grammar">>, Grant = <<1:128>>, ReqId = <<2:128>>, Next = <<3:128>>,
    Terms = [{blocks_credit, Grant}, {blocks_req, Grant, ReqId, 1, 2},
             {blocks_resp_bytes, Grant, ReqId, [<<"opaque">>], 2, Next},
             {blocks_err, Grant, ReqId, not_ready, Next},
             {blocks_err, Grant, ReqId, server_error, Next}],
    lists:foreach(fun(Term) ->
        ?assertMatch({ok, Term, _},
                     quod_catchup:decode_frame(Ns, quod_catchup:encode_frame(Ns, Term)))
    end, Terms),
    Invalid = [{blocks_req, ReqId, 1, 2}, {blocks_req, Grant, make_ref(), 1, 2},
               {blocks_req, Grant, ReqId, 0, 2}, {blocks_req, Grant, ReqId, 2, 1},
               {blocks_credit, <<1>>}, {blocks_resp_bytes, Grant, ReqId, [], 2, Grant},
               {blocks_err, Grant, ReqId, timeout, Next}],
    lists:foreach(fun(Term) ->
        ?assertEqual({error, bad_frame}, quod_catchup:decode_frame(Ns, raw_frame(Ns, Term)))
    end, Invalid),
    %% Opaque wire blobs are intentionally not decoded at this boundary.
    ?assertEqual({error, bad_frame}, quod_catchup:decode_entries([<<"opaque">>], wrapped)).

canonical_outer_and_inner_frames_are_exact_test() ->
    Ns = <<"catchup:canonical">>,
    Term = {blocks_resp_bytes, <<1:128>>, <<2:128>>,
            [binary:copy(<<0>>, 2048)], 2, <<3:128>>},
    Inner = term_to_binary(Term, [deterministic]),
    Outer = raw_frame(Ns, Term),
    <<131, 104, 3, OuterFields/binary>> = Outer,
    Bad = [<<Outer/binary, 0>>,
           <<131, 105, 3:32, OuterFields/binary>>,
           term_to_binary({catchup, Ns, <<Inner/binary, 0>>}, [deterministic]),
           term_to_binary({catchup, Ns, Inner}, [compressed, deterministic]),
           term_to_binary({catchup, Ns, term_to_binary(Term, [compressed, deterministic])},
                          [deterministic]),
           raw_frame(<<"another:namespace">>, Term)],
    lists:foreach(fun(Frame) ->
        ?assertEqual({error, bad_frame}, quod_catchup:decode_frame(Ns, Frame))
    end, Bad),
    %% INTEGER_EXT for a small positive integer is valid ETF but not canonical.
    Canonical = term_to_binary({blocks_req, <<1:128>>, <<2:128>>, 1, 2}, [deterministic]),
    N = byte_size(Canonical) - 4,
    <<Prefix:N/binary, 97, 1, 97, 2>> = Canonical,
    Noncanonical = <<Prefix/binary, 98, 1:32/signed-big, 97, 2>>,
    ?assertEqual({error, bad_frame}, quod_catchup:decode_frame(
      Ns, term_to_binary({catchup, Ns, Noncanonical}, [deterministic]))).

page_count_bytes_and_frame_headroom_test() ->
    Ns = <<"catchup:bounds">>, Grant = <<1:128>>, ReqId = <<2:128>>, Next = <<3:128>>,
    AtCount = lists:duplicate(?QUOD_MAX_FOREIGN_PAGE_ENTRIES, <<>>),
    Page = fun(Blobs) -> {blocks_resp_bytes, Grant, ReqId, Blobs, 9, Next} end,
    ?assertMatch({ok, _, _}, quod_catchup:decode_frame(Ns, raw_frame(Ns, Page(AtCount)))),
    ?assertEqual({error, bad_frame}, quod_catchup:decode_frame(
      Ns, raw_frame(Ns, Page([<<>> | AtCount])))),
    AtBytes = [binary:copy(<<0>>, ?QUOD_MAX_FOREIGN_PAGE_BYTES)],
    Frame = quod_catchup:encode_frame(Ns, Page(AtBytes)),
    ?assert(byte_size(Frame) < ?QUOD_TRANSPORT_MAX_FRAME_BYTES),
    ?assertMatch({ok, _, _}, quod_catchup:decode_frame(Ns, Frame)),
    ?assertEqual({error, bad_frame}, quod_catchup:decode_frame(
      Ns, raw_frame(Ns, Page([<<1>> | AtBytes])))),
    ?assertEqual({error, frame_too_large}, quod_catchup:decode_frame(
      Ns, binary:copy(<<0>>, ?QUOD_TRANSPORT_MAX_FRAME_BYTES + 1))),
    ?assertEqual({error, bad_frame}, quod_catchup:decode_entries(
      lists:duplicate(?QUOD_MAX_FOREIGN_PAGE_ENTRIES + 1, <<>>), materialized)).

foreign_response_keeps_unknown_vocabulary_opaque_test() ->
    Ns = <<"catchup:opaque-response">>,
    Name = <<"quod_r3_catchup_", (binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>,
    Symbol = {'$quod_symbol', Name},
    Transaction = #transaction{
      tx_id = <<12:256>>, origin = {Ns, <<0:256>>},
      diff = [{assert, {{Symbol, value}, {[], false}}}], read_check = #{},
      author = <<13:256>>, sig = none, signed_bytes = none},
    {ok, TransactionBytes} = quod_transaction:encode_ledger_transaction(Transaction),
    {ok, BlockBytes} = quod_safe_term:encode_canonical(
      {quod_block, 1, 1, 0, {batch, [{transaction, TransactionBytes}]}, 0}, 1024 * 1024),
    Entry = #entry{index = 1, data = {batch, [Transaction]}, timestamp = 0,
                   block_bytes = BlockBytes, cert = none},
    {ok, Blob} = quod_ledger:encode_entry(Entry),
    Grant = <<1:128>>, ReqId = <<2:128>>, Next = <<3:128>>,
    Frame = quod_catchup:encode_frame(
      Ns, {blocks_resp_bytes, Grant, ReqId, [Blob], 1, Next}),
    ?assertException(error, badarg, binary_to_existing_atom(Name, utf8)),
    {ok, {blocks_resp_bytes, Grant, ReqId, Blobs, 1, Next}, _} =
        quod_catchup:decode_frame(Ns, Frame),
    {ok, [Decoded]} = quod_catchup:decode_entries(Blobs, wrapped),
    ?assertMatch(#entry{data = {batch, [#transaction{
      diff = [{assert, {{Symbol, value}, {[], false}}}]}]}}, Decoded),
    ?assertException(error, badarg, binary_to_existing_atom(Name, utf8)),
    ?assertEqual({error, bad_frame},
                 quod_catchup:decode_entries([<<Blob/binary, 0>>], wrapped)),
    <<131, EntryBody/binary>> = Blob,
    Compressed = <<131, 80, (byte_size(EntryBody)):32,
                   (zlib:compress(EntryBody))/binary>>,
    ?assertEqual({error, bad_frame}, quod_catchup:decode_entries([Compressed], wrapped)).

%% These tests run the actual endpoint and its linked/monitored reader. The
%% link stub models only authenticated link callbacks, not grant validation.
same_link_response_waits_for_reader_down_and_send_acceptance_test() ->
    with_endpoint(fun(#{endpoint := Endpoint, ns := Ns}) ->
        with_link(fun(Link) ->
            {Op, Worker} = held_reader(Endpoint, Link, after_result),
            Rows = readers(Endpoint),
            ?assertMatch(#{worker := Worker, result := {ok, _, 5}}, maps:get(Op, Rows)),
            assert_no_complete(Link),
            ?assert(is_process_alive(Worker)),
            Worker ! {release_reader, Op},
            {ok, Blobs, 5} = expect_complete(Link, Endpoint, Op),
            ?assertMatch({ok, [#entry{index = 2}, #entry{index = 3}]},
                         quod_catchup:decode_entries(Blobs, materialized)),
            ?assertNot(is_process_alive(Worker)),
            ?assertMatch(#{worker := none}, maps:get(Op, readers(Endpoint))),
            ?assertEqual(1, maps:get(server_inflight, quod_catchup:stats(Ns))),
            Link ! {accept_page, Endpoint, Op},
            await_readers(Endpoint, 0),
            ?assertEqual(1, maps:get(server_inflight_peak, quod_catchup:stats(Ns)))
        end)
    end).

expired_link_admission_does_not_start_a_reader_test() ->
    with_endpoint(fun(#{endpoint := Endpoint}) ->
        with_link(fun(Link) ->
            ok = quod_catchup:test_hold_next_reader(Endpoint, before_read, self()),
            Op = make_ref(),
            %% The timestamp belongs to link grant admission, not the later
            %% endpoint mailbox turn. An already-spent budget opens no view.
            Endpoint ! {catchup_request, Link, Op, 2, 3, quod_time:mono_ms() - 8001},
            ?assertEqual({error, not_ready}, expect_complete(Link, Endpoint, Op)),
            ?assertMatch(#{worker := none}, maps:get(Op, readers(Endpoint))),
            receive {reader_held, _, Op, _} -> error(expired_admission_started_reader)
            after 0 -> ok
            end,
            Link ! {accept_page, Endpoint, Op},
            await_readers(Endpoint, 0)
        end)
    end).

source_death_after_result_cannot_publish_captured_page_test() ->
    with_endpoint(fun(#{endpoint := Endpoint, source := Source}) ->
        with_link(fun(Link) ->
            {Op, Worker} = held_reader(Endpoint, Link, after_result),
            ?assertMatch(#{result := {ok, _, _}}, maps:get(Op, readers(Endpoint))),
            Monitor = monitor(process, Worker),
            exit(Source, kill),
            await_down(Worker, Monitor),
            ?assertEqual({error, not_ready}, expect_complete(Link, Endpoint, Op)),
            Link ! {accept_page, Endpoint, Op},
            await_readers(Endpoint, 0)
        end)
    end).

link_death_releases_held_reader_test() ->
    with_endpoint(fun(#{endpoint := Endpoint}) ->
        with_link(fun(Link) ->
            {_Op, Worker} = held_reader(Endpoint, Link, before_read),
            Monitor = monitor(process, Worker),
            exit(Link, kill),
            await_down(Worker, Monitor),
            await_readers(Endpoint, 0),
            assert_no_complete(Link)
        end)
    end).

endpoint_kill_releases_held_reader_test() ->
    with_endpoint(fun(#{endpoint := Endpoint}) ->
        with_link(fun(Link) ->
            {_Op, Worker} = held_reader(Endpoint, Link, before_read),
            Monitor = monitor(process, Worker),
            exit(Endpoint, kill),
            await_down(Worker, Monitor),
            assert_no_complete(Link)
        end)
    end).

more_than_32_links_retain_and_retire_all_readers_test() ->
    with_endpoint(fun(#{endpoint := Endpoint, source := Source, ns := Ns}) ->
        Links = [start_link_stub() || _ <- lists:seq(1, 40)],
        try
            Source ! {pause_captures, self()},
            receive {source_paused, Source} -> ok after 1000 -> error(source_not_paused) end,
            Pages = [{Link, make_ref()} || Link <- Links],
            lists:foreach(fun({Link, Op}) ->
                Endpoint ! {catchup_request, Link, Op, 2, 3, quod_time:mono_ms()}
            end, Pages),
            %% The source is genuinely busy: all forty readers have issued
            %% their owner capture, not merely been put behind a test gate.
            await(fun() ->
                {messages, Messages} = process_info(Source, messages),
                length([ok || {'$gen_call', _, {history_view, _, _, _}} <- Messages]) =:= 40
            end),
            ?assertEqual(40, map_size(readers(Endpoint))),
            ?assertEqual(40, maps:get(server_inflight_peak, quod_catchup:stats(Ns))),
            lists:foreach(fun({Link, _}) -> assert_no_complete(Link) end, Pages),
            Source ! resume_captures,
            lists:foreach(fun({Link, Op}) ->
                ?assertMatch({ok, [_ | _], 5}, expect_complete(Link, Endpoint, Op)),
                Link ! {accept_page, Endpoint, Op}
            end, Pages),
            await_readers(Endpoint, 0)
        after lists:foreach(fun stop_process/1, Links)
        end
    end).

queued_pulls_share_one_identified_link_and_grants_fifo_test() ->
    with_endpoint(fun(#{endpoint := Endpoint, ns := Ns}) ->
        with_link(fun(Link) ->
            Contact = {"127.0.0.1", 14570}, Peer = <<10:256>>,
            quod_quic:ensure_cache(),
            _ = ets:delete(quod_addr_cache, Peer),
            try
                First = start_pull(Ns, 1, 1, Contact),
                {OpenRef, Chan} = expect_open(Endpoint, Contact, identified),
                Second = start_pull(Ns, 2, 2, Contact),
                await_pending(Ns, 2),
                ?assertEqual(1, map_size(maps:get(openings, recovery(Endpoint)))),
                assert_no_open(),
                Endpoint ! {link_up, OpenRef, Peer, Chan, Link},
                Binding = expect_binding(Link, Endpoint),
                ?assertEqual({ok, Contact}, quod_quic:resolve(Peer)),
                assert_no_request(Link),
                Grant1 = <<1:128>>, Grant2 = <<2:128>>, Grant3 = <<3:128>>,
                Endpoint ! {catchup_credit, Link, Binding, Grant1},
                Req1 = expect_request(Link, Endpoint, Binding, Grant1, 1, 1),
                assert_no_request(Link),
                %% Wrong correlation cannot complete the first pull or dispatch the second.
                Endpoint ! {catchup_page, Link, Binding, <<99:128>>, Req1,
                            {error, server_error}, Grant2},
                ?assertEqual(2, maps:get(client_pending, quod_catchup:stats(Ns))),
                assert_no_request(Link),
                Endpoint ! {catchup_page, Link, Binding, Grant1, Req1,
                            {ok, [], 5}, Grant2},
                ?assertEqual({ok, [], 5}, pull_result(First)),
                Req2 = expect_request(Link, Endpoint, Binding, Grant2, 2, 2),
                ?assertNotEqual(Req1, Req2),
                assert_no_open(),
                Endpoint ! {catchup_page, Link, Binding, Grant2, Req2,
                            {error, server_error}, Grant3},
                ?assertEqual({error, server_error}, pull_result(Second)),
                await_pending(Ns, 0)
            after _ = ets:delete(quod_addr_cache, Peer)
            end
        end)
    end).

expired_queued_pull_creates_no_borrower_or_open_test() ->
    with_endpoint(fun(#{endpoint := Endpoint, ns := Ns}) ->
        Contact = <<17:256>>,
        Parent = self(),
        ok = sys:suspend(Endpoint),
        Caller = spawn(fun() ->
            Result = gen_server:call(
                       Endpoint, {pull, 1, 2, Contact, quod_time:mono_ms() - 8001}, 2000),
            Parent ! {pull_result, self(), Result},
            receive stop -> ok end
        end),
        try
            await_queued_pull(Endpoint, Caller),
            ok = sys:resume(Endpoint),
            ?assertEqual({error, timeout}, pull_result(Caller)),
            ?assert(is_process_alive(Caller)),
            assert_no_pull_admission(Endpoint, Ns)
        after
            _ = catch sys:resume(Endpoint),
            stop_process(Caller)
        end
    end).

dead_queued_pull_caller_creates_no_borrower_or_open_test() ->
    with_endpoint(fun(#{endpoint := Endpoint, ns := Ns}) ->
        ok = sys:suspend(Endpoint),
        Caller = start_pull(Ns, 1, 2, <<18:256>>),
        try
            %% Exercise public pull/4: its real call, including StartedMs,
            %% is already queued before the original caller disappears.
            await_queued_pull(Endpoint, Caller),
            Monitor = monitor(process, Caller),
            exit(Caller, kill),
            await_down(Caller, Monitor),
            ok = sys:resume(Endpoint),
            assert_no_pull_admission(Endpoint, Ns)
        after
            _ = catch sys:resume(Endpoint),
            stop_process(Caller)
        end
    end).

retired_open_failure_does_not_strand_the_surviving_borrower_test() ->
    with_endpoint(fun(#{endpoint := Endpoint, ns := Ns}) ->
        with_link(fun(Link) ->
            Contact = <<19:256>>,
            First = start_pull(Ns, 1, 1, Contact),
            {OldOpen, Chan} = expect_open(Endpoint, Contact, ordinary),
            Monitor = monitor(process, First),
            exit(First, kill),
            await_down(First, Monitor),
            await(fun() ->
                Bindings = maps:get(bindings, recovery(Endpoint)),
                lists:any(fun(#{retiring := Retiring, borrowers := Borrowers}) ->
                                  Retiring andalso Borrowers =:= 0
                          end, maps:values(Bindings))
            end),
            Parent = self(),
            Survivor = spawn(fun() -> recovery_client(Parent, Ns, Contact) end),
            try
                Survivor ! {pull, 2, 2},
                await_pending(Ns, 1),
                ?assert(maps:is_key(OldOpen, maps:get(openings, recovery(Endpoint)))),
                assert_no_open(),
                Endpoint ! {link_error, OldOpen, Contact, Chan},
                %% Preserve the existing failed-open result. A subsequent
                %% explicit request, not an automatic retry, owns the next turn.
                ?assertEqual({error, link_down}, pull_result(Survivor)),
                ?assert(is_process_alive(Survivor)),
                Survivor ! {pull, 3, 3},
                {NewOpen, Chan} = expect_open(Endpoint, Contact, ordinary),
                ?assertNotEqual(OldOpen, NewOpen),
                Endpoint ! {link_up, NewOpen, Contact, Chan, Link},
                Binding = expect_binding(Link, Endpoint),
                Grant = <<21:128>>, Next = <<22:128>>,
                Endpoint ! {catchup_credit, Link, Binding, Grant},
                Req = expect_request(Link, Endpoint, Binding, Grant, 3, 3),
                Endpoint ! {catchup_page, Link, Binding, Grant, Req, {ok, [], 5}, Next},
                ?assertEqual({ok, [], 5}, pull_result(Survivor)),
                await_pending(Ns, 0)
            after stop_process(Survivor)
            end
        end)
    end).

recovery_caller_retains_one_link_between_pages_until_it_exits_test() ->
    with_endpoint(fun(#{endpoint := Endpoint, ns := Ns}) ->
        with_link(fun(Link) ->
            Peer = <<14:256>>,
            Parent = self(),
            Client = spawn(fun() -> recovery_client(Parent, Ns, Peer) end),
            try
                Client ! {pull, 1, 1},
                {OpenRef, Chan} = expect_open(Endpoint, Peer, ordinary),
                Endpoint ! {link_up, OpenRef, Peer, Chan, Link},
                Binding = expect_binding(Link, Endpoint),
                Grant1 = <<1:128>>, Grant2 = <<2:128>>, Grant3 = <<3:128>>,
                Endpoint ! {catchup_credit, Link, Binding, Grant1},
                Req1 = expect_request(Link, Endpoint, Binding, Grant1, 1, 1),
                Endpoint ! {catchup_page, Link, Binding, Grant1, Req1, {ok, [], 5}, Grant2},
                ?assertEqual({ok, [], 5}, pull_result(Client)),
                await_pending(Ns, 0),
                ?assert(is_process_alive(Link)),
                Client ! {pull, 2, 2},
                Req2 = expect_request(Link, Endpoint, Binding, Grant2, 2, 2),
                assert_no_open(),
                Endpoint ! {catchup_page, Link, Binding, Grant2, Req2, {ok, [], 5}, Grant3},
                ?assertEqual({ok, [], 5}, pull_result(Client)),
                LinkMonitor = monitor(process, Link),
                stop_process(Client),
                await_down(Link, LinkMonitor)
            after stop_process(Client)
            end
        end)
    end).

ordinary_keyed_pull_uses_the_ordinary_pool_test() ->
    with_endpoint(fun(#{endpoint := Endpoint, ns := Ns}) ->
        Peer = <<15:256>>,
        Pull = start_pull(Ns, 1, 2, Peer),
        {OpenRef, Chan} = expect_open(Endpoint, Peer, ordinary),
        Endpoint ! {link_error, OpenRef, Peer, Chan},
        ?assertMatch({error, _}, pull_result(Pull)),
        await_pending(Ns, 0)
    end).

failed_identified_open_cannot_bind_a_late_link_test() ->
    with_endpoint(fun(#{endpoint := Endpoint, ns := Ns}) ->
        with_link(fun(Link) ->
            Contact = {"127.0.0.1", 14571},
            Pull = start_pull(Ns, 1, 2, Contact),
            {OpenRef, Chan} = expect_open(Endpoint, Contact, identified),
            Endpoint ! {link_error, OpenRef, Contact, Chan},
            ?assertMatch({error, _}, pull_result(Pull)),
            Endpoint ! {link_up, OpenRef, <<11:256>>, Chan, Link},
            ?assertEqual(#{}, maps:get(openings, recovery(Endpoint))),
            receive {link_event, Link, {bind_catchup, _, _}} -> error(late_link_bound)
            after 30 -> ok
            end,
            assert_no_request(Link)
        end)
    end).

raw_frame(Ns, Term) ->
    term_to_binary({catchup, Ns, term_to_binary(Term, [deterministic])}, [deterministic]).

with_endpoint(Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    Fixture = {Dir, Ns, _Cert, _Snapshot} = setup(),
    Parent = self(),
    Source = spawn(fun() ->
        {ok, Store} = quod_ledger_store:open(Ns, Dir),
        try
            true = quod_reg:reg({quod_simplex, Ns}),
            State = quod_simplex:test_state(#{ns => Ns, genesis_hash => <<0:256>>,
              store => Store, slot => 5, last_applied => 0, sync => ready,
              prolog_ready => false}),
            Parent ! {source_ready, self()},
            source_loop(State)
        after quod_ledger_store:close(Store)
        end
    end),
    try
        receive {source_ready, Source} -> ok after 2000 -> error(source_not_ready) end,
        Transport = spawn(fun() ->
            true = quod_reg:reg({transport, node}),
            Parent ! {transport_ready, self()},
            transport_loop(Parent)
        end),
        try
            receive {transport_ready, Transport} -> ok after 2000 -> error(transport_not_ready) end,
            {ok, Endpoint} = quod_catchup:start_link(
                               Ns, #{node_id => <<0:256>>, seed_peers => []}),
            unlink(Endpoint),
            try Fun(#{endpoint => Endpoint, source => Source, ns => Ns})
            after stop_endpoint(Endpoint)
            end
        after stop_process(Transport)
        end
    after
        stop_process(Source),
        cleanup(Fixture)
    end.

source_loop(State) ->
    receive
        {pause_captures, Caller} ->
            Caller ! {source_paused, self()},
            receive resume_captures -> source_loop(State) end;
        {'$gen_call', From, {history_view, Identity, Requirement, Deadline}} ->
            gen:reply(From, quod_simplex:test_local_history_view(
                             Identity, Requirement, Deadline, State)),
            source_loop(State);
        stop -> ok
    end.

transport_loop(Parent) ->
    receive
        {'$gen_cast', Request} -> Parent ! {transport_event, Request}, transport_loop(Parent);
        stop -> ok
    end.

start_link_stub() ->
    Parent = self(),
    spawn(fun() -> link_loop(Parent) end).
with_link(Fun) ->
    Link = start_link_stub(),
    try Fun(Link) after stop_process(Link) end.
link_loop(Parent) ->
    receive
        {accept_page, Endpoint, Op} ->
            Endpoint ! {catchup_page_sent, self(), Op},
            link_loop(Parent);
        {sync, Caller, Ref} ->
            Caller ! {link_synced, self(), Ref},
            link_loop(Parent);
        stop -> ok;
        close -> ok;
        Message -> Parent ! {link_event, self(), Message}, link_loop(Parent)
    end.

held_reader(Endpoint, Link, Point) ->
    ok = quod_catchup:test_hold_next_reader(Endpoint, Point, self()),
    Op = make_ref(),
    Endpoint ! {catchup_request, Link, Op, 2, 3, quod_time:mono_ms()},
    receive {reader_held, Worker, Op, Point} ->
        await(fun() ->
            case maps:find(Op, readers(Endpoint)) of
                {ok, #{result := Result}} -> Point =:= before_read orelse Result =/= none;
                error -> false
            end
        end),
        {Op, Worker}
    after 2000 -> error(reader_not_held)
    end.

expect_complete(Link, Endpoint, Op) ->
    receive {link_event, Link, {complete_page, Endpoint, Op, Result}} -> Result
    after 2000 -> error({missing_page_completion, Op})
    end.
assert_no_complete(Link) ->
    receive {link_event, Link, {complete_page, _, _, _}} -> error(response_before_reader_down)
    after 0 -> ok
    end.

recovery(Endpoint) -> quod_catchup:test_recovery_state(Endpoint).
readers(Endpoint) -> maps:get(readers, recovery(Endpoint)).
await_queued_pull(Endpoint, Caller) ->
    await(fun() ->
        {messages, Messages} = process_info(Endpoint, messages),
        lists:any(fun({'$gen_call', {Pid, _}, {pull, _, _, _, Started}}) ->
                          Pid =:= Caller andalso is_integer(Started);
                     (_) -> false
                  end, Messages)
    end).
assert_no_pull_admission(Endpoint, Ns) ->
    State = recovery(Endpoint),
    ?assertEqual(#{}, maps:get(contacts, State)),
    ?assertEqual(#{}, maps:get(openings, State)),
    ?assertEqual(#{}, maps:get(bindings, State)),
    ?assertEqual(0, maps:get(client_pending, quod_catchup:stats(Ns))),
    ?assertEqual(0, maps:get(client_pending_peak, quod_catchup:stats(Ns))),
    receive {transport_event, Event} -> error({unadmitted_pull_opened_transport, Event})
    after 30 -> ok
    end.
await_readers(Endpoint, Count) ->
    await(fun() -> map_size(readers(Endpoint)) =:= Count end).
await_pending(Ns, Count) ->
    await(fun() -> maps:get(client_pending, quod_catchup:stats(Ns)) =:= Count end).
await(Check) -> await(Check, quod_time:mono_ms() + 2000).
await(Check, Deadline) ->
    case Check() of
        true -> ok;
        false ->
            case quod_time:mono_ms() < Deadline of
                true -> receive after 1 -> await(Check, Deadline) end;
                false -> error(state_did_not_converge)
            end
    end.

start_pull(Ns, From, To, Contact) ->
    Parent = self(),
    spawn(fun() -> Parent ! {pull_result, self(), quod_catchup:pull(Ns, From, To, Contact)} end).
recovery_client(Parent, Ns, Contact) ->
    receive
        {pull, From, To} ->
            Parent ! {pull_result, self(), quod_catchup:pull(Ns, From, To, Contact)},
            recovery_client(Parent, Ns, Contact);
        stop -> ok
    end.
pull_result(Pid) ->
    receive {pull_result, Pid, Result} -> Result
    after 2000 -> error(pull_did_not_complete)
    end.
expect_open(Endpoint, Contact, Pool) ->
    Kind = case Pool of identified -> open_link_identified; ordinary -> open_link end,
    receive {transport_event, {Kind, Contact, Chan, {Endpoint, OpenRef}}} ->
        {OpenRef, Chan}
    after 2000 -> error({missing_transport_open, Pool})
    end.
assert_no_open() ->
    receive {transport_event, Event} -> error({extra_transport_request, Event})
    after 0 -> ok
    end.
expect_binding(Link, Endpoint) ->
    receive {link_event, Link, {bind_catchup, Endpoint, Binding}} -> Binding
    after 2000 -> error(link_not_bound)
    end.
expect_request(Link, Endpoint, Binding, Grant, From, To) ->
    receive {link_event, Link, {request_page, Endpoint, Binding, Grant, ReqId, From, To}} -> ReqId
    after 2000 -> error(missing_fifo_page_request)
    end.
assert_no_request(Link) ->
    receive {link_event, Link, {request_page, _, _, _, _, _, _}} -> error(uncredited_page)
    after 0 -> ok
    end.

stop_endpoint(Pid) ->
    case is_process_alive(Pid) of
        true -> _ = catch gen_server:stop(Pid, normal, 2000);
        false -> ok
    end.
stop_process(Pid) ->
    Monitor = monitor(process, Pid),
    Pid ! stop,
    receive {'DOWN', Monitor, process, Pid, _} -> ok
    after 1000 -> exit(Pid, kill), await_down(Pid, Monitor)
    end.
await_down(Pid, Monitor) ->
    receive {'DOWN', Monitor, process, Pid, _} -> ok
    after 2000 -> error({process_did_not_stop, Pid})
    end.

%% Cold recovery begins with endpoint seeds, not pubkey resolver hints. Candidate discovery must keep the
%% endpoint form (so a direct authenticated pull can teach the hint), exclude self, deduplicate, and cap.
contact_candidates_test() ->
    Ns = <<"catchup:no-process">>,
    Self = {"127.0.0.1", 14567},
    A = {"10.0.0.1", 1001}, B = {"10.0.0.2", 1002},
    application:set_env(quod, node_addr, Self),
    try
        Candidates = quod_catchup:contact_candidates(Ns, [Self, A, A, B], 8),
        ?assertEqual(lists:sort([A, B]), lists:sort(Candidates)),
        ?assertEqual(1, length(quod_catchup:contact_candidates(Ns, [A, B], 1)))
    after
        application:unset_env(quod, node_addr)
    end.

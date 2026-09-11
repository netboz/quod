-module(quod_ledger_store_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").
-include("quod_ledger.hrl").

-define(V1_MAGIC, 16#915106AA).
-define(V2_MAGIC, 16#915106AB).
-define(V3_MAGIC, 16#915106AC).
-define(V4_MAGIC, 16#915106AD).
-define(V5_MAGIC, 16#915106AE).
-define(MAGIC, 16#915106AF).
-define(READ_CHUNK, 262144).

%% Every superseded frame magic must be rejected as an identifiable format, at
%% its exact offset, without mutating the file. Each legacy case below runs for
%% all of them.
legacy_formats() -> [{1, ?V1_MAGIC}, {2, ?V2_MAGIC}, {3, ?V3_MAGIC},
                     {4, ?V4_MAGIC}, {5, ?V5_MAGIC}].

%%%===================================================================
%%% fixtures
%%%===================================================================

setup() ->
    Dir = filename:join("/tmp", "quod_store_test_" ++
                        integer_to_list(erlang:unique_integer([positive]))),
    {Dir, <<"onia:peers">>}.   %% an Ns containing ':' to exercise base64url

cleanup({Dir, _Ns}) ->
    _ = file:del_dir_r(Dir),
    ok.

%% Each test is a single synchronous fun (immediate asserts): the store's raw fd
%% is process-bound, so all I/O must happen in the test process before close.
store_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [fun t_empty/1,
      fun t_append_read/1,
      fun t_opaque_payload_roundtrip/1,
      fun t_wrapped_foreign_store_never_materializes_symbols/1,
      fun t_reopen_persists/1,
      fun t_read_snapshot_preserves_verified_index/1,
      fun t_read_snapshot_accepts_append_but_refuses_truncation/1,
      fun t_resume_snapshot_appends_without_rescan/1,
      fun t_resume_snapshot_refuses_a_changed_file/1,
      fun t_torn_tail_recovery/1,
      fun t_torn_tail_bad_crc_trims/1,
      fun t_interior_corruption_fail_stops/1,
      fun t_chunked_tail_detects_distant_magic/1,
      fun t_chunked_tail_detects_split_magic/1,
      fun t_chunked_marker_free_tail_trims/1,
      fun t_open_ro_reads/1,
      fun t_traced_open_profiles_scan_without_per_entry_spans/1,
      fun t_traced_append_separates_encode_write_and_sync/1,
      fun t_open_ro_non_truncating/1,
      fun t_checkpointed_reads/1,
      fun t_trim_across_checkpoints/1,
      fun t_rejects_wrong_first_index/1,
      fun t_fold_beyond_tail/1,
      fun t_huge_len_tail_trimmed/1,
      fun t_legacy_format_fails_without_mutation/1,
      fun t_legacy_tail_fails_without_mutation/1,
      fun t_short_legacy_header_fails_without_mutation/1,
      fun t_short_legacy_tail_fails_without_mutation/1,
      fun t_corrupt_current_before_legacy_fails_without_mutation/1]}.

%%%===================================================================
%%% helpers
%%%===================================================================

ent(I) ->
    {ok, Entry} = quod_ledger:new_entry(I, data(I), 0, none),
    Entry.

entry_index(Entry) -> (quod_ledger:entry_view(Entry))#entry.index.
entry_data(Entry) -> (quod_ledger:entry_view(Entry))#entry.data.
read_view({ok, Entry}) -> {ok, quod_ledger:entry_view(Entry)};
read_view(Other) -> Other.

data(I) -> {batch, [chg(I)]}.

chg(I) ->
    #transaction{tx_id = integer_to_binary(I), origin = {<<"onia:peers">>, <<0:256>>},
            diff = [{assert, {{fact, I}, true}}], read_check = #{},
            author = <<1:256>>, sig = none}.

%%%===================================================================
%%% tests
%%%===================================================================

t_empty({Dir, Ns}) ->
    fun() ->
        {ok, S} = quod_ledger_store:open(Ns, Dir),
        ?assertEqual(0, quod_ledger_store:last(S)),
        ?assertEqual(not_found, quod_ledger_store:read_at(S, 1)),
        ok = quod_ledger_store:close(S)
    end.

t_append_read({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, [ent(1), ent(2), ent(3)]),
        ?assertEqual(3, quod_ledger_store:last(S1)),
        {ok, [E1, E2, E3]} = quod_ledger_store:read_range(S1, 1, 3),
        ?assertEqual(1, entry_index(E1)),
        ?assertEqual(2, entry_index(E2)),
        ?assertEqual(3, entry_index(E3)),
        {ok, E2b} = quod_ledger_store:read_at(S1, 2),
        ?assertEqual(data(2), entry_data(E2b)),
        %% a non-contiguous append is rejected (the store is append-only, in slot order)
        ?assertError({non_contiguous_append, 3, [5]}, quod_ledger_store:append(S1, [ent(5)])),
        ok = quod_ledger_store:close(S1)
    end.

%% The store persists the ledger's canonical envelope unchanged; application
%% bytes inside a transaction remain byte-exact across reopen.
t_opaque_payload_roundtrip({Dir, Ns}) ->
    fun() ->
        Opaque = <<0, 1, 2, 255>>,
        Data = {batch, [(chg(1))#transaction{
                           diff = [{assert, {{fact, Opaque}, true}}]}]},
        {ok, Entry} = quod_ledger:new_entry(1, Data, 0, none),
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, [Entry]),
        {ok, ExpectedEnvelope} = quod_ledger:encode_entry(Entry),
        LogPath = filename:join([Dir, base64url(Ns), "log.0001"]),
        {ok, <<?MAGIC:32, Length:32, CRC:32, StoredEnvelope:Length/binary>>} =
            file:read_file(LogPath),
        ?assertEqual(ExpectedEnvelope, StoredEnvelope),
        ?assertEqual(CRC, erlang:crc32(StoredEnvelope)),
        {ok, Stored} = quod_ledger_store:read_at(S1, 1),
        ?assertEqual(Data, entry_data(Stored)),
        ok = quod_ledger_store:close(S1),
        {ok, S2} = quod_ledger_store:open(Ns, Dir),
        {ok, Reopened} = quod_ledger_store:read_at(S2, 1),
        ?assertEqual(Data, entry_data(Reopened)),
        ok = quod_ledger_store:close(S2)
    end.

%% The foreign-log cache owns opaque decoded views. Its symbol mode must
%% survive the immutable session handoff between verification workers.
t_wrapped_foreign_store_never_materializes_symbols({Dir, Ns}) ->
    fun() ->
        Name = <<"quod_r3_store_", (binary:encode_hex(
                                     crypto:strong_rand_bytes(8)))/binary>>,
        Symbol = {'$quod_symbol', Name},
        Transaction = (chg(1))#transaction{
                        diff = [{assert,
                                 {{Symbol, value}, {[], false}}}]},
        {ok, TransactionBytes} =
            quod_transaction:encode_ledger_transaction(Transaction),
        {ok, BlockBytes} = quod_safe_term:encode_canonical(
                             {quod_block, 1, 1, 0,
                              {batch, [{transaction, TransactionBytes}]}, 0},
                             1024 * 1024),
        {ok, Entry} = quod_ledger:from_entry_view(
                       #entry{index = 1, data = {batch, [Transaction]},
                              timestamp = 0, block_bytes = BlockBytes, cert = none}),
        ?assertException(error, badarg,
                         binary_to_existing_atom(Name, utf8)),
        {ok, S0} = quod_ledger_store:open(Ns, Dir, wrapped),
        {ok, S1} = quod_ledger_store:append(S0, [Entry]),
        Session = quod_ledger_store:snapshot(S1),
        ok = quod_ledger_store:close(S1),
        {ok, S2} = quod_ledger_store:resume(Session),
        ?assertMatch(
           {ok,
            #entry{data =
                     {batch,
                      [#transaction{
                         diff = [{assert,
                                  {{Symbol, value}, {[], false}}}]}]}}},
           read_view(quod_ledger_store:read_at(S2, 1))),
        ok = quod_ledger_store:close(S2),
        ?assertException(error, badarg,
                         binary_to_existing_atom(Name, utf8))
    end.

t_reopen_persists({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, [ent(1), ent(2)]),
        ok = quod_ledger_store:close(S1),
        {ok, S2} = quod_ledger_store:open(Ns, Dir),
        ?assertEqual(2, quod_ledger_store:last(S2)),
        ?assertMatch({ok, [_, _]}, quod_ledger_store:read_range(S2, 1, 2)),
        ok = quod_ledger_store:close(S2)
    end.

%% Catch-up workers reuse the writer's verified sparse index but open their own
%% raw descriptor, preserving the one-process ownership rule.
t_read_snapshot_preserves_verified_index({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, [ent(1), ent(2), ent(3)]),
        Session = quod_ledger_store:snapshot(S1),
        {ok, S2} = quod_ledger_store:open_ro_snapshot(Session),
        ?assertEqual(Ns, quod_ledger_store:namespace(S2)),
        ?assertEqual(3, quod_ledger_store:last(S2)),
        ?assertMatch({ok, #entry{index = 2}},
                     read_view(quod_ledger_store:read_at(S2, 2))),
        ok = quod_ledger_store:close(S2),
        ok = quod_ledger_store:close(S1)
    end.

%% Later appends cannot widen a captured view; truncating its committed prefix
%% makes it unusable.
t_read_snapshot_accepts_append_but_refuses_truncation({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, [ent(1)]),
        Session = quod_ledger_store:snapshot(S1),
        {ok, S2} = quod_ledger_store:append(S1, [ent(2)]),
        {ok, View} = quod_ledger_store:open_ro_snapshot(Session),
        ?assertEqual(1, quod_ledger_store:last(View)),
        ?assertEqual(not_found, quod_ledger_store:read_at(View, 2)),
        ok = quod_ledger_store:close(View),
        ok = quod_ledger_store:close(S2),
        LogPath = filename:join([Dir, base64url(Ns), "log.0001"]),
        {ok, Fd} = file:open(LogPath, [write, raw, binary]),
        ok = file:truncate(Fd),
        ok = file:close(Fd),
        ?assertEqual({error, changed},
                     quod_ledger_store:open_ro_snapshot(Session))
    end.

%% The foreign-history owner hands this immutable session between consecutive
%% workers. Resuming must preserve the verified index and remain appendable.
t_resume_snapshot_appends_without_rescan({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, [ent(1), ent(2)]),
        Session = quod_ledger_store:snapshot(S1),
        ok = quod_ledger_store:close(S1),
        {ok, S2} = quod_ledger_store:resume(Session),
        ?assertEqual(2, quod_ledger_store:last(S2)),
        {ok, S3} = quod_ledger_store:append(S2, [ent(3)]),
        ?assertMatch({ok, #entry{index = 3}},
                     read_view(quod_ledger_store:read_at(S3, 3))),
        ok = quod_ledger_store:close(S3)
    end.

%% A stale session never overwrites or trims work performed after it was
%% captured. The ordinary open path remains the sole recovery owner.
t_resume_snapshot_refuses_a_changed_file({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, [ent(1)]),
        Session = quod_ledger_store:snapshot(S1),
        {ok, S2} = quod_ledger_store:append(S1, [ent(2)]),
        ok = quod_ledger_store:close(S2),
        ?assertEqual({error, changed}, quod_ledger_store:resume(Session)),
        {ok, Recovered} = quod_ledger_store:open(Ns, Dir),
        ?assertEqual(2, quod_ledger_store:last(Recovered)),
        ok = quod_ledger_store:close(Recovered)
    end.

%% open_ro gives a read-only view of the committed log (the catch-up/feed server's read path).
t_open_ro_reads({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, [ent(1), ent(2), ent(3)]),
        ok = quod_ledger_store:close(S1),
        {ok, RO} = quod_ledger_store:open_ro(Ns, Dir),
        ?assertEqual(3, quod_ledger_store:last(RO)),
        ?assertMatch({ok, [_, _, _]}, quod_ledger_store:read_range(RO, 1, 3)),
        ?assertMatch({ok, #entry{index = 2}}, read_view(quod_ledger_store:read_at(RO, 2))),
        ok = quod_ledger_store:close(RO),
        ?assertEqual({error, no_log}, quod_ledger_store:open_ro(<<"never:opened">>, Dir))
    end.

%% One aggregate scan span gives a traced caller enough depth to separate file
%% open, framing/index rebuild and canonical decode without exporting one span
%% per historical entry (which would perturb long-ledger measurements).
t_traced_open_profiles_scan_without_per_entry_spans({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, [ent(1), ent(2), ent(3)]),
        ok = quod_ledger_store:close(S1),
        quod_trace_tests:with_tracer(fun() ->
            quod_trace:with_span(
              otel_ctx:new(), <<"ledger.profile.parent">>, internal, #{},
              fun(_Parent) ->
                  {ok, RO} = quod_ledger_store:open_ro(Ns, Dir),
                  ?assertMatch({ok, #entry{index = 2}},
                               read_view(quod_ledger_store:read_at(RO, 2))),
                  ok = quod_ledger_store:close(RO)
              end),
            Parent = quod_trace_tests:take_span(<<"ledger.profile.parent">>),
            FileOpen = quod_trace_tests:take_span(<<"quod.ledger.file_open">>),
            Scan = quod_trace_tests:take_span(<<"quod.ledger.index_scan">>),
            Read = quod_trace_tests:take_span(<<"quod.ledger.read_at">>),
            lists:foreach(
              fun(Child) ->
                  ?assertEqual(Parent#span.trace_id, Child#span.trace_id),
                  ?assertEqual(Parent#span.span_id, Child#span.parent_span_id)
              end, [FileOpen, Scan, Read]),
            Attrs = otel_attributes:map(Scan#span.attributes),
            ?assertEqual(Ns, maps:get('quod.namespace', Attrs)),
            ?assertEqual(3, maps:get('quod.ledger.entries', Attrs)),
            ?assert(maps:get('quod.ledger.bytes', Attrs) > 0),
            ?assert(maps:get('quod.ledger.framing_us', Attrs) >= 0),
            ?assert(maps:get('quod.ledger.decode_us', Attrs) >= 0),
            receive
                {quod_test_span, #span{name = <<"quod.ledger.index_scan">>}} ->
                    error(per_entry_scan_span)
            after 0 -> ok
            end
        end)
    end.

t_traced_append_separates_encode_write_and_sync({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        quod_trace_tests:with_tracer(fun() ->
            quod_trace:with_span(
              otel_ctx:new(), <<"ledger.append.parent">>, internal, #{},
              fun(_Parent) ->
                  {ok, S1} = quod_ledger_store:append(S0, [ent(1)]),
                  ok = quod_ledger_store:close(S1)
              end),
            Parent = quod_trace_tests:take_span(<<"ledger.append.parent">>),
            Append = quod_trace_tests:take_span(
                       <<"quod.ledger.append_batch">>),
            Sync = quod_trace_tests:take_span(<<"quod.ledger.datasync">>),
            ?assertEqual(Parent#span.span_id, Append#span.parent_span_id),
            ?assertEqual(Append#span.span_id, Sync#span.parent_span_id),
            Attrs = otel_attributes:map(Append#span.attributes),
            ?assertEqual(Ns, maps:get('quod.namespace', Attrs)),
            ?assertEqual(1, maps:get('quod.ledger.entries', Attrs)),
            ?assert(maps:get('quod.ledger.bytes', Attrs) > 0),
            ?assert(maps:get('quod.ledger.encode_us', Attrs) >= 0),
            ?assert(maps:get('quod.ledger.write_us', Attrs) >= 0)
        end)
    end.

%% open_ro is NON-TRUNCATING: a torn tail (a frame the live writer is mid-appending) bounds the readable
%% index but the file is NOT mutated — so a concurrent reader can never corrupt the writer's log. (The
%% writer's own truncating open still trims it.)
t_open_ro_non_truncating({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, [ent(1), ent(2)]),
        ok = quod_ledger_store:close(S1),
        LogPath   = filename:join([Dir, base64url(Ns), "log.0001"]),
        ValidSize = filelib:file_size(LogPath),
        {ok, Fd}  = file:open(LogPath, [read, write, raw, binary]),
        {ok, _}   = file:position(Fd, eof),
        ok = file:write(Fd, <<"torn-partial-frame">>),   %% the writer mid-appending a frame
        ok = file:close(Fd),
        TornSize = filelib:file_size(LogPath),
        ?assert(TornSize > ValidSize),
        {ok, RO} = quod_ledger_store:open_ro(Ns, Dir),
        ?assertEqual(2, quod_ledger_store:last(RO)),             %% reads up to the last valid entry
        ?assertMatch({ok, [_, _]}, quod_ledger_store:read_range(RO, 1, 2)),
        ok = quod_ledger_store:close(RO),
        ?assertEqual(TornSize, filelib:file_size(LogPath)),     %% open_ro left the torn tail (SAFE)
        {ok, W} = quod_ledger_store:open(Ns, Dir),              %% the writer's open DOES trim it
        ok = quod_ledger_store:close(W),
        ?assertEqual(ValidSize, filelib:file_size(LogPath))
    end.

t_torn_tail_recovery({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, [ent(1), ent(2), ent(3)]),
        ok = quod_ledger_store:close(S1),
        %% simulate a crash mid-append: a partial/garbage tail on the log file
        LogPath = filename:join([Dir, base64url(Ns), "log.0001"]),
        {ok, Fd} = file:open(LogPath, [read, write, raw, binary]),
        {ok, _} = file:position(Fd, eof),
        ok = file:write(Fd, <<"torn">>),   %% < a full header → trimmed on reopen
        ok = file:close(Fd),
        {ok, S2} = quod_ledger_store:open(Ns, Dir),
        ?assertEqual(3, quod_ledger_store:last(S2)),
        ?assertMatch({ok, [_, _, _]}, quod_ledger_store:read_range(S2, 1, 3)),
        ok = quod_ledger_store:close(S2)
    end.

%% A bad-CRC FINAL frame (a crash that fully wrote the length but corrupted the payload,
%% with nothing after it) is still a torn tail → trimmed, earlier entries kept.
t_torn_tail_bad_crc_trims({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, [ent(1), ent(2), ent(3)]),
        ok = quod_ledger_store:close(S1),
        LogPath = filename:join([Dir, base64url(Ns), "log.0001"]),
        {ok, Fd} = file:open(LogPath, [read, write, raw, binary]),
        {ok, Size} = file:position(Fd, eof),
        {ok, <<B>>} = file:pread(Fd, Size - 1, 1),     %% flip the LAST byte (frame 3's payload)
        ok = file:pwrite(Fd, Size - 1, <<(B bxor 16#FF)>>),
        ok = file:close(Fd),
        {ok, S2} = quod_ledger_store:open(Ns, Dir),
        ?assertEqual(2, quod_ledger_store:last(S2)),  %% frame 3 trimmed, 1 & 2 kept
        ?assertMatch({ok, [_, _]}, quod_ledger_store:read_range(S2, 1, 2)),
        ok = quod_ledger_store:close(S2)
    end.

%% A corrupt INTERIOR frame (bad CRC) FOLLOWED by a valid frame is NOT a torn tail — a
%% crash can only damage the last write — so it is mid-log corruption: open/2 fail-stops
%% rather than silently discarding the durably-committed entries after it.
t_interior_corruption_fail_stops({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, [ent(1), ent(2), ent(3)]),
        ok = quod_ledger_store:close(S1),
        LogPath = filename:join([Dir, base64url(Ns), "log.0001"]),
        {ok, Fd} = file:open(LogPath, [read, write, raw, binary]),
        {ok, <<B>>} = file:pread(Fd, 14, 1),           %% a byte inside frame 1's payload (hdr=12)
        ok = file:pwrite(Fd, 14, <<(B bxor 16#FF)>>),  %% frames 2 & 3 still follow intact
        ok = file:close(Fd),
        ?assertError({log_corruption, _, _}, quod_ledger_store:open(Ns, Dir))
    end.

%% Interior-corruption detection must stay bounded without losing reach: a
%% later frame marker beyond multiple read windows still prevents truncation.
t_chunked_tail_detects_distant_magic({Dir, Ns}) ->
    fun() ->
        Path = prepare_log_path(Dir, Ns),
        Filler = binary:copy(<<0>>, 2 * ?READ_CHUNK + 17),
        Bytes = <<0:32, Filler/binary, ?MAGIC:32>>,
        ok = file:write_file(Path, Bytes),
        ?assertError(
           {log_corruption, bad_magic, 0},
           quod_ledger_store:open(Ns, Dir)),
        ?assertEqual({ok, Bytes}, file:read_file(Path))
    end.

%% The scanner overlaps windows by three bytes, covering every possible split
%% of the current V5 or any recognized V1/V2/V3/V4 marker at a chunk boundary.
t_chunked_tail_detects_split_magic({Dir, Ns}) ->
    fun() ->
        Path = prepare_log_path(Dir, Ns),
        [begin
             Filler = binary:copy(<<0>>, ?READ_CHUNK - PrefixBytes),
             Bytes = <<0:32, Filler/binary, Magic:32>>,
             ok = file:write_file(Path, Bytes),
             ?assertError(
                {log_corruption, bad_magic, 0},
                quod_ledger_store:open(Ns, Dir)),
             ?assertEqual({ok, Bytes}, file:read_file(Path))
         end
         || Magic <- [?MAGIC, ?V4_MAGIC, ?V3_MAGIC, ?V2_MAGIC, ?V1_MAGIC],
            PrefixBytes <- [1, 2, 3]],
        ok
    end.

%% A genuinely final corrupt frame with a large marker-free tail remains
%% recoverable: after scanning every bounded window, the writer trims it.
t_chunked_marker_free_tail_trims({Dir, Ns}) ->
    fun() ->
        Path = prepare_log_path(Dir, Ns),
        Filler = binary:copy(<<0>>, 2 * ?READ_CHUNK + 17),
        ok = file:write_file(Path, <<0:32, Filler/binary>>),
        {ok, Store} = quod_ledger_store:open(Ns, Dir),
        ?assertEqual(0, quod_ledger_store:last(Store)),
        ok = quod_ledger_store:close(Store),
        ?assertEqual(0, filelib:file_size(Path))
    end.

%% The index is SPARSE (one checkpointed offset per 256 entries): reads seek to the nearest
%% checkpoint and hop frame headers forward. Exercise entries just before/on/after a checkpoint
%% boundary, a read_range run crossing boundaries, the windowed fold/5 stream, and a reopen
%% (the scan rebuilds the same checkpoints).
t_checkpointed_reads({Dir, Ns}) ->
    fun() ->
        N = 600,   %% checkpoints land at 1, 257, 513 — three of them
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, [ent(I) || I <- lists:seq(1, N)]),
        ?assertEqual(N, quod_ledger_store:last(S1)),
        {ok, E256} = quod_ledger_store:read_at(S1, 256),   %% farthest from its checkpoint (255 hops)
        ?assertEqual(data(256), entry_data(E256)),
        {ok, E257} = quod_ledger_store:read_at(S1, 257),   %% exactly on a checkpoint (0 hops)
        ?assertEqual(data(257), entry_data(E257)),
        {ok, Es} = quod_ledger_store:read_range(S1, 250, 520),   %% one run across two boundaries
        ?assertEqual(lists:seq(250, 520), [entry_index(E) || E <- Es]),
        Sum = quod_ledger_store:fold(S1, 1, N, fun(E, Acc) -> Acc + entry_index(E) end, 0),
        ?assertEqual(N * (N + 1) div 2, Sum),
        ok = quod_ledger_store:close(S1),
        {ok, S2} = quod_ledger_store:open(Ns, Dir),        %% reopen: the scan rebuilds the checkpoints
        %% exercise EVERY rebuilt checkpoint word, not just the last: reads served via word 0
        %% (index 2), word 1 (index 300), word 2 (index 600), plus a full-log fold.
        ?assertMatch({ok, #entry{index = 2}},   read_view(quod_ledger_store:read_at(S2, 2))),
        ?assertMatch({ok, #entry{index = 300}}, read_view(quod_ledger_store:read_at(S2, 300))),
        ?assertMatch({ok, #entry{index = 600}}, read_view(quod_ledger_store:read_at(S2, 600))),
        ?assertEqual(not_found, quod_ledger_store:read_at(S2, 601)),
        ?assertEqual(N * (N + 1) div 2,
                     quod_ledger_store:fold(S2, 1, N, fun(E, A) -> A + entry_index(E) end, 0)),
        ok = quod_ledger_store:close(S2)
    end.

%% Trim + checkpoints together: a torn tail on a MULTI-checkpoint log must leave every
%% earlier checkpoint word serving correct reads, and appending after the trim must resume
%% cleanly across the next checkpoint boundary.
t_trim_across_checkpoints({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, [ent(I) || I <- lists:seq(1, 300)]),   %% cps at 1, 257
        ok = quod_ledger_store:close(S1),
        LogPath = filename:join([Dir, base64url(Ns), "log.0001"]),
        {ok, Fd} = file:open(LogPath, [read, write, raw, binary]),
        {ok, _} = file:position(Fd, eof),
        ok = file:write(Fd, <<"torn-mid-append">>),
        ok = file:close(Fd),
        {ok, S2} = quod_ledger_store:open(Ns, Dir),        %% trims the torn tail, keeps 1..300
        ?assertEqual(300, quod_ledger_store:last(S2)),
        ?assertMatch({ok, #entry{index = 256}}, read_view(quod_ledger_store:read_at(S2, 256))),   %% word 0, max hops
        ?assertMatch({ok, #entry{index = 257}}, read_view(quod_ledger_store:read_at(S2, 257))),   %% word 1, 0 hops
        {ok, Run} = quod_ledger_store:read_range(S2, 250, 300),                        %% crosses the boundary
        ?assertEqual(lists:seq(250, 300), [entry_index(E) || E <- Run]),
        {ok, S3} = quod_ledger_store:append(S2, [ent(I) || I <- lists:seq(301, 600)]), %% resumes; cps at 513
        ?assertMatch({ok, #entry{index = 513}}, read_view(quod_ledger_store:read_at(S3, 513))),
        {ok, Run2} = quod_ledger_store:read_range(S3, 500, 520),
        ?assertEqual(lists:seq(500, 520), [entry_index(E) || E <- Run2]),
        ok = quod_ledger_store:close(S3)
    end.

%% The log is contiguous FROM INDEX 1 (base-above-1 is unsupported until compaction lands
%% with its committee checkpoint): a CRC-valid head frame with any other index is corruption —
%% fail-stop when intact frames follow, torn-tail trim when alone — never silently indexed
%% (an index-0 head must not shift the checkpoint words; the old 0-sentinel bug).
t_rejects_wrong_first_index({Dir, Ns}) ->
    fun() ->
        LogDir  = filename:join(Dir, base64url(Ns)),
        ok = filelib:ensure_path(LogDir),
        LogPath = filename:join(LogDir, "log.0001"),
        {ok, WrongHead} = quod_safe_term:encode_canonical(
                            {quod_entry, 1, 0, none, none}, 1024),
        ok = file:write_file(
               LogPath, [raw_frame_payload(?MAGIC, WrongHead),
                         raw_frame(ent(1))]),
        ?assertError({log_corruption, bad_entry, _},
                     quod_ledger_store:open(Ns, Dir)),
        ok = file:write_file(LogPath, raw_frame(ent(5))),   %% a lone wrong-index head: torn tail
        {ok, S} = quod_ledger_store:open(Ns, Dir),
        ?assertEqual(0, quod_ledger_store:last(S)),         %% trimmed to empty, nothing served
        ?assertEqual(not_found, quod_ledger_store:read_at(S, 1)),
        ok = quod_ledger_store:close(S)
    end.

%% fold/5 must FAIL LOUDLY when asked past the live tail — a caller that believes more is
%% committed than the store holds must never get a silent partial fold. Empty ranges are fine.
t_fold_beyond_tail({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, [ent(1), ent(2), ent(3)]),
        Cons = fun(E, A) -> [E | A] end,
        ?assertError({fold_beyond_tail, 10, 3}, quod_ledger_store:fold(S1, 4, 10, Cons, [])),
        ?assertEqual([], quod_ledger_store:fold(S1, 4, 3, Cons, [])),   %% From > To: empty, no error
        ok = quod_ledger_store:close(S1)
    end.

%% A tail frame whose length field is insane (corrupt Len) must be handled WITHOUT a giant
%% allocation: at the tail it is trimmed like any torn frame, and the committed prefix survives.
t_huge_len_tail_trimmed({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, [ent(1), ent(2)]),
        ok = quod_ledger_store:close(S1),
        LogPath = filename:join([Dir, base64url(Ns), "log.0001"]),
        {ok, Fd} = file:open(LogPath, [read, write, raw, binary]),
        {ok, _} = file:position(Fd, eof),
        ok = file:write(Fd, <<?MAGIC:32, 16#7FFFFFFF:32, 0:32, "junk">>),   %% Len = 2 GiB
        ok = file:close(Fd),
        {ok, S2} = quod_ledger_store:open(Ns, Dir),
        ?assertEqual(2, quod_ledger_store:last(S2)),
        ?assertMatch({ok, [_, _]}, quod_ledger_store:read_range(S2, 1, 2)),
        ok = quod_ledger_store:close(S2)
    end.

t_legacy_format_fails_without_mutation({Dir, Ns}) ->
    fun() ->
        lists:foreach(
          fun({Version, Magic}) ->
              Path = prepare_log_path(Dir, Ns),
              Legacy = raw_frame(Magic, ent(1)),
              ok = file:write_file(Path, Legacy),
              ?assertEqual(
                 {error, {scan_failed, error,
                          {unsupported_ledger_format, Version, 0}}},
                 quod_ledger_store:open_ro(Ns, Dir)),
              ?assertEqual({ok, Legacy}, file:read_file(Path)),
              ?assertError(
                 {unsupported_ledger_format, Version, 0},
                 quod_ledger_store:open(Ns, Dir)),
              ?assertEqual({ok, Legacy}, file:read_file(Path))
          end, legacy_formats())
    end.

t_legacy_tail_fails_without_mutation({Dir, Ns}) ->
    fun() ->
        lists:foreach(
          fun({Version, Magic}) ->
              Path = prepare_log_path(Dir, Ns),
              Current = raw_frame(ent(1)),
              Legacy = raw_frame(Magic, ent(2)),
              Bytes = <<Current/binary, Legacy/binary>>,
              LegacyOffset = byte_size(Current),
              ok = file:write_file(Path, Bytes),
              ?assertEqual(
                 {error, {scan_failed, error,
                          {unsupported_ledger_format, Version, LegacyOffset}}},
                 quod_ledger_store:open_ro(Ns, Dir)),
              ?assertEqual({ok, Bytes}, file:read_file(Path)),
              ?assertError(
                 {unsupported_ledger_format, Version, LegacyOffset},
                 quod_ledger_store:open(Ns, Dir)),
              ?assertEqual({ok, Bytes}, file:read_file(Path))
          end, legacy_formats())
    end.

t_short_legacy_header_fails_without_mutation({Dir, Ns}) ->
    fun() ->
        lists:foreach(
          fun({Version, Magic}) ->
              Path = prepare_log_path(Dir, Ns),
              LegacyMagic = <<Magic:32>>,
              ok = file:write_file(Path, LegacyMagic),
              ?assertEqual(
                 {error, {scan_failed, error,
                          {unsupported_ledger_format, Version, 0}}},
                 quod_ledger_store:open_ro(Ns, Dir)),
              ?assertEqual({ok, LegacyMagic}, file:read_file(Path)),
              ?assertError(
                 {unsupported_ledger_format, Version, 0},
                 quod_ledger_store:open(Ns, Dir)),
              ?assertEqual({ok, LegacyMagic}, file:read_file(Path))
          end, legacy_formats())
    end.

t_short_legacy_tail_fails_without_mutation({Dir, Ns}) ->
    fun() ->
        lists:foreach(
          fun({Version, Magic}) ->
              Path = prepare_log_path(Dir, Ns),
              Current = raw_frame(ent(1)),
              LegacyMagic = <<Magic:32>>,
              Bytes = <<Current/binary, LegacyMagic/binary>>,
              LegacyOffset = byte_size(Current),
              ok = file:write_file(Path, Bytes),
              ?assertEqual(
                 {error, {scan_failed, error,
                          {unsupported_ledger_format, Version, LegacyOffset}}},
                 quod_ledger_store:open_ro(Ns, Dir)),
              ?assertEqual({ok, Bytes}, file:read_file(Path)),
              ?assertError(
                 {unsupported_ledger_format, Version, LegacyOffset},
                 quod_ledger_store:open(Ns, Dir)),
              ?assertEqual({ok, Bytes}, file:read_file(Path))
          end, legacy_formats())
    end.

t_corrupt_current_before_legacy_fails_without_mutation({Dir, Ns}) ->
    fun() ->
        lists:foreach(
          fun({_Version, Magic}) ->
              Path = prepare_log_path(Dir, Ns),
              Corrupt = bad_crc_raw_frame(ent(1)),
              Legacy = raw_frame(Magic, ent(2)),
              Bytes = <<Corrupt/binary, Legacy/binary>>,
              ok = file:write_file(Path, Bytes),
              ?assertError(
                 {log_corruption, bad_crc, 0},
                 quod_ledger_store:open(Ns, Dir)),
              ?assertEqual({ok, Bytes}, file:read_file(Path))
          end, legacy_formats())
    end.

%% mirror of quod_ledger_store's frame/1 for hand-crafting log files in tests
raw_frame(Entry) ->
    {ok, Payload} = quod_ledger:encode_entry(Entry),
    raw_frame_payload(?MAGIC, Payload).

raw_frame(Magic, Entry) ->
    %% Legacy fixture bytes remain the old native view, never the transient
    %% artifact wrapper. Their exact recognizable framing is unchanged.
    P = term_to_binary(quod_ledger:entry_view(Entry), [deterministic]),
    raw_frame_payload(Magic, P).

raw_frame_payload(Magic, Payload) ->
    <<Magic:32, (byte_size(Payload)):32,
      (erlang:crc32(Payload)):32, Payload/binary>>.

bad_crc_raw_frame(Entry) ->
    {ok, P} = quod_ledger:encode_entry(Entry),
    CRC = erlang:crc32(P) bxor 1,
    <<?MAGIC:32, (byte_size(P)):32, CRC:32, P/binary>>.

prepare_log_path(Dir, Ns) ->
    LogDir = filename:join(Dir, base64url(Ns)),
    ok = filelib:ensure_path(LogDir),
    filename:join(LogDir, "log.0001").

%% mirror of quod_ledger_store:base64url/1 for path construction in the torn-tail test
base64url(Bin) ->
    B = base64:encode(Bin),
    [case C of $+ -> $-; $/ -> $_; _ -> C end || <<C>> <= B, C =/= $=].

%% The ledger's home is `ledger_dir` when set (fast local disk), else `data_dir` (the
%% durable volume), else the user-cache default — the split that keeps the replicated,
%% re-fetchable chain off the slow-fsync volume while identity + vote journal stay on it.
ledger_dir_resolution_test() ->
    ?assertEqual("/fast/ledger",
                 quod_ledger_store:ledger_dir(#{ledger_dir => "/fast/ledger",
                                                data_dir => "/durable"})),
    ?assertEqual("/durable",
                 quod_ledger_store:ledger_dir(#{data_dir => "/durable"})),
    ?assertEqual(quod_ledger_store:default_data_dir(),
                 quod_ledger_store:ledger_dir(#{})).

-module(quod_ledger_store_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

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
      fun t_reopen_persists/1,
      fun t_torn_tail_recovery/1,
      fun t_torn_tail_bad_crc_trims/1,
      fun t_interior_corruption_fail_stops/1,
      fun t_open_ro_reads/1,
      fun t_open_ro_non_truncating/1,
      fun t_checkpointed_reads/1,
      fun t_trim_across_checkpoints/1,
      fun t_rejects_wrong_first_index/1,
      fun t_fold_beyond_tail/1,
      fun t_huge_len_tail_trimmed/1]}.

%%%===================================================================
%%% helpers
%%%===================================================================

ent(I) -> #entry{index = I, data = chg(I)}.

chg(I) ->
    #transaction{tx_id = integer_to_binary(I), caller_ns = <<"onia:peers">>,
            diff = [{assert, {{fact, I}, true}}], read_check = #{},
            author = {"127.0.0.1", 5000}, sig = none}.

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
        ?assertEqual(1, E1#entry.index),
        ?assertEqual(2, E2#entry.index),
        ?assertEqual(3, E3#entry.index),
        {ok, E2b} = quod_ledger_store:read_at(S1, 2),
        ?assertEqual(chg(2), E2b#entry.data),
        %% a non-contiguous append is rejected (the store is append-only, in slot order)
        ?assertError({non_contiguous_append, 3, [5]}, quod_ledger_store:append(S1, [ent(5)])),
        ok = quod_ledger_store:close(S1)
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

%% open_ro gives a read-only view of the committed log (the catch-up/feed server's read path).
t_open_ro_reads({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, [ent(1), ent(2), ent(3)]),
        ok = quod_ledger_store:close(S1),
        {ok, RO} = quod_ledger_store:open_ro(Ns, Dir),
        ?assertEqual(3, quod_ledger_store:last(RO)),
        ?assertMatch({ok, [_, _, _]}, quod_ledger_store:read_range(RO, 1, 3)),
        ?assertMatch({ok, #entry{index = 2}}, quod_ledger_store:read_at(RO, 2)),
        ok = quod_ledger_store:close(RO),
        ?assertEqual({error, no_log}, quod_ledger_store:open_ro(<<"never:opened">>, Dir))
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
        ?assertEqual(chg(256), E256#entry.data),
        {ok, E257} = quod_ledger_store:read_at(S1, 257),   %% exactly on a checkpoint (0 hops)
        ?assertEqual(chg(257), E257#entry.data),
        {ok, Es} = quod_ledger_store:read_range(S1, 250, 520),   %% one run across two boundaries
        ?assertEqual(lists:seq(250, 520), [E#entry.index || E <- Es]),
        Sum = quod_ledger_store:fold(S1, 1, N, fun(#entry{index = I}, Acc) -> Acc + I end, 0),
        ?assertEqual(N * (N + 1) div 2, Sum),
        ok = quod_ledger_store:close(S1),
        {ok, S2} = quod_ledger_store:open(Ns, Dir),        %% reopen: the scan rebuilds the checkpoints
        %% exercise EVERY rebuilt checkpoint word, not just the last: reads served via word 0
        %% (index 2), word 1 (index 300), word 2 (index 600), plus a full-log fold.
        ?assertMatch({ok, #entry{index = 2}},   quod_ledger_store:read_at(S2, 2)),
        ?assertMatch({ok, #entry{index = 300}}, quod_ledger_store:read_at(S2, 300)),
        ?assertMatch({ok, #entry{index = 600}}, quod_ledger_store:read_at(S2, 600)),
        ?assertEqual(not_found, quod_ledger_store:read_at(S2, 601)),
        ?assertEqual(N * (N + 1) div 2,
                     quod_ledger_store:fold(S2, 1, N, fun(#entry{index = I}, A) -> A + I end, 0)),
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
        ?assertMatch({ok, #entry{index = 256}}, quod_ledger_store:read_at(S2, 256)),   %% word 0, max hops
        ?assertMatch({ok, #entry{index = 257}}, quod_ledger_store:read_at(S2, 257)),   %% word 1, 0 hops
        {ok, Run} = quod_ledger_store:read_range(S2, 250, 300),                        %% crosses the boundary
        ?assertEqual(lists:seq(250, 300), [E#entry.index || E <- Run]),
        {ok, S3} = quod_ledger_store:append(S2, [ent(I) || I <- lists:seq(301, 600)]), %% resumes; cps at 513
        ?assertMatch({ok, #entry{index = 513}}, quod_ledger_store:read_at(S3, 513)),
        {ok, Run2} = quod_ledger_store:read_range(S3, 500, 520),
        ?assertEqual(lists:seq(500, 520), [E#entry.index || E <- Run2]),
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
        ok = file:write_file(LogPath, [raw_frame(ent(0)), raw_frame(ent(1))]),
        ?assertError({log_corruption, {discontinuity, 0}, _}, quod_ledger_store:open(Ns, Dir)),
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
        ok = file:write(Fd, <<16#915106AA:32, 16#7FFFFFFF:32, 0:32, "junk">>),   %% Len = 2 GiB
        ok = file:close(Fd),
        {ok, S2} = quod_ledger_store:open(Ns, Dir),
        ?assertEqual(2, quod_ledger_store:last(S2)),
        ?assertMatch({ok, [_, _]}, quod_ledger_store:read_range(S2, 1, 2)),
        ok = quod_ledger_store:close(S2)
    end.

%% mirror of quod_ledger_store's frame/1 for hand-crafting log files in tests
raw_frame(Entry) ->
    P = term_to_binary(Entry, [deterministic]),
    <<16#915106AA:32, (byte_size(P)):32, (erlang:crc32(P)):32, P/binary>>.

%% mirror of quod_ledger_store:base64url/1 for path construction in the torn-tail test
base64url(Bin) ->
    B = base64:encode(Bin),
    [case C of $+ -> $-; $/ -> $_; _ -> C end || <<C>> <= B, C =/= $=].

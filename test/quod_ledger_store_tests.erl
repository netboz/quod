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
      fun t_load/1]}.

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

t_load({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, [ent(1), ent(2)]),
        Loaded = quod_ledger_store:load(S1),
        ?assertEqual([1, 2], [E#entry.index || E <- maps:get(log, Loaded)]),
        ?assertEqual([log], maps:keys(Loaded)),
        ok = quod_ledger_store:close(S1)
    end.

%% mirror of quod_ledger_store:base64url/1 for path construction in the torn-tail test
base64url(Bin) ->
    B = base64:encode(Bin),
    [case C of $+ -> $-; $/ -> $_; _ -> C end || <<C>> <= B, C =/= $=].

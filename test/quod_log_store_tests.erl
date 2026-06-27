-module(quod_log_store_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_log.hrl").

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
      fun t_meta_roundtrip/1,
      fun t_reopen_persists/1,
      fun t_truncate_from/1,
      fun t_torn_tail_recovery/1,
      fun t_torn_tail_bad_crc_trims/1,
      fun t_interior_corruption_fail_stops/1,
      fun t_load/1]}.

%%%===================================================================
%%% helpers
%%%===================================================================

ent(I, T) -> #entry{index = I, term = T, kind = block, data = chg(I)}.

chg(I) ->
    #change{tx_id = integer_to_binary(I), caller_ns = <<"onia:peers">>,
            diff = [{assert, {{fact, I}, true}}], read_check = #{},
            author = {"127.0.0.1", 5000}, sig = none}.

%%%===================================================================
%%% tests
%%%===================================================================

t_empty({Dir, Ns}) ->
    fun() ->
        {ok, S} = quod_log_store:open(Ns, Dir),
        ?assertEqual({0, 0}, quod_log_store:last(S)),
        ?assertEqual(not_found, quod_log_store:read_at(S, 1)),
        ?assertEqual({0, none}, quod_log_store:read_meta(S)),
        ?assertEqual(0, quod_log_store:term_at(S, 0)),
        ok = quod_log_store:close(S)
    end.

t_append_read({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_log_store:open(Ns, Dir),
        {ok, S1} = quod_log_store:append(S0, [ent(1, 1), ent(2, 1), ent(3, 2)]),
        ?assertEqual({3, 2}, quod_log_store:last(S1)),
        {ok, [E1, E2, E3]} = quod_log_store:read_range(S1, 1, 3),
        ?assertEqual(1, E1#entry.index),
        ?assertEqual(2, E2#entry.index),
        ?assertEqual(3, E3#entry.index),
        ?assertEqual(2, quod_log_store:term_at(S1, 3)),
        ?assertEqual(1, quod_log_store:term_at(S1, 1)),
        ?assertEqual(undefined, quod_log_store:term_at(S1, 9)),
        {ok, E2b} = quod_log_store:read_at(S1, 2),
        ?assertEqual(chg(2), E2b#entry.data),
        ok = quod_log_store:close(S1)
    end.

t_meta_roundtrip({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_log_store:open(Ns, Dir),
        ok = quod_log_store:write_meta(S0, 7, {"10.0.0.2", 5000}),
        ?assertEqual({7, {"10.0.0.2", 5000}}, quod_log_store:read_meta(S0)),
        ok = quod_log_store:write_meta(S0, 8, none),   %% atomic overwrite
        ?assertEqual({8, none}, quod_log_store:read_meta(S0)),
        ok = quod_log_store:close(S0)
    end.

t_reopen_persists({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_log_store:open(Ns, Dir),
        {ok, S1} = quod_log_store:append(S0, [ent(1, 1), ent(2, 3)]),
        ok = quod_log_store:write_meta(S1, 3, {"127.0.0.1", 5000}),
        ok = quod_log_store:close(S1),
        {ok, S2} = quod_log_store:open(Ns, Dir),
        ?assertEqual({2, 3}, quod_log_store:last(S2)),
        ?assertEqual({3, {"127.0.0.1", 5000}}, quod_log_store:read_meta(S2)),
        ?assertMatch({ok, [_, _]}, quod_log_store:read_range(S2, 1, 2)),
        ok = quod_log_store:close(S2)
    end.

t_truncate_from({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_log_store:open(Ns, Dir),
        {ok, S1} = quod_log_store:append(S0, [ent(1, 1), ent(2, 1), ent(3, 1), ent(4, 1)]),
        {ok, S2} = quod_log_store:truncate_from(S1, 3),    %% drop 3,4
        {ok, S3} = quod_log_store:append(S2, [ent(3, 2)]), %% divergent re-append
        ?assertEqual({3, 2}, quod_log_store:last(S3)),
        ?assertEqual(not_found, quod_log_store:read_at(S3, 4)),
        ?assertEqual(2, quod_log_store:term_at(S3, 3)),
        ok = quod_log_store:close(S3),
        {ok, S4} = quod_log_store:open(Ns, Dir),           %% persists across reopen
        ?assertEqual({3, 2}, quod_log_store:last(S4)),
        ?assertEqual(not_found, quod_log_store:read_at(S4, 4)),
        ok = quod_log_store:close(S4)
    end.

t_torn_tail_recovery({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_log_store:open(Ns, Dir),
        {ok, S1} = quod_log_store:append(S0, [ent(1, 1), ent(2, 1), ent(3, 1)]),
        ok = quod_log_store:close(S1),
        %% simulate a crash mid-append: a partial/garbage tail on the log file
        LogPath = filename:join([Dir, base64url(Ns), "log.0001"]),
        {ok, Fd} = file:open(LogPath, [read, write, raw, binary]),
        {ok, _} = file:position(Fd, eof),
        ok = file:write(Fd, <<"torn">>),   %% < a full header → trimmed on reopen
        ok = file:close(Fd),
        {ok, S2} = quod_log_store:open(Ns, Dir),
        ?assertEqual({3, 1}, quod_log_store:last(S2)),
        ?assertMatch({ok, [_, _, _]}, quod_log_store:read_range(S2, 1, 3)),
        ok = quod_log_store:close(S2)
    end.

%% A bad-CRC FINAL frame (a crash that fully wrote the length but corrupted the payload,
%% with nothing after it) is still a torn tail → trimmed, earlier entries kept.
t_torn_tail_bad_crc_trims({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_log_store:open(Ns, Dir),
        {ok, S1} = quod_log_store:append(S0, [ent(1, 1), ent(2, 1), ent(3, 1)]),
        ok = quod_log_store:close(S1),
        LogPath = filename:join([Dir, base64url(Ns), "log.0001"]),
        {ok, Fd} = file:open(LogPath, [read, write, raw, binary]),
        {ok, Size} = file:position(Fd, eof),
        {ok, <<B>>} = file:pread(Fd, Size - 1, 1),     %% flip the LAST byte (frame 3's payload)
        ok = file:pwrite(Fd, Size - 1, <<(B bxor 16#FF)>>),
        ok = file:close(Fd),
        {ok, S2} = quod_log_store:open(Ns, Dir),
        ?assertEqual({2, 1}, quod_log_store:last(S2)),  %% frame 3 trimmed, 1 & 2 kept
        ?assertMatch({ok, [_, _]}, quod_log_store:read_range(S2, 1, 2)),
        ok = quod_log_store:close(S2)
    end.

%% A corrupt INTERIOR frame (bad CRC) FOLLOWED by a valid frame is NOT a torn tail — a
%% crash can only damage the last write — so it is mid-log corruption: open/2 fail-stops
%% rather than silently discarding the durably-committed entries after it (review #8).
t_interior_corruption_fail_stops({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_log_store:open(Ns, Dir),
        {ok, S1} = quod_log_store:append(S0, [ent(1, 1), ent(2, 1), ent(3, 1)]),
        ok = quod_log_store:close(S1),
        LogPath = filename:join([Dir, base64url(Ns), "log.0001"]),
        {ok, Fd} = file:open(LogPath, [read, write, raw, binary]),
        {ok, <<B>>} = file:pread(Fd, 14, 1),           %% a byte inside frame 1's payload (hdr=12)
        ok = file:pwrite(Fd, 14, <<(B bxor 16#FF)>>),  %% frames 2 & 3 still follow intact
        ok = file:close(Fd),
        ?assertError({log_corruption, _, _}, quod_log_store:open(Ns, Dir))
    end.

t_load({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_log_store:open(Ns, Dir),
        {ok, S1} = quod_log_store:append(S0, [ent(1, 1), ent(2, 2)]),
        ok = quod_log_store:write_meta(S1, 2, {"127.0.0.1", 5000}),
        Loaded = quod_log_store:load(S1),
        ?assertEqual(2, maps:get(cur_term, Loaded)),
        ?assertEqual({"127.0.0.1", 5000}, maps:get(voted_for, Loaded)),
        ?assertEqual(2, length(maps:get(log, Loaded))),
        ?assertEqual(0, maps:get(snap_idx, Loaded)),
        ?assertEqual(none, maps:get(snap_data, Loaded)),
        ok = quod_log_store:close(S1)
    end.

%% mirror of quod_log_store:base64url/1 for path construction in the torn-tail test
base64url(Bin) ->
    B = base64:encode(Bin),
    [case C of $+ -> $-; $/ -> $_; _ -> C end || <<C>> <= B, C =/= $=].

-module(quod_ledger_store_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").
-include("quod_ledger.hrl").

-define(V1_MAGIC, 16#915106AA).
-define(V2_MAGIC, 16#915106AB).
-define(V3_MAGIC, 16#915106AC).
-define(V4_MAGIC, 16#915106AD).
-define(V5_MAGIC, 16#915106AE).
-define(V6_MAGIC, 16#915106AF).
-define(V7_MAGIC, 16#915106B0).
-define(MAGIC, 16#915106B1).
-define(READ_CHUNK, 262144).

%% Every superseded frame magic must be rejected as an identifiable format, at
%% its exact offset, without mutating the file. Each legacy case below runs for
%% all of them.
legacy_formats() -> [{1, ?V1_MAGIC}, {2, ?V2_MAGIC}, {3, ?V3_MAGIC},
                     {4, ?V4_MAGIC}, {5, ?V5_MAGIC}, {6, ?V6_MAGIC}, {7, ?V7_MAGIC}].

%% V8 framing tests exercise the real file and captured-session seams. Fixture
%% QCs here are shape-only; consensus authority is tested at the verifier.
era_archive_keeps_proofs_out_of_material_history_test() ->
    with_era_store(fun(Dir, Ns, Genesis, Tx, Era, Anchor) ->
        {Blocks, Entries} = era_materials(2, Tx, Era, Anchor),
        [First, Second] = Blocks,
        {ok, Carrier} = quod_ledger:new_block({Era, 3}, quod_ledger:block_ref(Second), empty, 1),
        Cert = archive_cert(Carrier),
        Final = [quod_ledger:entry(I, B, Cert) || {I, B} <- lists:zip([2, 3], Blocks)],
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, {none, [Genesis]}),
        Snapshot = quod_ledger_store:snapshot(S1),
        {ok, S2} = quod_ledger_store:append(S1, {proof_source([Carrier, Second]), Final}),
        ?assertEqual(3, quod_ledger_store:last(S2)),
        ?assertEqual({ok, [Genesis | Final]}, quod_ledger_store:read_range(S2, 1, 3, all)),
        ?assertEqual([Carrier#block.block_bytes, Second#block.block_bytes], proof_bytes(S2, 2)),
        ?assertEqual(proof_bytes(S2, 2), proof_bytes(S2, 3)),
        {ok, Old} = quod_ledger_store:open_ro_snapshot(Snapshot),
        ?assertEqual(not_found, quod_ledger_store:proof_cursor(Old, 2)),
        ?assertEqual({ok, Genesis}, quod_ledger_store:read_at(Old, 1)),
        ok = quod_ledger_store:close(Old),
        ok = quod_ledger_store:close(S2),
        {ok, Restored} = quod_ledger_store:open(Ns, Dir),
        ?assertEqual({ok, Final}, quod_ledger_store:read_range(Restored, 2, 3, all)),
        ?assertEqual([Carrier#block.block_bytes, Second#block.block_bytes], proof_bytes(Restored, 2)),
        ?assertEqual({ok, First}, quod_ledger:block_from_entry(hd(Final))),
        ?assertEqual(2, length(Entries)),
        ok = quod_ledger_store:close(Restored)
    end).

era_archive_reuses_the_selected_durable_span_test() ->
    with_era_store(fun(Dir, Ns, Genesis, Tx, Era, Anchor) ->
        {[First, Second], _} = era_materials(2, Tx, Era, Anchor),
        Cert = archive_cert(Second),
        E2 = quod_ledger:entry(2, First, Cert), E3 = quod_ledger:entry(3, Second, Cert),
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, {none, [Genesis]}),
        {ok, S2} = quod_ledger_store:append(S1, {proof_source([Second]), [E2]}),
        {ok, S3} = quod_ledger_store:append(S2, {{reuse, 2}, [E3]}),
        ?assertEqual(proof_bytes(S3, 2), proof_bytes(S3, 3)),
        ok = quod_ledger_store:close(S3),
        {ok, S4} = quod_ledger_store:open(Ns, Dir),
        ?assertEqual({ok, [E2, E3]}, quod_ledger_store:read_range(S4, 2, 3, all)),
        ?assertEqual([Second#block.block_bytes], proof_bytes(S4, 3)),
        ok = quod_ledger_store:close(S4)
    end).

era_archive_extends_an_archived_parent_without_copying_it_test() ->
    with_era_store(fun(Dir, Ns, Genesis, Tx, Era, Anchor) ->
        {[First], _} = era_materials(1, Tx, Era, Anchor),
        {ok, Carrier} = quod_ledger:new_block({Era, 2}, quod_ledger:block_ref(First), empty, 1),
        {ok, Next} = quod_ledger:new_block({Era, 3}, quod_ledger:block_ref(Carrier), {batch, [Tx]}, 1),
        E2 = quod_ledger:entry(2, First, archive_cert(Carrier)),
        E3 = quod_ledger:entry(3, Next, archive_cert(Next)),
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, {none, [Genesis]}),
        {ok, S2} = quod_ledger_store:append(S1, {proof_source([Carrier, First]), [E2]}),
        Path = filename:join(quod_ledger_store:ns_dir(Dir, Ns), "log.0001"),
        {ok, Before} = file:read_file(Path), Base = byte_size(Before),
        {ok, S3} = quod_ledger_store:append(S2, {{extend, proof_source([Next]), 2}, [E3]}),
        {ok, <<_:Base/binary, Appended/binary>>} = file:read_file(Path),
        ?assertEqual(nomatch, binary:match(Appended, Carrier#block.block_bytes)),
        ?assertEqual(nomatch, binary:match(Appended, First#block.block_bytes)),
        Expected = [B#block.block_bytes || B <- [Next, Carrier, First]],
        ?assertEqual(Expected, proof_bytes(S3, 3)),
        ok = quod_ledger_store:close(S3),
        {ok, S4} = quod_ledger_store:open(Ns, Dir),
        ?assertEqual(Expected, proof_bytes(S4, 3)),
        ?assertEqual({ok, E3}, quod_ledger_store:read_at(S4, 3)),
        ok = quod_ledger_store:close(S4)
    end).

era_archive_incomplete_group_discards_complete_orphan_proofs_test() ->
    with_era_store(fun(Dir, Ns, Genesis, Tx, Era, Anchor) ->
        {[First, Second], _} = era_materials(2, Tx, Era, Anchor),
        E2 = quod_ledger:entry(2, First, archive_cert(Second)),
        {Size, _Next, _State} = proof_source([Second]),
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, {none, [Genesis]}),
        Path = filename:join(quod_ledger_store:ns_dir(Dir, Ns), "log.0001"),
        {ok, Before} = file:read_file(Path),
        Crash = fun(first) -> {Second#block.block_bytes, crashed};
                   (crashed) -> error(injected_append_failure) end,
        ?assertError(injected_append_failure,
          quod_ledger_store:append(S1, {{Size, Crash, first}, [E2]})),
        ok = quod_ledger_store:close(S1),
        {ok, Torn} = file:read_file(Path),
        ?assert(byte_size(Torn) > byte_size(Before)),
        {ok, ReadOnly} = quod_ledger_store:open_ro(Ns, Dir),
        ?assertEqual(1, quod_ledger_store:last(ReadOnly)),
        ok = quod_ledger_store:close(ReadOnly),
        ?assertEqual({ok, Torn}, file:read_file(Path)),
        {ok, Recovered} = quod_ledger_store:open(Ns, Dir),
        ?assertEqual(1, quod_ledger_store:last(Recovered)),
        ?assertEqual({ok, Before}, file:read_file(Path)),
        ok = quod_ledger_store:close(Recovered)
    end).

era_archive_rejects_corrupt_referenced_proof_without_truncation_test() ->
    with_era_store(fun(Dir, Ns, Genesis, Tx, Era, Anchor) ->
        {[First, Second], _} = era_materials(2, Tx, Era, Anchor),
        E2 = quod_ledger:entry(2, First, archive_cert(Second)),
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, {none, [Genesis]}),
        Path = filename:join(quod_ledger_store:ns_dir(Dir, Ns), "log.0001"),
        {ok, Before} = file:read_file(Path),
        {ok, S2} = quod_ledger_store:append(S1, {proof_source([Second]), [E2]}),
        ok = quod_ledger_store:close(S2),
        {ok, Bytes} = file:read_file(Path),
        %% Damage the first proof's CRC, keeping the completed footer intact.
        %% Even the last complete group is protected.
        Base = byte_size(Before),
        <<_:Base/binary, _:32, HeaderLength:32, _/binary>> = Bytes,
        At = Base + 12 + HeaderLength + 8,
        <<Prefix:At/binary, Byte, Rest/binary>> = Bytes,
        Damaged = <<Prefix/binary, (Byte bxor 1), Rest/binary>>,
        ok = file:write_file(Path, Damaged),
        ?assertException(error, {log_corruption, _, _}, quod_ledger_store:open(Ns, Dir)),
        ?assertMatch({error, {scan_failed, error, {log_corruption, _, _}}},
                     quod_ledger_store:open_ro(Ns, Dir)),
        ?assertEqual({ok, Damaged}, file:read_file(Path))
    end).

era_archive_streams_long_proof_and_seeks_across_material_checkpoints_test_() ->
    {timeout, 30, fun() ->
      with_era_store(fun(Dir, Ns, Genesis, Tx, Era, Anchor) ->
        {Blocks, Entries} = era_materials(600, Tx, Era, Anchor),
        Last = lists:last(Blocks),
        {CarriersRev, _} = lists:foldl(fun(V, {Acc, Parent}) ->
            {ok, B} = quod_ledger:new_block({Era, V}, Parent, empty, 1),
            {[B | Acc], quod_ledger:block_ref(B)}
        end, {[], quod_ledger:block_ref(Last)}, lists:seq(601, 6600)),
        Head = hd(CarriersRev), Cert = archive_cert(Head),
        Material = [quod_ledger:entry(I, B, Cert)
                    || {I, B} <- lists:zip(lists:seq(2, 601), Blocks)],
        Proofs = CarriersRev ++ lists:reverse(tl(Blocks)),
        {Size, _, _} = Source = proof_source(Proofs),
        ?assert(Size > 900 * 1024),
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, {none, [Genesis]}),
        {ok, S2} = quod_ledger_store:append(S1, {Source, Material}),
        ?assertEqual(601, quod_ledger_store:last(S2)),
        lists:foreach(fun(I) ->
          ?assertEqual({ok, lists:nth(I - 1, Material)}, quod_ledger_store:read_at(S2, I))
        end, [2, 255, 256, 257, 258, 511, 512, 513, 601]),
        ?assertEqual([B#block.block_bytes || B <- Proofs], proof_bytes(S2, 513)),
        ?assertEqual(600, length(Entries)),
        Snap = quod_ledger_store:snapshot(S2),
        ok = quod_ledger_store:close(S2),
        {ok, S3} = quod_ledger_store:resume(Snap),
        ?assertEqual(601, quod_ledger_store:fold(S3, 1, 601, fun(_, N) -> N + 1 end, 0)),
        ok = quod_ledger_store:close(S3),
        {ok, S4} = quod_ledger_store:open(Ns, Dir, wrapped),
        ?assertEqual(601, quod_ledger_store:last(S4)),
        ?assertEqual(601, quod_ledger:entry_index(element(2, quod_ledger_store:read_at(S4, 601)))),
        ok = quod_ledger_store:close(S4)
      end)
    end}.

era_archive_every_torn_group_prefix_is_atomic_test_() ->
    {timeout, 60, fun() ->
      with_era_store(fun(Dir, Ns, Genesis, Tx, Era, Anchor) ->
        {[First, Second], _} = era_materials(2, Tx, Era, Anchor),
        Final = [quod_ledger:entry(I, B, archive_cert(Second))
                   || {I, B} <- lists:zip([2, 3], [First, Second])],
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, {none, [Genesis]}),
        Path = filename:join(quod_ledger_store:ns_dir(Dir, Ns), "log.0001"),
        {ok, Before} = file:read_file(Path), Base = byte_size(Before),
        {ok, S2} = quod_ledger_store:append(S1, {proof_source([Second]), Final}),
        ok = quod_ledger_store:close(S2),
        {ok, <<_:Base/binary, Group/binary>>} = file:read_file(Path),
        lists:foreach(fun(Cut) ->
            Partial = <<Before/binary, (binary:part(Group, 0, Cut))/binary>>,
            ok = file:write_file(Path, Partial),
            {ok, RO} = quod_ledger_store:open_ro(Ns, Dir),
            ?assertEqual(1, quod_ledger_store:last(RO)),
            ok = quod_ledger_store:close(RO),
            ?assertEqual({ok, Partial}, file:read_file(Path)),
            {ok, RW} = quod_ledger_store:open(Ns, Dir),
            ?assertEqual(1, quod_ledger_store:last(RW)),
            ok = quod_ledger_store:close(RW),
            ?assertEqual({ok, Before}, file:read_file(Path))
        end, lists:seq(1, byte_size(Group) - 1))
      end)
    end}.

era_archive_sequential_group_reads_keep_their_buffer_test_() ->
    {timeout, 30, fun() ->
      with_era_store(fun(Dir, Ns, Genesis, Tx, Era, Anchor) ->
        {_, Entries} = era_materials(600, Tx, Era, Anchor),
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        S1 = lists:foldl(fun(E, S) ->
            {ok, Next} = quod_ledger_store:append(S, {none, [E]}), Next
        end, S0, [Genesis | Entries]),
        %% Count actual pread requests, not elapsed time. Crossing 601 groups
        %% must retain the sequential buffer, rather than request one 256KB
        %% slab for every small group.
        {601, Reads, Requested} = count_archive_reads(fun() ->
          quod_ledger_store:fold(S1, 1, 601, fun(_, N) -> N + 1 end, 0)
        end),
        ?assert(Reads < 20),
        ?assert(Requested < 4 * 1024 * 1024),
        ok = quod_ledger_store:close(S1),
        {{ok, Reopened}, OpenReads, OpenBytes} = count_archive_reads(fun() ->
            quod_ledger_store:open(Ns, Dir)
        end),
        ?assert(OpenReads < 20),
        ?assert(OpenBytes < 4 * 1024 * 1024),
        ok = quod_ledger_store:close(Reopened)
      end)
    end}.

count_archive_reads(Fun) ->
    Tracer = spawn(fun() -> archive_read_trace(0, 0) end),
    erlang:trace_pattern({file, pread, 3}, true, []),
    erlang:trace(self(), true, [call, {tracer, Tracer}]),
    try
        Result = Fun(),
        erlang:trace(self(), false, [call]),
        Ref = erlang:trace_delivered(self()),
        receive {trace_delivered, _, Ref} -> ok end,
        Tracer ! {result, self()},
        receive {archive_reads, Tracer, Count, Bytes} -> {Result, Count, Bytes} end
    after
        erlang:trace(self(), false, [call]),
        erlang:trace_pattern({file, pread, 3}, false, []),
        exit(Tracer, kill)
    end.

archive_read_trace(Count, Bytes) ->
    receive
        {trace, _, call, {file, pread, [_, _, Size]}} ->
            archive_read_trace(Count + 1, Bytes + Size);
        {result, From} -> From ! {archive_reads, self(), Count, Bytes};
        _ -> archive_read_trace(Count, Bytes)
    end.

era_archive_v7_is_rejected_without_mutation_test() ->
    {Dir, Ns} = Fixture = setup(),
    Path = filename:join(quod_ledger_store:ns_dir(Dir, Ns), "log.0001"),
    try
        ok = filelib:ensure_dir(Path),
        ok = file:write_file(Path, <<16#915106B0:32>>),
        ?assertError({unsupported_ledger_format, 7, 0}, quod_ledger_store:open(Ns, Dir)),
        ?assertEqual({ok, <<16#915106B0:32>>}, file:read_file(Path))
    after cleanup(Fixture) end.

with_era_store(Fun) ->
    {Dir, Ns} = Fixture = setup(),
    try
        #{identity := {Ns, Anchor}, genesis := GBlock, era := Era, transaction := Tx} =
            quod_ct:protocol_fixture(Ns),
        Fun(Dir, Ns, quod_ledger:entry(1, GBlock, none), Tx, Era, Anchor)
    after cleanup(Fixture) end.

era_materials(Count, Tx, Era, Anchor) ->
    {Rev, _} = lists:foldl(fun(View, {Acc, Parent}) ->
        {ok, B} = quod_ledger:new_block({Era, View}, Parent, {batch, [Tx]}, 1),
        {[B | Acc], quod_ledger:block_ref(B)}
    end, {[], {Era, 0, Anchor}}, lists:seq(1, Count)),
    Blocks = lists:reverse(Rev),
    {Blocks, [quod_ledger:entry(I, B, archive_cert(B))
               || {I, B} <- lists:zip(lists:seq(2, Count + 1), Blocks)]}.

archive_cert(B) ->
    {Era, View, Hash} = quod_ledger:block_ref(B),
    #cert{kind = commit, era = Era, slot = View, block_hash = Hash,
           sigs = [{<<1:256>>, <<2:512>>}]}.

era_transfer_finishes_the_group_and_stops_at_the_receivers_material_root_test() ->
    with_era_store(fun(Dir, Ns, Genesis, Tx, Era, Anchor) ->
        {[First, Second], _} = era_materials(2, Tx, Era, Anchor),
        {ok, Carrier} = quod_ledger:new_block({Era, 3}, quod_ledger:block_ref(Second), empty, 1),
        Cert = archive_cert(Carrier),
        E2 = quod_ledger:entry(2, First, Cert), E3 = quod_ledger:entry(3, Second, Cert),
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, {none, [Genesis]}),
        Snapshot = quod_ledger_store:snapshot(S1),
        {ok, S2} = quod_ledger_store:append(S1, {proof_source([Carrier, Second, First]), [E2, E3]}),
        {ok, Old} = quod_ledger_store:open_ro_snapshot(Snapshot),
        ?assertEqual(not_found, quod_ledger_store:transfer_cursor(Old, 2)),
        ?assertEqual([{entry, encoded_entry(Genesis)}], transfer_parts(Old, 1, 1)),
        ok = quod_ledger_store:close(Old),
        ?assertEqual([{entry, encoded_entry(E2)}, {entry, encoded_entry(E3)},
                      {proof, Carrier#block.block_bytes}, {proof, Second#block.block_bytes},
                      {proof, First#block.block_bytes}], transfer_parts(S2, 2, 3)),
        %% The receiver already owns First, including its certified prefix.
        %% Do not resend First or expose local archive offsets as a claim.
        ?assertEqual([{entry, encoded_entry(E3)}, {proof, Carrier#block.block_bytes},
                      {proof, Second#block.block_bytes}], transfer_parts(S2, 3, 3)),
        {ok, Next} = quod_ledger:new_block({Era, 4}, quod_ledger:block_ref(Carrier), {batch, [Tx]}, 1),
        E4 = quod_ledger:entry(4, Next, archive_cert(Next)),
        {ok, S3} = quod_ledger_store:append(S2, {{extend, proof_source([Next]), 2}, [E4]}),
        ?assertEqual([{entry, encoded_entry(E4)}, {proof, Next#block.block_bytes},
                      {proof, Carrier#block.block_bytes}], transfer_parts(S3, 4, 4)),
        ok = quod_ledger_store:close(S3)
    end).

era_transfer_keeps_its_cursor_across_a_proof_larger_than_a_network_page_test_() ->
    {timeout, 30, fun() ->
      with_era_store(fun(Dir, Ns, Genesis, Tx, Era, Anchor) ->
        {[First], _} = era_materials(1, Tx, Era, Anchor),
        {Carriers, _} = lists:foldl(fun(V, {Acc, Parent}) ->
            {ok, B} = quod_ledger:new_block({Era, V}, Parent, empty, 1),
            {[B | Acc], quod_ledger:block_ref(B)}
        end, {[], quod_ledger:block_ref(First)}, lists:seq(2, 8001)),
        Entry = quod_ledger:entry(2, First, archive_cert(hd(Carriers))),
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, {none, [Genesis]}),
        {ok, S2} = quod_ledger_store:append(S1, {proof_source(Carriers ++ [First]), [Entry]}),
        {ok, 2, Cur} = quod_ledger_store:transfer_cursor(S2, 2),
        {{Count, Bytes}, Reads, ReadBytes} = count_archive_reads(fun() ->
            count_transfer_parts(S2, Cur, 0, 0)
        end),
        ?assertEqual(8002, Count),
        ?assert(Bytes > 900 * 1024),
        %% A retained cursor consumes slabs, not one seek/scan per proof link.
        ?assert(Reads < 20),
        ?assert(ReadBytes < Bytes + 3 * ?READ_CHUNK),
        ok = quod_ledger_store:close(S2)
      end)
    end}.

encoded_entry(E) -> {ok, Bytes} = quod_ledger:encode_entry(E), Bytes.

era_proof_stage_can_be_consumed_by_the_append_owner_and_dies_with_its_worker_test() ->
    with_era_store(fun(Dir, Ns, Genesis, Tx, Era, Anchor) ->
        {[First], [Entry]} = era_materials(1, Tx, Era, Anchor),
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, {none, [Genesis]}),
        Parent = self(),
        StagePath = filename:join(Dir, ".proof-worker-test"),
        {Worker, MRef} = spawn_monitor(fun() ->
            quod_ledger_store:with_proof_stage(StagePath, fun(Stage) ->
                Filled = quod_ledger_store:stage_proof(Stage, First#block.block_bytes),
                Source = quod_ledger_store:staged_proof_source(Filled),
                {monitored_by, Watchers} = process_info(self(), monitored_by),
                [FileProcess] = Watchers -- [Parent],
                Parent ! {staged, self(), Source, FileProcess},
                receive finish_stage -> ok end
            end)
        end),
        receive {staged, Worker, Source, FileProcess} ->
            %% The append owner has its own raw archive handle and reads the
            %% worker-owned, unnamed stage through the standard file process.
            FRef = monitor(process, FileProcess),
            {ok, Names} = file:list_dir(Dir),
            ?assertEqual([], [N || N <- Names, lists:prefix(".proof-", N)]),
            {ok, S2} = quod_ledger_store:append(S1, {Source, [Entry]}),
            ?assertEqual([First#block.block_bytes], proof_bytes(S2, 2)),
            exit(Worker, kill),
            receive {'DOWN', MRef, process, Worker, killed} -> ok end,
            _ = file:delete(StagePath),
            receive {'DOWN', FRef, process, FileProcess, _} -> ok end,
            {_, Next, Cursor} = Source,
            ?assertException(error, {invalid_proof_stage, _}, Next(Cursor)),
            ok = quod_ledger_store:close(S2);
        {'DOWN', MRef, process, Worker, Reason} -> error({stage_worker_failed, Reason})
        end
    end).

transfer_parts(S, First, Last) ->
    {ok, Last, C} = quod_ledger_store:transfer_cursor(S, First),
    collect_transfer_parts(S, C, []).
collect_transfer_parts(S, C, Acc) ->
    case quod_ledger_store:transfer_next(S, C) of
        done -> lists:reverse(Acc);
        {ok, Part, Next} -> collect_transfer_parts(S, Next, [Part | Acc])
    end.
count_transfer_parts(S, C, Count, Bytes) ->
    case quod_ledger_store:transfer_next(S, C) of
        done -> {Count, Bytes};
        {ok, {_, Part}, Next} -> count_transfer_parts(S, Next, Count + 1, Bytes + byte_size(Part))
    end.

proof_source(Blocks) ->
    Bytes = [B#block.block_bytes || B <- Blocks],
    {lists:sum([13 + byte_size(B) || B <- Bytes]),
     fun([]) -> done; ([B | Rest]) -> {B, Rest} end, Bytes}.

proof_bytes(Store, I) ->
    {ok, Cursor} = quod_ledger_store:proof_cursor(Store, I),
    proof_bytes_loop(Store, Cursor, []).
proof_bytes_loop(Store, Cursor, Acc) ->
    case quod_ledger_store:proof_next(Store, Cursor) of
        done -> lists:reverse(Acc);
        {ok, Bytes, Next} -> proof_bytes_loop(Store, Next, [Bytes | Acc])
    end.

%%%===================================================================
%%% fixtures
%%%===================================================================

setup() ->
    Dir = filename:join("/tmp", "quod_store_test_" ++
                        binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
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
    store_entry(I, data(I)).

%% Storage-only fixtures: certificates are shape-valid; the history verifier
%% owns ancestry and committee authority, exercised by the era tests above.
store_entry(I, Payload) ->
    {Position, Parent} = case I of
        1 -> {{genesis, 0}, none};
        _ -> {{<<1:256>>, I - 1}, {<<1:256>>, I - 2, <<0:256>>}}
    end,
    {ok, Block} = quod_ledger:new_block(Position, Parent, Payload, 0),
    Cert = case I of 1 -> none; _ -> archive_cert(Block) end,
    quod_ledger:entry(I, Block, Cert).

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
        {ok, S1} = quod_ledger_store:append(S0, {none, [ent(1), ent(2), ent(3)]}),
        ?assertEqual(3, quod_ledger_store:last(S1)),
        {ok, [E1, E2, E3]} = quod_ledger_store:read_range(S1, 1, 3, all),
        ?assertEqual(1, entry_index(E1)),
        ?assertEqual(2, entry_index(E2)),
        ?assertEqual(3, entry_index(E3)),
        {ok, E2b} = quod_ledger_store:read_at(S1, 2),
        ?assertEqual(data(2), entry_data(E2b)),
        %% a non-contiguous append is rejected (the store is append-only, in slot order)
        ?assertError({non_contiguous_append, 3, [5]}, quod_ledger_store:append(S1, {none, [ent(5)]})),
        ok = quod_ledger_store:close(S1)
    end.

%% The store persists the ledger's canonical envelope unchanged; application
%% bytes inside a transaction remain byte-exact across reopen.
t_opaque_payload_roundtrip({Dir, Ns}) ->
    fun() ->
        Opaque = <<0, 1, 2, 255>>,
        Data = {batch, [(chg(1))#transaction{
                           diff = [{assert, {{fact, Opaque}, true}}]}]},
        Entry = store_entry(1, Data),
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, {none, [Entry]}),
        {ok, ExpectedEnvelope} = quod_ledger:encode_entry(Entry),
        LogPath = filename:join([Dir, base64url(Ns), "log.0001"]),
        ?assertEqual({ok, raw_group(0, 1, [ExpectedEnvelope])}, file:read_file(LogPath)),
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
                             {quod_block, 2, genesis, 0, none,
                              {batch, [{transaction, TransactionBytes}]}, 0},
                             1024 * 1024),
        {ok, Entry} = quod_ledger:from_entry_view(
                       #entry{index = 1, data = {batch, [Transaction]},
                              timestamp = 0, block_bytes = BlockBytes, cert = none}),
        ?assertException(error, badarg,
                         binary_to_existing_atom(Name, utf8)),
        {ok, S0} = quod_ledger_store:open(Ns, Dir, wrapped),
        {ok, S1} = quod_ledger_store:append(S0, {none, [Entry]}),
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
        {ok, S1} = quod_ledger_store:append(S0, {none, [ent(1), ent(2)]}),
        ok = quod_ledger_store:close(S1),
        {ok, S2} = quod_ledger_store:open(Ns, Dir),
        ?assertEqual(2, quod_ledger_store:last(S2)),
        ?assertMatch({ok, [_, _]}, quod_ledger_store:read_range(S2, 1, 2, all)),
        ok = quod_ledger_store:close(S2)
    end.

%% Catch-up workers reuse the writer's verified sparse index but open their own
%% raw descriptor, preserving the one-process ownership rule.
t_read_snapshot_preserves_verified_index({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, {none, [ent(1), ent(2), ent(3)]}),
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
        {ok, S1} = quod_ledger_store:append(S0, {none, [ent(1)]}),
        Session = quod_ledger_store:snapshot(S1),
        {ok, S2} = quod_ledger_store:append(S1, {none, [ent(2)]}),
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
        {ok, S1} = quod_ledger_store:append(S0, {none, [ent(1), ent(2)]}),
        Session = quod_ledger_store:snapshot(S1),
        ok = quod_ledger_store:close(S1),
        {ok, S2} = quod_ledger_store:resume(Session),
        ?assertEqual(2, quod_ledger_store:last(S2)),
        {ok, S3} = quod_ledger_store:append(S2, {none, [ent(3)]}),
        ?assertMatch({ok, #entry{index = 3}},
                     read_view(quod_ledger_store:read_at(S3, 3))),
        ok = quod_ledger_store:close(S3)
    end.

%% A stale session never overwrites or trims work performed after it was
%% captured. The ordinary open path remains the sole recovery owner.
t_resume_snapshot_refuses_a_changed_file({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, {none, [ent(1)]}),
        Session = quod_ledger_store:snapshot(S1),
        {ok, S2} = quod_ledger_store:append(S1, {none, [ent(2)]}),
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
        {ok, S1} = quod_ledger_store:append(S0, {none, [ent(1), ent(2), ent(3)]}),
        ok = quod_ledger_store:close(S1),
        {ok, RO} = quod_ledger_store:open_ro(Ns, Dir),
        ?assertEqual(3, quod_ledger_store:last(RO)),
        ?assertMatch({ok, [_, _, _]}, quod_ledger_store:read_range(RO, 1, 3, all)),
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
        {ok, S1} = quod_ledger_store:append(S0, {none, [ent(1), ent(2), ent(3)]}),
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
                  {ok, S1} = quod_ledger_store:append(S0, {none, [ent(1)]}),
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
        {ok, S1} = quod_ledger_store:append(S0, {none, [ent(1), ent(2)]}),
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
        ?assertMatch({ok, [_, _]}, quod_ledger_store:read_range(RO, 1, 2, all)),
        ok = quod_ledger_store:close(RO),
        ?assertEqual(TornSize, filelib:file_size(LogPath)),     %% open_ro left the torn tail (SAFE)
        {ok, W} = quod_ledger_store:open(Ns, Dir),              %% the writer's open DOES trim it
        ok = quod_ledger_store:close(W),
        ?assertEqual(ValidSize, filelib:file_size(LogPath))
    end.

t_torn_tail_recovery({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, {none, [ent(1), ent(2), ent(3)]}),
        ok = quod_ledger_store:close(S1),
        %% simulate a crash mid-append: a partial/garbage tail on the log file
        LogPath = filename:join([Dir, base64url(Ns), "log.0001"]),
        {ok, Fd} = file:open(LogPath, [read, write, raw, binary]),
        {ok, _} = file:position(Fd, eof),
        ok = file:write(Fd, <<"torn">>),   %% < a full header → trimmed on reopen
        ok = file:close(Fd),
        {ok, S2} = quod_ledger_store:open(Ns, Dir),
        ?assertEqual(3, quod_ledger_store:last(S2)),
        ?assertMatch({ok, [_, _, _]}, quod_ledger_store:read_range(S2, 1, 3, all)),
        ok = quod_ledger_store:close(S2)
    end.

%% A bad-CRC FINAL frame (a crash that fully wrote the length but corrupted the payload,
%% with nothing after it) is still a torn tail → trimmed, earlier entries kept.
t_torn_tail_bad_crc_trims({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, Prefix} = quod_ledger_store:append(S0, {none, [ent(1), ent(2)]}),
        {ok, S1} = quod_ledger_store:append(Prefix, {none, [ent(3)]}),
        ok = quod_ledger_store:close(S1),
        LogPath = filename:join([Dir, base64url(Ns), "log.0001"]),
        {ok, Fd} = file:open(LogPath, [read, write, raw, binary]),
        {ok, Size} = file:position(Fd, eof),
        {ok, <<B>>} = file:pread(Fd, Size - 1, 1),     %% tear the final group's completion footer
        ok = file:pwrite(Fd, Size - 1, <<(B bxor 16#FF)>>),
        ok = file:close(Fd),
        {ok, S2} = quod_ledger_store:open(Ns, Dir),
        ?assertEqual(2, quod_ledger_store:last(S2)),  %% incomplete group 3 trimmed, preceding group kept
        ?assertMatch({ok, [_, _]}, quod_ledger_store:read_range(S2, 1, 2, all)),
        ok = quod_ledger_store:close(S2)
    end.

%% A corrupt INTERIOR frame (bad CRC) FOLLOWED by a valid frame is NOT a torn tail — a
%% crash can only damage the last write — so it is mid-log corruption: open/2 fail-stops
%% rather than silently discarding the durably-committed entries after it.
t_interior_corruption_fail_stops({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, {none, [ent(1), ent(2), ent(3)]}),
        ok = quod_ledger_store:close(S1),
        LogPath = filename:join([Dir, base64url(Ns), "log.0001"]),
        {ok, Fd} = file:open(LogPath, [read, write, raw, binary]),
        {ok, <<B>>} = file:pread(Fd, 14, 1),           %% a byte inside frame 1's payload (hdr=12)
        ok = file:pwrite(Fd, 14, <<(B bxor 16#FF)>>),  %% frames 2 & 3 still follow intact
        ok = file:close(Fd),
        ?assertError({log_corruption, _, _}, quod_ledger_store:open(Ns, Dir))
    end.

%% A completed group beyond several scan windows prevents truncation of a
%% corrupt prefix. Bare current-format markers do not prove completion.
t_chunked_tail_detects_distant_magic({Dir, Ns}) ->
    fun() ->
        Path = prepare_log_path(Dir, Ns),
        Filler = binary:copy(<<0>>, 2 * ?READ_CHUNK + 17),
        FooterAt = 4 + byte_size(Filler),
        Footer = raw_frame_payload(?MAGIC, <<3, 0:64, (FooterAt + 29):64>>),
        Bytes = <<0:32, Filler/binary, Footer/binary>>,
        ok = file:write_file(Path, Bytes),
        ?assertError({log_corruption, bad_magic, 0}, quod_ledger_store:open(Ns, Dir)),
        ?assertEqual({ok, Bytes}, file:read_file(Path))
    end.

%% The three-byte overlap must find a footer or an identifiable old-format
%% marker even when its magic is split across scan buffers.
t_chunked_tail_detects_split_magic({Dir, Ns}) ->
    fun() ->
        Path = prepare_log_path(Dir, Ns),
        [begin
             Filler = binary:copy(<<0>>, ?READ_CHUNK - PrefixBytes),
             At = 4 + byte_size(Filler),
             Suffix = case Version of
                 current -> raw_frame_payload(Magic, <<3, 0:64, (At + 29):64>>);
                 _ -> <<Magic:32>>
             end,
             Bytes = <<0:32, Filler/binary, Suffix/binary>>,
             ok = file:write_file(Path, Bytes),
             Expected = case Version of
                 current -> {log_corruption, bad_magic, 0};
                 _ -> {unsupported_ledger_format, Version, At}
             end,
             ?assertError(Expected, quod_ledger_store:open(Ns, Dir)),
             ?assertEqual({ok, Bytes}, file:read_file(Path))
         end || {Version, Magic} <- [{current, ?MAGIC} | legacy_formats()],
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
        {ok, S1} = quod_ledger_store:append(S0, {none, [ent(I) || I <- lists:seq(1, N)]}),
        ?assertEqual(N, quod_ledger_store:last(S1)),
        {ok, E256} = quod_ledger_store:read_at(S1, 256),   %% farthest from its checkpoint (255 hops)
        ?assertEqual(data(256), entry_data(E256)),
        {ok, E257} = quod_ledger_store:read_at(S1, 257),   %% exactly on a checkpoint (0 hops)
        ?assertEqual(data(257), entry_data(E257)),
        {ok, Es} = quod_ledger_store:read_range(S1, 250, 520, all),   %% one run across two boundaries
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
        {ok, S1} = quod_ledger_store:append(S0, {none, [ent(I) || I <- lists:seq(1, 300)]}),   %% cps at 1, 257
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
        {ok, Run} = quod_ledger_store:read_range(S2, 250, 300, all),                        %% crosses the boundary
        ?assertEqual(lists:seq(250, 300), [entry_index(E) || E <- Run]),
        {ok, S3} = quod_ledger_store:append(S2, {none, [ent(I) || I <- lists:seq(301, 600)]}), %% resumes; cps at 513
        ?assertMatch({ok, #entry{index = 513}}, read_view(quod_ledger_store:read_at(S3, 513))),
        {ok, Run2} = quod_ledger_store:read_range(S3, 500, 520, all),
        ?assertEqual(lists:seq(500, 520), [entry_index(E) || E <- Run2]),
        ok = quod_ledger_store:close(S3)
    end.

%% A completed group with a wrong first index is corruption, including when
%% alone: its footer proves that it is not an interrupted append to trim.
t_rejects_wrong_first_index({Dir, Ns}) ->
    fun() ->
        LogPath = prepare_log_path(Dir, Ns),
        {ok, WrongHead} = quod_safe_term:encode_canonical(
                            {quod_entry, 2, 0, none, none}, 1024),
        BadEntry = raw_group(0, 1, [WrongHead]),
        ok = file:write_file(LogPath, BadEntry),
        ?assertError({log_corruption, bad_entry, _}, quod_ledger_store:open(Ns, Dir)),
        ?assertEqual({ok, BadEntry}, file:read_file(LogPath)),
        WrongGroup = raw_frame(ent(5)),
        ok = file:write_file(LogPath, WrongGroup),
        ?assertError({log_corruption, bad_group_header, 0}, quod_ledger_store:open(Ns, Dir)),
        ?assertEqual({ok, WrongGroup}, file:read_file(LogPath))
    end.

%% fold/5 must FAIL LOUDLY when asked past the live tail — a caller that believes more is
%% committed than the store holds must never get a silent partial fold. Empty ranges are fine.
t_fold_beyond_tail({Dir, Ns}) ->
    fun() ->
        {ok, S0} = quod_ledger_store:open(Ns, Dir),
        {ok, S1} = quod_ledger_store:append(S0, {none, [ent(1), ent(2), ent(3)]}),
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
        {ok, S1} = quod_ledger_store:append(S0, {none, [ent(1), ent(2)]}),
        ok = quod_ledger_store:close(S1),
        LogPath = filename:join([Dir, base64url(Ns), "log.0001"]),
        {ok, Fd} = file:open(LogPath, [read, write, raw, binary]),
        {ok, _} = file:position(Fd, eof),
        ok = file:write(Fd, <<?MAGIC:32, 16#7FFFFFFF:32, 0:32, "junk">>),   %% Len = 2 GiB
        ok = file:close(Fd),
        {ok, S2} = quod_ledger_store:open(Ns, Dir),
        ?assertEqual(2, quod_ledger_store:last(S2)),
        ?assertMatch({ok, [_, _]}, quod_ledger_store:read_range(S2, 1, 2, all)),
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
          fun({Version, Magic}) ->
              Path = prepare_log_path(Dir, Ns),
              Corrupt = bad_crc_raw_frame(ent(1)),
              Legacy = raw_frame(Magic, ent(2)),
              Bytes = <<Corrupt/binary, Legacy/binary>>,
              LegacyOffset = byte_size(Corrupt),
              ok = file:write_file(Path, Bytes),
              ?assertError(
                 {unsupported_ledger_format, Version, LegacyOffset},
                 quod_ledger_store:open(Ns, Dir)),
              ?assertEqual({ok, Bytes}, file:read_file(Path))
          end, legacy_formats())
    end.

%% mirror of quod_ledger_store's frame/1 for hand-crafting log files in tests
raw_frame(Entry) ->
    {ok, Payload} = quod_ledger:encode_entry(Entry),
    raw_group(0, quod_ledger:entry_index(Entry), [Payload]).

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

raw_group(Start, First, Entries) ->
    Data = iolist_to_binary([raw_frame_payload(?MAGIC, <<2, B/binary>>) || B <- Entries]),
    Header = raw_frame_payload(?MAGIC,
        <<0, First:64, (length(Entries)):64, 0:64, (byte_size(Data)):64, 0:64, 0:64, 0:64>>),
    End = Start + byte_size(Header) + byte_size(Data) + 29,
    <<Header/binary, Data/binary, (raw_frame_payload(?MAGIC, <<3, Start:64, End:64>>))/binary>>.

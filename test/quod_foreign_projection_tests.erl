-module(quod_foreign_projection_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_ledger.hrl").

materializer_pins_owner_session_across_append_without_path_scan_test() ->
    Suffix = binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(16), lowercase)),
    Dir = filename:join("/tmp", "quod-materializer-session-" ++ Suffix),
    try materializer_session_case(Dir)
    after _ = file:del_dir_r(Dir)
    end.

materializer_session_case(Dir) ->
    Ns = <<"materializer-session">>,
    F = quod_ct:protocol_fixture(Ns),
    Identity = maps:get(identity, F),
    First = quod_ledger:entry(1, maps:get(genesis, F), none),
    Root = maps:get(protocol_root, maps:get(projection, F)),
    {BlocksRev, LastRef} = lists:foldl(fun(Height, {Blocks, Parent}) ->
        Diff = case Height of
            258 -> [{assert, {{materializer_value, 1}, true}}];
            _ -> []
        end,
        Block = material_block(F, Height, Parent, Diff),
        {[Block | Blocks], quod_ledger:block_ref(Block)}
    end, {[], Root}, lists:seq(2, 258)),
    Cert = quod_ct:protocol_certificate(hd(BlocksRev), F),
    Entries = [quod_ledger:entry(H, B, Cert) ||
        {H, B} <- lists:zip(lists:seq(2, 258), lists:reverse(BlocksRev))],
    {ok, Store0} = quod_ledger_store:open(Ns, Dir, wrapped),
    try
    {ok, GenesisStore} = quod_ledger_store:append(Store0, {none, [First]}),
    {ok, Store1} = quod_ledger_store:append(GenesisStore, {proof_source(BlocksRev), Entries}),
    View1 = view(Store1, Identity, lists:last(Entries)),
    ExtraBlock = material_block(F, 259, LastRef,
                               [{assert, {{materializer_value, 2}, true}}]),
    Extra = quod_ledger:entry(259, ExtraBlock, quod_ct:protocol_certificate(ExtraBlock, F)),
    {ok, Store2} = quod_ledger_store:append(Store1, {proof_source([ExtraBlock]), [Extra]}),
    View2 = view(Store2, Identity, Extra),
    {Pid, MRef, Generation} = quod_foreign_projection:start_monitor(
                                self(), Identity, filename:join(Dir, "scratch"), View1),
    try
        enable_source_trace(Pid),
        ok = quod_foreign_projection:advance(Pid, Generation, View1),
        ?assertMatch(#{height := 258, resnapshot := true}, ready(Identity, Generation)),
        ?assertMatch({ok, 258, #{}}, read_clauses(
                        Pid, Generation, [{materializer_value, 1}], 1000)),
        %% A later append cannot expand the already-admitted source snapshot.
        Calls1 = source_calls(Pid),
        ?assertEqual([], full_open_calls(Calls1)),
        %% The complete admitted local range no longer splits at 256 entries.
        ?assertEqual(1, length([ok || {open_ro_snapshot, _} <- Calls1])),
        ok = quod_foreign_projection:advance(Pid, Generation, View2),
        ?assertMatch(#{from := 258, height := 259}, ready(Identity, Generation)),
        ?assertMatch({ok, 259, #{}}, read_clauses(
                        Pid, Generation, [{materializer_value, 1}], 1000)),
        Calls2 = source_calls(Pid),
        ?assertEqual([], full_open_calls(Calls2)),
        ?assertEqual(1, length([ok || {open_ro_snapshot, _} <- Calls2])),
        ok = quod_foreign_projection:advance(Pid, Generation, View2),
        ?assertMatch(#{height := 259}, ready(Identity, Generation)),
        ?assertEqual([], source_calls(Pid))
    after
        disable_source_trace(Pid),
        quod_foreign_projection:stop(Pid),
        receive {'DOWN', MRef, process, Pid, _} -> ok after 1000 -> exit(Pid, kill) end
    end
    after quod_ledger_store:close(Store0)
    end.

full_open_trace_detects_default_wrappers_and_explicit_modes_test() ->
    Suffix = binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(16), lowercase)),
    Dir = filename:join("/tmp", "quod-materializer-trace-control-" ++ Suffix),
    Ns = <<"materializer-trace-control">>,
    try
        {ok, Store} = quod_ledger_store:open(Ns, Dir, wrapped),
        ok = quod_ledger_store:close(Store),
        Parent = self(),
        {Pid, MRef} = spawn_monitor(
          fun() ->
              receive read -> ok end,
              lists:foreach(
                fun(Open) ->
                    {ok, Reader} = Open(),
                    ok = quod_ledger_store:close(Reader)
                end,
                [fun() -> quod_ledger_store:open(Ns, Dir) end,
                 fun() -> quod_ledger_store:open(Ns, Dir, wrapped) end,
                 fun() -> quod_ledger_store:open_ro(Ns, Dir) end,
                 fun() -> quod_ledger_store:open_ro(Ns, Dir, wrapped) end]),
              Parent ! {full_open_control_complete, self()},
              receive stop -> ok end
          end),
        try
            enable_source_trace(Pid),
            Pid ! read,
            receive
                {full_open_control_complete, Pid} -> ok;
                {'DOWN', MRef, process, Pid, Reason} -> error({full_open_control_failed, Reason})
            after 1000 -> error(full_open_control_not_complete)
            end,
            %% /2 delegates locally to /3. A global /3-only trace misses that
            %% scan; the same detector used above must see both entry points.
            ?assertEqual([{open, 2}, {open, 3}, {open, 3},
                          {open_ro, 2}, {open_ro, 3}, {open_ro, 3}],
                         lists:sort(full_open_calls(source_calls(Pid))))
        after
            disable_source_trace(Pid),
            exit(Pid, kill),
            receive {'DOWN', MRef, process, Pid, _} -> ok after 1000 -> ok end
        end
    after _ = file:del_dir_r(Dir)
    end.

source_trace_mfas() ->
    [{quod_ledger_store, open, 2}, {quod_ledger_store, open, 3},
     {quod_ledger_store, open_ro, 2}, {quod_ledger_store, open_ro, 3},
     {quod_ledger_store, open_ro_snapshot, 1}].

enable_source_trace(Pid) ->
    lists:foreach(fun(MFA) -> 1 = erlang:trace_pattern(MFA, true, [local]) end,
                  source_trace_mfas()),
    1 = erlang:trace(Pid, true, [call, {tracer, self()}]),
    ok.

disable_source_trace(Pid) ->
    _ = erlang:trace(Pid, false, [call]),
    lists:foreach(fun(MFA) -> _ = erlang:trace_pattern(MFA, false, [local]) end,
                  source_trace_mfas()).

full_open_calls(Calls) ->
    [{Fun, length(Args)} || {Fun, Args} <- Calls, Fun =:= open orelse Fun =:= open_ro].

view(Store, Identity, Entry) ->
    #{owner => self(), identity => Identity, slot => quod_ledger_store:last(Store),
      snapshot => quod_ledger_store:snapshot(Store),
      projection => #{history_head =>
                        {(quod_ledger:entry_view(Entry))#entry.index, entry_hash(Entry)}}}.

material_block(#{identity := {Ns, Anchor} = Identity, signer := Signer,
                 admission := Admission, era := Era, transaction := Template},
               Height, Parent, Diff) ->
    Tx0 = Template#transaction{diff = Diff, author_seq = Height - 1,
                               submitted_at = Height, sig = none,
                               signed_bytes = none, authentication = none},
    {ok, Tx} = quod_transaction:sign({Ns, Anchor, Admission},
                                    quod_transaction:bind_id(Identity, Tx0), Signer),
    {ok, Block} = quod_ledger:new_block({Era, Height - 1}, Parent, Height, {batch, [Tx]}, Height),
    Block.

proof_source(Blocks) ->
    Bytes = [quod_ledger:block_bytes(B) || B <- Blocks],
    {lists:sum([quod_ledger_store:proof_frame_size(B) || B <- Bytes]),
     fun([]) -> done; ([B | Rest]) -> {B, Rest} end, Bytes}.

entry_hash(Entry) ->
    {ok, Block} = quod_ledger:block_from_entry(Entry),
    quod_simplex:block_hash(Block).

ready(Identity, Generation) ->
    receive {foreign_projection_ready, Identity, Generation, Result} -> Result
    after 3000 -> error(materializer_not_ready)
    end.

source_calls(Pid) ->
    Delivered = erlang:trace_delivered(Pid),
    receive {trace_delivered, Pid, Delivered} -> ok after 1000 -> error(trace_not_delivered) end,
    source_calls(Pid, []).

source_calls(Pid, Acc) ->
    receive {trace, Pid, call, {quod_ledger_store, Fun, Args}} -> source_calls(Pid, [{Fun, Args} | Acc])
    after 0 -> lists:reverse(Acc)
    end.

snapshot_readers_test_() ->
    [{atom_to_list(Disposition), fun() -> snapshot_reader_case(Disposition) end}
     || Disposition <- [complete, exception, death]].

snapshot_reader_case(Disposition) ->
    Suffix = binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(16), lowercase)),
    Dir = filename:join("/tmp", "quod-materializer-reader-" ++ Suffix),
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"materializer-reader">>,
    F = readable_fixture(Ns), Identity = maps:get(identity, F),
    Genesis = quod_ledger:entry(1, maps:get(genesis, F), none),
    Root = maps:get(protocol_root, maps:get(projection, F)),
    {ok, Store} = quod_ledger_store:open(Ns, Dir, wrapped),
    try
        {ok, S1} = quod_ledger_store:append(Store, {none, [Genesis]}),
        {S2, E2, B2} = append_value(F, 2, Root, [], one, S1),
        {Pid, MRef, Gen} = quod_foreign_projection:start_monitor(
                            self(), Identity, filename:join(Dir, "scratch"), view(S2, Identity, E2)),
        try
            quod_foreign_projection:advance(Pid, Gen, view(S2, Identity, E2)),
            #{height := 2} = ready(Identity, Gen),
            ?assertEqual({ok, 2, #{{materializer_value, 1} => [{{materializer_value, one}, {[], false}}]}},
                         read_clauses(Pid, Gen, [{materializer_value, 1}], 1000)),
            Parent = self(),
            {Reader, ReaderMonitor} = spawn_monitor(fun() ->
                Value = try quod_foreign_projection:read(Pid, Gen, quod_time:mono_ms() + 10000,
                  fun(#{height := 2, est := Est}) ->
                    Parent ! {snapshot_held, self()},
                    receive read_old -> ok after 5000 -> error(no_read_instruction) end,
                    case Disposition of
                        exception -> throw(abandoned);
                        _ -> quod_diff:interpreted_clauses(Est, {materializer_value, 1})
                    end
                  end) catch throw:abandoned -> abandoned end,
                Parent ! {old_snapshot_result, self(), Value}
            end),
            try
                receive {snapshot_held, Reader} -> ok after 1000 -> error(no_snapshot) end,
                {S3, E3, B3} = append_value(F, 3, quod_ledger:block_ref(B2), [one], two, S2),
                quod_foreign_projection:advance(Pid, Gen, view(S3, Identity, E3)),
                #{height := 3} = ready(Identity, Gen),
                ?assertEqual(1, history_count(Pid, Gen)),
                trace_reader_release(Pid, Reader, Disposition, true),
                try
                    case Disposition of
                        death -> exit(Reader, kill);
                        _ ->
                            Reader ! read_old,
                            Expected = case Disposition of
                                complete -> {ok, [{{materializer_value, one}, {[], false}}]};
                                exception -> abandoned
                            end,
                            receive {old_snapshot_result, Reader, Value} -> ?assertEqual(Expected, Value)
                            after 1000 -> error(old_snapshot_not_read)
                            end
                    end,
                    receive {'DOWN', ReaderMonitor, process, Reader, Reason} ->
                        ?assertEqual(case Disposition of death -> killed; _ -> normal end, Reason)
                    after 1000 -> error(reader_not_released)
                    end,
                    Release = case Disposition of death -> reader_down; _ -> release_snapshot end,
                    receive {trace, Pid, call, {quod_foreign_projection, Release, _}} -> ok
                    after 1000 -> error(reader_release_not_called)
                    end,
                    receive {trace, Pid, return_from, {quod_foreign_projection, Release, _}, _} -> ok
                    after 1000 -> error(reader_floor_not_released)
                    end
                after trace_reader_release(Pid, Reader, Disposition, false) end,
                {S4, E4, _B4} = append_value(F, 4, quod_ledger:block_ref(B3), [two], three, S3),
                quod_foreign_projection:advance(Pid, Gen, view(S4, Identity, E4)),
                #{height := 4} = ready(Identity, Gen),
                ?assertEqual(0, history_count(Pid, Gen)),
                ?assertMatch({ok, 4, #{{materializer_value, 1} := [{{materializer_value, three}, {[], false}}]}},
                             read_clauses(Pid, Gen, [{materializer_value, 1}], 1000)),
                ?assertEqual({error, stale}, quod_foreign_projection:read(
                              Pid, make_ref(), quod_time:mono_ms() + 1000, fun(_) -> unexpected end)),
                ?assertEqual({error, unavailable}, quod_foreign_projection:read(
                              Pid, Gen, quod_time:mono_ms(), fun(_) -> unexpected end)),
                unchanged_projection_reads(Pid, Gen),
                StopMonitor = monitor(process, Pid),
                ?assertEqual({error, unavailable}, quod_foreign_projection:read(
                    Pid, Gen, quod_time:mono_ms() + 1000, fun(Snapshot) ->
                        quod_foreign_projection:stop(Pid),
                        receive {'DOWN', StopMonitor, process, Pid, normal} -> ok
                        after 1000 -> error(owner_did_not_stop)
                        end,
                        quod_foreign_projection:clauses([{materializer_value, 1}], Snapshot)
                    end))
            after exit(Reader, kill), demonitor(ReaderMonitor, [flush]) end
        after
            quod_foreign_projection:stop(Pid),
            receive {'DOWN', MRef, process, Pid, _} -> ok after 1000 -> exit(Pid, kill) end
        end
    after quod_ledger_store:close(Store), file:del_dir_r(Dir)
    end.

history_count(Pid, Gen) ->
    quod_foreign_projection:read(Pid, Gen, quod_time:mono_ms() + 1000,
      fun(#{est := #est{db = #db{ref = Ref}}}) -> quod_erlog_db_mvcc:history_predicates(Ref) end).

append_value(F, Height, Parent, Before, Value, Store) ->
    Diff = [{retract, {{materializer_value, V}, true}} || V <- Before] ++
           [{assert, {{materializer_value, Value}, true}}],
    Block = material_block(F, Height, Parent, Diff),
    Entry = quod_ledger:entry(Height, Block, quod_ct:protocol_certificate(Block, F)),
    {ok, Next} = quod_ledger_store:append(Store, {proof_source([Block]), [Entry]}),
    {Next, Entry, Block}.

readable_fixture(Ns) ->
    F = quod_ct:protocol_fixture(Ns),
    #{signer := #{pubkey := Pub}} = F,
    Tx = quod_simplex:test_genesis_tx(
           #{external_predicate_modules => [], node_addr => {<<"localhost">>, 1},
             genesis_diff => [{assert, {{can_invoke, {'Goal'}, {'Principal'}, [], {'Ns'}}, true}}]},
           Ns, Pub, <<6:256>>),
    {ok, Genesis} = quod_ledger:new_block({genesis, 0}, none, 1, {batch, [Tx]}, 0),
    {genesis, 0, Anchor} = quod_ledger:block_ref(Genesis),
    Identity = {Ns, Anchor},
    Projection = quod_simplex:history_advance(Ns, quod_ledger:entry(1, Genesis, none),
                                             quod_simplex:history_projection(Identity)),
    F#{identity => Identity, genesis => Genesis, era => quod_ledger:initial_era(Identity),
       transaction => (maps:get(transaction, F))#transaction{origin = Identity},
       projection => Projection, admission => maps:get(Pub, maps:get(admissions, Projection))}.

trace_reader_release(Pid, Reader, Disposition, Enable) ->
    {Function, Arity, Pattern} = case Disposition of
        death -> {reader_down, 2, '_'};
        _ -> {release_snapshot, 3, [Reader, '_', '_']}
    end,
    Match = case Enable of true -> [{Pattern, [], [{return_trace}]}]; false -> false end,
    erlang:trace_pattern({quod_foreign_projection, Function, Arity}, Match, [local]),
    erlang:trace(Pid, Enable, [call, {tracer, self()}]).

unchanged_projection_reads(Pid, Gen) ->
    Parent = self(),
    {Reader, Monitor} = spawn_monitor(fun() ->
        receive check -> ok end,
        lists:foreach(fun(_) ->
            {ok, 4, _} = read_clauses(Pid, Gen, [{materializer_value, 1}], 1000)
        end, lists:seq(1, 20)),
        Parent ! {unchanged_reads_complete, self()},
        receive stop -> ok end
    end),
    Work = [{quod_committed_projection, apply_entry, 3},
            {quod_erlog_db_mvcc, commit, 3},
            {quod_ledger_store, open, 2}, {quod_ledger_store, open, 3},
            {quod_ledger_store, open_ro_snapshot, 1},
            {file, write, 2}, {file, pwrite, 3}, {file, sync, 1}, {file, datasync, 1}],
    try
        lists:foreach(fun(MFA) -> erlang:trace_pattern(MFA, true, [local]) end, Work),
        lists:foreach(fun(P) -> erlang:trace(P, true, [call, {tracer, Parent}]) end, [Pid, Reader]),
        Reader ! check,
        receive {unchanged_reads_complete, Reader} -> ok
        after 3000 -> error(unchanged_reads_not_complete)
        end,
        lists:foreach(fun(P) ->
            Delivered = erlang:trace_delivered(P),
            receive {trace_delivered, P, Delivered} -> ok
            after 1000 -> error(work_trace_not_delivered)
            end
        end, [Pid, Reader]),
        receive {trace, P, call, Call} when P =:= Pid; P =:= Reader ->
            error({unchanged_read_performed_work, Call})
        after 0 -> ok
        end
    after
        lists:foreach(fun(P) -> erlang:trace(P, false, [call]) end, [Pid, Reader]),
        lists:foreach(fun(MFA) -> erlang:trace_pattern(MFA, false, [local]) end, Work),
        Reader ! stop,
        receive {'DOWN', Monitor, process, Reader, _} -> ok after 1000 -> exit(Reader, kill) end
    end.

read_clauses(Pid, Gen, Functors, Timeout) ->
    quod_foreign_projection:read(Pid, Gen, quod_time:mono_ms() + Timeout,
      fun(Snapshot) -> quod_foreign_projection:clauses(Functors, Snapshot) end).

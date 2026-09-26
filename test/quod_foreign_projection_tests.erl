-module(quod_foreign_projection_tests).

-include_lib("eunit/include/eunit.hrl").
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
        ?assertMatch({ok, 258, #{}}, quod_foreign_projection:clauses(
                        Pid, Generation, [{materializer_value, 1}], 1000)),
        %% A later append cannot expand the already-admitted source snapshot.
        Calls1 = source_calls(Pid),
        ?assertEqual([], full_open_calls(Calls1)),
        ?assertEqual(2, length([ok || {open_ro_snapshot, _} <- Calls1])),
        ok = quod_foreign_projection:advance(Pid, Generation, View2),
        ?assertMatch(#{from := 258, height := 259}, ready(Identity, Generation)),
        ?assertMatch({ok, 259, #{}}, quod_foreign_projection:clauses(
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

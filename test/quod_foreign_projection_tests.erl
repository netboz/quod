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
    {Pub, Seed} = quod_identity:generate(),
    Signer = #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})},
    Genesis = quod_simplex:test_genesis_tx(
                #{node_id => Pub, mode => create, committee => [],
                  node_addr => {"127.0.0.1", 19000}, genesis_diff => []},
                Ns, Pub, crypto:strong_rand_bytes(32)),
    {ok, First} = quod_ledger:new_entry(1, {batch, [Genesis]}, 1, none),
    Identity = {Ns, entry_hash(First)},
    Projection = quod_simplex:history_advance(Ns, First, quod_simplex:history_projection(Identity)),
    {ok, AuthorBinding} = quod_simplex:history_binding(Identity, Pub, Projection),
    Last = material_entry(Identity, Pub, Signer, AuthorBinding, 258, 1),
    Entries = [First | [begin {ok, E} = quod_ledger:new_entry(I, noop, 0, none), E end
                        || I <- lists:seq(2, 257)]] ++ [Last],
    {ok, Store0} = quod_ledger_store:open(Ns, Dir, wrapped),
    try
    {ok, Store1} = quod_ledger_store:append(Store0, Entries),
    View1 = view(Store1, Identity, lists:last(Entries)),
    Extra = material_entry(Identity, Pub, Signer, AuthorBinding, 259, 2),
    {ok, Store2} = quod_ledger_store:append(Store1, [Extra]),
    View2 = view(Store2, Identity, Extra),
    {Pid, MRef, Generation} = quod_foreign_projection:start_monitor(
                                self(), Identity, filename:join(Dir, "scratch"), View1),
    try
        enable_source_trace(Pid),
        ok = quod_foreign_projection:advance(Pid, Generation, View1),
        ?assertMatch(#{height := 258, resnapshot := true}, ready(Identity, Generation)),
        %% A later append cannot expand the already-admitted source snapshot.
        Calls1 = source_calls(Pid),
        ?assertEqual([], full_open_calls(Calls1)),
        ?assertEqual(2, length([ok || {open_ro_snapshot, _} <- Calls1])),
        ok = quod_foreign_projection:advance(Pid, Generation, View2),
        ?assertMatch(#{from := 258, height := 259}, ready(Identity, Generation)),
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

material_entry(Identity = {Ns, Anchor}, Pub, Signer, AuthorBinding, Slot, Sequence) ->
    {ok, Goal} = quod_durable_term:encode_goal({materializer_append, Sequence}),
    {ok, Result} = quod_durable_term:encode_result(#{}),
    Tx0 = #transaction{origin = Identity,
                       proof_id = crypto:hash(sha256, term_to_binary({proof, Sequence})),
                       plan_digest = crypto:hash(sha256, term_to_binary({plan, Sequence})),
                       goal = Goal, result = Result,
                       diff = [{assert, {{materializer_value, Sequence}, true}}],
                       read_check = #{}, author = Pub, author_seq = Sequence,
                       submitted_at = Sequence + 1, sig = none},
    {ok, Tx} = quod_transaction:sign(AuthorBinding, quod_transaction:bind_id(Identity, Tx0), Signer),
    {ok, Block} = quod_ledger:new_block(Slot, Slot - 1, {batch, [Tx]}, Sequence + 1),
    Hash = quod_simplex:block_hash(Block),
    #share{sig = Signature} = quod_simplex:make_share(
                               quod_simplex:consensus_domain(Ns, Anchor), commit, Slot, Hash, Signer),
    quod_ledger:entry(Block, #cert{kind = commit, slot = Slot, block_hash = Hash, sigs = [{Pub, Signature}]}).

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

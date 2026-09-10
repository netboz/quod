-module(quod_replay_completion_tests).
-moduledoc """
Recovery closure is an owner-ordered request, independent of an old ready ack.

The fixture delegates init, ordinary callbacks, actions and termination to the
real Simplex implementation in an OTP statem registered as the actual namespace
owner. Test-only calls arrange recovery capabilities and observe state. Real
N=1 founding, certified entries, journal/store, Prolog and runtime are used; the
network recovery worker/result and observer role are controlled fixture inputs,
not a claim of full multi-node recovery. No test calls mark_ready directly.
""".
-behaviour(gen_statem).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").
-export([init/1, callback_mode/0, running/3, terminate/3, run_case/1]).

replay_completion_test_() ->
    [{atom_to_list(Case), {timeout, 30, fun() -> run_case(Case) end}}
     || Case <- [member_idle, member_multi_window, observer_multi_window,
                 observer_live_feed, initial_unconfirmed, projection_failure,
                 network_dependency, stale_worker, stale_prolog_ack,
                 prefix_not_dispatched, overtaken_by_live, successor_interval,
                 empty_and_duplicate, ordinary_progress_no_ack_loop,
                 prolog_restart, snapshot_reader_reaped]].

%% Each case has its own mailbox, including pubsub/call-trace traffic. Never
%% weaken an assertion to accommodate a preceding test's messages.
run_case(Case) ->
    Parent = self(), Ref = make_ref(),
    {Pid, Mon} = spawn_monitor(fun() ->
        Result = try with_fixture(fun(F) -> exercise(Case, F) end) of
                     _ -> ok
                 catch C:E:St -> {raise, C, E, St}
                 end,
        Parent ! {Ref, Result}
    end),
    receive
        {Ref, Result} ->
            receive {'DOWN', Mon, process, Pid, normal} -> ok end,
            case Result of
                ok -> ok;
                {raise, C, E, St} -> erlang:raise(C, E, St)
            end;
        {'DOWN', Mon, process, Pid, Reason} -> error({fixture_down, Reason})
    after 25000 ->
        exit(Pid, kill),
        receive {'DOWN', Mon, process, Pid, _} -> ok end,
        error({fixture_timeout, Case})
    end.

exercise(member_idle, F) ->
    begin_member(F),
    window(F, recovery, 2, 3, noop),
    assert_open(F, 1),
    complete_member(F, 3),
    assert_closed(F, 3),
    assert_dispatch_order(F, [2, 3], 1);
exercise(member_multi_window, F) ->
    begin_member(F),
    window(F, recovery, 2, 2, noop),
    progress(F),
    assert_open(F, 1),
    window(F, recovery, 3, 3, noop),
    progress(F),
    assert_open(F, 1),
    complete_member(F, 3),
    assert_closed(F, 3),
    assert_dispatch_order(F, [2, 3], 1);
exercise(observer_multi_window, F) ->
    make_observer(F),
    window(F, feed, 2, 2, noop),
    progress(F),
    assert_open(F, 1),
    window(F, feed, 3, 3, noop),
    progress(F),
    assert_open(F, 1),
    complete_feed(F),
    assert_closed(F, 3),
    assert_dispatch_order(F, [2, 3], 1);
exercise(observer_live_feed, F) ->
    make_observer(F),
    window(F, live_feed, 2, 2, content),
    wait_live(F, 2),
    ?assertEqual([], lifecycle()),
    ?assertEqual(1, maps:get(reconciles, stats(F))),
    ?assertEqual(1, maps:get(events_seen, stats(F))),
    ?assertEqual([], markers(trace_calls(F)));
exercise(initial_unconfirmed, F) ->
    restart_prolog_unconfirmed(F),
    ?assertMatch({error, {ontology_rebuilding, _}}, proof_access(F)),
    case prolog_field(F, ready) of
        false -> ok;
        true -> error(premature_prolog_readiness)
    end,
    begin_member(F),
    window(F, recovery, 2, 3, noop),
    assert_no_ready(),
    ?assertMatch({error, {ontology_rebuilding, _}}, proof_access(F)),
    complete_member(F, 3),
    wait_live(F, 3),
    wait_ack(F),
    ?assertMatch({ok, _}, proof_access(F));
exercise(projection_failure, F) ->
    blocked_projection(F, projection_failure, injected_projection_failure);
exercise(network_dependency, F) ->
    blocked_projection(F, apply_dependency, {network_identity, make_ref()});
exercise(stale_worker, F = #{owner := Owner}) ->
    begin_member(F),
    window(F, recovery, 2, 3, noop),
    gen_statem:cast(Owner, {sync_done, self(), {ready, 3}}),
    barrier(F),
    assert_open(F, 1),
    ?assertEqual([], markers(trace_calls(F))),
    complete_member(F, 3),
    assert_closed(F, 3);
exercise(stale_prolog_ack, F = #{owner := Owner}) ->
    restart_prolog_unconfirmed(F),
    fixture(F, fun(S) -> {ok, quod_simplex:test_state_set(sync, ready, S)} end),
    gen_statem:cast(Owner, {prolog_ready, self(), 1, []}),
    gen_statem:cast(Owner, {prolog_ready, prolog_pid(F), 0, []}),
    owner_barrier(F),
    ?assertMatch({error, {ontology_rebuilding, _}}, proof_access(F)),
    begin_member(F),
    complete_member(F, 1),
    wait_live(F, 1),
    wait_ack(F),
    ?assertMatch({ok, _}, proof_access(F));
exercise(prefix_not_dispatched, F) ->
    %% The completion request is still guarded by the dispatched prefix, not
    %% only sync=ready. This intentionally inconsistent fixture never votes.
    fixture(F, fun(S) ->
        {ok, quod_simplex:test_state_set(last_applied, 0, S)}
    end),
    make_observer(F),
    complete_feed(F),
    ?assertEqual([], markers(trace_calls(F))),
    ?assertEqual([], lifecycle());
exercise(overtaken_by_live, F) ->
    begin_member(F),
    window(F, recovery, 2, 3, noop),
    %% Drive the production live dispatch through the real verified feed sink
    %% after arranging its existing observer capability; then restore member
    %% completion ownership. This pins the overtaken interval, not a quorum run.
    make_observer(F),
    window(F, live_feed, 4, 4, content),
    wait_live(F, 4),
    Events = lifecycle(),
    [{replay_started, Id, 1}, {replay_ready, Id, 3}] = Events,
    restore_member(F),
    begin_member(F),
    complete_member(F, 3),             % actual Slot >= H rule, 4 > 3
    barrier(F),
    ?assertEqual([], lifecycle()),
    ?assertEqual(2, maps:get(reconciles, stats(F))),
    ?assertEqual([owner(F)], markers(trace_calls(F)));
exercise(successor_interval, F) ->
    %% Hold Prolog while the SAME owner queues complete interval 1 followed
    %% by interval 2. Per-sender FIFO, not scheduler timing, orders the closes.
    Kb = prolog_pid(F),
    ok = sys:suspend(Kb),
    try
        begin_member(F),
        window(F, recovery, 2, 2, noop),
        complete_member_queued(F, 2),
        begin_member(F),
        window(F, recovery, 3, 3, noop),
        complete_member_queued(F, 3)
    after ok = sys:resume(Kb)
    end,
    barrier(F),
    wait_live(F, 3),
    [{replay_started, Id1, 1}, {replay_ready, Id1, 2},
     {replay_started, Id2, 2}, {replay_ready, Id2, 3}] = lifecycle(),
    ?assertNotEqual(Id1, Id2),
    ?assertEqual([{apply, 2, replay}, mark_ready,
                  {apply, 3, replay}, mark_ready], compact_trace(F));
exercise(empty_and_duplicate, F) ->
    begin_member(F),
    window(F, recovery, 2, 3, noop),
    complete_member(F, 3),
    assert_closed(F, 3),
    _ = trace_calls(F),
    begin_member(F),
    P = projection(F),
    ?assertMatch({ok, _}, sink(F, recovery, [], P)),
    %% Already-durable entries are rejected as a stale window, never replayed.
    E = skipped(F, 3),
    ?assertEqual({error, stale_window}, sink(F, recovery, [E], P)),
    complete_member(F, 3),
    barrier(F),
    ?assertEqual([], lifecycle()),
    ?assertEqual(2, maps:get(reconciles, stats(F))),
    ?assertEqual([owner(F)], markers(trace_calls(F)));
exercise(ordinary_progress_no_ack_loop, F = #{owner := Owner}) ->
    begin_member(F),
    window(F, recovery, 2, 3, noop),
    complete_member(F, 3),
    assert_closed(F, 3),
    _ = trace_calls(F),
    [progress(F) || _ <- lists:seq(1, 5)],
    gen_statem:cast(Owner, {prolog_ready, prolog_pid(F), 3, []}),
    barrier(F),
    ?assertEqual([], trace_calls(F)),
    ?assertEqual([], lifecycle()),
    ?assertEqual(2, maps:get(reconciles, stats(F)));
exercise(prolog_restart, F) ->
    begin_member(F),
    window(F, recovery, 2, 3, noop),
    Old = prolog_pid(F),
    stop_runtime(F),
    ok = gen_server:stop(Old),
    {ok, New} = quod_prolog:start_link(namespace(F), maps:get(config, F)),
    ?assertNotEqual(Old, New),
    owner_barrier(F),
    barrier(F),
    ?assertMatch({error, {ontology_rebuilding, _}}, proof_access(F)),
    gen_statem:cast(owner(F), {prolog_ready, Old, 3, []}),
    owner_barrier(F),
    ?assertMatch({error, {ontology_rebuilding, _}}, proof_access(F)),
    {ok, _} = quod_runtime:start_link(namespace(F), #{}),
    complete_member(F, 3),
    wait_live(F, 3),
    wait_ack(F),
    ?assertMatch({ok, _}, proof_access(F));
exercise(snapshot_reader_reaped, F) ->
    Ns = namespace(F),
    ok = quod_runtime:enqueue_heavy(Ns, reader, 1, {slow, 20000000}),
    ok = quod_ct:wait_until(fun() -> maps:get(heavy_running, stats(F)) =:= 1 end),
    Rt = runtime_pid(F),
    Running = record_get(quod_runtime, heavy_running, sys:get_state(Rt)),
    [{Worker, _, _, _, _, _}] = maps:values(Running),
    Mon = monitor(process, Worker),
    ReaderMFAs = [{quod_prolog, runtime_detach, 1}, {quod_prolog, attach_runtime, 1}],
    [erlang:trace_pattern(MFA, true, [local]) || MFA <- ReaderMFAs],
    1 = erlang:trace(Rt, true, [call, strict_monotonic_timestamp, {tracer, self()}]),
    1 = erlang:trace(Worker, true, [procs, strict_monotonic_timestamp, {tracer, self()}]),
    try
        begin_member(F),
        window(F, recovery, 2, 3, noop),
        assert_open(F, 1),
        receive {'DOWN', Mon, process, Worker, _} -> ok
        after 2000 -> error(old_snapshot_reader_survived_replay)
        end,
        ?assertEqual(none, prolog_field(F, runtime_pin)),
        complete_member(F, 3),
        assert_closed(F, 3),
        ?assertEqual(0, maps:get(heavy_running, stats(F))),
        %% Same-VM strict monotonic trace timestamps order the actual exit
        %% and API calls; cross-process message arrival is not the oracle.
        Times = reader_trace(erlang:trace_delivered(all), Rt, Worker, #{}),
        Exit = maps:get(exit, Times), Detach = maps:get(runtime_detach, Times),
        Attach = maps:get(attach_runtime, Times),
        case Exit < Detach andalso Detach < Attach of
            true -> ok;
            false -> error({reader_not_reaped_before_pin_change, Times})
        end
    after
        [catch erlang:trace(P, false, [call, procs, strict_monotonic_timestamp])
         || P <- [Rt, Worker]],
        [erlang:trace_pattern(MFA, false, [local]) || MFA <- ReaderMFAs]
    end.

reader_trace(Ref, Rt, Worker, Times) ->
    receive
        {trace_ts, Worker, exit, _Reason, Time} ->
            reader_trace(Ref, Rt, Worker, Times#{exit => Time});
        {trace_ts, Rt, call, {quod_prolog, F, [_Ns]}, Time}
          when F =:= runtime_detach; F =:= attach_runtime ->
            ?assertNot(maps:is_key(F, Times)),
            reader_trace(Ref, Rt, Worker, Times#{F => Time});
        {trace_delivered, all, Ref} -> Times
    after 2000 -> error(reader_trace_barrier_missing)
    end.

blocked_projection(F, Field, Value) ->
    begin_member(F),
    window(F, recovery, 2, 3, noop),
    assert_open(F, 1),
    sys:replace_state(prolog_pid(F), fun(S) ->
        record_set(quod_prolog, Field, Value,
          record_set(quod_prolog, ready, false, S))
    end),
    complete_member(F, 3),
    assert_open(F, 1),
    ?assertEqual(false, prolog_field(F, ready)),
    ?assertEqual([owner(F)], markers(trace_calls(F))).

%% Production init/callback/actions/terminate; only fixture calls arrange state.
callback_mode() -> [state_functions].
init({Ns, Config}) -> quod_simplex:init({Ns, Config}).
running({call, From}, {fixture, Fun}, S) ->
    {Reply, Next} = Fun(S),
    {keep_state, Next, [{reply, From, Reply}]};
running({call, From}, fixture_tick, S) ->
    {keep_state, Next, Actions} = quod_simplex:running({timeout, tick}, tick, S),
    {keep_state, Next, [{reply, From, ok} | Actions]};
running(Type, Event, S) -> quod_simplex:running(Type, Event, S).
terminate(Reason, Name, S) -> quod_simplex:terminate(Reason, Name, S).

with_fixture(Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(10), lowercase),
    Ns = <<"replay-close:", Suffix/binary>>,
    Dir = filename:join("/tmp", "quod-replay-close-" ++ binary_to_list(Suffix)),
    ok = file:make_dir(Dir),
    {Pub, Seed} = quod_identity:generate(),
    Identity = #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})},
    Terms = [{founding_marker, true}, {slow, 0},
             {':-', {slow, {'N'}},
              {',', {'>', {'N'}, 0},
               {',', {is, {'N1'}, {'-', {'N'}, 1}}, {slow, {'N1'}}}}}],
    Config = #{node_id => Pub, identity => Identity, data_dir => Dir,
               mode => create, genesis_diff => quod_prolog:terms_to_diff(Terms)},
    {ok, Owner} = gen_statem:start_link(
                    quod_reg:via({quod_simplex, Ns}), ?MODULE, {Ns, Config}, []),
    Worker = spawn_link(fun worker/0),
    F = #{ns => Ns, owner => Owner, worker => Worker, identity => Identity,
          config => Config, dir => Dir},
    try
        {ok, _} = quod_prolog:start_link(Ns, Config),
        {ok, _} = quod_runtime:start_link(Ns, #{}),
        wait_live(F, 1),
        wait_ack(F),
        true = quod_reg:subscribe({runtime, Ns}),
        trace_start(F),
        try Fun(F)
        after
            trace_stop(F),
            true = quod_reg:unsubscribe({runtime, Ns})
        end
    after
        stop_runtime(F),
        stop_registered(quod_prolog, Ns),
        gen_statem:stop(Owner),
        Mon = monitor(process, Worker), Worker ! stop,
        receive {'DOWN', Mon, process, Worker, _} -> ok end,
        ok = file:del_dir_r(Dir)
    end.

worker() -> receive stop -> ok end.
owner(#{owner := P}) -> P.
namespace(#{ns := N}) -> N.
prolog_pid(F) -> quod_reg:where({quod_prolog, namespace(F)}).
runtime_pid(F) -> quod_reg:where({quod_runtime, namespace(F)}).
stats(F) -> quod_runtime:stats(namespace(F)).
proof_access(F) -> quod_simplex:acquire_proof_access(namespace(F)).
fixture(#{owner := P}, Fun) -> gen_statem:call(P, {fixture, Fun}, 5000).
owner_barrier(F) -> fixture(F, fun(S) -> {ok, S} end).
barrier(F) -> owner_barrier(F), ok = quod_prolog:sync(namespace(F)).

begin_member(F = #{worker := W}) ->
    fixture(F, fun(S) -> {ok, quod_simplex:test_state_set(sync, {pulling, W}, S)} end).
restore_member(F = #{identity := #{pubkey := Pub}}) ->
    fixture(F, fun(S) -> {ok, quod_simplex:test_state_set(self, Pub, S)} end).
make_observer(F) ->
    fixture(F, fun(S) ->
        {ok, quod_simplex:test_state_set(sync, ready,
               quod_simplex:test_state_set(self, <<0:256>>, S))}
    end).
complete_member_queued(#{owner := P, worker := W} = F, H) ->
    gen_statem:cast(P, {sync_done, W, {ready, H}}), owner_barrier(F).
complete_member(F, H) -> complete_member_queued(F, H), barrier(F).
complete_feed(F) ->
    ?assertEqual(ok, gen_statem:call(owner(F), finish_feed_replay)), barrier(F).
progress(F) ->
    ok = gen_statem:call(owner(F), fixture_tick),
    barrier(F).
projection(F) ->
    fixture(F, fun(S) -> {quod_simplex:test_state_projection(S), S} end).

window(F, Source, First, Last, Kind) ->
    P0 = projection(F),
    Es = [entry(F, H, Kind, P0) || H <- lists:seq(First, Last)],
    P1 = lists:foldl(fun(E, P) ->
        ?assertEqual(ok, quod_catchup:verify_entry(target(F), E, P)),
        quod_simplex:history_advance(namespace(F), E, P)
    end, P0, Es),
    ?assertMatch({ok, _}, sink(F, Source, Es, P1)).
sink(F = #{worker := W}, Source, Es, P) ->
    Capability = case Source of recovery -> {recovery, W};
                               feed -> {feed, replay};
                               live_feed -> {feed, live}
                 end,
    gen_statem:call(owner(F), {sink_catchup, Capability, Es, P}, 5000).
target(F) -> {namespace(F), quod_simplex:genesis_hash(namespace(F))}.
domain(F) -> quod_simplex:consensus_domain(namespace(F), element(2, target(F))).
entry(F, H, noop, _P) -> skipped(F, H);
entry(F = #{identity := Id = #{pubkey := Pub}}, H, content, P) ->
    Tx0 = quod_ct:change(namespace(F), quod_ct:diff_for({live_marker, H})),
    Tx = Tx0#transaction{author = Pub, author_seq = H},
    {ok, Binding} = quod_simplex:history_binding(target(F), Pub, P),
    {ok, Signed} = quod_transaction:sign(Binding, Tx, Id),
    {ok, Block} = quod_ledger:new_block(H, H - 1, {batch, [Signed]}, 0),
    Hash = quod_simplex:block_hash(Block),
    Share = quod_simplex:make_share(domain(F), commit, H, Hash, Id),
    {ok, Cert} = quod_simplex:form_cert(domain(F), commit, H, Hash, [Share], [Pub]),
    quod_ledger:entry(Block, Cert).
skipped(F = #{identity := Id = #{pubkey := Pub}}, H) ->
    Share = quod_simplex:make_share(domain(F), complaint, H, none, Id),
    {ok, Cert} = quod_simplex:form_cert(domain(F), complaint, H, none, [Share], [Pub]),
    quod_ledger:noop_entry(H, Cert).

wait_live(F, H) ->
    ok = quod_ct:wait_until(fun() ->
        case stats(F) of
            #{mode := live, p_height := H, e_frontier := H,
              runner_active := false, queue_len := 0} -> true;
            _ -> false
        end
    end).
wait_ack(F) ->
    ok = quod_ct:wait_until(fun() ->
        maps:get(prolog_ready, quod_simplex:stats(namespace(F)))
    end).
assert_open(F, H) ->
    barrier(F),
    assert_no_ready(),
    ok = quod_ct:wait_until(fun() ->
        case stats(F) of
            #{mode := replaying, p_height := H, runner_active := false} -> true;
            _ -> false
        end
    end),
    assert_no_ready().
assert_no_ready() ->
    receive E = {replay_ready, _, _} -> error({premature_replay_close, E})
    after 0 -> ok end.
assert_closed(F, H) ->
    case lifecycle() of
        [{replay_started, Id, 1}, {replay_ready, Id, H}] -> ok;
        Events -> error({missing_or_misordered_replay_close, Events})
    end,
    wait_live(F, H),
    ?assertEqual(2, maps:get(reconciles, stats(F))),
    ?assertEqual(0, maps:get(events_seen, stats(F))),
    ?assertEqual(H, quod_prolog:applied(namespace(F))).
lifecycle() -> lifecycle([]).
lifecycle(Acc) ->
    receive E = {replay_started, _, _} -> lifecycle([E | Acc]);
            E = {replay_ready, _, _} -> lifecycle([E | Acc])
    after 0 -> lists:reverse(Acc)
    end.

trace_start(#{owner := P, worker := W}) ->
    [erlang:trace_pattern(MFA, true, [local])
     || MFA <- [{quod_prolog, apply_entry, 3}, {quod_prolog, mark_ready, 1}]],
    [erlang:trace(Pid, true, [call, set_on_spawn, {tracer, self()}]) || Pid <- [P, W]],
    ok.
trace_stop(#{owner := P, worker := W}) ->
    [catch erlang:trace(Pid, false, [call, set_on_spawn]) || Pid <- [P, W]],
    [erlang:trace_pattern(MFA, false, [local])
     || MFA <- [{quod_prolog, apply_entry, 3}, {quod_prolog, mark_ready, 1}]],
    ok.
trace_calls(F) ->
    owner_barrier(F),
    Ref = erlang:trace_delivered(all),
    trace_calls(Ref, []).
trace_calls(Ref, Acc) ->
    receive
        {trace, Pid, call, {quod_prolog, mark_ready, [_Ns]}} ->
            trace_calls(Ref, [{Pid, mark_ready} | Acc]);
        {trace, Pid, call, {quod_prolog, apply_entry, [_Ns, E, Origin]}} ->
            H = (quod_ledger:entry_view(E))#entry.index,
            trace_calls(Ref, [{Pid, {apply, H, Origin}} | Acc]);
        {trace_delivered, all, Ref} -> lists:reverse(Acc)
    after 2000 -> error(trace_barrier_missing)
    end.
markers(Calls) -> [P || {P, mark_ready} <- Calls].
compact_trace(F) ->
    Calls = trace_calls(F),
    case lists:all(fun({P, _}) -> P =:= owner(F) end, Calls) of
        true -> ok;
        false -> error({closure_not_from_simplex_owner, Calls})
    end,
    [E || {_P, E} <- Calls].
assert_dispatch_order(F, Heights, Marks) ->
    Calls = compact_trace(F),
    ?assertEqual([{apply, H, replay} || H <- Heights] ++
                 lists:duplicate(Marks, mark_ready), Calls).

restart_prolog_unconfirmed(F) ->
    stop_runtime(F),
    fixture(F, fun(S) -> {ok, quod_simplex:test_state_set(sync, unconfirmed, S)} end),
    ok = gen_server:stop(prolog_pid(F)),
    {ok, _} = quod_prolog:start_link(namespace(F), maps:get(config, F)),
    barrier(F),
    {ok, _} = quod_runtime:start_link(namespace(F), #{}),
    _ = lifecycle(),
    _ = trace_calls(F),
    ok.
stop_runtime(F) -> stop_registered(quod_runtime, namespace(F)).
stop_registered(Mod, Ns) ->
    case quod_reg:where({Mod, Ns}) of
        undefined -> ok;
        Pid -> gen_server:stop(Pid)
    end.
prolog_field(F, Field) -> record_get(quod_prolog, Field, sys:get_state(prolog_pid(F))).
record_get(Mod, Name, S) -> element(record_index(Mod, Name), S).
record_set(Mod, Name, Value, S) -> setelement(record_index(Mod, Name), S, Value).
record_index(Mod, Name) ->
    %% Read the compiled record layout instead of hardcoding private offsets.
    %% Used only for named failure/snapshot-reader fixture state, never a dump.
    {ok, {Mod, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
        beam_lib:chunks(code:which(Mod), [abstract_code]),
    [{attribute, _, record, {s, Fields}}] =
        [X || X = {attribute, _, record, {s, _}} <- Forms],
    Names = [field_name(X) || X <- Fields],
    [Index] = [I || {N, I} <- lists:zip(Names, lists:seq(2, length(Names) + 1)),
                    N =:= Name],
    Index.
field_name({typed_record_field, Field, _}) -> field_name(Field);
field_name({record_field, _, {atom, _, Name}, _}) -> Name;
field_name({record_field, _, {atom, _, Name}}) -> Name.

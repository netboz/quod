-module(quod_root_resource_lifecycle_tests).
-include_lib("eunit/include/eunit.hrl").

-define(ROOT, <<"quod:root">>).

root_policy_restores_journal_before_node_and_after_owner_restart_test_() ->
    {timeout, 90, fun() -> with_root(fun(#{journal := Journal, directory := Dir,
                                         runtime := Runtime, observer := Observer}) ->
        ?assertEqual({error, unavailable}, quod_node_actor:principal()),
        ?assertEqual(64, quod_effect_journal:capacity()),
        Engine = quod_reg:where({quod_prolog, ?ROOT}),
        Anchor = quod_simplex:genesis_hash(?ROOT),
        ?assertEqual({ok, Anchor}, quod_ontology:network_identity()),
        Trace = start_trace(Runtime, Journal),
        try
            commit_capacity(7),
            configured(Trace, 7),
            settled(Observer),
            _ = counts(Trace),
            gen_server:stop(Journal),
            %% The committed root remains available while the resource owner
            %% is absent. Its failed installation must retain current policy.
            commit_capacity(9),
            ?assert(maps:is_key(effect_custody,
                               maps:get(resource_failures, settled(Observer)))),
            _ = counts(Trace),
            {ok, Replacement} = quod_effect_journal:start_link(#{data_dir => Dir}),
            unlink(Replacement),
            %% Await the runtime worker's actual successful API return. A
            %% restored on-disk value of 7 cannot satisfy this assertion.
            configured(Trace, 9),
            ?assertEqual(9, quod_effect_journal:capacity()),
            ?assertEqual(Runtime, quod_reg:where({quod_runtime, ?ROOT})),
            ?assertEqual(Engine, quod_reg:where({quod_prolog, ?ROOT})),
            ?assertEqual(Anchor, quod_simplex:genesis_hash(?ROOT)),
            ?assertEqual({error, unavailable}, quod_node_actor:principal()),
            ?assertEqual(#{}, maps:get(resource_failures, settled(Observer))),
            trace:process(maps:get(session, Trace), Replacement, true, [call, set_on_spawn]),
            _ = counts(Trace),
            quod_runtime:reconcile_now(?ROOT),
            settled(Observer),
            quod_runtime:reconcile_now(?ROOT),
            settled(Observer),
            ?assertEqual(#{selections => 0, configurations => 0, io => []}, counts(Trace)),
            %% The instrumentation must still see the write and durability
            %% work required by a genuine later committed policy change.
            commit_capacity(11),
            configured(Trace, 11),
            settled(Observer),
            Changed = counts(Trace),
            ?assert(maps:get(selections, Changed) > 0),
            ?assert(lists:member({file, datasync, 1}, maps:get(io, Changed))),
            ?assertEqual(11, quod_effect_journal:capacity())
        after stop_trace(Trace) end
    end) end}.

%% Use the same actual namespace/journal startup as the existing system and
%% lifecycle fixtures, stopping before logical-node creation. No native test
%% predicate is installed and no resource inventory is injected into runtime.
with_root(Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    Keys = [node_pubkey, identity_key, identity_dir, content_data_dir,
            node_actor_principal, namespace_desired, namespace_static_content,
            content_storage_dirs],
    Saved = [{K, application:get_env(quod, K)} || K <- Keys],
    Dir = filename:join("/tmp", "quod_root_resources_" ++
                       binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    {Pub, _} = Pair = quod_identity:generate(),
    Identity = #{pubkey => Pub, key => quod_identity:key_term(Pair),
                 cert => quod_identity:mint_cert(Pair)},
    application:set_env(quod, node_pubkey, Pub),
    application:set_env(quod, identity_key, maps:get(key, Identity)),
    application:set_env(quod, identity_dir, Dir),
    application:set_env(quod, content_data_dir, Dir),
    application:unset_env(quod, node_actor_principal),
    application:set_env(quod, namespace_desired, #{content => #{}, brahms => #{}}),
    application:set_env(quod, content_storage_dirs, #{}),
    {ok, Router} = quod_ask_router:start_link(),
    unlink(Router),
    {ok, Journal} = quod_effect_journal:start_link(#{data_dir => Dir}),
    unlink(Journal),
    ?assertEqual(unconfigured, quod_effect_journal:capacity()),
    Parent = self(), Initial = make_ref(),
    WatchCapacity = fun(State, {in, {'$gen_call', _, {configure_capacity, 64}}}, _) ->
                            Parent ! {initial_capacity, Initial}, State;
                       (State, _, _) -> State end,
    ok = sys:install(Journal, {WatchCapacity, none}),
    {?ROOT, Config0} = quod_app:build_ns_config(
       #{namespace => ?ROOT, mode => create, genesis_file => <<"ontologies/quod_root.pl">>,
         data_dir => list_to_binary(Dir), seeds => []}),
    Config = Config0#{identity => Identity, proof_timeout_ms => 5000},
    application:set_env(quod, namespace_static_content, #{?ROOT => Config}),
    true = quod_reg:subscribe({runtime, ?ROOT}),
    {ok, Sup} = quod_ns:start_link(?ROOT, Config),
    unlink(Sup),
    Result = try
        receive {replay_ready, _, _} -> ok
        after 10000 -> error(root_not_replay_ready) end,
        receive {initial_capacity, Initial} ->
            %% Joining the received call with a capacity query proves its
            %% handler completed, independently of input-frontier progress.
            ?assertEqual(64, quod_effect_journal:capacity())
        after 10000 -> error(root_capacity_not_restored_before_node) end,
        Runtime = quod_reg:where({quod_runtime, ?ROOT}),
        Anchor = quod_simplex:genesis_hash(?ROOT),
        application:set_env(quod, namespace_desired,
            #{content => #{?ROOT => Config#{genesis_hash => Anchor}}, brahms => #{}}),
        Observer = observe(Runtime),
        try
            settled(Observer),
            Fun(#{journal => Journal, directory => Dir, runtime => Runtime,
                  observer => Observer})
        after unobserve(Observer) end
    catch Class:Reason:Stack ->
        io:format("Failed root resource fixture retained at ~s~n", [Dir]),
        erlang:raise(Class, Reason, Stack)
    after
        quod_reg:unsubscribe({runtime, ?ROOT}),
        stop(Sup),
        stop(quod_reg:where({quod_effect_journal, node})),
        stop(Router),
        [case Value of
             {ok, V} -> application:set_env(quod, K, V);
             undefined -> application:unset_env(quod, K)
         end || {K, Value} <- Saved]
    end,
    ok = file:del_dir_r(Dir),
    Result.

commit_capacity(Value) ->
    ?assertMatch({ok, _, _}, quod_prolog:execute(?ROOT, {set_effect_custody_capacity, Value})).
configured(#{tag := Tag}, Value) ->
    receive
        {Tag, {trace, Worker, call, {quod_effect_journal, configure_capacity, [Value]}}} ->
            receive
                {Tag, {trace, Worker, return_from, {quod_effect_journal, configure_capacity, 1}, Result}} ->
                    ?assertEqual(ok, Result)
            after 10000 -> error(capacity_configuration_did_not_return) end
    after 10000 -> error({capacity_not_restored, Value}) end.

observe(Runtime) ->
    Parent = self(), Tag = make_ref(),
    Observe = fun(State, {in, {'$gen_cast', {runner_done, _, _}}}, _) ->
                      Parent ! {root_resource_step, Tag}, State;
                 (State, {in, {applied_live, _, _}}, _) ->
                      Parent ! {root_resource_step, Tag}, State;
                 (State, {in, {runtime_snapshot_advanced, _, _, _}}, _) ->
                      Parent ! {root_resource_step, Tag}, State;
                 (State, _, _) -> State end,
    ok = sys:install(Runtime, {Observe, none}),
    {Runtime, Tag, Observe}.
unobserve({Runtime, _, Observe}) -> sys:remove(Runtime, Observe).
settled(Observer) -> settled(Observer, quod_prolog:applied(?ROOT), deadline()).
settled(Observer = {_, Tag, _}, Height, Deadline) ->
    case quod_runtime:stats(?ROOT) of
        #{mode := live, height := H, runner_active := false, queue_len := 0} = Stats
          when H >= Height -> Stats;
        _ -> receive {root_resource_step, Tag} -> settled(Observer, Height, Deadline)
             after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
                 error(root_resource_owner_did_not_settle) end
    end.

start_trace(Runtime, Journal) ->
    Trace = #{session := Session, io := IO} = new_trace(),
    trace:function(Session, {quod_runtime, select_resource_description, 5},
                   [{[?ROOT, '_', '_', effect_custody, '_'], [], []}], [local]),
    trace:function(Session, {quod_effect_journal, configure_capacity, 1},
                   [{'_', [], [{return_trace}]}], [local]),
    [trace:function(Session, MFA, true, [local]) || MFA <- IO],
    [trace:process(Session, Pid, true, [call, set_on_spawn]) || Pid <- [Runtime, Journal]],
    clear_measurement(Trace),
    Trace.
counts(Trace = #{tag := Tag, io := IO}) ->
    trace_barrier(Trace),
    trace_counts(Tag, IO, #{selections => 0, configurations => 0, io => []}).
trace_counts(Tag, IO, Acc) ->
    receive
        {Tag, {trace, _, call, {quod_runtime, select_resource_description, _}}} ->
            trace_counts(Tag, IO, Acc#{selections := maps:get(selections, Acc) + 1});
        {Tag, {trace, _, call, {quod_effect_journal, configure_capacity, _}}} ->
            trace_counts(Tag, IO, Acc#{configurations := maps:get(configurations, Acc) + 1});
        {Tag, {trace, _, return_from, {quod_effect_journal, configure_capacity, 1}, _}} ->
            trace_counts(Tag, IO, Acc);
        {Tag, {trace, _, call, {M, F, Args}}} ->
            trace_counts(Tag, IO, record_io(M, F, Args, IO, Acc))
    after 0 -> Acc end.

%% A private session and tracer give every message this measurement's tag.
%% Old EUnit mailbox traces and other sessions cannot enter its counters.
new_trace() ->
    Parent = self(), Tag = make_ref(),
    Tracer = spawn_link(fun() -> trace_relay(Parent, Tag) end),
    Session = trace:session_create(?MODULE, Tracer, []),
    #{session => Session, tracer => Tracer, tag => Tag, io => io_mfas()}.
trace_relay(Parent, Tag) ->
    receive
        {barrier, Ref} -> Parent ! {Tag, barrier, Ref}, trace_relay(Parent, Tag);
        stop -> ok;
        Message -> Parent ! {Tag, Message}, trace_relay(Parent, Tag)
    end.
trace_barrier(#{session := Session, tracer := Tracer, tag := Tag}) ->
    Ref = trace:delivered(Session, all),
    receive {trace_delivered, all, Ref} -> ok
    after 10000 -> error(resource_trace_not_delivered) end,
    %% Delivery puts all earlier traces in the relay's mailbox. Its reply is
    %% therefore ordered after forwarding them to this test process.
    Tracer ! {barrier, Ref},
    receive {Tag, barrier, Ref} -> ok
    after 10000 -> error(resource_trace_relay_not_drained) end.
clear_measurement(Trace = #{tag := Tag}) ->
    trace_barrier(Trace),
    discard_trace(Tag).
discard_trace(Tag) ->
    receive {Tag, _} -> discard_trace(Tag) after 0 -> ok end.
stop_trace(Trace = #{session := Session, tracer := Tracer, tag := Tag}) ->
    trace_barrier(Trace),
    true = trace:session_destroy(Session),
    Monitor = monitor(process, Tracer),
    Tracer ! stop,
    receive {'DOWN', Monitor, process, Tracer, normal} -> ok
    after 10000 -> error(resource_tracer_not_stopped) end,
    discard_trace(Tag).
io_mfas() ->
    [{quod_simplex, history_view, 3}, {quod_ledger_store, open_ro_snapshot, 1},
     {quod_ledger_store, read_at, 2}, {file, write, 2}, {file, pwrite, 3},
     {file, write_file, 2}, {file, write_file, 3}, {file, sync, 1}, {file, datasync, 1}].
record_io(M, F, Args, IO, Acc) ->
    MFA = {M, F, length(Args)},
    case lists:member(MFA, IO) of
        true -> Acc#{io := [MFA | maps:get(io, Acc)]};
        false -> error({unexpected_measurement_trace, MFA})
    end.
deadline() -> erlang:monotonic_time(millisecond) + 10000.
stop(Pid) when is_pid(Pid) ->
    Monitor = monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', Monitor, process, Pid, _} -> ok
    after 5000 -> error(root_resource_fixture_did_not_stop) end;
stop(_) -> ok.

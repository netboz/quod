-module(quod_dtx_coordinator_unwind_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").
-include_lib("opentelemetry/src/otel_tracer.hrl").
-include_lib("opentelemetry/src/otel_span_ets.hrl").

%% Compiled-start fault controls run only in fresh stdio peers. Their prefix
%% injects an exception or stops SDK storage after real span creation, without
%% adding a production hook or changing the remainder of the real start body.
-export([start_failure/2, callback_unwind_inventory/0, with_sdk/1,
         run_compiled_start_control/3, compiled_start_fault/2]).

%% B's callback-unwind amendment deliberately does not add a second owner or
%% rollback registry. These fixtures exercise production callbacks and real
%% SDK storage, not a complete consensus transition. Counts at start_monitor
%% and end_span are independent of which spans happen to export.

sdk_end_after_take_is_a_noop_not_a_second_export_test() ->
    with_sdk(fun(_Storage) ->
        {_Ctx, Handle} = quod_trace:start_span(
          otel_ctx:new(), <<"unwind.sdk.take">>, internal, #{}),
        Id = otel_span:span_id(Handle),
        ?assertMatch([#span{}], ets:lookup(?SPAN_TAB, Id)),
        ?assertEqual(true, otel_span_ets:end_span(Handle)),
        ?assertEqual([], ets:lookup(?SPAN_TAB, Id)),
        %% The immutable context still says recording after ets:take. It is
        %% not an owner-side ended flag. The second real SDK end returns false.
        ?assert(otel_span:is_recording(Handle)),
        ?assertEqual(false, otel_span_ets:end_span(Handle)),
        ?assertEqual([Id], [S#span.span_id || S <- exported()])
    end).

replacement_start_failure_dying_callback_reends_old_handle_without_reexport_test() ->
    with_sdk(fun(_Storage) ->
        with_fixture(fun(F, S0, _Journal, _Store) ->
            {OriginNs, _} = Origin = maps:get(target, F),
            GroupId = group_id(F),
            Other = quod_ct:signed_atomic_fixture(#{target => Origin,
              node_identity => maps:get(node_identity, F),
              admission => maps:get(admission, F),
              proof_id => <<241:256>>, operation_id => <<242:256>>}),
            OtherGroupId = group_id(Other),
            ?assertNotEqual(GroupId, OtherGroupId),
            with_calls([self()], fun(Calls) ->
                S1 = start(F, S0),
                #{pid := Worker, coordinate_span := {_, OldSpan}} = row(F, S1),
                Monitor = monitor(process, Worker),
                OldId = otel_span:span_id(OldSpan),
                %% Match the existing owner by its map key, then supply a
                %% genuinely different valid group to exercise replacement.
                %% Same-group changes now preserve the owner. Bad OwnerNs
                %% makes the replacement's real start return invalid_own_vote.
                Ns = <<OriginNs/binary, ".different-origin">>,
                StartState = quod_simplex:test_state_set(ns, Ns, S1),
                Expected = {dtx_coordinator_start_failed, Ns, OtherGroupId, invalid_own_vote},
                ?assertError(Expected, quod_simplex:test_reconcile_dtx_coordinators(
                  #{GroupId => own_row(Other)}, StartState)),
                %% An exception prevents OTP from installing the tentative
                %% replacement state. Termination sees the original row.
                ?assertEqual(ok, quod_simplex:terminate(Expected, running, StartState)),
                down(Monitor, Worker, shutdown),
                #{starts := 2, ends := Ends} = calls(Calls),
                Spans = coordinate_exports(),
                ?assertEqual(2, count(OldId, Ends)),
                ?assertEqual(3, length(Ends)),
                ?assertEqual(1, count(OldId, [S#span.span_id || S <- Spans])),
                ?assertEqual(2, length(Spans)),
                ?assertEqual(2, length(coordinate_starts())),
                ?assertEqual([<<"retirement_requested">>, <<"start_failed">>],
                             lists:sort([closure(S) || S <- Spans])),
                %% No rewritten owner_terminating provenance can be exported
                %% for the already-taken old row.
                [Old] = [S || S <- Spans, S#span.span_id =:= OldId],
                ?assertEqual(<<"retirement_requested">>, closure(Old))
            end)
        end)
    end).

%% A successful nested start followed by an outer callback error never
%% publishes its tentative owner row to OTP. The child follows actual owner
%% death normally; its new root is lost, not manufactured as completion.
tentative_start_lost_on_callback_unwind_is_counted_and_swept_test() ->
    ?assertMatch(#{expected_attempts := 1, producer_starts := 1,
                   exported_roots := 0, sdk_sweeper_reclaimed := true},
                 callback_unwind_inventory()).

callback_unwind_inventory() ->
    with_sdk(fun(_Storage) ->
        Parent = self(),
        {Owner, OwnerMonitor} = spawn_monitor(fun() ->
            receive begin_callback -> ok end,
            with_fixture(fun(F, S0, _Journal, _Store) ->
                Tentative = start(F, S0),
                Parent ! {tentative_started, self(),
                          (row(F, Tentative))#{namespace => element(1, maps:get(target, F))}},
                receive unwind_callback -> ok end,
                %% Equivalent to OTP's old-state terminate boundary, followed
                %% by actual owner death. No tentative row is handed to it.
                try error(unwind_after_tentative_start)
                catch Class:Reason:Stack ->
                    ok = quod_simplex:terminate(Reason, running, S0),
                    erlang:raise(Class, Reason, Stack)
                end
            end)
        end),
        try
            with_calls([Owner], fun(Calls) ->
                Owner ! begin_callback,
                #{pid := Worker, group_id := GroupId, namespace := Namespace,
                  coordinate_span := {_, Handle}} = receive
                    {tentative_started, Owner, Row} -> Row
                after 3000 -> error(no_tentative_start)
                end,
                Id = otel_span:span_id(Handle),
                WorkerMonitor = monitor(process, Worker),
                ?assertMatch([#span{}], ets:lookup(?SPAN_TAB, Id)),
                ?assertEqual(1, maps:get(starts, calls(Calls))),
                Owner ! unwind_callback,
                receive
                    {'DOWN', OwnerMonitor, process, Owner,
                     {unwind_after_tentative_start, _Stack}} -> ok
                after 3000 -> error(callback_owner_survived)
                end,
                down(WorkerMonitor, Worker, normal),
                #{starts := 1, ends := Ends} = calls(Calls),
                ?assertEqual(0, count(Id, Ends)),
                ?assertEqual([], coordinate_exports()),
                ?assertEqual([Id], coordinate_starts()),
                ?assertMatch([#span{}], ets:lookup(?SPAN_TAB, Id)),
                %% Use the pinned SDK's actual sweeper process and drop
                %% strategy. This is a test-only short TTL, not a deployment
                %% retuning or a claim that sweeping exports a valid root.
                ?assertEqual(undefined, whereis(otel_span_sweeper)),
                {ok, Sweeper} = otel_span_sweeper:start_link(
                  #{interval => 1, span_ttl => 0, strategy => drop,
                    storage_size => infinity}),
                try await_reclaimed(Id, erlang:monotonic_time(millisecond) + 2000)
                after gen_statem:stop(Sweeper)
                end,
                ?assertEqual([], ets:lookup(?SPAN_TAB, Id)),
                ?assertEqual([], coordinate_exports()),
                %% Returned only to the isolated evidence runner. This is an
                %% independently counted synthetic attempt, not a new runtime
                %% inventory/collector or a reconstructed client operation.
                #{provenance => <<"real-SDK callback-state fixture, not fleet telemetry">>,
                  expected_attempts => 1, producer_starts => 1, exported_roots => 0,
                  span_id => hex_id(Id, 8),
                  trace_id => hex_id(otel_span:trace_id(Handle), 16),
                  group_id => binary:encode_hex(GroupId),
                  namespace => Namespace,
                  span_name => <<"quod.dtx.coordinate">>,
                  loss_class => <<"tentative_callback_unwind">>,
                  owner_exit => <<"unwind_after_tentative_start">>,
                  worker_exit => <<"normal">>, end_calls => 0,
                  sdk_sweeper_reclaimed => true}
            end)
        after
            exit(Owner, kill),
            demonitor(OwnerMonitor, [flush])
        end
    end).

sdk_disappearance_release_and_termination_keep_resource_shutdown_test_() ->
    [{atom_to_list(Edge), fun() -> disappearance_release(Edge) end}
     || Edge <- [retire, owner_terminate, fatal_child_error]].

disappearance_release(Edge) ->
    with_sdk(fun(Storage) ->
        with_fixture(fun(F, S0, Journal, Store) ->
            S1 = start(F, S0),
            #{pid := Worker, monitor := OwnedMonitor,
              coordinate_span := {_, Handle}} = row(F, S1),
            Id = otel_span:span_id(Handle),
            Monitor = monitor(process, Worker),
            try
                stop_storage(Storage),
                with_calls([self()], fun(Calls) ->
                    case Edge of
                        retire ->
                            S2 = quod_simplex:test_reconcile_dtx_coordinators(#{}, S1),
                            ?assertEqual(#{}, quod_simplex:test_dtx_coordinator_state(S2)),
                            %% Retirement does not acquire owner resource
                            %% shutdown. Only the existing terminate edge does.
                            ?assertEqual([], maps:get(stores, calls(Calls))),
                            ?assertEqual([], maps:get(journals, calls(Calls))),
                            ok = quod_simplex:terminate(normal, running, S2);
                        owner_terminate ->
                            ok = quod_simplex:terminate(shutdown, running, S1);
                        fatal_child_error ->
                            Secret = <<"unwind-private-template-do-not-export">>,
                            {Ns, _} = maps:get(target, F),
                            Expected = {dtx_coordinator_failed, Ns, group_id(F), Secret},
                            ?assertError(Expected, quod_simplex:running(info,
                              {dtx_coordinator, Worker, group_id(F), {error, Secret}}, S1)),
                            %% Tracing failure must not substitute for the
                            %% original fatal error or stop terminate midway.
                            ok = quod_simplex:terminate(Expected, running, S1)
                    end,
                    down(Monitor, Worker, shutdown),
                    #{ends := Ends, stores := Stores, journals := Journals, fds := Fds} = calls(Calls),
                    ?assertEqual([Id], Ends),
                    ?assertEqual([Store], Stores),
                    ?assertEqual([Journal], Journals),
                    ?assertEqual(2, length(Fds)),
                    lists:foreach(fun assert_fd_closed/1, Fds),
                    ?assertNot(lists:member({process, Worker}, monitors())),
                    receive {'DOWN', OwnedMonitor, process, Worker, _} ->
                        error(owner_monitor_was_not_flushed)
                    after 0 -> ok
                    end,
                    ?assertEqual([], coordinate_exports())
                end)
            after
                exit(Worker, kill),
                demonitor(Monitor, [flush])
            end
        end)
    end).

start_failure_preserves_returned_error_and_exception_with_or_without_sdk_test_() ->
    [{Label ++ "/" ++ atom_to_list(StorageState),
      {timeout, 60, fun() -> start_failure(Kind, StorageState) end}}
     || {Kind, Label} <- [{returned, "returned"}, {exception, "compiled_exception"}],
        StorageState <- [present, disappeared]].

sdk_disappears_during_compiled_start_control_test_() ->
    %% Exercise both cleanup branches with an owned real SDK handle whose
    %% storage disappears inside start, rather than a pre-start noop handle.
    {timeout, 60, fun() ->
        lists:foreach(fun(Kind) -> start_failure(Kind, during_start) end,
                      [returned, exception])
    end}.

%% initial_state/4 now shape-checks an authenticated own row and returns
%% invalid_own_vote. The deleted recovered-evidence verifier supplied the old
%% deterministic throw; there is no current input-driven producer throw at
%% this same synchronous seam. Keep that exception/stack guard explicitly
%% synthetic, isolated from the runner and from all production source.
start_failure(exception, StorageState) ->
    compiled_start_control(exception, StorageState);
start_failure(returned, during_start) ->
    compiled_start_control(returned, during_start);
start_failure(returned, StorageState) ->
    start_failure_case(returned, StorageState).

start_failure_case(Kind, StorageState) ->
    with_sdk(fun(Storage) ->
        with_fixture(fun(F, S0, Journal, Store) ->
            GroupId = group_id(F),
            {OriginNs, _} = maps:get(target, F),
            Desired = own_row(F),
            Secret = start_fault_secret(),
            %% A valid Vote reaches start_monitor/4, where the mismatched
            %% owner namespace produces its real returned invalid_own_vote.
            Ns = case Kind of
                returned -> <<OriginNs/binary, ".different-origin">>;
                exception -> OriginNs
            end,
            StartState = quod_simplex:test_state_set(ns, Ns, S0),
            case StorageState of
                present -> ok;
                during_start -> ok; % isolated VM's compiled start seam stops SDK
                disappeared -> stop_storage(Storage)
            end,
            with_calls([self()], fun(Calls) ->
                Result = try quod_simplex:test_reconcile_dtx_coordinators(
                               #{GroupId => Desired}, StartState) of
                    Unexpected -> {unexpected_success, Unexpected}
                catch Class:Reason:Stack -> {Class, Reason, Stack}
                end,
                case Kind of
                    returned ->
                        ?assertMatch({error,
                          {dtx_coordinator_start_failed, Ns, GroupId, invalid_own_vote}, _}, Result);
                    exception ->
                        ?assertMatch({error, {compiled_start_fault, Secret},
                          [{?MODULE, compiled_start_fault, _, _} | _]}, Result),
                        %% The prefix captures the original class/reason/full
                        %% stack before Simplex's real cleanup/rethrow boundary.
                        receive {unwind_start_fault, Original} -> ?assertEqual(Original, Result)
                        after 1000 -> error(missing_compiled_start_fault)
                        end
                end,
                #{starts := Starts, ends := Ends} = calls(Calls),
                ?assertEqual(1, Starts),
                ?assertEqual(#{}, quod_simplex:test_dtx_coordinator_state(S0)),
                [Id] = coordinate_starts(),
                Spans = coordinate_exports(),
                case StorageState of
                    present ->
                        ?assertEqual([Id], Ends),
                        ?assertEqual(1, length(Spans)),
                        [Span] = Spans,
                        ?assertEqual(Id, Span#span.span_id),
                        ?assertEqual([], ets:lookup(?SPAN_TAB, Id)),
                        ?assertEqual(<<"start_failed">>, closure(Span)),
                        ?assertEqual(nomatch, binary:match(term_to_binary(Span), Secret));
                    disappeared ->
                        %% Failed SDK insertion returns a noop handle: there
                        %% is no owned span for cleanup to end.
                        ?assertEqual([], Ends),
                        ?assertEqual([], Spans);
                    during_start ->
                        ?assertEqual([Id], Ends),
                        ?assertEqual(undefined, ets:info(?SPAN_TAB)),
                        ?assertEqual([], Spans)
                end,
                ok = quod_simplex:terminate(element(2, Result), running, S0),
                #{ends := FinalEnds, stores := Stores, journals := Journals, fds := Fds} = calls(Calls),
                ?assertEqual(Ends, FinalEnds),
                ?assertEqual([Store], Stores),
                ?assertEqual([Journal], Journals),
                ?assertEqual(2, length(Fds)),
                lists:foreach(fun assert_fd_closed/1, Fds)
            end)
        end)
    end).

%% Permanent fault runner, not a production injection path. Only the peer's
%% in-memory coordinator is instrumented; the parent VM and all files retain
%% their original code. Pin selected beams before starting the peer so this
%% control also works with the parent's private sequential-build snapshots.
compiled_start_control(Kind, StorageState) ->
    Modules = [?MODULE, quod_simplex, quod_dtx_coordinator,
               quod_dtx_group_trace_tests, quod_ct, quod_trace, quod_attempt_span],
    Beams = [begin
        Path = filename:absname(code:which(Module)),
        {ok, Beam} = file:read_file(Path),
        {Module, Path, Beam}
    end || Module <- Modules],
    {quod_dtx_coordinator, _, CoordinatorBeam} = lists:keyfind(quod_dtx_coordinator, 1, Beams),
    {ok, Peer, _} = peer:start(#{connection => standard_io,
      env => [{"ERL_CRASH_DUMP", "/dev/null"}],
      args => ["+S", "2:2", "+SDcpu", "1", "+SDio", "1", "-pa" | code:get_path()]}),
    try
        lists:foreach(fun({Module, Path, Beam}) ->
            ?assertEqual({module, Module}, peer:call(Peer, code, load_binary,
                                                   [Module, Path, Beam]))
        end, Beams),
        ?assertEqual(ok, peer:call(Peer, ?MODULE, run_compiled_start_control,
                                   [Kind, StorageState, CoordinatorBeam], 45000))
    after peer:stop(Peer)
    end.

run_compiled_start_control(Kind, StorageState, CoordinatorBeam) ->
    Module = quod_dtx_coordinator,
    {ok, {Module, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
        beam_lib:chunks(CoordinatorBeam, [abstract_code]),
    [Original = {function, L, start_monitor, 4,
                 [{clause, CL, Args, Guards, Body} | Fallback]}] =
        [F || F = {function, _, start_monitor, 4, _} <- Forms],
    Prefix = {call, CL,
                {remote, CL, {atom, CL, ?MODULE}, {atom, CL, compiled_start_fault}},
                [erl_parse:abstract(Kind), erl_parse:abstract(StorageState)]},
    Instrumented = {function, L, start_monitor, 4,
                    [{clause, CL, Args, Guards, [Prefix | Body]} | Fallback]},
    %% Preserve the start guards, returned-error arms and every other form;
    %% the returned/during_start arm runs the original body after SDK loss.
    Updated = [case F =:= Original of true -> Instrumented; false -> F end || F <- Forms],
    Compiled = compile:forms(Updated, [binary, debug_info, return_errors, return_warnings]),
    Beam = case Compiled of
        {ok, Module, Binary} -> Binary;
        {ok, Module, Binary, _Warnings} -> Binary;
        _ -> error({compiled_start_control_failed, Compiled})
    end,
    {module, Module} = code:load_binary(Module, "quod_dtx_coordinator.unwind-start-control", Beam),
    start_failure_case(Kind, StorageState).

compiled_start_fault(Kind, StorageState) ->
    case StorageState of
        disappeared -> ?assertEqual(undefined, ets:info(?SPAN_TAB));
        _ ->
            Span = otel_tracer:current_span_ctx(quod_trace:context()),
            ?assertMatch([#span{name = <<"quod.dtx.coordinate">>}],
                         ets:lookup(?SPAN_TAB, otel_span:span_id(Span))),
            case StorageState of
                during_start -> stop_storage(ets:info(?SPAN_TAB, owner));
                present -> ok
            end
    end,
    case Kind of
        returned -> ok;
        exception ->
            try error({compiled_start_fault, start_fault_secret()})
            catch Class:Reason:Stack ->
                self() ! {unwind_start_fault, {Class, Reason, Stack}},
                erlang:raise(Class, Reason, Stack)
            end
    end.

start_fault_secret() -> <<"unwind-secret-compiled-start-fault">>.

start(F, S) ->
    GroupId = group_id(F),
    quod_simplex:test_reconcile_dtx_coordinators(
      #{GroupId => own_row(F)}, S).

own_row(F) ->
    #{material => quod_atomic:control_material(maps:get(vote_control, F)),
      ref => none, resolution => none}.
group_id(F) -> quod_atomic:group_id(maps:get(group, F)).
row(F, S) -> maps:get(group_id(F), quod_simplex:test_dtx_coordinator_state(S)).
closure(Span) -> maps:get('quod.dtx.closure', otel_attributes:map(Span#span.attributes)).
count(Item, Items) -> length([I || I <- Items, I =:= Item]).
hex_id(Id, Bytes) -> binary:encode_hex(<<Id:Bytes/unit:8>>).
monitors() -> {monitors, Monitors} = process_info(self(), monitors), Monitors.

with_fixture(Fun) ->
    quod_dtx_group_trace_tests:with_fixture(fun(F, S0, {Journal, Dir}) ->
        {Ns, _} = maps:get(target, F),
        {ok, Store} = quod_ledger_store:open(Ns, filename:join(Dir, "ledger")),
        try Fun(F, quod_simplex:test_state_set(store, Store, S0), Journal, Store)
        after catch quod_ledger_store:close(Store)
        end
    end).

down(Monitor, Pid, Reason) ->
    receive {'DOWN', Monitor, process, Pid, Actual} -> ?assertEqual(Reason, Actual)
    after 3000 -> error({missing_worker_down, Pid})
    end.

assert_fd_closed(Fd) ->
    Result = catch file:position(Fd, cur),
    ?assertNotMatch({ok, _}, Result).

await_reclaimed(Id, Deadline) ->
    case ets:lookup(?SPAN_TAB, Id) of
        [] -> ok;
        [_] ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> receive after 1 -> await_reclaimed(Id, Deadline) end;
                false -> error(sdk_sweeper_did_not_reclaim)
            end
    end.

exported() -> exported([]).
exported(Acc) ->
    receive {quod_test_span, Span} -> exported([Span | Acc])
    after 0 -> lists:reverse(Acc)
    end.
coordinate_exports() -> [S || S = #span{name = <<"quod.dtx.coordinate">>} <- exported()].
coordinate_starts() -> coordinate_starts([]).
coordinate_starts(Acc) ->
    receive {unwind_sdk_start, <<"quod.dtx.coordinate">>, Id} -> coordinate_starts([Id | Acc])
    after 0 -> lists:reverse(Acc)
    end.

%% The fixture uses the real sampler, attachment, ETS storage and end
%% processors. Only exporting is redirected to the test mailbox. It tolerates
%% deliberate storage shutdown while restoring every changed global key.
with_sdk(Fun) ->
    %% Export counts belong to this fixture, not an earlier EUnit module's
    %% mailbox. Production casts stay private too; no assertion is weakened.
    Parent = self(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        _ = quod_process:kill_when_owner_dies(Parent, self()),
        Result = try {ok, with_sdk_local(Fun)} catch C:R:S -> {raised, C, R, S} end,
        Parent ! {isolated_sdk_result, self(), Result}
    end),
    receive
        {isolated_sdk_result, Pid, Result} ->
            down(Monitor, Pid, normal),
            case Result of {ok, Value} -> Value;
                           {raised, C, R, S} -> erlang:raise(C, R, S) end;
        {'DOWN', Monitor, process, Pid, Reason} -> error({isolated_sdk_exit, Reason})
    end.

with_sdk_local(Fun) ->
    {ok, Storage} = otel_span_ets:start_link([]),
    Key = {opentelemetry, global, tracer, opentelemetry:get_application(quod_trace)},
    LimitsKey = {otel_span_limits, span_limits},
    Previous = persistent_term:get(Key, absent),
    PreviousLimits = persistent_term:get(LimitsKey, absent),
    Token = otel_ctx:attach(otel_ctx:new()),
    Parent = self(),
    Tracer = {otel_tracer_default,
      #tracer{module = otel_tracer_default,
        sampler = otel_sampler:new({parent_based, #{root => always_on}}),
        id_generator = otel_id_generator,
        on_start_processors = fun(_Ctx, Span) ->
            Parent ! {unwind_sdk_start, Span#span.name, Span#span.span_id}, Span
        end,
        on_end_processors = fun(Span) -> Parent ! {quod_test_span, Span}, true end,
        instrumentation_scope = opentelemetry:instrumentation_scope(?MODULE, <<>>, undefined)}},
    try
        case PreviousLimits of
            absent -> persistent_term:put(LimitsKey, #span_limits{});
            _ -> ok
        end,
        true = opentelemetry:verify_and_set_term(Tracer, Key, otel_tracer),
        Fun(Storage)
    after
        restore(Key, Previous),
        restore(LimitsKey, PreviousLimits),
        otel_ctx:detach(Token),
        case is_process_alive(Storage) of
            true -> gen_server:stop(Storage);
            false -> ok
        end
    end.

stop_storage(Storage) ->
    ok = gen_server:stop(Storage),
    ?assertEqual(undefined, ets:info(?SPAN_TAB)).

restore(Key, absent) -> persistent_term:erase(Key);
restore(Key, Value) -> persistent_term:put(Key, Value).

with_calls(Pids, Fun) ->
    Collector = spawn_link(fun() -> collect_calls(
      #{starts => 0, ends => [], stores => [], journals => [], fds => []}) end),
    Patterns = [{quod_dtx_coordinator, start_monitor, 4}, {otel_span, end_span, 1},
                {quod_ledger_store, close, 1}, {quod_signing_journal, close, 1},
                {file, close, 1}],
    lists:foreach(fun({Module, _, _}) -> {module, Module} = code:ensure_loaded(Module) end,
                  Patterns),
    lists:foreach(fun(MFA) -> 1 = erlang:trace_pattern(MFA, true, [local]) end, Patterns),
    lists:foreach(fun(Pid) -> 1 = erlang:trace(Pid, true, [call, {tracer, Collector}]) end, Pids),
    try Fun(Collector)
    after
        lists:foreach(fun(Pid) -> catch erlang:trace(Pid, false, [call]) end, Pids),
        lists:foreach(fun(MFA) -> erlang:trace_pattern(MFA, false, [local]) end, Patterns),
        Collector ! stop
    end.

calls(Collector) ->
    Barrier = erlang:trace_delivered(all),
    receive {trace_delivered, all, Barrier} -> ok
    after 2000 -> error(trace_barrier_timeout)
    end,
    Ref = make_ref(),
    Collector ! {get, self(), Ref},
    receive {Ref, Calls} -> Calls after 2000 -> error(missing_call_inventory) end.

collect_calls(Calls) ->
    receive
        {trace, _, call, {quod_dtx_coordinator, start_monitor, _}} ->
            collect_calls(Calls#{starts := maps:get(starts, Calls) + 1});
        {trace, _, call, {otel_span, end_span, [Span]}} ->
            collect_calls(Calls#{ends := [otel_span:span_id(Span) | maps:get(ends, Calls)]});
        {trace, _, call, {quod_ledger_store, close, [Store]}} ->
            collect_calls(Calls#{stores := [Store | maps:get(stores, Calls)]});
        {trace, _, call, {quod_signing_journal, close, [Journal]}} ->
            collect_calls(Calls#{journals := [Journal | maps:get(journals, Calls)]});
        {trace, _, call, {file, close, [Fd]}} ->
            collect_calls(Calls#{fds := [Fd | maps:get(fds, Calls)]});
        {get, From, Ref} -> From ! {Ref, Calls}, collect_calls(Calls);
        stop -> ok
    end.

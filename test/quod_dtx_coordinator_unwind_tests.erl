-module(quod_dtx_coordinator_unwind_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").
-include_lib("opentelemetry/src/otel_tracer.hrl").
-include_lib("opentelemetry/src/otel_span_ets.hrl").

%% Also used by the isolated compiled-start fault control, which stops SDK
%% storage between the real span creation and the unchanged real start body.
-export([start_failure/2, callback_unwind_inventory/0]).

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
            with_calls([self()], fun(Calls) ->
                S1 = start(F, S0),
                #{pid := Worker, coordinate_span := {_, OldSpan}} = row(F, S1),
                Monitor = monitor(process, Worker),
                OldId = otel_span:span_id(OldSpan),
                {Ns, _} = maps:get(target, F),
                GroupId = group_id(F),
                Expected = {dtx_coordinator_start_failed, Ns, GroupId, invalid_begin},
                ?assertError(Expected, quod_simplex:test_reconcile_dtx_coordinators(
                  #{GroupId => {record, GroupId, invalid_begin, different_group_ref}}, S1)),
                %% An exception prevents OTP from installing the tentative
                %% replacement state. Termination sees the original row.
                ?assertEqual(ok, quod_simplex:terminate(Expected, running, S1)),
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
            #{pid := Worker, monitor := OwnedMonitor} = row(F, S1),
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
                    #{stores := Stores, journals := Journals, fds := Fds} = calls(Calls),
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
    [{atom_to_list(Kind) ++ "/" ++ atom_to_list(StorageState),
      fun() -> start_failure(Kind, StorageState) end}
     || Kind <- [returned, exception], StorageState <- [present, disappeared]].

start_failure(Kind, StorageState) ->
    with_sdk(fun(Storage) ->
        with_fixture(fun(F, S0, Journal, Store) ->
            GroupId = group_id(F),
            {OriginNs, _} = maps:get(target, F),
            Begin = maps:get('begin', F),
            {ok, GroupRef} = quod_dtx:begin_group_ref(Begin),
            Secret = <<"unwind-secret-start-evidence">>,
            Desired = case Kind of
                returned -> {record, GroupId, Begin, GroupRef};
                %% The real initial-state verifier insists identity matches
                %% before reading any further evidence fields. This is an
                %% actual throwing start, not a configurable fake starter.
                exception -> {recovered, GroupId, Begin, GroupRef, none,
                              {ok, #{identity => Secret}}}
            end,
            %% A valid Begin reaches start_monitor, where the mismatched
            %% owner namespace produces its real returned invalid_begin.
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
                          {dtx_coordinator_start_failed, Ns, GroupId, invalid_begin}, _}, Result);
                    exception ->
                        ?assertMatch({error, {badmatch, Secret},
                          [{quod_dtx_coordinator, valid_phase_evidence, _, _} | _]}, Result)
                end,
                ?assertEqual(1, maps:get(starts, calls(Calls))),
                ?assertEqual(#{}, quod_simplex:test_dtx_coordinator_state(S0)),
                Spans = coordinate_exports(),
                case StorageState of
                    present ->
                        ?assertEqual(1, length(Spans)),
                        [Span] = Spans,
                        ?assertEqual(<<"start_failed">>, closure(Span)),
                        ?assertEqual(nomatch, binary:match(term_to_binary(Span), Secret));
                    _ -> ?assertEqual([], Spans)
                end,
                ok = quod_simplex:terminate(element(2, Result), running, S0),
                #{stores := Stores, journals := Journals, fds := Fds} = calls(Calls),
                ?assertEqual([Store], Stores),
                ?assertEqual([Journal], Journals),
                ?assertEqual(2, length(Fds)),
                lists:foreach(fun assert_fd_closed/1, Fds)
            end)
        end)
    end).

start(F, S) ->
    Begin = maps:get('begin', F),
    GroupId = group_id(F),
    {ok, GroupRef} = quod_dtx:begin_group_ref(Begin),
    quod_simplex:test_reconcile_dtx_coordinators(
      #{GroupId => {record, GroupId, Begin, GroupRef}}, S).

group_id(F) -> quod_dtx:group_id(maps:get('begin', F)).
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
    Patterns = [{quod_dtx_coordinator, start_monitor, 5}, {otel_span, end_span, 1},
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

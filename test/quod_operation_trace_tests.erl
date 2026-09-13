-module(quod_operation_trace_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").
-include_lib("opentelemetry/src/otel_span_ets.hrl").

%% Real owner transitions, monitored production child and SDK. The exact
%% projection comes from a signed history constructor, not consensus admission.
%% Workers are parked by the existing readiness stream; no network mock drives
%% progress or closure. The shared SDK fixture also isolates every mailbox.
one_root_after_actual_worker_entry_test() ->
    quod_dtx_coordinator_unwind_tests:with_sdk(fun(_Storage) ->
        {module, quod_dtx_coordinator} = code:ensure_loaded(quod_dtx_coordinator),
        Session = trace:session_create(operation_root_entry, self(), []),
        1 = trace:function(Session, {quod_dtx_coordinator, operation_init, 3}, true, [local]),
        _ = trace:process(Session, new, true, [call]),
        {Ctx, Parent} = quod_trace:start_span(otel_ctx:new(), <<"entry.parent">>, internal, #{}),
        F = quod_ct:remote_operation_fixture(#{}),
        S = quod_simplex:test_start_operation_recovery(op(F), Ctx, state(F)),
        #{pid := Child, attempt_span := {_, Handle}} = owner(op(F), S),
        try
            receive {trace, Child, call, {quod_dtx_coordinator, operation_init, _}} -> ok
            after 2000 -> error(no_real_worker_entry) end,
            Trace = otel_span:trace_id(Parent),
            Roots = [Span || Span = #span{name = <<"quod.operation.recover">>, trace_id = T}
                                  <- ets:tab2list(?SPAN_TAB), T =:= Trace],
            ?assertEqual([otel_span:span_id(Handle)], [R#span.span_id || R <- Roots])
        after
            trace:session_destroy(Session),
            quod_simplex:terminate(fixture_cleanup, running, S),
            exit(Child, shutdown), otel_span:end_span(Parent)
        end
    end).

receipt_retirement_releases_one_owner_root_test() ->
    with_fixture(fun(F, S, Parent, _Storage) ->
        Ref = op(F), #{pid := Child, attempt_span := {_, Handle}} = owner(Ref, S),
        M = monitor(process, Child), Id = otel_span:span_id(Handle),
        ?assertMatch([#span{}], ets:lookup(?SPAN_TAB, Id)),
        Done = quod_simplex:apply_operation_projection(8, maps:get(completion, F), S),
        ?assertEqual(#{}, owners(Done)), down(M, Child, shutdown),
        Span = take(), ?assertEqual(Id, Span#span.span_id),
        ?assertEqual(otel_span:span_id(Parent), Span#span.parent_span_id),
        ?assertEqual(<<"retirement_requested">>, attribute('quod.operation.closure', Span)),
        ?assertEqual([], ets:lookup(?SPAN_TAB, Id)),
        ?assertEqual(Done, quod_simplex:apply_operation_projection(8, maps:get(completion, F), Done)),
        no_root()
    end).

done_notification_releases_before_later_receipt_test() ->
    with_fixture(fun(F, S, _Parent, _Storage) ->
        Ref = op(F), #{pid := Child} = owner(Ref, S),
        {true, Settled} = quod_simplex:settle_operation_recovery(Child, Ref, S),
        ?assertMatch(#{status := settling, pid := none, attempt_span := none}, owner(Ref, Settled)),
        Span = take(), ?assertEqual(<<"done_observed">>, attribute('quod.operation.closure', Span)),
        ?assertEqual(false, quod_simplex:settle_operation_recovery(Child, Ref, Settled)),
        _ = quod_simplex:apply_operation_projection(8, maps:get(completion, F), Settled),
        no_root()
    end).

error_notification_releases_without_exporting_reason_test() ->
    with_fixture(fun(F, S, _Parent, _Storage) ->
        Ref = op(F), #{pid := Child} = owner(Ref, S),
        Secret = <<"private-error-must-not-be-exported">>,
        {true, Blocked} = quod_simplex:block_operation_recovery(Child, Ref, Secret, S),
        ?assertMatch(#{status := blocked, pid := none, attempt_span := none}, owner(Ref, Blocked)),
        Span = take(), ?assertEqual(<<"error_observed">>, attribute('quod.operation.closure', Span)),
        ?assertEqual(nomatch, binary:match(term_to_binary(Span), Secret)),
        ?assertEqual(false, quod_simplex:block_operation_recovery(Child, Ref, Secret, Blocked)),
        no_root()
    end).

worker_down_replacement_is_a_sibling_test() ->
    with_fixture(fun(F, S, Parent, _Storage) ->
        Ref = op(F), #{pid := Child, monitor := M} = owner(Ref, S),
        exit(Child, kill), down(M, Child, killed),
        {true, Released} = quod_simplex:drop_operation_recovery_owner(M, Child, killed, S),
        ?assertEqual(none, maps:get(attempt_span, owner(Ref, Released))),
        Span = take(), ?assertEqual(<<"worker_exit">>, attribute('quod.operation.closure', Span)),
        ?assertEqual(false, quod_simplex:drop_operation_recovery_owner(M, Child, killed, Released)),
        Ctx = maps:get(trace_ctx, owner(Ref, Released)),
        Restarted = quod_simplex:test_start_operation_recovery(Ref, Ctx, Released),
        #{pid := New, attempt_span := {_, NewHandle}} = owner(Ref, Restarted),
        NewId = otel_span:span_id(NewHandle), ?assertNotEqual(Span#span.span_id, NewId),
        [NewSpan] = ets:lookup(?SPAN_TAB, NewId),
        ?assertEqual(otel_span:span_id(Parent), NewSpan#span.parent_span_id),
        _ = quod_simplex:apply_operation_projection(8, maps:get(completion, F), Restarted),
        _ = take(), exit(New, shutdown), no_root()
    end).

history_owner_does_not_borrow_ambient_parent_on_adoption_test() ->
    with_fixture(fun(F, S, Parent, _Storage) ->
        Ref = op(F), Empty = otel_ctx:new(),
        %% Retire the initial attempt, then rebuild with no carrying ancestry.
        _ = quod_simplex:apply_operation_projection(8, maps:get(completion, F), S), _ = take(),
        Base = state(F),
        Fresh = quod_simplex:test_start_operation_recovery(Ref, Empty, Base),
        #{attempt_span := {_, Handle}} = owner(Ref, Fresh),
        [Span] = ets:lookup(?SPAN_TAB, otel_span:span_id(Handle)),
        ?assertNotEqual(otel_span:trace_id(Parent), Span#span.trace_id),
        ?assertEqual(<<"no_retained_parent">>, attribute('quod.operation.ancestry', Span)),
        {Ambient, Other} = quod_trace:start_span(otel_ctx:new(), <<"unrelated.callback">>, internal, #{}),
        Adopted = quod_trace:with_context(Ambient, fun() ->
            quod_simplex:apply_operation_projection(7, maps:get(claim, F), Fresh)
        end),
        ?assertEqual(Empty, maps:get(trace_ctx, owner(Ref, Adopted))),
        _ = quod_simplex:apply_operation_projection(8, maps:get(completion, F), Adopted),
        _ = take(), otel_span:end_span(Other), no_root()
    end).

sdk_disappearance_cannot_prevent_retirement_test() ->
    with_fixture(fun(F, S, _Parent, Storage) ->
        #{pid := Child} = owner(op(F), S), M = monitor(process, Child),
        ok = gen_server:stop(Storage),
        ?assertEqual(undefined, ets:info(?SPAN_TAB)),
        Done = quod_simplex:apply_operation_projection(8, maps:get(completion, F), S),
        ?assertEqual(#{}, owners(Done)), down(M, Child, shutdown),
        ?assertEqual(ok, quod_simplex:terminate(original_error, running, S))
    end).

returned_start_error_releases_tentative_handle_test() ->
    with_fixture(fun(F, _S, _Parent, _Storage) ->
        Bad = quod_simplex:test_state(#{ns => <<"not-the-operation-source">>}),
        Ref = op(F), Failed = quod_simplex:test_start_operation_recovery(Ref, otel_ctx:new(), Bad),
        ?assertMatch(#{status := blocked, pid := none, attempt_span := none}, owner(Ref, Failed)),
        Span = take(), ?assertEqual(<<"start_failed">>, attribute('quod.operation.closure', Span))
    end).

owner_termination_closes_without_changing_child_shutdown_semantics_test() ->
    with_fixture(fun(F, S, _Parent, _Storage) ->
        #{pid := Child} = owner(op(F), S),
        ok = quod_simplex:terminate(original_error, running, S),
        Span = take(), ?assertEqual(<<"owner_terminating">>, attribute('quod.operation.closure', Span)),
        %% In this direct callback fixture the owner has not died. Existing
        %% operation shutdown is still solely its monitored owner-DOWN edge.
        ?assert(is_process_alive(Child)), no_root()
    end).

with_fixture(Fun) ->
    quod_dtx_coordinator_unwind_tests:with_sdk(fun(Storage) ->
        F = quod_ct:remote_operation_fixture(#{}),
        {Ctx, Parent} = quod_trace:start_span(otel_ctx:new(), <<"operation.owner.test">>, internal, #{}),
        S0 = state(F),
        S1 = quod_simplex:test_start_operation_recovery(op(F), Ctx, S0),
        #{pid := Child} = owner(op(F), S1),
        S = quod_simplex:apply_operation_projection(7, maps:get(claim, F), S1),
        try Fun(F, S, Parent, Storage)
        after
            _ = catch quod_simplex:terminate(fixture_cleanup, running, S),
            exit(Child, shutdown),
            _ = catch otel_span:end_span(Parent)
        end
    end).
state(F) ->
    {Ns, Anchor} = maps:get(origin, F),
    quod_simplex:test_state(#{ns => Ns, genesis_hash => Anchor, prolog_ready => false}).
op(F) ->
    {ok, #{operation_ref := Ref}} = quod_transaction:request_claim(maps:get(claim, F)), Ref.
owners(S) -> quod_simplex:test_operation_recoveries(S).
owner(Ref, S) -> maps:get(Ref, owners(S)).
take() -> quod_trace_tests:take_span(<<"quod.operation.recover">>).
no_root() ->
    receive {quod_test_span, #span{name = <<"quod.operation.recover">>}} -> error(duplicate_root)
    after 0 -> ok end.
down(M, P, Reason) ->
    receive {'DOWN', M, process, P, Reason} -> ok
    after 2000 -> error({worker_not_down, Reason}) end.
attribute(K, #span{attributes = A}) ->
    maps:get(K, otel_attributes:map(A), undefined).

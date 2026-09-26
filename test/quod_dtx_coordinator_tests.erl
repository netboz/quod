-module(quod_dtx_coordinator_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").
-include("quod_proof_limits.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").

receipt_recovery_workers_keep_the_request_trace_test() ->
    with_operation_fixture(fun(F) ->
        quod_trace_tests:with_tracer(fun() ->
            quod_trace:with_span(otel_ctx:new(), <<"operation.test.parent">>, internal, #{},
              fun(_) ->
                  with_operation_worker(F, fun(Worker, Monitor) ->
                      with_operation_close_order(Worker, maps:get(operation_ref, F), fun() ->
                          reply_operation_source(F, terminal_operation_row(F)),
                          restore_operation_receipt(F, Worker),
                          assert_operation_result(F, Worker, Monitor, committed)
                      end)
                  end)
              end),
            Parent = quod_trace_tests:take_span(<<"operation.test.parent">>),
            Worker = quod_trace_tests:take_span(<<"quod.operation.recover">>),
            Local = quod_trace_tests:take_span(<<"quod.operation.local_outcome">>),
            Resolve = quod_trace_tests:take_span(<<"quod.operation.completion_evidence">>),
            Notify = quod_trace_tests:take_span(<<"quod.operation.result_notify">>),
            ?assertEqual(Parent#span.trace_id, Worker#span.trace_id),
            ?assertEqual(Parent#span.span_id, Worker#span.parent_span_id),
            ?assertEqual(Worker#span.trace_id, Local#span.trace_id),
            assert_operation_wave_ancestry(Local, Worker),
            ?assert(Local#span.end_time =< Resolve#span.start_time),
            ?assertEqual(
               #{'quod.namespace' => maps:get(source_ns, F)},
               otel_attributes:map(Local#span.attributes)),
            assert_operation_wave_ancestry(Resolve, Worker),
            Events = lists:reverse(otel_events:list(Worker#span.events)),
            ?assertEqual([<<"operation.worker_started">>, <<"operation.close_observed">>],
                         [E#event.name || E <- Events]),
            [Started, Closed] = Events,
            [Sent] = otel_events:list(Notify#span.events),
            ?assertEqual(Worker#span.trace_id, Notify#span.trace_id),
            ?assertEqual(Worker#span.span_id, Notify#span.parent_span_id),
            ?assertEqual(<<"operation.result_sent">>, Sent#event.name),
            ?assert(Started#event.system_time_native =< Local#span.start_time),
            ?assert(Resolve#span.end_time =< Sent#event.system_time_native),
            ?assertEqual(#{}, otel_attributes:map(Sent#event.attributes)),
            ?assertEqual(#{}, otel_attributes:map(Started#event.attributes)),
            ?assertEqual(#{'quod.operation.result' => <<"done">>},
                         otel_attributes:map(Closed#event.attributes)),
            ?assert(Sent#event.system_time_native =< Closed#event.system_time_native)
        end)
    end).

assert_operation_wave_ancestry(Child, Root) ->
    Item = take_operation_span(Child#span.parent_span_id),
    Wave = take_operation_span(Item#span.parent_span_id),
    ?assertEqual(<<"quod.dtx.wave.item">>, Item#span.name),
    ?assertEqual(<<"quod.dtx.wave">>, Wave#span.name),
    ?assertEqual(Root#span.span_id, Wave#span.parent_span_id),
    [?assertEqual(Root#span.trace_id, Span#span.trace_id) || Span <- [Child, Item, Wave]],
    ?assert(Wave#span.start_time =< Item#span.start_time),
    ?assert(Item#span.start_time =< Child#span.start_time),
    ?assert(Child#span.end_time =< Item#span.end_time),
    ?assert(Item#span.end_time =< Wave#span.end_time).

with_operation_close_order(Worker, Op, Fun) ->
    Session = trace:session_create(operation_close_order, self(), []),
    1 = trace:function(Session, {quod_trace, add_event, 3}, true, [local]),
    1 = trace:process(Session, Worker, true, [call, send]),
    try
        Result = Fun(),
        %% Both records originate in this same worker: this pins program
        %% order, not delivery/processing order across different recipients.
        receive
            {trace, Worker, call, {quod_trace, add_event,
              [_Ctx, <<"operation.close_observed">>, _Attrs]}} -> ok;
            {trace, Worker, send, {dtx_coordinator, Worker, Op, {done, Op}}, _} ->
                error(operation_notification_before_final_event)
        after 1000 -> error(missing_final_event_trace) end,
        receive {trace, Worker, send, {dtx_coordinator, Worker, Op, {done, Op}}, _} -> ok
        after 1000 -> error(missing_done_notification_trace) end,
        Result
    after trace:session_destroy(Session) end.

take_operation_span(Id) ->
    receive {quod_test_span, #span{span_id = Id} = Span} -> Span
    after 1000 -> error({missing_operation_ancestor, Id}) end.

%% A source projection is discovery, not permission to add another target.
%% The certified claim fixes the vector before any target is dispatched.
operation_projection_cannot_add_a_target_to_the_certified_claim_test() ->
    with_operation_fixture(fun(F) ->
        with_operation_worker(F, fun(Worker, Monitor) ->
            {ok, Row} = terminal_operation_row(F),
            Ref = maps:get(target_ref, F),
            Other = {transaction, <<"quod:s7-other">>, digest(250), digest(251)},
            {ok, Refs} = quod_operation_vector:references([Ref, Other]),
            reply_operation_source(F, {ok, Row#{outcome_ref := {applications, Refs}}}),
            Op = maps:get(operation_ref, F),
            receive
                {dtx_coordinator, Worker, Op, {claim_state, terminal, 2, _, Refs}} -> ok;
                {dtx_coordinator, Worker, Op, OtherMessage} ->
                    error({multi_target_worker_dispatched, OtherMessage})
            after 1000 -> error(multi_target_projection_not_observed)
            end,
            reply_operation_claim(F),
            assert_operation_error(F, Worker, Monitor, invalid_operation_claim),
            assert_no_target_result(Worker)
        end)
    end).

%% Drive the real fresh-result branch, including its ordinary receipt call.
%% Holding that call proves the target result is sent before receipt drain;
%% tracing never substitutes a decoder, a verifier, or a delivery result.
fresh_operation_result_decode_and_send_are_traced_test_() ->
    [{atom_to_list(Class), fun() ->
        fresh_operation_result_trace(Class)
      end} || Class <- [committed, rejected, malformed, wrong_target]].

held_target_cannot_delay_another_targets_application_and_certificate_test() ->
    with_operation_fixture(2, fun(F = #{operation_ref := Op, target_refs := Refs,
                                      targets := [A, B], target_data := Data}) ->
        FA = maps:merge(F, maps:get(A, Data)), FB = maps:merge(F, maps:get(B, Data)),
        RefA = maps:get(target_ref, FA), RefB = maps:get(target_ref, FB),
        with_operation_worker(F, fun(Worker, Monitor) ->
            {ok, Row} = terminal_operation_row(F),
            reply_operation_source(F, {ok, Row#{operation_state := unresolved,
                                               receipt_height := none, included := []}}),
            receive {dtx_coordinator, Worker, Op, {claim_state, unresolved, 2, _, Refs}} -> ok
            after 1000 -> error(missing_vector_claim_binding) end,
            reply_operation_claim(F),
            {FromA, RequestA} = expect_operation_application(FA),
            {FromB, RequestB} = expect_operation_application(FB),
            reply_operation_application(FA, FromA, RequestA),
            {VoteFromA, VoteRequestA, _} = operation_vote_request(FA, local),
            reply_operation_vote(FA, VoteFromA, VoteRequestA,
                                 #{status => committed, height => 2, ref => RefA}),
            receive {dtx_coordinator, Worker, Op, {target_result, committed, RefA}} -> ok
            after 1000 -> error(held_target_blocked_other_certificate) end,
            %% B's actual endpoint reply is still held. A has already been
            %% verified, certified and installed through the production loop.
            ?assertMatch(#{wave := #{workers := 1}, protocol := {operation,
              #{model := #{observations := #{A := #{certificate := _}}}}}},
              quod_dtx_coordinator:test_state(Worker)),
            assert_no_operation_stub_calls(),
            reply_operation_application(FB, FromB, RequestB),
            {VoteFromB, VoteRequestB, _} = operation_vote_request(FB, local),
            reply_operation_vote(FB, VoteFromB, VoteRequestB,
              #{status => rejected, reason => conflict_retry, height => 2, ref => RefB}),
            receive {dtx_coordinator, Worker, Op,
                     {target_result, {rejected, conflict_retry}, RefB}} -> ok
            after 1000 -> error(missing_second_target_certificate) end,
            ReceiptFrom = expect_vector_receipt(F,
              [{A, {committed, RefA}}, {B, {{rejected, conflict_retry}, RefB}}]),
            gen_server:reply(ReceiptFrom, {ok, [], 4, digest(252)}),
            receive {dtx_coordinator, Worker, Op, {done, Op}} -> ok
            after 1000 -> error(vector_receipt_not_completed) end,
            receive {'DOWN', Monitor, process, Worker, normal} -> ok
            after 1000 -> error(vector_worker_not_finished) end,
            assert_no_operation_stub_calls()
        end)
    end).

target_continuation_admission_boundaries_test_() ->
    [{atom_to_list(Kind), fun() ->
      isolated_continuation_fixture(fun() ->
        %% These are direct production scheduling transitions with signed
        %% fixture models, not a consensus-admitted or live-latency witness.
        with_operation_fixture(2, fun(F) ->
            {ok, Model} = quod_operation:new(maps:get(source_ns, F),
              maps:get(operation_ref, F), maps:get(certified_claim_ref, F), maps:get(claim, F)),
            Now = quod_time:mono_ms(),
            {Ready, Deadline, Progress, Busy, Result, Expected} = case Kind of
                admitted -> {true, Now + 1000, true, false, {error, retry}, 1};
                no_progress -> {true, Now + 1000, false, false, {error, retry}, 0};
                paused -> {false, Now + 1000, true, false, {error, retry}, 0};
                expired -> {true, Now - 1, true, false, {error, retry}, 0};
                already_running -> {true, Now + 1000, true, true, {error, retry}, 0};
                fatal -> {true, Now + 1000, true, false, {error, invalid_target_evidence}, 0}
            end,
            ?assertMatch(#{admitted := Expected, deadline := Deadline},
              quod_dtx_coordinator:test_operation_continuation_admission(
                Model, Ready, Deadline, Progress, Busy, Result))
        end)
      end)
    end} || Kind <- [admitted, no_progress, paused, expired, already_running, fatal]].

isolated_continuation_fixture(Fun) ->
    %% Even the positive admission case may have an endpoint signal in flight
    %% when its synthetic callback owner reaps the worker. Keep every such
    %% fixture message in a disposable process, never the combined-suite inbox.
    {Pid, Monitor} = spawn_monitor(Fun),
    receive {'DOWN', Monitor, process, Pid, Reason} -> ?assertEqual(normal, Reason)
    after 3000 -> exit(Pid, kill), demonitor(Monitor, [flush]), error(continuation_fixture_timeout)
    end.

independent_retry_does_not_join_a_held_sibling_test_() ->
    [{atom_to_list(Order), fun() -> independent_retry_continuation(Order) end}
      || Order <- [progress_before_result, progress_after_result, paused_then_ready,
                   foreign_progress, retained_application]].

independent_retry_continuation(Order) ->
    with_operation_fixture(2, fun(F = #{operation_ref := Op, target_refs := Refs,
                                      targets := [A, B], target_data := Data}) ->
        FA = maps:merge(F, maps:get(A, Data)), FB = maps:merge(F, maps:get(B, Data)),
        RefA = maps:get(target_ref, FA), RefB = maps:get(target_ref, FB),
      with_continuation_follow(Order, fun() ->
        with_operation_worker(F, fun(Worker, Monitor) ->
            {ok, Row} = terminal_operation_row(F),
            reply_operation_source(F, {ok, Row#{operation_state := unresolved,
                                               receipt_height := none, included := []}}),
            receive {dtx_coordinator, Worker, Op, {claim_state, unresolved, 2, _, Refs}} -> ok
            after 1000 -> error(missing_retry_claim_binding) end,
            reply_operation_claim(F),
            {FromA, RequestA = {apply_claim, IdA, A, ClaimBytes}} = expect_operation_application(FA),
            {FromB, RequestB} = expect_operation_application(FB),
            #{wave := #{correlation := WaveRef, meta := #{request_deadline := Deadline}}} =
                quod_dtx_coordinator:test_state(Worker),
            case Order of
                progress_before_result ->
                    %% Multiple readiness transitions coalesce; no second worker
                    %% may run for A while its first endpoint is still held.
                    [operation_resume(Worker, Op) || _ <- lists:seq(1, 3)],
                    ?assertMatch(#{wave := #{workers := 2}},
                                 quod_dtx_coordinator:test_state(Worker)),
                    assert_no_operation_stub_calls();
                paused_then_ready ->
                    {operation, Ns, Anchor, _, _} = Op,
                    Worker ! {local_dtx_progress, self(), {Ns, Anchor}, 0, false},
                    ?assertMatch(#{execution_ready := false},
                                 quod_dtx_coordinator:test_state(Worker));
                _ -> ok
            end,
            ExpectedStored = case Order of
                retained_application ->
                    reply_operation_application(FA, FromA, RequestA),
                    {PendingFrom, PendingRequest, _} = operation_vote_request(FA, local),
                    reply_operation_vote(FA, PendingFrom, PendingRequest,
                                         #{status => pending, ref => RefA}),
                    observed;
                _ -> gen_server:reply(FromA, {ok, {error, IdA, not_ready}, []}), {error, retry}
            end,
            FollowRef = case Order of
                progress_before_result -> none;
                foreign_progress ->
                    Follow = attach_operation_follow(FA, Worker),
                    _ = await_operation_target_result(Worker, ExpectedStored, quod_time:mono_ms() + 1000),
                    operation_status_notices(FA, Worker, Follow),
                    %% Source progress and a completed-target wake cannot
                    %% stand in for A's actual dependency changing.
                    operation_ready(Worker, self(), Op),
                    ?assertMatch(#{wave := #{workers := 1, progress_edges := Edges}}
                                   when map_size(Edges) =:= 0,
                                 quod_dtx_coordinator:test_state(Worker)),
                    assert_no_operation_stub_calls(),
                    wake_operation_follow(FA, Worker, Follow),
                    Follow;
                _ ->
                    Parked = await_operation_target_result(Worker, ExpectedStored, quod_time:mono_ms() + 1000),
                    ?assertMatch(#{wave := #{workers := 1,
                        meta := #{request_deadline := Deadline}}}, Parked),
                    %% Same-owner state responses establish processing, not
                    %% cross-recipient send notifications or sleeps.
                    [quod_dtx_coordinator:test_state(Worker) || _ <- lists:seq(1, 3)],
                    assert_no_operation_stub_calls(),
                    operation_resume(Worker, Op),
                    none
            end,
            case Order of
                retained_application -> ok;
                _ ->
                    {RetryFrom, RetryRequest = {apply_claim, RetryId, A, RetryBytes}} =
                        expect_operation_application(FA),
                    ?assertNotEqual(IdA, RetryId),
                    ?assertEqual(ClaimBytes, RetryBytes),
                    reply_operation_application(FA, RetryFrom, RetryRequest)
            end,
            %% A retained application continues with a vote, never another
            %% application call or sufficient-history recapture. This helper
            %% would fail on an apply_claim instead of the expected vote.
            {VoteFromA, VoteRequestA, _} = operation_vote_request(FA, local),
            %% Reusing the logical wave/index must not let an old worker's
            %% delayed result poison the newly admitted target attempt.
            Worker ! {dtx_wave_result, WaveRef, element(1, FromA), 1,
                       {error, invalid_target_evidence}},
            #{wave := #{workers := 2, results := PendingResults,
                        meta := #{request_deadline := Deadline}}} =
                quod_dtx_coordinator:test_state(Worker),
            ?assertNot(maps:is_key(1, PendingResults)),
            case Order of
                foreign_progress ->
                    %% A's followed progress must not authorize a retry of
                    %% B after its held result arrives. The old broad wake
                    %% left an unused allowance for B here.
                    ?assertMatch(#{wave := #{progress_edges := Edges}} when map_size(Edges) =:= 0,
                                 quod_dtx_coordinator:test_state(Worker));
                _ -> ok
            end,
            reply_operation_vote(FA, VoteFromA, VoteRequestA,
                                 #{status => committed, height => 2, ref => RefA}),
            receive {dtx_coordinator, Worker, Op, {target_result, committed, RefA}} -> ok
            after 1000 -> error(retry_waited_for_held_sibling) end,
            operation_ready(Worker, self(), Op),
            ?assertMatch(#{wave := #{workers := 1}}, quod_dtx_coordinator:test_state(Worker)),
            assert_no_operation_stub_calls(),
            %% A's certified result is installed while B's original request
            %% has never been released. Complete-vector publication still joins.
            reply_operation_application(FB, FromB, RequestB),
            {VoteFromB, VoteRequestB, _} = operation_vote_request(FB, local),
            reply_operation_vote(FB, VoteFromB, VoteRequestB,
                                 #{status => committed, height => 2, ref => RefB}),
            receive {dtx_coordinator, Worker, Op, {target_result, committed, RefB}} -> ok
            after 1000 -> error(missing_held_sibling_result) end,
            ReceiptFrom = expect_vector_receipt(F, [{A, {committed, RefA}}, {B, {committed, RefB}}]),
            gen_server:reply(ReceiptFrom, {ok, [], 4, digest(253)}),
            receive {dtx_coordinator, Worker, Op, {done, Op}} -> ok
            after 1000 -> error(retry_receipt_not_completed) end,
            receive {'DOWN', Monitor, process, Worker, normal} -> ok
            after 1000 -> error(retry_worker_not_finished) end,
            case FollowRef of
                none -> ok;
                _ -> _ = expect_operation_stub_call(foreign, {unfollow, FollowRef}), ok
            end,
            assert_no_operation_stub_calls(),
            ?assertMatch({apply_claim, IdA, A, ClaimBytes}, RequestA)
        end)
      end)
    end).

with_continuation_follow(foreign_progress, Fun) ->
    with_operation_follow_owner(fun(_) -> Fun() end);
with_continuation_follow(_, Fun) -> Fun().

parked_targets_resume_only_on_their_own_progress_test() ->
    with_operation_fixture(2, fun(F = #{operation_ref := Op, target_refs := Refs,
                                      targets := [A, B], target_data := Data}) ->
        FA = maps:merge(F, maps:get(A, Data)), FB = maps:merge(F, maps:get(B, Data)),
        with_operation_follow_owner(fun(_) ->
          with_operation_worker(F, fun(Worker, _Monitor) ->
            reply_operation_source(F, unresolved_operation_row(F)),
            receive {dtx_coordinator, Worker, Op, {claim_state, unresolved, 2, _, Refs}} -> ok
            after 1000 -> error(missing_scoped_claim_binding) end,
            reply_operation_claim(F),
            {FromA, {apply_claim, IdA, A, Bytes}} = expect_operation_application(FA),
            {FromB, {apply_claim, IdB, B, Bytes}} = expect_operation_application(FB),
            gen_server:reply(FromA, {ok, {error, IdA, not_ready}, []}),
            FollowA = attach_operation_follow(FA, Worker),
            gen_server:reply(FromB, {ok, {error, IdB, not_ready}, []}),
            FollowB = attach_operation_follow(FB, Worker),
            dormant_await_idle(Worker),
            wake_operation_follow(FA, Worker, FollowA),
            %% No source re-read and no B call: actual I/O, not just an
            %% internal scheduling flag, pins the dependency boundary.
            {RetryA, {apply_claim, NewA, A, Bytes}} = expect_operation_application(FA),
            ?assertMatch(#{wave := #{items := [{application, A}], workers := 1}},
                         quod_dtx_coordinator:test_state(Worker)),
            assert_no_operation_stub_calls(),
            %% B changes while A's narrower wave is in flight. Its edge must
            %% survive that wave, without minting another allowance for A.
            wake_operation_follow(FB, Worker, FollowB),
            ?assertMatch(#{progress_pending := #{B := true}},
                         quod_dtx_coordinator:test_state(Worker)),
            gen_server:reply(RetryA, {ok, {error, NewA, not_ready}, []}),
            {_, {apply_claim, NewB, B, Bytes}} = expect_operation_application(FB),
            ?assertNotEqual(IdB, NewB),
            ?assertMatch(#{wave := #{items := [{application, B}], workers := 1}},
                         quod_dtx_coordinator:test_state(Worker)),
            assert_no_operation_stub_calls()
          end)
        end)
    end).

all_returned_targets_park_with_the_original_deadline_test() ->
    with_operation_fixture(2, fun(F = #{operation_ref := Op, target_refs := Refs,
                                      targets := [A, B], target_data := Data}) ->
        FA = maps:merge(F, maps:get(A, Data)), FB = maps:merge(F, maps:get(B, Data)),
        with_operation_worker(F, fun(Worker, _Monitor) ->
            {ok, Row} = terminal_operation_row(F),
            reply_operation_source(F, {ok, Row#{operation_state := unresolved,
                                               receipt_height := none, included := []}}),
            receive {dtx_coordinator, Worker, Op, {claim_state, unresolved, 2, _, Refs}} -> ok
            after 1000 -> error(missing_parked_claim_binding) end,
            reply_operation_claim(F),
            {FromA, {apply_claim, IdA, A, Bytes}} = expect_operation_application(FA),
            {FromB, {apply_claim, IdB, B, Bytes}} = expect_operation_application(FB),
            #{wave := #{correlation := WaveRef, meta := #{request_deadline := Deadline}}} =
                quod_dtx_coordinator:test_state(Worker),
            {operation, Ns, Anchor, _, _} = Op,
            Worker ! {local_dtx_progress, self(), {Ns, Anchor}, 0, false},
            ?assertMatch(#{execution_ready := false}, quod_dtx_coordinator:test_state(Worker)),
            gen_server:reply(FromA, {ok, {error, IdA, not_ready}, []}),
            gen_server:reply(FromB, {ok, {error, IdB, not_ready}, []}),
            Parked = await_all_targets_parked(Worker, quod_time:mono_ms() + 1000),
            ?assertMatch(#{wave := #{running := true, correlation := WaveRef, workers := 0,
                                    meta := #{request_deadline := Deadline}}}, Parked),
            operation_ready(Worker, self(), Op),
            {_, {apply_claim, NewA, A, Bytes}} = expect_operation_application(FA),
            {_, {apply_claim, NewB, B, Bytes}} = expect_operation_application(FB),
            ?assertNotEqual(IdA, NewA), ?assertNotEqual(IdB, NewB),
            ?assertMatch(#{wave := #{workers := 2, correlation := WaveRef,
                                    meta := #{request_deadline := Deadline}}},
                         quod_dtx_coordinator:test_state(Worker)),
            assert_no_operation_stub_calls()
        end)
    end).

await_all_targets_parked(Worker, Limit) ->
    case quod_dtx_coordinator:test_state(Worker) of
        #{wave := #{workers := 0}} = State -> State;
        #{wave := none} -> error(discarded_paused_target_wave);
        _ -> true = quod_time:mono_ms() < Limit, await_all_targets_parked(Worker, Limit)
    end.

one_progress_edge_cannot_be_reused_after_the_target_wave_test() ->
    with_operation_fixture(2, fun(F = #{operation_ref := Op, target_refs := Refs,
                                      targets := [A, B], target_data := Data}) ->
        FA = maps:merge(F, maps:get(A, Data)), FB = maps:merge(F, maps:get(B, Data)),
        with_operation_worker(F, fun(Worker, _Monitor) ->
            {ok, Row} = terminal_operation_row(F),
            reply_operation_source(F, {ok, Row#{operation_state := unresolved,
                                               receipt_height := none, included := []}}),
            receive {dtx_coordinator, Worker, Op, {claim_state, unresolved, 2, _, Refs}} -> ok
            after 1000 -> error(missing_edge_claim_binding) end,
            reply_operation_claim(F),
            {FromA, {apply_claim, IdA, A, Bytes}} = expect_operation_application(FA),
            {FromB, RequestB} = expect_operation_application(FB),
            gen_server:reply(FromA, {ok, {error, IdA, not_ready}, []}),
            _ = await_operation_target_result(Worker, {error, retry}, quod_time:mono_ms() + 1000),
            operation_resume(Worker, Op),
            {RetryFrom, {apply_claim, RetryId, A, Bytes}} = expect_operation_application(FA),
            gen_server:reply(RetryFrom, {ok, {error, RetryId, not_ready}, []}),
            _ = await_operation_target_result(Worker, {error, retry}, quod_time:mono_ms() + 1000),
            reply_operation_application(FB, FromB, RequestB),
            {VoteFrom, VoteRequest, _} = operation_vote_request(FB, local),
            RefB = maps:get(target_ref, FB),
            reply_operation_vote(FB, VoteFrom, VoteRequest,
                                 #{status => committed, height => 2, ref => RefB}),
            receive {dtx_coordinator, Worker, Op, {target_result, committed, RefB}} -> ok
            after 1000 -> error(missing_edge_sibling_result) end,
            ?assertMatch(#{wave := none, progress_pending := false},
                         quod_dtx_coordinator:test_state(Worker)),
            %% A second owner turn catches an already-queued old drive. It
            %% must not refresh the source or mint another target allowance.
            ?assertMatch(#{wave := none, progress_pending := false},
                         quod_dtx_coordinator:test_state(Worker)),
            assert_no_operation_stub_calls()
        end)
    end).

await_operation_target_result(Worker, Expected, Limit) ->
    receive
        {operation_stub_call, target, _, {dtx_endpoint_local, {apply_claim, _, _, _}, _, _, _}} ->
            error(unprompted_target_redelivery)
    after 0 -> ok
    end,
    case quod_dtx_coordinator:test_state(Worker) of
        #{wave := #{workers := 1, results := #{1 := Expected}}} = State -> State;
        _ -> true = quod_time:mono_ms() < Limit, await_operation_target_result(Worker, Expected, Limit)
    end.

reply_operation_application(F, From, {apply_claim, Id, _, _}) ->
    {ok, Blob} = quod_transaction:encode_evidence(
      maps:get(certified_target_ref, F), maps:get(application, F)),
    gen_server:reply(From, {ok, {application, Id, committed, Blob}, []}).

fresh_operation_result_trace(Class) ->
    with_operation_fixture(fun(F = #{operation_ref := Op, target_ref := TargetRef}) ->
        with_operation_follow_owner(fun(_Foreign) ->
            quod_trace_tests:with_tracer(fun() ->
                quod_trace:with_span(otel_ctx:new(), <<"operation.fresh.test">>, internal, #{},
                  fun(_) -> with_operation_owner(F, fun(Worker, Monitor, OwnerState) ->
                    {ok, Row} = terminal_operation_row(F),
                    reply_operation_source(F, {ok, Row#{operation_state := unresolved,
                                                       receipt_height := none, included := []}}),
                    receive {dtx_coordinator, Worker, Op, {claim_state, unresolved, 2, _, [TargetRef]}} -> ok
                    after 1000 -> error(missing_fresh_claim_binding) end,
                    reply_operation_claim(F),
                    {From, {apply_claim, Id, _, _}} = expect_operation_application(F),
                    {Ref, Tx} = case Class of
                        wrong_target ->
                            Other = quod_ct:remote_operation_fixture(#{}),
                            {maps:get(certified_target_ref, Other), maps:get(application, Other)};
                        _ -> {maps:get(certified_target_ref, F), maps:get(application, F)}
                    end,
                    {ok, Encoded} = quod_transaction:encode_evidence(Ref, Tx),
                    Blob = case Class of malformed -> <<"not an evidence blob">>; _ -> Encoded end,
                    %% Deliberately lie in the transport result label for the
                    %% rejected case: only the independently signed AM3 wins.
                    gen_server:reply(From, {ok, {application, Id, committed, Blob}, []}),
                    case Class of
                        C when C =:= committed; C =:= rejected ->
                            {VoteFrom, VoteRequest, _} = operation_vote_request(F, local),
                            Result = case C of committed -> committed; rejected -> {rejected, conflict_retry} end,
                            Outcome = case Result of
                                committed -> #{status => committed, height => 2, ref => TargetRef};
                                {rejected, Reason} -> #{status => rejected, reason => Reason,
                                                       height => 2, ref => TargetRef}
                            end,
                            reply_operation_vote(F, VoteFrom, VoteRequest, Outcome),
                            receive {dtx_coordinator, Worker, Op, {target_result, Result, TargetRef}} -> ok
                            after 1000 -> error(missing_fresh_target_result) end,
                            ReceiptFrom = expect_operation_receipt(F, Result),
                            ?assert(is_process_alive(Worker)),
                            Notify = quod_trace_tests:take_span(<<"quod.operation.result_notify">>),
                            ?assertNot(Notify#span.is_recording),
                            receive {dtx_coordinator, Worker, Op, {done, _}} ->
                                error(receipt_drain_was_not_waited)
                            after 0 -> ok end,
                            receive {quod_test_span, #span{name = <<"quod.operation.recover">>}} ->
                                error(recovery_parent_ended_before_receipt)
                            after 0 -> ok end,
                            gen_server:reply(ReceiptFrom, {ok, [], 4, digest(252)}),
                            receive {dtx_coordinator, Worker, Op, {done, Op}} -> ok
                            after 1000 -> error(missing_fresh_operation_done) end,
                            receive {'DOWN', Monitor, process, Worker, normal} -> ok
                            after 1000 -> error(fresh_operation_worker_did_not_finish) end,
                            {true, _Released} = quod_simplex:settle_operation_recovery(Worker, Op, OwnerState),
                            Root = quod_trace_tests:take_span(<<"quod.operation.recover">>),
                            Probe = quod_trace_tests:take_span(<<"quod.dtx.quorum.probe">>),
                            Collector = take_operation_span(Probe#span.parent_span_id),
                            ?assertEqual(<<"quod.dtx.quorum.collect">>, Collector#span.name),
                            ?assertEqual(Root#span.trace_id, Probe#span.trace_id),
                            ?assertEqual(Collector#span.trace_id, Probe#span.trace_id),
                            ?assert(Collector#span.start_time =< Probe#span.start_time),
                            ?assert(Probe#span.end_time =< Collector#span.end_time),
                            assert_operation_wave_ancestry(Collector, Root),
                            Decode = quod_trace_tests:take_span(<<"quod.operation.result_evidence_decode">>),
                            Receipt = quod_trace_tests:take_span(<<"quod.operation.receipt">>),
                            ?assertEqual(Root#span.trace_id, Notify#span.trace_id),
                            ?assertEqual(Root#span.span_id, Notify#span.parent_span_id),
                            ?assertEqual(#{}, otel_attributes:map(Decode#span.attributes)),
                            [Sent] = otel_events:list(Notify#span.events),
                            ?assertEqual(<<"operation.result_sent">>, Sent#event.name),
                            ?assert(Decode#span.end_time =< Sent#event.system_time_native),
                            ?assert(Notify#span.end_time =< Receipt#span.start_time),
                            ?assertEqual(Root#span.trace_id, Receipt#span.trace_id);
                        malformed ->
                            %% The existing worker authenticates opaque reply
                            %% evidence before any exact-history/AM3 work.
                            assert_operation_error(F, Worker, Monitor, invalid_operation_claim),
                            assert_no_target_result(Worker);
                        wrong_target ->
                            %% The model binds the application to this exact
                            %% claim/target before evidence or route work.
                            assert_operation_error(F, Worker, Monitor, invalid_operation_claim),
                            assert_no_target_result(Worker)
                    end
                  end) end),
                assert_no_operation_stub_calls()
            end)
        end)
    end).

reply_operation_claim(F = #{source_ns := Ns}) ->
    receive
        {operation_stub_call, source_consensus, From, {history_view, Ns, any, Deadline}} ->
            ?assert(Deadline > quod_time:mono_ms()),
            gen_server:reply(From, {ok, maps:get(source_view, F)})
    after 1000 -> error(missing_exact_source_claim_read) end.

expect_operation_application(#{target := Target, claim := Claim, certified_claim_ref := ClaimRef}) ->
    receive
        {operation_stub_call, target, From,
         {dtx_endpoint_local, {apply_claim, _, Target, Bytes} = Request, [], Timeout, _Trace}} ->
            ?assert(Timeout > 0),
            ?assertEqual({ok, Bytes}, quod_transaction:encode_evidence(ClaimRef, Claim)),
            {From, Request}
    after 1000 -> error(missing_exact_claim_application) end.

expect_operation_receipt(F = #{target := Target, target_ref := Ref}, Result) ->
    expect_vector_receipt(F, [{Target, {Result, Ref}}]).

expect_vector_receipt(F = #{operation_ref := Op, request_digest := Digest,
                           target_data := Data}, Expected) ->
    receive
        {operation_stub_call, source, From,
         {submit_role, #transaction{role = {remote_complete, Op, Digest, Rows}}, [], _Trace}} ->
            ?assertEqual(maps:get(targets, F), [T || {T, _} <- Rows]),
            Actual = [begin
                ?assert(quod_applied_certificate:verify_operation_certificate(
                  Certificate, maps:get(network, F), maps:get(evidence, maps:get(Target, Data)))),
                {ok, #{result := Certified}} =
                    quod_applied_certificate:operation_certificate_binding(Certificate),
                {Target, {case Certified of applied -> committed; _ -> Certified end, Ref}}
            end || {Target, {certified, Ref, Certificate}} <- Rows],
            ?assertEqual(Expected, Actual),
            From
    after 1000 -> error(missing_certified_source_receipt) end.

options_are_strict_and_share_the_endpoint_deadline_test() ->
    ?assertMatch({ok, _}, quod_dtx_coordinator:test_options(#{})),
    ?assertMatch(
       {ok, _},
       quod_dtx_coordinator:test_options(
         #{request_timeout_ms => 1})),
    ?assertEqual(
       {error, invalid_coordinator_options},
       quod_dtx_coordinator:test_options(#{unknown => 1})),
    ?assertEqual(
       {error, invalid_coordinator_options},
       quod_dtx_coordinator:test_options(
         #{request_timeout_ms =>
               ?QUOD_DTX_ENDPOINT_WORKER_TIMEOUT_MS + 1})),
    ?assertEqual(
       {error, invalid_coordinator_options},
       quod_dtx_coordinator:test_options(
         #{request_timeout_ms => 0})).

remote_operation_temporary_reply_parks_on_progress_test() ->
    Fixture = quod_ct:remote_operation_fixture(#{}),
    {ok, ClaimEvidence} = quod_transaction:encode_evidence(
                            maps:get(certified_claim_ref, Fixture),
                            maps:get(claim, Fixture)),
    RequestId = <<199:128>>,
    Request = {apply_claim, RequestId, maps:get(participant_target, Fixture), ClaimEvidence},
    lists:foreach(
      fun(Reason) ->
          ?assertEqual(
             {error, retry},
             quod_dtx_coordinator:
               test_operation_application_evidence(
                 #{}, Request, {ok, {error, RequestId, Reason}, []}))
      end,
      [busy, not_ready, not_found, conflict_retry,
       read_certificate_unavailable]),
    ?assertEqual(
       {error, invalid_operation_claim},
       quod_dtx_coordinator:test_operation_application_evidence(
         #{}, Request, {ok, {error, RequestId, invalid_request}, []})),
    ?assertEqual(
       {error, invalid_target_response},
       quod_dtx_coordinator:test_operation_application_evidence(
         #{}, Request, {ok, {error, <<200:128>>, not_ready}, []})),
    ?assertEqual(
       {error, invalid_target_response},
       quod_dtx_coordinator:test_operation_application_evidence(
         #{}, Request, {ok, malformed, []})).

application_result_carries_only_its_bound_acceleration_test() ->
    quod_operation_fixture:with(2, fun(F) ->
        {ok, Model} = quod_operation:new(
                        maps:get(source_ns, F), maps:get(operation_ref, F),
                        maps:get(certified_claim_ref, F), maps:get(claim, F)),
        [Target, OtherTarget] = maps:get(targets, F),
        Data = maps:get(target_data, F),
        Own = maps:get(Target, Data),
        Other = maps:get(OtherTarget, Data),
        RequestId = <<201:128>>,
        {ok, ClaimBlob} = quod_transaction:encode_evidence(
                            maps:get(certified_claim_ref, F), maps:get(claim, F)),
        {ok, ApplicationBlob} = quod_transaction:encode_evidence(
                                  maps:get(certified_target_ref, Own),
                                  maps:get(application, Own)),
        Request = {apply_claim, RequestId, Target, ClaimBlob},
        Response = {application, RequestId, committed, ApplicationBlob},
        Signer = maps:get(node_identity, F),
        Key = maps:get(pubkey, Signer),
        Vote = fun(D) ->
            Ref = maps:get(certified_target_ref, D),
            {ok, Statement} = quod_applied_certificate:operation_statement(
                                maps:get(network, F), maps:get(evidence, D), applied),
            {ok, {Key, Signature}} =
                quod_applied_certificate:sign_operation_vote(Statement, Signer),
            {{operation_vote, Ref, Key}, {Statement, Signature}}
        end,
        OwnRef = maps:get(certified_target_ref, Own),
        OwnVote = Vote(Own),
        Sidecar = [{OwnRef, maps:get(entry, Own)}, OwnVote,
                   {maps:get(certified_target_ref, Other), maps:get(entry, Other)},
                   Vote(Other)],
        ?assertMatch(
           {ok, OwnRef,
            #{entry_hint := _, operation_votes := [OwnVote]}},
           quod_dtx_coordinator:test_operation_application_evidence(
             Model, Request, {ok, Response, Sidecar})),
        {ok, OwnRef, Acceleration} =
            quod_dtx_coordinator:test_operation_application_evidence(
              Model, Request, {ok, Response, Sidecar}),
        ?assertEqual(maps:get(entry, Own), maps:get(entry_hint, Acceleration))
    end).

%% Completed receipts restore their certified vector without fresh votes or
%% target application. Only owner interfaces are stubs; unexpected transport
%% or receipt submission fails. In-progress certification is tested separately.
terminal_operation_recovers_committed_result_without_resubmission_test() ->
    with_operation_fixture(
      fun(F) ->
          with_operation_worker(F,
            fun(Worker, Monitor) ->
                reply_operation_source(F, terminal_operation_row(F)),
                restore_operation_receipt(F, Worker),
                assert_operation_result(F, Worker, Monitor, committed)
            end)
      end).

terminal_operation_recovers_rejected_result_without_resubmission_test() ->
    with_operation_fixture(1, {rejected, conflict_retry},
      fun(F) ->
          with_operation_worker(F,
            fun(Worker, Monitor) ->
                reply_operation_source(F, terminal_operation_row(F)),
                restore_operation_receipt(F, Worker),
                assert_operation_result(
                  F, Worker, Monitor, {rejected, conflict_retry})
            end)
      end).

unknown_operation_waits_for_its_source_projection_edge_test() ->
    with_operation_fixture(
      fun(F = #{operation_ref := OperationRef}) ->
          with_operation_worker(F,
            fun(Worker, Monitor) ->
                reply_operation_source(F, {error, not_found}),
                %% Send the edge after the failed source read. It is retained
                %% in the worker mailbox even if it arrives before parking.
                operation_ready(Worker, self(), OperationRef),
                reply_operation_source(F, terminal_operation_row(F)),
                restore_operation_receipt(F, Worker),
                assert_operation_result(F, Worker, Monitor, committed)
            end)
      end).

terminal_operation_rejects_mismatched_source_reference_test() ->
    with_operation_fixture(
      fun(F = #{operation_ref := OperationRef}) ->
          with_operation_worker(F,
            fun(Worker, Monitor) ->
                {ok, Row} = terminal_operation_row(F),
                WrongRef = setelement(5, OperationRef, digest(254)),
                reply_operation_source(F, {ok, Row#{ref => WrongRef}}),
                assert_operation_error(
                  F, Worker, Monitor, invalid_operation_claim)
            end)
      end).

operation_source_index_corruption_is_reported_not_parked_test() ->
    with_operation_fixture(
      fun(F) ->
          with_operation_worker(F,
            fun(Worker, Monitor) ->
                reply_operation_source(F, {error, outcome_index_corrupt}),
                assert_operation_error(F, Worker, Monitor, outcome_index_corrupt)
            end)
      end).

operation_source_worker_fault_is_reported_not_parked_test() ->
    with_operation_fixture(fun(F = #{operation_ref := Ref}) ->
        with_operation_worker(F, fun(Worker, Monitor) ->
            From = expect_operation_stub_call(source, {outcome, Ref}),
            ?assertMatch(#{wave := #{workers := 1}},
                         quod_dtx_coordinator:test_state(Worker)),
            exit(element(1, From), operation_source_fault_control),
            assert_operation_error(F, Worker, Monitor,
              {operation_worker_crash, operation_source_fault_control})
        end)
    end).

included_application_uses_remote_committee_when_local_cannot_vote_test_() ->
    [{atom_to_list(Reason),
      fun() ->
          with_operation_fixture(
            fun(F) ->
                with_operation_follow_owner(
                  fun(_ForeignOwner) ->
                      with_operation_worker(F,
                        fun(Worker, Monitor) ->
                            start_included_application(F, Worker),
                            certify_operation_remote_result(F, Worker, Reason),
                            finish_operation_receipt(F, committed),
                            assert_operation_result(F, Worker, Monitor, committed)
                        end)
                  end)
            end)
      end} || Reason <- [observer, no_local_identity]].

included_application_keeps_one_follow_and_ignores_nonprogress_notices_test() ->
    with_operation_fixture(
      fun(F = #{target := Target, target_ref := TargetRef}) ->
          with_operation_follow_owner(
            fun(_ForeignOwner) ->
                with_operation_worker(F,
                  fun(Worker, Monitor) ->
                      Pending = #{status => pending, ref => TargetRef},
                      start_included_application(F, Worker),
                      certify_operation_result(F, Worker, Pending),
                      FollowRef = attach_operation_follow(F, Worker),
                      %% add_follow emits building immediately. A second
                      %% acknowledged status is a mailbox barrier: if the
                      %% first status erroneously re-drives work, the worker
                      %% blocks on our unanswered source call and cannot ack
                      %% the second one. No time-based quiet-period assertion.
                      operation_status_notices(F, Worker, FollowRef),
                      dormant_await_idle(Worker),
                      send_operation_follow_notice(
                        Target, Worker, FollowRef,
                        {certified, 3, digest(250)}),
                      %% Only this target changed. A fresh source read is
                      %% now an unexpected call, not a fixture requirement.
                      certify_operation_result(F, Worker, Pending),
                      %% Still unavailable after real progress: retain this
                      %% exact follow, without unfollow/follow/refresh churn.
                      operation_status_notices(F, Worker, FollowRef),
                      %% A notice ack is not a barrier for a certification
                      %% wave's result (it arrives through another sender).
                      dormant_await_idle(Worker),
                      wake_operation_follow(F, Worker, FollowRef),
                      certify_operation_result(F, Worker, committed),
                      finish_operation_receipt(F, committed),
                      _ = expect_operation_stub_call(foreign, {unfollow, FollowRef}),
                      assert_operation_result(F, Worker, Monitor, committed)
                  end)
            end)
      end).

included_application_refuses_wrong_result_and_follows_owner_replacement_test() ->
    with_operation_fixture(
      fun(F = #{target := Target, target_ref := TargetRef}) ->
          with_operation_follow_owner(
            fun(ForeignOwner) ->
                with_operation_worker(F,
                  fun(Worker, Monitor) ->
                      start_included_application(F, Worker),
                      WrongRef = setelement(4, TargetRef, digest(254)),
                      certify_operation_result(
                        F, Worker, #{status => committed, height => 3,
                                     ref => WrongRef}),
                      %% The existing quorum collector refuses the mismatched
                      %% ref. It grants no result; the worker waits on the
                      %% existing follower rather than re-applying the claim.
                      OldFollowRef = attach_operation_follow(F, Worker),
                      assert_no_target_result(Worker),
                      ForeignMonitor = quod_reg:monitor_name(
                                         {foreign_log, node}, follow),
                      exit(ForeignOwner, kill),
                      receive {gproc, unreg, ForeignMonitor, _} -> ok
                      after 1000 -> error(foreign_owner_not_unregistered)
                      end,
                      quod_reg:demonitor_name(
                        {foreign_log, node}, ForeignMonitor),
                      with_operation_follow_owner(
                        fun(_Replacement) ->
                            FollowRef = attach_operation_follow(F, Worker),
                            %% Replacement invalidates the old follow even if
                            %% its final ready notice arrives late. It gets no
                            %% ack on the replacement owner's registration.
                            Worker ! {quod_foreign_follow, OldFollowRef,
                                      make_ref(), Target,
                                      operation_follow_progress()},
                            operation_status_notices(F, Worker, FollowRef),
                            %% The correct follow with the wrong anchored
                            %% identity is also status-only, never progress.
                            WrongTarget = {element(1, Target), digest(251)},
                            Worker ! {quod_foreign_follow, FollowRef, make_ref(),
                                      WrongTarget, operation_follow_progress()},
                            _ = quod_dtx_coordinator:test_state(Worker),
                            operation_status_notices(F, Worker, FollowRef),
                            wake_operation_follow(F, Worker, FollowRef),
                            certify_operation_result(F, Worker, committed),
                            finish_operation_receipt(F, committed),
                            _ = expect_operation_stub_call(foreign, {unfollow, FollowRef}),
                            assert_operation_result(
                              F, Worker, Monitor, committed)
                        end)
                  end)
            end)
      end).

operation_worker_exits_during_held_source_read_test() ->
    with_operation_fixture(
      fun(#{source_ns := Ns, operation_ref := OperationRef}) ->
          Test = self(),
          Owner = spawn(
                    fun() ->
                        {ok, Worker, _Monitor} =
                            quod_dtx_coordinator:start_operation_monitor(
                              self(), Ns, OperationRef, #{}),
                        operation_ready(Worker, self(), OperationRef),
                        Test ! {operation_test_worker, self(), Worker},
                        receive stop -> ok end
                    end),
          Worker = receive {operation_test_worker, Owner, Pid} -> Pid
                   after 1000 -> error(operation_worker_not_started)
                   end,
          Monitor = monitor(process, Worker),
          try
              From = expect_operation_stub_call(source, {outcome, OperationRef}),
              IoMonitor = monitor(process, element(1, From)),
              exit(Owner, kill),
              receive {'DOWN', Monitor, process, Worker, _} -> ok
              after 1000 -> error(operation_worker_survived_owner)
              end,
              receive {'DOWN', IoMonitor, process, _, _} -> ok
              after 1000 -> error(operation_source_io_survived_owner) end,
              assert_no_operation_stub_calls()
          after
              exit(Owner, kill),
              exit(Worker, kill),
              erlang:demonitor(Monitor, [flush])
          end
      end).

cohosted_submit_falls_through_only_on_retryable_local_results_test() ->
    with_fixture(
      fun(F) ->
          Vote = maps:get(vote, F),
          {ok, RecordBlob} = quod_atomic:encode_record(Vote),
          Request = {submit, <<200:128>>, RecordBlob},
          RequestId = element(2, Request),
          Digest = quod_atomic:record_digest(Vote),
          {_Target, _Control, Ref} = evidence(maps:get(origin, F), Vote, 2, F),
          ?assertEqual(
             uncertain,
             quod_dtx_coordinator:test_local_submit_result(
               Request,
               {ok, {error, RequestId, not_ready},
                {reply_source, local, []}})),
          ?assertEqual(
             uncertain,
             quod_dtx_coordinator:test_local_submit_result(
               Request,
               {ok, {error, RequestId, busy},
                {reply_source, local, []}})),
          ?assertEqual(
             uncertain,
             quod_dtx_coordinator:test_local_submit_result(
               Request, {error, unavailable})),
          ?assertEqual(
             terminal,
             quod_dtx_coordinator:test_local_submit_result(
               Request,
               {ok, {accepted, RequestId, Digest, Ref},
                {reply_source, local, []}})),
          ?assertEqual(
             terminal,
             quod_dtx_coordinator:test_local_submit_result(
               Request,
               {ok, {error, RequestId, invalid_request},
                {reply_source, local, []}})),
          %% A Byzantine first route cannot turn its fabricated rejection or
          %% malformed response into a group-terminal result; traversal reaches
          %% the next pinned validator. Only correlated acceptance/refusal ends
          %% remote iteration.
          ?assertEqual(
             next,
             quod_dtx_coordinator:test_remote_submit_result(
               Request, {error, RequestId, invalid_request})),
          ?assertEqual(
             next,
             quod_dtx_coordinator:test_remote_submit_result(
               Request, {accepted, <<204:128>>, Digest, Ref})),
          ?assertEqual(
             next,
             quod_dtx_coordinator:test_remote_submit_result(
               Request, malformed)),
          ?assertEqual(
             terminal,
             quod_dtx_coordinator:test_remote_submit_result(
               Request, {accepted, RequestId, Digest, Ref}))
      end).

remote_endpoint_fallback_preserves_uncertainty_and_correlation_test() ->
    with_fixture(
      fun(F) ->
          Vote = maps:get(vote, F),
          {ok, RecordBlob} = quod_atomic:encode_record(Vote),
          Request = {submit, <<205:128>>, RecordBlob},
          RequestId = element(2, Request),
          Digest = quod_atomic:record_digest(Vote),
          {_Target, _Control, Ref} = evidence(
                                      maps:get(origin, F), Vote, 2, F),
          Peer = digest(214),
          Live = {"127.0.0.1", 3214},
          Historical = {"127.0.0.1", 3215},

          TimeoutThenClosed =
              fun(Endpoint, CandidateRequest, _Timeout) ->
                  self() ! {fallback_attempt, Endpoint, CandidateRequest},
                  case Endpoint of
                      Live -> {error, timeout};
                      Historical -> {error, closed}
                  end
              end,
          ?assertEqual(
             {error, timeout},
             quod_dtx_coordinator:test_endpoint_request_candidates(
               [Live, Historical], Peer, Request, 1000,
               TimeoutThenClosed)),
          assert_fallback_attempts(Live, Historical, Request),

          LiveBusy =
              fun(Endpoint, CandidateRequest, _Timeout) ->
                  self() ! {fallback_attempt, Endpoint, CandidateRequest},
                  case Endpoint of
                      Live -> {ok, {error, RequestId, busy}, []};
                      Historical -> {error, closed}
                  end
              end,
          ?assertEqual(
             {ok, {error, RequestId, busy},
              {reply_source, remote, Peer, []}},
             quod_dtx_coordinator:test_endpoint_request_candidates(
               [Live, Historical], Peer, Request, 1000, LiveBusy)),
          receive {fallback_attempt, Live, Request} -> ok
          after 1000 -> error(missing_live_peer_reply) end,
          receive {fallback_attempt, Historical, _} -> error(redialed_live_peer_reply)
          after 0 -> ok end,

          AcceptedFallback =
              fun(Endpoint, CandidateRequest, _Timeout) ->
                  self() ! {fallback_attempt, Endpoint, CandidateRequest},
                  case Endpoint of
                      Live -> {error, closed};
                      Historical ->
                          {ok, {accepted, RequestId, Digest, Ref}, []}
                  end
              end,
          ?assertEqual(
             {ok, {accepted, RequestId, Digest, Ref},
              {reply_source, remote, Peer, []}},
             quod_dtx_coordinator:test_endpoint_request_candidates(
               [Live, Historical], Peer, Request, 1000,
               AcceptedFallback)),
          assert_fallback_attempts(Live, Historical, Request),

          WrongCorrelation =
              fun(Endpoint, CandidateRequest, _Timeout) ->
                  self() ! {fallback_attempt, Endpoint, CandidateRequest},
                  Id = case Endpoint of Live -> <<99:128>>; Historical -> RequestId end,
                  {ok, {accepted, Id, Digest, Ref}, []}
              end,
          ?assertEqual(
             {ok, {accepted, RequestId, Digest, Ref}, {reply_source, remote, Peer, []}},
             quod_dtx_coordinator:test_endpoint_request_candidates(
               [Live, Historical], Peer, Request, 1000, WrongCorrelation)),
          assert_fallback_attempts(Live, Historical, Request),

          InvalidRequest =
              fun(Endpoint, CandidateRequest, _Timeout) ->
                  self() ! {fallback_attempt, Endpoint, CandidateRequest},
                  {ok, {error, RequestId, invalid_request}, []}
              end,
          ?assertEqual(
             {ok, {error, RequestId, invalid_request},
              {reply_source, remote, Peer, []}},
             quod_dtx_coordinator:test_endpoint_request_candidates(
               [Live, Historical], Peer, Request, 1000, InvalidRequest)),
          receive
              {fallback_attempt, Live, Request} -> ok
          after 1000 -> error(missing_authoritative_rejection)
          end,
          receive
              {fallback_attempt, Historical, _} ->
                  error(redialed_authoritative_rejection)
          after 0 -> ok
          end
      end).

assert_fallback_attempts(First, Second, Request) ->
    receive {fallback_attempt, First, Request} -> ok
    after 1000 -> error({missing_fallback_attempt, First})
    end,
    receive {fallback_attempt, Second, Request} -> ok
    after 1000 -> error({missing_fallback_attempt, Second})
    end,
    receive {fallback_attempt, _, _} -> error(extra_fallback_attempt)
    after 0 -> ok
    end.

submit_fanout_starts_every_source_and_cleans_losers_test() ->
    with_fixture(
      fun(F) ->
          Vote = maps:get(vote, F),
          {ok, RecordBlob} = quod_atomic:encode_record(Vote),
          Digest = quod_atomic:record_digest(Vote),
          {_Target, _Control, Ref} = evidence(maps:get(origin, F), Vote, 2, F),
          Sources = [{remote, digest(211), [{"127.0.0.1", 3211}]},
                     {remote, digest(212), [{"127.0.0.1", 3212}]},
                     {remote, digest(213), [{"127.0.0.1", 3213}]}],
          Parent = self(),
          RequestFun =
              fun(Source, Request) ->
                  Parent ! {fanout_started, Source, self(), Request},
                  receive {fanout_result, Result} -> Result end
              end,
          Caller = spawn(
                     fun() ->
                         Parent !
                           {fanout_reply, self(),
                            quod_dtx_coordinator:
                              test_submit_endpoint_requests(
                                Sources, RecordBlob, 2000, RequestFun)}
                     end),
          Started = receive_fanout_started(length(Sources), #{}),
          ?assertEqual(lists:sort(Sources), lists:sort(maps:keys(Started))),
          Ids = [Id || {_Pid, {submit, Id, B}} <- maps:values(Started), B =:= RecordBlob],
          ?assertEqual(length(Sources), length(lists:usort(Ids))),
          %% Actual owner processing while EVERY endpoint is held. A send
          %% trace or mailbox snapshot alone cannot satisfy this barrier.
          ?assertMatch(#{execution_ready := true,
                         wave := #{running := true, stage := phase_command}},
                       quod_dtx_coordinator:test_state(Caller)),
          Monitors = maps:map(
                       fun(_Source, {Pid, _Request}) ->
                           erlang:monitor(process, Pid)
                       end, Started),
          Winner = hd(Sources),
          {WinnerPid, {submit, RequestId, RecordBlob}} = maps:get(Winner, Started),
          WinnerPid !
              {fanout_result,
               {ok, {accepted, RequestId, Digest, Ref}, Winner}},
          receive
              {fanout_reply, Caller,
               {reply, {accepted, RequestId, Digest, Ref}, Winner}} -> ok
          after 1000 ->
              error(missing_fanout_terminal_reply)
          end,
          lists:foreach(
            fun({Source, {Pid, _}}) when Source =:= Winner ->
                    MRef = maps:get(Source, Monitors),
                    receive {'DOWN', MRef, process, Pid, normal} -> ok
                    after 1000 -> error({fanout_winner_not_reaped, Pid})
                    end;
               ({Source, {Pid, _}}) ->
                    MRef = maps:get(Source, Monitors),
                    receive {'DOWN', MRef, process, Pid, killed} -> ok
                    after 1000 -> error({fanout_worker_not_cleaned, Pid})
                    end
            end, maps:to_list(Started))
      end).

prepared_endpoint_waits_for_readiness_without_renewing_deadline_test() ->
    with_fixture(fun(F) ->
        {ok, Blob} = quod_atomic:encode_record(maps:get(vote, F)),
        Source = {remote, digest(218), [{"127.0.0.1", 3218}]},
        Parent = self(), Deadline = quod_time:mono_ms() + 3000,
        Target = {<<"quod:test">>, <<0:256>>},
        {Caller, Monitor} = spawn_monitor(fun() ->
            Result = quod_dtx_coordinator:test_submit_endpoint_requests(
                [Source], Blob,
                #{deadline => Deadline, owner => Parent, ready => false},
                fun(Source0, {submit, _, Blob0}) when Blob0 =:= Blob ->
                    Parent ! {prepared_dispatched, self(), Source0},
                    receive finish_prepared -> {error, econnrefused} end
                end),
            Parent ! {prepared_result, self(), Result}
        end),
        try
            %% A real owner turn must show retained preparation and zero
            %% workers, not merely the absence of a send notification.
            Paused = quod_dtx_coordinator:test_state(Caller),
            ?assertMatch(#{execution_ready := false,
              wave := #{workers := 0, results := #{1 := {prepared_submit, _}},
                        meta := #{request_deadline := Deadline}}}, Paused),
            Caller ! {local_dtx_progress, Caller, Target, 1, true},
            ?assertEqual(Paused, quod_dtx_coordinator:test_state(Caller)),
            Caller ! {local_dtx_progress, Parent, Target, 1, true},
            Worker = receive {prepared_dispatched, Pid, Source} -> Pid
                     after 1000 -> error(prepared_endpoint_not_released) end,
            ?assertMatch(#{execution_ready := true,
              wave := #{workers := 1,
                        meta := #{request_deadline := Deadline}}},
                         quod_dtx_coordinator:test_state(Caller)),
            WorkerMonitor = erlang:monitor(process, Worker),
            Worker ! finish_prepared,
            receive {prepared_result, Caller, Result} ->
                ?assertEqual(not_submitted, Result)
            after 1000 -> error(missing_prepared_result) end,
            receive {'DOWN', Monitor, process, Caller, normal} -> ok
            after 1000 -> error(prepared_owner_not_finished) end,
            %% Coordinator completion does not order the worker's exit.
            receive {'DOWN', WorkerMonitor, process, Worker, _} -> ok
            after 1000 -> error(prepared_worker_not_finished) end,
            ?assertNot(is_process_alive(Worker))
        after
            exit(Caller, kill), demonitor(Monitor, [flush])
        end
    end).

operation_source_wave_parks_continuation_with_original_deadline_test() ->
    with_operation_fixture(fun(F = #{operation_ref := Ref}) ->
        with_operation_worker(F, fun(Worker, Monitor) ->
            From = expect_operation_stub_call(source, {outcome, Ref}),
            #{wave := #{stage := operation, items := [local_outcome],
                        meta := #{request_deadline := Deadline}}} =
                quod_dtx_coordinator:test_state(Worker),
            {operation, Ns, Anchor, _, _} = Ref,
            Worker ! {local_dtx_progress, self(), {Ns, Anchor}, 0, false},
            ?assertMatch(#{execution_ready := false, wave := #{running := true}},
                         quod_dtx_coordinator:test_state(Worker)),
            gen_server:reply(From, terminal_operation_row(F)),
            Deferred = operation_await_deferred(Worker, quod_time:mono_ms() + 1000),
            ?assertMatch(#{wave := #{running := false, items := [{claim_evidence, 2}],
                                    meta := #{request_deadline := Deadline}}}, Deferred),
            assert_no_operation_stub_calls(),
            operation_ready(Worker, self(), Ref),
            restore_operation_receipt(F, Worker),
            assert_operation_result(F, Worker, Monitor, committed)
        end)
    end).

operation_await_deferred(Worker, Limit) ->
    case quod_dtx_coordinator:test_state(Worker) of
        #{wave := #{running := false}, progress_pending := false} = S -> S;
        _ ->
            true = quod_time:mono_ms() < Limit,
            operation_await_deferred(Worker, Limit)
    end.

dispatched_endpoint_worker_death_preserves_uncertainty_test() ->
    with_fixture(fun(F) ->
        {ok, Blob} = quod_atomic:encode_record(maps:get(vote, F)),
        Source = {remote, digest(219), [{"127.0.0.1", 3219}]},
        Parent = self(),
        {Caller, Monitor} = spawn_monitor(fun() ->
            Result = quod_dtx_coordinator:test_submit_endpoint_requests(
                [Source], Blob, 1000,
                fun(Source0, {submit, _, Blob0}) when Blob0 =:= Blob ->
                    Parent ! {dispatched, Source0, self()},
                    exit(endpoint_disappeared_after_dispatch)
                end),
            Parent ! {death_result, self(), Result}
        end),
        Worker = receive {dispatched, Source, W} -> W
                 after 1000 -> error(no_real_endpoint_worker) end,
        receive {death_result, Caller, Result} -> ?assertEqual(outcome_unknown, Result)
        after 1000 -> error(no_endpoint_death_result) end,
        receive {'DOWN', Monitor, process, Caller, normal} -> ok
        after 1000 -> error(fanout_owner_did_not_finish) end,
        ?assertNot(is_process_alive(Worker)),
        receive {dispatched, _, _} -> error(resubmitted_uncertain_endpoint)
        after 0 -> ok end
    end).

receive_fanout_started(0, Acc) ->
    Acc;
receive_fanout_started(N, Acc) ->
    receive
        {fanout_started, Source, Pid, Request} ->
            receive_fanout_started(N - 1, Acc#{Source => {Pid, Request}})
    after 1000 ->
        error({missing_fanout_workers, N})
    end.

historical_routes_may_be_a_valid_committee_subset_test() ->
    KeyA = digest(2),
    KeyB = digest(3),
    KeyC = digest(4),
    EndpointA = {"127.0.0.1", 4001},
    EndpointB = {"127.0.0.1", 4002},
    Committee = [KeyA, KeyB],
    ?assert(
       quod_dtx_coordinator:test_valid_validator_routes(
         #{KeyA => EndpointA}, Committee)),
    ?assert(
       quod_dtx_coordinator:test_valid_validator_routes(#{}, Committee)),
    ?assertNot(
       quod_dtx_coordinator:test_valid_validator_routes(
         #{KeyA => EndpointA, KeyC => EndpointB}, Committee)),
    ?assertNot(
       quod_dtx_coordinator:test_valid_validator_routes(
         #{KeyA => bad_endpoint}, Committee)).

phase_evidence_structure_fails_loudly_test() ->
    with_fixture(
      fun(F) ->
          Vote = maps:get(vote, F),
          Target = maps:get(origin, F),
          {Control, Entry, Ref} = certified_control(Target, Vote, 2, F),
          Pub = maps:get(pubkey, maps:get(signer, F)),
          Evidence =
              #{identity => Target, phase => vote, generation => 0,
                control => Control, ref => Ref,
                entry => Entry,
                committee => [Pub], committee_id => digest(211),
                routes => #{}},
          ?assertMatch(
             {ok, Control, 0,
              #{identity := Target, phase := vote, control := Control,
                ref := Ref, generation := 0, entry := Entry,
                committee := [Pub], committee_id := _, routes := #{}},
              Entry},
             quod_dtx_coordinator:test_valid_phase_evidence(
               Target, quod_atomic:group_id(Vote), vote, Ref, Evidence)),
          ?assertError(
             {badkey, routes},
             quod_dtx_coordinator:test_valid_phase_evidence(
               Target, quod_atomic:group_id(Vote), vote, Ref,
               maps:remove(routes, Evidence)))
      end).

phase_evidence_accepts_an_equivalent_quorum_subset_test() ->
    with_fixture(
      fun(F) ->
          Vote = maps:get(vote, F),
          Target = maps:get(origin, F),
          {Control, Entry0, _LocalRef} =
              certified_control(Target, Vote, 2, F),
          {Ns, Anchor} = Target,
          #entry{cert = #cert{block_hash = BlockHash}} =
              quod_ledger:entry_view(Entry0),
          {ok, Block} = quod_ledger:block_from_entry(Entry0),
    Position = {Block#block.era, Block#block.slot},
          Domain = quod_simplex:consensus_domain(Ns, Anchor),
          Validators =
              [begin
                   {Pub, Seed} = quod_identity:generate(),
                   {Pub, #{pubkey => Pub,
                           key => quod_identity:key_term({Pub, Seed})}}
               end || _ <- lists:seq(1, 4)],
          Committee = lists:sort([Pub || {Pub, _} <- Validators]),
          Shares = maps:from_list(
                     [{Pub, quod_simplex:make_share(
                              Domain, commit, Position, BlockHash, Signer)}
                      || {Pub, Signer} <- Validators]),
          [A, B, C, D] = Committee,
          Form = fun(Keys) ->
                         {ok, Cert} = quod_simplex:form_cert(
                                        Domain, commit, Position, BlockHash,
                                        [maps:get(Key, Shares)
                                         || Key <- Keys],
                                        Committee),
                         Cert
                 end,
          RetainedCert = Form([A, B, C]),
          SuppliedCert = Form([B, C, D]),
          Entry = quod_ledger:entry(2, Block, RetainedCert),
          SuppliedEntry = quod_ledger:entry(2, Block, SuppliedCert),
          {ok, Ref} = quod_dtx:certified_entry_ref(
                        Target, SuppliedEntry, Control),
          Evidence =
              #{identity => Target, phase => vote, generation => 0,
                control => Control, ref => Ref, entry => Entry,
                committee => Committee, committee_id => digest(212),
                routes => #{}},
          ?assertNotEqual(RetainedCert, SuppliedCert),
          ?assertMatch(
             {ok, Control, 0, #{ref := Ref, entry := Entry}, Entry},
             quod_dtx_coordinator:test_valid_phase_evidence(
               Target, quod_atomic:group_id(Vote), vote, Ref, Evidence))
      end).

applied_wave_retains_verified_siblings_when_one_target_retries_test() ->
    with_fixture(fun(F) ->
        {Own, Snapshot, [ACommand, BCommand], [ACertificate, BCertificate]} = applied_fixture(F),
        {applied, A, _, _, _, _} = ACommand, {applied, B, _, _, _, _} = BCommand,
        {ok, S1, [A], [BCommand], true} =
            quod_dtx_coordinator:test_install_applied_results(
              Own, [ACommand,BCommand], [{verified,ACertificate},retry], Snapshot),
        ?assertEqual(#{A => ACertificate},maps:get(applied,S1)),
        {ok, S2, [B], [], true} =
            quod_dtx_coordinator:test_install_applied_results(Own, [BCommand], [{verified,BCertificate}], S1),
        ?assertEqual(#{A => ACertificate,B => BCertificate},maps:get(applied,S2))
    end).

applied_wave_rechecks_deadline_at_owner_consumption_test() ->
    with_fixture(fun(F) ->
        {Own, Snapshot, [Command | _], [Certificate | _]} = applied_fixture(F),
        {applied, Target, _, _, _, _} = Command,
        %% Callback input has already crossed the verifier; this proves the
        %% queued-verdict deadline, not cryptographic or consensus admission.
        Parent = self(),
        lists:foreach(fun({Form,Offset,Expected}) ->
            {Pid,Monitor} = spawn_monitor(fun() ->
                Rows = quod_dtx_coordinator:test_consume_applied_wave(
                    Own, Snapshot, Command, Certificate, quod_time:mono_ms() + Offset),
                Parent ! {applied_consumed,self(),Rows}
            end),
            receive {applied_consumed,Pid,Rows} -> ?assertEqual({Form,Expected},{Form,Rows})
            after 2000 -> error(applied_consumer_missing) end,
            receive {'DOWN',Monitor,process,Pid,normal} -> ok
            after 2000 -> error(applied_consumer_failed) end
        end,[{live,1000,#{Target => Certificate}},{expired,-1,#{}}])
    end).

applied_fixture(F) ->
    [Origin,A,B] = maps:get(targets,F), Own = maps:get(own,F),
    Id = quod_atomic:group_id(maps:get(group,F)),
    Commands = [{applied,T,Id,dtx_test_ref(T,7 + N,digest(220 + N)),N + 1,commit}
                 || {T,N} <- [{A,1},{B,2}]],
    %% Compact observations stand for completed verifier callbacks. No whole
    %% foreign plan enters the coordinator's snapshot.
    Evidence = maps:from_list([{{resolve,T},
        #{ref => Ref,generation => Gen,outcome => commit,own_vote => dtx_test_ref(T,2,digest(230))}}
        || {applied,T,_,Ref,Gen,_} <- Commands]),
    ?assertNot(lists:member(Origin,[A,B])),
    Snapshot = (quod_dtx_recovery:empty())#{evidence := Evidence},
    {Own,Snapshot,Commands,[applied_certificate(C,digest(223)) || C <- Commands]}.

worker_is_owned_by_an_exact_monitor_not_a_link_test() ->
    with_fixture(
      fun(F) ->
          Parent = self(),
          {Ns, _Anchor} = maps:get(origin, F),
          Owner = spawn(
                    fun() ->
                        Result = quod_dtx_coordinator:start_monitor(
                                   self(), Ns, maps:get(own, F),
                                   #{request_timeout_ms => 1}),
                        Parent ! {coordinator_started, self(), Result},
                        receive stop -> ok end
                    end),
          Worker = receive
                       {coordinator_started, Owner, {ok, Pid, Monitor}}
                         when is_pid(Pid), is_reference(Monitor) -> Pid
                   after 1000 -> error(coordinator_start_timeout)
                   end,
          WorkerMonitor = erlang:monitor(process, Worker),
          exit(Owner, kill),
          receive
              {'DOWN', WorkerMonitor, process, Worker, normal} -> ok
          after 1000 ->
              error(coordinator_owner_cleanup_timeout)
          end,
          %% An ordinary monitored worker must not be linked back to this test.
          ?assert(is_process_alive(self()))
      end).

coordinator_close_cancels_wave_timer_and_workers_test() ->
    Workers = [spawn(fun blocked_worker/0) || _ <- lists:seq(1, 3)],
    Monitors = [{Pid, erlang:monitor(process, Pid)} || Pid <- Workers],
    Timer = quod_dtx_coordinator:test_close_wave(Workers),
    ?assertEqual(false, erlang:read_timer(Timer)),
    lists:foreach(
      fun({Pid, Monitor}) ->
          receive
              {'DOWN', Monitor, process, Pid, killed} -> ok
          after 1000 -> error({wave_worker_survived_close, Pid})
          end
      end, Monitors),
    receive test_wave_timeout -> error(wave_timer_survived_close)
    after 0 -> ok
    end.

owned_workers_follow_their_immediate_owner_transitively_test() ->
    Test = self(),
    Owner = spawn(
              fun() ->
                  {Outer, _OuterMonitor} =
                      quod_dtx_coordinator:test_spawn_owned_worker(
                        self(),
                        fun() ->
                            {Nested, _NestedMonitor} =
                                quod_dtx_coordinator:
                                  test_spawn_owned_worker(
                                    self(), fun blocked_worker/0),
                            Test ! {owned_worker_tree, self(), Nested},
                            blocked_worker()
                        end),
                  Test ! {owned_outer, self(), Outer},
                  blocked_worker()
              end),
    Outer = receive {owned_outer, Owner, OuterPid} -> OuterPid
            after 1000 -> error(missing_owned_outer)
            end,
    Nested = receive {owned_worker_tree, Outer, NestedPid} -> NestedPid
             after 1000 -> error(missing_owned_nested)
             end,
    OuterMonitor = erlang:monitor(process, Outer),
    NestedMonitor = erlang:monitor(process, Nested),
    exit(Owner, kill),
    receive {'DOWN', OuterMonitor, process, Outer, killed} -> ok
    after 1000 -> error(outer_worker_survived_owner)
    end,
    receive {'DOWN', NestedMonitor, process, Nested, killed} -> ok
    after 1000 -> error(nested_worker_survived_outer)
    end.

only_submit_death_is_uncertain_and_only_timeout_is_retryable_test() ->
    ?assertEqual(
       uncertain,
       quod_dtx_coordinator:test_worker_down_disposition(
         submit, simulated_crash)),
    lists:foreach(
      fun(Stage) ->
          ?assertEqual(
             retry,
             quod_dtx_coordinator:test_worker_down_disposition(
               Stage, timeout)),
          ?assertEqual(
             {fatal, {dtx_worker_crash, Stage, simulated_crash}},
             quod_dtx_coordinator:test_worker_down_disposition(
               Stage, simulated_crash))
      end, [phase, evidence, applied]).

blocked_worker() ->
    receive stop -> ok end.

source_progress_uses_owner_commit_edge_not_foreign_history_test() ->
    Origin = {<<"quod:source-progress">>, digest(221)},
    Remote = {<<"quod:remote-progress">>, digest(222)},
    SameNameWrongAnchor = {element(1, Origin), digest(223)},
    ?assertEqual(
       owner,
       quod_dtx_coordinator:test_progress_source(Origin, Origin)),
    ?assertEqual(
       foreign,
       quod_dtx_coordinator:test_progress_source(Remote, Origin)),
    ?assertEqual(
       foreign,
       quod_dtx_coordinator:test_progress_source(
         SameNameWrongAnchor, Origin)).

source_progress_accepts_only_its_existing_commit_stream_test() ->
    Identity = {<<"quod:source-progress">>, digest(224)},
    ?assert(
       quod_dtx_coordinator:test_local_progress_event(
         {local_dtx_progress, self(), Identity, 7, true}, Identity)),
    ?assertNot(
       quod_dtx_coordinator:test_local_progress_event(
         {local_dtx_progress, self(),
          {<<"quod:other">>, element(2, Identity)}, 7, true}, Identity)),
    ?assertNot(
       quod_dtx_coordinator:test_local_progress_event(
         {local_dtx_progress, self(),
          {element(1, Identity), digest(225)}, 7, true}, Identity)),
    ?assertNot(
       quod_dtx_coordinator:test_local_progress_event(
         {local_dtx_progress, self(), Identity, -1, true}, Identity)),
    ?assertNot(
       quod_dtx_coordinator:test_local_progress_event(
         {local_dtx_progress, self(), Identity, 7, malformed}, Identity)),
    ?assertNot(
       quod_dtx_coordinator:test_local_progress_event(
         malformed, Identity)).

invalid_own_role_allocates_no_worker_test() ->
    ?assertEqual(
       {error, invalid_own_vote},
       quod_dtx_coordinator:start_monitor(
         self(), <<"quod:a">>, malformed, #{})).

dormant_cancel_retires_custody_only_on_explicit_terminal_reply_test() ->
    RequestId = <<230:128>>,
    Request = {cancel_operation_effect, RequestId, {<<"quod:a">>, <<1:256>>}, <<"signed-submission">>},
    ?assertEqual(
       terminal,
       quod_dtx_coordinator:test_dormant_cancel_disposition(
         Request,
         {operation_effect_cancelled, RequestId, cancelled})),
    ?assertEqual(
       terminal,
       quod_dtx_coordinator:test_dormant_cancel_disposition(
         Request,
         {operation_effect_cancelled, RequestId, not_found})),
    ?assertEqual(
       wait,
       quod_dtx_coordinator:test_dormant_cancel_disposition(
         Request,
         {operation_effect_cancelled, <<231:128>>, cancelled})),
    [?assertEqual(
       wait,
       quod_dtx_coordinator:test_dormant_cancel_disposition(
         Request, {error, RequestId, Reason}))
     || Reason <- [busy, not_ready, not_found, invalid_request]],
    ?assertEqual(
       wait,
       quod_dtx_coordinator:test_dormant_cancel_disposition(
         Request, malformed)).

dormant_cancel_signals_one_exact_directory_demand_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    stop_route_recovery_owners(),
    {ok, Directory} = quod_directory:start_link(
                        #{expire_tick_ms => 60000, ttl_ms => 10000}),
    unlink(Directory),
    {ok, Control} = quod_directory_control:start_link(#{}),
    unlink(Control),
    Fixture = quod_ct:signed_effect_operation_submission(),
    {OriginNs, _} = maps:get(origin, Fixture),
    Target = maps:get(target, Fixture),
    try
        {ok, Worker} = quod_dtx_coordinator:start_dormant_operation_monitor(
                         self(), OriginNs, maps:get(submission, Fixture)),
        ok = wait_route_demand(Target, 100),
        ?assertEqual(
           [Target],
           maps:get(route_demands,
                    quod_directory_control:test_control_state())),
        exit(Worker, kill)
    after
        catch gen_server:stop(Control),
        catch gen_server:stop(Directory),
        stop_route_recovery_owners()
    end.

%% Lost endpoint replies and link failures do not synthesize progress from a
%% foreign-history baseline. Custody remains parked until this exact target's
%% directory owner publishes a real route edge; that wake rebuilds only the
%% outer correlation id around the unchanged signed submission.
dormant_cancel_retries_exact_submission_only_on_target_route_edge_test() ->
    with_dormant_wave_fixture(fun(F, Owner, Worker) ->
        Target = maps:get(target, F),
        {From1, Request1 = {cancel_operation_effect, Id1, Target, Bytes}} = dormant_endpoint_call(),
        %% The actual endpoint call is held. The coordinator must remain
        %% responsive, not merely emit a send trace before blocking.
        ?assertMatch(#{wave := #{running := true, stage := dormant}},
                     quod_dtx_coordinator:test_state(Worker)),
        gen_statem:reply(From1, {ok, {error, Id1, not_ready}, []}),
        dormant_await_idle(Worker),
        Worker ! {quod_foreign_follow, make_ref(), make_ref(), Target, {building, 0, 0}},
        Worker ! {directory_route_available, {<<"other-target">>, <<233:256>>}},
        ?assertMatch(#{wave := none, progress_pending := false},
                     quod_dtx_coordinator:test_state(Worker)),
        assert_no_operation_stub_calls(),
        Worker ! {directory_route_available, Target},
        {From2, Request2 = {cancel_operation_effect, Id2, Target, Bytes}} = dormant_endpoint_call(),
        ?assertNotEqual(Id1, Id2),
        {ok, Bytes} = quod_transaction:encode_operation_submission(maps:get(submission, F)),
        ?assertEqual(terminal, quod_dtx_coordinator:test_dormant_cancel_disposition(
           Request2, {operation_effect_cancelled, Id2, cancelled})),
        ?assertEqual(wait, quod_dtx_coordinator:test_dormant_cancel_disposition(
           Request1, {operation_effect_cancelled, Id2, cancelled})),
        %% Real owner death is observed while the second endpoint remains
        %% held. Killing the I/O worker does not invent an acknowledgement.
        Monitor = monitor(process, Worker),
        IoMonitor = monitor(process, element(1, From2)),
        exit(Owner, kill),
        receive {'DOWN', Monitor, process, Worker, _} -> ok
        after 1000 -> error(dormant_owner_down_blocked_by_endpoint) end,
        receive {'DOWN', IoMonitor, process, _, _} -> ok
        after 1000 -> error(dormant_io_outlived_owner) end
    end).

dormant_custody_release_preserves_actual_caller_pid_test() ->
    with_dormant_wave_fixture(fun(_F, Owner, Worker) ->
        {From, {cancel_operation_effect, Id, _Target, _Bytes}} = dormant_endpoint_call(),
        gen_statem:reply(From, {ok, {operation_effect_cancelled, Id, cancelled}, []}),
        receive
            {dormant_owner_call, Owner, NativeFrom, {cancel_transaction_custody, _TxId}} ->
                ?assertEqual(Worker, element(1, NativeFrom)),
                ?assertMatch(#{wave := #{running := true, stage := dormant}},
                             quod_dtx_coordinator:test_state(Worker)),
                Monitor = monitor(process, Worker),
                gen_statem:reply(NativeFrom, ok),
                receive {'DOWN', Monitor, process, Worker, normal} -> ok
                after 1000 -> error(dormant_native_reply_not_consumed) end
        after 1000 -> error(missing_native_custody_release) end
    end).

%% Signed submission and real production worker/endpoint client; the target
%% is a protocol fixture, not a consensus-admitted namespace. The separate
%% Simplex exact-owner test exercises the actual custody authorization.
with_dormant_wave_fixture(Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    F = quod_ct:signed_effect_operation_submission(),
    {TargetNs, Anchor} = maps:get(target, F),
    Saved = application:get_env(quod, node_pubkey),
    application:set_env(quod, node_pubkey, maps:get(pubkey, maps:get(target_identity, F))),
    Table = ets:new(binary_to_atom(<<"quod_simplex_genesis_", TargetNs/binary>>, utf8),
                    [named_table, public, set]),
    ets:insert(Table, {anchor, Anchor}),
    Stub = start_operation_stub(dormant, {quod_simplex, TargetNs}),
    Test = self(),
    Owner = spawn(fun() ->
        {Ns, _} = maps:get(origin, F),
        true = quod_reg:reg({quod_simplex, Ns}),
        {ok, Worker} = quod_dtx_coordinator:start_dormant_operation_monitor(
                         self(), Ns, maps:get(submission, F)),
        Test ! {dormant_worker, self(), Worker},
        dormant_source_stub(Test)
    end),
    Worker = receive {dormant_worker, Owner, Pid} -> Pid
             after 1000 -> error(dormant_worker_missing) end,
    try Fun(F, Owner, Worker)
    after
        exit(Worker, kill), exit(Owner, kill), stop_operation_stub(Stub), ets:delete(Table),
        case Saved of
            {ok, V} -> application:set_env(quod, node_pubkey, V);
            undefined -> application:unset_env(quod, node_pubkey)
        end
    end.

dormant_source_stub(Test) ->
    receive
        {'$gen_call', From, Request} ->
            Test ! {dormant_owner_call, self(), From, Request},
            dormant_source_stub(Test)
    end.

dormant_endpoint_call() ->
    receive
        {operation_stub_call, dormant, From, {dtx_endpoint_local, Request, [], _Timeout, _Trace}} ->
            {From, Request}
    after 1000 -> error(dormant_endpoint_not_called) end.

dormant_await_idle(Worker) ->
    dormant_await_idle(Worker, quod_time:mono_ms() + 1000).
dormant_await_idle(Worker, Deadline) ->
    case quod_dtx_coordinator:test_state(Worker) of
        #{wave := none, progress_pending := false} -> ok;
        _ ->
            true = quod_time:mono_ms() < Deadline,
            dormant_await_idle(Worker, Deadline)
    end.

%% ------------------------------------------------------------------
%% Operation recovery owner-interface fixtures
%% ------------------------------------------------------------------

with_operation_fixture(Fun) -> with_operation_fixture(1, Fun).

with_operation_fixture(N, Fun) -> with_operation_fixture(N, applied, Fun).

with_operation_fixture(N, Result, Fun) ->
    quod_operation_fixture:with(N, [], Result, fun(F0 = #{source_ns := Ns, targets := Targets}) ->
        Tables = [begin
            Table = ets:new(binary_to_atom(<<"quod_simplex_genesis_", TargetNs/binary>>, utf8),
                            [named_table, protected, set]),
            true = ets:insert(Table, {anchor, Anchor}), Table
        end || {TargetNs, Anchor} <- Targets],
        Stubs = [start_operation_stub(source, {quod_prolog, Ns}),
                 start_operation_stub(source_consensus, {quod_simplex, Ns}) |
                 [start_operation_stub(target, {quod_simplex, TargetNs}) || {TargetNs, _} <- Targets]],
        try
            Data = maps:map(fun(_, D = #{store := Store, projection := P, entry := E}) ->
                D#{target_view => quod_operation_fixture:view(Store, P, E)}
            end, maps:get(target_data, F0)),
            View = quod_operation_fixture:view(maps:get(source_store, F0),
              maps:get(source_projection, F0), maps:get(source_entry, F0)),
            F = F0#{target_data := Data, source_view => View},
            Fun(maps:merge(F, maps:get(hd(Targets), Data)))
        after
            [stop_operation_stub(Pid) || Pid <- Stubs],
            [true = ets:delete(Table) || Table <- Tables]
        end
    end).

start_operation_stub(Role, Key) ->
    Test = self(),
    Pid = spawn(
            fun() ->
                true = quod_reg:reg(Key),
                Test ! {operation_stub_started, self()},
                operation_stub_loop(Test, Role)
            end),
    receive {operation_stub_started, Pid} -> Pid
    after 1000 ->
        exit(Pid, kill),
        error({operation_stub_not_started, Role})
    end.

operation_stub_loop(Test, Role) ->
    receive
        {'$gen_call', From, Request} ->
            Test ! {operation_stub_call, Role, From, Request},
            operation_stub_loop(Test, Role);
        {'$gen_cast', Request} ->
            Test ! {operation_stub_cast, Role, Request},
            operation_stub_loop(Test, Role);
        stop -> ok;
        Message ->
            Test ! {unexpected_operation_stub_message, Role, Message},
            operation_stub_loop(Test, Role)
    end.

stop_operation_stub(Pid) ->
    Monitor = monitor(process, Pid),
    Pid ! stop,
    receive {'DOWN', Monitor, process, Pid, _} -> ok
    after 1000 ->
        exit(Pid, kill),
        erlang:demonitor(Monitor, [flush])
    end.

with_operation_worker(F, Fun) ->
    with_operation_owner(F, fun(Worker, Monitor, _OwnerState) -> Fun(Worker, Monitor) end).

%% The real Simplex transition owns the attempt span. These are owner-interface
%% protocol fixtures, not founded consensus nodes. Cleanup uses the same SDK
%% end-after-take guarantee as other direct-callback fixtures.
with_operation_owner(#{source_ns := Ns, operation_ref := OperationRef}, Fun) ->
    Base = quod_simplex:test_state(#{ns => Ns, genesis_hash => element(3, OperationRef),
                                     prolog_ready => false}),
    State = quod_simplex:test_start_operation_recovery(OperationRef, quod_trace:context(), Base),
    #{OperationRef := #{pid := Worker, monitor := Monitor}} = quod_simplex:test_operation_recoveries(State),
    operation_ready(Worker, self(), OperationRef),
    try Fun(Worker, Monitor, State)
    after
        _ = quod_simplex:terminate(fixture_cleanup, running, State),
        exit(Worker, kill),
        erlang:demonitor(Monitor, [flush])
    end.

operation_ready(Worker, Owner, {operation, Ns, Anchor, _, _}) ->
    Worker ! {local_dtx_progress, Owner, {Ns, Anchor}, 0, true}.

operation_resume(Worker, Op = {operation, Ns, Anchor, _, _}) ->
    Worker ! {local_dtx_progress, self(), {Ns, Anchor}, 0, false},
    operation_ready(Worker, self(), Op).

with_operation_follow_owner(Fun) ->
    ?assertEqual(undefined, quod_reg:where({foreign_log, node})),
    Pid = start_operation_stub(foreign, {foreign_log, node}),
    try Fun(Pid)
    after stop_operation_stub(Pid)
    end.

attach_operation_follow(#{target := Target}, Worker) ->
    From = expect_operation_stub_call(foreign, {follow, Target, progress}),
    FollowRef = make_ref(),
    gen_server:reply(From, {ok, FollowRef}),
    %% Follow admission itself schedules acquisition. The common asynchronous
    %% owner loop consumes the real reply; no redundant refresh is required.
    _ = Worker,
    FollowRef.

wake_operation_follow(#{target := Target}, Worker, FollowRef) ->
    send_operation_follow_notice(
      Target, Worker, FollowRef, operation_follow_progress()).

operation_follow_progress() ->
    {certified, 3, digest(250)}.

operation_status_notices(#{target := Target}, Worker, FollowRef) ->
    send_operation_follow_notice(Target, Worker, FollowRef, {building, 3}),
    send_operation_follow_notice(
      Target, Worker, FollowRef, {unreachable, unavailable, 3}),
    assert_no_target_result(Worker),
    assert_no_operation_stub_calls().

send_operation_follow_notice(Target, Worker, FollowRef, Notice) ->
    NoticeRef = make_ref(),
    Worker ! {quod_foreign_follow, FollowRef, NoticeRef, Target, Notice},
    receive
        {operation_stub_cast, foreign, {ack, FollowRef, NoticeRef, Worker}} -> ok
    after 1000 -> error(missing_foreign_follow_ack)
    end.

assert_no_target_result(Worker) ->
    receive
        {dtx_coordinator, Worker, _, {target_result, _, _}} ->
            error(unverified_operation_result)
    after 0 -> ok
    end.

terminal_operation_row(#{operation_ref := OperationRef,
                         request_digest := Digest, target_refs := Refs,
                         completion := #transaction{role = {remote_complete, _, _, Included}}}) ->
    {ok, #{status => claimed, operation_state => terminal,
           ref => OperationRef, request_digest => Digest,
           outcome_ref => {applications, Refs},
           included => Included,
           height => 2, receipt_height => 3}}.

restore_operation_receipt(F, Worker) ->
    assert_terminal_operation_binding(F, Worker),
    reply_operation_claim(F),
    %% Claim and receipt each read the source's immutable history view. No
    %% target call is necessary: AM3 is already in the committed receipt.
    reply_operation_claim(F).

unresolved_operation_row(F) ->
    {ok, Row} = terminal_operation_row(F),
    {ok, Row#{operation_state := unresolved, receipt_height := none, included := []}}.

start_included_application(F, Worker) ->
    reply_operation_source(F, unresolved_operation_row(F)),
    assert_operation_binding(F, Worker, unresolved),
    reply_operation_claim(F),
    {From, Request} = expect_operation_application(F),
    reply_operation_application(F, From, Request).

finish_operation_receipt(F, Result) ->
    From = expect_operation_receipt(F, Result),
    gen_server:reply(From, {ok, [], 4, digest(252)}).

reply_operation_source(#{operation_ref := OperationRef}, Reply) ->
    From = expect_operation_stub_call(source, {outcome, OperationRef}),
    gen_server:reply(From, Reply).

expect_operation_stub_call(Role, Request) ->
    receive
        {operation_stub_call, Role, From, Request} -> From;
        {operation_stub_call, OtherRole, _From, OtherRequest} ->
            error({unexpected_operation_call, OtherRole, OtherRequest});
        {unexpected_operation_stub_message, OtherRole, Message} ->
            error({unexpected_operation_message, OtherRole, Message})
    after 1000 ->
        error({missing_operation_call, Role, Request})
    end.

certify_operation_result(F = #{target_ref := TargetRef}, Worker, committed) ->
    certify_operation_result(
      F, Worker, #{status => committed, height => 2, ref => TargetRef});
certify_operation_result(F = #{target_ref := TargetRef}, Worker,
                         {rejected, Reason}) ->
    certify_operation_result(
      F, Worker, #{status => rejected, reason => Reason,
                   height => 2, ref => TargetRef});
certify_operation_result(F, _Worker, Outcome) ->
    {From, Request, Timeout} = operation_vote_request(F, local),
    ?assert(Timeout > 0),
    reply_operation_vote(F, From, Request, Outcome).

operation_vote_request(F, Location) ->
    receive
        {operation_stub_call, Role, From, {history_view, Identity, Requirement, Deadline}}
          when Role =:= source_consensus; Role =:= target ->
            {Identity, Requirement} = case Role of
                source_consensus -> {maps:get(source_ns, F), any};
                target -> {maps:get(target, F), {committed, 2}}
            end,
            ?assert(Deadline > quod_time:mono_ms()),
            ViewKey = case Role of source_consensus -> source_view; target -> target_view end,
            gen_server:reply(From, {ok, maps:get(ViewKey, F)}),
            operation_vote_request(F, Location);
        {operation_stub_call, target, From,
         {dtx_endpoint_local, {operation_applied, _, _} = Request, [], Timeout, _TraceCtx}}
          when Location =:= local ->
            {From, Request, Timeout};
        {operation_stub_call, source_consensus, From,
         {dtx_endpoint_request, Ns, Key, {"127.0.0.1", 34249},
          {operation_applied, _, _} = Request, [], Timeout, _TraceCtx}}
          when Location =:= remote ->
            ?assertEqual(element(1, maps:get(target, F)), Ns),
            ?assertEqual(maps:get(pubkey, maps:get(node_identity, F)), Key),
            {From, Request, Timeout};
        {operation_stub_call, Role, _From, Request} ->
            error({unexpected_operation_call, Role, Request})
    after 1000 -> error(missing_exact_application_vote)
    end.

reply_operation_vote(F, From, {operation_applied, Id, Ref}, Outcome) ->
    ?assertEqual(maps:get(certified_target_ref, F), Ref),
    Evidence = maps:get(evidence, F),
    case quod_operation:applied_result(Ref, Evidence,
        #{applied_floor => 2, outcome => Outcome}) of
        {ok, Result} ->
            {ok, Statement} = quod_applied_certificate:operation_statement(
              maps:get(network, F), Evidence, Result),
            {ok, {Key, Signature}} = quod_applied_certificate:sign_operation_vote(
              Statement, maps:get(node_identity, F)),
            gen_server:reply(From, {ok, {operation_applied, Id, Ref, Statement, Key, Signature}, []});
        _ -> gen_server:reply(From, {ok, {error, Id, not_ready}, []})
    end.

certify_operation_remote_result(F, _Worker, LocalRole) ->
    %% Historical membership, not current local voting readiness, selects
    %% result signers. The local owner still supplies exact immutable bytes.
    case LocalRole of
        observer -> application:set_env(quod, node_pubkey, digest(249));
        no_local_identity -> application:unset_env(quod, node_pubkey)
    end,
    {From, Request, Timeout} = operation_vote_request(F, remote),
    ?assert(Timeout > 0),
    reply_operation_vote(F, From, Request,
      #{status => committed, height => 2, ref => maps:get(target_ref, F)}).

assert_terminal_operation_binding(F, Worker) ->
    assert_operation_binding(F, Worker, terminal).

assert_operation_binding(
  #{operation_ref := OperationRef, request_digest := Digest,
    target_ref := TargetRef}, Worker, State) ->
    receive
        {dtx_coordinator, Worker, OperationRef,
         {claim_state, State, 2, Digest, [TargetRef]}} -> ok
    after 1000 -> error({missing_operation_binding, State})
    end.

assert_operation_result(#{operation_ref := OperationRef,
                          target_ref := TargetRef}, Worker, Monitor, Result) ->
    receive
        {dtx_coordinator, Worker, OperationRef,
         {target_result, Result, TargetRef}} -> ok
    after 1000 -> error(missing_verified_operation_result)
    end,
    receive
        {dtx_coordinator, Worker, OperationRef, {done, OperationRef}} -> ok
    after 1000 -> error(missing_operation_completion)
    end,
    receive {'DOWN', Monitor, process, Worker, normal} -> ok
    after 1000 -> error(operation_worker_did_not_finish)
    end,
    assert_no_operation_stub_calls().

assert_operation_error(#{operation_ref := OperationRef}, Worker, Monitor,
                       Reason) ->
    receive
        {dtx_coordinator, Worker, OperationRef, {error, Reason}} -> ok
    after 1000 -> error({missing_operation_error, Reason})
    end,
    receive {'DOWN', Monitor, process, Worker, normal} -> ok
    after 1000 -> error(operation_worker_did_not_finish)
    end,
    assert_no_operation_stub_calls().

assert_no_operation_stub_calls() ->
    receive
        {operation_stub_call, Role, _From, Request} ->
            error({unexpected_operation_call, Role, Request});
        {operation_stub_cast, Role, Request} ->
            error({unexpected_operation_cast, Role, Request});
        {unexpected_operation_stub_message, Role, Message} ->
            error({unexpected_operation_message, Role, Message})
    after 0 -> ok
    end.

%% ------------------------------------------------------------------
%% Current own-role source fixture; reference evidence below is callback input,
%% not a founded consensus-node witness.
%% ------------------------------------------------------------------

with_fixture(Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    Origin = {<<"quod:coordinator-a">>, digest(11)},
    Targets = [Origin, {<<"quod:coordinator-b">>, digest(12)},
                        {<<"quod:coordinator-c">>, digest(13)}],
    F = quod_ct:signed_plan_fixture(#{target => Origin, atomic => true}, Targets),
    {ok, Group} = quod_atomic:new_group(maps:get(manifest, F), maps:get(auth, F),
                                        maps:get(Origin, maps:get(attestations, F))),
    {ok, Vote} = quod_atomic:new_vote(Group, Origin,
                                     lists:keyfind(Origin, 1, maps:get(bundles, F)), prepared),
    {ok, Material} = quod_atomic:admission_material(Vote),
    Own = #{material => Material, ref => none, resolution => none},
    Fun(F#{targets => Targets, group => Group, vote => Vote, own => Own,
           signer => maps:get(node_identity, F)}).

evidence(Target, Record, Slot,
         Fixture) ->
    {Control, _Entry, Ref} = certified_control(
                              Target, Record, Slot, Fixture),
    {Target, Control, Ref}.

certified_control(Target, Record, Slot,
                  #{signer := Signer, admission := Admission}) ->
    {ok, Material} = quod_atomic:admission_material(Record),
    {ok, Control} = quod_atomic:sign_control(Target, Material, Admission, Slot, Slot, Signer),
    Payload = {batch, [{dtx, Control}]},
    Era = quod_ledger:initial_era(Target),
    {ok, Block} = quod_ledger:new_block(
                    {Era, Slot - 1}, {Era, 0, element(2, Target)}, Payload, 0),
    Entry = quod_ledger:entry(Slot, Block,
        quod_ct:protocol_certificate(Block, #{identity => Target, signer => Signer})),
    {ok, Ref} = quod_dtx:certified_entry_ref(Target, Entry, Control),
    {Control, Entry, Ref}.

dtx_test_ref({Ns, Anchor}, Slot, RecordDigest) ->
    {ok, Ref} = quod_dtx:certified_ref(
                  Ns, Anchor, Slot, digest(225), RecordDigest,
                  quod_ct:fixture_finality(Slot - 1, digest(225))),
    Ref.

applied_certificate(
  {applied, Target, GroupId, ResolveRef, Generation, Verdict}, CommitteeId) ->
    Certificate =
        {quod_dtx_applied_certificate, 2,
         digest(226), Target, CommitteeId, GroupId, ResolveRef,
         Generation, Verdict, [{digest(227), <<228:512>>}]},
    ?assert(quod_ct:valid_applied_certificate_shape(
              Certificate)),
    Certificate.

stop_route_recovery_owners() ->
    _ = [catch gen_server:stop(Pid)
         || Key <- [{directory, control}, {directory, node}],
            Pid <- [quod_reg:where(Key)], is_pid(Pid)],
    ok.

wait_route_demand(Identity, 0) ->
    error({route_demand_timeout, Identity,
           quod_directory_control:test_control_state()});
wait_route_demand(Identity, Left) ->
    State = quod_directory_control:test_control_state(),
    case lists:member(Identity, maps:get(route_demands, State)) of
        true -> ok;
        false ->
            receive after 5 -> ok end,
            wait_route_demand(Identity, Left - 1)
    end.

digest(N) -> <<N:256>>.

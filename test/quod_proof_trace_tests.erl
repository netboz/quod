-module(quod_proof_trace_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").
-include("quod_ledger.hrl").

ordinary_proof_spans_preserve_spawn_parent_and_stage_boundaries_test() ->
    with_engine(fun(Ns) ->
        quod_trace_tests:with_tracer(fun() ->
            ?assertEqual({ok, [#{}], 1}, quod_prolog:prove(Ns, true)),
            Public = quod_trace_tests:take_span(<<"quod.prolog.public_proof">>),
            Worker = quod_trace_tests:take_span(<<"quod.prolog.prove">>),
            Authorization = quod_trace_tests:take_span(
                              <<"quod.prolog.authorization">>),
            Invocation = quod_trace_tests:take_span(<<"quod.prolog.invocation">>),
            PinOrigin = quod_trace_tests:take_span(<<"quod.prolog.pin_origin">>),
            ContextStart = quod_trace_tests:take_span(
                             <<"quod.prolog.context_start">>),
            OriginOpen = quod_trace_tests:take_span(
                           <<"quod.prolog.origin_scope_open">>),
            SessionOpen = quod_trace_tests:take_span(
                            <<"quod.proof_session.open">>),
            FirstResult = quod_trace_tests:take_span(
                            <<"quod.proof_session.first_result">>),
            Advance = quod_trace_tests:take_span(
                        <<"quod.proof_session.advance">>),
            ErlogStep = quod_trace_tests:take_span(<<"quod.erlog.step">>),
            Interpret = quod_trace_tests:take_span(
                          <<"quod.erlog.interpret_result">>),
            Exposure = quod_trace_tests:take_span(
                         <<"quod.erlog.exposure_guard">>),
            Seal = quod_trace_tests:take_span(<<"quod.proof_context.seal">>),
            Finalize = quod_trace_tests:take_span(
                         <<"quod.proof_context.finalize">>),
            Cleanup = quod_trace_tests:take_span(
                        <<"quod.proof_context.cleanup">>),
            assert_child(Public, Worker),
            lists:foreach(fun(Child) -> assert_child(Worker, Child) end,
                          [PinOrigin, ContextStart, OriginOpen, Authorization,
                           Invocation, Seal, Finalize, Cleanup]),
            assert_child(Invocation, SessionOpen),
            assert_child(Invocation, FirstResult),
            assert_child(FirstResult, Advance),
            lists:foreach(fun(Child) -> assert_child(Advance, Child) end,
                          [ErlogStep, Interpret, Exposure]),
            %% A seal span must not accidentally wrap downstream submission or
            %% final cleanup. Cached finalize(commit) must not seal a second time.
            ordered([Authorization, Invocation, Seal, Finalize, Cleanup]),
            receive
                {quod_test_span, #span{name = <<"quod.proof_context.seal">>}} ->
                    error(duplicate_seal_span)
            after 0 -> ok
            end
        end)
    end).

failed_proof_keeps_failure_and_finishes_cleanup_without_exporting_goal_test() ->
    with_engine(fun(Ns) ->
        quod_trace_tests:with_tracer(fun() ->
            Secret = <<"trace-proof-secret-not-an-attribute">>,
            Goal = {missing_trace_predicate, Secret},
            ?assertEqual({fail, [Goal]}, quod_prolog:prove(Ns, Goal)),
            Names = [<<"quod.prolog.public_proof">>, <<"quod.prolog.prove">>,
                     <<"quod.prolog.authorization">>,
                     <<"quod.prolog.invocation">>,
                     <<"quod.proof_context.finalize">>,
                     <<"quod.proof_context.cleanup">>],
            Spans = [quod_trace_tests:take_span(Name) || Name <- Names],
            lists:foreach(
              fun(Span) ->
                  ?assert(Span#span.end_time >= Span#span.start_time),
                  ?assertEqual(nomatch, binary:match(term_to_binary(Span), Secret))
              end, Spans),
            receive
                {quod_test_span, #span{name = <<"quod.proof_context.seal">>}} ->
                    error(failed_proof_was_sealed)
            after 0 -> ok
            end
        end)
    end).

single_write_apply_and_publication_trace_boundaries_test() ->
    traced_committed_batch([otel_ctx:new()]).

shared_batch_is_applied_once_with_two_other_request_links_test() ->
    traced_committed_batch([otel_ctx:new(), otel_ctx:new(), otel_ctx:new()]).

sampled_batch_request_is_not_hidden_by_an_earlier_unsampled_request_test() ->
    Unsampled = quod_trace:extract(
                  [{<<"traceparent">>,
                    <<"00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-00">>}]),
    traced_committed_batch([Unsampled, otel_ctx:new()]).

uncorrelated_apply_does_not_create_request_spans_test() ->
    with_engine(fun(Ns) ->
        quod_trace_tests:with_tracer(fun() ->
            Change = quod_ct:change(Ns, quod_ct:diff_for(untraced_fact), #{}),
            ok = quod_prolog:apply_entry(
                   Ns, quod_ct:committed_entry(Ns, 2, {batch, [Change]}), live),
            ok = quod_prolog:sync(Ns),
            ?assertEqual(2, quod_prolog:applied(Ns)),
            ?assertEqual([], completed_spans())
        end)
    end).

traced_committed_batch(Contexts) ->
    with_engine(fun(Ns) ->
        %% Only consensus placement is simulated. Requests run the real proof,
        %% seal, durable-admission, ordered reducer and waiter-release paths.
        Key = {quod_simplex, Ns},
        true = quod_reg:reg(Key),
        try
            quod_trace_tests:with_tracer(fun() ->
              with_batch_requests(Ns, Contexts, 1, [], fun(TracedRows) ->
                Changes = [Change || {_Caller, _Monitor, _From, Change, _Ctx}
                                      <- TracedRows],
                lists:foreach(
                  fun({_Caller, _Monitor, From, _Change, _Ctx}) ->
                      gen_statem:reply(From, {ok, 2})
                  end, TracedRows),
                ok = quod_prolog:apply_entry(
                       Ns, quod_ct:committed_entry(Ns, 2, {batch, Changes}), live),
                lists:foreach(fun await_batch_result/1, TracedRows),
                ok = quod_prolog:sync(Ns),
                Spans = completed_spans(),
                [Apply] = spans_named(<<"quod.prolog.apply">>, Spans),
                [Flush] = spans_named(<<"quod.outcome.flush">>, Spans),
                [Publish] = spans_named(<<"quod.mvcc.publish">>, Spans),
                assert_child(Apply, Flush),
                assert_child(Apply, Publish),
                ordered([Flush, Publish]),
                RequestSpans = [otel_tracer:current_span_ctx(Ctx)
                                || {_, _, _, _, Ctx} <- TracedRows],
                {Recording, Unrecorded} = lists:partition(
                                           fun otel_span:is_recording/1,
                                           RequestSpans),
                [Parent | Linked] = Recording ++ Unrecorded,
                ?assertEqual(otel_span:trace_id(Parent), Apply#span.trace_id),
                ?assertEqual(otel_span:span_id(Parent), Apply#span.parent_span_id),
                ?assertEqual(
                   lists:sort([{otel_span:trace_id(Span), otel_span:span_id(Span)}
                               || Span <- Linked]),
                   lists:sort([{Link#link.trace_id, Link#link.span_id}
                               || Link <- otel_links:list(Apply#span.links)])),
                lists:foreach(
                  fun(Transaction) ->
                      [Admission] = [Span || Span <- Spans,
                         Span#span.name =:= <<"quod.outcome.admission">>,
                         Span#span.trace_id =:= Transaction#span.trace_id],
                      ?assert(Admission#span.end_time =< Transaction#span.start_time)
                  end, spans_named(<<"quod.transaction">>, Spans)),
                lists:foreach(
                  fun(#transaction{tx_id = Tx}) ->
                      ?assertMatch(
                         {ok, #{status := committed, height := 2}},
                         quod_prolog:local_outcome(
                           Ns, {transaction, Ns, <<0:256>>, Tx}))
                  end, Changes),
                ?assertEqual(length(Contexts), maps:get(applies, quod_prolog:stats(Ns)) - 1)
              end)
            end)
        after
            true = gproc:unreg(quod_reg:name(Key))
        end
    end).

with_batch_requests(_Ns, [], _Index, Acc, Use) -> Use(lists:reverse(Acc));
with_batch_requests(Ns, [Context | Rest], Index, Acc, Use) ->
    Owner = self(),
    Fact = {lists:nth(Index, [trace_written_one, trace_written_two,
                              trace_written_three]), Index},
    {Caller, Monitor} = spawn_monitor(fun() ->
        Result = quod_trace:with_span(
                   Context, <<"test.write">>, internal, #{},
                   fun(_Span) -> quod_prolog:prove(Ns, {assertz, Fact}) end),
        Owner ! {batch_write_result, self(), Result}
    end),
    try receive
        {'$gen_call', From, {append, Change, TransactionCtx}} ->
            with_batch_requests(
              Ns, Rest, Index + 1,
              [{Caller, Monitor, From, Change, TransactionCtx} | Acc], Use);
        {batch_write_result, Caller, EarlyResult} ->
            error({write_did_not_reach_consensus, EarlyResult});
        {'DOWN', Monitor, process, Caller, Reason} ->
            error({write_caller_failed, Reason})
    after 2000 ->
        error(missing_batch_append)
    end
    after
        exit(Caller, kill),
        erlang:demonitor(Monitor, [flush])
    end.

await_batch_result({Caller, Monitor, _From, _Change, _Context}) ->
    receive
        {batch_write_result, Caller, Result} ->
            ?assertEqual({ok, [#{}], 2}, Result),
            erlang:demonitor(Monitor, [flush]);
        {'DOWN', Monitor, process, Caller, Reason} ->
            error({write_caller_failed, Reason})
    after 2000 ->
        exit(Caller, kill),
        error(missing_batch_result)
    end.

completed_spans() ->
    receive
        {quod_test_span, Span} -> [Span | completed_spans()]
    after 0 -> []
    end.

spans_named(Name, Spans) -> [Span || Span = #span{name = N} <- Spans, N =:= Name].

assert_child(Parent, Child) ->
    ?assertEqual(Parent#span.trace_id, Child#span.trace_id),
    ?assertEqual(Parent#span.span_id, Child#span.parent_span_id),
    ?assert(Parent#span.start_time =< Child#span.start_time),
    ?assert(Child#span.end_time =< Parent#span.end_time).

ordered([Left, Right | Rest]) ->
    ?assert(Left#span.end_time =< Right#span.start_time),
    ordered([Right | Rest]);
ordered([_]) -> ok.

with_engine(Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"trace-proof:",
           (binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>,
    {ok, Engine} = quod_prolog:start_link(
                     Ns, #{node_id => {"127.0.0.1", 5000},
                           outcome_backend => memory}),
    try
        %% Same committed host-entry policy as the ordinary bare-engine tests;
        %% tracing does not receive an authorization bypass or a mock proof.
        Policy = {can_invoke, {'Goal'}, {'Principal'}, [], {'Namespace'}},
        Change = (quod_ct:change(Ns, quod_ct:diff_for(Policy), #{}))#transaction{
                    proof_id = none, plan_digest = none,
                    goal = undefined, result = undefined},
        ok = quod_prolog:apply_entry(
               Ns, quod_ct:committed_entry(Ns, 1, {batch, [Change]}), live),
        ok = quod_prolog:mark_ready(Ns),
        ?assertEqual(1, quod_prolog:applied(Ns)),
        Fun(Ns)
    after
        gen_server:stop(Engine)
    end.

-module(quod_foreign_queue_observation_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").

%% Real owner rows and SDK spans: the fetch gate blocks only the predecessor's
%% ordinary certified read. Observation cannot release it or skip its custody.
current_queue_names_the_actual_exact_predecessor_test() ->
    queue_behind_exact(recorded).

unrecorded_predecessor_remains_identified_without_a_fabricated_link_test() ->
    queue_behind_exact(missing).

queue_behind_exact(Mode) ->
    quod_trace_tests:with_tracer(fun() ->
        Fixture = fixture(),
        Parent = self(),
        Gate = make_ref(),
        Held = atomics:new(1, []),
        Fetch0 = fetch(Fixture),
        Fetch = fun(P, E, Ns, From, To) ->
            case atomics:compare_exchange(Held, 1, 0, 1) of
                ok ->
                    Parent ! {held_exact, Gate, self()},
                    receive {release_exact, Gate} -> ok end;
                1 -> ok
            end,
            Fetch0(P, E, Ns, From, To)
        end,
        with_owner(Fetch, fun(Owner) ->
            {FirstContext, FirstSpan} = parent(<<"test.queue.predecessor">>),
            {Context, Span} = parent(<<"test.queue.current">>),
            TraceContext = case Mode of recorded -> FirstContext; missing -> undefined end,
            First = send_request(Owner, exact_request(Fixture, 5000), TraceContext),
            Worker = receive {held_exact, Gate, W} -> W
                     after 2000 -> error(exact_predecessor_not_held) end,
            try
                Current = send_request(Owner, current_request(Fixture, 5000), Context),
                Blocker = span(<<"quod.foreign.queue_blocker">>, Span),
                #{active := #{job_id := JobId, worker := Worker},
                  waiting := [_]} = lifecycle(Owner, identity(Fixture)),
                Attributes = attrs(Blocker),
                ?assertEqual(<<"active">>, maps:get('quod.owner.blocker', Attributes)),
                ?assertEqual(JobId, maps:get('quod.owner.blocker_job_id', Attributes)),
                ?assertEqual(<<"exact">>, maps:get('quod.owner.blocker_work', Attributes)),
                ?assertEqual(maps:get(ns, Fixture),
                             maps:get('quod.namespace', Attributes)),
                ?assertEqual(binary:encode_hex(maps:get(anchor, Fixture), lowercase),
                             maps:get('quod.genesis_anchor', Attributes)),
                ?assertEqual(timeout, gen_server:wait_response(Current, 0)),
                Worker ! {release_exact, Gate},
                ?assertMatch({reply, {ok, _}}, gen_server:wait_response(First, 5000)),
                ?assertMatch({reply, {ok, _}}, gen_server:wait_response(Current, 5000)),
                case Mode of
                    recorded ->
                        WorkerSpan = span(<<"quod.foreign.verification_worker">>, FirstSpan),
                        [Link] = otel_links:list(Blocker#span.links),
                        ?assertEqual(WorkerSpan#span.trace_id, Link#link.trace_id),
                        ?assertEqual(WorkerSpan#span.span_id, Link#link.span_id),
                        ?assertEqual(true, maps:get('quod.owner.blocker_trace_available', Attributes));
                    missing ->
                        ?assertEqual([], otel_links:list(Blocker#span.links)),
                        ?assertEqual(false, maps:get('quod.owner.blocker_trace_available', Attributes))
                end,
                Residence = span(<<"quod.foreign.caller_residence">>, Span),
                ?assertEqual(1, maps:get('quod.owner.blockers_expected', attrs(Residence))),
                ?assertEqual(<<"finite">>, maps:get('quod.caller.budget_kind', attrs(Residence))),
                Admission = maps:get('quod.caller.remaining_ms', attrs(Residence)),
                Stages = owner_stages(Residence),
                [Dispatch] = [S || S <- Stages,
                    maps:get('quod.owner.stage', attrs(S)) =:= <<"acquiring">>],
                ?assert(maps:get('quod.caller.remaining_ms', attrs(Dispatch)) =< Admission),
                ?assertEqual(<<"shared_current">>,
                             maps:get('quod.foreign.work_lifetime', attrs(Dispatch)))
            after
                Worker ! {release_exact, Gate},
                quod_trace:finish_span(Span, ok),
                quod_trace:finish_span(FirstSpan, ok)
            end
        end)
    end).

custody_wait_is_distinct_from_a_route_park_test() ->
    quod_trace_tests:with_tracer(fun() ->
        Fixture = fixture(),
        Identity = identity(Fixture),
        Parent = self(),
        with_owner(fetch(Fixture), fun(Owner) ->
            Custodian = spawn(fun() ->
                true = quod_reg:reg({foreign_cache_writer, Identity}),
                Parent ! {custodian_ready, self()},
                receive stop -> ok end
            end),
            receive {custodian_ready, Custodian} -> ok
            after 1000 -> error(custodian_not_registered) end,
            {FirstContext, FirstSpan} = parent(<<"test.queue.custody">>),
            {Context, Span} = parent(<<"test.queue.after-custody">>),
            try
                First = send_request(Owner, exact_request(Fixture, 5000), FirstContext),
                Custody = span(<<"quod.foreign.queue_blocker">>, FirstSpan),
                ?assertEqual(<<"custody_wait">>, maps:get('quod.owner.blocker', attrs(Custody))),
                #{active := none, waiting := [#{job_id := JobId, wait_reason := custody}]} =
                    lifecycle(Owner, Identity),
                Next = send_request(Owner, current_request(Fixture, 5000), Context),
                Blocker = span(<<"quod.foreign.queue_blocker">>, Span),
                ?assertEqual(<<"earlier_custody_wait">>,
                             maps:get('quod.owner.blocker', attrs(Blocker))),
                ?assertEqual(JobId, maps:get('quod.owner.blocker_job_id', attrs(Blocker))),
                ?assertEqual(timeout, gen_server:wait_response(Next, 0)),
                Monitor = monitor(process, Custodian),
                Custodian ! stop,
                receive {'DOWN', Monitor, process, Custodian, normal} -> ok
                after 1000 -> error(custodian_not_dead) end,
                ?assertMatch({reply, {ok, _}}, gen_server:wait_response(First, 5000)),
                ?assertMatch({reply, {ok, _}}, gen_server:wait_response(Next, 5000))
            after
                exit(Custodian, kill),
                quod_trace:finish_span(Span, ok),
                quod_trace:finish_span(FirstSpan, ok)
            end
        end)
    end).

route_park_names_itself_without_inventing_a_predecessor_test() ->
    quod_trace_tests:with_tracer(fun() ->
        Fixture = fixture(),
        with_owner(fun(_, _, _, _, _) -> error(route_park_fetched) end, fun(Owner) ->
            {Context, Span} = parent(<<"test.queue.route-park">>),
            try
                Request = {verify_reference, maps:get(ref, Fixture), finalize,
                           none, none, 60},
                Call = send_request(Owner, Request, Context),
                Blocker = span(<<"quod.foreign.queue_blocker">>, Span),
                ?assertEqual(<<"route_park">>, maps:get('quod.owner.blocker', attrs(Blocker))),
                ?assertEqual([], otel_links:list(Blocker#span.links)),
                ?assertEqual({reply, {error, retry}}, gen_server:wait_response(Call, 1000)),
                Residence = span(<<"quod.foreign.caller_residence">>, Span),
                ?assertEqual(1, maps:get('quod.owner.blockers_expected', attrs(Residence)))
            after quod_trace:finish_span(Span, ok)
            end
        end)
    end).

source_death_observes_retirement_and_infinity_without_a_new_deadline_test() ->
    quod_trace_tests:with_tracer(fun() ->
        Fixture = fixture(),
        SourceDir = temp_dir("source"),
        {SourcePid, SourceMonitor, Source} =
            quod_foreign_log_tests:start_local_borrow_source(SourceDir, Fixture),
        try
            with_owner(fetch(Fixture), fun(Owner) ->
                {FirstContext, FirstSpan} = parent(<<"test.queue.infinite-borrow">>),
                {Context, Span} = parent(<<"test.queue.retiring">>),
                Gate = make_ref(),
                ok = gen_server:call(Owner, {test_hold_next_local_worker, self(), Gate}),
                try
                    First = send_request(Owner,
                        {verify_local, Source, maps:get(ref, Fixture), finalize, infinity},
                        FirstContext),
                    receive {local_worker_held, Gate, _, _} -> ok
                    after 1000 -> error(local_worker_not_held) end,
                    Current = send_request(Owner, current_request(Fixture, 5000), Context),
                    Active = span(<<"quod.foreign.queue_blocker">>, Span),
                    ?assertEqual(<<"active">>, maps:get('quod.owner.blocker', attrs(Active))),
                    exit(SourcePid, kill),
                    Retiring = span(<<"quod.foreign.queue_blocker">>, Span),
                    ?assertEqual(<<"retiring">>, maps:get('quod.owner.blocker', attrs(Retiring))),
                    ?assertEqual(maps:get('quod.owner.blocker_job_id', attrs(Active)),
                                 maps:get('quod.owner.blocker_job_id', attrs(Retiring))),
                    ?assertEqual({reply, {error, retry}}, gen_server:wait_response(First, 1000)),
                    ?assertMatch({reply, {ok, _}}, gen_server:wait_response(Current, 5000)),
                    Residence = span(<<"quod.foreign.caller_residence">>, FirstSpan),
                    ?assertEqual(<<"infinity">>, maps:get('quod.caller.budget_kind', attrs(Residence))),
                    ?assertNot(maps:is_key('quod.caller.remaining_ms', attrs(Residence))),
                    Stages = owner_stages(Residence),
                    ?assert(lists:all(fun(S) ->
                        maps:get('quod.caller.budget_kind', attrs(S)) =:= <<"infinity">> andalso
                        not maps:is_key('quod.caller.remaining_ms', attrs(S))
                    end, Stages)),
                    [Running] = [S || S <- Stages,
                        maps:get('quod.owner.stage', attrs(S)) =:= <<"running">>],
                    ?assertEqual(<<"source_lifetime">>,
                                 maps:get('quod.foreign.work_lifetime', attrs(Running))),
                    CurrentResidence = span(<<"quod.foreign.caller_residence">>, Span),
                    ?assertEqual(2, maps:get('quod.owner.blockers_expected', attrs(CurrentResidence)))
                after
                    quod_trace:finish_span(Span, ok),
                    quod_trace:finish_span(FirstSpan, ok)
                end
            end)
        after
            quod_foreign_log_tests:stop_local_borrow_source(SourcePid, SourceMonitor),
            _ = file:del_dir_r(SourceDir)
        end
    end).

fixture() ->
    Ns = <<"foreign:queue-observation:",
           (binary:encode_hex(crypto:strong_rand_bytes(8), lowercase))/binary>>,
    quod_foreign_log_tests:foreign_fixture(Ns).
identity(F) -> {maps:get(ns, F), maps:get(anchor, F)}.
contact(F) -> {maps:get(pub, F), {"127.0.0.1", 19091}}.
fetch(F) -> quod_foreign_log_tests:peer_chain_fetch(
              maps:get(ns, F), maps:get(chain, F), [maps:get(pub, F)]).
exact_request(F, Budget) ->
    {verify_reference, maps:get(ref, F), finalize, contact(F), none, Budget}.
current_request(F, Budget) ->
    {Peer, Endpoint} = contact(F),
    {current, [{Peer, [Endpoint]}], identity(F), none, Budget}.
send_request(Owner, Request, Context) ->
    Budget = element(tuple_size(Request), Request),
    Deadline = case Budget of infinity -> infinity;
                              _ -> quod_time:mono_ms() + Budget end,
    gen_server:send_request(Owner,
      {verification, Deadline, Context, erlang:monotonic_time(), Request}).
lifecycle(Owner, Identity) ->
    maps:get(Identity, gen_server:call(Owner, test_lifecycle_state)).
parent(Name) -> quod_trace:start_span(otel_ctx:new(), Name, internal, #{}).
span(Name, Parent) -> quod_trace_tests:take_span(Name, otel_span:trace_id(Parent)).
attrs(S) -> otel_attributes:map(S#span.attributes).
owner_stages(Residence) ->
    Count = maps:get('quod.owner.stages_expected', attrs(Residence)),
    TraceId = Residence#span.trace_id,
    ParentId = Residence#span.span_id,
    [receive
         {quod_test_span, S = #span{name = <<"quod.foreign.owner_stage">>,
                                   trace_id = TraceId, parent_span_id = ParentId}} -> S
     after 1000 -> error(missing_owner_stage)
     end || _ <- lists:seq(1, Count)].
with_owner(Fetch, Fun) ->
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(gproc),
    ?assertEqual(undefined, quod_reg:where({foreign_log, node})),
    Dir = temp_dir("owner"),
    {ok, Owner} = quod_foreign_log:start_link(
                    #{cache_dir => Dir, fetch_fun => Fetch, page_timeout_ms => 1000}),
    try Fun(Owner)
    after
        unlink(Owner),
        _ = catch gen_server:stop(Owner),
        _ = file:del_dir_r(Dir)
    end.
temp_dir(Label) ->
    filename:join("/tmp", "quod_foreign_queue_observation_" ++ Label ++ "_" ++
          binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8), lowercase))).

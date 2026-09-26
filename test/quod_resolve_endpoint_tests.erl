-module(quod_resolve_endpoint_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").

local_verdict_does_not_finish_foreign_validation_test() ->
    isolated(fun() -> quod_trace_tests:with_tracer(fun foreign_validation_interval/0) end).

foreign_validation_interval() ->
    {ok, _} = application:ensure_all_started(gproc),
    F = quod_ct:atomic_role_fixture(),
    Target = {Ns, Anchor} = maps:get(target, F),
    {SourceNs, _} = maps:get(origin, F),
    Owner = self(),
    {Source, SourceMonitor} = spawn_monitor(fun() ->
        true = quod_reg:reg({quod_simplex, SourceNs}),
        Owner ! {source_ready, self()},
        receive {'$gen_call', From, {history_view, _, _, _}} ->
            Owner ! {foreign_read_held, self(), erlang:monotonic_time()},
            receive release -> gen_statem:reply(From, {error, not_ready}) end,
            receive stop -> ok end
        end
    end),
    receive {source_ready, Source} -> ok after 1000 -> error(source_not_ready) end,
    Dir = filename:join("/tmp", "quod-foreign-validation-" ++
              binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    {ok, Store} = quod_ledger_store:open(Ns, Dir),
    {Ctx, Parent} = quod_trace:start_span(otel_ctx:new(), <<"resolve.diagnostic">>, internal, #{}),
    try
        Record = quod_ct:atomic_abort_record(Target, <<94:256>>, maps:get(source_ref, F)),
        {ok, Material} = quod_atomic:admission_material(Record),
        {ok, Control} = quod_atomic:sign_control(Target, Material, maps:get(admission, F),
                                                1, 0, maps:get(signer, F)),
        Era = quod_ledger:initial_era(Target),
        Root = {Era, 0, Anchor},
        {ok, Block} = quod_ledger:new_block({Era, 1}, Root, 2, {batch, [{dtx, Control}]}, 0),
        Hash = quod_simplex:block_hash(Block), Token = {1, Anchor},
        S0 = quod_simplex:test_state(#{ns => Ns, genesis_hash => Anchor, store => Store,
            history_head => Token, eng => quod_simplex:eng_new(<<95:256>>, [], {Root, 1, 0}),
            dtx_projection => quod_atomic:initial_projection(Target, 0)}),
        S1 = quod_simplex:test_state_set(local_proposal, {1, Hash, [Ctx]}, S0),
        {_Monitor, Latched} = quod_simplex:test_latch_dtx_validation(1, Hash, Token, self(), Block, S1),
        Pending = quod_simplex:test_on_dtx_verdict(1, Hash, Token, self(), 1, {valid, #{}}, Latched),
        {Hash, {dtx_foreign, Token, Worker, WorkerMonitor, _, _}, {Hash, Block}, _, _} =
            quod_simplex:test_dtx_round(1, Pending),
        HeldAt = receive {foreign_read_held, Source, At} -> At
                 after 1000 -> error(foreign_validation_not_running) end,
        receive {dtx_foreign_verdict, _, _, _, _} -> error(early_foreign_verdict)
        after 0 -> ok end,
        ReleaseAt = erlang:monotonic_time(), Source ! release,
        receive {dtx_foreign_verdict, {1, Hash, Token}, Worker, Deadline, abstain} ->
            ?assert(Deadline > quod_time:mono_ms())
        after 1000 -> error(foreign_validation_did_not_finish) end,
        erlang:demonitor(WorkerMonitor, [flush]),
        Span = quod_trace_tests:take_span(<<"quod.consensus.foreign_validation">>, otel_span:trace_id(Parent)),
        ?assertEqual(otel_span:span_id(Parent), Span#span.parent_span_id),
        ?assert(Span#span.start_time =< HeldAt),
        ?assert(Span#span.end_time >= ReleaseAt),
        Attrs = otel_attributes:map(Span#span.attributes),
        ?assertEqual(Ns, maps:get('quod.namespace', Attrs)),
        ?assertEqual(1, maps:get('quod.consensus.slot', Attrs)),
        ?assertEqual(1, maps:get('quod.validation.controls', Attrs))
    after
        Source ! stop, exit(Source, kill),
        receive {'DOWN', SourceMonitor, process, Source, _} -> ok after 1000 -> error(source_cleanup) end,
        quod_attempt_span:close({Ctx, Parent}, #{}),
        ok = quod_ledger_store:close(Store), ok = file:del_dir_r(Dir)
    end.

%% Owner/endpoint lifecycle controls, not a consensus-admission witness: the
%% foreign reference and finality below are shape fixtures. Real signed local
%% controls enter the production endpoint and use its actual waiter processes.
%% The committed callback must wake all waiters without another progress turn,
%% including a receiver not scheduled until after the result was published.
resolve_commit_wakes_all_endpoint_waiters_test_() ->
    [{atom_to_list(Delivery), fun() -> isolated(fun() -> resolve_waiters(Delivery) end) end}
     || Delivery <- [running, suspended]].

resolve_waiters(Delivery) ->
    {ok, _} = application:ensure_all_started(gproc),
    F = quod_ct:atomic_role_fixture(),
    Target = {Ns, Anchor} = maps:get(target, F),
    #{pubkey := Self} = Signer = maps:get(signer, F),
    Admission = maps:get(admission, F),
    Domain = <<91:256>>,
    Era = quod_ledger:initial_era(Target),
    Root = {Era, 0, Anchor},
    Dir = filename:join("/tmp", "quod-resolve-endpoint-" ++
              binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    {ok, Journal} = quod_signing_journal:initialize(Ns, Domain, Dir),
    Record = quod_ct:atomic_abort_record(Target, <<92:256>>, maps:get(source_ref, F)),
    {ok, Blob} = quod_atomic:encode_record(Record),
    S0 = quod_simplex:test_state(#{ns => Ns, genesis_hash => Anchor,
        self => Self, id => Signer, validators => [Self], committee_id => <<93:256>>,
        author_admissions => #{Self => Admission}, consensus_domain => Domain,
        sync => ready, prolog_ready => true, signing_journal => Journal,
        history_head => {1, Anchor}, archive_tip => {Root, 0},
        eng => quod_simplex:eng_new(Domain, [Self], {Root, 1, 0})}),
    {monitors, BeforeMonitors} = process_info(self(), monitors),
    try
        {S1, Calls} = lists:foldl(fun(I, {State, Acc}) ->
            From = {self(), make_ref()}, Request = {submit, <<I:128>>, Blob},
            {ok, Next, []} = quod_simplex:test_start_local_dtx_endpoint_request(
                                Request, [], 5000, From, State),
            {Next, [{From, Request} | Acc]}
        end, {S0, []}, lists:seq(1, 4)),
        #{retained := 1, waiters := 4} = quod_simplex:test_retained_dtx_state(S1),
        {monitors, AfterMonitors} = process_info(self(), monitors),
        Pids = lists:usort([Pid || {process, Pid} <- AfterMonitors -- BeforeMonitors,
                                 is_pid(Pid), Pid =/= self()]),
        ?assertEqual(4, length(Pids)),
        case Delivery of
            suspended -> lists:foreach(fun erlang:suspend_process/1, Pids);
            running -> ok
        end,
        {ok, Material} = quod_atomic:admission_material(Record),
        {ok, Control} = quod_atomic:sign_control(Target, Material, Admission, 2, 0, Signer),
        Payload = {batch, [{dtx, Control}]},
        {ok, Block} = quod_ledger:new_block({Era, 1}, Root, 2, Payload, 0),
        Hash = quod_simplex:block_hash(Block),
        #share{sig = Sig} = quod_simplex:make_share(Domain, commit, {Era, 1}, Hash, Signer),
        Entry = quod_ledger:entry(2, Block, #cert{kind = commit, era = Era, slot = 1,
                              block_hash = Hash, sigs = [{Self, Sig}]}),
        S2 = quod_simplex:test_resolve_committed_dtx(Entry, Payload, S1),
        case Delivery of
            suspended -> lists:foreach(fun erlang:resume_process/1, Pids);
            running -> ok
        end,
        {S3, Replies} = lists:foldl(fun(_, {State, Acc}) ->
            receive {dtx_endpoint_worker_result, Pid, Result} ->
                ?assert(lists:member(Pid, Pids)),
                {Next, [{reply, From, {ok, Response, _Hints}}]} =
                    quod_simplex:test_finish_dtx_worker(Pid, Result, State),
                {Next, [{From, Response} | Acc]}
            after 1000 -> error(committed_resolve_did_not_wake_endpoint)
            end
        end, {S2, []}, Calls),
        lists:foreach(fun({From, Request}) ->
            {From, Response = {accepted, _, _, _}} = lists:keyfind(From, 1, Replies),
            ?assert(quod_dtx_endpoint:correlates(Request, Response))
        end, Calls),
        ?assertMatch(#{retained := 0, waiters := 0}, quod_simplex:test_retained_dtx_state(S3)),
        ok = quod_simplex:test_close_dtx_endpoint(S3)
    after
        ok = quod_signing_journal:close(Journal),
        ok = file:del_dir_r(Dir)
    end.

isolated(Fun) ->
    {Pid, Ref} = spawn_monitor(Fun),
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok;
        {'DOWN', Ref, process, Pid, Why} -> error(Why)
    after 10000 -> exit(Pid, kill), error(test_owner_timeout)
    end.

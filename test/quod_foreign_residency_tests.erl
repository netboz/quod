-module(quod_foreign_residency_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").

%% These are the preserved public-API replay probe, with the old undesirable
%% behavior replaced by the permanent architectural assertion. A failed route
%% may fail a request; it may not discard an independently certified prefix.
warm_exact_routes_preserve_verified_cursor_test_() ->
    [{lists:flatten(io_lib:format("~p prefix ~B", [Mode, Height])),
      {timeout, 15, fun() -> warm_exact_routes(Mode, Height) end}}
     || Height <- [1, 2], Mode <- [healthy, transient_fallback]].

definitive_request_failure_does_not_discard_a_healthy_cursor_test_() ->
    {timeout, 15, fun() -> warm_exact_routes(definitive_fallback, 2) end}.

partially_advanced_prefix_survives_candidate_failure_test_() ->
    {timeout, 15, fun() -> warm_exact_routes(partial_fallback, 1) end}.

post_mutation_failure_never_tries_a_source_with_the_old_cursor_test_() ->
    [{atom_to_list(Stage), {timeout, 15, fun() -> persistence_failure(Stage) end}}
     || Stage <- [ledger_append, phase_commit, checkpoint_write, cache_accounting,
                  reserve_page]].

persistence_failure(Stage) ->
    Fixture = quod_foreign_log_tests:foreign_fixture(quod_foreign_log_tests:unique_ns()),
    Ns = maps:get(ns, Fixture), Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture), Chain = maps:get(chain, Fixture),
    FirstPeer = crypto:strong_rand_bytes(32),
    First = {"127.0.0.1", 29999}, Second = {"127.0.0.1", 19000},
    Base = quod_foreign_log_tests:chain_fetch(Ns, Chain),
    Parent = self(), Tag = make_ref(),
    Fetch = fun(P, Endpoint, N, From, To) ->
        Parent ! {persistence_source, Tag, Endpoint, From, To},
        case {Endpoint, get({?MODULE, armed})} of
            {First, undefined} ->
                put({?MODULE, armed}, true),
                ok = quod_foreign_log:test_fail_persist_after(Stage);
            _ -> ok
        end,
        Base(P, Endpoint, N, From, To)
    end,
    Dir = quod_foreign_log_tests:temp_dir("post-mutation-cursor"),
    Owner = quod_foreign_log_tests:start_owner(Dir, Fetch),
    try
        %% Discovery deduplicates by peer, not endpoint. An untrusted byte
        %% source followed by the genuine committee member exercises the
        %% actual two-source walk, and preserves the authority separation.
        Result = quod_foreign_log:current(
            [{FirstPeer, [First]}, {Peer, [Second]}], Identity, 500),
        Sources = persistence_sources(Tag, []),
        ?assert(lists:any(fun({E, _, _}) -> E =:= First end, Sources)),
        case Stage of
            reserve_page ->
                %% Refusal before append leaves the old empty verified prefix
                %% intact, so the ordinary second-source walk is still safe.
                ?assertMatch({ok, #{identity := Identity, slot := 2}}, Result),
                ?assert(lists:any(fun({E, _, _}) -> E =:= Second end, Sources)),
                assert_retained_entries(Owner, Identity, Chain);
            _ ->
                ?assertEqual([], [S || S = {E, _, _} <- Sources, E =:= Second]),
                ?assertEqual({error, retry}, Result),
                ?assertEqual(0, maps:get(resident_verified, quod_foreign_log:stats())),
                %% The completed physical append is intentionally preserved
                %% for the existing cold recovery owner; it is not served
                %% using the pre-append cursor or silently deleted to retry.
                assert_physical_entries(Dir, Identity, Chain)
        end
    after
        quod_foreign_log_tests:stop_owner(Owner),
        _ = file:del_dir_r(Dir)
    end.

persistence_sources(Tag, Acc) ->
    receive {persistence_source, Tag, Endpoint, From, To} ->
        persistence_sources(Tag, [{Endpoint, From, To} | Acc])
    after 0 -> lists:reverse(Acc) end.

failed_tip_confirmation_retains_prefix_without_rebinding_freshness_test_() ->
    {timeout, 15, fun failed_tip_confirmation/0}.

failed_tip_confirmation() ->
    Fixture = quod_foreign_log_tests:foreign_fixture(quod_foreign_log_tests:unique_ns()),
    Ns = maps:get(ns, Fixture), Anchor = maps:get(anchor, Fixture),
    Identity = {Ns, Anchor}, Peer = maps:get(pub, Fixture),
    [Genesis, _] = Chain = maps:get(chain, Fixture),
    Endpoint = {"127.0.0.1", 19000}, Routes = [{Peer, [Endpoint]}],
    PrefixFetch = quod_foreign_log_tests:chain_fetch(Ns, [Genesis]),
    FullFetch = quod_foreign_log_tests:chain_fetch(Ns, Chain),
    Mode = atomics:new(1, []), Parent = self(),
    Fetch = fun(P, E, N, From, To) ->
        Parent ! {freshness_fetch, From},
        case atomics:get(Mode, 1) of
            0 -> PrefixFetch(P, E, N, From, To);
            1 when From > 2 -> {error, retry};
            1 -> FullFetch(P, E, N, From, To);
            2 -> FullFetch(P, E, N, From, To);
            3 -> error({confirmed_unchanged_head_fetched, From})
        end
    end,
    Dir = quod_foreign_log_tests:temp_dir("failed-tip-residency"),
    Owner = quod_foreign_log_tests:start_owner(Dir, Fetch),
    Link = spawn(fun() -> feed_link(Parent) end),
    try
        ?assertMatch({ok, #{slot := 1}}, quod_foreign_log:current(Routes, Identity, 3000)),
        PhaseFiles = phase_files(Dir, Identity),
        1 = erlang:trace(Owner, true, ['receive', {tracer, self()}]),
        ok = atomics:put(Mode, 1, 1),
        CallRef = make_ref(),
        {Caller, MRef} = spawn_monitor(fun() ->
            Parent ! {CallRef, quod_foreign_log:current(Routes, Identity, 250)}
        end),
        receive
            {trace, Owner, 'receive', {foreign_worker_done, _, {error, retry}, _}} -> ok
        after 3000 -> error(failed_current_result_missing) end,
        %% sys:get_state is FIFO behind the observed completion turn, not a
        %% sleep hoping that its metadata has already been installed.
        H = state_history(Identity, sys:get_state(Owner)),
        ?assertEqual(2, record_field(history, height, H)),
        ?assertEqual(true, record_field(history, resident_verified, H)),
        ?assertEqual(unconfirmed, record_field(history, current_view, H)),
        ?assertEqual(PhaseFiles, phase_files(Dir, Identity)),
        receive {CallRef, Result} -> ?assertEqual({error, retry}, Result)
        after 3000 -> error(failed_tip_caller_not_released) end,
        receive {'DOWN', MRef, process, Caller, normal} -> ok
        after 3000 -> error(failed_tip_caller_survived) end,
        1 = erlang:trace(Owner, false, ['receive']),
        RegistrationId = crypto:strong_rand_bytes(16),
        ok = quod_foreign_log:test_install_feed_registration(
            Owner, Identity, Peer, Link, RegistrationId),
        Owner ! {quod_message, {Peer, Link}, quod_feed:channel(Ns),
                 quod_feed:encode(Ns, {recipient_registered, 1, RegistrationId, Anchor, 2})},
        receive {residency_feed_ack, Link, Ack} ->
            ?assertEqual({ack, RegistrationId, Anchor, 2}, quod_feed:decode_recipient(Ack, Ns))
        after 1000 -> error(freshness_registration_not_acknowledged) end,
        %% An H flag is not a K assertion. The failed K request cannot become
        %% successful because a later registration happens to mention K.
        ?assertEqual(unconfirmed, record_field(history, current_view,
            state_history(Identity, sys:get_state(Owner)))),
        ok = atomics:put(Mode, 1, 2),
        _ = freshness_fetches([]),
        ?assertMatch({ok, #{identity := Identity, slot := 2}},
                     quod_foreign_log:current(Routes, Identity, 3000)),
        ?assert(lists:member(3, freshness_fetches([]))),
        ok = atomics:put(Mode, 1, 3),
        ?assertMatch({ok, #{identity := Identity, slot := 2}},
                     quod_foreign_log:current(Routes, Identity, 3000)),
        ?assertEqual([], freshness_fetches([])),
        ?assertEqual(PhaseFiles, phase_files(Dir, Identity)),
        assert_retained_entries(Owner, Identity, Chain)
    after
        _ = catch erlang:trace(Owner, false, [all]),
        Link ! close,
        quod_foreign_log_tests:stop_owner(Owner),
        _ = file:del_dir_r(Dir)
    end.

feed_link(Parent) ->
    receive
        {send_ordered, Payload} -> Parent ! {residency_feed_ack, self(), Payload}, feed_link(Parent);
        close -> ok
    end.

freshness_fetches(Acc) ->
    receive {freshness_fetch, From} -> freshness_fetches([From | Acc])
    after 0 -> lists:reverse(Acc) end.

follow_borrow_refusal_returns_the_transferred_resident_session_test_() ->
    {timeout, 15, fun follow_borrow_refusal/0}.

follow_borrow_refusal() ->
    Fixture = quod_foreign_log_tests:membership_after_finalize_fixture(
                quod_foreign_log_tests:unique_ns()),
    Ns = maps:get(ns, Fixture), Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture), Endpoint = {"127.0.0.1", 19000},
    Prefix = lists:sublist(maps:get(chain, Fixture), 2),
    Dir = quod_foreign_log_tests:temp_dir("follow-borrow-residency"),
    SourceDir = quod_foreign_log_tests:temp_dir("follow-borrow-source"),
    Base = quod_foreign_log_tests:chain_fetch(Ns, Prefix),
    Allowed = atomics:new(1, []),
    Fetch = fun(P, E, N, F, T) ->
        case atomics:get(Allowed, 1) of
            0 -> Base(P, E, N, F, T);
            1 -> error({retained_exact_reference_refetched, F})
        end
    end,
    Owner = quod_foreign_log_tests:start_owner(Dir, Fetch),
    {Source, SourceMRef, _View} = quod_foreign_log_tests:start_local_borrow_source(
                                    SourceDir, Fixture),
    try
        ?assertMatch({ok, #{slot := 2}}, quod_foreign_log:current(
            [{Peer, [Endpoint]}], Identity, 3000)),
        PhaseFiles = phase_files(Dir, Identity),
        ?assertEqual(1, length(PhaseFiles)),
        Source ! {hold_capture, self()},
        receive {local_capture_gate_ready, Source} -> ok
        after 1000 -> error(follow_source_gate_not_ready) end,
        1 = erlang:trace(Owner, true, ['receive', {tracer, self()}]),
        {ok, FollowRef} = quod_foreign_log:follow(Identity),
        receive {local_capture_held, Source, _Deadline} -> ok
        after 1000 -> error(follow_did_not_capture_source) end,
        #{active := #{worker := Worker}} = maps:get(
            Identity, quod_foreign_log:test_lifecycle_state()),
        1 = erlang:trace(Worker, true, [send, {tracer, self()}]),
        ok = sys:suspend(Owner),
        Source ! release_capture,
        receive
            {trace, Worker, send, {'$gen_call', _, {borrow_local_view, _, _}}, Owner} -> ok
        after 1000 -> error(follow_borrow_was_not_queued) end,
        %% The source dies after capture but before admission at the owner.
        %% The refusal is the genuine early-return arm; no deadline is changed
        %% and no sleeping/polling is needed to establish the schedule.
        exit(Source, kill),
        receive {'DOWN', SourceMRef, process, Source, killed} -> ok
        after 1000 -> error(follow_source_did_not_die) end,
        ok = sys:resume(Owner),
        receive
            {trace, Owner, 'receive', {foreign_worker_done, _,
                {error, {unreachable, unavailable}}, _}} -> ok
        after 3000 -> error(follow_borrow_refusal_not_returned) end,
        H = state_history(Identity, sys:get_state(Owner)),
        ?assertEqual(2, record_field(history, height, H)),
        ?assertEqual(true, record_field(history, resident_verified, H)),
        ?assertNotEqual(none, record_field(history, phase_session, H)),
        ?assertEqual(PhaseFiles, phase_files(Dir, Identity)),
        ok = atomics:put(Allowed, 1, 1),
        ?assertMatch({ok, #{phase := finalize}}, quod_foreign_log:verify_reference(
            maps:get(ref, Fixture), finalize, {Peer, Endpoint}, 3000)),
        ?assertEqual(PhaseFiles, phase_files(Dir, Identity)),
        assert_retained_entries(Owner, Identity, Prefix),
        ok = quod_foreign_log:unfollow(FollowRef)
    after
        _ = catch sys:resume(Owner),
        _ = catch erlang:trace(Owner, false, [all]),
        exit(Source, kill),
        _ = erlang:demonitor(SourceMRef, [flush]),
        quod_foreign_log_tests:stop_owner(Owner),
        _ = file:del_dir_r(SourceDir),
        _ = file:del_dir_r(Dir)
    end.

confirmed_binding_survives_only_the_same_verified_head_test_() ->
    [{atom_to_list(Mode), fun() -> confirmed_binding(Mode) end}
     || Mode <- [same_head, advanced_head]].

confirmed_binding(Mode) ->
    {Height, Expected} = case Mode of
        same_head -> {1, confirmed};
        advanced_head -> {2, unconfirmed}
    end,
    with_installation_state(Height, fun(Identity, RequestRef, State0, Meta) ->
    State1 = quod_foreign_log:test_install_worker_meta(RequestRef, Meta, State0),
    H1 = state_history(Identity, State1),
    ?assertEqual(Height, record_field(history, height, H1)),
    ?assertEqual(maps:get(projection, Meta), record_field(history, projection, H1)),
    ?assertEqual(Expected, record_field(history, current_view, H1))
    end).

resident_failure_only_wakes_waiters_on_real_advance_test_() ->
    [{atom_to_list(Mode), fun() -> resident_failure_wakes(Mode) end}
     || Mode <- [unchanged_prefix, advanced_prefix]].

resident_failure_wakes(Mode) ->
    {Height, Expected} = case Mode of
        unchanged_prefix -> {1, [true, true]};
        advanced_prefix -> {2, [false, false]}
    end,
    with_installation_state(Height, fun(Identity, RequestRef, State0, Meta) ->
    Request = maps:get(RequestRef, record_field(s, pending, State0)),
    {exact_reference, Ref, prepare, none} = record_field(
        routed_work, kind, record_field(request, work, Request)),
    WorkA = make_record(routed_work, #{kind => {exact_reference, Ref, prepare, none}}),
    WorkB = make_record(routed_work, #{kind => {exact_reference, Ref, finalize, none}}),
    Caller = make_record(caller, #{deadline => infinity,
                                  enqueued_native => erlang:monotonic_time()}),
    Rows = [make_record(request,
                       #{ref => make_ref(), identity => Identity, work => Work,
                         callers => #{{self(), make_ref()} => Caller},
                         enqueued_native => erlang:monotonic_time(), parked => true})
            || Work <- [WorkA, WorkB]],
    H0 = state_history(Identity, State0),
    State = put_record(s, histories,
        #{Identity => put_record(history, waiting, queue:from_list(Rows), H0)}, State0),
    %% A real active-row guard holds dispatch while we inspect both distinct
    %% live callers' park permissions. Repeated unchanged installations model
    %% each unsuccessful job finishing: neither may grant the other's retry.
    State1 = quod_foreign_log:test_install_verified_progress(RequestRef, Meta, State),
    ?assertEqual(Expected, parked_flags(Identity, State1)),
    State2 = quod_foreign_log:test_install_verified_progress(RequestRef, Meta, State1),
    ?assertEqual(Expected, parked_flags(Identity, State2)),
    ?assertEqual(RequestRef, record_field(history, active, state_history(Identity, State2))),
    ?assertEqual(2, length(queue:to_list(
        record_field(history, waiting, state_history(Identity, State2)))))
    end).

with_installation_state(Height, Fun) ->
    Fixture = quod_foreign_log_tests:prepared_then_committed_fixture(
                quod_foreign_log_tests:unique_ns()),
    Ns = maps:get(ns, Fixture), Anchor = maps:get(anchor, Fixture),
    Identity = {Ns, Anchor},
    [Genesis, Prepare, _] = maps:get(chain, Fixture),
    PhaseDir = quod_foreign_log_tests:temp_dir("installation-projection"),
    CacheNs = quod_foreign_log:cache_namespace(Identity),
    {ok, PhaseIndex} = quod_dtx_phase_index:open(PhaseDir, CacheNs),
    {ok, Hold} = quod_dtx_phase_index:retain_empty(PhaseIndex),
    {ok, Store0} = quod_ledger_store:open(CacheNs, PhaseDir, wrapped),
    try
        %% Callback-state fixture, not an admitted consensus job. Its read
        %% capability and returned cursor now use real verified disk resources;
        %% resident_verified with no index/snapshot is not a valid state.
        {ok, [_], P1, D1} = quod_catchup:verify_forward(
            Ns, Anchor, quod_simplex:history_projection(Identity), 1, [Genesis], PhaseIndex),
        ok = quod_dtx_phase_index:commit_delta(PhaseIndex, D1),
        {ok, Store1} = quod_ledger_store:append(Store0, [Genesis]),
        Snapshot1 = quod_ledger_store:snapshot(Store1),
        {ok, [_], P2, D2} = quod_catchup:verify_forward(
            Ns, Anchor, P1, 2, [Prepare], PhaseIndex),
        {Projection, Store} = case Height of
            1 -> {P1, Store1};
            2 ->
                {ok, Store2} = quod_ledger_store:append(Store1, [Prepare]),
                ok = quod_dtx_phase_index:commit_delta(PhaseIndex, D2),
                {P2, Store2}
        end,
        {ok, Session} = quod_dtx_phase_index:suspend(PhaseIndex),
        RequestRef = make_ref(),
        Published = make_record(prefix, #{height => 1, projection => P1,
                                          snapshot => Snapshot1, index => Hold}),
        History = make_record(history,
            #{height => 1, projection => P1, resident_verified => false,
              published => Published, current_view => confirmed, active => RequestRef}),
        Request = make_record(request,
            #{identity => Identity, worker => self(), mref => make_ref(),
              work => make_record(routed_work,
                  #{kind => {exact_reference, maps:get(prepare_ref, Fixture), prepare, none}})}),
        State = make_record(s,
            #{histories => #{Identity => History}, pending => #{RequestRef => Request}}),
        Meta = #{height => Height, projection => Projection, resident_verified => true,
                 phase_session => Session, cache_session => quod_ledger_store:snapshot(Store)},
        try Fun(Identity, RequestRef, State, Meta)
        after ok = quod_dtx_phase_index:release(Hold),
              ok = quod_dtx_phase_index:close(Session)
        end
    after
        _ = quod_dtx_phase_index:release(Hold),
        _ = quod_dtx_phase_index:close(PhaseIndex),
        _ = quod_ledger_store:close(Store0),
        _ = file:del_dir_r(PhaseDir)
    end.

state_history(Identity, State) -> maps:get(Identity, record_field(s, histories, State)).

parked_flags(Identity, State) ->
    [record_field(request, parked, Row) || Row <- queue:to_list(
        record_field(history, waiting, state_history(Identity, State)))].

warm_exact_routes(Mode, PrefixHeight) ->
    try
        quod_trace_tests:with_tracer(fun() -> warm_exact_routes_traced(Mode, PrefixHeight) end)
    after
        drain_test_spans()
    end.

drain_test_spans() ->
    receive {quod_test_span, _} -> drain_test_spans()
    after 0 -> ok end.

warm_exact_routes_traced(Mode, PrefixHeight) ->
    Ns = quod_foreign_log_tests:unique_ns(),
    FixtureHeight = case Mode of partial_fallback -> 2; _ -> PrefixHeight end,
    Fixture = case FixtureHeight of
                  1 -> quod_foreign_log_tests:foreign_fixture(Ns);
                  2 -> quod_foreign_log_tests:prepared_then_committed_fixture(Ns)
              end,
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Chain = maps:get(chain, Fixture),
    Prefix = lists:sublist(Chain, PrefixHeight),
    RequestedSlot = length(Chain),
    Ref = case FixtureHeight of
              1 -> maps:get(ref, Fixture);
              2 -> maps:get(finalize_ref, Fixture)
          end,
    Good = {"127.0.0.1", 19000},
    ContactEndpoint = {"127.0.0.1", 29999},
    PrefixFetch = quod_foreign_log_tests:chain_fetch(Ns, Prefix),
    FullFetch = quod_foreign_log_tests:chain_fetch(Ns, Chain),
    Phase = atomics:new(1, []),
    Parent = self(),
    Fetch = fun(P, Endpoint, RequestedNs, From, To) ->
        Parent ! {residency_fetch, atomics:get(Phase, 1), Endpoint, From, To},
        case {atomics:get(Phase, 1), Endpoint, Mode} of
            {0, Good, _} -> PrefixFetch(P, Endpoint, RequestedNs, From, To);
            {1, ContactEndpoint, transient_fallback} -> {error, retry};
            {1, ContactEndpoint, partial_fallback} when From =:= 2 ->
                {ok, [lists:nth(2, Chain)], RequestedSlot};
            {1, ContactEndpoint, partial_fallback} when From =:= 3 ->
                {error, retry};
            {1, _, _} -> FullFetch(P, Endpoint, RequestedNs, From, To)
        end
    end,
    Dir = quod_foreign_log_tests:temp_dir("verified-cursor"),
    Owner = quod_foreign_log_tests:start_owner(Dir, Fetch),
    MFAs = [{quod_ledger_store, open, 3}, {quod_foreign_log, replay_cache, 6}],
    try
        {module, quod_ledger_store} = code:ensure_loaded(quod_ledger_store),
        [1 = erlang:trace_pattern(MFA, true, [local]) || MFA <- MFAs],
        1 = erlang:trace(Owner, true, [call, set_on_spawn, {tracer, self()}]),
        {ok, #{identity := Identity, slot := PrefixHeight}} =
            quod_foreign_log:current([{Peer, [Good]}], Identity, 5000),
        ?assertMatch(#{resident_verified := 1}, quod_foreign_log:stats()),
        WarmCalls = drain_calls(),
        %% Positive control: this exact trace observes the real initial full
        %% open. A disabled hook cannot satisfy the subsequent zero-work test.
        ?assertEqual(1, call_count({quod_ledger_store, open, 3}, WarmCalls)),
        ?assertEqual(0, call_count({quod_foreign_log, replay_cache, 6}, WarmCalls)),
        FilesBefore = phase_files(Dir, Identity),
        ?assertEqual(1, length(FilesBefore)),
        _ = drain_fetches(),
        ok = atomics:put(Phase, 1, 1),
        Contact = case Mode of healthy -> {Peer, Good};
                               _ -> {Peer, ContactEndpoint} end,
        ExpectedPhase = case Mode of definitive_fallback -> prepare;
                                     _ -> finalize end,
        RootName = <<"test.residency.exact">>,
        Result = quod_trace:with_span(quod_trace:context(), RootName, internal, #{},
            fun(_Span) -> quod_foreign_log:verify_reference(
                             Ref, ExpectedPhase, Contact, 5000) end),
        case Mode of
            definitive_fallback ->
                ?assertEqual({error, invalid_foreign_reference}, Result);
            _ ->
                ?assertMatch({ok, #{identity := Identity, phase := finalize}}, Result)
        end,
        Calls = drain_calls(),
        Fetches = drain_fetches(),
        RootSpan = quod_trace_tests:take_span(RootName),
        Worker = quod_trace_tests:take_span(
                   <<"quod.foreign.verification_worker">>, RootSpan#span.trace_id),
        Attributes = otel_attributes:map(Worker#span.attributes),
        ?assertEqual(0, call_count({quod_ledger_store, open, 3}, Calls)),
        ?assertEqual(0, call_count({quod_foreign_log, replay_cache, 6}, Calls)),
        ?assertEqual(FilesBefore, phase_files(Dir, Identity)),
        ?assertEqual(0, maps:get('quod.foreign.disk_replayed_entries', Attributes)),
        ?assertEqual(0, maps:get('quod.foreign.cold_opens', Attributes)),
        case Mode of
            healthy -> ?assertMatch([{1, Good, RequestedSlot, _}], Fetches);
            transient_fallback ->
                ?assertMatch([{1, ContactEndpoint, RequestedSlot, _},
                              {1, Good, RequestedSlot, _}], Fetches);
            partial_fallback ->
                ?assertMatch([{1, ContactEndpoint, 2, 3},
                              {1, ContactEndpoint, 3, 3},
                              {1, Good, 3, 3}], Fetches);
            definitive_fallback ->
                %% The first source supplied the exact suffix. The second
                %% definitive arm must inspect that cursor, not re-fetch it.
                ?assertMatch([{1, ContactEndpoint, RequestedSlot, _}], Fetches)
        end,
        ?assertMatch(#{resident_verified := 1}, quod_foreign_log:stats()),
        assert_retained_entries(Owner, Identity, Chain)
    after
        _ = catch erlang:trace(Owner, false, [all]),
        [erlang:trace_pattern(MFA, false, [local]) || MFA <- MFAs],
        quod_foreign_log_tests:stop_owner(Owner),
        _ = file:del_dir_r(Dir)
    end.

assert_retained_entries(Owner, Identity, Entries) ->
    Histories = record_field(s, histories, sys:get_state(Owner)),
    History = maps:get(Identity, Histories),
    ?assertEqual(length(Entries), record_field(history, height, History)),
    Session = record_field(history, cache_session, History),
    {ok, Store} = quod_ledger_store:open_ro_snapshot(Session),
    assert_store_entries(Store, Entries).

assert_physical_entries(Dir, Identity, Entries) ->
    %% Offline, non-truncating inspection is deliberately used only after the
    %% worker refused its inconsistent cursor. It is not a live fallback and
    %% does not promote a disk checkpoint to verification authority.
    {ok, Store} = quod_ledger_store:open_ro(
        quod_foreign_log:cache_namespace(Identity), Dir, wrapped),
    assert_store_entries(Store, Entries).

assert_store_entries(Store, Entries) ->
    try
        ?assertEqual(length(Entries), quod_ledger_store:last(Store)),
        lists:foreach(fun({Index, Expected}) ->
            {ok, Retained} = quod_ledger_store:read_at(Store, Index),
            ?assertEqual(quod_ledger:encode_entry(Expected),
                         quod_ledger:encode_entry(Retained))
        end, lists:zip(lists:seq(1, length(Entries)), Entries))
    after
        ok = quod_ledger_store:close(Store)
    end.

%% Derive record layout from the module under test. There are no positional
%% copies that can silently drift when the owner refactors its state.
record_field(Tag, Name, Record) ->
    Fields = record_fields(Tag),
    Names = [record_field_name(F) || F <- Fields],
    ?assertEqual(Tag, element(1, Record)),
    element(1 + field_index(Name, Names, 1), Record).

put_record(Tag, Name, Value, Record) ->
    Names = [record_field_name(F) || F <- record_fields(Tag)],
    ?assertEqual(Tag, element(1, Record)),
    setelement(1 + field_index(Name, Names, 1), Record, Value).

make_record(Tag, Overrides) ->
    Fields = record_fields(Tag),
    Names = [record_field_name(F) || F <- Fields],
    ?assertEqual([], maps:keys(maps:without(Names, Overrides))),
    list_to_tuple([Tag | [maps:get(record_field_name(F), Overrides, record_default(F))
                          || F <- Fields]]).

record_fields(Tag) ->
    {ok, {quod_foreign_log, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
        beam_lib:chunks(code:which(quod_foreign_log), [abstract_code]),
    [Fields] = [Fs || {attribute, _, record, {T, Fs}} <- Forms, T =:= Tag],
    Fields.

record_default({typed_record_field, Field, _Type}) -> record_default(Field);
record_default({record_field, _, {atom, _, _Name}, Default}) ->
    {value, Value, _Bindings} = erl_eval:expr(Default, erl_eval:new_bindings()), Value;
record_default({record_field, _, {atom, _, _Name}}) -> undefined.

record_field_name({typed_record_field, Field, _Type}) -> record_field_name(Field);
record_field_name({record_field, _, {atom, _, Name}, _Default}) -> Name;
record_field_name({record_field, _, {atom, _, Name}}) -> Name.

field_index(Name, [Name | _], Index) -> Index;
field_index(Name, [_ | Rest], Index) -> field_index(Name, Rest, Index + 1).

phase_files(Dir, Identity) ->
    CacheNs = quod_foreign_log:cache_namespace(Identity),
    CacheDir = quod_ledger_store:ns_dir(Dir, CacheNs),
    {ok, Names} = file:list_dir(CacheDir),
    lists:sort([Name || Name <- Names,
                       lists:prefix("dtx-phases.", Name),
                       lists:suffix(".dets", Name)]).

drain_calls() ->
    Delivery = erlang:trace_delivered(all),
    receive {trace_delivered, all, Delivery} -> ok
    after 5000 -> error(trace_barrier_timeout) end,
    drain_calls([]).

drain_calls(Acc) ->
    receive {trace, Pid, call, MFA} -> drain_calls([{Pid, MFA} | Acc])
    after 0 -> lists:reverse(Acc) end.

call_count({M, F, A}, Calls) ->
    length([ok || {_Pid, {CM, CF, Args}} <- Calls,
                  CM =:= M, CF =:= F, length(Args) =:= A]).

drain_fetches() -> drain_fetches([]).
drain_fetches(Acc) ->
    receive {residency_fetch, Phase, Endpoint, From, To} ->
        drain_fetches([{Phase, Endpoint, From, To} | Acc])
    after 0 -> lists:reverse(Acc) end.

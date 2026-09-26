-module(quod_foreign_residency_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").
-include("quod_proof_limits.hrl").

checkpoint_once_per_verified_range_test_() ->
    [{integer_to_list(Height), {timeout, 15,
       fun() -> checkpoint_once_per_verified_range(Height) end}}
     || Height <- [2, 64, 257]].

checkpoint_once_per_verified_range(Height) ->
    Fixture = quod_foreign_log_tests:long_identity_fixture(
        quod_foreign_log_tests:unique_ns(), Height),
    Ns = maps:get(ns, Fixture), Identity = {Ns, maps:get(anchor, Fixture)},
    Chain = maps:get(chain, Fixture), Peer = maps:get(pub, Fixture),
    Dir = quod_foreign_log_tests:temp_dir("range-checkpoint"),
    Owner = quod_foreign_log_tests:start_owner(
        Dir, quod_foreign_log_tests:chain_fetch(Ns, Chain)),
    MFA = {quod_foreign_log, write_checkpoint, 5},
    SyncMFA = {quod_ledger_store, batch_sync, 1},
    Session = trace:session_create(?MODULE, self(), []),
    try
        1 = trace:function(Session, MFA, true, [local]),
        1 = trace:function(Session, SyncMFA, true, [local]),
        1 = trace:process(Session, Owner, true, [call, arity, set_on_spawn]),
        ?assertMatch({ok, #{slot := Height}}, quod_foreign_log_tests:prime_projection(
            [{Peer, [{"127.0.0.1", 19000}]}], Identity, Height, 3000)),
        Delivery = trace:delivered(Session, all),
        Ranges = (Height + ?QUOD_MAX_FOREIGN_PAGE_ENTRIES - 1)
                 div ?QUOD_MAX_FOREIGN_PAGE_ENTRIES,
        ?assertEqual({Ranges, Ranges}, checkpoint_calls(Delivery, {0, 0})),
        assert_retained_entries(Owner, Identity, Chain)
    after
        trace:session_destroy(Session),
        quod_foreign_log_tests:stop_owner(Owner),
        _ = file:del_dir_r(Dir)
    end.


startup_retains_complete_groups_after_checkpoint_test_() ->
    [{atom_to_list(Checkpoint), {timeout, 15,
      fun() -> startup_complete_suffix(Checkpoint) end}}
     || Checkpoint <- [older, missing]].

startup_complete_suffix(Checkpoint) ->
    Fixture = quod_foreign_log_tests:long_identity_fixture(
        quod_foreign_log_tests:unique_ns(), 4),
    Ns = maps:get(ns, Fixture), Identity = {Ns, maps:get(anchor, Fixture)},
    [Genesis | Suffix] = Chain = maps:get(chain, Fixture),
    Peer = maps:get(pub, Fixture), Dir = quod_foreign_log_tests:temp_dir("checkpoint-suffix"),
    CacheNs = quod_foreign_log:cache_namespace(Identity),
    Path = filename:join(quod_ledger_store:ns_dir(Dir, CacheNs), "checkpoint.term"),
    Owner = quod_foreign_log_tests:start_owner(
        Dir, quod_foreign_log_tests:chain_fetch(Ns, [Genesis])),
    try
        ?assertMatch({ok, #{slot := 1}}, quod_foreign_log_tests:prime_projection(
            [{Peer, [{"127.0.0.1", 19000}]}], Identity, 1, 3000)),
        quod_foreign_log_tests:stop_owner(Owner),
        {ok, PriorCheckpoint} = file:read_file(Path),
        %% Simulate the real durability/publication gap: complete, synced
        %% archive groups exist while the published checkpoint is still old.
        {ok, Store0} = quod_ledger_store:open(CacheNs, Dir, wrapped),
        {ok, Store} = quod_ct:append_direct_history(Store0, Suffix),
        {ok, ExpectedBytes} = quod_ledger_store:committed_boundary(Store, 4),
        ok = quod_ledger_store:close(Store),
        case Checkpoint of older -> ok; missing -> ok = file:delete(Path) end,
        Parent = self(),
        Restarted = quod_foreign_log_tests:start_owner(Dir,
            fun(_, _, _, Query, _, _) ->
                Parent ! {unexpected_startup_fetch, Query},
                error({unexpected_startup_fetch, Query})
            end),
        try
            ok = quod_foreign_log_tests:await_history_ready(Identity, 4),
            assert_retained_entries(Restarted, Identity, Chain),
            {ok, NewCheckpoint} = file:read_file(Path),
            ?assertNotEqual(PriorCheckpoint, NewCheckpoint),
            ?assertMatch({quod_foreign_log_checkpoint, _, Ns, _, 4, ExpectedBytes, _},
                         binary_to_term(NewCheckpoint, [safe])),
            receive {unexpected_startup_fetch, Query} ->
                error({startup_should_use_complete_archive, Query})
            after 0 -> ok end
        after quod_foreign_log_tests:stop_owner(Restarted) end
    after
        quod_foreign_log_tests:stop_owner(Owner),
        _ = file:del_dir_r(Dir)
    end.

checkpoint_calls(Delivery, {Count, Syncs}) ->
    receive
        {trace, _, call, {quod_foreign_log, write_checkpoint, 5}} ->
            checkpoint_calls(Delivery, {Count + 1, Syncs});
        {trace, _, call, {quod_ledger_store, batch_sync, 1}} ->
            checkpoint_calls(Delivery, {Count, Syncs + 1});
        {trace_delivered, all, Delivery} -> {Count, Syncs}
    after 3000 -> error(checkpoint_trace_delivery_missing)
    end.

%% These are the preserved public-API replay probe, with the old undesirable
%% behavior replaced by the permanent architectural assertion. A failed route
%% may fail a request; it may not discard an independently certified prefix.
warm_exact_routes_preserve_verified_cursor_test_() ->
    [{lists:flatten(io_lib:format("~p prefix ~B", [Mode, Height])),
      {timeout, 15, fun() -> warm_exact_routes(Mode, Height) end}}
     || Height <- [1, 2], Mode <- [healthy, transient_fallback]].

definitive_request_failure_does_not_discard_a_healthy_cursor_test_() ->
    {timeout, 15, fun() -> warm_exact_routes(definitive_fallback, 2) end}.

interrupted_sparse_proof_preserves_retained_material_prefix_test_() ->
    {timeout, 15, fun() -> warm_exact_routes(partial_fallback, 1) end}.

post_mutation_failure_never_tries_a_source_with_the_old_cursor_test_() ->
    [{atom_to_list(Stage), {timeout, 15, fun() -> persistence_failure(Stage) end}}
     || Stage <- [ledger_append, ledger_sync, phase_commit, checkpoint_write, cache_accounting,
                  reserve_page]].

persistence_failure(Stage) ->
    Fixture = quod_foreign_log_tests:foreign_fixture(quod_foreign_log_tests:unique_ns()),
    Ns = maps:get(ns, Fixture), Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture), Chain = maps:get(chain, Fixture),
    FirstPeer = <<0:256>>,
    First = {"127.0.0.1", 29999}, Second = {"127.0.0.1", 19000},
    Base = quod_foreign_log_tests:chain_fetch(Ns, Chain),
    Parent = self(), Tag = make_ref(),
    Fetch = fun(P, Endpoint, N, Query, Deadline, Consume) ->
        Parent ! {persistence_source, Tag, Endpoint, Query, Deadline},
        case {Endpoint, Query, get({?MODULE, armed})} of
            {_, {range, _, _}, undefined} ->
                put({?MODULE, armed}, true),
                ok = quod_foreign_log:test_fail_persist_after(Stage);
            _ -> ok
        end,
        Base(P, Endpoint, N, Query, Deadline, Consume)
    end,
    Dir = quod_foreign_log_tests:temp_dir("post-mutation-cursor"),
    Owner = quod_foreign_log_tests:start_owner(Dir, Fetch),
    try
        %% Discovery deduplicates by peer, not endpoint. An untrusted byte
        %% source followed by the genuine committee member exercises the
        %% actual two-source walk, and preserves the authority separation.
        Result = quod_foreign_log_tests:prime_projection(
            [{FirstPeer, [First]}, {Peer, [Second]}], Identity, 2, 500),
        Sources = [Source || Source = {_, {range, _, _}, _} <- persistence_sources(Tag, [])],
        ?assert(Sources =/= []),
        case Stage of
            reserve_page ->
                %% Refusal before append leaves the old empty verified prefix
                %% intact, so the ordinary second-source walk is still safe.
                ?assertMatch({ok, #{identity := Identity, slot := 2}}, Result),
                ?assertEqual(2, length(lists:usort([E || {E, _, _} <- Sources]))),
                assert_retained_entries(Owner, Identity, Chain);
            _ ->
                ?assertEqual(1, length(Sources)),
                ?assertMatch({error, _}, Result),
                %% Group-local failures retain one group; checkpointing runs
                %% after the complete bounded acquisition. Cold recovery owns
                %% either physical prefix; it is not served
                %% using the pre-append cursor or silently deleted to retry.
                Retained = case Stage of
                    ledger_append -> [hd(Chain)];
                    _ -> Chain
                end,
                assert_physical_entries(Dir, Identity, Retained)
        end
    after
        quod_foreign_log_tests:stop_owner(Owner),
        _ = file:del_dir_r(Dir)
    end.

persistence_sources(Tag, Acc) ->
    receive {persistence_source, Tag, Endpoint, From, To} ->
        persistence_sources(Tag, [{Endpoint, From, To} | Acc])
    after 0 -> lists:reverse(Acc) end.

failed_probe_retains_prefix_for_later_feed_confirmation_test_() ->
    {timeout, 15, fun failed_tip_confirmation/0}.

failed_tip_confirmation() ->
    Fixture = quod_foreign_log_tests:four_member_confirmation_fixture(
        quod_foreign_log_tests:unique_ns(), 2),
    Ns = maps:get(ns, Fixture), Anchor = maps:get(anchor, Fixture),
    Identity = {Ns, Anchor}, [Peer | _] = Peers = maps:get(peers, Fixture),
    [Genesis, _] = Chain = maps:get(chain, Fixture),
    Routes = maps:get(routes, Fixture),
    PrefixFetch = quod_foreign_log_tests:peer_chain_fetch(Ns, [Genesis], Peers),
    FullFetch = quod_foreign_log_tests:peer_chain_fetch(Ns, Chain, Peers),
    Mode = atomics:new(1, []), Parent = self(),
    Fetch = fun(P, E, N, Query, Deadline, Consume) ->
        Parent ! {freshness_fetch, Query},
        case atomics:get(Mode, 1) of
            0 -> PrefixFetch(P, E, N, Query, Deadline, Consume);
            %% One genuine member proves the tip but cannot confirm the
            %% four-member committee. The other members refuse the request.
            1 when P =:= Peer -> FullFetch(P, E, N, Query, Deadline, Consume);
            1 -> {error, retry};
            2 -> FullFetch(P, E, N, Query, Deadline, Consume)
        end
    end,
    Dir = quod_foreign_log_tests:temp_dir("failed-tip-residency"),
    Owner = quod_foreign_log_tests:start_owner(Dir, Fetch),
    Links = [{Member, spawn(fun() -> feed_link(Parent) end)}
             || Member <- lists:sublist(Peers, 3)],
    try
        ?assertMatch({ok, #{slot := 1}}, quod_foreign_log_tests:prime_projection(
            Routes, Identity, 1, 3000)),
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
        ?assertEqual(1, record_field(history, height, H)),
        ?assertEqual(true, record_field(history, resident_verified, H)),
        ?assertMatch(#{height := 2}, record_field(history, certified_tip, H)),
        ?assertEqual(PhaseFiles, phase_files(Dir, Identity)),
        receive {CallRef, Result} -> ?assertEqual({error, retry}, Result)
        after 3000 -> error(failed_tip_caller_not_released) end,
        receive {'DOWN', MRef, process, Caller, normal} -> ok
        after 3000 -> error(failed_tip_caller_survived) end,
        1 = erlang:trace(Owner, false, ['receive']),
        lists:foreach(fun({Member, Link}) ->
            RegistrationId = crypto:strong_rand_bytes(16),
            ok = quod_foreign_log:test_install_feed_registration(
                Owner, Identity, Member, Link, RegistrationId),
            Owner ! {quod_message, {Member, Link}, quod_feed:channel(Ns),
                     quod_feed:encode(Ns, {recipient_registered, 1, RegistrationId, Anchor, 2})},
            receive {residency_feed_ack, Link, Ack} ->
                ?assertEqual({ack, RegistrationId, Anchor, 2}, quod_feed:decode_recipient(Ack, Ns))
            after 1000 -> error(freshness_registration_not_acknowledged) end
        end, Links),
        %% The failed caller above stays failed. A new caller may now use the
        %% live exact-height committee feed as its confirmation; the earlier
        %% failed probe is neither rewritten nor required again.
        ok = atomics:put(Mode, 1, 2),
        _ = freshness_fetches([]),
        ?assertMatch({ok, #{identity := Identity, slot := 2}},
                     quod_foreign_log:current(Routes, Identity, 3000)),
        ?assertEqual([], freshness_fetches([])),
        ?assertMatch({ok, #{identity := Identity, slot := 2}},
                     quod_foreign_log:current(Routes, Identity, 3000)),
        ?assertEqual([], freshness_fetches([])),
        ?assertEqual(PhaseFiles, phase_files(Dir, Identity)),
        assert_retained_entries(Owner, Identity, [Genesis])
    after
        _ = catch erlang:trace(Owner, false, [all]),
        [Link ! close || {_, Link} <- Links],
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
    Fetch = fun(P, E, N, Query, Deadline, Consume) ->
        case atomics:get(Allowed, 1) of
            0 -> Base(P, E, N, Query, Deadline, Consume);
            1 -> error({retained_exact_reference_refetched, Query})
        end
    end,
    Owner = quod_foreign_log_tests:start_owner(Dir, Fetch),
    try
        ?assertMatch({ok, #{slot := 2}}, quod_foreign_log_tests:prime_projection(
            [{Peer, [Endpoint]}], Identity, 2, 3000)),
        {Source, SourceMRef, _View} = quod_foreign_log_tests:start_local_borrow_source(
                                        SourceDir, Fixture),
        try
        PhaseFiles = phase_files(Dir, Identity),
        ?assertEqual(1, length(PhaseFiles)),
        Source ! {hold_capture, self()},
        receive {local_capture_gate_ready, Source} -> ok
        after 1000 -> error(follow_source_gate_not_ready) end,
        1 = erlang:trace(Owner, true, ['receive', {tracer, self()}]),
        {ok, FollowRef} = quod_foreign_log:follow(Identity, projection),
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
        ?assertMatch({ok, #{phase := resolve}}, quod_foreign_log:verify_reference(
            maps:get(ref, Fixture), resolve, {Peer, Endpoint}, 3000)),
        ?assertEqual(PhaseFiles, phase_files(Dir, Identity)),
        assert_retained_entries(Owner, Identity, Prefix),
        ok = quod_foreign_log:unfollow(FollowRef)
        after
            exit(Source, kill),
            _ = erlang:demonitor(SourceMRef, [flush])
        end
    after
        _ = catch sys:resume(Owner),
        _ = catch erlang:trace(Owner, false, [all]),
        quod_foreign_log_tests:stop_owner(Owner),
        _ = file:del_dir_r(SourceDir),
        _ = file:del_dir_r(Dir)
    end.

%% The former two stored-confirmation-bit cases are retired: no such bit is
%% authority now. Exact-height/committee and crossed-progress regressions live
%% in feed_established_current_view_test_; residency is asserted above and below.
resident_failure_only_wakes_waiters_on_real_advance_test_() ->
    [{atom_to_list(Mode), fun() -> resident_failure_wakes(Mode) end}
     || Mode <- [unchanged_prefix, advanced_prefix]].

resident_failure_wakes(Mode) ->
    {Height, Expected} = case Mode of
        unchanged_prefix -> {1, [true, true]};
        advanced_prefix -> {2, []}
    end,
    with_installation_state(Height, fun(Identity, RequestRef, State0, Meta) ->
    Request = maps:get(RequestRef, record_field(s, pending, State0)),
    {exact_reference, Ref, vote, none} = record_field(
        routed_work, kind, record_field(request, work, Request)),
    WorkA = make_record(routed_work, #{kind => {exact_reference, Ref, vote, none}}),
    WorkB = make_record(routed_work, #{kind => {exact_reference, Ref, resolve, none}}),
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
    %% An active writer does not block covered readers. Unchanged prefixes
    %% still cannot grant either unavailable job another route attempt.
    State1 = quod_foreign_log:test_install_verified_progress(RequestRef, Meta, State),
    ?assertEqual(Expected, parked_flags(Identity, State1)),
    case Mode of
        advanced_prefix ->
            lists:foreach(fun(Row) ->
                [{_, Tag}] = maps:keys(record_field(request, callers, Row)),
                receive {Tag, Capability} ->
                    ?assertMatch({ready_reference, _, Ref, _, _}, Capability),
                    Verified = quod_foreign_log_tests:consume_verification_reply(
                                 self(), {reply, Capability}),
                    case record_field(routed_work, kind, record_field(request, work, Row)) of
                        {exact_reference, Ref, vote, none} ->
                            ?assertMatch({reply, {ok, #{phase := vote}}}, Verified);
                        {exact_reference, Ref, resolve, none} ->
                            ?assertMatch({reply, {error, _}}, Verified)
                    end
                after 1000 -> error(published_reader_not_released) end
            end, Rows);
        unchanged_prefix -> ok
    end,
    State2 = quod_foreign_log:test_install_verified_progress(RequestRef, Meta, State1),
    ?assertEqual(Expected, parked_flags(Identity, State2)),
    ?assertEqual(RequestRef, record_field(history, active, state_history(Identity, State2))),
    ?assertEqual(length(Expected), length(queue:to_list(
        record_field(history, waiting, state_history(Identity, State2)))))
    end).

with_installation_state(Height, Fun) ->
    Fixture = quod_foreign_log_tests:prepared_then_committed_fixture(
                quod_foreign_log_tests:unique_ns()),
    quod_ct:with_network_identity(maps:get(network, Fixture), fun() ->
    Ns = maps:get(ns, Fixture), Anchor = maps:get(anchor, Fixture),
    Identity = {Ns, Anchor},
    [Genesis, Vote, _] = maps:get(chain, Fixture),
    PhaseDir = quod_foreign_log_tests:temp_dir("installation-projection"),
    CacheNs = quod_foreign_log:cache_namespace(Identity),
    {ok, PhaseIndex} = quod_dtx_phase_index:open(PhaseDir, CacheNs),
    {ok, Hold} = quod_dtx_phase_index:retain_empty(PhaseIndex),
    {ok, Store0} = quod_ledger_store:open(CacheNs, PhaseDir, wrapped),
    try
        %% Callback-state fixture, not an admitted consensus job. Its read
        %% capability and returned cursor now use real verified disk resources;
        %% resident_verified with no index/snapshot is not a valid state.
        {ok, #{projection := P1, delta := D1, proof := Proof1}} =
            quod_ct:history_group(Identity, Genesis,
                quod_simplex:history_projection(Identity), PhaseIndex),
        {ok, Store1} = quod_ledger_store:append(Store0, {Proof1, [Genesis]}),
        ok = quod_dtx_phase_index:commit_delta(PhaseIndex, D1),
        Snapshot1 = quod_ledger_store:snapshot(Store1),
        {ok, #{projection := P2, delta := D2, proof := Proof2}} =
            quod_ct:history_group(Identity, Vote, P1, PhaseIndex),
        {Projection, Store} = case Height of
            1 -> {P1, Store1};
            2 ->
                {ok, Store2} = quod_ledger_store:append(Store1, {Proof2, [Vote]}),
                ok = quod_dtx_phase_index:commit_delta(PhaseIndex, D2),
                {P2, Store2}
        end,
        {ok, Session} = quod_dtx_phase_index:suspend(PhaseIndex),
        RequestRef = make_ref(),
        Published = make_record(prefix, #{height => 1, projection => P1,
                                          snapshot => Snapshot1, index => Hold}),
        History = make_record(history,
            #{height => 1, projection => P1, resident_verified => false,
              published => Published, active => RequestRef}),
        Request = make_record(request,
            #{identity => Identity, worker => self(), mref => make_ref(),
              work => make_record(routed_work,
                  #{kind => {exact_reference, maps:get(vote_ref, Fixture), vote, none}})}),
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
    end
    end).

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
    quod_ct:with_network_identity(maps:get(network, Fixture, <<202:256>>), fun() ->
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Chain = maps:get(chain, Fixture),
    Prefix = lists:sublist(Chain, PrefixHeight),
    RequestedSlot = length(Chain),
    Ref = case FixtureHeight of
              1 -> maps:get(ref, Fixture);
              2 -> maps:get(resolve_ref, Fixture)
          end,
    Good = {"127.0.0.1", 19000},
    ContactEndpoint = {"127.0.0.1", 29999},
    PrefixFetch = quod_foreign_log_tests:chain_fetch(Ns, Prefix),
    FullFetch = quod_foreign_log_tests:chain_fetch(Ns, Chain),
    Phase = atomics:new(1, []),
    Parent = self(),
    Fetch = fun(P, Endpoint, RequestedNs, Query, Deadline, Consume) ->
        Parent ! {residency_fetch, atomics:get(Phase, 1), Endpoint, Query},
        case {atomics:get(Phase, 1), Endpoint, Mode, Query} of
            {0, Good, _, _} ->
                PrefixFetch(P, Endpoint, RequestedNs, Query, Deadline, Consume);
            {1, ContactEndpoint, transient_fallback, _} -> {error, retry};
            {1, ContactEndpoint, partial_fallback, {evidence, _, _}} ->
                Continuation = {<<70:128>>, 1},
                {ok, Consumed, RequestedSlot, done} = FullFetch(P, Endpoint, RequestedNs, Query,
                    Deadline, fun(Parts, RemoteHeight, done) ->
                        ?assertEqual(RequestedSlot, RemoteHeight),
                        {GenesisParts, [_ | _]} = lists:split(3, Parts),
                        Consume(GenesisParts, RequestedSlot, Continuation)
                    end),
                {ok, Consumed, RequestedSlot, Continuation};
            {1, ContactEndpoint, partial_fallback, {continue, <<70:128>>, 1}} ->
                {error, retry};
            {1, _, _, _} ->
                FullFetch(P, Endpoint, RequestedNs, Query, Deadline, Consume)
        end
    end,
    Dir = quod_foreign_log_tests:temp_dir("verified-cursor"),
    Owner = quod_foreign_log_tests:start_owner(Dir, Fetch),
    MFAs = [{quod_ledger_store, open, 3}, {quod_foreign_log, replay_cache, 7}],
    try
        {module, quod_ledger_store} = code:ensure_loaded(quod_ledger_store),
        [1 = erlang:trace_pattern(MFA, true, [local]) || MFA <- MFAs],
        1 = erlang:trace(Owner, true, [call, set_on_spawn, {tracer, self()}]),
        {ok, #{identity := Identity, slot := PrefixHeight}} =
            quod_foreign_log_tests:prime_projection([{Peer, [Good]}], Identity, PrefixHeight, 5000),
        ?assertMatch(#{resident_verified := 1}, quod_foreign_log:stats()),
        CacheNs = quod_foreign_log:cache_namespace(Identity),
        WarmCalls = cache_calls(CacheNs, drain_calls()),
        %% Positive control: this exact trace observes the real initial full
        %% open. A disabled hook cannot satisfy the subsequent zero-work test.
        ?assertEqual(1, call_count({quod_ledger_store, open, 3}, WarmCalls)),
        ?assertEqual(0, call_count({quod_foreign_log, replay_cache, 7}, WarmCalls)),
        FilesBefore = phase_files(Dir, Identity),
        ?assertEqual(1, length(FilesBefore)),
        _ = drain_fetches(),
        ok = atomics:put(Phase, 1, 1),
        Contact = case Mode of healthy -> {Peer, Good};
                               _ -> {Peer, ContactEndpoint} end,
        ExpectedPhase = case Mode of definitive_fallback -> vote;
                                     _ -> resolve end,
        RootName = <<"test.residency.exact">>,
        Result = quod_trace:with_span(quod_trace:context(), RootName, internal, #{},
            fun(_Span) -> quod_foreign_log:verify_reference(
                             Ref, ExpectedPhase, Contact, 5000) end),
        case Mode of
            definitive_fallback ->
                ?assertEqual({error, phase_mismatch}, Result);
            _ ->
                ?assertMatch({ok, #{identity := Identity, phase := resolve}}, Result)
        end,
        Calls = cache_calls(CacheNs, drain_calls()),
        Fetches = drain_fetches(),
        RootSpan = quod_trace_tests:take_span(RootName),
        Worker = quod_trace_tests:take_span(
                   <<"quod.foreign.verification_worker">>, RootSpan#span.trace_id),
        Attributes = otel_attributes:map(Worker#span.attributes),
        ?assertEqual(0, call_count({quod_ledger_store, open, 3}, Calls)),
        ?assertEqual(0, call_count({quod_foreign_log, replay_cache, 7}, Calls)),
        ?assertEqual(FilesBefore, phase_files(Dir, Identity)),
        ?assertEqual(0, maps:get('quod.foreign.disk_replayed_entries', Attributes)),
        ?assertEqual(0, maps:get('quod.foreign.cold_opens', Attributes)),
        case Mode of
            healthy -> ?assertMatch([{1, Good, {evidence, _, {exact, RequestedSlot, _}}}], Fetches);
            transient_fallback ->
                ?assertMatch([{1, ContactEndpoint, {evidence, _, {exact, RequestedSlot, _}}},
                              {1, Good, {evidence, _, {exact, RequestedSlot, _}}}], Fetches);
            partial_fallback ->
                ?assertMatch([{1, ContactEndpoint, {evidence, _, {exact, RequestedSlot, _}}},
                              {1, ContactEndpoint, {continue, <<70:128>>, 1}},
                              {1, Good, {evidence, _, {exact, RequestedSlot, _}}}], Fetches);
            definitive_fallback ->
                ?assertMatch([{1, ContactEndpoint, {evidence, _, {exact, RequestedSlot, _}}}], Fetches)
        end,
        ?assertMatch(#{resident_verified := 1}, quod_foreign_log:stats()),
        assert_retained_entries(Owner, Identity, Prefix)
    after
        _ = catch erlang:trace(Owner, false, [all]),
        [erlang:trace_pattern(MFA, false, [local]) || MFA <- MFAs],
        quod_foreign_log_tests:stop_owner(Owner),
        _ = file:del_dir_r(Dir)
    end
    end).

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

cache_calls(CacheNs, Calls) ->
    [Call || Call = {_, MFA} <- Calls,
        case MFA of
            {quod_ledger_store, open, [Ns, _, _]} -> Ns =:= CacheNs;
            _ -> true
        end].

call_count({M, F, A}, Calls) ->
    length([ok || {_Pid, {CM, CF, Args}} <- Calls,
                  CM =:= M, CF =:= F, length(Args) =:= A]).

drain_fetches() -> drain_fetches([]).
drain_fetches(Acc) ->
    receive {residency_fetch, Phase, Endpoint, Query} ->
        drain_fetches([{Phase, Endpoint, Query} | Acc])
    after 0 -> lists:reverse(Acc) end.

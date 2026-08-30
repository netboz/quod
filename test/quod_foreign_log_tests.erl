-module(quod_foreign_log_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").
-include("quod_proof_limits.hrl").

-export([identity_current_global_network_dependency_case/0]).

-define(GENESIS_TX_VERSION, 1).
-define(GENESIS_TX_TAG, "quod/genesis").

required_references_is_exhaustive_test() ->
    A = {<<"a">>, key(1)},
    B = {<<"b">>, key(2)},
    BeginA = ref(A, 1, 11),
    PrepareA = ref(A, 2, 12),
    PrepareB = ref(B, 2, 13),
    Decision = ref(A, 3, 14),
    FinalizeA = ref(A, 4, 15),
    FinalizeB = ref(B, 4, 16),
    Target = A,
    ?assertEqual(
       {ok, []},
       quod_foreign_log:required_references(
         control('begin', Target,
                 {quod_dtx_begin, 3, ignored, none, ignored}))),
    ?assertEqual(
       {ok, [{'begin', BeginA}]},
       quod_foreign_log:required_references(
         control(prepare, Target,
                 {quod_dtx_prepare, 3, key(20), BeginA, ignored,
                  key(21), <<>>}))),
    ?assertEqual(
       {ok, [{'begin', BeginA}, {prepare, PrepareA}, {prepare, PrepareB}]},
       quod_foreign_log:required_references(
         control(decision, Target,
                 {quod_dtx_decision, 3, key(20), BeginA, commit,
                  [{A, PrepareA}, {B, PrepareB}], none}))),
    ?assertEqual(
       {ok, [{decision, Decision}, {prepare, PrepareA}]},
       quod_foreign_log:required_references(
         control(finalize, Target,
                 {quod_dtx_finalize, 3, key(20), Decision, commit,
                  PrepareA, 2}))),
    ?assertEqual(
       {ok, [{decision, Decision}]},
       quod_foreign_log:required_references(
         control(finalize, Target,
                 {quod_dtx_finalize, 3, key(20), Decision, abort, none, 1}))),
    ?assertEqual(
       {ok, [{decision, Decision},
             {finalize, FinalizeA}, {finalize, FinalizeB}]},
       quod_foreign_log:required_references(
         control(complete, Target,
                 {quod_dtx_complete, 3, key(20), Decision,
                  [{A, FinalizeA, 2}, {B, FinalizeB, 3}]}))),
    %% A row cannot smuggle a reference for a different anchored identity.
    ?assertEqual(
       {error, invalid_control},
       quod_foreign_log:required_references(
         control(decision, Target,
                 {quod_dtx_decision, 3, key(20), BeginA, commit,
                  [{B, PrepareA}], none}))),
    ?assertEqual(
       {error, invalid_control},
       quod_foreign_log:required_references(
         control(complete, Target,
                 {quod_dtx_complete, 3, key(20), Decision,
                  [{A, FinalizeA, 16#10000000000000000}]}))),
    %% Ingress sees the unsigned canonical record before consensus wraps it;
    %% it must use the same exhaustive reference extractor as validators.
    Fixture = quod_ct:dtx_prepare_fixture(),
    ?assertEqual(
       {ok, [{'begin', maps:get(begin_ref, Fixture)}]},
       quod_foreign_log:required_references(maps:get(prepare, Fixture))).

invalid_public_timeout_is_rejected_without_owner_test() ->
    ?assertEqual(
       {error, bad_foreign_reference},
       quod_foreign_log:verify_reference(
         ref({<<"timeout">>, key(9)}, 1, 10), finalize, invalid)).

resident_projection_reuses_verified_frontier_and_phase_index_test() ->
    Identity = {<<"resident">>, key(8)},
    Committee = [key(9)],
    CommitteeId = key(10),
    Projection = (quod_simplex:history_projection(Identity))#{
                   committee => Committee,
                   committee_id => CommitteeId,
                   committee_views =>
                       [{1, Committee, CommitteeId, #{}}],
                   history_head => {7, key(11)}},
    Checkpoint = maps:remove(committee_views, Projection),
    Resident = {verified, 7, Projection, phase_session},
    ?assertEqual(
       {ok, Projection, Projection},
       quod_foreign_log:test_resident_projection(
         Resident, 7, Checkpoint, 7, Identity)),
    ?assertEqual(
       {ok, Projection, undefined},
       quod_foreign_log:test_resident_projection(
         Resident, 7, Checkpoint, 8, Identity)),
    %% A restart-loaded row or changed durable height must replay.  An exact
    %% historical reference inside this owner's already-certified prefix does
    %% not: the retained entry binds its slot/hash/digest and committee-era
    %% routing metadata comes from this resident projection. An unfinished DTX
    %% group likewise keeps using the phase index suspended with that projection.
    ?assertEqual(
       replay,
       quod_foreign_log:test_resident_projection(
         none, 7, Checkpoint, 7, Identity)),
    ?assertEqual(
       replay,
       quod_foreign_log:test_resident_projection(
         Resident, 8, Checkpoint, 7, Identity)),
    ?assertEqual(
       {ok, Projection, Projection},
       quod_foreign_log:test_resident_projection(
         Resident, 7, Checkpoint, 3, Identity)),
    Pending = Projection#{dtx_pending => {pending, key(99)}},
    ?assertEqual(
       {ok, Pending, undefined},
       quod_foreign_log:test_resident_projection(
         {verified, 7, Pending, phase_session},
         7, maps:remove(committee_views, Pending), 8, Identity)).

dtx_batch_projection_keeps_each_controls_changes_separate_test() ->
    FirstOps = [{assert, {{first_control, one}, true}}],
    SecondOps = [{retract, {{second_control, two}, false}}],
    FirstHeads = [{first_control, one}],
    SecondHeads = [{second_control, two}],
    Result =
        #{kind => dtx_batch,
          items =>
              [#{group_id => key(801), applied_ops => FirstOps,
                 changed_heads => FirstHeads},
               #{group_id => key(802), applied_ops => SecondOps,
                 changed_heads => SecondHeads}]},
    ?assertEqual(
       FirstHeads ++ SecondHeads,
       quod_foreign_projection:test_result_heads(Result)),
    %% A materialized follower emits two ordered occurrences at the shared
    %% block height.  Aggregating the slot's operations would lose which
    %% control produced which publication and permit cross-control leakage.
    ?assertEqual(
       [{9, FirstOps}, {9, SecondOps}],
       quod_foreign_projection:test_result_publications(9, Result)).

warm_exact_and_current_reuse_one_verified_phase_session_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 31980},
    Ref = maps:get(ref, Fixture),
    BaseFetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer]),
    Mode = atomics:new(2, []),
    ok = atomics:put(Mode, 1, 1),
    Fetch =
        fun(P, E, RequestedNs, From, To) ->
            case atomics:get(Mode, 1) of
                1 ->
                    BaseFetch(P, E, RequestedNs, From, To);
                2 ->
                    error({warm_exact_used_network, From});
                3 when From =:= 3 ->
                    _ = atomics:add_get(Mode, 2, 1),
                    BaseFetch(P, E, RequestedNs, From, To);
                3 ->
                    error({warm_current_restarted_fetch, From})
            end
        end,
    Dir = temp_dir("resident-warm-exact-current"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertMatch(
           {ok, #{identity := Identity, phase := finalize}},
           quod_foreign_log:verify(Peer, Endpoint, Ref, finalize, 5000)),
        [SessionFile] = phase_session_files(Dir, Identity),

        %% The exact entry and its post-slot projection are already resident.
        %% A network read or a new phase-index file would prove that the warm
        %% path discarded and rebuilt work it had just verified.
        ok = atomics:put(Mode, 1, 2),
        ?assertMatch(
           {ok, #{identity := Identity, phase := finalize}},
           quod_foreign_log:verify(Peer, Endpoint, Ref, finalize, 5000)),
        ?assertEqual([SessionFile], phase_session_files(Dir, Identity)),

        %% Current-view confirmation still asks the remote committee whether
        %% there is a newer slot, but it must resume the same verified phase
        %% session for both its exact-reference and current-prefix passes.
        ok = atomics:put(Mode, 1, 3),
        ?assertMatch(
           {ok, #{identity := Identity, slot := 2}},
           quod_foreign_log:verify_current(
             route_candidates([{Peer, Endpoint}]), Ref, 5000)),
        ?assert(atomics:get(Mode, 2) > 0),
        ?assertEqual([SessionFile], phase_session_files(Dir, Identity))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

pending_prepare_to_finalize_resumes_phase_history_and_fetches_only_delta_test() ->
    Fixture = prepared_then_committed_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 31981},
    BaseFetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer]),
    Mode = atomics:new(2, []),
    ok = atomics:put(Mode, 1, 1),
    Fetch =
        fun(P, E, RequestedNs, From, To) ->
            case atomics:get(Mode, 1) of
                1 ->
                    BaseFetch(P, E, RequestedNs, From, To);
                2 when From =:= 3 ->
                    _ = atomics:add_get(Mode, 2, 1),
                    BaseFetch(P, E, RequestedNs, From, To);
                2 ->
                    error({finalize_restarted_fetch, From})
            end
        end,
    Dir = temp_dir("resident-pending-finalize"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertMatch(
           {ok, #{identity := Identity, phase := prepare}},
           quod_foreign_log:verify(
             Peer, Endpoint, maps:get(prepare_ref, Fixture),
             prepare, 5000)),
        {2, PrepareProjection} = cache_checkpoint(Dir, Identity),
        %% A participant-side Prepare does not advertise a pending group in
        %% the public projection.  Its exact group history lives only in the
        %% phase index, so accepting the Finalize from slot 3 alone below is
        %% the non-vacuous proof that the suspended index was resumed.
        ?assertEqual(#{}, maps:get(dtx_pending, PrepareProjection)),
        [SessionFile] = phase_session_files(Dir, Identity),

        %% Finalize depends on the exact Prepare history kept in the suspended
        %% phase index.  The second request may fetch only slot 3; fetching
        %% from an earlier slot or replacing the session is a hidden replay.
        ok = atomics:put(Mode, 1, 2),
        ?assertMatch(
           {ok, #{identity := Identity, phase := finalize}},
           quod_foreign_log:verify(
             Peer, Endpoint, maps:get(finalize_ref, Fixture),
             finalize, 5000)),
        ?assertEqual(1, atomics:get(Mode, 2)),
        ?assertEqual([SessionFile], phase_session_files(Dir, Identity)),
        ?assertMatch({3, _}, cache_checkpoint(Dir, Identity))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

worker_down_after_phase_session_transfer_does_not_leave_fake_resident_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 31982},
    BaseFetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer]),
    Crash = atomics:new(1, []),
    Fetch =
        fun(P, E, RequestedNs, From, To) ->
            case atomics:get(Crash, 1) of
                0 -> BaseFetch(P, E, RequestedNs, From, To);
                1 -> error({resident_fetch_crash, From})
            end
        end,
    Dir = temp_dir("resident-worker-down"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertMatch(
           {ok, #{identity := Identity}},
           quod_foreign_log:verify(
             Peer, Endpoint, maps:get(ref, Fixture), finalize, 5000)),
        ?assertMatch(
           #{histories := 1, resident_verified := 1},
           quod_foreign_log:stats()),

        %% Launch transfers the only suspended phase session to the worker.
        %% If that worker dies before returning it, the owner has a durable
        %% cache but no reusable in-memory verification state and must unload
        %% the row.  Keeping `resident_verified=true` here would strand a
        %% history that resident_cache/2 can never actually resume.
        ok = atomics:put(Crash, 1, 1),
        ?assertEqual(
           {error, retry},
           quod_foreign_log:current(
             route_candidates([{Peer, Endpoint}]), Identity, 5000)),
        ?assertMatch(
           #{pending := 0, histories := 0, resident_verified := 0},
           quod_foreign_log:stats())
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

accepted_entry_hint_advances_through_the_one_verified_cache_path_test() ->
    Fixture = prepared_then_committed_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 31983},
    BaseFetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer]),
    NetworkAllowed = atomics:new(1, []),
    Fetch =
        fun(P, E, RequestedNs, From, To) ->
            case atomics:get(NetworkAllowed, 1) of
                1 -> BaseFetch(P, E, RequestedNs, From, To);
                0 -> error({accepted_hint_refetched, From})
            end
        end,
    Dir = temp_dir("accepted-entry-hint"),
    Pid = start_owner(Dir, Fetch),
    try
        ok = atomics:put(NetworkAllowed, 1, 1),
        ?assertMatch(
           {ok, #{identity := Identity, phase := prepare}},
           quod_foreign_log:verify(
             Peer, Endpoint, maps:get(prepare_ref, Fixture),
             prepare, 5000)),
        [SessionFile] = phase_session_files(Dir, Identity),
        FinalizeEntry = lists:last(maps:get(chain, Fixture)),

        %% The response-carried entry is only acceleration material.  It is
        %% accepted here solely because the ordinary history fold validates
        %% it against the cached prefix and the ordinary exact checker binds
        %% it to this Ref and phase before the page is persisted.
        ok = atomics:put(NetworkAllowed, 1, 0),
        ?assertMatch(
           {ok, #{identity := Identity, phase := finalize}},
           quod_foreign_log:verify_reference(
             maps:get(finalize_ref, Fixture), finalize,
             {Peer, Endpoint}, FinalizeEntry, 5000)),
        ?assertEqual([SessionFile], phase_session_files(Dir, Identity)),
        ?assertMatch({3, _}, cache_checkpoint(Dir, Identity))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

bad_accepted_entry_hint_is_inert_and_falls_back_to_certified_fetch_test() ->
    Fixture = prepared_then_committed_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 31984},
    BaseFetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer]),
    Mode = atomics:new(2, []),
    ok = atomics:put(Mode, 1, 1),
    Fetch =
        fun(P, E, RequestedNs, From, To) ->
            case atomics:get(Mode, 1) of
                1 ->
                    BaseFetch(P, E, RequestedNs, From, To);
                2 when From =:= 3 ->
                    _ = atomics:add_get(Mode, 2, 1),
                    BaseFetch(P, E, RequestedNs, From, To);
                2 ->
                    error({bad_hint_restarted_fetch, From})
            end
        end,
    Dir = temp_dir("bad-accepted-entry-hint"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertMatch(
           {ok, #{identity := Identity, phase := prepare}},
           quod_foreign_log:verify(
             Peer, Endpoint, maps:get(prepare_ref, Fixture),
             prepare, 5000)),
        [SessionFile] = phase_session_files(Dir, Identity),
        FinalizeEntry = lists:last(maps:get(chain, Fixture)),
        BadHint = FinalizeEntry#entry{cert = none},

        %% Previewing a bad hint mutates neither the durable cache nor the
        %% phase index.  The same worker therefore continues from slot 2 and
        %% obtains the authoritative slot 3 through its normal source.
        ok = atomics:put(Mode, 1, 2),
        ?assertMatch(
           {ok, #{identity := Identity, phase := finalize}},
           quod_foreign_log:verify_reference(
             maps:get(finalize_ref, Fixture), finalize,
             {Peer, Endpoint}, BadHint, 5000)),
        ?assertEqual(1, atomics:get(Mode, 2)),
        ?assertEqual([SessionFile], phase_session_files(Dir, Identity)),
        ?assertMatch({3, _}, cache_checkpoint(Dir, Identity))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

authenticated_bootstrap_candidates_are_bounded_and_peer_unique_test() ->
    Dir = temp_dir("bootstrap-bounds"),
    Pid = start_owner(
            Dir, fun(_, _, _, _, _) -> {error, unavailable} end),
    Identity = {unique_ns(), key(95)},
    Limit = 2 * ?MAX_VALIDATORS,
    try
        lists:foreach(
          fun(N) ->
              quod_foreign_log:observe_candidate(
                Identity, {key(1000 + N), {"127.0.0.1", 20000 + N}})
          end, lists:seq(1, Limit + 1)),
        Stats1 = quod_foreign_log:stats(),
        ?assertEqual(Limit, maps:get(bootstrap_candidates, Stats1)),
        ?assertEqual(Limit + 1, maps:get(bootstrap_accepted, Stats1)),
        ?assertEqual(1, maps:get(bootstrap_evicted, Stats1)),

        %% Re-observing one authenticated peer replaces its endpoint; it
        %% cannot consume another source slot for the same identity.
        Peer = key(1000 + Limit + 1),
        Replacement = {"127.0.0.1", 29999},
        quod_foreign_log:observe_candidate(Identity, {Peer, Replacement}),
        {ok, Selected} = quod_foreign_log:route_hints(Identity, []),
        ?assert(length(Selected) =< ?MAX_VALIDATORS),
        ?assertEqual(length(Selected),
                     length(lists:usort([K || {K, _} <- Selected]))),
        ?assertEqual([{Peer, [Replacement]}],
                     [Row || Row = {K, _} <- Selected, K =:= Peer]),
        ?assertEqual(Limit,
                     maps:get(bootstrap_candidates,
                              quod_foreign_log:stats()))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

bootstrap_candidates_do_not_impose_a_global_history_cap_test() ->
    Dir = temp_dir("bootstrap-history-unbounded"),
    Pid = start_owner(
            Dir, fun(_, _, _, _, _) -> {error, unavailable} end),
    Count = 96,
    try
        lists:foreach(
          fun(N) ->
              quod_foreign_log:observe_candidate(
                {<<"candidate:", (integer_to_binary(N))/binary>>, key(N)},
                {key(2000 + N), {"127.0.0.1", 30000 + N}})
          end, lists:seq(1, Count)),
        Stats = quod_foreign_log:stats(),
        ?assertEqual(0, maps:get(histories, Stats)),
        ?assertEqual(Count, maps:get(bootstrap_candidates, Stats)),
        ?assertEqual(0, maps:get(bootstrap_rejected, Stats))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

inactive_history_is_hibernated_and_reopened_from_verified_cache_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 31990},
    Ref = maps:get(ref, Fixture),
    Fetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer]),
    Dir = temp_dir("lazy-history"),
    Pid1 = start_owner(Dir, Fetch),
    try
        %% Exact verification writes a certified cache and retains only its
        %% bounded owner-verified projection for later calls in this VM.
        ?assertMatch(
           {ok, #{identity := Identity, phase := finalize}},
           quod_foreign_log:verify(Peer, Endpoint, Ref, finalize, 5000)),
        ?assertEqual(1, maps:get(histories, quod_foreign_log:stats())),
        ?assertEqual(1, maps:get(resident_verified,
                                quod_foreign_log:stats())),
        ?assertEqual(0, maps:get(channels, quod_foreign_log:stats())),
        stop_owner(Pid1),

        %% Restart does not scan or materialize dormant caches. The next
        %% ordinary verification opens the exact cache on demand and uses its
        %% certified route without any caller-supplied route.
        Pid2 = start_owner(Dir, Fetch),
        try
            ?assertEqual(0, maps:get(histories, quod_foreign_log:stats())),
            ?assertMatch(
               {ok, #{identity := Identity, phase := finalize}},
               quod_foreign_log:verify_reference(Ref, finalize, 5000)),
            ?assertEqual(1, maps:get(histories, quod_foreign_log:stats())),
            ?assertEqual(1, maps:get(resident_verified,
                                    quod_foreign_log:stats())),
            ?assertEqual(0, maps:get(channels, quod_foreign_log:stats()))
        after
            stop_owner(Pid2)
        end
    after
        _ = file:del_dir_r(Dir)
    end.

byte_large_verified_cache_reopens_through_canonical_pages_test() ->
    Fixture = byte_large_foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 31991},
    Ref = maps:get(ref, Fixture),
    SourceDir = temp_dir("byte-large-source"),
    CacheDir = temp_dir("byte-large-cache"),
    {ok, Store0} = quod_ledger_store:open(Ns, SourceDir),
    {ok, Store1} = quod_ledger_store:append(
                     Store0, maps:get(chain, Fixture)),
    ok = quod_ledger_store:close(Store1),
    Fetch =
        fun(_RoutePeer, _RouteEndpoint, RequestedNs, From, To)
              when RequestedNs =:= Ns ->
                quod_catchup:serve_blocks(Ns, SourceDir, From, To);
           (_RoutePeer, _RouteEndpoint, _RequestedNs, _From, _To) ->
                {error, wrong_namespace}
        end,
    Pid1 = start_owner(CacheDir, Fetch),
    try
        ?assertMatch(
           {ok, #{identity := Identity}},
           quod_foreign_log:current(
             [{Peer, [Endpoint]}], Identity, 5000)),
        %% One current-view job advances every certified page to the captured
        %% source height. A later call reuses that completed cache.
        ?assertMatch(
           {ok, #{identity := Identity}},
           quod_foreign_log:current(
             [{Peer, [Endpoint]}], Identity, 5000)),
        ?assertEqual(1, maps:get(histories, quod_foreign_log:stats()))
    after
        stop_owner(Pid1)
    end,
    %% The cache exceeds one certified page even though every source response
    %% and every individual block is valid. Reopening must replay the same
    %% byte-bounded page shape rather than treating a count-bounded read as one
    %% oversized network page.
    CacheNs = quod_foreign_log:cache_namespace(Identity),
    CacheLog = filename:join(
                 quod_ledger_store:ns_dir(CacheDir, CacheNs), "log.0001"),
    ?assert(filelib:file_size(CacheLog) > ?QUOD_MAX_FOREIGN_PAGE_BYTES),
    NoFetch = fun(_, _, _, _, _) -> {error, network_used} end,
    Pid2 = start_owner(CacheDir, NoFetch),
    try
        ?assertMatch(
           {ok, #{identity := Identity, phase := finalize}},
           quod_foreign_log:verify_reference(Ref, finalize, 5000))
    after
        stop_owner(Pid2),
        _ = file:del_dir_r(SourceDir),
        _ = file:del_dir_r(CacheDir)
    end.

one_peer_can_introduce_many_dormant_bootstrap_identities_test() ->
    Dir = temp_dir("bootstrap-peer-identities"),
    Pid = start_owner(
            Dir, fun(_, _, _, _, _) -> {error, unavailable} end),
    Peer = key(97),
    OtherPeer = key(98),
    try
        lists:foreach(
          fun(N) ->
              quod_foreign_log:observe_candidate(
                {<<"peer-cap:", (integer_to_binary(N))/binary>>, key(N)},
                {Peer, {"127.0.0.1", 31000 + N}})
          end, lists:seq(1, ?DIRECTORY_MAX_NAMESPACES + 1)),
        OtherIdentity = {<<"peer-cap:other">>, key(999)},
        quod_foreign_log:observe_candidate(
          OtherIdentity, {OtherPeer, {"127.0.0.1", 31999}}),
        Stats = quod_foreign_log:stats(),
        ?assertEqual(0,
                     maps:get(histories, Stats)),
        ?assertEqual(?DIRECTORY_MAX_NAMESPACES + 2,
                     maps:get(bootstrap_candidates, Stats)),
        ?assertEqual(0, maps:get(bootstrap_rejected, Stats)),
        ?assertMatch({ok, [{OtherPeer, [_]}]},
                     quod_foreign_log:route_hints(OtherIdentity, []))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

verify_reference_uses_authenticated_candidate_and_route_failover_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Dir = temp_dir("candidate-verify"),
    Identity = {maps:get(ns, Fixture), maps:get(anchor, Fixture)},
    GoodPeer = maps:get(pub, Fixture),
    BadPeer = key(96),
    GoodEndpoint = {"127.0.0.1", 19096},
    BadEndpoint = {"127.0.0.1", 19097},
    Fetch = peer_chain_fetch(
              maps:get(ns, Fixture), maps:get(chain, Fixture), [GoodPeer]),
    Pid = start_owner(Dir, Fetch),
    try
        quod_foreign_log:observe_candidate(
          Identity, {GoodPeer, GoodEndpoint}),
        %% Newest candidate is tried first, so this unavailable route proves
        %% exact verification fails over within the one shared selector.
        quod_foreign_log:observe_candidate(
          Identity, {BadPeer, BadEndpoint}),
        ?assertMatch(
           {ok, #{identity := Identity, phase := finalize}},
           quod_foreign_log:verify_reference(
             maps:get(ref, Fixture), finalize, 5000)),
        %% Once certified history is installed, its committee routes replace
        %% the temporary contacts instead of retaining stale guesses behind it.
        ?assertEqual(
           0, maps:get(bootstrap_candidates, quod_foreign_log:stats()))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

verify_reference_uses_request_contact_without_pre_observation_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Dir = temp_dir("request-contact-verify"),
    Identity = {maps:get(ns, Fixture), maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 19098},
    Fetch = peer_chain_fetch(
              maps:get(ns, Fixture), maps:get(chain, Fixture), [Peer]),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertMatch(
           {ok, #{identity := Identity, phase := finalize}},
           quod_foreign_log:verify_reference(
             maps:get(ref, Fixture), finalize,
             {Peer, Endpoint}, 5000)),
        %% The request contact enabled the exact verification without first
        %% becoming a bootstrap hint. Certified history is the only retained
        %% result.
        ?assertMatch(
           #{histories := 1, bootstrap_candidates := 0},
           quod_foreign_log:stats())
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

authenticated_live_endpoint_precedes_certified_history_with_fallback_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Ref = maps:get(ref, Fixture),
    Historical = {"127.0.0.1", 19000},
    Live = {"127.0.0.1", 19990},
    Supplied = {"127.0.0.1", 19991},
    TestPid = self(),
    BaseFetch = chain_fetch(Ns, maps:get(chain, Fixture)),
    Fetch = fun(P, Endpoint, RequestedNs, From, To) ->
                    TestPid ! {route_rotation_fetch, Endpoint, From},
                    case Endpoint of
                        Live -> {error, retry};
                        Historical ->
                            BaseFetch(P, Endpoint, RequestedNs, From, To);
                        _ -> {error, wrong_route}
                    end
            end,
    Dir = temp_dir("authenticated-live-fallback"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertMatch(
           {ok, _},
           quod_foreign_log:verify(
             Peer, Historical, Ref, finalize, 5000)),
        %% A caller-supplied address never displaces certified history.
        ?assertEqual(
           {ok, [{Peer, [Historical]}]},
           quod_foreign_log:route_hints(Identity, [{Peer, Supplied}])),
        %% Learning the already-certified address does not manufacture a
        %% second attempt for the same peer.
        quod_foreign_log:observe_candidate(Identity, {Peer, Historical}),
        ?assertEqual(
           {ok, [{Peer, [Historical]}]},
           quod_foreign_log:route_hints(Identity, [])),
        %% A contact learned from the peer itself is fresher reachability, but
        %% the certified address remains the same-key fallback.
        quod_foreign_log:observe_candidate(Identity, {Peer, Live}),
        ?assertEqual(
           {ok, [{Peer, [Live, Historical]}]},
           quod_foreign_log:route_hints(Identity, [])),
        ?assertMatch(
           {ok, #{identity := Identity}},
           quod_foreign_log:verify_current(
             [{Peer, [Live, Historical]}], Ref, 5000)),
        Calls = collect_route_rotation_fetches([]),
        ?assert(lists:member(Live, Calls)),
        ?assert(lists:member(Historical, Calls))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

cross_key_live_endpoint_cannot_displace_certified_fallback_test() ->
    Fixture = membership_after_finalize_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Old = maps:get(pub, Fixture),
    New = maps:get(new_pub, Fixture),
    Ref = maps:get(ref, Fixture),
    OldEndpoint = {"127.0.0.1", 19000},
    NewEndpoint = {"127.0.0.1", 19101},
    Initial = route_candidates(
                [{Old, OldEndpoint}, {New, NewEndpoint}]),
    BaseFetch = chain_fetch(Ns, maps:get(chain, Fixture)),
    TestPid = self(),
    Fetch = fun(Peer, Endpoint, RequestedNs, From, To) ->
                    TestPid ! {cross_key_fetch, Peer, Endpoint},
                    case {Peer, Endpoint} of
                        {Old, OldEndpoint} ->
                            BaseFetch(Peer, Endpoint, RequestedNs, From, To);
                        {New, NewEndpoint} ->
                            BaseFetch(Peer, Endpoint, RequestedNs, From, To);
                        _ ->
                            {error, tls_identity_mismatch}
                    end
            end,
    Dir = temp_dir("cross-key-live-route"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertMatch(
           {ok, #{committee := [_, _]}},
           quod_foreign_log:verify_current(Initial, Ref, 5000)),
        %% A live hint may be stale or wrongly associated. It is tried only
        %% under Old's key and cannot remove Old's certified address.
        quod_foreign_log:observe_candidate(
          Identity, {Old, NewEndpoint}),
        {ok, Candidates} = quod_foreign_log:route_hints(Identity, []),
        ?assertEqual(
           [NewEndpoint, OldEndpoint],
           proplists:get_value(Old, Candidates)),
        ?assertEqual(
           [NewEndpoint],
           proplists:get_value(New, Candidates)),
        ?assertMatch(
           {ok, #{committee := [_, _]}},
           quod_foreign_log:verify_current(Candidates, Ref, 5000)),
        Calls = collect_cross_key_fetches([]),
        ?assert(lists:member({Old, NewEndpoint}, Calls)),
        ?assert(lists:member({Old, OldEndpoint}, Calls))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

collect_cross_key_fetches(Acc) ->
    receive
        {cross_key_fetch, Peer, Endpoint} ->
            collect_cross_key_fetches([{Peer, Endpoint} | Acc])
    after 0 ->
        lists:reverse(Acc)
    end.

collect_route_rotation_fetches(Acc) ->
    receive
        {route_rotation_fetch, Endpoint, _From} ->
            collect_route_rotation_fetches([Endpoint | Acc])
    after 0 ->
        lists:reverse(Acc)
    end.

bootstrap_hints_preserve_current_committee_contacts_test() ->
    Fixture = membership_after_finalize_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Old = maps:get(pub, Fixture),
    New = maps:get(new_pub, Fixture),
    Ref = maps:get(ref, Fixture),
    OldHistorical = {"127.0.0.1", 19000},
    NewHistorical = {"127.0.0.1", 19101},
    OldLive = {"127.0.0.1", 19980},
    NewLive = {"127.0.0.1", 19981},
    Dir = temp_dir("bootstrap-protected-eviction"),
    Pid = start_owner(
            Dir, peer_chain_fetch(
                   Ns, maps:get(chain, Fixture), [Old, New])),
    try
        ?assertMatch(
           {ok, #{committee := [_, _]}},
           quod_foreign_log:verify_current(
             route_candidates(
               [{Old, OldHistorical}, {New, NewHistorical}]),
             Ref, 5000)),
        quod_foreign_log:observe_candidate(Identity, {Old, OldLive}),
        quod_foreign_log:observe_candidate(Identity, {New, NewLive}),
        lists:foreach(
          fun(N) ->
              quod_foreign_log:observe_candidate(
                Identity,
                {key(3000 + N), {"127.0.0.1", 22000 + N}})
          end, lists:seq(1, 2 * ?MAX_VALIDATORS)),
        {ok, Candidates} = quod_foreign_log:route_hints(Identity, []),
        ?assertEqual(
           [OldLive, OldHistorical],
           proplists:get_value(Old, Candidates)),
        ?assertEqual(
           [NewLive, NewHistorical],
           proplists:get_value(New, Candidates)),
        ?assertEqual(
           lists:sort([Old, New]),
           lists:sort([Key || {Key, _Endpoints} <- Candidates])),
        Stats = quod_foreign_log:stats(),
        ?assertEqual(2 * ?MAX_VALIDATORS,
                     maps:get(bootstrap_candidates, Stats)),
        ?assertEqual(2, maps:get(bootstrap_evicted, Stats))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

foreign_log_start_removes_only_disposable_projection_state_test() ->
    Dir = temp_dir("projection-start-cleanup"),
    ProjectionDir = filename:join([Dir, "projections", "stale-generation"]),
    Marker = filename:join(ProjectionDir, "outcome.dets"),
    ok = filelib:ensure_dir(Marker),
    ok = file:write_file(Marker, <<"derived">>),
    Pid = start_owner(Dir, fun(_, _, _, _, _) -> {error, unavailable} end),
    try
        ?assertNot(filelib:is_dir(filename:join(Dir, "projections")))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

slow_follow_consumer_coalesces_live_occurrences_to_state_only_test() ->
    Projection1 = key(103),
    Projection2 = key(104),
    Freshness = #{committee_id => key(105)},
    First = {advanced, 7, 8, Projection1, Freshness,
             [{changed, one}],
             [{8, [{assert, {{remote_ping, one}, {[], false}}}]}]},
    Second = {advanced, 8, 9, Projection2, Freshness,
              [{changed, two}],
              [{9, [{assert, {{remote_ping, two}, {[], false}}}]}]},
    %% Once a consumer has missed an acknowledgement boundary, the cache is
    %% still authoritative for current P but the occurrences are no longer a
    %% replay-safe E stream. The next notice therefore carries no history.
    ?assertEqual(
       {resnapshot, 9, Projection2, Freshness},
       quod_foreign_log:test_coalesce_notice(First, Second)),
    ?assertEqual(
       {resnapshot, 10, Projection2, Freshness},
       quod_foreign_log:test_coalesce_notice(
         {resnapshot, 9, Projection1, Freshness},
         {advanced, 9, 10, Projection2, Freshness, [],
          [{10, [{retract, {{remote_ping, one}, {[], false}}}]}]})).

follow_progress_is_message_driven_and_cleanup_is_exact_test() ->
    Dir = temp_dir("follow-lifecycle"),
    NoFetch = fun(_, _, _, _, _) -> {error, unavailable} end,
    Pid = start_owner_opts(Dir, NoFetch, #{}),
    Identity = {unique_ns(), key(101)},
    try
        {ok, Follow1} = quod_foreign_log:follow(Identity),
        Notice1 = receive_follow(Follow1, Identity),
        ?assertMatch({building, 0}, element(2, Notice1)),
        ok = quod_foreign_log:ack(Follow1, element(1, Notice1)),
        Unreachable1 = receive_follow(Follow1, Identity),
        ?assertMatch({unreachable, unavailable, 0}, element(2, Unreachable1)),
        ok = quod_foreign_log:ack(Follow1, element(1, Unreachable1)),
        FollowStats = quod_foreign_log:stats(),
        ?assertMatch(#{follow_unreachable := 1}, FollowStats),
        ?assertEqual(1, maps:get(follow_wakes, FollowStats)),

        %% An exact directory event wakes the parked verifier immediately.
        %% There is no retry timer between these two attempts.
        Pid ! {directory_route_available, Identity},
        Unreachable2 = receive_follow(Follow1, Identity),
        ?assertMatch({unreachable, unavailable, 0}, element(2, Unreachable2)),
        ok = quod_foreign_log:ack(Follow1, element(1, Unreachable2)),
        ?assertEqual(2, maps:get(follow_wakes, quod_foreign_log:stats())),

        %% A TLS-authenticated but uncertified peer cannot spend work merely
        %% by naming the same feed channel.  Generic block/digest freshness
        %% is accepted only from this exact identity's certified committee.
        Ns = element(1, Identity),
        FeedChan = quod_feed:channel(Ns),
        FeedWake = term_to_binary({feed, Ns, <<0, 1, 2>>}),
        Pid ! {quod_message, {key(77), self()}, FeedChan, FeedWake},
        ?assertEqual(2, maps:get(follow_wakes, quod_foreign_log:stats())),

        %% A co-hosted commit does not need to leave this Erlang node and come
        %% back through Brahms to wake the same certified follower.  The local
        %% commit is still only a freshness edge; the failed certified fetch
        %% below proves the entry was not consumed as trusted evidence.
        _ = quod_reg:publish(
              {committed, Ns},
              {committed, Ns, 1, #entry{index = 1, data = noop}}),
        Unreachable4 = receive_follow(Follow1, Identity),
        ?assertMatch({unreachable, unavailable, 0}, element(2, Unreachable4)),
        ok = quod_foreign_log:ack(Follow1, element(1, Unreachable4)),
        ?assertEqual(3, maps:get(follow_wakes, quod_foreign_log:stats())),

        {ok, Follow2} = quod_foreign_log:follow(Identity),
        Notice2 = receive_follow(Follow2, Identity),
        ?assertMatch({building, 0}, element(2, Notice2)),
        ok = quod_foreign_log:ack(Follow2, element(1, Notice2)),
        ?assertMatch(
           #{histories := 1, followed_histories := 1,
             follow_consumers := 2}, quod_foreign_log:stats()),

        ok = quod_foreign_log:unfollow(Follow1),
        ?assertEqual(1, maps:get(follow_consumers, quod_foreign_log:stats())),
        ok = quod_foreign_log:unfollow(Follow2),
        ?assertMatch(
           #{histories := 0, followed_histories := 0,
             follow_consumers := 0, projection_workers := 0},
           quod_foreign_log:stats())
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

root_readiness_resumes_parked_projection_without_polling_test() ->
    Fixture = signed_content_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Network = maps:get(network, Fixture),
    Endpoint = {"127.0.0.1", 31980},
    SavedDesired = application:get_env(quod, namespace_desired),
    SavedStatic = application:get_env(quod, namespace_static_content),
    RootNs = quod_ontology:root_ns(),
    application:set_env(
      quod, namespace_desired,
      #{content => #{RootNs => #{genesis_hash => Network}}, brahms => #{}}),
    application:set_env(quod, namespace_static_content, #{}),
    Dir = temp_dir("root-ready-projection-wake"),
    Pid = start_owner(
            Dir, peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer])),
    try
        %% First verify and retain the certified history while Root is ready.
        %% The regression concerns only its separately rebuilt P projection.
        ?assertMatch(
           {ok, #{identity := Identity}},
           quod_foreign_log:current(
             route_candidates([{Peer, Endpoint}]), Identity, 5000)),
        application:set_env(
          quod, namespace_desired, #{content => #{}, brahms => #{}}),
        ok = quod_foreign_log:observe_candidate(Identity, {Peer, Endpoint}),
        {ok, FollowRef} = quod_foreign_log:follow(Identity),
        Initial = receive_follow(FollowRef, Identity),
        ?assertMatch({building, 0}, element(2, Initial)),
        ok = quod_foreign_log:ack(FollowRef, element(1, Initial)),

        %% The certified cache reaches the signed entry, but its projection
        %% cannot validate that entry until Root supplies the network anchor.
        Waiting = receive_follow(FollowRef, Identity),
        ?assertMatch({building, _}, element(2, Waiting)),
        ?assertMatch(
           #{follow_building := 1, follow_unreachable := 0},
           quod_foreign_log:stats()),

        Desired0 = application:get_env(quod, namespace_desired, #{}),
        Content0 = maps:get(content, Desired0, #{}),
        application:set_env(
          quod, namespace_desired,
          Desired0#{content =>
                        Content0#{RootNs => #{genesis_hash => Network}}}),
        _ = quod_reg:publish(
              {runtime, RootNs}, {replay_ready, boot, 1}),
        ok = quod_foreign_log:ack(FollowRef, element(1, Waiting)),
        Ready = receive_follow_resnapshot(FollowRef, Identity),
        ?assertMatch({resnapshot, 2, _, _}, element(2, Ready)),
        ok = quod_foreign_log:ack(FollowRef, element(1, Ready)),
        ?assertMatch(
           #{follow_building := 0, follow_unreachable := 0},
           quod_foreign_log:stats()),
        ok = quod_foreign_log:unfollow(FollowRef)
    after
        stop_owner(Pid),
        restore_application_env(namespace_desired, SavedDesired),
        restore_application_env(namespace_static_content, SavedStatic),
        _ = file:del_dir_r(Dir)
    end.

directory_renewal_does_not_probe_a_reachable_follow_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 31979},
    BaseFetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer]),
    FetchCalls = atomics:new(1, []),
    Fetch =
        fun(P, E, RequestedNs, From, To) ->
            _ = atomics:add_get(FetchCalls, 1, 1),
            BaseFetch(P, E, RequestedNs, From, To)
        end,
    Dir = temp_dir("reachable-follow-directory-renewal"),
    Pid = start_owner(Dir, Fetch),
    try
        ok = quod_foreign_log:observe_candidate(Identity, {Peer, Endpoint}),
        {ok, FollowRef} = quod_foreign_log:follow(Identity),
        Building = receive_follow(FollowRef, Identity),
        ok = quod_foreign_log:ack(FollowRef, element(1, Building)),
        Ready = receive_follow_resnapshot(FollowRef, Identity),
        ok = quod_foreign_log:ack(FollowRef, element(1, Ready)),
        Before = quod_foreign_log:stats(),
        ?assertEqual(0, maps:get(follow_unreachable, Before)),
        Wakes = maps:get(follow_wakes, Before),
        Calls = atomics:get(FetchCalls, 1),

        %% The signed lease is useful for route/link reconciliation, but an
        %% already-reachable certified follower waits for feed/commit progress.
        %% It must not turn the lease cadence into a periodic history pull.
        Pid ! {directory_route_available, Identity},
        After = quod_foreign_log:stats(),
        ?assertEqual(Wakes, maps:get(follow_wakes, After)),
        ?assertEqual(Calls, atomics:get(FetchCalls, 1)),
        ok = quod_foreign_log:unfollow(FollowRef),
        ok = wait_follow_count(0, 2000)
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

feed_progress_is_correlated_to_each_anchored_committee_test() ->
    Dir = temp_dir("feed-progress-committee-correlation"),
    NoFetch = fun(_, _, _, _, _) -> {error, unavailable} end,
    Pid = start_owner_opts(Dir, NoFetch, #{}),
    Ns = unique_ns(),
    Fixture1 = fixture_base(Ns),
    Fixture2 = fixture_base(Ns),
    Peer1 = maps:get(pub, Fixture1),
    Peer2 = maps:get(pub, Fixture2),
    Identity1 = {Ns, maps:get(anchor, Fixture1)},
    Identity2 = {Ns, maps:get(anchor, Fixture2)},
    Projection1 = quod_simplex:history_advance(
                    Ns, maps:get(genesis, Fixture1),
                    quod_simplex:history_projection(Identity1)),
    Projection2 = quod_simplex:history_advance(
                    Ns, maps:get(genesis, Fixture2),
                    quod_simplex:history_projection(Identity2)),
    try
        {ok, Follow1} = quod_foreign_log:follow(Identity1),
        Building1 = receive_follow(Follow1, Identity1),
        ok = quod_foreign_log:ack(Follow1, element(1, Building1)),
        Unreachable1 = receive_follow(Follow1, Identity1),
        ok = quod_foreign_log:ack(Follow1, element(1, Unreachable1)),
        {ok, Follow2} = quod_foreign_log:follow(Identity2),
        Building2 = receive_follow(Follow2, Identity2),
        ok = quod_foreign_log:ack(Follow2, element(1, Building2)),
        Unreachable2 = receive_follow(Follow2, Identity2),
        ok = quod_foreign_log:ack(Follow2, element(1, Unreachable2)),
        ok = quod_foreign_log:test_install_feed_projection(
               Pid, Identity1, Projection1),
        ok = quod_foreign_log:test_install_feed_projection(
               Pid, Identity2, Projection2),
        Wakes0 = maps:get(follow_wakes, quod_foreign_log:stats()),
        FeedChan = quod_feed:channel(Ns),
        Digest = quod_feed:encode(Ns, {digest, 2}),

        %% Any authenticated outsider is inert, even with a valid feed shape.
        Pid ! {quod_message, {key(32030), self()}, FeedChan, Digest},
        ?assertEqual(Wakes0,
                     maps:get(follow_wakes, quod_foreign_log:stats())),

        %% The same namespace can identify distinct anchored histories. Peer1
        %% is certified only by Identity1, so its digest wakes exactly that
        %% follower and cannot spend work for Identity2.
        Pid ! {quod_message, {Peer1, self()}, FeedChan, Digest},
        Woken1 = receive_follow(Follow1, Identity1),
        ok = quod_foreign_log:ack(Follow1, element(1, Woken1)),
        ?assertEqual(Wakes0 + 1,
                     maps:get(follow_wakes, quod_foreign_log:stats())),
        receive
            {quod_foreign_follow, Follow2, _, Identity2, _} ->
                error(wrong_anchor_feed_woke_follower)
        after 0 ->
            ok
        end,

        %% Identity2's own certified peer independently wakes it.
        Pid ! {quod_message, {Peer2, self()}, FeedChan, Digest},
        Woken2 = receive_follow(Follow2, Identity2),
        ok = quod_foreign_log:ack(Follow2, element(1, Woken2)),
        ?assertEqual(Wakes0 + 2,
                     maps:get(follow_wakes, quod_foreign_log:stats())),
        ok = quod_foreign_log:unfollow(Follow1),
        ok = quod_foreign_log:unfollow(Follow2)
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

feed_recipient_wake_is_exactly_correlated_and_interest_owned_test() ->
    Dir = temp_dir("feed-recipient-source"),
    TestPid = self(),
    Fetch =
        fun(_, _, _, _, _) ->
            TestPid ! {feed_recipient_fetch_waiting, self()},
            receive
                release_feed_recipient_fetch -> {error, unavailable}
            end
        end,
    Pid = start_owner_opts(Dir, Fetch, #{}),
    Ns = unique_ns(),
    Anchor = key(32010),
    Identity = {Ns, Anchor},
    Peer = key(32011),
    RegistrationId = binary:part(key(32012), 0, 16),
    WrongRegistrationId = binary:part(key(32013), 0, 16),
    Link = spawn(fun() -> fake_feed_link(TestPid) end),
    try
        ok = quod_foreign_log:observe_candidate(
               Identity, {Peer, {"127.0.0.1", 32010}}),
        {ok, Follow1} = quod_foreign_log:follow(Identity),
        Building1 = receive_follow(Follow1, Identity),
        ok = quod_foreign_log:ack(Follow1, element(1, Building1)),
        _BlockedWorker = receive
                             {feed_recipient_fetch_waiting, Worker} -> Worker
                         after 1000 ->
                             error(initial_follow_did_not_start)
                         end,
        Wakes0 = maps:get(follow_wakes, quod_foreign_log:stats()),

        %% Install the post-handshake state directly: transport opening is
        %% covered by QUIC tests, while this test owns the source correlation
        %% boundary.  A crossed generation must neither ACK nor wake work.
        ok = quod_foreign_log:test_install_feed_registration(
               Pid, Identity, Peer, Link, RegistrationId),
        Wrong = quod_feed:encode(
                  Ns,
                  {recipient_registered, 1,
                   WrongRegistrationId, Anchor, 7}),
        Pid ! {quod_message, {Peer, Link}, quod_feed:channel(Ns), Wrong},
        ?assertEqual(Wakes0,
                     maps:get(follow_wakes, quod_foreign_log:stats())),
        ?assertNot(receive_fake_feed_send(Link, 0)),

        %% The exact registration response both closes the open/register race
        %% and wakes the one existing certified follower.  Its height is only
        %% acknowledged freshness; the still-blocked certified fetch proves
        %% it was not applied as history evidence.
        Registered = quod_feed:encode(
                       Ns,
                       {recipient_registered, 1,
                        RegistrationId, Anchor, 7}),
        Pid ! {quod_message, {Peer, Link}, quod_feed:channel(Ns), Registered},
        Ack7 = receive_fake_feed_send(Link, 1000),
        ?assertMatch(
           {ack, RegistrationId, Anchor, 7},
           quod_feed:decode_recipient(Ack7, Ns)),

        Wake8 = quod_feed:encode(
                  Ns,
                  {recipient_wake, 1, RegistrationId, Anchor, 8}),
        Pid ! {quod_message, {Peer, Link}, quod_feed:channel(Ns), Wake8},
        Ack8 = receive_fake_feed_send(Link, 1000),
        ?assertMatch(
           {ack, RegistrationId, Anchor, 8},
           quod_feed:decode_recipient(Ack8, Ns)),
        %% The second edge is coalesced into the already-running certified
        %% job; acknowledgements never create parallel history work.
        ?assertEqual(Wakes0,
                     maps:get(follow_wakes, quod_foreign_log:stats())),

        %% One registration belongs to the anchored identity, not to an
        %% individual consumer.  It survives the first detach and is removed
        %% exactly when the last interest disappears.
        {ok, Follow2} = quod_foreign_log:follow(Identity),
        Building2 = receive_follow(Follow2, Identity),
        ok = quod_foreign_log:ack(Follow2, element(1, Building2)),
        ok = quod_foreign_log:unfollow(Follow1),
        ?assertEqual(1,
                     maps:get(feed_registrations,
                              quod_foreign_log:stats())),
        ok = quod_foreign_log:unfollow(Follow2),
        Unregister = receive_fake_feed_send(Link, 1000),
        ?assertMatch(
           {unregister, RegistrationId, Anchor},
           quod_feed:decode_recipient(Unregister, Ns)),
        receive
            {fake_feed_link_closed, Link} -> ok
        after 1000 ->
            error(feed_registration_link_not_closed)
        end,
        ?assertEqual(0,
                     maps:get(feed_registrations,
                              quod_foreign_log:stats()))
    after
        Link ! close,
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

feed_registration_crossed_link_reply_preserves_opening_test() ->
    Dir = temp_dir("feed-registration-crossed-open"),
    NoFetch = fun(_, _, _, _, _) -> {error, unavailable} end,
    Pid = start_owner_opts(Dir, NoFetch, #{}),
    TestPid = self(),
    Ns = unique_ns(),
    Anchor = key(32020),
    Identity = {Ns, Anchor},
    Peer = key(32021),
    WrongPeer = key(32022),
    RegistrationId = binary:part(key(32023), 0, 16),
    OpenRef = make_ref(),
    Chan = quod_feed:channel(Ns),
    WrongPeerLink = spawn(fun() -> fake_feed_link(TestPid) end),
    WrongChannelLink = spawn(fun() -> fake_feed_link(TestPid) end),
    ExactLink = spawn(fun() -> fake_feed_link(TestPid) end),
    try
        ok = quod_foreign_log:test_install_feed_opening(
               Pid, Identity, Peer, RegistrationId, OpenRef),

        %% A crossed reply must close only the unrelated link.  In
        %% particular it must not consume the real opening: the exact reply
        %% below still has to install the link and send its registration.
        Pid ! {link_up, OpenRef, WrongPeer, Chan, WrongPeerLink},
        receive
            {fake_feed_link_closed, WrongPeerLink} -> ok
        after 1000 ->
            error(crossed_peer_link_not_closed)
        end,
        Pid ! {link_up, OpenRef, Peer, <<"wrong-channel">>,
               WrongChannelLink},
        receive
            {fake_feed_link_closed, WrongChannelLink} -> ok
        after 1000 ->
            error(crossed_channel_link_not_closed)
        end,

        Pid ! {link_up, OpenRef, Peer, Chan, ExactLink},
        Register = receive_fake_feed_send(ExactLink, 1000),
        ?assertMatch(
           {register, RegistrationId, Anchor},
           quod_feed:decode_recipient(Register, Ns))
    after
        WrongPeerLink ! close,
        WrongChannelLink ! close,
        ExactLink ! close,
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

local_commit_progress_subscription_is_namespace_refcounted_test() ->
    Dir = temp_dir("local-commit-refcount"),
    NoFetch = fun(_, _, _, _, _) -> {error, unavailable} end,
    Pid = start_owner_opts(Dir, NoFetch, #{}),
    Ns = unique_ns(),
    Identity1 = {Ns, key(121)},
    Identity2 = {Ns, key(122)},
    try
        {ok, Follow1} = quod_foreign_log:follow(Identity1),
        Building1 = receive_follow(Follow1, Identity1),
        ok = quod_foreign_log:ack(Follow1, element(1, Building1)),
        Unreachable1 = receive_follow(Follow1, Identity1),
        ok = quod_foreign_log:ack(Follow1, element(1, Unreachable1)),

        {ok, Follow2} = quod_foreign_log:follow(Identity2),
        Building2 = receive_follow(Follow2, Identity2),
        ok = quod_foreign_log:ack(Follow2, element(1, Building2)),
        Unreachable2 = receive_follow(Follow2, Identity2),
        ok = quod_foreign_log:ack(Follow2, element(1, Unreachable2)),

        %% Releasing one anchored identity must retain the one per-namespace
        %% subscription needed by the other identity.
        ok = quod_foreign_log:unfollow(Follow1),
        ok = wait_follow_count(1, 2000),
        _ = quod_reg:publish(
              {committed, Ns},
              {committed, Ns, 2, #entry{index = 2, data = noop}}),
        Woken2 = receive_follow(Follow2, Identity2),
        ?assertMatch({unreachable, unavailable, 0}, element(2, Woken2)),
        ok = quod_foreign_log:ack(Follow2, element(1, Woken2)),

        %% Releasing the last identity removes both namespace progress
        %% subscriptions.  The stats call is a mailbox barrier for any event
        %% this process could still have delivered.
        ok = quod_foreign_log:unfollow(Follow2),
        ok = wait_follow_count(0, 2000),
        Wakes = maps:get(follow_wakes, quod_foreign_log:stats()),
        _ = quod_reg:publish(
              {committed, Ns},
              {committed, Ns, 3, #entry{index = 3, data = noop}}),
        ?assertEqual(Wakes,
                     maps:get(follow_wakes, quod_foreign_log:stats()))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

follow_wakes_coalesce_while_certified_work_is_inflight_test() ->
    Dir = temp_dir("follow-wake-coalesce"),
    Parent = self(),
    BlockingFetch =
        fun(_, _, _, _, _) ->
            Parent ! {follow_fetch_started, self()},
            receive
                release_follow_fetch -> {error, unavailable}
            end
        end,
    Pid = start_owner_opts(Dir, BlockingFetch, #{}),
    Identity = {unique_ns(), key(111)},
    Peer = key(112),
    Endpoint = {"127.0.0.1", 31990},
    try
        ok = quod_foreign_log:observe_candidate(Identity, {Peer, Endpoint}),
        {ok, FollowRef} = quod_foreign_log:follow(Identity),
        Building = receive_follow(FollowRef, Identity),
        ok = quod_foreign_log:ack(FollowRef, element(1, Building)),
        Worker1 = receive
                      {follow_fetch_started, W1} -> W1
                  after 2000 -> error(first_follow_fetch_not_started)
                  end,

        Ns = element(1, Identity),
        Pid ! {directory_route_available, Identity},
        Pid ! {directory_route_available, Identity},
        Pid ! {quod_message, {Peer, self()}, quod_feed:channel(Ns),
               term_to_binary({feed, Ns, <<"wake">>})},
        ?assertEqual(1, maps:get(follow_wakes, quod_foreign_log:stats())),

        Worker1 ! release_follow_fetch,
        Unreachable1 = receive_follow(FollowRef, Identity),
        ok = quod_foreign_log:ack(FollowRef, element(1, Unreachable1)),
        Unreachable2 = receive_follow(FollowRef, Identity),
        ok = quod_foreign_log:ack(FollowRef, element(1, Unreachable2)),
        %% Three signals created one dirty edge and therefore one second job.
        ?assertEqual(2, maps:get(follow_wakes, quod_foreign_log:stats())),
        ok = quod_foreign_log:unfollow(FollowRef),
        ok = wait_follow_count(0, 2000)
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

exact_verification_parks_until_directory_progress_test() ->
    Ns = unique_ns(),
    Identity = {Ns, key(31990)},
    Peer = key(31991),
    Endpoint = {"127.0.0.1", 31991},
    Ref = ref(Identity, 2, 31992),
    TestPid = self(),
    Fetch = fun(P, E, _RequestedNs, _From, _To) ->
                    TestPid ! {parked_exact_fetch, P, E},
                    {error, unavailable}
            end,
    Dir = temp_dir("parked-exact-directory"),
    Pid = start_owner(Dir, Fetch),
    try
        Request = gen_server:send_request(
                    Pid,
                    {verify_reference, Ref, finalize, none, none, 300}),
        %% The stats call is a mailbox barrier: absence of a route has parked
        %% the owned call instead of returning retry or starting a worker.
        ?assertMatch(#{pending := 0, queued := 1},
                     quod_foreign_log:stats()),

        %% The contact remains an untrusted bootstrap hint.  Only the exact
        %% directory progress edge makes the parked verifier select it and
        %% run the ordinary anchored history fold.
        ok = quod_foreign_log:observe_candidate(
               Identity, {Peer, Endpoint}),
        ?assertEqual(1, maps:get(queued, quod_foreign_log:stats())),
        Pid ! {directory_route_available, Identity},
        receive
            {parked_exact_fetch, Peer, Endpoint} -> ok
        after 1000 ->
            error(parked_verifier_not_woken)
        end,
        %% The failed fetch parks again.  Only the caller's original final
        %% deadline ends the request; there is no retry timer or ladder.
        ?assertEqual(
           {reply, {error, retry}},
           gen_server:wait_response(Request, 2000)),
        ?assertMatch(#{pending := 0, queued := 0},
                     quod_foreign_log:stats())
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

parked_route_does_not_block_later_request_contact_test() ->
    Ns = unique_ns(),
    Identity = {Ns, key(31993)},
    Peer = key(31994),
    Endpoint = {"127.0.0.1", 31992},
    Ref = ref(Identity, 2, 31995),
    TestPid = self(),
    Fetch = fun(P, E, _RequestedNs, _From, _To) ->
                    TestPid ! {contact_exact_fetch, P, E},
                    {error, unavailable}
            end,
    Dir = temp_dir("parked-exact-contact"),
    Pid = start_owner(Dir, Fetch),
    try
        Parked = gen_server:send_request(
                   Pid,
                   {verify_reference, Ref, finalize, none, none, 350}),
        ?assertEqual(1, maps:get(queued, quod_foreign_log:stats())),
        Contact = gen_server:send_request(
                    Pid,
                    {verify_reference, Ref, finalize,
                     {Peer, Endpoint}, none, 250}),
        %% The second row has a usable request-scoped route, so it runs even
        %% though the older row remains parked at the front of the one queue.
        receive
            {contact_exact_fetch, Peer, Endpoint} -> ok
        after 1000 ->
            error(contact_request_blocked_behind_parked_row)
        end,
        ?assertEqual(
           {reply, {error, retry}},
           gen_server:wait_response(Contact, 2000)),
        ?assertEqual(
           {reply, {error, retry}},
           gen_server:wait_response(Parked, 2000)),
        ?assertMatch(#{pending := 0, queued := 0},
                     quod_foreign_log:stats())
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

uncertified_feed_progress_does_not_wake_parked_exact_verification_test() ->
    Ns = unique_ns(),
    Identity = {Ns, key(31998)},
    Peer = key(31999),
    Endpoint = {"127.0.0.1", 31993},
    Ref = ref(Identity, 2, 32000),
    TestPid = self(),
    Fetch = fun(P, E, _RequestedNs, _From, _To) ->
                    TestPid ! {feed_woken_exact_fetch, P, E},
                    {error, unavailable}
            end,
    Dir = temp_dir("parked-exact-feed"),
    Pid = start_owner(Dir, Fetch),
    try
        Request = gen_server:send_request(
                    Pid,
                    {verify_reference, Ref, finalize, none, none, 300}),
        ?assertEqual(1, maps:get(queued, quod_foreign_log:stats())),
        ok = quod_foreign_log:observe_candidate(
               Identity, {Peer, Endpoint}),
        ?assertEqual(1, maps:get(queued, quod_foreign_log:stats())),
        Pid ! {quod_message, {Peer, self()}, quod_feed:channel(Ns),
               term_to_binary({feed, Ns, <<"wake">>})},
        ?assertEqual(1, maps:get(queued, quod_foreign_log:stats())),
        receive
            {feed_woken_exact_fetch, Peer, Endpoint} ->
                error(uncertified_feed_woke_parked_verifier)
        after 0 ->
            ok
        end,

        %% The exact directory signal remains the ordinary discovery wake.
        Pid ! {directory_route_available, Identity},
        receive
            {feed_woken_exact_fetch, Peer, Endpoint} -> ok
        after 1000 ->
            error(directory_did_not_wake_parked_verifier)
        end,
        ?assertEqual(
           {reply, {error, retry}},
           gen_server:wait_response(Request, 2000)),
        ?assertMatch(#{pending := 0, queued := 0, histories := 0},
                     quod_foreign_log:stats())
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

parked_exact_expires_only_at_its_caller_deadline_test() ->
    Identity = {unique_ns(), key(31996)},
    Ref = ref(Identity, 2, 31997),
    Dir = temp_dir("parked-exact-deadline"),
    Pid = start_owner(Dir, fun(_, _, _, _, _) -> {error, unavailable} end),
    try
        Request = gen_server:send_request(
                    Pid,
                    {verify_reference, Ref, finalize,
                     none, none, 80}),
        ?assertEqual(1, maps:get(queued, quod_foreign_log:stats())),
        ?assertEqual(
           {reply, {error, retry}},
           gen_server:wait_response(Request, 2000)),
        ?assertMatch(#{pending := 0, queued := 0, histories := 0},
                     quod_foreign_log:stats())
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

follow_owner_identity_and_consumer_down_are_fail_closed_test() ->
    Dir = temp_dir("follow-owner"),
    NoFetch = fun(_, _, _, _, _) -> {error, unavailable} end,
    Pid = start_owner_opts(Dir, NoFetch, #{}),
    Identity = {unique_ns(), key(102)},
    Parent = self(),
    Consumer = spawn(
                 fun() ->
                         Result = quod_foreign_log:follow(Identity),
                         Parent ! {child_follow, self(), Result},
                         receive stop -> ok end
                 end),
    try
        FollowRef = receive
                        {child_follow, Consumer, {ok, Ref}} -> Ref
                    after 2000 -> error(missing_child_follow)
                    end,
        %% A different process cannot remove the child's consumer reference.
        ok = quod_foreign_log:unfollow(FollowRef),
        ?assertEqual(1, maps:get(follow_consumers, quod_foreign_log:stats())),
        exit(Consumer, kill),
        ok = wait_follow_count(0, 2000),
        ?assertEqual(0, maps:get(followed_histories, quod_foreign_log:stats()))
    after
        catch exit(Consumer, kill),
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

verify_exact_reference_and_persisted_cache_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Dir = temp_dir("verify"),
    Chain = maps:get(chain, Fixture),
    Ns = maps:get(ns, Fixture),
    Ref = maps:get(ref, Fixture),
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 19091},
    Fetch = chain_fetch(Ns, Chain),
    Pid = start_owner(Dir, Fetch),
    try
        {ok, Evidence} = quod_foreign_log:verify(
                           Peer, Endpoint, Ref, finalize, 5000),
        ?assertEqual({Ns, maps:get(anchor, Fixture)},
                     maps:get(identity, Evidence)),
        ?assertEqual(2, maps:get(slot, Evidence)),
        ?assertEqual(finalize, maps:get(phase, Evidence)),
        ?assertEqual(0, maps:get(generation, Evidence)),
        ?assertEqual([maps:get(pub, Fixture)],
                     maps:get(committee, Evidence)),
        ?assertEqual(
           #{maps:get(pub, Fixture) => {"127.0.0.1", 19000}},
           maps:get(routes, Evidence)),
        ?assert(is_binary(maps:get(committee_id, Evidence))),
        ?assertEqual(1, maps:get(histories, quod_foreign_log:stats())),
        ?assertMatch(
           {ok, #{slot := 2, phase := finalize, control := _}},
           quod_foreign_log:verify(Peer, Endpoint, Ref, entry, 5000)),
        ?assertEqual(
           {error, retry},
           quod_foreign_log:verify(
             key(91), Endpoint, Ref, finalize, 5000))
    after
        stop_owner(Pid)
    end,

    %% The second owner verifies the durable cache from slot 1.  A network
    %% fetch would fail, proving restart does not confuse availability with
    %% validity and does not trust checkpoint fields without replaying them.
    NoFetch = fun(_, _, _, _, _) -> {error, should_not_fetch} end,
    Pid2 = start_owner(Dir, NoFetch),
    try
        ?assertMatch(
           {ok, #{slot := 2, phase := finalize}},
           quod_foreign_log:verify(
             Peer, Endpoint, Ref, finalize, 5000))
    after
        stop_owner(Pid2),
        _ = file:del_dir_r(Dir)
    end.

foreign_exact_reference_accepts_only_the_pinned_genesis_entry_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Anchor = maps:get(anchor, Fixture),
    [#entry{data = {batch, [Genesis]}} = GenesisEntry | _] =
        maps:get(chain, Fixture),
    {ok, GenesisRef} = quod_dtx:certified_entry_ref(
                         {Ns, Anchor}, GenesisEntry, Genesis),
    Dir = temp_dir("exact-pinned-genesis"),
    Pid = start_owner(Dir, chain_fetch(Ns, maps:get(chain, Fixture))),
    try
        %% Slot 1 has no quorum certificate.  It is accepted only because the
        %% immutable genesis entry rebuilds to the identity's pinned anchor.
        ?assertMatch(
           {ok, #{slot := 1, phase := transaction, transaction := Genesis}},
           quod_foreign_log:verify(
             maps:get(pub, Fixture), {"127.0.0.1", 19094}, GenesisRef,
             transaction, 5000)),
        BadAnchorRef = setelement(4, GenesisRef, key(genesis_wrong_anchor)),
        ?assertEqual(
           {error, retry},
           quod_foreign_log:verify(
             maps:get(pub, Fixture), {"127.0.0.1", 19094}, BadAnchorRef,
             transaction, 5000))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

generic_entry_reference_accepts_certified_content_test() ->
    Fixture = long_identity_fixture(unique_ns(), 2),
    Ns = maps:get(ns, Fixture),
    Anchor = maps:get(anchor, Fixture),
    [_, #entry{data = {batch, [Transaction]}} = Entry] =
        maps:get(chain, Fixture),
    {ok, Ref} = quod_dtx:certified_entry_ref(
                  {Ns, Anchor}, Entry, Transaction),
    Dir = temp_dir("generic-content-entry"),
    Pid = start_owner(
            Dir, chain_fetch(Ns, maps:get(chain, Fixture))),
    try
        ?assertMatch(
           {ok, #{phase := transaction, transaction := Transaction,
                  committee := [_]}},
           quod_foreign_log:verify(
             maps:get(pub, Fixture), {"127.0.0.1", 19093},
             Ref, entry, 5000)),
        ?assertMatch(
           {ok, #{phase := transaction, transaction := Transaction}},
           quod_foreign_log:verify(
             maps:get(pub, Fixture), {"127.0.0.1", 19093},
             Ref, transaction, 5000))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

verify_local_uses_exact_historical_projection_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Ref = maps:get(ref, Fixture),
    SourceDir = temp_dir("local-source"),
    CacheDir = temp_dir("local-cache"),
    {ok, Store0} = quod_ledger_store:open(Ns, SourceDir),
    {ok, Store1} = quod_ledger_store:append(
                     Store0, maps:get(chain, Fixture)),
    ok = quod_ledger_store:close(Store1),
    NoNetwork = fun(_, _, _, _, _) -> {error, network_used} end,
    Pid = start_owner(CacheDir, NoNetwork),
    try
        {ok, Evidence} = quod_foreign_log:verify_local(
                           SourceDir, Ref, finalize, 5000),
        ?assertEqual(finalize, maps:get(phase, Evidence)),
        ?assertEqual(0, maps:get(generation, Evidence)),
        ?assertEqual(
           #{maps:get(pub, Fixture) => {"127.0.0.1", 19000}},
           maps:get(routes, Evidence))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(SourceDir),
        _ = file:del_dir_r(CacheDir)
    end.

foreign_projection_loads_genesis_pinned_predicates_test() ->
    Ns = unique_ns(),
    Pub = key(210),
    Nonce = key(211),
    StaticBridgeHead =
        {directory_host, Ns, key(212), Pub, "127.0.0.1", 19000},
    Genesis = quod_simplex:test_genesis_tx(
                #{node_id => Pub, mode => create, committee => [],
                  node_addr => {"127.0.0.1", 19000},
                  external_predicate_modules =>
                      [quod_directory_predicates],
                  genesis_diff =>
                      quod_prolog:terms_to_diff([StaticBridgeHead])},
                Ns, Pub, Nonce),
    Entry = #entry{index = 1, data = {batch, [Genesis]}, timestamp = 1,
                   cert = none},
    Anchor = entry_hash(Entry),
    Root = temp_dir("projection-manifest"),
    CacheNs = <<"projection-cache:", Ns/binary>>,
    {ok, Store0} = quod_ledger_store:open(CacheNs, Root),
    {ok, Store1} = quod_ledger_store:append(Store0, [Entry]),
    ok = quod_ledger_store:close(Store1),
    {Pid, MRef, Generation} = quod_foreign_projection:start_monitor(
                                self(), {Ns, Anchor}, Root, CacheNs),
    try
        ok = quod_foreign_projection:advance(
               Pid, Generation, 1, {1, entry_hash(Entry)}),
        Result = receive
                     {foreign_projection_ready, {Ns, Anchor}, Generation,
                      Ready} -> Ready
                 after 3000 ->
                     error(foreign_projection_timeout)
                 end,
        %% If the foreign worker ignored the genesis manifest, this ordinary
        %% assertion would materialize.  With the pinned bridge installed it
        %% is the same static procedure as on validators and is not changed.
        ?assertNot(
           lists:member(
             StaticBridgeHead, maps:get(changed_heads, Result)))
    after
        quod_foreign_projection:stop(Pid),
        receive {'DOWN', MRef, process, Pid, _} -> ok after 3000 -> ok end,
        _ = file:del_dir_r(Root)
    end.

certified_current_view_advances_past_finalize_membership_test() ->
    Fixture = membership_after_finalize_fixture(unique_ns()),
    Dir = temp_dir("current-membership"),
    Ns = maps:get(ns, Fixture),
    Old = maps:get(pub, Fixture),
    New = maps:get(new_pub, Fixture),
    Routes = route_candidates(
               [{Old, {"127.0.0.1", 19000}},
                {New, {"127.0.0.1", 19101}}]),
    Pid = start_owner(
            Dir, peer_chain_fetch(Ns, maps:get(chain, Fixture), [Old, New])),
    try
        {ok, Historical} = quod_foreign_log:verify(
                             Old, {"127.0.0.1", 19000},
                             maps:get(ref, Fixture), finalize, 5000),
        {ok, Current} = quod_foreign_log:verify_current(
                          Routes, maps:get(ref, Fixture), 5000),
        %% The current-view call advanced the resident cache past a committee
        %% rotation. Re-reading the older exact Finalize must still return the
        %% committee that was certified at its own slot, independently of the
        %% verifier's newer cache head and without a genesis replay.
        {ok, HistoricalAgain} = quod_foreign_log:verify_reference(
                                  maps:get(ref, Fixture), finalize, 5000),
        ?assertEqual(2, maps:get(slot, Historical)),
        ?assertEqual(3, maps:get(slot, Current)),
        ?assertEqual([Old], maps:get(committee, Historical)),
        ?assertEqual(maps:get(committee, Historical),
                     maps:get(committee, HistoricalAgain)),
        ?assertEqual(maps:get(committee_id, Historical),
                     maps:get(committee_id, HistoricalAgain)),
        ?assertEqual(lists:sort([Old, New]), maps:get(committee, Current)),
        ?assertNotEqual(maps:get(committee_id, Historical),
                        maps:get(committee_id, Current)),
        %% Applied evidence signed before the rotation remains valid against
        %% the exact Finalize evidence after the cache advances. Substituting
        %% the current head's committee view must fail.
        NetworkIdentity = key(179),
        GroupId = quod_dtx:group_id(maps:get(control, Fixture)),
        {ok, Vote} = quod_dtx_current_view:sign_applied_vote(
                       NetworkIdentity, {Ns, maps:get(anchor, Fixture)},
                       maps:get(committee_id, Historical), GroupId,
                       maps:get(ref, Fixture),
                       maps:get(generation, Historical), abort,
                       maps:get(signer, Fixture)),
        AppliedCertificate =
            {quod_dtx_applied_certificate, 1, NetworkIdentity,
             {Ns, maps:get(anchor, Fixture)},
             maps:get(committee_id, Historical), GroupId,
             maps:get(ref, Fixture), maps:get(generation, Historical),
             abort, [Vote]},
        ?assert(quod_dtx_current_view:verify_applied_certificate(
                  AppliedCertificate, NetworkIdentity, HistoricalAgain)),
        ?assertNot(quod_dtx_current_view:verify_applied_certificate(
                     AppliedCertificate, NetworkIdentity, Current)),
        ?assertEqual(
           lists:keysort(1, Routes), maps:get(route_candidates, Current))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

restart_rebuilds_committee_eras_for_old_exact_references_test() ->
    Fixture = membership_after_finalize_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Old = maps:get(pub, Fixture),
    New = maps:get(new_pub, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Routes = route_candidates(
               [{Old, {"127.0.0.1", 19000}},
                {New, {"127.0.0.1", 19101}}]),
    Fetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Old, New]),
    Dir = temp_dir("restart-committee-eras"),
    Pid1 = start_owner(Dir, Fetch),
    {Historical, Current} =
        try
            {ok, Historical0} = quod_foreign_log:verify(
                                  Old, {"127.0.0.1", 19000},
                                  maps:get(ref, Fixture), finalize, 5000),
            {ok, Current0} = quod_foreign_log:verify_current(
                               Routes, maps:get(ref, Fixture), 5000),
            {_Height, Checkpoint} = cache_checkpoint(Dir, Identity),
            ?assertEqual(false, maps:is_key(committee_views, Checkpoint)),
            {Historical0, Current0}
        after
            stop_owner(Pid1)
        end,
    Pid2 = start_owner(Dir, Fetch),
    try
        {ok, HistoricalAgain} = quod_foreign_log:verify_reference(
                                  maps:get(ref, Fixture), finalize, 5000),
        {ok, CurrentAgain} = quod_foreign_log:verify_current(
                               Routes, maps:get(ref, Fixture), 5000),
        ?assertEqual(maps:get(committee, Historical),
                     maps:get(committee, HistoricalAgain)),
        ?assertEqual(maps:get(committee_id, Historical),
                     maps:get(committee_id, HistoricalAgain)),
        ?assertEqual(maps:get(committee, Current),
                     maps:get(committee, CurrentAgain)),
        ?assertEqual(maps:get(committee_id, Current),
                     maps:get(committee_id, CurrentAgain))
    after
        stop_owner(Pid2),
        _ = file:del_dir_r(Dir)
    end.

verify_local_uses_anchor_era_after_local_committee_rotation_test() ->
    Fixture = membership_after_finalize_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Old = maps:get(pub, Fixture),
    SourceDir = temp_dir("local-rotation-source"),
    CacheDir = temp_dir("local-rotation-cache"),
    {ok, Store0} = quod_ledger_store:open(Ns, SourceDir),
    {ok, Store1} = quod_ledger_store:append(
                     Store0, maps:get(chain, Fixture)),
    ok = quod_ledger_store:close(Store1),
    Pid = start_owner(
            CacheDir, fun(_, _, _, _, _) -> {error, network_used} end),
    try
        {ok, Current} = quod_foreign_log:verify_local_current(
                          SourceDir, maps:get(ref, Fixture), 5000),
        {ok, Historical} = quod_foreign_log:verify_local(
                             SourceDir, maps:get(ref, Fixture),
                             finalize, 5000),
        ?assertEqual(3, maps:get(slot, Current)),
        ?assertEqual([Old], maps:get(committee, Historical)),
        ?assertNotEqual(maps:get(committee_id, Current),
                        maps:get(committee_id, Historical))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(SourceDir),
        _ = file:del_dir_r(CacheDir)
    end.

local_current_view_folds_to_captured_ledger_head_test() ->
    Fixture = membership_after_finalize_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    SourceDir = temp_dir("local-current-source"),
    CacheDir = temp_dir("local-current-cache"),
    {ok, Store0} = quod_ledger_store:open(Ns, SourceDir),
    {ok, Store1} = quod_ledger_store:append(
                     Store0, maps:get(chain, Fixture)),
    ok = quod_ledger_store:close(Store1),
    Pid = start_owner(
            CacheDir, fun(_, _, _, _, _) -> {error, network_used} end),
    try
        ?assertMatch(
           {ok, #{slot := 3, committee := [_, _]}},
           quod_foreign_log:verify_local_current(
             SourceDir, maps:get(ref, Fixture), 5000)),
        Identity = {Ns, maps:get(anchor, Fixture)},
        [SessionFile] = phase_session_files(CacheDir, Identity),
        ?assertMatch(
           {ok, #{slot := 3, committee := [_, _]}},
           quod_foreign_log:verify_local_current(
             SourceDir, maps:get(ref, Fixture), 5000)),
        %% Local and remote current checks share the same resident projection
        %% seam. Replacing this scratch session proves the local half silently
        %% replayed the certified prefix instead of resuming it.
        ?assertEqual(
           [SessionFile], phase_session_files(CacheDir, Identity))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(SourceDir),
        _ = file:del_dir_r(CacheDir)
    end.

identity_current_view_starts_at_genesis_and_tracks_rotation_test() ->
    Fixture = membership_after_finalize_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Anchor = maps:get(anchor, Fixture),
    Old = maps:get(pub, Fixture),
    New = maps:get(new_pub, Fixture),
    Routes = route_candidates(
               [{Old, {"127.0.0.1", 19000}},
                {New, {"127.0.0.1", 19101}}]),
    TestPid = self(),
    Fetch0 = peer_chain_fetch(
               Ns, maps:get(chain, Fixture), [Old, New]),
    Fetch = fun(Peer, Endpoint, RequestedNs, From, To) ->
                    TestPid ! {identity_current_fetch, From},
                    Fetch0(Peer, Endpoint, RequestedNs, From, To)
            end,
    Dir = temp_dir("identity-current"),
    Pid = start_owner(Dir, Fetch),
    try
        {ok, Current} = quod_foreign_log:current(
                          Routes, {Ns, Anchor}, 5000),
        ?assertEqual(3, maps:get(slot, Current)),
        ?assertEqual(lists:sort([Old, New]), maps:get(committee, Current)),
        ?assertEqual(
           lists:keysort(1, Routes), maps:get(route_candidates, Current)),
        Fetches = collect_identity_current_fetches([]),
        ?assert(lists:member(1, Fetches))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

identity_current_bootstrap_fails_over_before_certified_routes_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Right = maps:get(pub, Fixture),
    Wrong = <<0:256>>,
    Endpoint = {"127.0.0.1", 19000},
    TestPid = self(),
    FetchTag = make_ref(),
    RightFetch = chain_fetch(Ns, maps:get(chain, Fixture)),
    Fetch =
        fun(Peer, GivenEndpoint, RequestedNs, From, To) ->
            TestPid ! {bootstrap_route_fetch, FetchTag, Peer, From},
            case {Peer, GivenEndpoint} of
                {Wrong, Endpoint} -> {error, retry};
                {Right, Endpoint} ->
                    RightFetch(Peer, GivenEndpoint, RequestedNs, From, To);
                _ -> {error, wrong_route}
            end
        end,
    Dir = temp_dir("identity-current-route-failover"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertMatch(
           {ok, #{identity := Identity, committee := [Right]}},
           quod_foreign_log:current(
             route_candidates([{Wrong, Endpoint}, {Right, Endpoint}]),
             Identity, 5000)),
        Calls = collect_bootstrap_route_fetches(FetchTag, []),
        ?assertMatch([{Wrong, 1}, {Right, 1} | _], Calls),
        %% After the genesis page certifies Right for Endpoint, the conflicting
        %% discovery hint is never consulted again.
        ?assertEqual(
           1, length([ok || {Peer, _} <- Calls, Peer =:= Wrong]))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

identity_current_bootstrap_continues_after_selected_source_retry_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Right = maps:get(pub, Fixture),
    Wrong = <<0:256>>,
    Endpoint = {"127.0.0.1", 19000},
    TestPid = self(),
    FetchTag = make_ref(),
    ChainFetch = chain_fetch(Ns, maps:get(chain, Fixture)),
    Fetch =
        fun(Peer, GivenEndpoint, RequestedNs, From, To) ->
            TestPid ! {bootstrap_route_fetch, FetchTag, Peer, From},
            case {Peer, GivenEndpoint, To} of
                {Wrong, Endpoint, 1} ->
                    %% The discovery page is valid, but this source becomes
                    %% unavailable while the verified history is downloaded.
                    ChainFetch(Peer, GivenEndpoint, RequestedNs, From, To);
                {Wrong, Endpoint, _Later} ->
                    {error, retry};
                {Right, Endpoint, _} ->
                    ChainFetch(Peer, GivenEndpoint, RequestedNs, From, To);
                _ ->
                    {error, wrong_route}
            end
        end,
    Dir = temp_dir("identity-current-selected-route-retry"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertMatch(
           {ok, #{identity := Identity, committee := [Right]}},
           quod_foreign_log:current(
             route_candidates([{Wrong, Endpoint}, {Right, Endpoint}]),
             Identity, 5000)),
        Calls = collect_bootstrap_route_fetches(FetchTag, []),
        ?assertEqual(
           2, length([ok || {Peer, _} <- Calls, Peer =:= Wrong])),
        ?assert(lists:any(fun({Peer, _}) -> Peer =:= Right end, Calls))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

identity_current_global_network_dependency_stops_route_failover_test() ->
    Name = list_to_atom(
             "foreign_identity_"
             ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, Peer, _Node} = peer:start(
                          #{name => Name, connection => standard_io,
                            args => ["-pa" | code:get_path()]}),
    try
        ?assertEqual(
           ok,
           peer:call(
             Peer, ?MODULE,
             identity_current_global_network_dependency_case, [], 15000))
    after
        _ = peer:stop(Peer)
    end.

%% Run in a fresh VM so no namespace started by another EUnit module can
%% satisfy the deliberately unavailable root-network dependency. This keeps
%% the route-policy test local without changing production identity precedence.
identity_current_global_network_dependency_case() ->
    Fixture = signed_content_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    %% Bootstrap routes are untrusted fetch hints, so they need not be the
    %% ledger signer.  Fix their canonical order explicitly: the assertion
    %% must exercise dependency failure at the selected first source rather
    %% than depend on a random signing key's sort position.
    [First, Second] = lists:sort([key(252), key(253)]),
    FirstEndpoint = {"127.0.0.1", 19000},
    SecondEndpoint = {"127.0.0.1", 19001},
    TestPid = self(),
    FetchTag = make_ref(),
    ChainFetch = chain_fetch(Ns, maps:get(chain, Fixture)),
    Fetch =
        fun(Peer, Endpoint, RequestedNs, From, To) ->
            TestPid ! {bootstrap_route_fetch, FetchTag, Peer, From},
            case {Peer, Endpoint} of
                {First, FirstEndpoint} ->
                    ChainFetch(Peer, Endpoint, RequestedNs, From, To);
                {Second, SecondEndpoint} ->
                    ChainFetch(Peer, Endpoint, RequestedNs, From, To);
                _ ->
                    {error, wrong_route}
            end
        end,
    Dir = temp_dir("identity-current-global-dependency"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertEqual(
           {error, retry},
           quod_foreign_log:current(
             route_candidates(
               [{First, FirstEndpoint}, {Second, SecondEndpoint}]),
             Identity, 200)),
        Calls = collect_bootstrap_route_fetches(FetchTag, []),
        ?assertEqual([], [ok || {PeerKey, _} <- Calls, PeerKey =:= Second]),
        ok
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

local_identity_current_view_needs_no_phase_reference_test() ->
    Fixture = membership_after_finalize_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    SourceDir = temp_dir("local-identity-current-source"),
    CacheDir = temp_dir("local-identity-current-cache"),
    {ok, Store0} = quod_ledger_store:open(Ns, SourceDir),
    {ok, Store1} = quod_ledger_store:append(
                     Store0, maps:get(chain, Fixture)),
    ok = quod_ledger_store:close(Store1),
    Pid = start_owner(
            CacheDir, fun(_, _, _, _, _) -> {error, network_used} end),
    try
        ?assertMatch(
           {ok, #{identity := Identity, slot := 3,
                  committee := [_, _]}},
           quod_foreign_log:local_current(
             SourceDir, Identity, 5000)),
        [SessionFile] = phase_session_files(CacheDir, Identity),
        ?assertMatch(
           {ok, #{identity := Identity, slot := 3,
                  committee := [_, _]}},
           quod_foreign_log:local_current(
             SourceDir, Identity, 5000)),
        ?assertEqual(
           [SessionFile], phase_session_files(CacheDir, Identity))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(SourceDir),
        _ = file:del_dir_r(CacheDir)
    end.

identity_current_view_rejects_stale_malformed_and_uncertified_history_test() ->
    Fixture = membership_after_finalize_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Routes = route_candidates([{Peer, {"127.0.0.1", 19000}}]),
    [Genesis, Finalize, Membership] = maps:get(chain, Fixture),
    Cases =
        [{identity_stale,
          fun(_P, _E, RequestedNs, From, To) ->
                  case From =< 2 of
                      true -> page_reply(
                                RequestedNs, Ns,
                                [Genesis, Finalize], From, To, 2);
                      false -> {ok, [], 1}
                  end
          end},
         {identity_malformed,
          fun(_P, _E, RequestedNs, From, To) ->
                  page_reply(
                    RequestedNs, Ns,
                    [Genesis, Finalize, Membership#entry{index = 4}],
                    From, To, 4)
          end},
         {identity_uncertified,
          fun(_P, _E, RequestedNs, From, To) ->
                  page_reply(
                    RequestedNs, Ns,
                    [Genesis, Finalize, Membership#entry{cert = none}],
                    From, To, 3)
          end}],
    lists:foreach(
      fun({Name, Fetch}) ->
          Dir = temp_dir(atom_to_list(Name)),
          Pid = start_owner(Dir, Fetch),
          try
              ?assertEqual(
                 {error, retry},
                 quod_foreign_log:current(Routes, Identity, 100))
          after
              stop_owner(Pid),
              _ = file:del_dir_r(Dir)
          end
      end, Cases).

outsider_cannot_establish_identity_current_view_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Outsider = key(196),
    Fetch = peer_chain_fetch(
              Ns, maps:get(chain, Fixture), [Outsider]),
    Dir = temp_dir("identity-current-outsider"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertEqual(
           {error, retry},
           quod_foreign_log:current(
             route_candidates([{Outsider, {"127.0.0.1", 19196}}]),
             Identity, 100))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

malformed_identity_current_request_is_rejected_before_owner_test() ->
    ?assertEqual(
       {error, bad_foreign_reference},
       quod_foreign_log:current(
         route_candidates([{key(197), {"127.0.0.1", 19197}}]),
         {<<>>, key(198)}, 1000)),
    ?assertEqual(
       {error, bad_foreign_reference},
       quod_foreign_log:local_current(
         "/unused", {<<"valid">>, <<1>>}, 1000)).

current_view_rejects_stale_malformed_and_uncertified_pages_test() ->
    Fixture = membership_after_finalize_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Peer = maps:get(pub, Fixture),
    Routes = route_candidates([{Peer, {"127.0.0.1", 19000}}]),
    Ref = maps:get(ref, Fixture),
    [Genesis, Finalize, Membership] = maps:get(chain, Fixture),
    Cases =
        [{stale, fun(_P, _E, RequestedNs, From, To) ->
                     case From =< 2 of
                         true -> page_reply(
                                   RequestedNs, Ns,
                                   [Genesis, Finalize], From, To, 2);
                         false -> {ok, [], 1}
                     end
                 end},
         {malformed, fun(_P, _E, RequestedNs, From, To) ->
                         case From =< 2 of
                             true -> page_reply(
                                       RequestedNs, Ns,
                                       [Genesis, Finalize], From, To, 2);
                             false ->
                                 {ok, [Membership#entry{index = 4}], 4}
                         end
                     end},
         {uncertified, fun(_P, _E, RequestedNs, From, To) ->
                           case From =< 2 of
                               true -> page_reply(
                                         RequestedNs, Ns,
                                         [Genesis, Finalize], From, To, 2);
                               false ->
                                   {ok, [Membership#entry{cert = none}], 3}
                           end
                       end}],
    lists:foreach(
      fun({Name, Fetch}) ->
          Dir = temp_dir(atom_to_list(Name)),
          Pid = start_owner(Dir, Fetch),
          try
              ?assertEqual(
                 {error, retry},
                 quod_foreign_log:verify_current(Routes, Ref, 100))
          after
              stop_owner(Pid),
              _ = file:del_dir_r(Dir)
          end
      end, Cases).

nonmember_route_cannot_corroborate_current_view_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Outsider = key(95),
    Fetch = peer_chain_fetch(
              Ns, maps:get(chain, Fixture), [Outsider]),
    Dir = temp_dir("current-nonmember"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertEqual(
           {error, retry},
           quod_foreign_log:verify_current(
             route_candidates([{Outsider, {"127.0.0.1", 19102}}]),
             maps:get(ref, Fixture), 100))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

current_view_caller_timeout_detaches_without_killing_shared_work_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Peer = maps:get(pub, Fixture),
    Ref = maps:get(ref, Fixture),
    Routes = route_candidates([{Peer, {"127.0.0.1", 19000}}]),
    TestPid = self(),
    Gate = atomics:new(1, []),
    BaseFetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer]),
    Fetch = fun(P, E, RequestedNs, From, To) ->
                    TestPid ! {current_fetch_from, From},
                    case atomics:compare_exchange(Gate, 1, 1, 2) of
                        ok ->
                            TestPid ! {current_fetch_blocked, self()},
                            receive release_current_fetch -> ok end;
                        _ ->
                            ok
                    end,
                    BaseFetch(P, E, RequestedNs, From, To)
            end,
    Dir = temp_dir("current-timeout"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertMatch(
           {ok, _},
           quod_foreign_log:verify(
             Peer, {"127.0.0.1", 19000}, Ref, finalize, 2000)),
        flush_fetches(),
        ok = atomics:put(Gate, 1, 1),
        First = gen_server:send_request(
                  Pid, {verify_current, Routes, Ref, 100}),
        Worker = receive
                     {current_fetch_blocked, FetchWorker} -> FetchWorker
                 after 2000 ->
                     error(current_fetch_not_started)
                 end,
        ?assertEqual(
           {reply, {error, retry}},
           gen_server:wait_response(First, 2000)),
        %% The caller is gone, but the one cache writer remains active.
        ?assertEqual(1, maps:get(pending, quod_foreign_log:stats())),
        ?assertEqual(1, maps:get(histories, quod_foreign_log:stats())),
        Second = gen_server:send_request(
                   Pid, {verify_current, Routes, Ref, 2000}),
        ?assertEqual(1, maps:get(pending, quod_foreign_log:stats())),
        Worker ! release_current_fetch,
        ?assertMatch(
           {reply, {ok, #{slot := 2}}},
           gen_server:wait_response(Second, 3000)),
        ?assertEqual(0, maps:get(pending, quod_foreign_log:stats())),
        Fetches = collect_fetches([]),
        ?assert(Fetches =/= []),
        ?assert(lists:all(fun(From) -> From =:= 3 end, Fetches))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

request_scoped_contact_is_preferred_and_not_retained_on_failure_test() ->
    Identity = {unique_ns(), key(301)},
    Peer = key(302),
    Stale = {"127.0.0.1", 19301},
    Live = {"127.0.0.1", 19302},
    TestPid = self(),
    Fetch = fun(P, Endpoint, _Ns, _From, _To) ->
                    TestPid ! {request_contact_fetch, P, Endpoint},
                    {error, unavailable}
            end,
    Dir = temp_dir("request-contact"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertEqual(
           {error, retry},
           quod_foreign_log:current(
             route_candidates([{Peer, Stale}]), Identity,
             {Peer, Live}, 1000)),
        receive
            {request_contact_fetch, Peer, Live} -> ok
        after 2000 ->
            error(request_contact_not_preferred)
        end,
        %% An unverifiable claim leaves neither a decoded history row nor a
        %% persistent bootstrap address. No population cap is needed.
        ?assertMatch(
           #{histories := 0, bootstrap_candidates := 0},
           quod_foreign_log:stats())
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

long_identity_convergence_survives_caller_timeout_test_() ->
    {timeout, 30,
     fun long_identity_convergence_survives_caller_timeout/0}.

long_identity_convergence_survives_caller_timeout() ->
    Fixture = long_identity_fixture(unique_ns(), 1025),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 19205},
    Routes = route_candidates([{Peer, Endpoint}]),
    TestPid = self(),
    Gate = atomics:new(1, []),
    BaseFetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer]),
    Fetch = fun(P, E, RequestedNs, From, To) ->
                    TestPid ! {long_current_fetch, From},
                    case From =:= 257 andalso
                         atomics:compare_exchange(Gate, 1, 0, 1) =:= ok of
                        true ->
                            TestPid ! {long_current_blocked, self()},
                            receive release_long_current -> ok end;
                        false ->
                            ok
                    end,
                    BaseFetch(P, E, RequestedNs, From, To)
            end,
    Dir = temp_dir("long-current-timeout"),
    Pid = start_owner_opts(
            Dir, Fetch, #{page_timeout_ms => 5000}),
    try
        First = gen_server:send_request(
                  Pid, {current, Routes, Identity, none, 100}),
        Worker = receive
                     {long_current_blocked, FetchWorker} -> FetchWorker
                 after 5000 ->
                     error(long_current_second_page_not_reached)
                 end,
        ?assertEqual(
           {reply, {error, retry}},
           gen_server:wait_response(First, 2000)),
        ?assertEqual(1, maps:get(pending, quod_foreign_log:stats())),
        Second = gen_server:send_request(
                   Pid, {current, Routes, Identity, none, 15000}),
        ?assertEqual(1, maps:get(pending, quod_foreign_log:stats())),
        Worker ! release_long_current,
        ?assertMatch(
           {reply, {ok, #{slot := 1025}}},
           gen_server:wait_response(Second, 15000)),
        Fetches = collect_long_current_fetches([]),
        %% Genesis is fetched once for discovery and once as the first page.
        %% A restarted job would add another From=1 fetch.
        ?assertEqual(2, length([ok || 1 <- Fetches])),
        ?assert(lists:member(257, Fetches)),
        ?assert(lists:member(513, Fetches)),
        ?assert(lists:member(769, Fetches)),
        ?assert(lists:member(1025, Fetches)),
        ?assertEqual(0, maps:get(pending, quod_foreign_log:stats()))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

identical_current_identity_requests_share_one_verification_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 19098},
    Routes = route_candidates([{Peer, Endpoint}]),
    RoutesWithAnotherHint = route_candidates(
                             [{Peer, Endpoint},
                              {key(199), {"127.0.0.1", 19199}}]),
    TestPid = self(),
    First = atomics:new(1, []),
    BaseFetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer]),
    Fetch = fun(P, E, RequestedNs, From, To) ->
                    case atomics:add_get(First, 1, 1) of
                        1 ->
                            TestPid ! {shared_current_fetch, self()},
                            receive release_shared_current -> ok end;
                        _ ->
                            ok
                    end,
                    BaseFetch(P, E, RequestedNs, From, To)
            end,
    Dir = temp_dir("shared-current-identity"),
    Pid = start_owner(Dir, Fetch),
    try
        FirstRequest = gen_server:send_request(
                         Pid, {current, Routes, Identity, none, 2000}),
        Worker = receive
                     {shared_current_fetch, FetchWorker} -> FetchWorker
                 after 2000 ->
                     error(shared_current_fetch_not_started)
                 end,
        SecondRequest = gen_server:send_request(
                          Pid, {current, RoutesWithAnotherHint,
                                Identity, none, 100}),
        %% This stats call is sent after the second request by the same
        %% process, so it is a deterministic mailbox barrier, not a sleep.
        ?assertEqual(1, maps:get(pending, quod_foreign_log:stats())),
        Worker ! release_shared_current,
        {reply, {ok, FirstView}} =
            gen_server:wait_response(FirstRequest, 3000),
        {reply, {ok, SecondView}} =
            gen_server:wait_response(SecondRequest, 3000),
        ?assertEqual(FirstView, SecondView),
        ?assertEqual(0, maps:get(pending, quod_foreign_log:stats()))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

queued_identical_callers_expire_without_cancelling_the_job_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 19310},
    Routes = route_candidates([{Peer, Endpoint}]),
    TestPid = self(),
    Gate = atomics:new(1, []),
    BaseFetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer]),
    Fetch = fun(P, E, RequestedNs, From, To) ->
                    case atomics:compare_exchange(Gate, 1, 0, 1) of
                        ok ->
                            TestPid ! {distinct_work_blocked, self()},
                            receive release_distinct_work -> ok end;
                        _ ->
                            case From =:= 3 andalso
                                 atomics:compare_exchange(
                                   Gate, 1, 1, 2) =:= ok of
                                true ->
                                    TestPid ! {callerless_job_blocked, self()},
                                    receive release_callerless_job -> ok end;
                                false ->
                                    ok
                            end
                    end,
                    BaseFetch(P, E, RequestedNs, From, To)
            end,
    Dir = temp_dir("queued-shared-current"),
    Pid = start_owner(Dir, Fetch),
    try
        Active = gen_server:send_request(
                   Pid, {verify, Peer, Endpoint, maps:get(ref, Fixture),
                         finalize, 5000}),
        ActiveWorker = receive
                           {distinct_work_blocked, Worker} -> Worker
                       after 2000 ->
                           error(distinct_work_not_started)
                       end,
        First = gen_server:send_request(
                  Pid, {current, Routes, Identity, none, 100}),
        Second = gen_server:send_request(
                   Pid, {current, Routes, Identity, none, 150}),
        %% Both callers own one queued work item, not duplicate catch-up jobs.
        ?assertEqual(1, maps:get(queued, quod_foreign_log:stats())),
        ?assertEqual(
           {reply, {error, retry}},
           gen_server:wait_response(First, 2000)),
        ?assertEqual(
           {reply, {error, retry}},
           gen_server:wait_response(Second, 2000)),
        ?assertEqual(1, maps:get(queued, quod_foreign_log:stats())),
        ActiveWorker ! release_distinct_work,
        ?assertMatch(
           {reply, {ok, _}}, gen_server:wait_response(Active, 3000)),
        %% The now-callerless queued job still starts from the certified prefix
        %% and finishes; caller expiry did not cancel shared history progress.
        CallerlessWorker = receive
            {callerless_job_blocked, Worker2} -> Worker2
        after 3000 ->
            error(callerless_queued_job_not_started)
        end,
        Third = gen_server:send_request(
                  Pid, {current, Routes, Identity, none, 2000}),
        ?assertEqual(1, maps:get(pending, quod_foreign_log:stats())),
        CallerlessWorker ! release_callerless_job,
        ?assertMatch(
           {reply, {ok, #{slot := 2}}},
           gen_server:wait_response(Third, 3000)),
        ?assertEqual(0, maps:get(queued, quod_foreign_log:stats())),
        ?assertEqual(0, maps:get(pending, quod_foreign_log:stats()))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

corrupt_cache_is_discarded_and_refetched_from_genesis_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Dir = temp_dir("corrupt-restart"),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Ref = maps:get(ref, Fixture),
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 19096},
    Pid = start_owner(Dir, chain_fetch(Ns, maps:get(chain, Fixture))),
    try
        ?assertMatch(
           {ok, _},
           quod_foreign_log:verify(Peer, Endpoint, Ref, finalize, 5000))
    after
        stop_owner(Pid)
    end,
    CacheNs = quod_foreign_log:cache_namespace(Identity),
    CacheDir = quod_ledger_store:ns_dir(Dir, CacheNs),
    ok = file:write_file(
           filename:join(CacheDir, "checkpoint.term"), <<"corrupt">>),
    TestPid = self(),
    Fetch0 = chain_fetch(Ns, maps:get(chain, Fixture)),
    Fetch = fun(P, E, RequestedNs, From, To) ->
                    TestPid ! {corrupt_cache_fetch_from, From},
                    Fetch0(P, E, RequestedNs, From, To)
            end,
    Pid2 = start_owner(Dir, Fetch),
    try
        ?assertMatch(
           {ok, _},
           quod_foreign_log:verify(Peer, Endpoint, Ref, finalize, 5000)),
        receive
            {corrupt_cache_fetch_from, 1} -> ok
        after 1000 ->
            error(cache_was_not_refetched_from_genesis)
        end
    after
        stop_owner(Pid2),
        _ = file:del_dir_r(Dir)
    end.

tampered_reference_and_phase_are_rejected_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Dir = temp_dir("tamper"),
    Ns = maps:get(ns, Fixture),
    Fetch = chain_fetch(Ns, maps:get(chain, Fixture)),
    Pid = start_owner(Dir, Fetch),
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 19092},
    Ref = maps:get(ref, Fixture),
    try
        ?assertMatch(
           {ok, _},
           quod_foreign_log:verify(Peer, Endpoint, Ref, finalize, 5000)),
        {quod_dtx_ref, 2, RNs, Anchor, Slot, BlockHash, Digest, Proof} = Ref,
        BadHash = {quod_dtx_ref, 2, RNs, Anchor, Slot, key(201),
                   Digest, Proof},
        BadDigest = {quod_dtx_ref, 2, RNs, Anchor, Slot, BlockHash,
                     key(202), Proof},
        BadProof = {quod_dtx_ref, 2, RNs, Anchor, Slot, BlockHash,
                    Digest, <<"different-qc">>},
        ?assertMatch(
           {error, _},
           quod_foreign_log:verify(
             Peer, Endpoint, BadHash, finalize, 5000)),
        ?assertMatch(
           {error, _},
           quod_foreign_log:verify(
             Peer, Endpoint, BadDigest, finalize, 5000)),
        ?assertMatch(
           {error, _},
           quod_foreign_log:verify(
             Peer, Endpoint, BadProof, finalize, 5000)),
        ?assertEqual(
           {error, phase_mismatch},
           quod_foreign_log:verify(
             Peer, Endpoint, Ref, decision, 5000))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

prepared_reference_reports_post_slot_generation_test() ->
    Fixture = prepared_fixture(unique_ns()),
    Dir = temp_dir("prepare-generation"),
    Ns = maps:get(ns, Fixture),
    Pid = start_owner(Dir, chain_fetch(Ns, maps:get(chain, Fixture))),
    try
        ?assertMatch(
           {ok, #{phase := prepare, generation := 0}},
           quod_foreign_log:verify(
             maps:get(pub, Fixture), {"127.0.0.1", 19095},
             maps:get(ref, Fixture),
             prepare, 5000))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

local_prepared_reference_uses_the_same_exact_verifier_test() ->
    Fixture = prepared_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    SourceDir = temp_dir("local-prepare-source"),
    CacheDir = temp_dir("local-prepare-cache"),
    {ok, Store0} = quod_ledger_store:open(Ns, SourceDir),
    {ok, Store1} = quod_ledger_store:append(
                     Store0, maps:get(chain, Fixture)),
    ok = quod_ledger_store:close(Store1),
    Pid = start_owner(
            CacheDir, fun(_, _, _, _, _) -> {error, network_used} end),
    try
        ?assertMatch(
           {ok, #{phase := prepare, generation := 0}},
           quod_foreign_log:verify_local(
             SourceDir, maps:get(ref, Fixture), prepare, 5000))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(SourceDir),
        _ = file:del_dir_r(CacheDir)
    end.

cached_earlier_reference_reuses_certified_current_projection_test() ->
    Fixture = prepared_then_committed_fixture(unique_ns()),
    Dir = temp_dir("historical-generation"),
    Ns = maps:get(ns, Fixture),
    Pid = start_owner(Dir, chain_fetch(Ns, maps:get(chain, Fixture))),
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 19097},
    try
        ?assertMatch(
           {ok, #{phase := finalize, generation := 1}},
           quod_foreign_log:verify(
             Peer, Endpoint, maps:get(finalize_ref, Fixture),
             finalize, 5000)),
        [SessionFile] = phase_session_files(Dir, {Ns, maps:get(anchor, Fixture)}),
        %% The cache is now certified through slot 3.  The immutable slot-2
        %% Prepare is checked against its retained entry while committee-era
        %% routing metadata comes from the resident projection. Prepare recovery reads the
        %% exact base generation from its signed plan, not this current-view
        %% field.  Replacing the phase session would prove a hidden replay.
        ?assertMatch(
           {ok, #{phase := prepare, generation := 1}},
           quod_foreign_log:verify(
             Peer, Endpoint, maps:get(prepare_ref, Fixture), prepare, 5000)),
        ?assertEqual(
           [SessionFile],
           phase_session_files(Dir, {Ns, maps:get(anchor, Fixture)})),
        %% Reusing the certified resident prefix never turns membership in the
        %% local store into authority.  The requested digest must still rebuild
        %% the exact certified reference from that slot's retained entry.
        BadDigestRef = setelement(
                         7, maps:get(prepare_ref, Fixture),
                         key(retained_wrong_record_digest)),
        ?assertEqual(
           {error, invalid_foreign_reference},
           quod_foreign_log:verify(
             Peer, Endpoint, BadDigestRef, prepare, 5000))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

wrong_anchor_and_unavailable_history_only_retry_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Dir = temp_dir("anchor"),
    Ns = maps:get(ns, Fixture),
    Fetch = chain_fetch(Ns, maps:get(chain, Fixture)),
    Pid = start_owner(Dir, Fetch),
    Peer = key(93),
    Endpoint = {"127.0.0.1", 19093},
    {quod_dtx_ref, 2, RNs, _Anchor, Slot, BlockHash, Digest, Proof} =
        maps:get(ref, Fixture),
    WrongAnchorRef = {quod_dtx_ref, 2, RNs, key(203), Slot,
                      BlockHash, Digest, Proof},
    try
        ?assertEqual(
           {error, retry},
           quod_foreign_log:verify(
             Peer, Endpoint, WrongAnchorRef, finalize, 5000))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end,

    EmptyDir = temp_dir("unavailable"),
    Missing = fun(_, _, _, _, _) -> {ok, [], 0} end,
    Pid2 = start_owner(EmptyDir, Missing),
    try
        ?assertEqual(
           {error, retry},
           quod_foreign_log:verify(
             Peer, Endpoint, maps:get(ref, Fixture), finalize, 5000))
    after
        stop_owner(Pid2),
        _ = file:del_dir_r(EmptyDir)
    end.

fetch_dependency_exit_is_retry_but_programmer_fault_is_visible_test() ->
    fetch_dependency_failure_case(noproc, normal),
    fetch_dependency_failure_case(
      programmer_fault, {foreign_fetch_dependency_fault, stacktrace}).

fetch_dependency_failure_case(Failure, ExpectedReason) ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Identity = {Ns, maps:get(anchor, Fixture)},
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 19093},
    TestPid = self(),
    Fetch =
        fun(_Peer, _Endpoint, _RequestedNs, _From, _To) ->
            TestPid ! {foreign_fetch_dependency, Failure, self()},
            receive
                {continue_foreign_fetch, Failure} -> ok
            end,
            case Failure of
                noproc -> exit(noproc);
                programmer_fault -> error(foreign_fetch_dependency_fault)
            end
        end,
    Dir = temp_dir("fetch-dependency"),
    Owner = start_owner(Dir, Fetch),
    Caller = spawn(
               fun() ->
                   TestPid !
                       {foreign_fetch_result, Failure,
                        quod_foreign_log:current(
                          route_candidates([{Peer, Endpoint}]),
                          Identity, 2000)}
               end),
    try
        Probe = receive
                    {foreign_fetch_dependency, Failure, Pid} -> Pid
                after 2000 ->
                    error({fetch_dependency_not_called, Failure})
                end,
        ProbeMonitor = erlang:monitor(process, Probe),
        Probe ! {continue_foreign_fetch, Failure},
        receive
            {'DOWN', ProbeMonitor, process, Probe, Reason} ->
                assert_fetch_failure_reason(ExpectedReason, Reason)
        after 2000 ->
            error({fetch_probe_survived, Failure})
        end,
        receive
            {foreign_fetch_result, Failure, {error, retry}} -> ok
        after 3000 ->
            error({missing_fetch_failure_result, Failure, Caller})
        end,
        ?assert(is_process_alive(Owner))
    after
        stop_owner(Owner),
        _ = file:del_dir_r(Dir)
    end.

assert_fetch_failure_reason(normal, normal) ->
    ok;
assert_fetch_failure_reason(
  {foreign_fetch_dependency_fault, stacktrace},
  {foreign_fetch_dependency_fault, [_ | _]}) ->
    ok;
assert_fetch_failure_reason(Expected, Actual) ->
    error({unexpected_fetch_failure_reason, Expected, Actual}).

decoded_page_bounds_test() ->
    Tiny = #entry{index = 1, data = noop},
    ?assertEqual(
       {error, too_many_entries},
       quod_catchup:page_stats(
         lists:duplicate(?QUOD_MAX_FOREIGN_PAGE_ENTRIES + 1, Tiny))),
    Huge = #entry{index = 1,
                  data = {batch,
                          [#transaction{
                             tx_id = <<"huge">>, origin = {<<"n">>, key(1)},
                             diff = [{assert,
                                      {{blob,
                                        binary:copy(
                                          <<0>>,
                                          ?QUOD_MAX_FOREIGN_PAGE_BYTES)},
                                       true}}],
                             read_check = #{}, author = key(2), sig = none}]}},
    ?assertEqual({error, page_too_large},
                 quod_catchup:page_stats([Huge])).

worst_case_implicit_entry_frame_stays_below_budget_test() ->
    Ns = <<"foreign:frame-bound">>,
    Payload = largest_payload(Ns),
    ?assert(byte_size(term_to_binary(Payload, [deterministic]))
            =< ?MAX_BLOCK_BYTES),
    Signatures = [{key(I), <<I:512>>} || I <- lists:seq(1, ?MAX_VALIDATORS)],
    Parent = #block{slot = 2, parent = 1, payload = Payload},
    Child = #block{slot = 3, parent = 2, payload = Payload},
    Support = #cert{kind = support, slot = 2,
                    block_hash = quod_simplex:block_hash(Parent),
                    sigs = Signatures},
    Commit = #cert{kind = commit, slot = 3,
                   block_hash = quod_simplex:block_hash(Child),
                   sigs = Signatures},
    Entry = #entry{index = 2, data = Payload,
                   cert = #implicit_cert{support = Support,
                                         child = Child, commit = Commit}},
    Frame = quod_catchup:encode_frame(
              Ns, {blocks_resp, make_ref(), [Entry], 3}),
    ?assert(byte_size(Frame) < ?QUOD_MAX_FOREIGN_PAGE_BYTES),
    ?assertMatch({ok, 1, _}, quod_catchup:page_stats([Entry])).

%%%===================================================================
%%% Fixtures
%%%===================================================================

foreign_fixture(Ns) ->
    Base = fixture_base(Ns),
    Pub = maps:get(pub, Base),
    Signer = maps:get(signer, Base),
    Genesis = maps:get(genesis, Base),
    Anchor = maps:get(anchor, Base),
    Binding = {Ns, Anchor},
    Admission = maps:get(admission, Base),
    GroupId = key(70),
    DecisionIdentity = {<<"origin:", Ns/binary>>, key(71)},
    DecisionRef = ref(DecisionIdentity, 7, 72),
    {ok, FinalizeRecord} =
        quod_dtx:new_finalize(GroupId, DecisionRef, abort, none, 0),
    {ok, Control} =
        quod_dtx:sign_control(
          Binding, FinalizeRecord, Admission, 1, 1, Signer),
    {ok, ControlBlob} = quod_dtx:encode_control(Control),
    Entry = control_entry(Ns, Anchor, Pub, Signer, 2, ControlBlob),
    {ok, Ref} = quod_dtx:certified_entry_ref(Binding, Entry, Control),
    #{ns => Ns, pub => Pub, signer => Signer, anchor => Anchor,
      admission => Admission,
      chain => [Genesis, Entry], ref => Ref, control => Control}.

byte_large_foreign_fixture(Ns) ->
    Fixture = foreign_fixture(Ns),
    Pub = maps:get(pub, Fixture),
    Signer = maps:get(signer, Fixture),
    Anchor = maps:get(anchor, Fixture),
    Admission = maps:get(admission, Fixture),
    Binding = {Ns, Anchor},
    Blob = binary:copy(<<16#aa>>, 48 * 1024),
    Entries =
        [begin
             Tx0 = #transaction{
                     origin = Binding,
                     proof_id = key(300 + Sequence),
                     plan_digest = key(400 + Sequence),
                     goal = durable_goal({large_history, Sequence}),
                     result = durable_result(),
                     diff = [{assert,
                              {{large_history, Sequence, Blob}, true}}],
                     read_check = #{}, author = Pub,
                     author_seq = Sequence,
                     submitted_at = Sequence, sig = none},
             Tx1 = quod_transaction:bind_id(Binding, Tx0),
             {ok, Tx} = quod_transaction:sign(
                          {Ns, Anchor, Admission}, Tx1, Signer),
             content_entry(
               Ns, Anchor, Pub, Signer, Sequence + 1, [Tx])
         end || Sequence <- lists:seq(2, 22)],
    Fixture#{chain := maps:get(chain, Fixture) ++ Entries}.

long_identity_fixture(Ns, Height) when Height > 1 ->
    Base = fixture_base(Ns),
    Pub = maps:get(pub, Base),
    Signer = maps:get(signer, Base),
    Anchor = maps:get(anchor, Base),
    Admission = maps:get(admission, Base),
    Binding = {Ns, Anchor},
    Entries =
        [begin
             Sequence = Slot - 1,
             Tx0 = #transaction{
                     origin = Binding,
                     proof_id = key({long_proof, Slot}),
                     plan_digest = key({long_plan, Slot}),
                     goal = durable_goal({long_history, Slot}),
                     result = durable_result(),
                     diff = [{assert, {{long_history, Slot}, true}}],
                     read_check = #{}, author = Pub,
                     author_seq = Sequence,
                     submitted_at = Sequence, sig = none},
             Tx1 = quod_transaction:bind_id(Binding, Tx0),
             {ok, Tx} = quod_transaction:sign(
                          {Ns, Anchor, Admission}, Tx1, Signer),
             content_entry(Ns, Anchor, Pub, Signer, Slot, [Tx])
         end || Slot <- lists:seq(2, Height)],
    Base#{ns => Ns,
          chain => [maps:get(genesis, Base) | Entries]}.

signed_content_fixture(Ns) ->
    ClientKeyPair = quod_identity:generate(),
    {ClientPub, _ClientSeed} = ClientKeyPair,
    AgentInstance = {human_user, test_agent},
    Base = fixture_base(
             Ns, [{agent_key, AgentInstance, ClientPub, active}]),
    Pub = maps:get(pub, Base),
    Signer = maps:get(signer, Base),
    Anchor = maps:get(anchor, Base),
    Admission = maps:get(admission, Base),
    Network = key(254),
    RequestFixture = quod_ct:signed_dtx_begin_fixture(
                       #{target => {Ns, Anchor}, network => Network,
                         key_pair => ClientKeyPair}),
    Unsigned = (maps:get(transaction, RequestFixture))#transaction{
                 author = Pub, author_seq = 1, sig = none},
    {ok, Signed} = quod_transaction:sign(
                     {Ns, Anchor, Admission}, Unsigned, Signer),
    Entry = content_entry(Ns, Anchor, Pub, Signer, 2, [Signed]),
    Base#{ns => Ns, network => Network,
          chain => [maps:get(genesis, Base), Entry]}.

membership_after_finalize_fixture(Ns) ->
    Fixture = foreign_fixture(Ns),
    OldPub = maps:get(pub, Fixture),
    OldSigner = maps:get(signer, Fixture),
    Anchor = maps:get(anchor, Fixture),
    Binding = {Ns, Anchor},
    {NewPub, _NewSeed} = quod_identity:generate(),
    Projection1 = quod_simplex:history_advance(
                    Ns, hd(maps:get(chain, Fixture)),
                    quod_simplex:history_projection()),
    Goal = durable_goal({admit, NewPub}),
    Result = durable_result(),
    Tx0 = #transaction{
             origin = Binding,
             proof_id = key(180), plan_digest = key(181),
             goal = Goal, result = Result,
             diff = [{assert,
                      {{peer_admitted, NewPub,
                        "127.0.0.1", 19101, NewPub}, true}}],
             read_check = #{}, author = OldPub,
             author_seq = 1, submitted_at = 1, sig = none},
    Tx1 = quod_transaction:bind_id(Binding, Tx0),
    {ok, AuthorBinding} = quod_simplex:history_binding(
                            Binding, OldPub, Projection1),
    {ok, Tx} = quod_transaction:sign(
                 AuthorBinding, Tx1, OldSigner),
    Entry = content_entry(
              Ns, Anchor, OldPub, OldSigner, 3, [Tx]),
    Fixture#{chain := maps:get(chain, Fixture) ++ [Entry],
             new_pub => NewPub}.

prepared_fixture(Ns) ->
    Base = fixture_base(Ns),
    Pub = maps:get(pub, Base),
    Signer = maps:get(signer, Base),
    Genesis = maps:get(genesis, Base),
    Anchor = maps:get(anchor, Base),
    Binding = {Ns, Anchor},
    Admission = maps:get(admission, Base),
    Origin = {<<"prepare-origin:", Ns/binary>>, key(80)},
    %% Reuse the shared public constructor so this foreign-history fixture
    %% cannot retain an old plan/signature preimage when that protocol evolves.
    BeginFixture = quod_ct:signed_dtx_begin_fixture(
                     #{target => Origin,
                       participant_target => Binding,
                       node_identity => Signer,
                       admission => Admission,
                       proof_id => key(83),
                       operation_id => key(82)}),
    Begin = maps:get('begin', BeginFixture),
    GroupId = quod_dtx:group_id(Begin),
    BeginRef = ref_with_digest(Origin, 7, key(84), GroupId),
    {ok, PrepareRecord} = quod_dtx:new_prepare(
                            Begin, BeginRef, Binding),
    {ok, Control} = quod_dtx:sign_control(
                      Binding, PrepareRecord, Admission, 1, 1, Signer),
    {ok, ControlBlob} = quod_dtx:encode_control(Control),
    Entry = control_entry(Ns, Anchor, Pub, Signer, 2, ControlBlob),
    {ok, Ref} = quod_dtx:certified_entry_ref(Binding, Entry, Control),
    #{ns => Ns, pub => Pub, anchor => Anchor, signer => Signer,
      admission => Admission, origin => Origin, group_id => GroupId,
      chain => [Genesis, Entry], ref => Ref, prepare_ref => Ref,
      control => Control}.

prepared_then_committed_fixture(Ns) ->
    Prepared = prepared_fixture(Ns),
    Binding = {Ns, maps:get(anchor, Prepared)},
    DecisionRef = ref(maps:get(origin, Prepared), 8, 84),
    {ok, FinalizeRecord} =
        quod_dtx:new_finalize(
          maps:get(group_id, Prepared), DecisionRef, commit,
          maps:get(prepare_ref, Prepared), 2),
    {ok, FinalizeControl} =
        quod_dtx:sign_control(
          Binding, FinalizeRecord, maps:get(admission, Prepared),
          2, 2, maps:get(signer, Prepared)),
    {ok, FinalizeBlob} = quod_dtx:encode_control(FinalizeControl),
    Entry = control_entry(
              Ns, maps:get(anchor, Prepared), maps:get(pub, Prepared),
              maps:get(signer, Prepared), 3, FinalizeBlob),
    {ok, FinalizeRef} =
        quod_dtx:certified_entry_ref(Binding, Entry, FinalizeControl),
    Prepared#{chain := maps:get(chain, Prepared) ++ [Entry],
              finalize_ref => FinalizeRef}.

fixture_base(Ns) ->
    fixture_base(Ns, []).

fixture_base(Ns, InitialTerms) ->
    {Pub, Seed} = quod_identity:generate(),
    Signer = #{pubkey => Pub,
               key => quod_identity:key_term({Pub, Seed})},
    Genesis = genesis(Ns, Pub, InitialTerms),
    Anchor = entry_hash(Genesis),
    Binding = {Ns, Anchor},
    {ok, [_], Projection1} =
        quod_catchup:verify_forward(
          Ns, Anchor, quod_simplex:history_projection(Binding),
          1, [Genesis]),
    ?assertEqual([Pub], quod_simplex:history_committee(Projection1)),
    Admission = crypto:hash(
                  sha256,
                  term_to_binary(
                    {quod_validator_admission, 1, Ns, 1, Anchor, Pub},
                    [deterministic])),
    #{pub => Pub, signer => Signer, genesis => Genesis,
      anchor => Anchor, admission => Admission}.

control_entry(Ns, Anchor, Pub, Signer, Slot, ControlBlob) ->
    Data = {batch, [{dtx, ControlBlob}]},
    Block = #block{slot = Slot, parent = Slot - 1, payload = Data},
    BlockHash = quod_simplex:block_hash(Block),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    #share{sig = Signature} = quod_simplex:make_share(
                                Domain, commit, Slot, BlockHash, Signer),
    Cert = #cert{kind = commit, slot = Slot, block_hash = BlockHash,
                 sigs = [{Pub, Signature}]},
    #entry{index = Slot, data = Data, cert = Cert}.

content_entry(Ns, Anchor, Pub, Signer, Slot, Transactions) ->
    Data = {batch, Transactions},
    Block = #block{slot = Slot, parent = Slot - 1, payload = Data},
    BlockHash = quod_simplex:block_hash(Block),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    #share{sig = Signature} = quod_simplex:make_share(
                                Domain, commit, Slot, BlockHash, Signer),
    Cert = #cert{kind = commit, slot = Slot, block_hash = BlockHash,
                 sigs = [{Pub, Signature}]},
    #entry{index = Slot, data = Data, cert = Cert}.

genesis(Ns, Pub, InitialTerms) ->
    Nonce = key(44),
    Tx = quod_simplex:test_genesis_tx(
           #{node_id => Pub, mode => create, committee => [],
             node_addr => {"127.0.0.1", 19000},
             genesis_diff => quod_prolog:terms_to_diff(InitialTerms)},
           Ns, Pub, Nonce),
    #entry{index = 1, data = {batch, [Tx]}, cert = none}.

entry_hash(#entry{index = Slot, data = Data, timestamp = Timestamp}) ->
    quod_simplex:block_hash(
      #block{slot = Slot, parent = Slot - 1,
             payload = Data, timestamp = Timestamp}).

chain_fetch(Ns, Chain) ->
    Height = length(Chain),
    fun(_Peer, _Endpoint, RequestedNs, From, To) when RequestedNs =:= Ns ->
            Page = [Entry || #entry{index = I} = Entry <- Chain,
                             I >= From, I =< To],
            {ok, Page, Height};
       (_Peer, _Endpoint, _RequestedNs, _From, _To) ->
            {error, wrong_namespace}
    end.

peer_chain_fetch(Ns, Chain, Peers) ->
    Base = chain_fetch(Ns, Chain),
    fun(Peer, Endpoint, RequestedNs, From, To) ->
            case lists:member(Peer, Peers) of
                true -> Base(Peer, Endpoint, RequestedNs, From, To);
                false -> {error, wrong_peer}
            end
    end.

page_reply(RequestedNs, Ns, Chain, From, To, Height)
  when RequestedNs =:= Ns ->
    {ok, [Entry || #entry{index = Index} = Entry <- Chain,
                   Index >= From, Index =< To], Height};
page_reply(_RequestedNs, _Ns, _Chain, _From, _To, _Height) ->
    {error, wrong_namespace}.

durable_goal(Goal) ->
    {ok, Blob} = quod_durable_term:encode_goal(Goal),
    Blob.

durable_result() ->
    {ok, Blob} = quod_durable_term:encode_result(#{}),
    Blob.

flush_fetches() ->
    receive
        {current_fetch_from, _From} -> flush_fetches()
    after 0 ->
        ok
    end.

collect_fetches(Acc) ->
    receive
        {current_fetch_from, From} -> collect_fetches([From | Acc])
    after 50 ->
        lists:reverse(Acc)
    end.

collect_identity_current_fetches(Acc) ->
    receive
        {identity_current_fetch, From} ->
            collect_identity_current_fetches([From | Acc])
    after 50 ->
        lists:reverse(Acc)
    end.

collect_bootstrap_route_fetches(Tag, Acc) ->
    receive
        {bootstrap_route_fetch, Tag, Peer, From} ->
            collect_bootstrap_route_fetches(Tag, [{Peer, From} | Acc])
    after 50 ->
        lists:reverse(Acc)
    end.

collect_long_current_fetches(Acc) ->
    receive
        {long_current_fetch, From} ->
            collect_long_current_fetches([From | Acc])
    after 50 ->
        lists:reverse(Acc)
    end.

phase_session_files(Dir, Identity) ->
    CacheNs = quod_foreign_log:cache_namespace(Identity),
    CacheDir = quod_ledger_store:ns_dir(Dir, CacheNs),
    {ok, Names} = file:list_dir(CacheDir),
    lists:sort(
      [Name || Name <- Names,
               lists:prefix("dtx-phases.", Name),
               lists:suffix(".dets", Name)]).

cache_checkpoint(Dir, Identity = {Ns, Anchor}) ->
    CacheNs = quod_foreign_log:cache_namespace(Identity),
    Path = filename:join(
             quod_ledger_store:ns_dir(Dir, CacheNs), "checkpoint.term"),
    {ok, Blob} = file:read_file(Path),
    {quod_foreign_log_checkpoint, _Version, Ns, Anchor,
     Height, _Bytes, Projection} = binary_to_term(Blob, [safe]),
    {Height, Projection}.

start_owner(Dir, Fetch) ->
    start_owner_opts(Dir, Fetch, #{}).

start_owner_opts(Dir, Fetch, Extra) ->
    {ok, _} = application:ensure_all_started(gproc),
    case quod_reg:where({foreign_log, node}) of
        Existing when is_pid(Existing) -> stop_owner(Existing);
        undefined -> ok
    end,
    {ok, Pid} = quod_foreign_log:start_link(
                  maps:merge(
                    #{cache_dir => Dir, fetch_fun => Fetch,
                      page_timeout_ms => 1000}, Extra)),
    Pid.

receive_follow(FollowRef, Identity) ->
    receive
        {quod_foreign_follow, FollowRef, NoticeRef, Identity, Notice} ->
            {NoticeRef, Notice}
    after 3000 ->
        error({missing_follow_notice, FollowRef, Identity})
    end.

receive_follow_resnapshot(FollowRef, Identity) ->
    Notice = receive_follow(FollowRef, Identity),
    case element(2, Notice) of
        {resnapshot, _, _, _} ->
            Notice;
        {building, _} ->
            ok = quod_foreign_log:ack(
                   FollowRef, element(1, Notice)),
            receive_follow_resnapshot(FollowRef, Identity);
        Unexpected ->
            error({unexpected_follow_notice, Unexpected})
    end.

fake_feed_link(Owner) ->
    receive
        {send_ordered, Payload} ->
            Owner ! {fake_feed_link_send, self(), Payload},
            fake_feed_link(Owner);
        close ->
            Owner ! {fake_feed_link_closed, self()}
    end.

receive_fake_feed_send(Link, Timeout) ->
    receive
        {fake_feed_link_send, Link, Payload} -> Payload
    after Timeout ->
        false
    end.

wait_follow_count(Expected, Left) when Left =< 0 ->
    case maps:get(follow_consumers, quod_foreign_log:stats()) of
        Expected -> ok;
        Actual -> error({follow_count_timeout, Expected, Actual})
    end;
wait_follow_count(Expected, Left) ->
    case maps:get(follow_consumers, quod_foreign_log:stats()) of
        Expected -> ok;
        _ -> receive after 10 -> ok end,
             wait_follow_count(Expected, Left - 10)
    end.

stop_owner(Pid) when is_pid(Pid) ->
    unlink(Pid),
    try gen_server:stop(Pid) catch exit:_ -> ok end.

restore_application_env(Key, {ok, Value}) ->
    application:set_env(quod, Key, Value);
restore_application_env(Key, undefined) ->
    application:unset_env(quod, Key).

control(Kind, Target, Record) ->
    {quod_dtx_control, 2, Kind, Target, Record,
     key(240), key(241), 1, 0, <<0:512>>}.

ref({Ns, Anchor}, Slot, Seed) ->
    {ok, Ref} = quod_dtx:certified_ref(
                  Ns, Anchor, Slot, key(Seed), key(Seed + 1),
                  <<"foreign-finality">>),
    Ref.

ref_with_digest({Ns, Anchor}, Slot, Seed, Digest) ->
    {ok, Ref} = quod_dtx:certified_ref(
                  Ns, Anchor, Slot, key(Seed), Digest,
                  <<"foreign-finality">>),
    Ref.

largest_payload(Ns) ->
    largest_payload(Ns, 0, ?MAX_BLOCK_BYTES).

largest_payload(Ns, Low, High) when Low + 1 >= High ->
    payload(Ns, Low);
largest_payload(Ns, Low, High) ->
    Mid = (Low + High) div 2,
    Candidate = payload(Ns, Mid),
    case byte_size(term_to_binary(Candidate, [deterministic]))
           =< ?MAX_BLOCK_BYTES of
        true -> largest_payload(Ns, Mid, High);
        false -> largest_payload(Ns, Low, Mid)
    end.

payload(Ns, Bytes) ->
    {batch,
     [#transaction{tx_id = key(250), origin = {Ns, key(251)},
                   proof_id = key(252), plan_digest = key(253),
                   goal = <<>>, result = <<>>,
                   diff = [{assert,
                            {{large_foreign_value,
                              binary:copy(<<0>>, Bytes)}, true}}],
                   read_check = #{}, author = key(254),
                   author_seq = 1, submitted_at = 1,
                   sig = <<0:512>>}]}.

unique_ns() ->
    <<"foreign:test:",
      (integer_to_binary(erlang:unique_integer([positive, monotonic])))/binary>>.

temp_dir(Suffix) ->
    filename:join(
      "/tmp",
      "quod_foreign_log_" ++ Suffix ++ "_" ++
          os:getpid() ++ "_" ++
          integer_to_list(erlang:unique_integer([positive, monotonic]))).

key(N) -> crypto:hash(sha256, term_to_binary({foreign_key, N})).

route_candidates(Routes) ->
    [{Peer, [Endpoint]} || {Peer, Endpoint} <- Routes].

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
        %% Exact verification writes a certified cache, then releases all
        %% owner memory because no proof or follow still owns this history.
        ?assertMatch(
           {ok, #{identity := Identity, phase := finalize}},
           quod_foreign_log:verify(Peer, Endpoint, Ref, finalize, 5000)),
        ?assertEqual(0, maps:get(histories, quod_foreign_log:stats())),
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
            ?assertEqual(0, maps:get(histories, quod_foreign_log:stats()))
        after
            stop_owner(Pid2)
        end
    after
        _ = file:del_dir_r(Dir)
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

follow_consumers_share_one_history_and_cleanup_exactly_test() ->
    Dir = temp_dir("follow-lifecycle"),
    NoFetch = fun(_, _, _, _, _) -> {error, unavailable} end,
    Pid = start_owner_opts(
            Dir, NoFetch,
            #{follow_poll_ms => 50, follow_retry_ms => 10,
              follow_max_retry_ms => 50}),
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
        ?assert(maps:get(follow_polls, FollowStats) > 0),
        ?assert(maps:get(follow_retries, FollowStats) > 0),

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

follow_owner_identity_and_consumer_down_are_fail_closed_test() ->
    Dir = temp_dir("follow-owner"),
    NoFetch = fun(_, _, _, _, _) -> {error, unavailable} end,
    Pid = start_owner_opts(
            Dir, NoFetch,
            #{follow_poll_ms => 1000, follow_retry_ms => 100,
              follow_max_retry_ms => 1000}),
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
        ?assertEqual(0, maps:get(histories, quod_foreign_log:stats())),
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
        ?assertEqual(2, maps:get(slot, Historical)),
        ?assertEqual(3, maps:get(slot, Current)),
        ?assertEqual(lists:sort([Old, New]), maps:get(committee, Current)),
        ?assertNotEqual(maps:get(committee_id, Historical),
                        maps:get(committee_id, Current)),
        ?assertEqual(
           lists:keysort(1, Routes), maps:get(route_candidates, Current))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
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
             SourceDir, maps:get(ref, Fixture), 5000))
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
             Identity, 5000)),
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
             SourceDir, Identity, 5000))
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
                 quod_foreign_log:current(Routes, Identity, 2000))
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
             Identity, 2000))
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
                 quod_foreign_log:verify_current(Routes, Ref, 2000))
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
             maps:get(ref, Fixture), 2000))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

current_view_timeout_releases_verified_cache_and_remains_reusable_test() ->
    Fixture = foreign_fixture(unique_ns()),
    Ns = maps:get(ns, Fixture),
    Peer = maps:get(pub, Fixture),
    Ref = maps:get(ref, Fixture),
    Routes = route_candidates([{Peer, {"127.0.0.1", 19000}}]),
    Mode = atomics:new(1, []),
    TestPid = self(),
    BaseFetch = peer_chain_fetch(Ns, maps:get(chain, Fixture), [Peer]),
    Fetch = fun(P, E, RequestedNs, From, To) ->
                    TestPid ! {current_fetch_from, From},
                    case atomics:get(Mode, 1) of
                        0 -> BaseFetch(P, E, RequestedNs, From, To);
                        1 -> receive after 250 -> {error, delayed} end
                    end
            end,
    Dir = temp_dir("current-timeout"),
    Pid = start_owner(Dir, Fetch),
    try
        ?assertMatch(
           {ok, _},
           quod_foreign_log:verify(
             Peer, {"127.0.0.1", 19000}, Ref, finalize, 2000)),
        flush_fetches(),
        ok = atomics:put(Mode, 1, 1),
        Started = erlang:monotonic_time(millisecond),
        ?assertEqual(
           {error, retry},
           quod_foreign_log:verify_current(Routes, Ref, 100)),
        ?assert(erlang:monotonic_time(millisecond) - Started < 1000),
        ?assertEqual(0, maps:get(pending, quod_foreign_log:stats())),
        ?assertEqual(0, maps:get(histories, quod_foreign_log:stats())),
        ok = atomics:put(Mode, 1, 0),
        ?assertMatch(
           {ok, #{slot := 2}},
           quod_foreign_log:verify_current(Routes, Ref, 2000)),
        Fetches = collect_fetches([]),
        ?assert(Fetches =/= []),
        ?assert(lists:all(fun(From) -> From =:= 3 end, Fetches))
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
           {ok, #{phase := prepare, generation := 1}},
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
           {ok, #{phase := prepare, generation := 1}},
           quod_foreign_log:verify_local(
             SourceDir, maps:get(ref, Fixture), prepare, 5000))
    after
        stop_owner(Pid),
        _ = file:del_dir_r(SourceDir),
        _ = file:del_dir_r(CacheDir)
    end.

cached_earlier_reference_uses_its_own_post_slot_projection_test() ->
    Fixture = prepared_then_committed_fixture(unique_ns()),
    Dir = temp_dir("historical-generation"),
    Ns = maps:get(ns, Fixture),
    Pid = start_owner(Dir, chain_fetch(Ns, maps:get(chain, Fixture))),
    Peer = maps:get(pub, Fixture),
    Endpoint = {"127.0.0.1", 19097},
    try
        ?assertMatch(
           {ok, #{phase := finalize, generation := 2}},
           quod_foreign_log:verify(
             Peer, Endpoint, maps:get(finalize_ref, Fixture),
             finalize, 5000)),
        %% The cache is now at slot 3.  Evidence for its slot-2 Prepare must
        %% still expose slot 2's generation rather than the cached head state.
        ?assertMatch(
           {ok, #{phase := prepare, generation := 1}},
           quod_foreign_log:verify(
             Peer, Endpoint, maps:get(prepare_ref, Fixture), prepare, 5000))
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

selected_sources_keep_the_per_peer_pending_bound_test() ->
    Dir = temp_dir("peer-bound"),
    TestPid = self(),
    Blocking =
        fun(_Peer, _Endpoint, Ns, _From, _To) ->
            TestPid ! {fetch_started, Ns, self()},
            receive release -> {error, retry} end
        end,
    Pid = start_owner(Dir, Blocking),
    Peer = key(94),
    Endpoint = {"127.0.0.1", 19094},
    IdentityRefs =
        [begin
             Identity = {<<"peer-bound:", I>>, key(210 + I)},
             {Identity, ref(Identity, 1, 220 + I)}
         end || I <- lists:seq(
                         1, ?QUOD_MAX_FOREIGN_PENDING_PER_PEER + 1)],
    lists:foreach(
      fun({Identity, _Ref}) ->
          quod_foreign_log:observe_candidate(
            Identity, {Peer, Endpoint})
      end, IdentityRefs),
    Callers =
        [spawn(fun() ->
                   TestPid ! {verify_result, self(),
                              quod_foreign_log:verify_reference(
                                Ref, finalize, 10000)}
               end)
         || {_Identity, Ref} <- lists:sublist(
                                  IdentityRefs,
                                  ?QUOD_MAX_FOREIGN_PENDING_PER_PEER)],
    try
        Workers = receive_fetches(?QUOD_MAX_FOREIGN_PENDING_PER_PEER, []),
        ?assertEqual(
           {error, busy},
           quod_foreign_log:verify_reference(
             element(2, lists:last(IdentityRefs)), finalize, 1000)),
        ?assertEqual(?QUOD_MAX_FOREIGN_PENDING_PER_PEER,
                     maps:get(pending, quod_foreign_log:stats())),
        _ = [W ! release || W <- Workers],
        _ = [receive {verify_result, Caller, {error, retry}} -> ok
             after 3000 -> error({missing_result, Caller}) end
             || Caller <- Callers]
    after
        stop_owner(Pid),
        _ = file:del_dir_r(Dir)
    end.

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
      chain => [Genesis, Entry], ref => Ref, control => Control}.

signed_content_fixture(Ns) ->
    Base = fixture_base(Ns),
    Pub = maps:get(pub, Base),
    Signer = maps:get(signer, Base),
    Anchor = maps:get(anchor, Base),
    Admission = maps:get(admission, Base),
    Network = key(254),
    RequestFixture = quod_ct:signed_dtx_begin_fixture(
                       #{target => {Ns, Anchor}, network => Network}),
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
    Other = {<<"prepare-other:", Ns/binary>>, key(81)},
    {ok, DiffBlob} = quod_wire_term:encode_canonical(
                       [{assert, {{prepared_fixture, Ns}, true}}]),
    {ok, EmptyBlob} = quod_wire_term:encode_canonical([]),
    Core = #{target => Binding, base_height => 1,
             proof_id => key(83), origin => Origin,
             principal => anonymous, request_binding => none,
             overlay_generation => 0,
             diff_ops => 1, read_functors => 0, effects_count => 0,
             diff => DiffBlob, read_check => EmptyBlob,
             effects => EmptyBlob, live_bridges => EmptyBlob,
             transcript => EmptyBlob},
    PlanBytes = term_to_binary(
                  {<<"quod.dtx.plan">>, 7, Core}, [deterministic]),
    Plan = {quod_plan, Core, Pub,
            quod_identity:sign(PlanBytes, Signer)},
    {ok, PlanBlob} = quod_dtx:encode(Plan),
    OtherCore = Core#{target := Other, diff_ops := 0, diff := EmptyBlob},
    OtherPlanBytes = term_to_binary(
                       {<<"quod.dtx.plan">>, 7, OtherCore}, [deterministic]),
    OtherPlan = {quod_plan, OtherCore, Pub,
                 quod_identity:sign(OtherPlanBytes, Signer)},
    {ok, OtherPlanBlob} = quod_dtx:encode(OtherPlan),
    {ok, GoalBlob} = quod_durable_term:encode_goal({foreign_prepare, Ns}),
    {ok, ResultBlob} = quod_durable_term:encode_result(#{}),
    {ok, Manifest} = quod_dtx:new_manifest(
                       #{proof_id => key(83),
                         coordinator =>
                             {element(1, Origin), element(2, Origin),
                              Pub, Admission},
                         nonce => key(82), principal => anonymous,
                         goal => GoalBlob, result => ResultBlob,
                         request_binding => none,
                         participants =>
                             [{Binding, quod_dtx:digest(Plan)},
                              {Other, quod_dtx:digest(OtherPlan)}]}),
    {ok, Attestation} = quod_dtx:attest_plan(
                          Binding, Plan, Manifest, Signer),
    {ok, OtherAttestation} = quod_dtx:attest_plan(
                               Other, OtherPlan, Manifest, Signer),
    {ok, Begin} = quod_dtx:new_begin(
                    Manifest, none,
                    [{Binding, quod_dtx:digest(Plan), PlanBlob, Attestation},
                     {Other, quod_dtx:digest(OtherPlan), OtherPlanBlob,
                      OtherAttestation}]),
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
    {Pub, Seed} = quod_identity:generate(),
    Signer = #{pubkey => Pub,
               key => quod_identity:key_term({Pub, Seed})},
    Genesis = genesis(Ns, Pub),
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
    Data = {dtx, ControlBlob},
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

genesis(Ns, Pub) ->
    Nonce = key(44),
    Tx = quod_simplex:test_genesis_tx(
           #{node_id => Pub, mode => create, committee => [],
             node_addr => {"127.0.0.1", 19000}},
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

receive_fetches(0, Acc) -> Acc;
receive_fetches(N, Acc) ->
    receive
        {fetch_started, _Ns, Worker} ->
            receive_fetches(N - 1, [Worker | Acc])
    after 3000 ->
        error({missing_fetches, N})
    end.

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
          integer_to_list(erlang:unique_integer([positive, monotonic]))).

key(N) -> crypto:hash(sha256, term_to_binary({foreign_key, N})).

route_candidates(Routes) ->
    [{Peer, [Endpoint]} || {Peer, Endpoint} <- Routes].

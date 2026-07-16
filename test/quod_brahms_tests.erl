-module(quod_brahms_tests).
-include_lib("eunit/include/eunit.hrl").

-import(quod_brahms, [split_counts/1, reconstruct/8, encode/1, decode/1, take_random/2, clean_resp/3,
                      due_probes/3, probe_candidates/4, prune_tombstones/3, gossip_targets/3,
                      stale_conns/4]).

-define(CFG, #{view_size => 16, alpha => 0.45, beta => 0.45, gamma => 0.10}).

%% --- split_counts: shares sum to ℓ --------------------------------------

split_counts_test() ->
    {L1, L2, L3} = split_counts(?CFG),
    ?assertEqual(16, L1 + L2 + L3),
    ?assertEqual(7, L1),
    ?assertEqual(7, L2),
    ?assertEqual(2, L3).

%% the sampler must ALWAYS contribute (L3 >= 1), AND the three counts must sum to
%% exactly view_size — else reconstruct's take(L, ...) truncates the tail (the
%% sample R), dropping the guaranteed slot. Both edge configs below would overshoot
%% (L1+L2 >= L) without the budget cap in split_counts.
split_counts_no_starvation_test() ->
    {L1, L2, L3} = split_counts(#{view_size => 16, alpha => 0.5, beta => 0.5, gamma => 0.0}),
    ?assert(L3 >= 1),
    ?assertEqual(16, L1 + L2 + L3),
    {A1, A2, A3} = split_counts(#{view_size => 16, alpha => 0.49, beta => 0.49, gamma => 0.02}),
    ?assert(A3 >= 1),
    ?assertEqual(16, A1 + A2 + A3).

%% --- pull responses are capped (pulls are attacker-controllable too) ----

clean_resp_caps_and_strips_self_test() ->
    Flood = [<<I:16>> || I <- lists:seq(1, 1000)],
    ?assert(length(clean_resp(Flood, 16, self_id)) =< 16),
    ?assertEqual([a, b], clean_resp([self_id, a, b], 16, self_id)).

improper_pull_response_is_rejected_test() ->
    %% OTP's is_list/1 accepts this outer cons, while lists:sublist/2 crashes.
    ?assert(is_list([a | malformed_tail])),
    ?assertEqual([], clean_resp([a | malformed_tail], 16, self_id)).

%% --- pick_contact: sample_contact/2's pure core (the download-contact pick) ---
%% Self is filtered by the node's ADDRESS (node_addr) — the pull clients' node_id is their PUBKEY,
%% which never equals a {Host, Port} seed, so filtering on it would be a silent no-op (the live
%% self-at-seed-head wedge). The pick is random, so the never-self properties are asserted over
%% many draws.

-define(SELF,  {"10.0.0.1", 14567}).
-define(OTHER, {"10.0.0.2", 14567}).

pick_contact_prefers_view_test() ->
    %% a live view peer wins over the static seeds (the seeds are only the cold-start fallback)
    ?assertEqual(?OTHER, quod_brahms:pick_contact([?OTHER], [{"10.0.0.9", 1}], ?SELF)).

pick_contact_never_self_test() ->
    %% self in BOTH pools, alongside a real peer: every draw must return the peer, never self
    ?assert(lists:all(fun(_) -> quod_brahms:pick_contact([?SELF, ?OTHER], [?SELF], ?SELF) =:= ?OTHER end,
                      lists:seq(1, 100))),
    %% THE WEDGE SHAPE: empty view, self at the seed HEAD — must always pick the other seed
    ?assert(lists:all(fun(_) -> quod_brahms:pick_contact([], [?SELF, ?OTHER], ?SELF) =:= ?OTHER end,
                      lists:seq(1, 100))).

pick_contact_seed_fallback_test() ->
    %% empty view (cold start / Brahms not running) falls back to the self-filtered seeds
    ?assertEqual(?OTHER, quod_brahms:pick_contact([], [?OTHER], ?SELF)).

pick_contact_isolated_test() ->
    ?assertEqual(none, quod_brahms:pick_contact([], [], ?SELF)),                  %% nothing anywhere
    ?assertEqual(none, quod_brahms:pick_contact([?SELF], [?SELF], ?SELF)),        %% only ourselves
    ?assertEqual(none, quod_brahms:pick_contact([], [?SELF, ?SELF], ?SELF)).      %% dup self seeds

pick_contact_no_self_addr_test() ->
    %% node_addr unset (legacy/test boot): nothing is filtered, the seeds stay usable
    ?assertEqual(?OTHER, quod_brahms:pick_contact([], [?OTHER], undefined)).

%% --- reconstruct prioritizes the mixed candidates over OldV (no sort bias)
%% A sort-biased impl (usort + take-smallest) would wrongly fill V with the
%% low-sorting OldV ids instead of the high-sorting mixed candidates.
reconstruct_prioritizes_candidates_test() ->
    Push = [<<"z1">>], Pull = [<<"z2">>], Smpl = [<<"z3">>],
    OldV = [<<"a1">>, <<"a2">>, <<"a3">>, <<"a4">>],
    V = reconstruct(OldV, Push, Pull, Smpl, {1, 1, 1}, 3, self_id, false),
    ?assertEqual(3, length(V)),
    [?assert(lists:member(Z, V)) || Z <- [<<"z1">>, <<"z2">>, <<"z3">>]].

%% --- gossip_targets: push AND pull are non-empty even for tiny views -----
%% Regression for the small-network starvation bug: the old disjoint slice gave an
%% EMPTY pull set whenever |V| =< L1 (so a 3-node cluster never pulled). Canonical
%% Brahms picks push/pull independently, so both are non-empty whenever V is.
gossip_targets_small_view_pulls_test() ->
    {Push2, Pull2} = gossip_targets(7, 7, [a, b]),       %% |V|=2 <= L1=7
    ?assertEqual([a, b], lists:sort(Push2)),
    ?assertEqual([a, b], lists:sort(Pull2)),             %% pull NOT empty
    {Push1, Pull1} = gossip_targets(7, 7, [a]),          %% single peer
    ?assertEqual([a], Push1),
    ?assertEqual([a], Pull1).

%% at scale each set is bounded by its quota and drawn from V (overlap allowed).
gossip_targets_bounded_test() ->
    V = lists:seq(1, 16),
    {Push, Pull} = gossip_targets(7, 7, V),
    ?assertEqual(7, length(Push)),
    ?assertEqual(7, length(Pull)),
    [?assert(lists:member(X, V)) || X <- Push ++ Pull].

%% --- liveness: stale_conns returns cached peers silent >= idle rounds -------
%% Liveness is recency of RECEIPT, not holding a link. A cached peer we haven't
%% heard from in conn_idle_rounds is "stale" and gets its link expired (then the
%% probe path re-validates). A never-heard peer (default 0) is stale once R hits
%% the idle window.
stale_conns_test() ->
    Conns = #{a => link_a, b => link_b, c => link_c},   %% values irrelevant; only keys used
    LH    = #{a => 10, b => 5},                          %% c never heard from
    %% R=12, idle=6: a (age 2) fresh; b (age 7) stale; c (age 12 via default 0) stale
    ?assertEqual([b, c], lists:sort(stale_conns(Conns, LH, 12, 6))),
    ?assertEqual([],     stale_conns(#{a => l}, #{a => 10}, 12, 6)),   %% all fresh
    ?assertEqual([a],    stale_conns(#{a => l}, #{}, 6, 6)),           %% never-heard, at window
    ?assertEqual([],     stale_conns(#{a => l}, #{}, 5, 6)).           %% never-heard, before window

%% N counts signed stable identities, never their dynamic endpoint.
population_estimate_uses_signed_stable_identity_test_() ->
    {setup,
     fun() -> {ok, Started} = application:ensure_all_started(gproc), Started end,
     fun(Started) -> [application:stop(A) || A <- Started], ok end,
     [{"signed stable identities contribute to total population N",
       fun population_estimate_uses_signed_stable_identity/0}]}.

population_estimate_uses_signed_stable_identity() ->
    Ns = <<"ont:live-estimate">>,
    SelfAddr = {"127.0.0.1", 65101},
    SelfIdentity = test_identity(),
    PeerIdentity = test_identity(),
    PeerKey = maps:get(pubkey, PeerIdentity),
    PeerAddr = {"127.0.0.1", 65102},
    GhostAddr = {"127.0.0.1", 65103},
    {ok, B} = quod_brahms:start_link(Ns, #{node_id => SelfAddr, seed_peers => [PeerAddr],
                                           population_identity => SelfIdentity,
                                           round_ms => 10000, collect_ms => 100, jitter => 0.0}),
    PeerPopulation = quod_brahms_population:tick(
                       quod_brahms_population:new(PeerIdentity, 128, 60000, 10000),
                       erlang:system_time(millisecond)),
    Heartbeat = quod_brahms_population:self_record(PeerPopulation),
    B ! {quod_message, {{PeerKey, PeerAddr}, self()}, Ns, encode({push, GhostAddr, Heartbeat})},
    ?assertEqual(2, maps:get(estimated_n, quod_brahms:stats(Ns))),
    gen_statem:stop(B).

test_identity() ->
    {Pub, Seed} = quod_identity:generate(),
    #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})}.

%% --- take_random: bounded, distinct, subset -----------------------------

take_random_test() ->
    L = [a, b, c, d, e],
    R = take_random(3, L),
    ?assertEqual(3, length(R)),
    ?assertEqual(3, length(lists:usort(R))),     %% distinct
    [?assert(lists:member(X, L)) || X <- R],
    ?assertEqual(lists:sort(L), lists:sort(take_random(99, L))).  %% N>=len -> all

%% --- reconstruct: under attack (Limited) the PUSH contribution is dropped,
%% but pull + sample still rebuild V (so the sampler keeps healing it). -----

reconstruct_limited_drops_push_test() ->
    V = reconstruct([old], [evil_push], [good_pull], [good_sample],
                    {1, 1, 1}, 16, self_id, true),
    ?assertNot(lists:member(evil_push, V)),
    ?assert(lists:member(good_pull, V)),
    ?assert(lists:member(good_sample, V)).

%% --- reconstruct: mixes sources, excludes self, bounded, non-empty ------

reconstruct_mix_test() ->
    Old   = [o1, o2],
    Push  = [a, b, c],
    Pull  = [d, e, f],
    Smpl  = [g, h],
    V = reconstruct(Old, Push, Pull, Smpl, {7, 7, 2}, 16, self_id, false),
    ?assert(length(V) =< 16),
    ?assert(length(V) >= 1),
    ?assertNot(lists:member(self_id, V)),
    All = Old ++ Push ++ Pull ++ Smpl,
    [?assert(lists:member(X, All)) || X <- V].

%% --- reconstruct: self is never admitted, even if pushed ----------------

reconstruct_excludes_self_test() ->
    V = reconstruct([], [self_id, a], [self_id], [self_id], {7, 7, 2}, 16, self_id, false),
    ?assertNot(lists:member(self_id, V)),
    ?assert(lists:member(a, V)).

%% --- reconstruct: empty candidates fall back to old view (no collapse) --

reconstruct_no_collapse_test() ->
    Old = [o1, o2],
    ?assertEqual(Old, reconstruct(Old, [], [], [], {7, 7, 2}, 16, self_id, false)).

%% --- reconstruct: stale OLD-view ids are NOT recycled into the new view -----
%% Regression for the view-inflation bug. Canonical Brahms rebuilds V ONLY from
%% this round's {push, pull, sample}; the old impl padded V up to view_size from
%% `Sampled ++ OldV`, recycling dead ids forever. With non-empty push/pull/sample,
%% OldV ids absent from all three must NOT appear in the new view — so on a small
%% network V tracks the live (gossiped) set instead of inflating.
reconstruct_excludes_oldv_test() ->
    OldV = [stale1, stale2, stale3, stale4, stale5],   %% none of these are gossiped this round
    V = reconstruct(OldV, [live_a], [live_b], [live_c], {7, 7, 2}, 16, self_id, false),
    [?assertNot(lists:member(S, V)) || S <- OldV],
    ?assertEqual([live_a, live_b, live_c], lists:sort(V)).

%% --- wire codec: roundtrip + defensive decode ---------------------------

codec_roundtrip_test() ->
    Msgs = [{push, <<"n1">>}, {pull_req, {"127.0.0.1", 14567}}, {pull_resp, <<"me">>, [a, b]}],
    [?assertEqual(M, decode(encode(M))) || M <- Msgs].

decode_garbage_is_safe_test() ->
    ?assertEqual(error, decode(<<"not erlang term binary">>)),
    ?assertEqual(error, decode(<<0, 1, 2, 3>>)).

%% --- reactive repair: a cached link dying with a buffered send re-opens NOW ---
%% (instead of waiting for the next round tick). Drives the real statem with a
%% stubbed transport authority; a long collect window keeps the round from firing
%% a second time so the state is deterministic.
reactive_reopen_test_() ->
    {setup,
     fun() -> {ok, Started} = application:ensure_all_started(gproc), Started end,
     fun(Started) -> [application:stop(A) || A <- Started], ok end,
     [{"a link death with a buffered send triggers an immediate re-open",
       fun reactive_reopen/0}]}.

reactive_reopen() ->
    Parent = self(),
    %% stub the transport authority: record every open_link cast as {open_link, NodeId, Ns}
    Stub = spawn(fun() -> true = quod_reg:reg({transport, node}), stub_loop(Parent) end),
    Seed = {"127.0.0.1", 65000},
    Ns   = <<"ont:reopen">>,
    {ok, B} = quod_brahms:start_link(Ns, #{node_id    => {"127.0.0.1", 65001},
                                           seed_peers => [Seed],
                                           round_ms   => 100,
                                           collect_ms => 10000,   %% stay in one round
                                           jitter     => 0.0}),
    %% round 1: do_round dials the uncached seed and buffers a payload for it
    receive {open_link, Seed, Ns} -> ok after 3000 -> erlang:error(no_first_open) end,
    %% the link comes up (brahms caches + monitors FakeLink), then dies while the
    %% send is still buffered -> the DOWN must re-open immediately
    FakeLink = spawn(fun() -> receive stop -> ok end end),
    B ! {link_up, Seed, Ns, FakeLink},
    timer:sleep(100),
    FakeLink ! stop,
    ?assertEqual(ok, receive {open_link, Seed, Ns} -> ok after 3000 -> timeout end),
    gen_statem:stop(B),
    exit(Stub, kill).

stub_loop(Parent) ->
    receive
        {'$gen_cast', {open_link, NodeId, Channel, _ReplyTo}} ->
            Parent ! {open_link, NodeId, Channel},
            stub_loop(Parent);
        _ ->
            stub_loop(Parent)
    end.

%% --- sample validation: due-probe selection (pure) ----------------------
%% A probe is "due" once it has been outstanding for >= probe_rounds rounds.
due_probes_test() ->
    Probing = #{a => 1, b => 3, c => 5},
    ?assertEqual([a, b], lists:sort(due_probes(Probing, 5, 2))),  %% c sent this round -> not due
    ?assertEqual([], due_probes(Probing, 5, 6)),                  %% none old enough
    ?assertEqual([a, b, c], lists:sort(due_probes(Probing, 5, 0))).

%% --- sample validation: probe candidate selection (pure) ----------------
%% Only COLD sampled ids: not self, not already linked, not already probing.
probe_candidates_test() ->
    Sample  = [a, b, c, a, self_id],     %% multiset with a dup + self
    Conns   = #{b => {self(), make_ref(), out}},
    Probing = #{c => 4},
    ?assertEqual([a], probe_candidates(Sample, Conns, Probing, self_id)),
    %% nothing cold -> nothing to probe
    ?assertEqual([], probe_candidates([self_id], #{}, #{}, self_id)),
    %% the pool is view ++ sample: an id present only via the VIEW (never won a
    %% sampler slot) is still a candidate, so dead view members get evicted too.
    ?assertEqual([viewonly], probe_candidates([viewonly], #{}, #{}, self_id)).

%% --- sample validation: an unanswered probe evicts the dead sample ------
%% Drive the real statem with a stub transport. The lone seed never answers a
%% probe, so within a couple of rounds it must be evicted from BOTH the view and
%% the sample (its sampler slot reset). This is the Brahms failure detector.
probe_evicts_dead_test_() ->
    {setup,
     fun() -> {ok, Started} = application:ensure_all_started(gproc), Started end,
     fun(Started) -> [application:stop(A) || A <- Started], ok end,
     [{"a sampled peer that never answers a probe is evicted + its slot reset",
       fun probe_evicts_dead/0}]}.

probe_evicts_dead() ->
    Parent = self(),
    Stub = spawn(fun() -> true = quod_reg:reg({transport, node}), stub_loop(Parent) end),
    Dead = {"127.0.0.1", 65055},
    Ns   = <<"ont:probe">>,
    {ok, B} = quod_brahms:start_link(Ns, #{node_id      => {"127.0.0.1", 65056},
                                           seed_peers   => [Dead],
                                           round_ms     => 50,
                                           collect_ms   => 10,
                                           jitter       => 0.0,
                                           probe_rounds => 1,
                                           probe_fanout => 5}),
    %% it probes the dead seed (open_link) and, getting no link_up, evicts it
    ?assertEqual(ok, receive {open_link, Dead, Ns} -> ok after 2000 -> timeout end),
    ?assertEqual(ok, wait_until(fun() ->
                                    not lists:member(Dead, quod_brahms:view(Ns)) andalso
                                    not lists:member(Dead, quod_brahms:sample(Ns))
                                end, 50, 60)),
    %% prove the removal was an EVICTION (probe path), not reconstruct churn
    ?assertMatch(#{evictions := E} when E >= 1, quod_brahms:stats(Ns)),
    gen_statem:stop(B),
    exit(Stub, kill).

wait_until(_F, _Ms, 0) -> timeout;
wait_until(F, Ms, N) ->
    case F() of
        true  -> ok;
        false -> timer:sleep(Ms), wait_until(F, Ms, N - 1)
    end.

%% --- tombstones: expiry (pure) ------------------------------------------
%% Keep ids younger than tombstone_rounds; drop the rest (age = now - stamped).
prune_tombstones_test() ->
    T = #{a => 1, b => 5, c => 9},
    ?assertEqual(#{c => 9}, prune_tombstones(T, 10, 5)),    %% a age9, b age5 expire; c age1 stays
    ?assertEqual(T,         prune_tombstones(T, 10, 100)),  %% none old enough
    ?assertEqual(#{},       prune_tombstones(T, 100, 5)).   %% all expired

%% --- tombstones: a re-gossiped dead id is NOT re-admitted ----------------
%% After the detector evicts the dead seed, a LIVE third party keeps pushing the
%% dead id back; the tombstone must keep it out (only the id itself could refute).
tombstone_blocks_readmission_test_() ->
    {setup,
     fun() -> {ok, Started} = application:ensure_all_started(gproc), Started end,
     fun(Started) -> [application:stop(A) || A <- Started], ok end,
     [{"a tombstoned dead id re-gossiped by a live peer stays out of view+sample",
       fun tombstone_blocks_readmission/0}]}.

tombstone_blocks_readmission() ->
    Parent = self(),
    Stub = spawn(fun() -> true = quod_reg:reg({transport, node}), stub_loop(Parent) end),
    Dead = {"127.0.0.1", 65077},
    Ns   = <<"ont:tomb">>,
    {ok, B} = quod_brahms:start_link(Ns, #{node_id          => {"127.0.0.1", 65078},
                                           seed_peers       => [Dead],
                                           round_ms         => 50,
                                           collect_ms       => 10,
                                           jitter           => 0.0,
                                           probe_rounds     => 1,
                                           probe_fanout     => 5,
                                           tombstone_rounds => 100}),
    %% the dead seed is probed, unanswered, evicted (and tombstoned)
    ?assertEqual(ok, receive {open_link, Dead, Ns} -> ok after 2000 -> timeout end),
    ?assertEqual(ok, wait_until(fun() -> not lists:member(Dead, quod_brahms:sample(Ns)) end, 50, 60)),
    #{evictions := E0} = quod_brahms:stats(Ns),
    ?assert(E0 >= 1),                                   %% the one real eviction happened
    %% a live third party re-gossips the dead id via push -> must be ignored
    Live     = {"127.0.0.1", 65079},
    FakeLink = spawn(fun() -> receive stop -> ok end end),
    [B ! {quod_message, {Live, FakeLink}, Ns, encode({push, Dead})} || _ <- lists:seq(1, 8)],
    timer:sleep(250),
    ?assertNot(lists:member(Dead, quod_brahms:sample(Ns))),
    ?assertNot(lists:member(Dead, quod_brahms:view(Ns))),
    %% the differential check: WITHOUT the tombstone the pushed id would re-enter
    %% the sampler, be re-probed, and re-evicted within these rounds -> evictions
    %% would climb. A stable counter proves the tombstone blocked re-admission.
    ?assertEqual(E0, maps:get(evictions, quod_brahms:stats(Ns))),
    FakeLink ! stop,
    gen_statem:stop(B),
    exit(Stub, kill).

%% --- link_error must NOT evict (only the probe-timeout path may) ----------
%% link_error fires on TRANSIENT stream-open failures over a live connection, not
%% just on a dead peer, so it must never evict/tombstone. Eviction is the probe
%% path's job alone. (Regression test for the link_error -> mark_dead bug.)
link_error_does_not_evict_test_() ->
    {setup,
     fun() -> {ok, Started} = application:ensure_all_started(gproc), Started end,
     fun(Started) -> [application:stop(A) || A <- Started], ok end,
     [{"a link_error leaves the peer in view+sample and does not bump evictions",
       fun link_error_does_not_evict/0}]}.

link_error_does_not_evict() ->
    Peer = {"127.0.0.1", 65091},
    Ns   = <<"ont:linkerr">>,
    %% round_ms huge so NO round (hence no probe, no transport call) fires during
    %% the test: the only thing that could evict is the link_error we inject.
    {ok, B} = quod_brahms:start_link(Ns, #{node_id    => {"127.0.0.1", 65092},
                                           seed_peers => [Peer],
                                           round_ms   => 3600000,
                                           collect_ms => 10,
                                           jitter     => 0.0}),
    ?assert(lists:member(Peer, quod_brahms:view(Ns))),     %% seed present at boot
    ?assert(lists:member(Peer, quod_brahms:sample(Ns))),
    B ! {link_error, Peer, Ns},                            %% transient open failure
    timer:sleep(100),
    ?assert(lists:member(Peer, quod_brahms:view(Ns))),     %% NOT evicted
    ?assert(lists:member(Peer, quod_brahms:sample(Ns))),   %% sampler slot NOT reset
    ?assertEqual(0, maps:get(evictions, quod_brahms:stats(Ns))),
    gen_statem:stop(B).

%% --- Fix B: a push received while IDLE is still admitted to V ------------
%% Pushes are unsolicited and mostly arrive OUTSIDE our short collect window. With a
%% tiny collect_ms (almost always idle) and probing off (so nothing is evicted), a
%% peer announced only via push must still reach the view — exercising the idle-push
%% accumulation path. (Membership is also supported via the sampler, so this guards
%% the codepath rather than discriminating push-pool vs sampler.)
idle_push_admitted_test_() ->
    {setup,
     fun() -> {ok, Started} = application:ensure_all_started(gproc), Started end,
     fun(Started) -> [application:stop(A) || A <- Started], ok end,
     [{"a push delivered while idle puts the pushed id into the view",
       fun idle_push_admitted/0}]}.

idle_push_admitted() ->
    Parent = self(),
    Stub = spawn(fun() -> true = quod_reg:reg({transport, node}), stub_loop(Parent) end),
    Seed = {"127.0.0.1", 65033},
    Ns   = <<"ont:idlepush">>,
    {ok, B} = quod_brahms:start_link(Ns, #{node_id      => {"127.0.0.1", 65034},
                                           seed_peers   => [Seed],
                                           round_ms     => 80,
                                           collect_ms   => 5,     %% ~6% collecting, ~94% idle
                                           jitter       => 0.0,
                                           probe_fanout => 0}),   %% no probing -> no eviction
    %% a NEW peer announces itself via push, repeatedly across rounds; the tiny
    %% collect window means these land in idle almost every time.
    New      = {"127.0.0.1", 65035},
    FakeLink = spawn(fun() -> receive stop -> ok end end),
    [begin
         B ! {quod_message, {New, FakeLink}, Ns, encode({push, New})},
         timer:sleep(15)
     end || _ <- lists:seq(1, 12)],
    ?assertEqual(ok, wait_until(fun() -> lists:member(New, quod_brahms:view(Ns)) end, 30, 40)),
    FakeLink ! stop,
    gen_statem:stop(B),
    exit(Stub, kill).

%% --- liveness: a dead peer we hold a LIVE cached link to is still evicted ----
%% The 30->3 regression. Over UDP a departed peer's link never dies (DOWN never
%% fires), so it lingers in `conns` and the old detector treated "in conns" as
%% "alive" and never probed it -> view never converged. Now expire_stale_conns
%% drops the silent link, the probe path re-dials (fails), and it is evicted.
%% Crucially we keep FakeLink ALIVE the whole time, so the eviction CANNOT be from
%% a link DOWN — it must come from the silence/expire/probe path.
stale_link_peer_evicted_test_() ->
    {setup,
     fun() -> {ok, Started} = application:ensure_all_started(gproc), Started end,
     fun(Started) -> [application:stop(A) || A <- Started], ok end,
     [{"a dead peer with a still-alive cached link is expired then probe-evicted",
       fun stale_link_peer_evicted/0}]}.

stale_link_peer_evicted() ->
    Parent = self(),
    Stub = spawn(fun() -> true = quod_reg:reg({transport, node}), stub_loop(Parent) end),
    Dead = {"127.0.0.1", 65061},
    Ns   = <<"ont:staleconn">>,
    {ok, B} = quod_brahms:start_link(Ns, #{node_id          => {"127.0.0.1", 65062},
                                           seed_peers       => [Dead],
                                           round_ms         => 60,
                                           collect_ms       => 8,
                                           jitter           => 0.0,
                                           conn_idle_rounds => 1,
                                           probe_rounds     => 1,
                                           probe_fanout     => 5,
                                           tombstone_rounds => 100}),
    %% One inbound message from Dead caches its (still-alive) link in `conns` and
    %% stamps last_heard — exactly the warm-but-doomed link from the scale test.
    FakeLink = spawn(fun() -> receive stop -> ok end end),
    B ! {quod_message, {Dead, FakeLink}, Ns, encode({push, Dead})},
    ?assertEqual(ok, wait_until(fun() ->
                                    lists:member(Dead, quod_brahms:view(Ns)) andalso
                                    is_process_alive(FakeLink)
                                end, 20, 30)),
    %% Now Dead goes silent (we send NO more messages from it) but FakeLink stays
    %% alive. It must still be evicted from view AND sample within a few rounds.
    ?assertEqual(ok, wait_until(fun() ->
                                    not lists:member(Dead, quod_brahms:view(Ns)) andalso
                                    not lists:member(Dead, quod_brahms:sample(Ns))
                                end, 60, 60)),
    ?assert(is_process_alive(FakeLink)),                 %% eviction was NOT from a link DOWN
    ?assertMatch(#{evictions := E} when E >= 1, quod_brahms:stats(Ns)),
    FakeLink ! stop,
    gen_statem:stop(B),
    exit(Stub, kill).

%% --- tombstone refresh: re-gossip keeps a dead id out PAST tombstone_rounds -----
%% The mass-departure convergence fix. tombstone_rounds is SHORT (3) here, and a
%% live third party re-gossips the dead id continuously for far more than 3 rounds.
%% WITHOUT refresh the tombstone would lapse after 3 rounds, the next push would
%% re-admit the dead id, and it would be re-probed + re-evicted (evictions climb) --
%% the churn the scale test exhibited. WITH refresh the tombstone is re-stamped on
%% every re-sighting, so the id stays out and evictions stay put.
tombstone_refresh_keeps_dead_out_test_() ->
    {setup,
     fun() -> {ok, Started} = application:ensure_all_started(gproc), Started end,
     fun(Started) -> [application:stop(A) || A <- Started], ok end,
     [{"re-gossip refreshes a tombstone so a dead id stays out past tombstone_rounds",
       fun tombstone_refresh_keeps_dead_out/0}]}.

tombstone_refresh_keeps_dead_out() ->
    Parent = self(),
    Stub = spawn(fun() -> true = quod_reg:reg({transport, node}), stub_loop(Parent) end),
    Dead = {"127.0.0.1", 65071},
    Ns   = <<"ont:tombrefresh">>,
    {ok, B} = quod_brahms:start_link(Ns, #{node_id          => {"127.0.0.1", 65072},
                                           seed_peers       => [Dead],
                                           round_ms         => 40,
                                           collect_ms       => 8,
                                           jitter           => 0.0,
                                           probe_rounds     => 1,
                                           probe_fanout     => 5,
                                           tombstone_rounds => 3}),   %% SHORT: would lapse fast
    %% the dead seed is probed, unanswered, evicted + tombstoned
    ?assertEqual(ok, wait_until(fun() -> not lists:member(Dead, quod_brahms:sample(Ns)) end, 40, 60)),
    #{evictions := E0} = quod_brahms:stats(Ns),
    ?assert(E0 >= 1),
    %% a LIVE third party re-gossips Dead for ~1.5s (~37 rounds >> tombstone_rounds=3).
    %% Each push must refresh the tombstone so Dead is NEVER re-admitted -> no new evictions.
    Live     = {"127.0.0.1", 65073},
    FakeLink = spawn(fun() -> receive stop -> ok end end),
    [begin
         B ! {quod_message, {Live, FakeLink}, Ns, encode({push, Dead})},
         timer:sleep(40)
     end || _ <- lists:seq(1, 37)],
    timer:sleep(150),
    ?assertNot(lists:member(Dead, quod_brahms:view(Ns))),
    ?assertNot(lists:member(Dead, quod_brahms:sample(Ns))),
    ?assertEqual(E0, maps:get(evictions, quod_brahms:stats(Ns))),   %% refresh kept it out: no re-eviction
    FakeLink ! stop,
    gen_statem:stop(B),
    exit(Stub, kill).

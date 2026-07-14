-module(growth_SUITE).
-moduledoc """
Slice D acceptance: **committee growth 1→4 over loopback QUIC with ZERO resolver pre-seeding**.

A founder (`mode=create`, N=1) and up to four `mode=join` joiners, each in its own OS Erlang node with
its own QUIC listener + Ed25519 identity. Unlike `simplex_SUITE` (which pre-seeds every peer's pubkey→addr
before co-founding), NOTHING here calls `quod_quic:learn` — every dial hint must establish itself: a
joiner reaches the founder by its seed ENDPOINT (catch-up); the founder learns the joiner from its inbound
request header; and — the seam this slice exists for — a member reaches a **brand-new member it never met**
because the new member's `peer_admitted` address is folded out of the committed log
(`quod_simplex:learn_member_endpoints` at catch-up, `quod_quic:learn` at the live commit). The N=3 probe is
the load-bearing proof: `quorum(3)=3` cannot commit unless J1 and J2 — who only ever learned each other
through the log — actually dial each other.

Keys are chained (`quod_ct:generate_key_gt`) so pubkey sort order = admission order, making round-robin
leadership computable at every N. The genesis is a test-local **default-open** `can_join` `.pl`; case 1
performs the production-rollout policy upgrade (`can_join :- peer_ready`) as one atomic tx, so every later
admit runs the real Slice-C readiness gate. Ordered; state threads via `save_config`.
""".
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("quod_ledger.hrl").
-import(quod_ct, [eventually/2, match_ok/1]).

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([policy_upgrade_live/1, admit_refused_mid_catchup/1,
         grow_to_two/1, grow_to_three/1, grow_to_four/1,
         rotation_sweep/1, byzantine_on_grown_committee/1,
         dead_member_removed/1, demote_to_observer/1]).
-export([pump/2]).   %% run ON the founder peer to build a multi-window log without per-write CT round-trips

-define(NS, <<"grow:d">>).
-define(FOUNDER_PORT, 15860).
-define(JOINER_PORTS, #{1 => 15861, 2 => 15862, 3 => 15863, 4 => 15864}).
-define(DELTA_MS, 4000).      %% Δ_timeout — above the cold first commit round, below the eventually budgets
-define(PUMP, 300).           %% > ?WINDOW (256): a multi-window log so catch-up spans >1 window (learn hook)
-define(SLOW_DIGEST, 7500).   %% J1's pinned digest period — the max readiness_config_ok/1 admits; its
                              %% ~6s jitter floor makes the mid-catchup admit refusal independent of catch-up speed

all() -> [policy_upgrade_live, admit_refused_mid_catchup,
          grow_to_two, grow_to_three, grow_to_four,
          rotation_sweep, byzantine_on_grown_committee,
          dead_member_removed, demote_to_observer].

%%%===================================================================
%%% suite setup: found N=1 on a default-open genesis; generate all keys
%%%===================================================================

init_per_suite(Config) ->
    {FPub, _} = FKey = quod_identity:generate(),
    %% chain the joiner keys so FPub < J1 < J2 < J3 < J4 — sort order = admission order, so the round-robin
    %% leader for any slot at any committee size is computable (via quod_simplex:leader/2).
    JKeys = chain_keys(FPub, 4),
    FAddr = {"127.0.0.1", ?FOUNDER_PORT},
    GenesisPl = write_genesis(Config),

    Founder = start_node(?FOUNDER_PORT, FKey, Config, #{},
                         #{mode => create, committee => [], genesis_file => GenesisPl}),
    ?assert(eventually(fun() -> slot(Founder) =:= 1 end, 10000)),   %% genesis committed
    GH = peer:call(Founder, quod_simplex, genesis_hash, [?NS]),
    ?assert(is_binary(GH)),
    start_brahms(Founder, FAddr, []),

    [{founder, Founder}, {fpub, FPub}, {faddr, FAddr}, {gh, GH},
     {genesis_pl, GenesisPl}, {jkeys, JKeys} | Config].

end_per_suite(Config) ->
    quod_ct:stop_all([?config(founder, Config)]),
    ok.

%%%===================================================================
%%% cases (ordered; joiner list threads via save_config)
%%%===================================================================

%% CASE 1 — the production-rollout step-2 dress rehearsal at N=1: swap the committed DEFAULT-OPEN can_join
%% for the peer_ready gate in ONE atomic transaction (retract the fact + assert the rule), then prove the
%% gate is live (a never-digested ghost is refused). This is a CONTENT change — no peer_admitted op — so it
%% commits via normal OCC, never the membership verdict; and every later admit runs under the upgraded rule.
policy_upgrade_live(Config) ->
    Founder = ?config(founder, Config),
    FPub    = ?config(fpub, Config),
    ?assert(eventually(fun() -> match_ok(prove(Founder, {acl_sovereign, {'X'}})) end, 20000)),  %% kb ready
    Rule    = {':-', {can_join, {'N'}, {'A'}, {'P'}}, {peer_ready, {'P'}}},
    Upgrade = {',', {retract, {can_join, {'X'}, {'Y'}, {'Z'}}}, {assertz, Rule}},
    ?assert(eventually(fun() -> match_ok(prove(Founder, Upgrade)) end, 20000)),
    %% the gate is now live: a ghost that never digested is refused (can_join :- peer_ready fails).
    {GhostPub, _} = quod_identity:generate(),
    ?assertEqual(fail, prove(Founder, {admit, GhostPub, "127.0.0.1", 9999})),
    ?assertEqual([FPub], committee(Founder)),   %% no membership change happened
    {save_config, []}.

%% CASE 2 — admit of a mid-catch-up node is refused. Pump a multi-window log, start J1 with a slow digest
%% period, and IMMEDIATELY assert the admit fails: a node that is mid-catch-up never digests (follows/4
%% false), and the first post-`done` digest can't fire before J1's ~6s jitter floor — so the refusal holds
%% regardless of how fast catch-up runs (DA#3: assert the refusal, not the transient state).
admit_refused_mid_catchup(Config) ->
    Founder = ?config(founder, Config),
    ok = peer:call(Founder, growth_SUITE, pump, [?NS, ?PUMP], 120000),
    ?assert(eventually(fun() -> slot(Founder) >= ?PUMP end, 60000)),
    J1 = {_J1Peer, J1Pub, J1Port} = start_joiner(1, Config, #{feed_anti_entropy_ms => ?SLOW_DIGEST}),
    %% immediately (within the digest-free floor) — the candidate cannot be ready yet, so the admit is
    %% refused regardless of how far catch-up has progressed (the refusal is what we assert, not any
    %% transient join state — that would be a tautology for a mode=join node and can race the 1s status budget).
    ?assertNot(peer_ready_at(Founder, J1Pub)),
    ?assertEqual(fail, prove(Founder, {admit, J1Pub, "127.0.0.1", J1Port})),
    {save_config, [J1]}.

%% CASE 3 — grow 1→2: once J1 has caught up and is digesting fresh, the admit commits; J1 self-promotes to
%% a voter; an UNPACED probe write (the promotion race, healed by Slice-B redrive) commits at quorum(2)=2.
grow_to_two(Config) ->
    Founder = ?config(founder, Config),
    [{J1Peer, J1Pub, J1Port} = J1] = prev_joiners(Config),
    ?assert(eventually(fun() -> synced(J1Peer) end, 60000)),
    admit(Config, [J1], J1Pub, J1Port),
    ExpectCommittee = lists:sort([?config(fpub, Config), J1Pub]),
    ?assert(eventually(fun() -> committee(Founder) =:= ExpectCommittee end, 20000)),
    ?assert(eventually(fun() -> committee(J1Peer) =:= ExpectCommittee end, 20000)),
    ?assert(eventually(fun() -> role(J1Peer) =:= validator end, 20000)),
    %% unpaced probe on the founder immediately (the race window); commits only if the joiner votes.
    probe(Config, [J1], {promoted, two}),
    {save_config, [J1]}.

%% CASE 4 — grow 2→3: the ZERO-PRE-SEED proof. J2 has met only the founder (seed) — it learned J1's address
%% ONLY by folding J1's peer_admitted fact out of the replayed log (Slice D). At quorum(3)=3 the probe can
%% commit only if J1 and J2 exchange shares, i.e. that fold actually let them dial each other.
grow_to_three(Config) ->
    Prev = prev_joiners(Config),
    J2 = start_joiner(2, Config, #{}),
    {J2Peer, J2Pub, J2Port} = J2,
    ?assert(eventually(fun() -> synced(J2Peer) end, 60000)),
    Members = [J2 | Prev],
    admit(Config, Members, J2Pub, J2Port),
    ExpectCommittee = member_pubs(Config, Members),
    [ ?assert(eventually(fun() -> committee(P) =:= ExpectCommittee end, 20000)) || P <- member_peers(Config, Members) ],
    ?assert(eventually(fun() -> role(J2Peer) =:= validator end, 20000)),
    probe(Config, Members, {grown, three}),   %% quorum(3)=3 ⇒ needs J1<->J2 dial
    {save_config, Members}.

%% CASE 5 — grow 3→4: at four members f=1, the first genuinely fault-tolerant committee (quorum(4)=3).
grow_to_four(Config) ->
    Prev = prev_joiners(Config),
    J3 = start_joiner(3, Config, #{}),
    {J3Peer, J3Pub, J3Port} = J3,
    ?assert(eventually(fun() -> synced(J3Peer) end, 60000)),
    Members = [J3 | Prev],
    admit(Config, Members, J3Pub, J3Port),
    ExpectCommittee = member_pubs(Config, Members),
    [ ?assert(eventually(fun() -> committee(P) =:= ExpectCommittee end, 20000)) || P <- member_peers(Config, Members) ],
    ?assert(eventually(fun() -> role(J3Peer) =:= validator end, 20000)),
    probe(Config, Members, {grown, four}),
    {save_config, Members}.

%% CASE 6 — rotation sweep at N=4: submit one write via each of four consecutive slot leaders. A non-leader
%% refuses ({error,{not_leader,_}}), so an accepted write through node X at slot S proves X led S; the four
%% accepting leaders must be the whole committee.
rotation_sweep(Config) ->
    Members = prev_joiners(Config),
    Peers   = member_peers(Config, Members),
    Pubs    = member_pubs(Config, Members),
    H0 = synced_height(Peers),
    Leaders = [ begin
                    Slot = H0 + I,
                    LPub = quod_simplex:leader(Slot, Pubs),   %% the real rotation fn (exported), not a copy
                    LPeer = peer_of(Config, Members, LPub),
                    ?assert(eventually(fun() -> match_ok(prove(LPeer, {assertz, {rot, Slot}})) end, 20000)),
                    ?assert(eventually(fun() -> synced_height(Peers) >= Slot end, 20000)),
                    LPub
                end || I <- lists:seq(1, length(Pubs)) ],
    ?assertEqual(lists:sort(Pubs), lists:usort(Leaders)),   %% every member led exactly one swept slot
    {save_config, Members}.

%% CASE 7 — Byzantine injection on the GROWN committee (grown ≡ co-founded): a crafted membership proposal
%% from the real slot leader's node is refused support by every honest validator, the slot skips, the
%% committee is unchanged, and an honest write still commits.
byzantine_on_grown_committee(Config) ->
    Members = prev_joiners(Config),
    Peers   = member_peers(Config, Members),
    Pubs    = member_pubs(Config, Members),
    H = synced_height(Peers),
    V = H + 1,
    LeaderPub  = quod_simplex:leader(V, Pubs),
    LeaderPeer = peer_of(Config, Members, LeaderPub),
    Before  = committee(hd(Peers)),
    RejBefore = rejects_total(Peers),
    Victim = ?config(fpub, Config),
    Evil   = tx([{retract, {{peer_admitted, Victim, "wrong-host", 9999, Victim}, true}}]),
    Ts     = erlang:system_time(millisecond) + 1000,
    Block  = #block{slot = V, parent = H, payload = [Evil], timestamp = Ts},
    Chan   = term_to_binary({log, ?NS}, [deterministic]),
    Frame  = quod_simplex:encode(?NS, {propose, Block}),
    _ = [peer:call(LeaderPeer, quod_quic, send, [Fp, Chan, Frame]) || Fp <- Pubs, Fp =/= LeaderPub],
    [ ?assert(eventually(fun() -> slot(P) >= V end, 20000)) || P <- Peers ],   %% skipped (noop), never committed
    ?assertEqual(Before, committee(hd(Peers))),
    ?assert(eventually(fun() -> rejects_total(Peers) > RejBefore end, 5000)),
    probe(Config, Members, {after_byzantine, V}),
    {save_config, Members}.

%% CASE 8 — dead member removed. Slice C REFUSES a dead candidate (the gate's job), so admit a LIVE J4
%% (N=5), then kill it and prove the 4 live still commit at quorum(5)=4, then remove the corpse (the retract
%% verdict is has_clause-only — liveness-agnostic — so a dead member CAN be removed).
dead_member_removed(Config) ->
    Prev = prev_joiners(Config),
    J4 = start_joiner(4, Config, #{}),
    {J4Peer, J4Pub, J4Port} = J4,
    ?assert(eventually(fun() -> synced(J4Peer) end, 60000)),
    Five = [J4 | Prev],
    admit(Config, Five, J4Pub, J4Port),
    FivePubs = member_pubs(Config, Five),
    [ ?assert(eventually(fun() -> committee(P) =:= FivePubs end, 20000)) || P <- member_peers(Config, Five) ],
    probe(Config, Five, {five, alive}),   %% proves J4 votes at quorum(5)=4

    %% kill J4; a probe on the four live members can only commit by complaint-skipping J4's slots first
    %% (quorum(5)=4 = every live member) and then committing under a live leader — the retrying `probe`
    %% handles the skip→rotate→commit exactly like simplex_SUITE's leader_failover. This proves the 4 live
    %% still make progress with a corpse in the committee.
    ok = peer:stop(J4Peer),
    Live = Prev,
    LivePeers = member_peers(Config, Live),
    probe(Config, Live, {corpse, in, committee}),

    %% remove the corpse: the retract verdict needs only that the exact peer_admitted clause is present
    %% (liveness is never consulted), so a DEAD member is removable. Back to N=4.
    remove(Config, Live, J4Pub),
    FourPubs = member_pubs(Config, Live),
    [ ?assert(eventually(fun() -> committee(P) =:= FourPubs end, 20000)) || P <- LivePeers ],
    probe(Config, Live, {corpse, removed}),
    {save_config, Live}.

%% CASE 9 — demote a LIVE member (4→3): J3 commit-signs its own removal, then degrades to a feed-following
%% observer — role=observer, and its height still tracks new commits via the feed with the fact in its KB.
demote_to_observer(Config) ->
    Members = prev_joiners(Config),
    %% demote the highest-pubkey member (a real voter, never the founder) — leadership order is by pubkey,
    %% so this is a well-defined live member.
    {DemotePeer, DemotePub, _} = lists:last(lists:keysort(2, Members)),
    Remaining = [M || M <- Members, element(2, M) =/= DemotePub],
    remove(Config, Members, DemotePub),
    RemainingPubs = member_pubs(Config, Remaining),
    [ ?assert(eventually(fun() -> committee(P) =:= RemainingPubs end, 20000)) || P <- member_peers(Config, Members) ],
    ?assert(eventually(fun() -> role(DemotePeer) =:= observer end, 20000)),
    ?assert(eventually(fun() -> synced(DemotePeer) end, 20000)),
    %% the demoted node now FOLLOWS the feed: a fresh write on the remaining committee reaches its KB.
    probe(Config, Remaining, {aftr, demote}),
    ?assert(eventually(fun() -> match_ok(prove(DemotePeer, {aftr, {'X'}})) end, 20000)),
    {save_config, Remaining}.

%%%===================================================================
%%% growth helpers — commit a write/admit/remove through the current leader (retried, zero pre-seed)
%%%===================================================================

%% Commit `Goal` by trying it on every member until one accepts (a non-leader redirects; the leader parks
%% until commit and returns {ok,_,_}). Retried under `eventually`, so an admit that fails at the submitter
%% because the candidate isn't digesting-fresh yet simply re-tries until it is.
commit(Peers, Goal, Budget) ->
    eventually(fun() -> lists:any(fun(P) -> match_ok(prove(P, Goal)) end, Peers) end, Budget).

admit(Config, Members, Pub, Port) ->
    Peers = member_peers(Config, Members),
    ?assert(commit(Peers, {admit, Pub, "127.0.0.1", Port}, 40000)).

remove(Config, Members, Pub) ->
    Peers = member_peers(Config, Members),
    ?assert(commit(Peers, {remove, Pub}, 40000)).

%% A probe write that must commit and land in EVERY member's KB (all heights converge, fact readable).
%% Read back the GROUND fact directly — an exact match (a variable-filled query would match any same-shape
%% fact, weakening the check).
probe(Config, Members, Fact) ->
    Peers = member_peers(Config, Members),
    ?assert(commit(Peers, {assertz, Fact}, 40000)),
    [ ?assert(eventually(fun() -> match_ok(prove(P, Fact)) end, 20000)) || P <- Peers ].

%%%===================================================================
%%% node harness (one OS node each; own identity + QUIC listener) — NO resolver pre-seeding
%%%===================================================================

start_joiner(N, Config, EnvOverrides) ->
    Port = maps:get(N, ?JOINER_PORTS),
    Key  = {Pub, _} = lists:nth(N, ?config(jkeys, Config)),
    Extra = #{mode => join, genesis_hash => ?config(gh, Config), seed_peers => [?config(faddr, Config)]},
    Peer = start_node(Port, Key, Config, EnvOverrides, Extra),
    start_brahms(Peer, {"127.0.0.1", Port}, [?config(faddr, Config)]),
    {Peer, Pub, Port}.

%% Start one node in its own OS node: identity env, QUIC listener, fast Δ, then the namespace. Crucially
%% NO quod_quic:learn — every pubkey→addr hint must establish itself (the point of the suite).
start_node(Port, {Pub, Seed}, Config, EnvOverrides, Extra) ->
    Name = list_to_atom("grow_" ++ integer_to_list(Port)),
    {ok, Peer, _Node} = peer:start(
                          #{name => Name, connection => standard_io, args => ["-pa" | code:get_path()]}),
    _ = peer:call(Peer, logger, set_primary_config, [level, warning]),
    _ = peer:call(Peer, application, load, [quod]),
    KeyTerm = quod_identity:key_term({Pub, Seed}),
    Set = fun(K, V) -> ok = peer:call(Peer, application, set_env, [quod, K, V]) end,
    Set(listen_port,   Port),
    Set(node_addr,     {"127.0.0.1", Port}),
    Set(node_pubkey,   Pub),
    Set(identity_key,  KeyTerm),
    Set(identity_cert, quod_identity:mint_cert({Pub, Seed})),
    Set(simplex_delta_ms, ?DELTA_MS),
    maps:foreach(Set, EnvOverrides),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [quod]),
    DataDir = quod_ct:datadir(Config, Port),
    Cfg = maps:merge(#{node_id => Pub, identity => #{pubkey => Pub, key => KeyTerm}, data_dir => DataDir},
                     Extra),
    {ok, _} = peer:call(Peer, quod_ns_sup, start_namespace, [?NS, Cfg]),
    Peer.

start_brahms(Peer, OwnAddr, Seeds) ->
    {ok, _} = peer:call(Peer, quod_brahms, start_namespace, [?NS, #{node_id => OwnAddr, seed_peers => Seeds}]),
    ok.

%% Build the default-open genesis ontology in the suite's priv_dir (the shipped quod_root.pl carries the
%% peer_ready rule; here case 1 upgrades to it live). can_read default-open so proves aren't fail-closed.
write_genesis(Config) ->
    Path = filename:join(?config(priv_dir, Config), "growth_root.pl"),
    ok = file:write_file(Path,
        <<"acl_sovereign('grow:d').\n"
          "can_read(_Goal, _Subject, _Ns).\n"
          "can_join(_Ns, _Addr, _Pk).\n">>),
    Path.

%% Run ON the founder peer: commit ?N writes locally (no per-write CT round-trip). Retries each write past
%% the post-boot {error,rebuilding} window; at N=1 each prove commits synchronously.
pump(Ns, N) ->
    lists:foreach(fun(I) -> pump1(Ns, I, 200) end, lists:seq(1, N)).
pump1(_Ns, _I, 0) -> ok;
pump1(Ns, I, Tries) ->
    case quod_prolog:prove(Ns, {assertz, {pump, I}}, Ns) of
        {ok, _, _} -> ok;
        _          -> timer:sleep(20), pump1(Ns, I, Tries - 1)
    end.

%%%===================================================================
%%% query + topology helpers
%%%===================================================================

chain_keys(_Lo, 0) -> [];
chain_keys(Lo, N)  -> {P, _} = K = quod_ct:generate_key_gt(Lo), [K | chain_keys(P, N - 1)].

prev_joiners(Config) ->
    case ?config(saved_config, Config) of
        {_Prev, Joiners} when is_list(Joiners) -> Joiners;
        _ -> ct:fail("missing saved_config from the previous ordered case (chain broken)")
    end.

member_peers(Config, Joiners) -> [?config(founder, Config) | [P || {P, _, _} <- Joiners]].
member_pubs(Config, Joiners)  -> lists:sort([?config(fpub, Config) | [Pub || {_, Pub, _} <- Joiners]]).
peer_of(Config, Joiners, Pub) ->
    case Pub =:= ?config(fpub, Config) of
        true  -> ?config(founder, Config);
        false -> element(1, lists:keyfind(Pub, 2, Joiners))
    end.

%% Wait until every peer reports the same height, then return it (the committee is quiescent between writes).
synced_height(Peers) ->
    ?assert(eventually(fun() -> length(lists:usort([slot(P) || P <- Peers])) =:= 1 end, 20000)),
    slot(hd(Peers)).

peer_ready_at(Judge, Pk) ->
    peer:call(Judge, quod_feed, peer_ready, [?NS, Pk, peer:call(Judge, quod_prolog, applied, [?NS])]).

status(Peer)    -> peer:call(Peer, quod_simplex, status, [?NS]).
slot(Peer)      -> maps:get(slot, status(Peer), -1).
role(Peer)      -> maps:get(role, status(Peer), undefined).
synced(Peer)    -> maps:get(syncing, status(Peer), true) =:= false.   %% caught up + confirmed the tip
committee(Peer) -> maps:get(committee, status(Peer), []).
prove(Peer, Goal) -> peer:call(Peer, quod_prolog, prove, [?NS, Goal, ?NS]).

rejects_total(Peers) ->
    lists:sum([maps:get(membership_rejects, peer:call(P, quod_simplex, stats, [?NS]), 0) || P <- Peers]).

%% a raw #transaction carrying an arbitrary diff (the Byzantine-submitter path — no admit/remove predicate)
tx(Diff) ->
    #transaction{tx_id = <<"evil">>, caller_ns = ?NS, diff = Diff,
                 read_check = #{}, author = <<"evil-author">>, sig = none}.

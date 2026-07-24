-module(simplex_SUITE).
-moduledoc """
Stage-2c integration: a real **4-node DispersedSimplex committee over loopback QUIC**, with **failover**.
Each validator runs in its own OS Erlang node (via `peer`, stdio-controlled, no Erlang distribution),
with its own `quod_quic` listener on a distinct port and its own Ed25519 identity — so the `{log, Ns}`
proposal / share / cert / complaint traffic between them is genuine loopback QUIC, exactly the
deployment shape.

The four co-found the same committee (`mode=create`, `committee` = the four `{pubkey, addr}`; the genesis
block asserts every co-founder's `peer_admitted` fact, so their logs are byte-identical). The committee is
derived from those facts. The leader for a slot **rotates** round-robin over the sorted set, so tests
target the correct proposer per slot. `commits_across_committee` proves a write commits everywhere;
`follower_relays` proves a non-leader transparently relays; `leader_failover` kills the next slot's leader
**before it proposes**, so the slot can only advance by a `⅔` **complaint cert → skip** — after which
the rotated leader commits the re-submitted write. `over_fault_restart_recovers` uses an isolated second
committee to stop two validators (`>f`), keeps the head stalled past Δ, restarts both from their existing
logs, and proves live finality resumes without a namespace-wide reboot. `quorum(4)=3` tolerates one down
in normal operation; the latter case validates liveness recovery after deliberately exceeding that bound,
while each validator's durable vote journal preserves its own no-equivocation decisions across restart.
The Byzantine safety assumption remains at most `f` faulty validators.
""".
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("quod_ledger.hrl").
-import(quod_ct, [eventually/2, match_ok/1]).

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([commits_across_committee/1, follower_relays/1, burst_commits_without_busy/1,
         byzantine_retract_rejected/1, byzantine_admit_rejected/1, leader_failover/1,
         over_fault_restart_recovers/1]).

-define(NS, <<"simplex:2c">>).
-define(PORTS, [15820, 15821, 15822, 15823]).   %% N=4 ⇒ quorum 3, tolerates 1 down (failover)
-define(DELTA_MS, 4000).   %% Δ_timeout on each peer: comfortably above even the FIRST commit round over cold
                           %% pairwise QUIC links (so a healthy slot never spuriously skips), well below the
                           %% `eventually` budgets (so a genuinely stuck slot still skips fast)

all() -> [commits_across_committee, follower_relays, burst_commits_without_busy,
          byzantine_retract_rejected, byzantine_admit_rejected, leader_failover,
          over_fault_restart_recovers].

%%%===================================================================
%%% suite setup: one 4-node committee, shared across the (ordered) tests
%%%===================================================================

init_per_suite(Config) ->
    Keys  = [quod_identity:generate() || _ <- ?PORTS],       %% [{Pubkey, Seed}]
    Identities = maps:from_list(
                   [{Pub, #{pubkey => Pub,
                            key => quod_identity:key_term({Pub, Seed})}}
                    || {Pub, Seed} <- Keys]),
    Addrs = [{P, {"127.0.0.1", Port}} || {{P, _}, Port} <- lists:zip(Keys, ?PORTS)],
    Nodes = [start_member(Port, Key, Addrs, Config)
             || {Port, Key} <- lists:zip(?PORTS, Keys)],
    [{nodes, Nodes}, {identities, Identities} | Config].

end_per_suite(Config) ->
    _ = [catch peer:stop(Peer) || {Peer, _Pub} <- ?config(nodes, Config)],
    ok.

%% Start one validator in its own OS node: its own identity (env), its own QUIC listener on Port, a fast
%% Δ_timeout, the resolver pre-seeded with every peer's pubkey→addr (so consensus can dial by pubkey),
%% then the namespace as a co-founder of the shared committee. Returns {Peer, Pubkey}.
start_member(Port, {Pub, Seed}, Addrs, Config) ->
    start_member(?NS, "sx_", Port, {Pub, Seed}, Addrs, Config).

start_member(Ns, NamePrefix, Port, {Pub, Seed}, Addrs, Config) ->
    Name = list_to_atom(NamePrefix ++ integer_to_list(Port)),
    {ok, Peer, _Node} = peer:start(
                          #{name => Name, connection => standard_io, args => ["-pa" | code:get_path()]}),
    try
        configure_member(Peer, Ns, Port, {Pub, Seed}, Addrs, Config)
    catch
        Class:Reason:Stack ->
            _ = catch peer:stop(Peer),
            erlang:raise(Class, Reason, Stack)
    end.

configure_member(Peer, Ns, Port, {Pub, Seed}, Addrs, Config) ->
    _ = peer:call(Peer, logger, set_primary_config, [level, warning]),
    _ = peer:call(Peer, application, load, [quod]),
    KeyTerm = quod_identity:key_term({Pub, Seed}),
    Set = fun(K, V) -> ok = peer:call(Peer, application, set_env, [quod, K, V]) end,
    Set(listen_port,      Port),
    Set(node_addr,        {"127.0.0.1", Port}),   %% advertised endpoint (identity is node_pubkey, below)
    Set(node_pubkey,      Pub),
    Set(identity_key,     KeyTerm),
    Set(identity_cert,    quod_identity:mint_cert({Pub, Seed})),
    Set(simplex_delta_ms, ?DELTA_MS),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [quod]),
    %% pre-seed the pubkey→addr resolver for the OTHER validators (the first dial needs it; later
    %% ones ride the link header). Then co-found the namespace.
    _ = [peer:call(Peer, quod_quic, learn, [Pj, Addr]) || {Pj, Addr} <- Addrs, Pj =/= Pub],
    DataDir = filename:join(?config(priv_dir, Config), "data_" ++ integer_to_list(Port)),
    Cfg = #{mode => create, node_id => Pub,
            identity  => #{pubkey => Pub, key => KeyTerm},
            %% co-founders as {Pubkey, Host, Port} — genesis asserts each one's peer_admitted with its
            %% address, so every founder's genesis transaction is byte-identical (bootstrap adds Self via
            %% node_addr). Consensus needs only the pubkeys; the addresses are the dial hint the KB carries.
            committee => [{Pj, Hj, Pt} || {Pj, {Hj, Pt}} <- Addrs, Pj =/= Pub],
            data_dir  => DataDir},
    {ok, _} = peer:call(Peer, quod_ns_sup, start_namespace, [Ns, Cfg]),
    {Peer, Pub}.

start_tracked_member(Ns, NamePrefix, Port, Key, Addrs, Config) ->
    Node = start_member(Ns, NamePrefix, Port, Key, Addrs, Config),
    put(over_f_nodes, [Node | case get(over_f_nodes) of undefined -> []; L -> L end]),
    Node.

%%%===================================================================
%%% tests
%%%===================================================================

%% A write submitted to a slot's (rotating) leader commits across the whole committee, fact in every KB.
commits_across_committee(Config) ->
    Nodes = ?config(nodes, Config),
    %% all four co-founded the same 4-validator committee via ONE genesis block (slot 1) whose transaction
    %% asserts every co-founder's peer_admitted fact — byte-identical, so all four start at height 1.
    [ ?assertEqual(1, slot(Peer)) || {Peer, _} <- Nodes ],
    %% ONE write on the correct rotating leader for slot 2 commits across the committee. Retried because
    %% quod_prolog answers {error,rebuilding} until its async post-boot replay marks ready; {error,rebuilding}
    %% never reaches consensus, so retrying still yields exactly one committed write (no over-shoot).
    {L2, _} = leader_peer(2, Config),
    ?assert(eventually(fun() -> match_ok(prove(L2, {assertz, {capital, france, paris}})) end, 20000)),
    %% the commit propagates: every node reaches height 2 and reads the fact from its OWN kb
    [ begin
          ?assert(eventually(fun() -> slot(Peer) >= 2 end, 15000)),
          ?assert(eventually(fun() -> match_ok(prove(Peer, {capital, france, {'X'}})) end, 10000))
      end || {Peer, _} <- Nodes ],
    Requested = [maps:get(requested_slot,
                          peer:call(Peer, quod_simplex, stats, [?NS]), -1)
                 || {Peer, _} <- Nodes],
    ?assertEqual([0, 0, 0, 0], Requested),
    Heights = lists:usort([slot(Peer) || {Peer, _} <- Nodes]),
    ?assertEqual([2], Heights).

%% A write submitted to a non-leader is signed there, relayed to the current
%% leader, committed once, and applied across the committee.
follower_relays(Config) ->
    Nodes = ?config(nodes, Config),
    H = synced_height(Nodes),
    {_LeaderPeer, LeaderPub} = leader_peer(H + 1, Config),
    %% pick a NON-leader by PUBKEY (element 2) — comparing the peer handle (element 1) would never match
    %% a pubkey, leaving the leader itself in the candidate set.
    {FollowerPeer, _} = hd([N || {_, Pub} = N <- Nodes, Pub =/= LeaderPub]),
    ?assertMatch({ok, _, _},
                 prove(FollowerPeer, {assertz, {relayed, from_follower}})),
    [ ?assert(eventually(
                fun() -> match_ok(prove(Peer, {relayed, {'X'}})) end,
                10000))
      || {Peer, _} <- Nodes ],
    ?assertEqual(H + 1, synced_height(Nodes)).

%% A concurrent burst across every validator commits COMPLETELY with ZERO busy
%% rejections: arrivals that miss a batch park in the bounded ingress queue and drain
%% into following blocks instead of bouncing on a retry timer. This is the headline
%% guarantee of the event-driven ingress work — before it, ~55% of burst appends were
%% rejected busy and paced by the 300ms relay retransmit.
burst_commits_without_busy(Config) ->
    Nodes = ?config(nodes, Config),
    %% settle first (standalone-safe): one committed warmup write, readable on every
    %% node, absorbs {error, rebuilding} so the burst measures ingress, not boot.
    H = synced_height(Nodes),
    {WarmLeader, _} = leader_peer(H + 1, Config),
    ?assert(eventually(
              fun() -> match_ok(prove(WarmLeader, {assertz, {burst_warmup, ready}})) end,
              20000)),
    [ ?assert(eventually(
                fun() -> match_ok(prove(Peer, {burst_warmup, {'X'}})) end, 15000))
      || {Peer, _} <- Nodes ],
    BusyBefore = total_busy(Nodes),
    H0 = synced_height(Nodes),
    T0 = erlang:monotonic_time(millisecond),
    Parent = self(),
    Writers =
        [begin
             Tag = {burst, NodeIx, I},
             spawn(fun() ->
                       R = writer_retry(Peer, {assertz, {burst_fact, NodeIx, I}}, 40),
                       Parent ! {Tag, R}
                   end),
             Tag
         end
         || {NodeIx, {Peer, _}} <- lists:zip(lists:seq(1, length(Nodes)), Nodes),
            I <- lists:seq(1, 10)],
    [receive {Tag, R} -> ?assertMatch({ok, _, _}, R)
     after 60000 ->
         ct:pal("burst stall — fleet state: ~p",
                [[{Pub, peer:call(Peer, quod_simplex, stats, [?NS])}
                  || {Peer, Pub} <- Nodes]]),
         ct:fail({writer_timed_out, Tag})
     end || Tag <- Writers],
    %% every fact readable everywhere; not one busy was minted anywhere in the fleet
    [ ?assert(eventually(
                fun() -> match_ok(prove(Peer, {burst_fact, 1, 1})) end, 15000))
      || {Peer, _} <- Nodes ],
    ?assertEqual(BusyBefore, total_busy(Nodes)),
    Heights = lists:usort([slot(Peer) || {Peer, _} <- Nodes]),
    ?assertEqual(1, length(Heights)),
    %% round pacing over the burst: the local-cluster reference number for the
    %% live fleet's ~250-500ms phases — local rounds much faster than production
    %% convicts the environment; equally slow convicts the code, reproducibly here
    ElapsedMs = erlang:monotonic_time(millisecond) - T0,
    Slots = hd(Heights) - H0,
    ct:pal("burst pacing: ~p slots in ~pms (~.1f ms/round, ~.2f blocks/s)",
           [Slots, ElapsedMs, ElapsedMs / max(1, Slots),
            Slots * 1000 / max(1, ElapsedMs)]).

total_busy(Nodes) ->
    lists:sum([maps:get(r_busy, peer:call(Peer, quod_simplex, stats, [?NS]), 0)
               || {Peer, _} <- Nodes]).

%% Writes ride quod_prolog: {error,rebuilding}/conflict_retry/retry/not_leader are all
%% client-retryable and MUST NOT count as failures; busy alone is what this test bans
%% (and it asserts the counter fleet-wide, so a swallowed busy cannot hide).
writer_retry(_Peer, _Goal, 0) -> {error, out_of_retries};
writer_retry(Peer, Goal, N) ->
    case prove(Peer, Goal) of
        {ok, _, _} = Ok -> Ok;
        _Other ->
            timer:sleep(50),
            writer_retry(Peer, Goal, N - 1)
    end.

%% A Byzantine leader injects a crafted `{propose, ...}` whose payload is a committee change its OWN
%% run_proof never gated — the multi-validator membership defense (Slice C). The proposal passes the pure
%% shape gate (one well-formed peer_admitted op, committee stays non-empty) so it REACHES the KB verdict,
%% but each honest follower re-judges it against its own kb and REFUSES support, so it can never reach a
%% notarizing quorum. The slot is complaint-skipped, the committee is unchanged, and the namespace still
%% commits honest writes.
%%
%% Case 1 — a fabricated-address RETRACT of a real founder (the retract-ejection the Slice A review flagged):
%% the crafted op carries the victim's pubkey but a wrong Host/Port, so it would drop the victim from the
%% validator-set projection while MISSING in the KB. The verdict's exact-clause check (`has_clause`) rejects
%% it — no honest support, the slot skips, the committee keeps all four.
byzantine_retract_rejected(Config) ->
    Nodes  = ?config(nodes, Config),
    Victim = element(2, hd(Nodes)),   %% a real founder's pubkey, retracted with a WRONG address
    Evil   = tx([{retract, {{peer_admitted, Victim, "wrong-host", 9999, Victim}, true}}]),
    assert_membership_proposal_skipped(Config, Evil).

%% Case 2 — an unauthorized ADMIT of a newcomer the join policy does not allow. This committee co-founds
%% with no `can_join` clause (no genesis ontology), so admission is fail-closed: the verdict re-proves
%% `can_join` and it fails, rejecting the admit. No honest support, the slot skips, the committee keeps four.
byzantine_admit_rejected(Config) ->
    {NewPub, _} = quod_identity:generate(),
    Evil = tx([{assert, {{peer_admitted, NewPub, "10.9.9.9", 9000, NewPub}, true}}]),
    assert_membership_proposal_skipped(Config, Evil).

%% Kill the next slot's leader BEFORE it proposes: the slot cannot commit (no proposer), so the three
%% live validators complain, a ⅔ complaint cert SKIPS it (a noop), and the rotated leader for the next
%% slot commits the re-submitted write. Proves complaint-timer → skip → rotation → commit end-to-end.
leader_failover(Config) ->
    Nodes = ?config(nodes, Config),
    H = synced_height(Nodes),
    V = H + 1,
    {DeadPeer, DeadPub} = leader_peer(V, Config),
    ok   = peer:stop(DeadPeer),
    Live = [N || {_, P} = N <- Nodes, P =/= DeadPub],
    %% a client write reaches every LIVE validator; each redirects to the (dead) leader AND arms its Δ
    %% timer for slot V — after Δ the three complain, forming a ⅔ complaint cert that skips V.
    W = {assertz, {failover, done, yes}},
    Parent = self(),
    _ = [spawn(fun() -> Parent ! {dead_leader_submit, P, prove(P, W)} end)
         || {P, _} <- Live],
    %% slot V can ONLY be reached by a skip — its leader is dead, so no block for V can ever commit.
    %% (NB: the write goes to the followers, not the dead leader; an alive leader given the write would
    %% instead PROPOSE + commit V — that contrasting path is what commits_across_committee proves.)
    [ ?assert(eventually(fun() -> slot(P) >= V end, 20000)) || {P, _} <- Live ],
    %% V is a NOOP skip, not a stealth commit of W: the fact must be ABSENT until the rotated leader commits.
    {LP1, _} = hd(Live),
    ?assertNot(match_ok(prove(LP1, {failover, done, {'X'}}))),
    %% re-submit to the rotated (alive) leader for V+1: it proposes, the three live nodes commit it.
    {L2, _} = leader_peer(V + 1, Config),
    ?assert(eventually(fun() -> match_ok(prove(L2, W)) end, 20000)),
    [ begin
          ?assert(eventually(fun() -> slot(P) >= V + 1 end, 15000)),
          ?assert(eventually(fun() -> match_ok(prove(P, {failover, done, {'X'}})) end, 10000))
      end || {P, _} <- Live ],
    ?assert(eventually(fun() -> lists:usort([slot(P) || {P, _} <- Live]) =:= [V + 1] end, 5000)).

%% Exceed the formal liveness bound (`N=4`, `f=1`) while a real proposal is in flight. The two survivors
%% must not accumulate irreversible complaints while they can see fewer than a quorum. Restart both absent
%% validators from their existing logs; the head watchdog then gets a fresh Δ, re-drives the full proposal
%% and finality evidence, and the committee commits both the interrupted write and a later probe without a
%% coordinated namespace restart.
over_fault_restart_recovers(Config) ->
    Ns = <<"simplex:over-f-recovery">>,
    Ports = [15830, 15831, 15832, 15833],
    Keys = [quod_identity:generate() || _ <- Ports],
    Addrs = [{P, {"127.0.0.1", Port}} || {{P, _}, Port} <- lists:zip(Keys, Ports)],
    put(over_f_nodes, []),
    try
        Nodes0 = [start_tracked_member(Ns, "sxr_", Port, Key, Addrs, Config)
                  || {Port, Key} <- lists:zip(Ports, Keys)],
        ?assert(eventually(
                  fun() ->
                          lists:all(
                            fun({P, _}) ->
                                    maps:get(syncing, status(P, Ns), true) =:= false
                            end, Nodes0)
                  end, 30000)),

        %% Create durable, non-genesis history before the outage. Restarting the stopped peers must now
        %% reopen and extend their existing ledgers, not accidentally pass as fresh empty/catch-up boots.
        HBase = synced_height(Nodes0, Ns),
        {BaselineLeader, _} =
            lists:keyfind(leader_for(HBase + 1, Nodes0), 2, Nodes0),
        ?assert(eventually(
                  fun() -> match_ok(prove(BaselineLeader, Ns,
                                          {assertz, {before_over_f, durable}})) end,
                  20000)),
        ?assert(eventually(
                  fun() -> lists:all(fun({P, _}) -> slot(P, Ns) >= HBase + 1 end, Nodes0) end,
                  20000)),
        H0 = synced_height(Nodes0, Ns),
        ?assert(H0 >= 2),

        LeaderPub = leader_for(H0 + 1, Nodes0),
        {LeaderPeer, LeaderPub} = lists:keyfind(LeaderPub, 2, Nodes0),
        {SurvivorPeer, _} = Survivor =
            hd([N || N <- Nodes0, N =/= {LeaderPeer, LeaderPub}]),
        Down = [N || N <- Nodes0,
                     N =/= {LeaderPeer, LeaderPub}, N =/= Survivor],
        LeaderPauses0 = maps:get(
                          quorum_pauses,
                          peer:call(LeaderPeer, quod_simplex, stats, [Ns]), 0),
        SurvivorPauses0 = maps:get(
                            quorum_pauses,
                            peer:call(SurvivorPeer, quod_simplex, stats, [Ns]), 0),
        [ok = peer:stop(P) || {P, _} <- Down],

        %% The write reaches the real leader with only 2/4 validators alive. Its caller may time out while
        %% quorum is absent; consensus still owns the signed proposal and must finish it after recovery.
        _ = spawn(fun() -> _ = prove(LeaderPeer, Ns, {assertz, {over_f, recovered}}) end),
        ?assert(eventually(
                  fun() ->
                          LeaderStats = peer:call(
                                          LeaderPeer, quod_simplex, stats, [Ns]),
                          SurvivorStats = peer:call(
                                            SurvivorPeer, quod_simplex, stats, [Ns]),
                          maps:get(quorum_pauses, LeaderStats, 0) > LeaderPauses0
                              andalso maps:get(quorum_pauses, SurvivorStats, 0)
                                      > SurvivorPauses0
                              andalso maps:get(head_complaint_signed, LeaderStats, 1) =:= 0
                              andalso maps:get(head_complaint_signed, SurvivorStats, 1) =:= 0
                              andalso slot(LeaderPeer, Ns) =:= H0
                              andalso slot(SurvivorPeer, Ns) =:= H0
                  end, ?DELTA_MS * 3)),

        DownPubs = [Pub || {_P, Pub} <- Down],
        Restarted = [start_tracked_member(
                       Ns, "sxr_", Port, Key, Addrs, Config)
                     || {Port, {Pub, _} = Key} <- lists:zip(Ports, Keys),
                        lists:member(Pub, DownPubs)],
        Nodes1 = [N || N <- Nodes0, not lists:member(element(2, N), DownPubs)] ++ Restarted,
        ?assert(eventually(
                  fun() ->
                          lists:all(fun({P, _}) -> slot(P, Ns) >= H0 + 1 end, Nodes1)
                              andalso lists:all(
                                        fun({P, _}) ->
                                                match_ok(prove(P, Ns, {over_f, {'X'}}))
                                        end, Nodes1)
                  end, 45000)),

        H1 = synced_height(Nodes1, Ns),
        {NextLeader, _} = lists:keyfind(leader_for(H1 + 1, Nodes1), 2, Nodes1),
        ?assert(eventually(
                  fun() -> match_ok(prove(NextLeader, Ns,
                                          {assertz, {after_over_f, live}})) end,
                  20000)),
        ?assert(eventually(
                  fun() -> lists:all(fun({P, _}) -> slot(P, Ns) >= H1 + 1 end, Nodes1) end,
                  20000))
    after
        %% Every successfully-started peer is registered immediately, so setup/restart failures cannot leak
        %% earlier OS nodes. Duplicate/stopped entries are harmless under catch.
        Tracked = case erase(over_f_nodes) of undefined -> []; L -> L end,
        _ = [catch peer:stop(P) || {P, _} <- Tracked]
    end.

%%%===================================================================
%%% helpers
%%%===================================================================

%% Inject `Evil` (a #transaction) as a crafted proposal for the next slot, from the REAL slot leader's
%% node, and assert every node skips the slot with the committee unchanged and the namespace still live.
assert_membership_proposal_skipped(Config, Evil) ->
    Nodes  = ?config(nodes, Config),
    H      = synced_height(Nodes),
    V      = H + 1,
    {LeaderPeer, LeaderPub} = leader_peer(V, Config),
    Before  = committee(peer1(Nodes)),
    RejBefore = rejects_total(Nodes),   %% cumulative — assert it GROWS for THIS proposal (not a stale count)
    %% craft the block for slot V and send it to every follower over the {log, Ns} channel FROM the leader's
    %% node — authenticated as the leader (so on_propose's leader-check passes), but bypassing the leader's
    %% own statem (a transport-level send). Timestamp margin keeps it monotonic vs the last committed block.
    Ts    = erlang:system_time(millisecond) + 1000,
    Identity = maps:get(LeaderPub, ?config(identities, Config)),
    Unsigned = Evil#transaction{author = LeaderPub,
                                author_seq = (1 bsl 60) + V, sig = none},
    {ok, SignedEvil} = quod_transaction:sign(?NS, Unsigned, Identity),
    Block = #block{slot = V, parent = H, payload = [SignedEvil], timestamp = Ts},
    Chan  = term_to_binary({log, ?NS}, [deterministic]),
    Frame = quod_simplex:encode(?NS, {propose, Block}),
    _ = [peer:call(LeaderPeer, quod_quic, send, [Fpub, Chan, Frame])
         || {_, Fpub} <- Nodes, Fpub =/= LeaderPub],
    %% the crafted slot can ONLY be skipped (no honest support) — every node advances past it via a noop
    [ ?assert(eventually(fun() -> slot(P) >= V end, 20000)) || {P, _} <- Nodes ],
    %% the committee is unchanged (the change never committed) and the fleet's reject counter GREW for THIS
    %% proposal — a delta, not a stale cumulative count from an earlier ordered test (false-green guard)
    ?assertEqual(Before, committee(peer1(Nodes))),
    ?assert(eventually(fun() -> rejects_total(Nodes) > RejBefore end, 5000)),
    %% the namespace is not wedged: the rotated leader for V+1 commits an honest write
    {L, _} = leader_peer(V + 1, Config),
    ?assert(eventually(fun() -> match_ok(prove(L, {assertz, {after_byzantine, V}})) end, 20000)),
    [ ?assert(eventually(fun() -> slot(P) >= V + 1 end, 15000)) || {P, _} <- Nodes ].

%% a raw #transaction carrying an arbitrary diff (the Byzantine submitter path — no admit/remove predicate)
tx(Diff) ->
    #transaction{tx_id = <<"evil">>, caller_ns = ?NS, diff = Diff,
                 read_check = #{}, author = <<0:256>>, sig = none}.

committee(Peer)          -> maps:get(committee, status(Peer), []).
membership_rejects(Peer) -> maps:get(membership_rejects, peer:call(Peer, quod_simplex, stats, [?NS]), 0).
rejects_total(Nodes)     -> lists:sum([membership_rejects(P) || {P, _} <- Nodes]).

pubs(Nodes) -> [P || {_, P} <- Nodes].
peer1(Nodes) -> element(1, hd(Nodes)).

%% Wait until EVERY node reports the same committed height, then return it. The committee is quiescent
%% between the (ordered) tests, so once they agree the height is stable — this avoids picking a leader
%% off a node that is a beat behind (a non-leader whose own next slot it would still lead).
synced_height(Nodes) ->
    ?assert(eventually(fun() -> length(lists:usort([slot(P) || {P, _} <- Nodes])) =:= 1 end, 10000)),
    slot(peer1(Nodes)).

synced_height(Nodes, Ns) ->
    ?assert(eventually(
              fun() -> length(lists:usort([slot(P, Ns) || {P, _} <- Nodes])) =:= 1 end,
              15000)),
    slot(peer1(Nodes), Ns).

%% The round-robin leader for a slot — MUST match quod_simplex:leader/2 (sorted set, (Slot-1) rem N).
leader_for(Slot, Nodes) ->
    Sorted = lists:sort(pubs(Nodes)),
    lists:nth(((Slot - 1) rem length(Sorted)) + 1, Sorted).

leader_peer(Slot, Config) ->
    Nodes = ?config(nodes, Config),
    lists:keyfind(leader_for(Slot, Nodes), 2, Nodes).

status(Peer) -> peer:call(Peer, quod_simplex, status, [?NS]).
status(Peer, Ns) -> peer:call(Peer, quod_simplex, status, [Ns]).
%% -1 (not a valid slot) if status/1 hits its internal timeout and returns #{} — a clean, retryable
%% miss instead of a {badkey,slot} crash. Numeric so `>= V` in eventually stays false (an atom sentinel
%% would sort above integers in Erlang term order and spuriously satisfy it).
slot(Peer) -> maps:get(slot, status(Peer), -1).
slot(Peer, Ns) -> maps:get(slot, status(Peer, Ns), -1).
prove(Peer, Goal) -> peer:call(Peer, quod_prolog, prove, [?NS, Goal, ?NS]).
prove(Peer, Ns, Goal) -> peer:call(Peer, quod_prolog, prove, [Ns, Goal, Ns]).

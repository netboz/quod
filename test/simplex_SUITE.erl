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
the rotated leader commits the re-submitted write. `quorum(4)=3` tolerates the one down node; this is the
multi-node failover validation the engine's eunit tests (a simulated committee) cannot give.
""".
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("quod_ledger.hrl").
-import(quod_ct, [eventually/2, match_ok/1]).

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([commits_across_committee/1, follower_relays/1,
         byzantine_retract_rejected/1, byzantine_admit_rejected/1, leader_failover/1]).

-define(NS, <<"simplex:2c">>).
-define(PORTS, [15820, 15821, 15822, 15823]).   %% N=4 ⇒ quorum 3, tolerates 1 down (failover)
-define(DELTA_MS, 4000).   %% Δ_timeout on each peer: comfortably above even the FIRST commit round over cold
                           %% pairwise QUIC links (so a healthy slot never spuriously skips), well below the
                           %% `eventually` budgets (so a genuinely stuck slot still skips fast)

all() -> [commits_across_committee, follower_relays,
          byzantine_retract_rejected, byzantine_admit_rejected, leader_failover].

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
    Name = list_to_atom("sx_" ++ integer_to_list(Port)),
    {ok, Peer, _Node} = peer:start(
                          #{name => Name, connection => standard_io, args => ["-pa" | code:get_path()]}),
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
    {ok, _} = peer:call(Peer, quod_ns_sup, start_namespace, [?NS, Cfg]),
    {Peer, Pub}.

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
    ?assert(eventually(fun() -> lists:usort([slot(Peer) || {Peer, _} <- Nodes]) =:= [2] end, 5000)).

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

%% The round-robin leader for a slot — MUST match quod_simplex:leader/2 (sorted set, (Slot-1) rem N).
leader_for(Slot, Nodes) ->
    Sorted = lists:sort(pubs(Nodes)),
    lists:nth(((Slot - 1) rem length(Sorted)) + 1, Sorted).

leader_peer(Slot, Config) ->
    Nodes = ?config(nodes, Config),
    lists:keyfind(leader_for(Slot, Nodes), 2, Nodes).

status(Peer) -> peer:call(Peer, quod_simplex, status, [?NS]).
%% -1 (not a valid slot) if status/1 hits its internal timeout and returns #{} — a clean, retryable
%% miss instead of a {badkey,slot} crash. Numeric so `>= V` in eventually stays false (an atom sentinel
%% would sort above integers in Erlang term order and spuriously satisfy it).
slot(Peer) -> maps:get(slot, status(Peer), -1).
prove(Peer, Goal) -> peer:call(Peer, quod_prolog, prove, [?NS, Goal, ?NS]).

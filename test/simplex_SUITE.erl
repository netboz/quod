-module(simplex_SUITE).
-moduledoc """
Stage-2c integration: a real **4-node DispersedSimplex committee over loopback QUIC**, with **failover**.
Each validator runs in its own OS Erlang node (via `peer`, stdio-controlled, no Erlang distribution),
with its own `quod_quic` listener on a distinct port and its own Ed25519 identity — so the `{log, Ns}`
proposal / share / cert / complaint traffic between them is genuine loopback QUIC, exactly the
deployment shape.

The four co-found the same committee (`mode=create`, `committee` = the four pubkeys, no genesis so their
logs are byte-identical). The leader for a slot **rotates** round-robin over the sorted set, so tests
target the correct proposer per slot. `commits_across_committee` proves a write commits everywhere;
`follower_redirects` proves a non-leader redirects; `leader_failover` kills the next slot's leader
**before it proposes**, so the slot can only advance by a `⅔` **complaint cert → skip** — after which
the rotated leader commits the re-submitted write. `quorum(4)=3` tolerates the one down node; this is the
multi-node failover validation the engine's eunit tests (a simulated committee) cannot give.
""".
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-import(quod_ct, [eventually/2, match_ok/1]).

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([commits_across_committee/1, follower_redirects/1, leader_failover/1]).

-define(NS, <<"simplex:2c">>).
-define(PORTS, [15820, 15821, 15822, 15823]).   %% N=4 ⇒ quorum 3, tolerates 1 down (failover)
-define(DELTA_MS, 4000).   %% Δ_timeout on each peer: comfortably above even the FIRST commit round over cold
                           %% pairwise QUIC links (so a healthy slot never spuriously skips), well below the
                           %% `eventually` budgets (so a genuinely stuck slot still skips fast)

all() -> [commits_across_committee, follower_redirects, leader_failover].

%%%===================================================================
%%% suite setup: one 4-node committee, shared across the (ordered) tests
%%%===================================================================

init_per_suite(Config) ->
    Keys  = [quod_identity:generate() || _ <- ?PORTS],       %% [{Pubkey, Seed}]
    Pubs  = [P || {P, _} <- Keys],
    Addrs = [{P, {"127.0.0.1", Port}} || {{P, _}, Port} <- lists:zip(Keys, ?PORTS)],
    Nodes = [start_member(Port, Key, Pubs, Addrs, Config)
             || {Port, Key} <- lists:zip(?PORTS, Keys)],
    [{nodes, Nodes} | Config].

end_per_suite(Config) ->
    _ = [catch peer:stop(Peer) || {Peer, _Pub} <- ?config(nodes, Config)],
    ok.

%% Start one validator in its own OS node: its own identity (env), its own QUIC listener on Port, a fast
%% Δ_timeout, the resolver pre-seeded with every peer's pubkey→addr (so consensus can dial by pubkey),
%% then the namespace as a co-founder of the shared committee. Returns {Peer, Pubkey}.
start_member(Port, {Pub, Seed}, Pubs, Addrs, Config) ->
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
            committee => Pubs -- [Pub],   %% co-founders (bootstrap usorts [Self | this])
            data_dir  => DataDir},
    {ok, _} = peer:call(Peer, quod_ns_sup, start_namespace, [?NS, Cfg]),
    {Peer, Pub}.

%%%===================================================================
%%% tests
%%%===================================================================

%% A write submitted to a slot's (rotating) leader commits across the whole committee, fact in every KB.
commits_across_committee(Config) ->
    Nodes = ?config(nodes, Config),
    %% all four co-founded the same 4-validator committee at height 4 (4 {add,M} entries, no genesis)
    [ ?assertEqual(4, slot(Peer)) || {Peer, _} <- Nodes ],
    %% ONE write on the correct rotating leader for slot 5 commits across the committee. Retried because
    %% quod_prolog answers {error,rebuilding} until its async post-boot replay marks ready; {error,rebuilding}
    %% never reaches consensus, so retrying still yields exactly one committed write (no over-shoot).
    {L5, _} = leader_peer(5, Config),
    ?assert(eventually(fun() -> match_ok(prove(L5, {assertz, {capital, france, paris}})) end, 20000)),
    %% the commit propagates: every node reaches height 5 and reads the fact from its OWN kb
    [ begin
          ?assert(eventually(fun() -> slot(Peer) >= 5 end, 15000)),
          ?assert(eventually(fun() -> match_ok(prove(Peer, {capital, france, {'X'}})) end, 10000))
      end || {Peer, _} <- Nodes ],
    ?assert(eventually(fun() -> lists:usort([slot(Peer) || {Peer, _} <- Nodes]) =:= [5] end, 5000)).

%% A write submitted to a non-leader is redirected to the current slot's leader, not silently dropped.
follower_redirects(Config) ->
    Nodes = ?config(nodes, Config),
    H = slot(peer1(Nodes)),
    {LeaderPeer, _} = leader_peer(H + 1, Config),
    [{FollowerPeer, _} | _] = [N || {P, _} = N <- Nodes, P =/= peer_pub(LeaderPeer, Nodes)],
    ?assertMatch({error, {not_leader, _}}, prove(FollowerPeer, {assertz, {should, not_commit}})).

%% Kill the next slot's leader BEFORE it proposes: the slot cannot commit (no proposer), so the three
%% live validators complain, a ⅔ complaint cert SKIPS it (a noop), and the rotated leader for the next
%% slot commits the re-submitted write. Proves complaint-timer → skip → rotation → commit end-to-end.
leader_failover(Config) ->
    Nodes = ?config(nodes, Config),
    H = slot(peer1(Nodes)),
    V = H + 1,
    {DeadPeer, DeadPub} = leader_peer(V, Config),
    ok   = peer:stop(DeadPeer),
    Live = [N || {_, P} = N <- Nodes, P =/= DeadPub],
    %% a client write reaches every LIVE validator; each redirects to the (dead) leader AND arms its Δ
    %% timer for slot V — after Δ the three complain, forming a ⅔ complaint cert that skips V.
    W = {assertz, {failover, done, yes}},
    _ = [prove(P, W) || {P, _} <- Live],
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

pubs(Nodes) -> [P || {_, P} <- Nodes].
peer1(Nodes) -> element(1, hd(Nodes)).
peer_pub(Peer, Nodes) -> element(2, lists:keyfind(Peer, 1, Nodes)).

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

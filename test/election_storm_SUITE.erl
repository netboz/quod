-module(election_storm_SUITE).
-moduledoc """
Regression guard for the 2-voter **election storm** (the `quod:root` full-restart bug).

Live, a full-cluster restart left a 2-voter committee leaderless for a long time: both
voters, unable to resolve each other's address from the (cold, post-restart) resolver
cache, kept timing out and incrementing their durable term — climbing to **term 1144**
before one happened to win. Root cause: a candidate that can't reach a quorum STILL
bumps its term on every election timeout. The fix is Ra-style **pre-vote** — a node runs
a non-binding trial election and only increments its term once a quorum says it would
vote for it, so an unreachable voter never inflates its term.

These run the **pubkey identity path** (real keypairs), so the resolver cache is in play
(the address-id path of `raft_safety_SUITE` resolves directly and can't reproduce this).

- `t_isolated_voter_does_not_storm` — ONE voter in a 2-voter committee whose peer never
  starts (unreachable, address unknown). Its term MUST stay bounded: today it storms,
  with pre-vote it stays put (it can never win a pre-vote alone). The sharp red→green guard.
- `t_cold_cache_converges` — TWO voters that start unable to resolve each other (empty
  cache, as after a restart). Once they learn each other's address (what the link header /
  Brahms gossip does live), they MUST settle on exactly one leader with the term still
  bounded — proving the fix preserves liveness, not just suppresses elections.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([t_isolated_voter_does_not_storm/1, t_cold_cache_converges/1]).
-import(quod_ct, [eventually/2, stop_all/1, datadir/2]).

-define(NS, <<"quod:root">>).
%% BRISK timing so a storm (if unfixed) is sharp within a few seconds: a bare candidate
%% re-elects every ~250-400ms. heartbeat << election (valid_cfg requires HB < EL).
-define(TUNING, #{election_ms => 250, election_jit => 0.6, heartbeat_ms => 80, join_ms => 500}).
%% An unreachable voter must NOT inflate its term at all — with pre-vote it stays at 0
%% (padded for safety). Today it climbs every timeout.
-define(ISOLATED_BOUND, 2).
%% A cold-cache pair, once reachable, converges in a handful of terms (a couple of jitter
%% rounds may leapfrog before one wins). A term above this is the unbounded storm — today
%% the cold window alone climbs well past it.
-define(CONVERGE_BOUND, 8).

all() -> [t_isolated_voter_does_not_storm, t_cold_cache_converges].

init_per_suite(Config) -> Config.
end_per_suite(_Config) -> ok.

%%%===================================================================
%%% tests
%%%===================================================================

%% A lone voter in a 2-voter committee whose peer never starts. It can neither resolve nor
%% reach the peer, so it can never win — and therefore MUST NOT keep inflating its term.
t_isolated_voter_does_not_storm(Config) ->
    {Pub1, Seed1}  = quod_identity:generate(),
    {Pub2, _Seed2} = quod_identity:generate(),     %% committee peer that is never started
    {Peer, _, _} = start_voter(15870, {Pub1, Seed1}, [Pub1, Pub2], Config),
    timer:sleep(3000),     %% at this tuning a bare candidate would re-elect ~8-12 times
    %% Fail CLOSED: prove the node is ALIVE and reporting a REAL state before trusting the term
    %% bound — term/role default to 0/undefined on a failed peer:call (a wedged/dead ledger would
    %% otherwise pass the bound spuriously). A present `term` key means the gen_statem answered.
    S = status(Peer),
    ?assert(is_map(S) andalso maps:is_key(term, S)),
    Role = maps:get(role, S),
    ?assert(lists:member(Role, [follower, pre_vote, candidate])),   %% alive + contesting, never leader
    T = maps:get(term, S),
    ct:pal("election_storm: isolated voter after 3s = term ~p role ~p (bound ~p)", [T, Role, ?ISOLATED_BOUND]),
    ?assert(T =< ?ISOLATED_BOUND),         %% the guard: MUST NOT inflate its term while unreachable
    stop_all([Peer]).

%% Two voters that start unable to resolve each other (cold cache, as after a restart).
%% Once each learns the other's address, they must elect ONE leader with a bounded term.
t_cold_cache_converges(Config) ->
    {Pub1, Seed1} = quod_identity:generate(),
    {Pub2, Seed2} = quod_identity:generate(),
    Committee = [Pub1, Pub2],
    {P1, _, A1} = start_voter(15871, {Pub1, Seed1}, Committee, Config),
    {P2, _, A2} = start_voter(15872, {Pub2, Seed2}, Committee, Config),
    %% cold cache: neither resolves the other yet. Let a (potential) storm build for a while —
    %% on the unfixed code the term climbs the whole time; with pre-vote it stays at 0.
    timer:sleep(2000),
    %% teach each node the other's address — exactly what an inbound link header / Brahms
    %% gossip does live (quod_link:learn_hint -> quod_quic:learn).
    _ = peer:call(P1, quod_quic, learn, [Pub2, A2]),
    _ = peer:call(P2, quod_quic, learn, [Pub1, A1]),
    %% they must now settle on exactly one leader...
    ?assert(eventually(fun() -> one_leader([P1, P2]) end, 15000)),
    %% ...with the term still BOUNDED — convergence costs only a few terms, not a storm.
    Terms = [term(P) || P <- [P1, P2]],
    ct:pal("election_storm: cold-cache converged terms = ~p (bound ~p)", [Terms, ?CONVERGE_BOUND]),
    ?assert(lists:max(Terms) =< ?CONVERGE_BOUND),
    stop_all([P1, P2]).

%%%===================================================================
%%% node start (real keypair = pubkey identity path), mirrors identity_SUITE
%%%===================================================================

start_voter(Port, {Pub, Seed}, Committee, Config) ->
    Cert = quod_identity:mint_cert({Pub, Seed}),
    Key  = quod_identity:key_term({Pub, Seed}),
    Addr = {"127.0.0.1", Port},
    Peer = start_peer(Port, Addr, Pub, Cert, Key),
    Cfg  = (?TUNING)#{node_id => Pub, mode => create, committee => Committee,
                      data_dir => datadir(Config, Port)},
    {ok, _} = peer:call(Peer, quod_ns_sup, start_namespace, [?NS, Cfg]),
    {Peer, Pub, Addr}.

%% Boot a node with a REAL identity: node_pubkey + a per-node Ed25519 cert/key in the env,
%% so quod_quic's transport id is {Pub, Addr} and a member is dialed pubkey -> resolved addr.
%% No addr_hints are seeded — the cache starts cold, the whole point of these tests.
start_peer(Port, Addr, Pub, Cert, Key) ->
    Name = list_to_atom("storm_" ++ integer_to_list(Port)),
    {ok, Peer, _Node} = peer:start(
                          #{name => Name, connection => standard_io,
                            args => ["-pa" | code:get_path()]}),
    _ = peer:call(Peer, logger, set_primary_config, [level, warning]),
    _ = peer:call(Peer, application, load, [quod]),
    ok = peer:call(Peer, application, set_env, [quod, listen_port, Port]),
    ok = peer:call(Peer, application, set_env, [quod, node_id, Addr]),       %% transport address
    ok = peer:call(Peer, application, set_env, [quod, node_pubkey, Pub]),    %% our identity (pubkey)
    ok = peer:call(Peer, application, set_env, [quod, identity_cert, Cert]),
    ok = peer:call(Peer, application, set_env, [quod, identity_key, Key]),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [quod]),
    Peer.

%%%===================================================================
%%% query helpers
%%%===================================================================

status(Peer) -> peer:call(Peer, quod_ledger, status, [?NS]).
role(Peer)   -> maps:get(role, status(Peer), undefined).
term(Peer)   -> maps:get(term, status(Peer), 0).

one_leader(Peers) ->
    length([leader || P <- Peers, (catch role(P)) =:= leader]) =:= 1.

-module(join_SUITE).
-moduledoc """
Integration: a node **joins a live committee over loopback QUIC** and syncs its history.

Each node runs in its own OS Erlang node (via `peer`, no Erlang distribution) with its own
`quod_quic` listener, so the `{log, Ns}` join handshake + replication is genuine loopback
QUIC — the deployment shape.

Covers the join milestone (`~/.claude/plans/delightful-giggling-reddy.md`):

- `t_join_1_to_2` — a `mode=join` node dials the founder, is admitted as a non-voting
  learner, syncs the genesis + a pre-join write, is promoted to a voter (committee = 2 on
  both), and a post-join write reaches both members' KBs.
- `t_join_2_to_3` — a third node joins a 2-voter committee, seeded at a *follower* (so it
  exercises the `not_in_charge` redirect to the leader) and grows the quorum 2 → 3.
- `t_join_denied` — a root whose `can_join` is fail-closed refuses admission: the committee
  never grows and the joiner stays out (no learner, no sync).
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([t_join_1_to_2/1, t_join_2_to_3/1, t_join_denied/1]).
-import(quod_ct, [eventually/2, stop_all/1, match_ok/1, datadir/2]).

-define(NS, <<"quod:root">>).
%% heartbeat << election so a promoted voter never spuriously elects; brisk join cadence.
-define(TUNING, #{election_ms => 2500, election_jit => 0.4, heartbeat_ms => 150,
                  join_ms => 500}).

all() -> [t_join_1_to_2, t_join_2_to_3, t_join_denied].

init_per_suite(Config) ->
    {Cert, Key} = make_cert(Config),
    [{certkey, {Cert, Key}} | Config].

end_per_suite(_Config) -> ok.

%%%===================================================================
%%% tests
%%%===================================================================

%% Founder (1-voter, real genesis) + one joiner ⇒ a 2-voter committee that converges.
t_join_1_to_2(Config) ->
    {Cert, Key} = ?config(certkey, Config),
    {FPeer, FId} = start_founder(15820, Cert, Key, root_genesis(Config), Config),
    ?assert(eventually(fun() -> role(FPeer) =:= leader end, 15000)),
    ?assert(eventually(fun() -> match_ok(prove(FPeer, {acl_sovereign, 'quod:root'})) end, 10000)),
    %% a pre-join write: the joiner must sync content beyond the genesis block too.
    ?assertMatch({ok, _, _}, write([{FPeer, FId}], {assertz, {capital, france, paris}})),

    {JPeer, JId} = start_joiner(15821, Cert, Key, [FId], Config),
    %% admitted → caught up → promoted: the committee is 2 voters on BOTH members.
    ?assert(eventually(fun() -> committee_size(FPeer) =:= 2 end, 20000)),
    ?assert(eventually(fun() -> committee_size(JPeer) =:= 2 end, 20000)),
    %% the joiner synced the genesis AND the pre-join write from the leader's log.
    ?assert(eventually(fun() -> match_ok(prove(JPeer, {acl_sovereign, 'quod:root'})) end, 15000)),
    ?assert(eventually(fun() -> match_ok(prove(JPeer, {capital, france, {'X'}})) end, 15000)),
    %% a post-join write commits (now needs both voters) and reaches both KBs.
    ?assertMatch({ok, _, _}, write([{FPeer, FId}, {JPeer, JId}], {assertz, {capital, japan, tokyo}})),
    [ ?assert(eventually(fun() -> match_ok(prove(P, {capital, japan, {'Y'}})) end, 15000))
      || P <- [FPeer, JPeer] ],
    stop_all([JPeer, FPeer]).

%% A third node joins a 2-voter committee, seeded at a follower (redirect) ⇒ 3 voters.
t_join_2_to_3(Config) ->
    {Cert, Key} = ?config(certkey, Config),
    {FPeer, FId} = start_founder(15822, Cert, Key, root_genesis(Config), Config),
    ?assert(eventually(fun() -> role(FPeer) =:= leader end, 15000)),
    {J1Peer, J1Id} = start_joiner(15823, Cert, Key, [FId], Config),
    ?assert(eventually(fun() -> committee_size(FPeer) =:= 2 end, 20000)),
    ?assert(eventually(fun() -> committee_size(J1Peer) =:= 2 end, 20000)),

    %% J2 seeds at J1 — a FOLLOWER — so it must be redirected to the leader before admission.
    {J2Peer, _J2Id} = start_joiner(15824, Cert, Key, [J1Id], Config),
    [ ?assert(eventually(fun() -> committee_size(P) =:= 3 end, 25000))
      || P <- [FPeer, J1Peer, J2Peer] ],
    %% J2 synced the genesis, and a fresh write reaches all three.
    ?assert(eventually(fun() -> match_ok(prove(J2Peer, {acl_sovereign, 'quod:root'})) end, 15000)),
    ?assertMatch({ok, _, _}, write([{FPeer, FId}], {assertz, {planet, earth}})),
    [ ?assert(eventually(fun() -> match_ok(prove(P, {planet, earth})) end, 15000))
      || P <- [FPeer, J1Peer, J2Peer] ],
    stop_all([J2Peer, J1Peer, FPeer]).

%% A fail-closed `can_join` refuses admission: the committee stays 1, the joiner stays out.
t_join_denied(Config) ->
    {Cert, Key} = ?config(certkey, Config),
    {FPeer, FId} = start_founder(15830, Cert, Key, closed_genesis(Config), Config),
    ?assert(eventually(fun() -> role(FPeer) =:= leader end, 15000)),
    {JPeer, _JId} = start_joiner(15831, Cert, Key, [FId], Config),
    %% give the join driver several retry ticks; admission must keep failing.
    timer:sleep(4000),
    ?assertEqual(1, committee_size(FPeer)),   %% never grew
    ?assertEqual(0, committee_size(JPeer)),   %% never admitted/synced ⇒ empty committee
    stop_all([JPeer, FPeer]).

%%%===================================================================
%%% node start helpers
%%%===================================================================

start_founder(Port, Cert, Key, Genesis, Config) ->
    Self = {"127.0.0.1", Port},
    Peer = start_peer(Port, Cert, Key),
    Cfg  = (?TUNING)#{node_id => Self, mode => create, committee => [],
                      data_dir => datadir(Config, Port), genesis_file => Genesis},
    {ok, _} = peer:call(Peer, quod_ns_sup, start_namespace, [?NS, Cfg]),
    {Peer, Self}.

start_joiner(Port, Cert, Key, Seeds, Config) ->
    Self = {"127.0.0.1", Port},
    Peer = start_peer(Port, Cert, Key),
    Cfg  = (?TUNING)#{node_id => Self, mode => join, committee => [],
                      seed_peers => Seeds, data_dir => datadir(Config, Port)},
    {ok, _} = peer:call(Peer, quod_ns_sup, start_namespace, [?NS, Cfg]),
    {Peer, Self}.

%% Boot one quod node (own QUIC listener on Port, shared dev cert). Returns the peer handle.
start_peer(Port, Cert, Key) ->
    Self = {"127.0.0.1", Port},
    Name = list_to_atom("join_" ++ integer_to_list(Port)),
    {ok, Peer, _Node} = peer:start(
                          #{name => Name, connection => standard_io,
                            args => ["-pa" | code:get_path()]}),
    _ = peer:call(Peer, logger, set_primary_config, [level, warning]),
    _ = peer:call(Peer, application, load, [quod]),
    ok = peer:call(Peer, application, set_env, [quod, listen_port, Port]),
    ok = peer:call(Peer, application, set_env, [quod, node_id, Self]),
    ok = peer:call(Peer, application, set_env, [quod, certfile, Cert]),
    ok = peer:call(Peer, application, set_env, [quod, keyfile, Key]),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [quod]),
    Peer.

%% The real root genesis (default-open can_join). Same _build path on controller + peers.
root_genesis(_Config) ->
    filename:join(code:priv_dir(quod), "ontologies/quod_root.pl").

%% A genesis with NO can_join clause ⇒ admission proves an unknown predicate ⇒ fail-closed.
closed_genesis(Config) ->
    F = filename:join(?config(priv_dir, Config), "closed_root.pl"),
    ok = file:write_file(F, <<"acl_sovereign('quod:root').\ncan_read(_, _, _).\n">>),
    F.

%%%===================================================================
%%% query helpers
%%%===================================================================

status(Peer)         -> peer:call(Peer, quod_ledger, status, [?NS]).
role(Peer)           -> maps:get(role, status(Peer), undefined).
committee_size(Peer) -> length(peer:call(Peer, quod_ledger, committee, [?NS])).

%% Submit a write the way a client does: find the leader and try it, retrying on a
%% redirect/timeout (leadership can churn transiently).
write(Nodes, Goal) -> write(Nodes, Goal, 20).
write(_Nodes, _Goal, 0) -> {error, exhausted};
write(Nodes, Goal, N) ->
    case leader(Nodes) of
        none -> timer:sleep(200), write(Nodes, Goal, N - 1);
        {LeaderPeer, _Id} ->
            case prove(LeaderPeer, Goal) of
                {ok, _, _} = Ok -> Ok;
                _Transient      -> timer:sleep(200), write(Nodes, Goal, N - 1)
            end
    end.

leader(Nodes) ->
    case [N || {P, _} = N <- Nodes, (catch role(P)) =:= leader] of
        [L | _] -> L;
        []      -> none
    end.

%% Prove a goal, retrying only while the engine is still rebuilding.
prove(Peer, Goal) -> prove(Peer, Goal, 200).
prove(_Peer, _Goal, 0) -> {error, timeout};
prove(Peer, Goal, N) ->
    case peer:call(Peer, quod_prolog, prove, [?NS, Goal, ?NS]) of
        {error, rebuilding} -> timer:sleep(25), prove(Peer, Goal, N - 1);
        R -> R
    end.

%% (eventually/2, stop_all/1, match_ok/1, datadir/2 are shared — see quod_ct.)

%% self-signed dev cert for the QUIC listeners (TLS 1.3 mandatory), shared by all nodes.
make_cert(Config) ->
    CertDir = filename:join(?config(priv_dir, Config), "certs"),
    ok = filelib:ensure_dir(filename:join(CertDir, "x")),
    Cert = filename:join(CertDir, "cert.pem"),
    Key  = filename:join(CertDir, "key.pem"),
    _ = os:cmd("openssl req -x509 -newkey rsa:2048 -nodes -keyout " ++ Key ++
               " -out " ++ Cert ++ " -days 1 -subj /CN=quod-join-test 2>&1"),
    true = filelib:is_regular(Cert) andalso filelib:is_regular(Key),
    {Cert, Key}.

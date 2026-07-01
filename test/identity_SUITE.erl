-module(identity_SUITE).
-moduledoc """
Integration: the **production identity path** — each node has a real Ed25519 keypair, so its
`node_id` is its pubkey (not the address). Unlike `join_SUITE`/`raft_safety_SUITE` (which use the
no-identity path, address-as-id), here every node sets `node_pubkey` + a per-node identity cert, so
the committee is identified by pubkeys, connections are mutually authenticated, and dialing a member
goes pubkey → resolved address.

- `t_real_key_committee` — a founder + a joiner, each with its own keypair, form a 2-voter committee
  over mutual-TLS loopback QUIC; content syncs. Exercises pubkey ids end to end: the join handshake
  (joiner dials the founder's endpoint, the founder learns the joiner's pubkey⇒addr from the
  authenticated header), the resolver (the founder dials the joiner back BY PUBKEY), and the peercert
  bind (every inbound connection's header pubkey must match `quic:peercert/1`).
- `t_committee_ids_are_pubkeys` — the committee members are 32-byte Ed25519 keys, not `{Host,Port}`.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([t_real_key_committee/1, t_committee_ids_are_pubkeys/1]).
-import(quod_ct, [eventually/2, stop_all/1, match_ok/1, datadir/2]).

-define(NS, <<"quod:root">>).
-define(TUNING, #{election_ms => 2500, election_jit => 0.4, heartbeat_ms => 150, join_ms => 500}).

all() -> [t_real_key_committee, t_committee_ids_are_pubkeys].

init_per_suite(Config) -> Config.
end_per_suite(_Config) -> ok.

%%%===================================================================
%%% tests
%%%===================================================================

%% Two nodes, each with its OWN keypair, form a 2-voter committee — the real pubkey path.
t_real_key_committee(Config) ->
    {FPeer, FPub, FAddr} = start_founder(15860, Config),
    ?assert(eventually(fun() -> role(FPeer) =:= leader end, 15000)),
    ?assertMatch({ok, _, _}, write([{FPeer, FPub}], {assertz, {capital, france, paris}})),

    {JPeer, JPub, _JAddr} = start_joiner(15861, [FAddr], Config),
    %% admitted (mutual-TLS bind + possession) → caught up (founder dials joiner BY PUBKEY,
    %% resolved via the learned hint) → promoted: committee = 2 voters on BOTH.
    ?assert(eventually(fun() -> committee_size(FPeer) =:= 2 end, 20000)),
    ?assert(eventually(fun() -> committee_size(JPeer) =:= 2 end, 20000)),
    %% the joiner synced the genesis AND the pre-join write.
    ?assert(eventually(fun() -> match_ok(prove(JPeer, {acl_sovereign, 'quod:root'})) end, 15000)),
    ?assert(eventually(fun() -> match_ok(prove(JPeer, {capital, france, {'X'}})) end, 15000)),
    %% a post-join write commits (needs both voters) and reaches both KBs.
    ?assertMatch({ok, _, _}, write([{FPeer, FPub}, {JPeer, JPub}], {assertz, {capital, japan, tokyo}})),
    [ ?assert(eventually(fun() -> match_ok(prove(P, {capital, japan, {'Y'}})) end, 15000))
      || P <- [FPeer, JPeer] ],
    %% the committee is exactly the two pubkeys (each member sees both).
    ?assertEqual(lists:sort([FPub, JPub]), lists:sort(committee(FPeer))),
    stop_all([JPeer, FPeer]).

%% The committee-member ids are real 32-byte Ed25519 pubkeys, not addresses.
t_committee_ids_are_pubkeys(Config) ->
    {FPeer, FPub, _FAddr} = start_founder(15862, Config),
    ?assert(eventually(fun() -> role(FPeer) =:= leader end, 15000)),
    ?assert(eventually(fun() -> committee_size(FPeer) =:= 1 end, 10000)),
    [Member] = committee(FPeer),
    ?assert(is_binary(Member)),
    ?assertEqual(32, byte_size(Member)),
    ?assertEqual(FPub, Member),
    stop_all([FPeer]).

%%%===================================================================
%%% node start helpers (each node gets its OWN keypair = real identity)
%%%===================================================================

start_founder(Port, Config) ->
    start_node(Port, create, [], root_genesis(), Config).

start_joiner(Port, Seeds, Config) ->
    start_node(Port, join, Seeds, undefined, Config).

start_node(Port, Mode, Seeds, Genesis, Config) ->
    {Pub, Seed} = quod_identity:generate(),
    Cert = quod_identity:mint_cert({Pub, Seed}),
    Key  = quod_identity:key_term({Pub, Seed}),
    Addr = {"127.0.0.1", Port},
    Peer = start_peer(Port, Addr, Pub, Cert, Key),
    Base = (?TUNING)#{node_id => Pub, mode => Mode, committee => [],
                      seed_peers => Seeds, data_dir => datadir(Config, Port)},
    Cfg  = case Genesis of undefined -> Base; G -> Base#{genesis_file => G} end,
    {ok, _} = peer:call(Peer, quod_ns_sup, start_namespace, [?NS, Cfg]),
    {Peer, Pub, Addr}.

%% Boot a node with a REAL identity: node_pubkey + a per-node Ed25519 cert/key in the env, so
%% quod_quic's transport id is {Pub, Addr} and it authenticates peers by their key. (env node_id
%% is the ADDRESS the transport listens at; the ledger's node_id, set in Cfg above, is the pubkey.)
start_peer(Port, Addr, _Pub, Cert, Key) ->
    Name = list_to_atom("identity_" ++ integer_to_list(Port)),
    {ok, Peer, _Node} = peer:start(
                          #{name => Name, connection => standard_io,
                            args => ["-pa" | code:get_path()]}),
    _ = peer:call(Peer, logger, set_primary_config, [level, warning]),
    _ = peer:call(Peer, application, load, [quod]),
    ok = peer:call(Peer, application, set_env, [quod, listen_port, Port]),
    ok = peer:call(Peer, application, set_env, [quod, node_id, Addr]),       %% transport address
    ok = peer:call(Peer, application, set_env, [quod, node_pubkey, _Pub]),   %% our identity (pubkey)
    ok = peer:call(Peer, application, set_env, [quod, identity_cert, Cert]),
    ok = peer:call(Peer, application, set_env, [quod, identity_key, Key]),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [quod]),
    Peer.

root_genesis() -> filename:join(code:priv_dir(quod), "ontologies/quod_root.pl").

%%%===================================================================
%%% query helpers
%%%===================================================================

status(Peer)         -> peer:call(Peer, quod_ledger, status, [?NS]).
role(Peer)           -> maps:get(role, status(Peer), undefined).
committee(Peer)      -> peer:call(Peer, quod_ledger, committee, [?NS]).
committee_size(Peer) -> length(committee(Peer)).

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

prove(Peer, Goal) -> prove(Peer, Goal, 200).
prove(_Peer, _Goal, 0) -> {error, timeout};
prove(Peer, Goal, N) ->
    case peer:call(Peer, quod_prolog, prove, [?NS, Goal, ?NS]) of
        {error, rebuilding} -> timer:sleep(25), prove(Peer, Goal, N - 1);
        R -> R
    end.

%% (eventually/2, stop_all/1, match_ok/1, datadir/2 are shared — see quod_ct.)

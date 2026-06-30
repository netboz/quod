-module(replica_SUITE).
-moduledoc """
Integration for the reader/subscriber layer P1 — **read-replicas + remote-read** over loopback
QUIC (OS `peer` nodes, no Erlang distribution).

- `t_replica_reads_locally` — a node joins `quod:root` as a permanent **non-voting replica**
  (`content.role=replica`): it catches up the full ledger and serves `prove` locally, yet is
  **never promoted** (the committee stays size 1 — reads never touched consensus). A post-join
  write on the founder reaches the replica's kb.
- `t_remote_read` — a **Neither** node (no namespace) runs a `quod_prove` client and remote-reads
  from the replica: a read returns bindings + the committed height; a write goal is refused
  (`read_only`); a `MinHeight` ahead of the replica returns `stale`.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([t_replica_reads_locally/1, t_remote_read/1]).

-define(NS, <<"quod:root">>).
-define(TUNING, #{election_ms => 2500, election_jit => 0.4, heartbeat_ms => 150, join_ms => 500}).

all() -> [t_replica_reads_locally, t_remote_read].

init_per_suite(Config) ->
    {Cert, Key} = make_cert(Config),
    [{certkey, {Cert, Key}} | Config].

end_per_suite(_Config) -> ok.

%%%===================================================================
%%% tests
%%%===================================================================

t_replica_reads_locally(Config) ->
    {Cert, Key} = ?config(certkey, Config),
    {FPeer, FId} = start_founder(15840, Cert, Key, Config),
    ?assert(eventually(fun() -> role(FPeer) =:= leader end, 15000)),
    ?assertMatch({ok, _, _}, write([{FPeer, FId}], {assertz, {capital, france, paris}})),

    {RPeer, _RId} = start_replica(15841, Cert, Key, [FId], Config),
    %% the replica catches up + serves reads, but the committee NEVER grows past the founder.
    ?assert(eventually(fun() -> match_ok(prove(RPeer, {acl_sovereign, 'quod:root'})) end, 20000)),
    ?assert(eventually(fun() -> match_ok(prove(RPeer, {capital, france, {'X'}})) end, 15000)),
    ?assertEqual(1, committee_size(FPeer)),   %% founder never promoted the replica
    ?assertEqual(1, committee_size(RPeer)),   %% replica sees a 1-voter committee (itself excluded)

    %% a further write on the founder reaches the replica's kb (it stays fresh via replication).
    ?assertMatch({ok, _, _}, write([{FPeer, FId}], {assertz, {capital, japan, tokyo}})),
    ?assert(eventually(fun() -> match_ok(prove(RPeer, {capital, japan, {'Y'}})) end, 15000)),
    stop_all([RPeer, FPeer]).

t_remote_read(Config) ->
    {Cert, Key} = ?config(certkey, Config),
    {FPeer, FId} = start_founder(15843, Cert, Key, Config),
    ?assert(eventually(fun() -> role(FPeer) =:= leader end, 15000)),
    {RPeer, RId} = start_replica(15844, Cert, Key, [FId], Config),
    ?assert(eventually(fun() -> match_ok(prove(RPeer, {acl_sovereign, 'quod:root'})) end, 20000)),

    %% a Neither node: the quod app (gproc + transport) but no namespace; a standalone quod_prove
    %% client pointed at the replica.
    NPeer = start_bare_node(15845, Cert, Key),
    NCfg  = #{node_id => {"127.0.0.1", 15845}, seed_peers => [RId]},
    {ok, _} = peer:call(NPeer, quod_prove, start_link, [?NS, NCfg]),

    %% a read returns bindings + the height it was proved at (a genesis fact, present on the replica).
    ?assert(eventually(fun() -> match_remote(remote(NPeer, {acl_sovereign, 'quod:root'}, RId, 0)) end, 15000)),
    {ok, _Bs, H} = remote(NPeer, {acl_sovereign, 'quod:root'}, RId, 0),
    ?assert(is_integer(H) andalso H >= 0),
    %% a write goal is refused on the read path.
    ?assertEqual({error, read_only}, remote(NPeer, {assertz, {sneaky, write}}, RId, 0)),
    %% a MinHeight far ahead of the replica is reported stale, not silently served.
    ?assertMatch({stale, _}, remote(NPeer, {acl_sovereign, 'quod:root'}, RId, 1000000)),
    stop_all([NPeer, RPeer, FPeer]).

%%%===================================================================
%%% node start
%%%===================================================================

start_founder(Port, Cert, Key, Config) ->
    Self = {"127.0.0.1", Port},
    Peer = start_bare_node(Port, Cert, Key),
    Cfg  = (?TUNING)#{node_id => Self, mode => create, role => member, committee => [],
                      data_dir => datadir(Config, Port),
                      genesis_file => filename:join(code:priv_dir(quod), "ontologies/quod_root.pl")},
    {ok, _} = peer:call(Peer, quod_ns_sup, start_namespace, [?NS, Cfg]),
    {Peer, Self}.

start_replica(Port, Cert, Key, Seeds, Config) ->
    Self = {"127.0.0.1", Port},
    Peer = start_bare_node(Port, Cert, Key),
    Cfg  = (?TUNING)#{node_id => Self, mode => join, role => replica, committee => [],
                      seed_peers => Seeds, data_dir => datadir(Config, Port)},
    {ok, _} = peer:call(Peer, quod_ns_sup, start_namespace, [?NS, Cfg]),
    {Peer, Self}.

%% A quod node with gproc + transport up but NO content namespace (legacy mode — no QUOD_CONF).
start_bare_node(Port, Cert, Key) ->
    Name = list_to_atom("replica_" ++ integer_to_list(Port)),
    {ok, Peer, _Node} = peer:start(
                          #{name => Name, connection => standard_io, args => ["-pa" | code:get_path()]}),
    _ = peer:call(Peer, logger, set_primary_config, [level, warning]),
    _ = peer:call(Peer, application, load, [quod]),
    ok = peer:call(Peer, application, set_env, [quod, listen_port, Port]),
    ok = peer:call(Peer, application, set_env, [quod, node_id, {"127.0.0.1", Port}]),
    ok = peer:call(Peer, application, set_env, [quod, certfile, Cert]),
    ok = peer:call(Peer, application, set_env, [quod, keyfile, Key]),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [quod]),
    Peer.

datadir(Config, Port) -> filename:join(?config(priv_dir, Config), "data_" ++ integer_to_list(Port)).
stop_all(Peers) -> _ = [catch peer:stop(P) || P <- Peers], ok.

%%%===================================================================
%%% query helpers
%%%===================================================================

status(Peer)         -> peer:call(Peer, quod_ledger, status, [?NS]).
role(Peer)           -> maps:get(role, status(Peer), undefined).
committee_size(Peer) -> length(peer:call(Peer, quod_ledger, committee, [?NS])).

remote(Peer, Goal, Contact, MinHeight) ->
    peer:call(Peer, quod_prove, remote, [?NS, Goal, ?NS, MinHeight, Contact]).

write(Nodes, Goal) -> write(Nodes, Goal, 20).
write(_Nodes, _Goal, 0) -> {error, exhausted};
write(Nodes, Goal, N) ->
    case [P || {P, _} <- Nodes, (catch role(P)) =:= leader] of
        []           -> timer:sleep(200), write(Nodes, Goal, N - 1);
        [Leader | _] -> case prove(Leader, Goal) of
                            {ok, _, _} = Ok -> Ok;
                            _               -> timer:sleep(200), write(Nodes, Goal, N - 1)
                        end
    end.

prove(Peer, Goal) -> prove(Peer, Goal, 200).
prove(_Peer, _Goal, 0) -> {error, timeout};
prove(Peer, Goal, N) ->
    case peer:call(Peer, quod_prolog, prove, [?NS, Goal, ?NS]) of
        {error, rebuilding} -> timer:sleep(25), prove(Peer, Goal, N - 1);
        R -> R
    end.

match_ok({ok, [_ | _], _}) -> true;
match_ok(_)                -> false.
match_remote({ok, [_ | _], _}) -> true;
match_remote(_)                -> false.

eventually(_F, T) when T =< 0 -> false;
eventually(F, T) -> case (catch F()) of true -> true; _ -> timer:sleep(150), eventually(F, T - 150) end.

make_cert(Config) ->
    CertDir = filename:join(?config(priv_dir, Config), "certs"),
    ok = filelib:ensure_dir(filename:join(CertDir, "x")),
    Cert = filename:join(CertDir, "cert.pem"),
    Key  = filename:join(CertDir, "key.pem"),
    _ = os:cmd("openssl req -x509 -newkey rsa:2048 -nodes -keyout " ++ Key ++
               " -out " ++ Cert ++ " -days 1 -subj /CN=quod-replica-test 2>&1"),
    true = filelib:is_regular(Cert) andalso filelib:is_regular(Key),
    {Cert, Key}.

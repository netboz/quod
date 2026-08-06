-module(quod_directory_SUITE).
-moduledoc """
Root-driven directory integration over two real QUIC nodes.

A founder admits a persistent peer key with an old endpoint through a live root
commit. The peer then moves to a new endpoint. Directory control reuses the
root ontology's current join contact, authenticates the endpoint's key, checks
that key against the local root proof, repairs the stale hint, and converges
signed records without separate directory bootstrap configuration.

The same live nodes exercise the namespace manager's desired-state recovery
when either dynamic supervisor or the manager itself is replaced.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([root_control_resync_after_endpoint_move/1,
         namespace_manager_lifecycle/1]).
-export([hold_namespace/3, refresh_directory_control/0,
         reconcile_namespace_manager/0]).

-define(ROOT, <<"quod:root">>).
-define(AGENT, <<"quod:agent">>).
-define(TARGET_PORT, 15980).
-define(JOINER_OLD_PORT, 15981).
-define(JOINER_PORT, 15982).

all() ->
    [root_control_resync_after_endpoint_move,
     namespace_manager_lifecycle].

init_per_suite(Config) ->
    TargetKey = quod_identity:generate(),
    JoinerKey = quod_identity:generate(),
    {TargetPub, _} = TargetKey,
    {JoinerPub, _} = JoinerKey,
    TargetAddr = {"127.0.0.1", ?TARGET_PORT},
    JoinerOldAddr = {"127.0.0.1", ?JOINER_OLD_PORT},
    JoinerAddr = {"127.0.0.1", ?JOINER_PORT},
    Allowlist = #{?ROOT => [JoinerPub], ?AGENT => [JoinerPub]},
    Target = start_node(
               directory_target, TargetAddr, TargetKey,
               Allowlist, [JoinerAddr], false,
               directory_target, Config),
    start_root_founder(Target, TargetKey, Config),
    ok = wait_root_peers(Target, [TargetPub], 400),

    %% The candidate's real listener is up at E_old, but it has made no network
    %% contact and has no root namespace yet.
    JoinerOld = start_node(
                  directory_joiner_old, JoinerOldAddr, JoinerKey,
                  Allowlist, [TargetAddr], true,
                  directory_joiner, Config),
    ?assertEqual(
       error,
       peer:call(Target, quod_quic, resolve, [JoinerPub])),

    %% The readiness row permits a real governed admission without adding an
    %% address observation. The cache miss after that row and exact old endpoint
    %% after the commit make the live-commit overwrite assertion non-vacuous.
    DigestTable =
        peer:call(Target, quod_feed, digest_table, [?ROOT]),
    true = peer:call(
             Target, quod_feed, record_digest,
             [DigestTable, JoinerPub, 1]),
    ?assertEqual(
       error,
       peer:call(Target, quod_quic, resolve, [JoinerPub])),
    ?assertMatch(
       {ok, [_], _},
       quod_ct:peer_prove(
         Target, ?ROOT,
         {admit, JoinerPub, "127.0.0.1", ?JOINER_OLD_PORT})),
    ?assertEqual(
       {ok, JoinerOldAddr},
       peer:call(Target, quod_quic, resolve, [JoinerPub])),

    GenesisHash =
        peer:call(Target, quod_simplex, genesis_hash, [?ROOT]),
    start_root_joiner(
      JoinerOld, JoinerKey, GenesisHash, TargetAddr, Config),
    ok = wait_root_ready(JoinerOld, 2, 400),
    ok = peer:call(
           Target, quod_directory_control, start_tracking, []),
    ok = peer:call(
           JoinerOld, quod_directory_control, start_tracking, []),
    ExpectedOldRoot =
        [{GenesisHash, JoinerPub, element(1, JoinerOldAddr),
          element(2, JoinerOldAddr)}],
    ok = wait_directory_hosts(
           Target, ?ROOT, ExpectedOldRoot, 400),
    ok = wait_directory_hosts(
           JoinerOld, ?ROOT, ExpectedOldRoot, 400),
    ok = peer:stop(JoinerOld),
    ?assertEqual(
       {ok, JoinerOldAddr},
       peer:call(Target, quod_quic, resolve, [JoinerPub])),

    %% Restarting the same durable root member at a new port supplies the real
    %% deployment shape. The founder has no live observation of E_new; its
    %% root contact must authenticate the moved key and promote the endpoint
    %% only because the root proof already authorizes that key.
    Joiner = start_node(
               directory_joiner, JoinerAddr, JoinerKey,
               Allowlist, [TargetAddr], true,
               directory_joiner, Config),
    start_root_joiner(
      Joiner, JoinerKey, GenesisHash, TargetAddr, Config),
    ok = peer:call(
           Target, ?MODULE, refresh_directory_control, []),
    ok = wait_resolve(Target, JoinerPub, JoinerAddr, 400),
    ok = wait_root_ready(Joiner, 2, 400),
    ?assertEqual(
       {ok, TargetAddr},
       peer:call(Joiner, quod_quic, resolve, [TargetPub])),
    ok = wait_root_peers(
           Target, [TargetPub, JoinerPub], 400),
    ok = wait_root_peers(
           Joiner, [TargetPub, JoinerPub], 400),
    ok = peer:call(
           Joiner, quod_directory_control, start_tracking, []),
    ok = peer:call(
           Target, ?MODULE, refresh_directory_control, []),
    ok = peer:call(
           Joiner, ?MODULE, refresh_directory_control, []),
    ok = wait_control_endpoint(
           Target, JoinerPub, JoinerAddr, 400),
    ExpectedRoot =
        [{GenesisHash, JoinerPub, element(1, JoinerAddr),
          element(2, JoinerAddr)}],
    ok = wait_directory_hosts(
           Target, ?ROOT, ExpectedRoot, 400),
    ok = wait_directory_hosts(
           Joiner, ?ROOT, ExpectedRoot, 400),
    [{target, Target}, {joiner, Joiner},
     {target_pub, TargetPub}, {joiner_pub, JoinerPub},
     {target_addr, TargetAddr}, {joiner_addr, JoinerAddr} | Config].

end_per_suite(Config) ->
    _ = [catch peer:stop(P)
         || P <- [?config(target, Config), ?config(joiner, Config)]],
    ok.

root_control_resync_after_endpoint_move(Config) ->
    Target = ?config(target, Config),
    Joiner = ?config(joiner, Config),
    TargetPub = ?config(target_pub, Config),
    JoinerPub = ?config(joiner_pub, Config),
    TargetAddr = ?config(target_addr, Config),
    JoinerAddr = ?config(joiner_addr, Config),
    GenesisHash = peer:call(
                    Target, quod_simplex, genesis_hash, [?ROOT]),
    ExpectedRoot =
        [{GenesisHash, JoinerPub,
          element(1, JoinerAddr), element(2, JoinerAddr)}],
    ?assertEqual(
       ok,
       wait_directory_hosts(Target, ?ROOT, ExpectedRoot, 400)),
    ?assertEqual(
       ok,
       wait_directory_hosts(Joiner, ?ROOT, ExpectedRoot, 400)),
    ?assertEqual(
       ok,
       wait_control_links(Target, 2, 1, 400)),
    ?assertEqual(
       ok,
       wait_control_links(Joiner, 2, 1, 400)),

    TargetStats = peer:call(
                    Target, quod_directory_control, stats, []),
    JoinerStats = peer:call(
                    Joiner, quod_directory_control, stats, []),
    ?assertNot(maps:is_key(bootstraps, TargetStats)),
    ?assertNot(maps:is_key(bootstraps, JoinerStats)),
    ?assert(maps:get(root_proof_height, TargetStats) >= 2),
    ?assert(maps:get(root_proof_height, JoinerStats) >= 2),
    ?assertNot(maps:get(enabled, TargetStats)),
    ?assertEqual(0, maps:get(sequence, TargetStats)),
    ?assert(maps:get(enabled, JoinerStats)),
    ?assert(maps:get(sequence, JoinerStats) > 0),

    %% Kill the joiner's exact outbound control link. Its monitor must remove
    %% only that generation and reopen a pinned link from the retained root
    %% truth plus the still-current ordinary address observation.
    JoinerState0 = peer:call(
                     Joiner, quod_directory_control,
                     test_control_state, []),
    {TargetAddr, OldLink, _OldMonitor} =
        maps:get(
          TargetPub, maps:get(control_links, JoinerState0)),
    ok = peer:call(Joiner, quod_link, close, [OldLink]),
    ?assertEqual(
       ok,
       wait_replaced_control_link(
         Joiner, TargetPub, OldLink, 400)),

    AgentAnchor = crypto:hash(sha256, ?AGENT),
    _JoinerAgentHost = peer:call(
                         Joiner, erlang, spawn,
                         [?MODULE, hold_namespace,
                          [?AGENT, AgentAnchor, observer]]),
    ok = peer:call(
           Joiner, quod_directory_control, namespace_changed, []),
    ExpectedAgent =
        [{AgentAnchor, JoinerPub,
          element(1, JoinerAddr), element(2, JoinerAddr)}],
    ?assertEqual(
       ok,
       wait_directory_hosts(Target, ?AGENT, ExpectedAgent, 400)),
    ?assertEqual(
       ok,
       wait_directory_hosts(Joiner, ?AGENT, ExpectedAgent, 400)),

    %% Pinned directory links cannot pollute or redirect the live ordinary root
    %% address observations established above.
    ?assertEqual(
       {ok, JoinerAddr},
       peer:call(Target, quod_quic, resolve, [JoinerPub])),
    ?assertEqual(
       {ok, TargetAddr},
       peer:call(Joiner, quod_quic, resolve, [TargetPub])).

namespace_manager_lifecycle(Config) ->
    Target = ?config(target, Config),
    TargetAddr = ?config(target_addr, Config),
    JoinerAddr = ?config(joiner_addr, Config),
    %% Desired namespace state is outside the replaceable dynamic
    %% supervisors. Replacing either pool must reconstruct its children
    %% without restarting the node or replaying application startup code.
    OldNsSup = peer:call(
                 Target, quod_reg, where,
                 [{quod_ns_sup, node}]),
    OldRoot = peer:call(
                Target, quod_reg, where,
                [{quod_ns, ?ROOT}]),
    true = peer:call(Target, erlang, exit, [OldNsSup, kill]),
    ?assertEqual(
       ok,
       wait_recovered_child(
         Target, {quod_ns_sup, node}, {quod_ns, ?ROOT},
         OldNsSup, OldRoot, 400)),
    ?assertEqual(ok, wait_root_ready(Target, 2, 400)),

    {ok, OldBrahms} = peer:call(
                        Target, quod_brahms, start_namespace,
                        [?ROOT,
                         #{node_id => TargetAddr,
                           seed_peers => [JoinerAddr]}]),
    %% The desired state is also durable across a manager replacement, not
    %% merely across a pool replacement while the original manager survives.
    OldManager = peer:call(
                   Target, quod_reg, where,
                   [{namespace_manager, node}]),
    true = peer:call(Target, erlang, exit, [OldManager, kill]),
    ?assertEqual(
       ok,
       wait_replaced_process(
         Target, {namespace_manager, node}, OldManager, 400)),
    OldBrahmsSup = peer:call(
                     Target, quod_reg, where,
                     [{quod_brahms_sup, node}]),
    true = peer:call(
             Target, erlang, exit, [OldBrahmsSup, kill]),
    ?assertEqual(
       ok,
       wait_recovered_child(
         Target, {quod_brahms_sup, node},
         {quod_brahms, ?ROOT},
         OldBrahmsSup, OldBrahms, 400)),

    %% Stopping through the manager removes desired state before terminating
    %% the child. A later pool replacement must not resurrect it.
    ok = peer:call(
           Target, quod_namespace_manager, stop_brahms, [?ROOT]),
    {ok, #{brahms := DesiredBrahms}} =
        peer:call(
          Target, application, get_env,
          [quod, namespace_desired]),
    ?assertNot(maps:is_key(?ROOT, DesiredBrahms)),
    StoppedBrahmsSup = peer:call(
                          Target, quod_reg, where,
                          [{quod_brahms_sup, node}]),
    true = peer:call(
             Target, erlang, exit, [StoppedBrahmsSup, kill]),
    ?assertEqual(
       ok,
       wait_replaced_process(
         Target, {quod_brahms_sup, node},
         StoppedBrahmsSup, 400)),
    ok = peer:call(
           Target, ?MODULE, reconcile_namespace_manager, []),
    ?assertEqual(
       undefined,
       peer:call(
         Target, quod_reg, where,
         [{quod_brahms, ?ROOT}])).

start_node(Name, {Host, Port}, {Pub, Seed} = KeyPair,
           Allowlist, RootContacts, DirectoryServer,
           IdentityName, Config) ->
    {ok, Peer, _Node} = peer:start(
                          #{name => Name, connection => standard_io,
                            args => ["-pa" | code:get_path()]}),
    _ = peer:call(
          Peer, logger, set_primary_config, [level, warning]),
    _ = peer:call(Peer, application, load, [quod]),
    Set =
        fun(Key, Value) ->
            ok = peer:call(
                   Peer, application, set_env,
                   [quod, Key, Value])
        end,
    IdentityDir = filename:join(
                    ?config(priv_dir, Config),
                    atom_to_list(IdentityName)),
    Set(listen_port, Port),
    Set(metrics_port, Port + 1000),
    Set(node_addr, {Host, Port}),
    Set(node_pubkey, Pub),
    Set(identity_key, quod_identity:key_term({Pub, Seed})),
    Set(identity_cert, quod_identity:mint_cert(KeyPair)),
    Directory =
        case DirectoryServer of
            true ->
                #{allowlist => Allowlist,
                  root_contacts => RootContacts,
                  identity_dir => IdentityDir};
            false ->
                #{allowlist => Allowlist,
                  root_contacts => RootContacts}
        end,
    Set(directory, Directory),
    {ok, _} = peer:call(
                Peer, application, ensure_all_started, [quod]),
    Peer.

start_root_founder(Peer, {Pub, Seed}, Config) ->
    DataDir = filename:join(
                ?config(priv_dir, Config),
                "directory_target_root"),
    KeyTerm = quod_identity:key_term({Pub, Seed}),
    RootConfig =
        #{mode => create, role => member, node_id => Pub,
          identity => #{pubkey => Pub, key => KeyTerm},
          committee => [], data_dir => DataDir,
          genesis_file =>
              filename:join(
                code:priv_dir(quod),
                "ontologies/quod_root.pl")},
    {ok, _} = peer:call(
                Peer, quod_ns_sup, start_namespace,
                [?ROOT, RootConfig]),
    ok.

start_root_joiner(
  Peer, {Pub, Seed}, GenesisHash, TargetAddr, Config) ->
    DataDir = filename:join(
                ?config(priv_dir, Config),
                "directory_joiner_root"),
    KeyTerm = quod_identity:key_term({Pub, Seed}),
    RootConfig =
        #{mode => join, node_id => Pub,
          identity => #{pubkey => Pub, key => KeyTerm},
          genesis_hash => GenesisHash,
          seed_peers => [TargetAddr],
          data_dir => DataDir},
    {ok, _} = peer:call(
                Peer, quod_ns_sup, start_namespace,
                [?ROOT, RootConfig]),
    ok.

refresh_directory_control() ->
    quod_reg:where({directory, control}) ! directory_tick,
    ok.

reconcile_namespace_manager() ->
    Manager = quod_reg:where({namespace_manager, node}),
    Manager ! reconcile,
    _ = sys:get_state(Manager),
    ok.

hold_namespace(Ns, GenesisAnchor, Role) ->
    true = gproc:reg({n, l, {quod_ns, Ns}}),
    true = gproc:reg({n, l, {quod_simplex, Ns}}),
    true = gproc:reg({n, l, {quod_prolog, Ns}}),
    Table = binary_to_atom(
              <<"quod_simplex_genesis_", Ns/binary>>, utf8),
    _ = ets:new(Table, [named_table, protected, set]),
    true = ets:insert(Table, {anchor, GenesisAnchor}),
    hold_namespace_loop(Role).

hold_namespace_loop(Role) ->
    receive
        {'$gen_call', From, get_status} ->
            gen:reply(From, #{role => Role}),
            hold_namespace_loop(Role);
        stop ->
            ok
    end.

wait_root_peers(Peer, Expected, Retries) ->
    wait_root_peers(Peer, Expected, Retries, undefined).

wait_root_peers(_Peer, _Expected, 0, LastResult) ->
    {timeout, LastResult};
wait_root_peers(Peer, Expected, Retries, _LastResult) ->
    Key = {'DirectoryControlKey'},
    Keys = {'DirectoryControlKeys'},
    Goal = {findall, Key, {directory_control_peer, Key}, Keys},
    Result =
        peer:call(
          Peer, quod_prolog, prove_ro,
          [?ROOT, Goal, ?ROOT]),
    case Result of
        {ok, [Bindings], _Height} ->
            case lists:sort(
                   maps:get(
                     'DirectoryControlKeys', Bindings, []))
                     =:= lists:sort(Expected) of
                true -> ok;
                false ->
                    timer:sleep(25),
                    wait_root_peers(
                      Peer, Expected, Retries - 1, Result)
            end;
        _ ->
            timer:sleep(25),
            wait_root_peers(
              Peer, Expected, Retries - 1, Result)
    end.

wait_root_ready(Peer, Height, Retries) ->
    wait_root_ready(Peer, Height, Retries, undefined).

wait_root_ready(_Peer, _Height, 0, LastStatus) ->
    {timeout, LastStatus};
wait_root_ready(Peer, Height, Retries, _LastStatus) ->
    Status = peer:call(
               Peer, quod_simplex, status, [?ROOT]),
    case {maps:get(slot, Status, -1),
          maps:get(syncing, Status, true)} of
        {Height, false} ->
            ok;
        _ ->
            timer:sleep(25),
            wait_root_ready(
              Peer, Height, Retries - 1, Status)
    end.

wait_resolve(_Peer, _NodeKey, _Endpoint, 0) ->
    timeout;
wait_resolve(Peer, NodeKey, Endpoint, Retries) ->
    case peer:call(
           Peer, quod_quic, resolve, [NodeKey]) of
        {ok, Endpoint} ->
            ok;
        _ ->
            timer:sleep(25),
            wait_resolve(
              Peer, NodeKey, Endpoint, Retries - 1)
    end.

wait_directory_hosts(_Peer, _Ns, _Expected, 0) ->
    timeout;
wait_directory_hosts(Peer, Ns, Expected, Retries) ->
    case peer:call(
           Peer, quod_directory, directory_hosts, [Ns])
             =:= Expected of
        true ->
            ok;
        false ->
            timer:sleep(25),
            wait_directory_hosts(
              Peer, Ns, Expected, Retries - 1)
    end.

wait_control_links(_Peer, _PeerCount, _LinkCount, 0) ->
    timeout;
wait_control_links(Peer, PeerCount, LinkCount, Retries) ->
    Stats = peer:call(
              Peer, quod_directory_control, stats, []),
    case {maps:get(control_peer_count, Stats, -1),
          maps:get(control_link_count, Stats, -1)} of
        {PeerCount, LinkCount} ->
            ok;
        _ ->
            timer:sleep(25),
            wait_control_links(
              Peer, PeerCount, LinkCount, Retries - 1)
    end.

wait_control_endpoint(_Peer, _Key, _Endpoint, 0) ->
    timeout;
wait_control_endpoint(Peer, Key, Endpoint, Retries) ->
    State = peer:call(
              Peer, quod_directory_control,
              test_control_state, []),
    case maps:get(
           Key, maps:get(control_links, State), undefined) of
        {Endpoint, LinkPid, _MonitorRef}
          when is_pid(LinkPid) ->
            ok;
        _ ->
            timer:sleep(25),
            wait_control_endpoint(
              Peer, Key, Endpoint, Retries - 1)
    end.

wait_replaced_control_link(_Peer, _Key, _OldLink, 0) ->
    timeout;
wait_replaced_control_link(Peer, Key, OldLink, Retries) ->
    State = peer:call(
              Peer, quod_directory_control,
              test_control_state, []),
    case maps:get(
           Key, maps:get(control_links, State), undefined) of
        {_Endpoint, NewLink, _Monitor}
          when is_pid(NewLink), NewLink =/= OldLink ->
            ok;
        _ ->
            timer:sleep(25),
            wait_replaced_control_link(
              Peer, Key, OldLink, Retries - 1)
    end.

wait_recovered_child(
  _Peer, _SupKey, _ChildKey, _OldSup, _OldChild, 0) ->
    timeout;
wait_recovered_child(
  Peer, SupKey, ChildKey, OldSup, OldChild, Retries) ->
    Sup = peer:call(Peer, quod_reg, where, [SupKey]),
    Child = peer:call(Peer, quod_reg, where, [ChildKey]),
    case is_pid(Sup) andalso Sup =/= OldSup
         andalso is_pid(Child) andalso Child =/= OldChild of
        true ->
            ok;
        false ->
            timer:sleep(25),
            wait_recovered_child(
              Peer, SupKey, ChildKey,
              OldSup, OldChild, Retries - 1)
    end.

wait_replaced_process(_Peer, _Key, _OldPid, 0) ->
    timeout;
wait_replaced_process(Peer, Key, OldPid, Retries) ->
    case peer:call(Peer, quod_reg, where, [Key]) of
        Pid when is_pid(Pid), Pid =/= OldPid ->
            ok;
        _ ->
            timer:sleep(25),
            wait_replaced_process(Peer, Key, OldPid, Retries - 1)
    end.

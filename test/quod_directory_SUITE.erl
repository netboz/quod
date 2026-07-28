-module(quod_directory_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([signed_bootstrap_resync_and_no_learn/1]).
-export([hold_namespace/1]).

-define(NS, <<"quod:root">>).
-define(NS2, <<"quod:agent">>).
-define(TARGET_PORT, 15980).
-define(JOINER_PORT, 15981).

all() -> [signed_bootstrap_resync_and_no_learn].

init_per_suite(Config) ->
    TargetKey = quod_identity:generate(),
    JoinerKey = quod_identity:generate(),
    {TargetPub, _} = TargetKey,
    {JoinerPub, _} = JoinerKey,
    Allowlist = #{?NS => [TargetPub], ?NS2 => [TargetPub]},
    TargetAddr = {"127.0.0.1", ?TARGET_PORT},
    JoinerAddr = {"127.0.0.1", ?JOINER_PORT},
    Target = start_node(
               directory_target, TargetAddr, TargetKey,
               Allowlist, [], true, Config),
    _TargetHost = host_namespace(Target, ?NS),
    ok = peer:call(
           Target, quod_directory_control, start_tracking, []),
    Joiner = start_node(
               directory_joiner, JoinerAddr, JoinerKey,
               Allowlist, [TargetAddr], false, Config),
    ok = peer:call(
           Joiner, quod_directory_control, start_tracking, []),
    [{target, Target}, {joiner, Joiner},
     {target_pub, TargetPub}, {joiner_pub, JoinerPub},
     {target_addr, TargetAddr}, {joiner_addr, JoinerAddr} | Config].

end_per_suite(Config) ->
    _ = [catch peer:stop(P)
         || P <- [?config(target, Config), ?config(joiner, Config)]],
    ok.

signed_bootstrap_resync_and_no_learn(Config) ->
    Target = ?config(target, Config),
    Joiner = ?config(joiner, Config),
    TargetPub = ?config(target_pub, Config),
    JoinerPub = ?config(joiner_pub, Config),
    TargetAddr = ?config(target_addr, Config),
    ?assertEqual(
       ok,
       wait_until(
         fun() ->
             peer:call(Target, quod_directory, directory_hosts, [?NS])
                 =:= [{TargetPub, element(1, TargetAddr),
                       element(2, TargetAddr)}]
         end, 200)),
    ?assertEqual(
       ok,
       wait_until(
         fun() ->
             peer:call(Joiner, quod_directory, directory_hosts, [?NS])
                 =:= [{TargetPub, element(1, TargetAddr),
                       element(2, TargetAddr)}]
         end, 200)),
    %% The bootstrap TOFU exchange and every subsequent system-route send are
    %% scoped no-learn: the directory knows the route but the shared consensus
    %% address cache does not.
    ?assertEqual(
       error,
       peer:call(Joiner, quod_quic, resolve, [TargetPub])),
    ?assertEqual(
       error,
       peer:call(Target, quod_quic, resolve, [JoinerPub])),

    %% The joiner is a non-allowlisted reader: it never publishes or receives
    %% fanout through a self route. Drop its retained seed stream, then add a
    %% target namespace. Its common maintenance tick must reconnect pinned and
    %% resync the new public route without signing anything itself.
    [SeedLink] = peer:call(
                   Joiner, quod_directory_control, test_seed_links, []),
    ok = peer:call(Joiner, quod_link, close, [SeedLink]),
    ?assertEqual(
       ok,
       wait_until(
         fun() ->
             peer:call(
               Joiner, quod_directory_control, test_seed_links, []) =:= []
         end, 100)),
    timer:sleep(5100),
    _TargetAgentHost = host_namespace(Target, ?NS2),
    ok = peer:call(
           Target, quod_directory_control, namespace_changed, []),
    ?assertEqual(
       ok,
       wait_until(
         fun() ->
             peer:call(Target, quod_directory, directory_hosts, [?NS2])
                 =:= [{TargetPub, element(1, TargetAddr),
                       element(2, TargetAddr)}]
         end, 100)),
    ?assertEqual(
       unknown,
       peer:call(Joiner, quod_directory, resolve, [?NS2])),
    ?assertEqual(
       ok,
       wait_until(
         fun() ->
             peer:call(Joiner, quod_directory, directory_hosts, [?NS2])
                 =:= [{TargetPub, element(1, TargetAddr),
                       element(2, TargetAddr)}]
         end, 600)),
    JoinerStats = peer:call(
                    Joiner, quod_directory_control, stats, []),
    ?assertNot(maps:get(enabled, JoinerStats)),
    ?assertEqual(0, maps:get(sequence, JoinerStats)),
    ?assertEqual(
       error,
       peer:call(Joiner, quod_quic, resolve, [TargetPub])).

start_node(Name, {Host, Port}, {Pub, Seed} = KeyPair,
           Allowlist, Bootstraps, DirectoryServer, Config) ->
    {ok, Peer, _Node} = peer:start(
                          #{name => Name, connection => standard_io,
                            args => ["-pa" | code:get_path()]}),
    _ = peer:call(Peer, logger, set_primary_config, [level, warning]),
    _ = peer:call(Peer, application, load, [quod]),
    Set = fun(K, V) ->
                  ok = peer:call(
                         Peer, application, set_env, [quod, K, V])
          end,
    IdentityDir = filename:join(
                    ?config(priv_dir, Config),
                    atom_to_list(Name)),
    Set(listen_port, Port),
    Set(node_addr, {Host, Port}),
    Set(node_pubkey, Pub),
    Set(identity_key, quod_identity:key_term({Pub, Seed})),
    Set(identity_cert, quod_identity:mint_cert(KeyPair)),
    Directory0 = #{allowlist => Allowlist,
                   bootstraps => Bootstraps},
    Directory =
        case DirectoryServer of
            true -> Directory0#{identity_dir => IdentityDir};
            false -> Directory0
        end,
    Set(directory, Directory),
    {ok, _} = peer:call(
                Peer, application, ensure_all_started, [quod]),
    Peer.

host_namespace(Peer, Ns) ->
    Pid = peer:call(Peer, erlang, spawn, [?MODULE, hold_namespace, [Ns]]),
    ok = wait_until(
           fun() ->
               lists:member(
                 Ns, peer:call(Peer, quod_ns_sup, namespaces, []))
           end, 100),
    Pid.

hold_namespace(Ns) ->
    true = gproc:reg({n, l, {quod_ns, Ns}}),
    receive
        stop -> ok
    end.

wait_until(_Fun, 0) ->
    timeout;
wait_until(Fun, Retries) ->
    case Fun() of
        true -> ok;
        _ -> timer:sleep(25), wait_until(Fun, Retries - 1)
    end.

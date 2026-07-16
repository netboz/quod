-module(quod_ask_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([remote_stream/1, remote_symbol_safety/1, remote_cancel/1]).

-define(TARGET_PORT, 15970).
-define(ASKER_PORT, 15971).
-define(NS, <<"animals">>).
-define(ASKER_NS, <<"pets">>).

all() -> [remote_stream, remote_symbol_safety, remote_cancel].

init_per_suite(Config) ->
    TargetKey = quod_identity:generate(),
    AskerKey = quod_identity:generate(),
    TargetAddr = {"127.0.0.1", ?TARGET_PORT},
    AskerAddr = {"127.0.0.1", ?ASKER_PORT},
    Animals = filename:join(code:priv_dir(quod), "ontologies/animals.pl"),
    {ok, AnimalsBin} = file:read_file(Animals),
    TargetGenesis = filename:join(?config(priv_dir, Config), "remote_animals.pl"),
    ok = file:write_file(TargetGenesis, [AnimalsBin, "\necho(X).\nloop :- loop.\n"]),
    Target = start_node(target, ?TARGET_PORT, TargetKey, ?NS,
                        TargetGenesis, [], Config),
    start_brahms(Target, ?NS, TargetAddr, []),
    Asker = start_node(asker, ?ASKER_PORT, AskerKey, ?ASKER_NS,
                       filename:join(code:priv_dir(quod), "ontologies/pets.pl"),
                       [TargetAddr], Config),
    start_brahms(Asker, ?ASKER_NS, AskerAddr, [TargetAddr]),
    wait_ready(Target, ?NS, {diet, dog, kibble}),
    wait_ready(Asker, ?ASKER_NS, {instance_of, pet, my_dog}),
    [{target, Target}, {asker, Asker} | Config].

end_per_suite(Config) ->
    _ = [catch peer:stop(P) || P <- [?config(target, Config), ?config(asker, Config)]],
    ok.

remote_stream(Config) ->
    Asker = ?config(asker, Config),
    Goal = {'::', ?NS, {diet, dog, {'D'}}},
    ?assertMatch({ok, [#{'D' := {'$quod_symbol', <<"kibble">>}}], _},
                 peer:call(Asker, quod_prolog, prove, [?ASKER_NS, Goal, ?ASKER_NS], 60000)),
    All = {findall, {'D'}, Goal, {'L'}},
    ?assertMatch({ok, [#{'L' := [{'$quod_symbol', <<"kibble">>},
                                  {'$quod_symbol', <<"meat">>}]}], _},
                 peer:call(Asker, quod_prolog, prove, [?ASKER_NS, All, ?ASKER_NS], 60000)).

remote_symbol_safety(Config) ->
    Target = ?config(target, Config),
    Asker = ?config(asker, Config),
    Echo = {'::', ?NS, {echo, asker_only_symbol}},
    ?assertMatch({ok, [#{}], _},
                 peer:call(Asker, quod_prolog, prove,
                           [?ASKER_NS, Echo, ?ASKER_NS], 60000)),
    ?assertEqual({ok, {'$quod_symbol', <<"asker_only_symbol">>}},
                 peer:call(Target, quod_wire_term, decode,
                           [{0, <<"asker_only_symbol">>}])),
    Unknown = {'::', ?NS, {asker_only_predicate, x}},
    ?assertEqual(fail,
                 peer:call(Asker, quod_prolog, prove,
                           [?ASKER_NS, Unknown, ?ASKER_NS], 60000)).

remote_cancel(Config) ->
    Target = ?config(target, Config),
    Asker = ?config(asker, Config),
    Loop = {'::', ?NS, loop},
    Caller = peer:call(Asker, erlang, spawn,
                       [quod_prolog, prove, [?ASKER_NS, Loop, ?ASKER_NS]]),
    wait_ask_workers(Target, 1, 200),
    true = peer:call(Asker, erlang, exit, [Caller, kill]),
    wait_ask_workers(Target, 0, 200).

start_node(Name, Port, {Pub, Seed}, Ns, Genesis, Seeds, Config) ->
    {ok, Peer, _Node} = peer:start(
                          #{name => Name, connection => standard_io,
                            args => ["-pa" | code:get_path()]}),
    _ = peer:call(Peer, logger, set_primary_config, [level, warning]),
    _ = peer:call(Peer, application, load, [quod]),
    Key = quod_identity:key_term({Pub, Seed}),
    Set = fun(K, V) -> ok = peer:call(Peer, application, set_env, [quod, K, V]) end,
    Set(listen_port, Port),
    Set(node_addr, {"127.0.0.1", Port}),
    Set(node_pubkey, Pub),
    Set(identity_key, Key),
    Set(identity_cert, quod_identity:mint_cert({Pub, Seed})),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [quod]),
    DataDir = filename:join(?config(priv_dir, Config), atom_to_list(Name)),
    Cfg = #{node_id => Pub, mode => create, role => member,
            data_dir => DataDir, seed_peers => Seeds,
            genesis_file => Genesis},
    {ok, _} = peer:call(Peer, quod_ns_sup, start_namespace, [Ns, Cfg]),
    Peer.

start_brahms(Peer, Ns, SelfAddr, Seeds) ->
    {ok, _} = peer:call(Peer, quod_brahms, start_namespace,
                        [Ns, #{node_id => SelfAddr, seed_peers => Seeds}]),
    ok.

wait_ready(Peer, Ns, Goal) ->
    case peer:call(Peer, quod_prolog, prove, [Ns, Goal, Ns], 5000) of
        {error, rebuilding} -> timer:sleep(20), wait_ready(Peer, Ns, Goal);
        {ok, _, _} -> ok;
        Other -> ct:fail({not_ready, Ns, Other})
    end.

wait_ask_workers(_Peer, _Expected, 0) -> ct:fail(ask_worker_timeout);
wait_ask_workers(Peer, Expected, Retries) ->
    Stats = peer:call(Peer, quod_prolog, stats, [?NS]),
    case maps:get(ask_workers, Stats, undefined) of
        Expected -> ok;
        _ -> timer:sleep(10), wait_ask_workers(Peer, Expected, Retries - 1)
    end.

-module(quod_ask_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([remote_stream/1, remote_symbol_safety/1, remote_peer_acl/1,
         remote_failure_reasons/1, remote_deep_failure_reasons/1,
         remote_structural_reason_truncation/1,
         remote_cancel/1, remote_return_stream_reuse/1]).
-export([run_remote_proofs/3]).

-define(TARGET_PORT, 15970).
-define(ASKER_PORT, 15971).
-define(NS, <<"animals">>).
-define(ASKER_NS, <<"pets">>).
-define(PRIVATE_NS, <<"private">>).

all() -> [remote_stream, remote_symbol_safety, remote_peer_acl,
          remote_failure_reasons, remote_deep_failure_reasons,
          remote_structural_reason_truncation,
          remote_cancel, remote_return_stream_reuse].

init_per_suite(Config) ->
    {TargetPub, _} = TargetKey = quod_identity:generate(),
    {WrongPub, _} = wrong_key_before(TargetPub),
    AskerKey = quod_identity:generate(),
    TargetAddr = {"127.0.0.1", ?TARGET_PORT},
    AskerAddr = {"127.0.0.1", ?ASKER_PORT},
    Animals = filename:join(code:priv_dir(quod), "ontologies/animals.pl"),
    {ok, AnimalsBin} = file:read_file(Animals),
    TargetGenesis = filename:join(?config(priv_dir, Config), "remote_animals.pl"),
    ok = file:write_file(
           TargetGenesis,
           [AnimalsBin,
            "\necho(X).\n"
            "blocked(X) :- fail_with_reason(impossible_to_link(X)).\n",
            deep_failure_rules(),
            "loop :- loop.\n"]),
    Target = start_node(target, ?TARGET_PORT, TargetKey, ?NS,
                        TargetGenesis, [], #{}, Config),
    PrivateGenesis = filename:join(?config(priv_dir, Config), "remote_private.pl"),
    ok = file:write_file(
           PrivateGenesis,
           ["can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).\n",
            "secret(42).\n"]),
    start_namespace(Target, TargetPub, ?PRIVATE_NS, PrivateGenesis, [], Config),
    start_brahms(Target, ?NS, TargetAddr, []),
    DirectoryAllow = #{?NS => [WrongPub, TargetPub]},
    Asker = start_node(asker, ?ASKER_PORT, AskerKey, ?ASKER_NS,
                       filename:join(code:priv_dir(quod), "ontologies/pets.pl"),
                       [TargetAddr], DirectoryAllow, Config),
    %% A lower-sorting route points at a valid server with the WRONG certificate:
    %% the pinned dial must reject it and advance to the real route.
    {ok, _} = peer:call(
                Asker, quod_directory, install_record,
                [WrongPub, TargetAddr, [?NS], 1, 1]),
    {ok, _} = peer:call(
                Asker, quod_directory, install_record,
                [TargetPub, TargetAddr, [?NS], 1, 1]),
    %% The private ontology is reachable only through an explicit local seed.
    ok = peer:call(
           Asker, quod_directory, add_direct_seed,
           [?PRIVATE_NS, TargetAddr]),
    start_brahms(Asker, ?ASKER_NS, AskerAddr, [TargetAddr]),
    wait_ready(Target, ?NS, {diet, dog, kibble}),
    wait_ready(Target, ?PRIVATE_NS, {secret, 42}),
    wait_ready(Asker, ?ASKER_NS, {instance_of, pet, my_dog}),
    %% Authorize the ontology name only. A remote request must additionally pass
    %% can_read for the TLS-authenticated node key, which this policy omits.
    ACL = {assertz, {can_read, {secret, {'X'}}, ?ASKER_NS, ?PRIVATE_NS}},
    ?assertMatch({ok, [_], _},
                 peer:call(Target, quod_prolog, prove,
                           [?PRIVATE_NS, ACL, ?PRIVATE_NS], 60000)),
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
    ?assertMatch({fail, [_ | _]},
                 peer:call(Asker, quod_prolog, prove,
                           [?ASKER_NS, Unknown, ?ASKER_NS], 60000)).

remote_peer_acl(Config) ->
    Asker = ?config(asker, Config),
    Goal = {'::', ?PRIVATE_NS, {secret, {'X'}}},
    ?assertEqual({error, not_allowed},
                 peer:call(Asker, quod_prolog, prove,
                           [?ASKER_NS, Goal, ?ASKER_NS], 60000)),
    {known, [Route]} = peer:call(
                         Asker, quod_directory, resolve, [?PRIVATE_NS]),
    ?assertEqual(direct, maps:get(scope, Route)),
    ?assertEqual(confirmed, maps:get(status, Route)),
    ?assertEqual([], peer:call(
                       Asker, quod_directory, directory_hosts,
                       [?PRIVATE_NS])).

remote_failure_reasons(Config) ->
    Asker = ?config(asker, Config),
    Remote = {'::', ?NS, {blocked, bob}},
    Recover = {';', Remote,
               {get_fail_reasons,
                [{'Outer'}, {blocked, bob}, {impossible_to_link, bob}]}},
    ?assertMatch(
       {ok, [#{'Outer' := Remote}], _},
       peer:call(Asker, quod_prolog, prove,
                 [?ASKER_NS, Recover, ?ASKER_NS], 60000)).

remote_deep_failure_reasons(Config) ->
    Asker = ?config(asker, Config),
    Remote = {'::', ?NS, {deep_failure, 70}},
    {fail, Reasons} = peer:call(
                        Asker, quod_prolog, prove,
                        [?ASKER_NS, Remote, ?ASKER_NS], 60000),
    ?assert(length(Reasons) > 64),
    ?assertEqual(Remote, hd(Reasons)),
    ?assertEqual({'$quod_symbol', <<"deep_bottom">>}, lists:last(Reasons)).

remote_structural_reason_truncation(Config) ->
    Asker = ?config(asker, Config),
    Remote = {'::', ?NS, deep_reason},
    ?assertEqual(
       {fail, [Remote, fail_reasons_truncated]},
       peer:call(Asker, quod_prolog, prove,
                 [?ASKER_NS, Remote, ?ASKER_NS], 60000)).

remote_cancel(Config) ->
    Target = ?config(target, Config),
    Asker = ?config(asker, Config),
    Loop = {'::', ?NS, loop},
    Caller = peer:call(Asker, erlang, spawn,
                       [quod_prolog, prove, [?ASKER_NS, Loop, ?ASKER_NS]]),
    wait_ask_workers(Target, 1, 200),
    true = peer:call(Asker, erlang, exit, [Caller, kill]),
    wait_ask_workers(Target, 0, 200).

%% A return stream belongs to the asking NODE, not one proof.  Two waves cross
%% the old per-proof QUIC stream ceiling while each result remains attributable
%% to its ask id through the return router.
remote_return_stream_reuse(Config) ->
    Target = ?config(target, Config),
    Asker = ?config(asker, Config),
    Goal = {'::', ?NS, {diet, dog, kibble}},
    run_remote_wave(Asker, Goal, first),
    wait_ask_workers(Target, 0, 200),
    run_remote_wave(Asker, Goal, second),
    wait_ask_workers(Target, 0, 200).

run_remote_wave(Asker, Goal, Wave) ->
    Results = peer:call(Asker, ?MODULE, run_remote_proofs, [?ASKER_NS, Goal, 64]),
    case Results of
        List when is_list(List), length(List) =:= 64 ->
            lists:foreach(
              fun({ok, [_], _}) -> ok;
                 (Result) -> ct:fail({remote_proof_failed, Wave, Result})
              end, List);
        timeout -> ct:fail({remote_proof_timeout, Wave});
        Other -> ct:fail({remote_proof_wave_failed, Wave, Other})
    end.

run_remote_proofs(Ns, Goal, Count) ->
    Parent = self(),
    _ = [spawn(fun() -> Parent ! {proof_done, quod_prolog:prove(Ns, Goal, Ns)} end)
         || _ <- lists:seq(1, Count)],
    collect_remote_proofs(Count, []).

collect_remote_proofs(0, Results) -> lists:reverse(Results);
collect_remote_proofs(Count, Results) ->
    receive
        {proof_done, Result} -> collect_remote_proofs(Count - 1, [Result | Results])
    after 10000 ->
        timeout
    end.

start_node(Name, Port, {Pub, Seed}, Ns, Genesis, Seeds,
           DirectoryAllowlist, Config) ->
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
    Set(directory, #{allowlist => DirectoryAllowlist}),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [quod]),
    start_namespace(Peer, Pub, Ns, Genesis, Seeds, Config),
    Peer.

start_namespace(Peer, Pub, Ns, Genesis, Seeds, Config) ->
    DataDir = filename:join(
                ?config(priv_dir, Config),
                unicode:characters_to_list(
                  [atom_to_list(peer:call(Peer, erlang, node, [])),
                   "_", Ns])),
    Cfg = #{node_id => Pub, mode => create, role => member,
            data_dir => DataDir, seed_peers => Seeds,
            genesis_file => Genesis},
    {ok, _} = peer:call(Peer, quod_ns_sup, start_namespace, [Ns, Cfg]),
    ok.

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

wrong_key_before(TargetPub) ->
    {Pub, _} = Key = quod_identity:generate(),
    case Pub < TargetPub of
        true -> Key;
        false -> wrong_key_before(TargetPub)
    end.

deep_failure_rules() ->
    DeepReason = lists:foldl(fun(_, Term) -> [Term] end,
                             deep_bottom, lists:seq(1, 70)),
    [[io_lib:format("deep_failure(~B) :- deep_failure(~B).~n", [N, N - 1])
      || N <- lists:seq(70, 1, -1)],
     "deep_failure(0) :- fail_with_reason(deep_bottom).\n",
     io_lib:format("deep_reason :- fail_with_reason(~p).~n", [DeepReason])].

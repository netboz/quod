-module(quod_names_SUITE).

%% `quod:names` on real nodes. The target peer hosts quod:names, quod:root
%% and a small agent ontology; the asker peer hosts only its own ontology and
%% reaches quod:names through an ordinary directory route (the non-hosting
%% remote case). Every draw here runs the real '$quod_draw'/3 inside the real
%% proof machinery: origin worker, co-hosted scope, remote scope.

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([remote_completion_of_deep_proof/1,
         cohosted_draw_labels_an_agent/1,
         remote_draw_from_non_hosting_node/1,
         public_queries_open_mutation_refused/1,
         backtracking_cut_and_savepoint/1,
         restart_recovery/1]).

-define(TARGET_PORT, 15990).
-define(ASKER_PORT, 15991).
-define(ROOT_NS, <<"quod:root">>).
-define(NAMES_NS, <<"quod:names">>).
-define(AGENT_NS, <<"naming-agent">>).
-define(ASKER_NS, <<"naming-asker">>).
-define(NAMES, {':', quod, names}).

all() -> [remote_completion_of_deep_proof,
          cohosted_draw_labels_an_agent,
          remote_draw_from_non_hosting_node,
          public_queries_open_mutation_refused,
          backtracking_cut_and_savepoint,
          restart_recovery].

init_per_suite(Config) ->
    {TargetPub, _} = TargetKey = quod_identity:generate(),
    {AskerPub, _} = AskerKey = quod_identity:generate(),
    TargetAddr = {"127.0.0.1", ?TARGET_PORT},
    AskerAddr = {"127.0.0.1", ?ASKER_PORT},
    Names = filename:join(code:priv_dir(quod), "ontologies/quod_names.pl"),
    AgentGenesis = filename:join(?config(priv_dir, Config), "naming_agent.pl"),
    ok = file:write_file(
           AgentGenesis,
           ["can_invoke(_Goal, _Principal, _CallChain, _Ns).\n"
            "can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).\n"
            "label_me(Salt, Name) :- quod:names::draw(Salt, Name).\n"]),
    AskerGenesis = filename:join(?config(priv_dir, Config), "naming_asker.pl"),
    ok = file:write_file(
           AskerGenesis,
           ["can_invoke(_Goal, _Principal, _CallChain, _Ns).\n"
            "can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).\n"
            "remote_label(Salt, Name) :- quod:names::draw(Salt, Name).\n"]),
    Target = start_node(names_target, ?TARGET_PORT, TargetKey, Config),
    start_root_namespace(Target, TargetPub, Config),
    start_namespace(Target, TargetPub, ?NAMES_NS, Names, Config),
    start_namespace(Target, TargetPub, ?AGENT_NS, AgentGenesis, Config),
    Asker = start_node(names_asker, ?ASKER_PORT, AskerKey, Config),
    start_namespace(Asker, AskerPub, ?ASKER_NS, AskerGenesis, Config),
    RootAnchor = peer:call(Target, quod_simplex, genesis_hash, [?ROOT_NS]),
    NamesAnchor = peer:call(Target, quod_simplex, genesis_hash, [?NAMES_NS]),
    lists:foreach(fun(Peer) -> set_network_identity(Peer, RootAnchor) end,
                  [Target, Asker]),
    ok = wait_ready(Target, ?NAMES_NS, {count, halfling, personal, male, {'_'}}),
    ok = wait_ready(Target, ?AGENT_NS, true),
    ok = wait_ready(Asker, ?ASKER_NS, true),
    ok = peer:call(Asker, quod_quic, learn, [TargetPub, TargetAddr]),
    {ok, _} = peer:call(
                Asker, quod_ct, install_directory_generation,
                [TargetPub, TargetAddr,
                 [{?NAMES_NS, NamesAnchor, validator},
                  {?ROOT_NS, RootAnchor, validator}], 1, 1]),
    [{target, Target}, {asker, Asker}, {target_pub, TargetPub},
     {asker_addr, AskerAddr}, {names_anchor, NamesAnchor} | Config].

end_per_suite(Config) ->
    quod_ct:stop_all([?config(target, Config), ?config(asker, Config)]).

%% Exhausting a remote draw sends the target's bounded failure stack back
%% with the completion. The asker knows none of quod:names' predicate names,
%% so every reason arrives as opaque symbols; a stack the target filled to
%% the wire cap must still be accepted here (quod_ask checked_completion).
remote_completion_of_deep_proof(Config) ->
    Asker = ?config(asker, Config),
    lists:foreach(
      fun(Salt) ->
              Result = quod_ct:peer_prove(
                         Asker, ?ASKER_NS,
                         {findall, {'N'},
                          {';', {'::', ?NAMES, {draw, {deep, Salt}, {'N'}}}, true},
                          {'L'}}),
              ?assertMatch({ok, [#{'L' := [Name, _]}], _} when is_binary(Name),
                           Result, {salt, Salt})
      end, lists:seq(1, 40)).

%% An ontology on the same node asks quod:names inside a write and keeps the
%% answer as an ordinary fact; quod:names itself stays untouched.
cohosted_draw_labels_an_agent(Config) ->
    Target = ?config(target, Config),
    Before = count(Target, ?NAMES_NS),
    Goal = {',', {label_me, {agent, 1}, {'N'}},
            {assertz, {attribute, me, display_name, {'N'}}}},
    {ok, [#{'N' := Label}], _} = execute(Target, ?AGENT_NS, Goal),
    ?assert(is_binary(Label)),
    ?assertNotEqual([], classes(Target, ?NAMES_NS, Label)),
    ?assertMatch({ok, [#{'L' := Label}], _},
                 quod_ct:peer_prove(Target, ?AGENT_NS,
                                    {attribute, me, display_name, {'L'}})),
    %% Another proof is another draw: still a name, kept as its own label.
    {ok, [#{'N' := Other}], _} =
        execute(Target, ?AGENT_NS,
                {',', {label_me, {agent, 1}, {'N'}},
                 {assertz, {attribute, other, display_name, {'N'}}}}),
    ?assertNotEqual([], classes(Target, ?NAMES_NS, Other)),
    ?assertEqual(Before, count(Target, ?NAMES_NS)),
    ?assertMatch({fail, _},
                 quod_ct:peer_prove(Target, ?NAMES_NS,
                                    {attribute, {'_'}, {'_'}, {'_'}})).

%% The asker hosts nothing of quod:names; its draws travel to the target and
%% are answered by the real scope there, with the asker's proof identity.
remote_draw_from_non_hosting_node(Config) ->
    Asker = ?config(asker, Config),
    Target = ?config(target, Config),
    ?assertEqual(undefined,
                 peer:call(Asker, quod_reg, where, [{quod_prolog, ?NAMES_NS}])),
    Started = erlang:monotonic_time(millisecond),
    {ok, [#{'N' := Name}], _} =
        quod_ct:peer_prove(Asker, ?ASKER_NS, {remote_label, s1, {'N'}}),
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    ct:pal("remote draw from non-hosting node: ~p ms -> ~p", [Elapsed, Name]),
    ?assert(is_binary(Name)),
    ?assertNotEqual([], classes(Target, ?NAMES_NS, Name)),
    %% The same question twice in one proof is one answer; a selection stays
    %% inside its pools; counts and recognition cross the wire too.
    ?assertMatch({ok, [#{'L' := [Same, Same]}], _},
                 quod_ct:peer_prove(
                   Asker, ?ASKER_NS,
                   {findall, {'N'},
                    {';', {remote_label, s2, {'N'}}, {remote_label, s2, {'N'}}},
                    {'L'}})),
    {ok, [#{'N' := Elf}], _} =
        quod_ct:peer_prove(Asker, ?ASKER_NS,
                           {'::', ?NAMES, {draw, elf, personal, female, s3, {'N'}}}),
    ?assert(lists:member(elf_female, classes(Target, ?NAMES_NS, Elf))),
    ?assertMatch({ok, [#{'C' := 384}], _},
                 quod_ct:peer_prove(
                   Asker, ?ASKER_NS,
                   {'::', ?NAMES, {count, halfling, personal, male, {'C'}}})),
    %% The asker never loaded quod:names, so its pool names arrive as opaque
    %% symbols rather than freshly allocated atoms.
    ?assertMatch({ok, [#{'L' := [{'$quod_symbol', <<"orc_male">>}]}], _},
                 quod_ct:peer_prove(
                   Asker, ?ASKER_NS,
                   {findall, {'K'}, {'::', ?NAMES, {name, {'K'}, <<"Ugbash">>}},
                    {'L'}})),
    Timings = [begin
                   T0 = erlang:monotonic_time(millisecond),
                   {ok, [#{'N' := _}], _} =
                       quod_ct:peer_prove(Asker, ?ASKER_NS,
                                          {remote_label, {t, I}, {'N'}}),
                   erlang:monotonic_time(millisecond) - T0
               end || I <- lists:seq(1, 5)],
    ct:pal("remote draw latencies (ms): ~p", [Timings]).

%% Anyone may ask; nobody but an admitted node may change the tables.
public_queries_open_mutation_refused(Config) ->
    Asker = ?config(asker, Config),
    Target = ?config(target, Config),
    Before = count(Target, ?NAMES_NS),
    Refused = fun(Inner) ->
                      Result = quod_ct:peer_prove(
                                 Asker, ?ASKER_NS, {'::', ?NAMES, Inner}),
                      ?assertNotMatch({ok, _, _}, Result),
                      Result
              end,
    Refused({assertz, {vile_medium, zzz}}),
    Refused({',', {name, {'N'}, orc, personal, male},
             {assertz, {vile_medium, zzz}}}),
    Refused({retract, {name_class, orc_male, orc, personal, male}}),
    Refused({assertz, {naming_query, {assertz, {'_'}}}}),
    ?assertEqual(Before, count(Target, ?NAMES_NS)),
    ?assertMatch({fail, _},
                 quod_ct:peer_prove(Target, ?NAMES_NS, {vile_medium, zzz})),
    ?assertMatch({ok, [#{'N' := _}], _},
                 quod_ct:peer_prove(
                   Asker, ?ASKER_NS,
                   {'::', ?NAMES, {name_nth, orc, personal, male, 0, {'N'}}})).

%% Backtracking re-asks and re-hears the same answer; a cut keeps it; a
%% rolled-back candidate that drew changes nothing for the draw after it.
backtracking_cut_and_savepoint(Config) ->
    Target = ?config(target, Config),
    ?assertMatch({ok, [#{'L' := [A, B, A]}], _} when A =/= B,
                 execute(Target, ?AGENT_NS,
                         {findall, {'N'},
                          {',', {member, {'S'}, [a, b, a]},
                           {label_me, {'S'}, {'N'}}}, {'L'}})),
    ?assertMatch({ok, [#{'L' := [_]}], _},
                 execute(Target, ?AGENT_NS,
                         {findall, {'N'},
                          {',', {member, {'S'}, [a, b]},
                           {',', {label_me, {'S'}, {'N'}}, '!'}}, {'L'}})),
    Goal = {',', {label_me, a, {'N1'}},
            {',', {';', {transaction,
                         {',', {assertz, {rolled, {'N1'}}}, fail}},
                   true},
             {',', {label_me, a, {'N2'}},
              {',', {'==', {'N1'}, {'N2'}},
               {assertz, {kept, {'N2'}}}}}}},
    {ok, [#{'N1' := N, 'N2' := N}], _} = execute(Target, ?AGENT_NS, Goal),
    ?assertMatch({fail, _},
                 quod_ct:peer_prove(Target, ?AGENT_NS, {rolled, {'_'}})),
    ?assertMatch({ok, [#{}], _},
                 quod_ct:peer_prove(Target, ?AGENT_NS, {kept, N})).

%% quod:names comes back after its engine dies, on the host and for the
%% remote asker alike.
restart_recovery(Config) ->
    Target = ?config(target, Config),
    Asker = ?config(asker, Config),
    OldSimplex = peer:call(Target, quod_reg, where, [{quod_simplex, ?NAMES_NS}]),
    OldEngine = peer:call(Target, quod_reg, where, [{quod_prolog, ?NAMES_NS}]),
    ?assert(is_pid(OldSimplex) andalso is_pid(OldEngine)),
    true = peer:call(Target, erlang, exit, [OldEngine, kill]),
    true = peer:call(Target, erlang, exit, [OldSimplex, kill]),
    ok = wait_restarted(Target, ?NAMES_NS, OldSimplex, 400),
    ok = wait_ready(Target, ?NAMES_NS, {count, halfling, personal, male, {'_'}}),
    ?assertEqual(?config(names_anchor, Config),
                 peer:call(Target, quod_simplex, genesis_hash, [?NAMES_NS])),
    {ok, [#{'N' := Local}], _} =
        execute(Target, ?AGENT_NS, {label_me, after_restart, {'N'}}),
    ?assertNotEqual([], classes(Target, ?NAMES_NS, Local)),
    ?assert(quod_ct:eventually(
              fun() ->
                      case quod_ct:peer_prove(Asker, ?ASKER_NS,
                                              {remote_label, after_restart, {'N'}}) of
                          {ok, [#{'N' := Remote}], _} -> is_binary(Remote);
                          _ -> false
                      end
              end, 30000)).

%% --- helpers ---------------------------------------------------------------

execute(Peer, Ns, Goal) ->
    peer:call(Peer, quod_prolog, execute, [Ns, Goal], 60000).

count(Peer, Ns) ->
    {ok, [#{'C' := C}], _} =
        quod_ct:peer_prove(Peer, Ns, {count, {'_'}, {'_'}, {'_'}, {'C'}}),
    C.

classes(Peer, Ns, Name) ->
    {ok, [#{'L' := L}], _} =
        quod_ct:peer_prove(Peer, Ns, {findall, {'K'}, {name, {'K'}, Name}, {'L'}}),
    L.

start_node(Name, Port, {Pub, Seed}, Config) ->
    %% Peer nodes must load the beam being tested (see quod_ask_SUITE).
    QuodEbin = filename:dirname(code:which(quod_simplex)),
    PeerPaths = [QuodEbin | lists:delete(QuodEbin, code:get_path())],
    {ok, Peer, _Node} = peer:start(
                          #{name => Name, connection => standard_io,
                            args => ["-pa" | PeerPaths]}),
    CacheDir = filename:join(?config(priv_dir, Config),
                             atom_to_list(Name) ++ "_cache"),
    true = peer:call(Peer, os, putenv, ["XDG_CACHE_HOME", CacheDir]),
    _ = peer:call(Peer, logger, set_primary_config, [level, warning]),
    _ = peer:call(Peer, application, load, [quod]),
    Set = fun(K, V) -> ok = peer:call(Peer, application, set_env, [quod, K, V]) end,
    Set(listen_port, Port),
    Set(node_addr, {"127.0.0.1", Port}),
    Set(node_pubkey, Pub),
    Set(identity_key, quod_identity:key_term({Pub, Seed})),
    Set(identity_cert, quod_identity:mint_cert({Pub, Seed})),
    Set(effect_journal_data_dir,
        filename:join(?config(priv_dir, Config),
                      atom_to_list(Name) ++ "_effect_journal")),
    Set(foreign_log,
        #{cache_dir => filename:join(?config(priv_dir, Config),
                                     atom_to_list(Name) ++ "_foreign_log")}),
    Set(directory, #{ttl_ms => 600000, expire_tick_ms => 60000}),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [quod]),
    Peer.

start_namespace(Peer, Pub, Ns, Genesis, Config) ->
    DataDir = filename:join(
                ?config(priv_dir, Config),
                unicode:characters_to_list(
                  [atom_to_list(peer:call(Peer, erlang, node, [])), "_", Ns])),
    Cfg = #{node_id => Pub, mode => create, role => member,
            data_dir => DataDir, seed_peers => [], genesis_file => Genesis},
    {ok, _} = peer:call(Peer, quod_ns_sup, start_namespace, [Ns, Cfg]),
    ok.

start_root_namespace(Peer, Pub, Config) ->
    DataDir = filename:join(
                ?config(priv_dir, Config),
                unicode:characters_to_list(
                  [atom_to_list(peer:call(Peer, erlang, node, [])), "_", ?ROOT_NS])),
    Content = #{namespace => ?ROOT_NS, mode => create,
                genesis_file => <<"ontologies/quod_root.pl">>,
                data_dir => list_to_binary(DataDir), seeds => []},
    {?ROOT_NS, Cfg0} = peer:call(Peer, quod_app, build_ns_config, [Content]),
    {ok, _} = peer:call(Peer, quod_ns_sup, start_namespace,
                        [?ROOT_NS, Cfg0#{node_id => Pub}]),
    ok.

set_network_identity(Peer, NetworkId) ->
    Desired = peer:call(Peer, application, get_env,
                        [quod, namespace_desired, #{}]),
    Content = maps:get(content, Desired, #{}),
    ok = peer:call(Peer, application, set_env,
                   [quod, namespace_desired,
                    Desired#{content => Content#{
                      quod_ontology:root_ns() => #{genesis_hash => NetworkId}}}]).

wait_ready(Peer, Ns, Goal) -> wait_ready(Peer, Ns, Goal, 750).

wait_ready(_Peer, Ns, _Goal, 0) -> ct:fail({ontology_never_ready, Ns});
wait_ready(Peer, Ns, Goal, Retries) ->
    case peer:call(Peer, quod_prolog, prove, [Ns, Goal], 5000) of
        {ok, _, _} -> ok;
        {error, rebuilding} -> timer:sleep(20), wait_ready(Peer, Ns, Goal, Retries - 1);
        {error, no_such_namespace} -> timer:sleep(20), wait_ready(Peer, Ns, Goal, Retries - 1);
        Other -> ct:fail({not_ready, Ns, Other})
    end.

wait_restarted(_Peer, _Ns, _OldSimplex, 0) -> ct:fail(namespace_did_not_restart);
wait_restarted(Peer, Ns, OldSimplex, Retries) ->
    Simplex = peer:call(Peer, quod_reg, where, [{quod_simplex, Ns}]),
    Prolog = peer:call(Peer, quod_reg, where, [{quod_prolog, Ns}]),
    case is_pid(Simplex) andalso Simplex =/= OldSimplex andalso is_pid(Prolog) of
        true -> ok;
        false -> timer:sleep(25), wait_restarted(Peer, Ns, OldSimplex, Retries - 1)
    end.

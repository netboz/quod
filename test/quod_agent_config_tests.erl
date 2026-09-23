-module(quod_agent_config_tests).
-include_lib("eunit/include/eunit.hrl").

accepted_capacity_boundaries_test_() ->
    [?_assertEqual(Value, maps:get(Key, maps:get(node, checked(#{Key => Value}))))
     || {Key, Value} <- [{runtime_max_hosted_agents, 0},
                        {runtime_max_hosted_agents, 1024},
                        {runtime_max_agent_observations, 1},
                        {runtime_max_agent_observation_bytes, 1},
                        {peer_observation_limit, 1}]].

invalid_capacity_values_test_() ->
    Invalid = [{Key, Value} || Key <- keys(), Value <- [-1, false, 1.5, <<"invalid">>]] ++
              [{runtime_max_hosted_agents, 2048}] ++
              [{Key, 0} || Key <- keys() -- [runtime_max_hosted_agents]],
    [?_assertException(throw, {quod_schema, _}, checked(#{Key => Value}))
     || {Key, Value} <- Invalid].

%% The node policy reaches existing consumers, including runtimes created
%% after boot, without becoming part of an ontology's persisted configuration.
file_and_environment_limits_reach_consumers_test() ->
    with_boot(fun(Dir, Path) ->
        write_conf(Dir, Path,
          "node { runtime_max_hosted_agents = 7, runtime_max_agent_observations = 9, "
          "runtime_max_agent_observation_bytes = 8192, peer_observation_limit = 11 }\n"),
        os:putenv("QUOD_NODE__RUNTIME_MAX_HOSTED_AGENTS", "0"),
        Blocks = quod_app:load_config(),
        ?assertEqual([0, 9, 8192, 11], env_values()),
        ?assert(lists:all(fun(Block) -> maps:with(keys(), Block) =:= #{} end, Blocks)),
        Resumed = quod_ontology:local_resume_config(
                    <<"capacity:dynamic-resume">>, crypto:strong_rand_bytes(32), Dir),
        ?assertEqual(#{}, maps:with(keys(), Resumed)),
        %% Reloading defaults replaces prior process environment tuning.
        os:unsetenv("QUOD_NODE__RUNTIME_MAX_HOSTED_AGENTS"),
        write_conf(Dir, Path, ""),
        _ = quod_app:load_config(),
        ?assertEqual([1024, 4096, 1048576, 4096], env_values())
    end).

configuration_free_limits_use_same_schema_test() ->
    with_boot(fun(Dir, _Path) ->
        ?assertEqual(none, quod_app:load_config()),
        ?assertEqual([1024, 4096, 1048576, 4096], env_values()),
        _ = [application:set_env(quod, Key, Value)
             || {Key, Value} <- lists:zip(keys(), [0, 1, 1, 1])],
        ?assertEqual(none, quod_app:load_config()),
        ?assertEqual([0, 1, 1, 1], env_values()),
        ?assertEqual(undefined, application:get_env(quod, node_pubkey)),
        ?assertNot(filelib:is_regular(filename:join([Dir, "identity", "node.key"])))
    end).

%% Validation happens before identity creation and before changing any
%% application setting, for both supported sources of node configuration.
invalid_limits_refused_before_boot_side_effects_test_() ->
    [{atom_to_list(Source) ++ ":" ++ atom_to_list(Key), fun() ->
        with_boot(fun(Dir, Path) ->
            case Source of
                file ->
                    write_conf(Dir, Path, io_lib:format("node.~s = ~p\n", [Key, Value]));
                env -> application:set_env(quod, Key, Value)
            end,
            Before = lists:sort(application:get_all_env(quod)),
            ?assertException(throw, {quod_schema, _}, quod_app:load_config()),
            ?assertEqual(Before, lists:sort(application:get_all_env(quod))),
            ?assertNot(filelib:is_regular(filename:join([Dir, "identity", "node.key"])))
        end)
    end} || Source <- [file, env],
            {Key, Value} <- [{runtime_max_hosted_agents, 2048},
                             {runtime_max_agent_observations, 0},
                             {runtime_max_agent_observation_bytes, -1},
                             {peer_observation_limit, false}]].

checked(Node) ->
    Raw = #{<<"node">> => maps:from_list([{atom_to_binary(K), V}
                                         || {K, V} <- maps:to_list(Node)])},
    hocon_tconf:check_plain(quod_schema, Raw,
                            #{atom_key => true, apply_override_envs => false}).

keys() ->
    [runtime_max_hosted_agents, runtime_max_agent_observations,
     runtime_max_agent_observation_bytes, peer_observation_limit].

env_values() -> [application:get_env(quod, Key, missing) || Key <- keys()].

with_boot(Fun) ->
    _ = application:load(quod),
    Saved = application:get_all_env(quod),
    Names = ["QUOD_CONF", "HOCON_ENV_OVERRIDE_PREFIX"] ++
            ["QUOD_NODE__" ++ string:uppercase(atom_to_list(Key)) || Key <- keys()],
    Os = [{Name, os:getenv(Name)} || Name <- Names],
    Dir = filename:join("/tmp", "quod_agent_config_" ++
                        binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    Path = filename:join(Dir, "quod.conf"),
    try
        ok = file:make_dir(Dir),
        _ = [os:unsetenv(Name) || Name <- Names],
        os:putenv("QUOD_CONF", Path),
        _ = [application:unset_env(quod, Key) || Key <- keys() ++ [node_pubkey]],
        Fun(Dir, Path)
    after
        SavedKeys = [Key || {Key, _} <- Saved],
        _ = [application:unset_env(quod, Key) || {Key, _} <- application:get_all_env(quod),
              not lists:member(Key, SavedKeys)],
        _ = [application:set_env(quod, Key, Value) || {Key, Value} <- Saved,
              application:get_env(quod, Key) =/= {ok, Value}],
        _ = [case Value of false -> os:unsetenv(Name); _ -> os:putenv(Name, Value) end
             || {Name, Value} <- Os],
        _ = file:del_dir_r(Dir)
    end.

write_conf(Dir, Path, NodeConfig) ->
    ok = file:write_file(Path,
      [NodeConfig, "content = [{ namespace = \"capacity:boot\", data_dir = \"",
       Dir, "\" }]\n"]).

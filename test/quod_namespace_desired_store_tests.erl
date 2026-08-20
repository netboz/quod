-module(quod_namespace_desired_store_tests).

-include_lib("eunit/include/eunit.hrl").

roundtrip_and_strip_creation_payload_test() ->
    with_store(
      fun(_Path) ->
          Ns = <<"user:durable">>,
          Anchor = crypto:strong_rand_bytes(32),
          Config0 = #{mode => create,
                      node_id => crypto:strong_rand_bytes(32),
                      data_dir => "/tmp/quod-store-test",
                      prepared_genesis_entry => private_entry,
                      genesis_diff => [{assert, private_fact}]},
          Config = quod_namespace_desired_store:resume_config(
                     Config0, Anchor),
          ?assertNot(maps:is_key(prepared_genesis_entry, Config)),
          ?assertNot(maps:is_key(genesis_diff, Config)),
          ?assertEqual(Anchor, maps:get(genesis_hash, Config)),
          ok = quod_namespace_desired_store:store(#{Ns => Config}),
          ?assertEqual(#{Ns => Config},
                       quod_namespace_desired_store:load())
      end).

corrupt_snapshot_fails_loudly_test() ->
    with_store(
      fun(Path) ->
          ok = filelib:ensure_dir(Path),
          ok = file:write_file(Path, <<"not a desired-state snapshot">>),
          ?assertError(namespace_desired_corrupt,
                       quod_namespace_desired_store:load())
      end).

with_store(Fun) ->
    Saved = application:get_env(quod, namespace_desired_path),
    Dir = filename:join(
            "/tmp", "quod_namespace_desired_" ++
            integer_to_list(erlang:unique_integer([positive]))),
    Path = filename:join(Dir, "hosted_namespaces.qnd"),
    application:set_env(quod, namespace_desired_path, Path),
    try Fun(Path)
    after
        case Saved of
            {ok, Value} ->
                application:set_env(quod, namespace_desired_path, Value);
            undefined ->
                application:unset_env(quod, namespace_desired_path)
        end,
        _ = file:del_dir_r(Dir)
    end.

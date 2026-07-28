-module(quod_directory_tests).
-include_lib("eunit/include/eunit.hrl").

direct_seed_is_local_and_precedes_system_test() ->
    Ns = <<"quod:agent">>,
    Key = key(1),
    with_directory(
      #{allowlist => #{Ns => [Key]}},
      fun(_Pid) ->
          {ok, _} = quod_directory:install_record(
                 Key, {<<"system">>, 1001}, [Ns], 1, 1),
          ?assertEqual(
             [{Key, <<"system">>, 1001}],
             quod_directory:directory_hosts(Ns)),

          Seed = {<<"private">>, 2002},
          ok = quod_directory:add_direct_seed(Ns, Seed),
          {known, [First, Second]} = quod_directory:resolve(Ns),
          ?assertEqual(direct, maps:get(scope, First)),
          ?assertEqual(provisional, maps:get(status, First)),
          ?assertEqual(system, maps:get(scope, Second)),
          %% Private/provisional state is never exposed by the public predicate view.
          ?assertEqual(
             [{Key, <<"system">>, 1001}],
             quod_directory:directory_hosts(Ns)),

          ok = quod_directory:confirm_direct_seed(Ns, Seed, key(2)),
          {known, [Confirmed | _]} = quod_directory:resolve(Ns),
          ?assertEqual(confirmed, maps:get(status, Confirmed)),
          ?assertEqual(key(2), maps:get(node_key, Confirmed))
      end).

mixed_allowlist_record_is_rejected_whole_test() ->
    A = <<"quod:agent">>,
    B = <<"quod:root">>,
    Key = key(3),
    with_directory(
      #{allowlist => #{A => [Key]}},
      fun(_Pid) ->
          ?assertEqual(
             {error, not_allowed},
             quod_directory:install_record(
               Key, {<<"node">>, 1003}, [A, B], 1, 1)),
          ?assertEqual([], quod_directory:directory_hosts(A)),
          ?assertEqual(unknown, quod_directory:resolve(A)),
          ?assertEqual(unknown, quod_directory:resolve(B)),
          ?assertEqual(#{routes => 0, highwater => 0, known => 0},
                       quod_directory:stats())
      end).

highwater_survives_expiry_and_blocks_replay_test() ->
    Ns = <<"quod:agent">>,
    Key = key(4),
    with_directory(
      #{allowlist => #{Ns => [Key]}, ttl_ms => 10},
      fun(_Pid) ->
          {ok, _} = quod_directory:install_record(
                 Key, {<<"node">>, 1004}, [Ns], 7, 11),
          ok = quod_directory:expire(quod_time:mono_ms() + 1000),
          ?assertEqual({known, []}, quod_directory:resolve(Ns)),
          ?assertEqual([], quod_directory:directory_hosts(Ns)),
          ?assertEqual(
             {error, stale_record},
             quod_directory:install_record(
               Key, {<<"node">>, 1004}, [Ns], 7, 11)),
          #{routes := 0, highwater := 1, known := 1} =
              quod_directory:stats()
      end).

strict_freshness_and_rate_limit_test() ->
    Ns = <<"quod:agent">>,
    Key = key(5),
    with_directory(
      #{allowlist => #{Ns => [Key]}, renew_min_ms => 1000},
      fun(_Pid) ->
          {ok, _} = quod_directory:install_record(
                 Key, {<<"node">>, 1005}, [Ns], 2, 1),
          ?assertEqual(
             {error, stale_record},
             quod_directory:install_record(
               Key, {<<"node">>, 1005}, [Ns], 1, 999)),
          ?assertEqual(
             {error, rate_limited},
             quod_directory:install_record(
               Key, {<<"node">>, 1005}, [Ns], 2, 2))
      end).

renewal_extends_receiver_local_expiry_test() ->
    Ns = <<"quod:agent">>,
    Key = key(51),
    with_directory(
      #{allowlist => #{Ns => [Key]}, ttl_ms => 100,
        renew_min_ms => 1},
      fun(_Pid) ->
          {ok, FirstExpiry} = quod_directory:install_record(
                                Key, {<<"node">>, 1051}, [Ns], 1, 1),
          {known, [First]} = quod_directory:resolve(Ns),
          ?assertEqual(FirstExpiry, maps:get(expiry, First)),
          timer:sleep(2),
          {ok, RenewedExpiry} = quod_directory:install_record(
                                  Key, {<<"node">>, 1051}, [Ns], 1, 2),
          {known, [Renewed]} = quod_directory:resolve(Ns),
          ?assertEqual(RenewedExpiry, maps:get(expiry, Renewed)),
          ?assert(RenewedExpiry > FirstExpiry),
          ok = quod_directory:expire(FirstExpiry),
          ?assertMatch({known, [_]}, quod_directory:resolve(Ns))
      end).

route_and_announce_bounds_are_atomic_test() ->
    A = <<"quod:a">>,
    B = <<"quod:b">>,
    K1 = key(6),
    K2 = key(7),
    with_directory(
      #{allowlist => #{A => [K1, K2], B => [K1]},
        max_namespaces => 1, max_routes_per_ns => 1,
        renew_min_ms => 1},
      fun(_Pid) ->
          ?assertEqual(
             {error, bad_record},
             quod_directory:install_record(
               K1, {<<"node1">>, 1006}, [A, B], 1, 1)),
          {ok, _} = quod_directory:install_record(
                 K1, {<<"node1">>, 1006}, [A], 1, 2),
          timer:sleep(2),
          ?assertEqual(
             {error, namespace_full},
             quod_directory:install_record(
               K2, {<<"node2">>, 1007}, [A], 1, 1)),
          ?assertEqual(
             [{K1, <<"node1">>, 1006}],
             quod_directory:directory_hosts(A))
      end).

directory_writer_canonicalizes_unique_namespace_order_test() ->
    A = <<"quod:a">>,
    B = <<"quod:b">>,
    Key = key(71),
    with_directory(
      #{allowlist => #{A => [Key], B => [Key]},
        max_namespaces => 2},
      fun(_Pid) ->
          {ok, _} = quod_directory:install_record(
                 Key, {<<"node">>, 1071}, [B, A], 1, 1),
          ?assertEqual(
             [{Key, <<"node">>, 1071}],
             quod_directory:directory_hosts(A)),
          ?assertEqual(
             [{Key, <<"node">>, 1071}],
             quod_directory:directory_hosts(B)),
          ?assertEqual(
             {error, bad_record},
             quod_directory:install_record(
               Key, {<<"node">>, 1071}, [A, A], 1, 2))
      end).

direct_reads_ignore_blocked_owner_and_fail_closed_without_tables_test() ->
    Ns = <<"quod:agent">>,
    Key = key(8),
    with_directory(
      #{allowlist => #{Ns => [Key]}},
      fun(Pid) ->
          {ok, _} = quod_directory:install_record(
                 Key, {<<"node">>, 1008}, [Ns], 1, 1),
          ok = sys:suspend(Pid),
          try
              {known, [_]} = quod_directory:resolve(Ns),
              ?assertEqual(
                 [{Key, <<"node">>, 1008}],
                 quod_directory:directory_hosts(Ns))
          after
              ok = sys:resume(Pid)
          end
      end),
    ?assertEqual(unknown, quod_directory:resolve(Ns)),
    ?assertEqual([], quod_directory:directory_hosts(Ns)).

signed_empty_set_withdraws_but_unknown_key_cannot_fill_highwater_test() ->
    Ns = <<"quod:agent">>,
    Key = key(9),
    Stranger = key(10),
    with_directory(
      #{allowlist => #{Ns => [Key]}, renew_min_ms => 1},
      fun(_Pid) ->
          ?assertEqual(
             {error, not_allowed},
             quod_directory:install_record(
               Stranger, {<<"stranger">>, 1010}, [], 1, 1)),
          {ok, _} = quod_directory:install_record(
                 Key, {<<"node">>, 1009}, [Ns], 1, 1),
          timer:sleep(2),
          {ok, _} = quod_directory:install_record(
                 Key, {<<"node">>, 1009}, [], 1, 2),
          ?assertEqual({known, []}, quod_directory:resolve(Ns)),
          ?assertEqual([], quod_directory:directory_hosts(Ns)),
          #{routes := 0, highwater := 1} = quod_directory:stats()
      end).

configured_direct_seed_is_rebuilt_with_directory_owner_test() ->
    Ns = <<"private:arm">>,
    Endpoint = {<<"private-host">>, 1011},
    Opts = #{direct_seeds => #{Ns => [Endpoint]},
             expire_tick_ms => 60000},
    {ok, _} = application:ensure_all_started(gproc),
    {ok, FirstOwner} = quod_directory:start_link(Opts),
    try
        ?assertMatch(
           {known, [#{scope := direct, endpoint := Endpoint}]},
           quod_directory:resolve(Ns))
    after
        _ = catch gen_server:stop(FirstOwner)
    end,
    {ok, SecondOwner} = quod_directory:start_link(Opts),
    try
        ?assertMatch(
           {known, [#{scope := direct, endpoint := Endpoint}]},
           quod_directory:resolve(Ns)),
        ?assertEqual([], quod_directory:directory_hosts(Ns))
    after
        _ = catch gen_server:stop(SecondOwner)
    end.

with_directory(Opts, Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    {ok, Pid} = quod_directory:start_link(
                  maps:merge(
                    #{expire_tick_ms => 60000, ttl_ms => 10000,
                      renew_min_ms => 1},
                    Opts)),
    try
        Fun(Pid)
    after
        _ = catch gen_server:stop(Pid)
    end.

key(N) -> <<N:256>>.

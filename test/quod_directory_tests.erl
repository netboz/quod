-module(quod_directory_tests).
-include_lib("eunit/include/eunit.hrl").

direct_seed_is_local_and_precedes_system_test() ->
    Ns = <<"quod:agent">>,
    Key = key(1),
    with_directory(
      #{allowlist => #{Ns => [Key]}},
      fun(_Pid) ->
          {ok, _} = quod_directory:install_record(
                 Key, {<<"system">>, 1001}, hosted(Ns), 1, 1),
          ?assertEqual(
             [host(Ns, Key, <<"system">>, 1001)],
             quod_directory:directory_hosts(Ns)),

          Seed = {<<"private">>, 2002},
          ok = quod_directory:add_direct_seed(Ns, Seed),
          {known, [First, Second]} = quod_directory:resolve(Ns),
          ?assertEqual(direct, maps:get(scope, First)),
          ?assertEqual(provisional, maps:get(status, First)),
          ?assertEqual(system, maps:get(scope, Second)),
          ?assertEqual(anchor(Ns), maps:get(genesis_anchor, Second)),
          ?assertEqual(validator, maps:get(role, Second)),
          %% Private/provisional state is never exposed by the public predicate view.
          ?assertEqual(
             [host(Ns, Key, <<"system">>, 1001)],
             quod_directory:directory_hosts(Ns)),

          DirectAnchor = anchor(<<Ns/binary, ":direct">>),
          ok = quod_directory:confirm_direct_seed(
                 Ns, Seed, key(2), DirectAnchor, validator),
          {known, [Confirmed | _]} = quod_directory:resolve(Ns),
          ?assertEqual(confirmed, maps:get(status, Confirmed)),
          ?assertEqual(key(2), maps:get(node_key, Confirmed)),
          ?assertEqual(DirectAnchor, maps:get(genesis_anchor, Confirmed)),
          ?assertEqual(validator, maps:get(role, Confirmed)),
          %% A confirmed operator seed is an immutable identity pin.
          ?assertEqual(
             {error, seed_identity_conflict},
             quod_directory:confirm_direct_seed(
               Ns, Seed, key(2), anchor(<<"other">>), observer)),
          ?assertEqual(
             Confirmed, hd(element(2, quod_directory:resolve(Ns))))
      end).

directory_hosts_remain_key_ordered_with_anchors_test() ->
    Ns = <<"quod:ordered">>,
    LowKey = key(1),
    HighKey = key(2),
    LowAnchor = <<1:256>>,
    HighAnchor = <<2:256>>,
    with_directory(
      #{allowlist => #{Ns => [LowKey, HighKey]}},
      fun(_Pid) ->
          {ok, _} = quod_directory:install_record(
                      LowKey, {<<"low-key">>, 1001},
                      [{Ns, HighAnchor, validator}], 1, 1),
          {ok, _} = quod_directory:install_record(
                      HighKey, {<<"high-key">>, 1002},
                      [{Ns, LowAnchor, validator}], 1, 1),
          ?assertEqual(
             [{HighAnchor, LowKey, <<"low-key">>, 1001},
              {LowAnchor, HighKey, <<"high-key">>, 1002}],
             quod_directory:directory_hosts(Ns))
      end).

ambiguous_direct_seed_promotion_fails_without_owner_crash_test() ->
    Ns = <<"quod:agent">>,
    Seed = {<<"private">>, 2003},
    with_directory(
      #{direct_seeds => #{Ns => [Seed]}},
      fun(Pid) ->
          _ = sys:replace_state(
                Pid,
                fun(State) ->
                    true = ets:insert(
                             quod_directory_routes,
                             {Ns, direct, {direct_seed, Seed}, undefined,
                              Seed, provisional, undefined, undefined,
                              infinity, 1, 1}),
                    State
                end),
          ?assertEqual(
             {error, ambiguous_seed},
             quod_directory:confirm_direct_seed(
               Ns, Seed, key(22), anchor(Ns), validator)),
          ?assert(is_process_alive(Pid)),
          {known, Routes} = quod_directory:resolve(Ns),
          ?assertEqual(2, length(Routes))
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
               Key, {<<"node">>, 1003}, hosted([A, B]), 1, 1)),
          ?assertEqual([], quod_directory:directory_hosts(A)),
          ?assertEqual(unknown, quod_directory:resolve(A)),
          ?assertEqual(unknown, quod_directory:resolve(B)),
          ?assertEqual(#{routes => 0, highwater => 0, known => 0},
                       quod_directory:stats())
      end).

snapshot_batch_preserves_position_aligned_admission_test() ->
    Ns = <<"quod:agent">>,
    Allowed = key(31),
    Denied = key(32),
    with_directory(
      #{allowlist => #{Ns => [Allowed]}},
      fun(_Pid) ->
          {ok, [{ok, Expiry}, {error, not_allowed}]} =
              quod_directory:install_records(
                [{Allowed, {<<"allowed">>, 1031}, hosted(Ns), 1, 1},
                 {Denied, {<<"denied">>, 1032}, hosted(Ns), 1, 1}]),
          ?assert(is_integer(Expiry)),
          ?assertEqual(
             [host(Ns, Allowed, <<"allowed">>, 1031)],
             quod_directory:directory_hosts(Ns))
      end).

highwater_survives_expiry_and_blocks_replay_test() ->
    Ns = <<"quod:agent">>,
    Key = key(4),
    with_directory(
      #{allowlist => #{Ns => [Key]}, ttl_ms => 10},
      fun(_Pid) ->
          {ok, _} = quod_directory:install_record(
                 Key, {<<"node">>, 1004}, hosted(Ns), 7, 11),
          ok = quod_directory:expire(quod_time:mono_ms() + 1000),
          ?assertEqual({known, []}, quod_directory:resolve(Ns)),
          ?assertEqual([], quod_directory:directory_hosts(Ns)),
          ?assertEqual(
             {error, stale_record},
             quod_directory:install_record(
               Key, {<<"node">>, 1004}, hosted(Ns), 7, 11)),
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
                 Key, {<<"node">>, 1005}, hosted(Ns), 2, 1),
          ?assertEqual(
             {error, stale_record},
             quod_directory:install_record(
               Key, {<<"node">>, 1005}, hosted(Ns), 1, 999)),
          ?assertEqual(
             {error, rate_limited},
             quod_directory:install_record(
               Key, {<<"node">>, 1005}, hosted(Ns), 2, 2))
      end).

renewal_extends_receiver_local_expiry_test() ->
    Ns = <<"quod:agent">>,
    Key = key(51),
    with_directory(
      #{allowlist => #{Ns => [Key]}, ttl_ms => 100,
        renew_min_ms => 1},
      fun(_Pid) ->
          {ok, FirstExpiry} = quod_directory:install_record(
                                Key, {<<"node">>, 1051}, hosted(Ns), 1, 1),
          {known, [First]} = quod_directory:resolve(Ns),
          ?assertEqual(FirstExpiry, maps:get(expiry, First)),
          timer:sleep(2),
          {ok, RenewedExpiry} = quod_directory:install_record(
                                  Key, {<<"node">>, 1051}, hosted(Ns), 1, 2),
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
               K1, {<<"node1">>, 1006}, hosted([A, B]), 1, 1)),
          {ok, _} = quod_directory:install_record(
                 K1, {<<"node1">>, 1006}, hosted(A), 1, 2),
          timer:sleep(2),
          ?assertEqual(
             {error, namespace_full},
             quod_directory:install_record(
               K2, {<<"node2">>, 1007}, hosted(A), 1, 1)),
          ?assertEqual(
             [host(A, K1, <<"node1">>, 1006)],
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
                 Key, {<<"node">>, 1071}, hosted([B, A]), 1, 1),
          ?assertEqual(
             [host(A, Key, <<"node">>, 1071)],
             quod_directory:directory_hosts(A)),
          ?assertEqual(
             [host(B, Key, <<"node">>, 1071)],
             quod_directory:directory_hosts(B)),
          ?assertEqual(
             {error, bad_record},
             quod_directory:install_record(
               Key, {<<"node">>, 1071},
               [{A, anchor(A), validator},
                {A, anchor(<<A/binary, "-other">>), observer}], 1, 2))
      end).

direct_reads_ignore_blocked_owner_and_fail_closed_without_tables_test() ->
    Ns = <<"quod:agent">>,
    Key = key(8),
    with_directory(
      #{allowlist => #{Ns => [Key]}},
      fun(Pid) ->
          {ok, _} = quod_directory:install_record(
                 Key, {<<"node">>, 1008}, hosted(Ns), 1, 1),
          ok = sys:suspend(Pid),
          try
              {known, [_]} = quod_directory:resolve(Ns),
              ?assertEqual(
                 [host(Ns, Key, <<"node">>, 1008)],
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
                 Key, {<<"node">>, 1009}, hosted(Ns), 1, 1),
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

hosted(Ns) when is_binary(Ns) ->
    [{Ns, anchor(Ns), validator}];
hosted(Namespaces) when is_list(Namespaces) ->
    [{Ns, anchor(Ns), validator} || Ns <- Namespaces].

host(Ns, Key, Host, Port) ->
    {anchor(Ns), Key, Host, Port}.

anchor(Ns) when is_binary(Ns) ->
    crypto:hash(sha256, Ns).

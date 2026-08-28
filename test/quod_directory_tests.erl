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

validator_routes_fail_whole_on_anchor_conflict_test() ->
    Ns = <<"quod:dtx-route">>,
    Expected = anchor(Ns),
    Other = anchor(<<Ns/binary, ":other">>),
    K1 = key(41),
    K2 = key(42),
    with_directory(
      #{allowlist => #{Ns => [K1, K2]}},
      fun(_Pid) ->
          {ok, _} = quod_directory:install_record(
                      K1, {<<"one">>, 1041},
                      [{Ns, Expected, validator}], 1, 1),
          ?assertMatch(
             {ok, [#{node_key := K1, genesis_anchor := Expected}]},
             quod_directory:validator_routes(Ns, Expected)),
          {ok, _} = quod_directory:install_record(
                      K2, {<<"two">>, 1042},
                      [{Ns, Other, validator}], 1, 1),
          ?assertEqual(
             {error, anchor_conflict},
             quod_directory:validator_routes(Ns, Expected))
      end).

route_availability_notification_is_exact_and_post_projection_test() ->
    Ns = <<"quod:route-notify">>,
    Anchor = anchor(Ns),
    Identity = {Ns, Anchor},
    OtherIdentity = {Ns, anchor(<<Ns/binary, ":other">>)},
    Seed = {<<"private">>, 2041},
    Key = key(43),
    with_directory(
      #{allowlist => #{Ns => [Key]}},
      fun(_Pid) ->
          true = quod_reg:subscribe({directory_route, Identity}),
          true = quod_reg:subscribe({directory_route, OtherIdentity}),
          try
              %% A provisional contact and a rejected advertisement cannot
              %% wake an exact-identity waiter.
              ok = quod_directory:add_direct_seed(Ns, Seed),
              assert_no_directory_route_event(),
              ?assertEqual(
                 {error, not_allowed},
                 quod_directory:install_record(
                   key(44), {<<"denied">>, 1044}, hosted(Ns), 1, 1)),
              assert_no_directory_route_event(),

              %% The event is sent only after the normal projection is usable,
              %% and contains identity only -- never endpoint or route data.
              ok = quod_directory:confirm_direct_seed(
                     Ns, Seed, Key, Anchor, validator),
              receive
                  {directory_route_available, Identity} ->
                      ?assertMatch(
                         {ok, [#{node_key := Key}]},
                         quod_directory:validator_routes(Ns, Anchor))
              after 1000 ->
                  erlang:error(missing_directory_route_event)
              end,
              assert_no_directory_route_event()
          after
              true = quod_reg:unsubscribe({directory_route, OtherIdentity}),
              true = quod_reg:unsubscribe({directory_route, Identity})
          end
      end).

private_route_reannounces_when_its_authenticated_node_returns_test() ->
    PrivateNs = <<"quod:private-return">>,
    RootNs = <<"quod:root">>,
    PrivateAnchor = anchor(PrivateNs),
    PrivateIdentity = {PrivateNs, PrivateAnchor},
    RootAnchor = anchor(RootNs),
    Seed = {<<"private-node">>, 2042},
    Key = key(47),
    with_directory(
      #{allowlist => #{RootNs => [Key]}},
      fun(_Pid) ->
          true = quod_reg:subscribe({directory_route, PrivateIdentity}),
          try
              ok = quod_directory:add_direct_seed(PrivateNs, Seed),
              ok = quod_directory:confirm_direct_seed(
                     PrivateNs, Seed, Key, PrivateAnchor, validator),
              await_directory_route_event(PrivateIdentity),

              %% The private ontology is deliberately absent from the public
              %% advertisement. A fresh signed record for the same physical
              %% node is nevertheless the exact remote-liveness edge which
              %% releases its pinned private route after restart/partition.
              {ok, _} = quod_directory:install_record(
                          Key, {<<"returned-node">>, 1047},
                          [{RootNs, RootAnchor, validator}], 1, 1),
              await_directory_route_event(PrivateIdentity),
              ?assertMatch(
                 {ok, [#{node_key := Key, endpoint := Seed}]},
                 quod_directory:validator_routes(
                   PrivateNs, PrivateAnchor)),

              %% A stale/replayed record is not a fresh liveness edge.
              ?assertEqual(
                 {error, stale_record},
                 quod_directory:install_record(
                   Key, {<<"returned-node">>, 1047},
                   [{RootNs, RootAnchor, validator}], 1, 1)),
              assert_no_directory_route_event()
          after
              true = quod_reg:unsubscribe(
                       {directory_route, PrivateIdentity})
          end
      end).

route_notification_change_removal_and_unsubscribe_are_safe_test() ->
    Ns = <<"quod:route-change">>,
    FirstAnchor = anchor(<<Ns/binary, ":first">>),
    SecondAnchor = anchor(<<Ns/binary, ":second">>),
    FirstIdentity = {Ns, FirstAnchor},
    SecondIdentity = {Ns, SecondAnchor},
    Key = key(45),
    ConflictKey = key(46),
    with_directory(
      #{allowlist => #{Ns => [Key, ConflictKey]}},
      fun(_Pid) ->
          true = quod_reg:subscribe({directory_route, FirstIdentity}),
          true = quod_reg:subscribe({directory_route, SecondIdentity}),
          try
              {ok, _} = quod_directory:install_record(
                          Key, {<<"first">>, 1045},
                          [{Ns, FirstAnchor, validator}], 1, 1),
              await_directory_route_event(FirstIdentity),

              %% A conflicting anchor makes the exact lookup unusable and
              %% cannot announce either identity. Withdrawing that conflict
              %% safely announces the identity that becomes usable again.
              {ok, _} = quod_directory:install_record(
                          ConflictKey, {<<"conflict">>, 1046},
                          [{Ns, SecondAnchor, validator}], 1, 1),
              assert_no_directory_route_event(),
              {ok, _} = quod_directory:install_record(
                          ConflictKey, {<<"conflict">>, 1046}, [], 1, 2),
              await_directory_route_event(FirstIdentity),

              %% Replacing a route wakes only the identity usable in the
              %% completed replacement; the removed identity is never sent.
              {ok, _} = quod_directory:install_record(
                          Key, {<<"second">>, 1047},
                          [{Ns, SecondAnchor, validator}], 1, 2),
              await_directory_route_event(SecondIdentity),
              assert_no_directory_route_event(),

              %% Withdrawal has no available identity to publish.
              {ok, _} = quod_directory:install_record(
                          Key, {<<"second">>, 1047}, [], 1, 3),
              assert_no_directory_route_event(),

              true = quod_reg:unsubscribe(
                       {directory_route, SecondIdentity}),
              {ok, _} = quod_directory:install_record(
                          Key, {<<"second">>, 1048},
                          [{Ns, SecondAnchor, validator}], 1, 4),
              assert_no_directory_route_event()
          after
              _ = catch quod_reg:unsubscribe(
                            {directory_route, SecondIdentity}),
              true = quod_reg:unsubscribe({directory_route, FirstIdentity})
          end
      end).

expired_anchor_conflict_publishes_the_identity_it_releases_test() ->
    Ns = <<"quod:route-expiry">>,
    DirectAnchor = anchor(<<Ns/binary, ":direct">>),
    ExpiringAnchor = anchor(<<Ns/binary, ":expiring">>),
    Identity = {Ns, DirectAnchor},
    Seed = {<<"private">>, 2048},
    DirectKey = key(48),
    ExpiringKey = key(49),
    with_directory(
      #{allowlist => #{Ns => [ExpiringKey]}, ttl_ms => 10},
      fun(_Pid) ->
          true = quod_reg:subscribe({directory_route, Identity}),
          try
              ok = quod_directory:add_direct_seed(Ns, Seed),
              ok = quod_directory:confirm_direct_seed(
                     Ns, Seed, DirectKey, DirectAnchor, validator),
              await_directory_route_event(Identity),
              {ok, Expiry} = quod_directory:install_record(
                               ExpiringKey, {<<"expiring">>, 1049},
                               [{Ns, ExpiringAnchor, validator}], 1, 1),
              ?assertEqual(
                 {error, anchor_conflict},
                 quod_directory:validator_routes(Ns, DirectAnchor)),
              assert_no_directory_route_event(),

              %% Once the conflicting system row expires, the persistent
              %% direct identity becomes usable without any new install.
              %% Expiry itself must therefore publish the exact route edge.
              ok = quod_directory:expire(Expiry),
              await_directory_route_event(Identity),
              ?assertMatch(
                 {ok, [#{node_key := DirectKey, endpoint := Seed}]},
                 quod_directory:validator_routes(Ns, DirectAnchor))
          after
              true = quod_reg:unsubscribe({directory_route, Identity})
          end
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

strict_freshness_accepts_immediate_newer_records_test() ->
    Ns = <<"quod:agent">>,
    Key = key(5),
    with_directory(
      #{allowlist => #{Ns => [Key]}},
      fun(_Pid) ->
          {ok, _} = quod_directory:install_record(
                 Key, {<<"node">>, 1005}, hosted(Ns), 2, 1),
          ?assertEqual(
             {error, stale_record},
             quod_directory:install_record(
               Key, {<<"node">>, 1005}, hosted(Ns), 1, 999)),
          ?assertMatch(
             {ok, _},
             quod_directory:install_record(
               Key, {<<"node">>, 1005}, hosted(Ns), 2, 2))
      end).

renewal_extends_receiver_local_expiry_test() ->
    Ns = <<"quod:agent">>,
    Key = key(51),
    with_directory(
      #{allowlist => #{Ns => [Key]}, ttl_ms => 100},
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
        max_namespaces => 1, max_routes_per_ns => 1},
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
      #{allowlist => #{Ns => [Key]}},
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
                    #{expire_tick_ms => 60000, ttl_ms => 10000},
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

await_directory_route_event(Identity) ->
    receive
        {directory_route_available, Identity} -> ok
    after 1000 ->
        erlang:error({missing_directory_route_event, Identity})
    end.

assert_no_directory_route_event() ->
    receive
        {directory_route_available, Identity} ->
            erlang:error({unexpected_directory_route_event, Identity})
    after 50 ->
        ok
    end.

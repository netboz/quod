-module(quod_directory_control_tests).

-include_lib("eunit/include/eunit.hrl").

direct_ingress_binds_author_and_endpoint_test() ->
    {Pub, Signer} = signer(),
    Ns = <<"quod:root">>,
    Endpoint = {<<"node-a">>, 5001},
    with_control(
      #{allowlist => #{Ns => [Pub]}},
      fun() ->
          {ok, Record} = quod_directory_record:sign(
                           Pub, Endpoint, [Ns], 1, 1, Signer),
          ?assertEqual(
             {error, source_mismatch},
             quod_directory_control:test_ingest(
               Record, {direct, Pub, {<<"substitute">>, 5001}})),
          ?assertEqual([], quod_directory:directory_hosts(Ns)),
          ?assertEqual(
             {error, source_mismatch},
             quod_directory_control:test_ingest(
               Record, {direct, key(99), Endpoint})),
          ?assertEqual([], quod_directory:directory_hosts(Ns)),
          ok = quod_directory_control:test_ingest(
                 Record, {direct, Pub, Endpoint}),
          ?assertEqual(
             [{Pub, <<"node-a">>, 5001}],
             quod_directory:directory_hosts(Ns))
      end).

relay_and_resync_reverify_original_signature_test() ->
    {Pub, Signer} = signer(),
    Ns = <<"quod:agent">>,
    Endpoint = {<<"node-b">>, 5002},
    with_control(
      #{allowlist => #{Ns => [Pub]}},
      fun() ->
          {ok, Record1} = quod_directory_record:sign(
                            Pub, Endpoint, [Ns], 3, 1, Signer),
          ok = quod_directory_control:test_ingest(Record1, relay),
          ?assertEqual(
             [{Pub, <<"node-b">>, 5002}],
             quod_directory:directory_hosts(Ns)),
          timer:sleep(2),
          {ok, Record2} = quod_directory_record:sign(
                            Pub, Endpoint, [Ns], 3, 2, Signer),
          ok = quod_directory_control:test_ingest(Record2, resync),
          ?assertEqual(1, maps:get(records, quod_directory_control:stats()))
      end).

tampered_record_is_rejected_for_every_ingress_kind_test() ->
    lists:foreach(
      fun(SourceKind) ->
          {Pub, Signer} = signer(),
          Ns = <<"quod:root">>,
          Endpoint = {<<"node-c">>, 5003},
          with_control(
            #{allowlist => #{Ns => [Pub]}},
            fun() ->
                {ok, Record} = quod_directory_record:sign(
                                 Pub, Endpoint, [Ns], 5, 1, Signer),
                Tampered = flip_last_byte(Record),
                Source = case SourceKind of
                             direct -> {direct, Pub, Endpoint};
                             relay -> relay;
                             resync -> resync
                         end,
                ?assertMatch(
                   {error, _},
                   quod_directory_control:test_ingest(Tampered, Source)),
                ?assertEqual([], quod_directory:directory_hosts(Ns)),
                ?assertEqual(
                   #{routes => 0, highwater => 0, known => 0},
                   quod_directory:stats())
            end)
      end,
      [direct, relay, resync]).

mixed_authorization_is_rejected_after_valid_signature_test() ->
    {Pub, Signer} = signer(),
    A = <<"quod:a">>,
    B = <<"quod:b">>,
    with_control(
      #{allowlist => #{A => [Pub]}},
      fun() ->
          {ok, Record} = quod_directory_record:sign(
                           Pub, {<<"node-d">>, 5004}, [A, B],
                           1, 1, Signer),
          ?assertEqual(
             {error, not_allowed},
             quod_directory_control:test_ingest(Record, relay)),
          ?assertEqual([], quod_directory:directory_hosts(A)),
          ?assertEqual(unknown, quod_directory:resolve(A))
      end).

public_reader_cannot_relay_or_push_captured_snapshot_test() ->
    {Author, Signer} = signer(),
    Relay = key(41),
    Reader = key(42),
    Ns = <<"quod:published">>,
    RelayNs = <<"quod:relay">>,
    Endpoint = {<<"author">>, 5041},
    with_control(
      #{allowlist => #{Ns => [Author], RelayNs => [Relay]}},
      fun() ->
          Control = quod_reg:where({directory, control}),
          Channel = quod_directory_control:channel(),
          {ok, Record} = quod_directory_record:sign(
                           Author, Endpoint, [Ns], 1, 1, Signer),
          Announce = term_to_binary(
                       {quod_directory_announce, Record},
                       [deterministic]),
          Snapshot = term_to_binary(
                       {quod_directory_snapshot, [Record], done},
                       [deterministic]),

          %% A public reader is authenticated enough to request a snapshot,
          %% but is neither a bootstrap nor an allowlisted relay.
          Control !
              {quod_message,
               {{Reader, {<<"reader">>, 5042}}, self()},
               Channel, Announce},
          _ = sys:get_state(Control),
          ?assertEqual([], quod_directory:directory_hosts(Ns)),
          Control !
              {quod_message, {Reader, self()}, Channel, Snapshot},
          _ = sys:get_state(Control),
          ?assertEqual([], quod_directory:directory_hosts(Ns)),
          Control !
              {quod_message,
               {{Reader, {<<"reader">>, 5042}}, self()},
               Channel, Snapshot},
          _ = sys:get_state(Control),
          ?assertEqual([], quod_directory:directory_hosts(Ns)),
          ?assertEqual(
             0, maps:get(records, quod_directory_control:stats())),

          %% An allowlisted system host may relay the same immutable signed
          %% record; the receiver still verifies the author and namespace.
          Control !
              {quod_message,
               {{Relay, {<<"relay">>, 5043}}, self()},
               Channel, Announce},
          _ = sys:get_state(Control),
          ?assertEqual(
             [{Author, <<"author">>, 5041}],
             quod_directory:directory_hosts(Ns))
      end).

directory_owner_restart_requires_fresh_peer_lease_test() ->
    {Pub, Signer} = signer(),
    Ns = <<"quod:root">>,
    Opts = #{allowlist => #{Ns => [Pub]},
             expire_tick_ms => 60000, ttl_ms => 10000,
             renew_min_ms => 1},
    {ok, _} = application:ensure_all_started(gproc),
    {ok, Directory0} = quod_directory:start_link(Opts),
    {ok, Control} = quod_directory_control:start_link(Opts),
    try
        {ok, Record} = quod_directory_record:sign(
                         Pub, {<<"node-e">>, 5005}, [Ns],
                         1, 1, Signer),
        ok = quod_directory_control:test_ingest(Record, relay),
        ?assertEqual(
           [{Pub, <<"node-e">>, 5005}],
           quod_directory:directory_hosts(Ns)),
        ?assertEqual(
           1, maps:get(records, quod_directory_control:stats())),
        ok = gen_server:stop(Directory0),
        ?assertEqual([], quod_directory:directory_hosts(Ns)),
        {ok, _Directory1} = quod_directory:start_link(Opts),
        timer:sleep(150),
        ?assertEqual([], quod_directory:directory_hosts(Ns)),
        ?assertEqual(
           0, maps:get(records, quod_directory_control:stats())),
        {ok, Renewal} = quod_directory_record:sign(
                          Pub, {<<"node-e">>, 5005}, [Ns],
                          1, 2, Signer),
        ok = quod_directory_control:test_ingest(Renewal, relay),
        ?assertEqual(
           ok,
           wait_until(
             fun() ->
                 quod_directory:directory_hosts(Ns)
                     =:= [{Pub, <<"node-e">>, 5005}]
             end, 100))
    after
        _ = catch gen_server:stop(Control),
        case quod_reg:where({directory, node}) of
            Pid when is_pid(Pid) -> _ = catch gen_server:stop(Pid);
            undefined -> ok
        end
    end.

retained_peer_record_expires_for_resync_test() ->
    {Pub, Signer} = signer(),
    Ns = <<"quod:short-lease">>,
    with_control(
      #{allowlist => #{Ns => [Pub]}, ttl_ms => 20},
      fun() ->
          {ok, Record} = quod_directory_record:sign(
                           Pub, {<<"short-lived">>, 5007}, [Ns],
                           1, 1, Signer),
          ok = quod_directory_control:test_ingest(Record, relay),
          ?assertEqual(
             1, maps:get(records, quod_directory_control:stats())),
          timer:sleep(30),
          ?assertEqual(
             0, maps:get(records, quod_directory_control:stats()))
      end).

resync_snapshot_is_page_bounded_test() ->
    ExpiresAt = quod_time:mono_ms() + 10000,
    Records = maps:from_list(
                [{key(N),
                  {<<"record-", (integer_to_binary(N))/binary>>, ExpiresAt}}
                 || N <- lists:seq(1, 129)]),
    {First, 128} = quod_directory_control:snapshot_page(0, Records),
    ?assertEqual(128, length(First)),
    {Second, done} = quod_directory_control:snapshot_page(128, Records),
    ?assertEqual(1, length(Second)).

running_namespace_changes_replace_the_advertised_set_test() ->
    {Pub, Signer} = signer(),
    A = <<"quod:dynamic-a">>,
    B = <<"quod:dynamic-b">>,
    Private = [<<"private:", (integer_to_binary(N))/binary>>
               || N <- lists:seq(1, 33)],
    Endpoint = {<<"self">>, 5006},
    IdentityDir = temp_identity_dir(),
    SavedEnv = save_env(
                 [node_pubkey, identity_key, node_addr,
                  directory_tracking]),
    try
        application:set_env(quod, node_pubkey, Pub),
        application:set_env(quod, identity_key, Signer),
        application:set_env(quod, node_addr, Endpoint),
        application:set_env(quod, directory_tracking, false),
        Opts = #{allowlist => #{A => [Pub], B => [Pub]},
                 identity_dir => IdentityDir,
                 expire_tick_ms => 60000, ttl_ms => 10000,
                 renew_min_ms => 1},
        {ok, _} = application:ensure_all_started(gproc),
        {ok, Directory0} = quod_directory:start_link(Opts),
        {ok, NsSup} = quod_ns_sup:start_link(),
        lists:foreach(
          fun(Ns) -> true = gproc:reg({n, l, {quod_ns, Ns}}) end,
          Private),
        true = gproc:reg({n, l, {quod_ns, A}}),
        {ok, Control0} = quod_directory_control:start_link(Opts),
        try
            %% A stale notification before the application startup barrier
            %% cannot publish the partially booted live registry.
            ok = quod_directory_control:namespace_changed(),
            timer:sleep(150),
            ?assertNot(maps:get(
                         tracking, quod_directory_control:stats())),
            ?assertEqual([], quod_directory:directory_hosts(A)),
            ok = quod_directory_control:start_tracking(),
            ?assertEqual(
               ok,
               wait_until(
                 fun() ->
                     quod_directory:directory_hosts(A)
                         =:= [{Pub, <<"self">>, 5006}]
                 end, 100)),
            SequenceA = maps:get(
                          sequence, quod_directory_control:stats()),
            timer:sleep(5),
            true = gproc:unreg({n, l, {quod_ns, A}}),
            true = gproc:reg({n, l, {quod_ns, B}}),
            %% No lifecycle notification: the next renewal must still read the
            %% live registry and publish one complete replacement set.
            Control0 ! directory_tick,
            ?assertEqual(
               ok,
               wait_until(
                 fun() ->
                     quod_directory:directory_hosts(A) =:= []
                         andalso quod_directory:directory_hosts(B)
                             =:= [{Pub, <<"self">>, 5006}]
                 end, 100)),
            ?assert(
               maps:get(sequence, quod_directory_control:stats())
                   > SequenceA),
            ?assertEqual({known, []}, quod_directory:resolve(A)),

            %% A directory-owner restart rebuilds the current desired self
            %% record, rather than an older accepted advertisement.
            ok = gen_server:stop(Directory0),
            {ok, _Directory1} = quod_directory:start_link(Opts),
            ?assertEqual(
               ok,
               wait_until(
                 fun() ->
                     quod_directory:directory_hosts(B)
                         =:= [{Pub, <<"self">>, 5006}]
                 end, 100)),

            %% A control-child restart must use the current registry under a
            %% fresh epoch, never its previous B advertisement.
            Epoch0 = maps:get(epoch, quod_directory_control:stats()),
            ok = gen_server:stop(Control0),
            true = gproc:unreg({n, l, {quod_ns, B}}),
            lists:foreach(
              fun(Ns) -> true = gproc:unreg({n, l, {quod_ns, Ns}}) end,
              Private),
            true = gproc:reg({n, l, {quod_ns, A}}),
            true = gproc:reg({n, l, {quod_prolog, A}}),
            {ok, _Control1} = quod_directory_control:start_link(Opts),
            ?assertEqual(
               ok,
               wait_until(
                 fun() ->
                     quod_directory:directory_hosts(A)
                         =:= [{Pub, <<"self">>, 5006}]
                         andalso quod_directory:directory_hosts(B) =:= []
                 end, 100)),
            ?assert(
               maps:get(epoch, quod_directory_control:stats()) > Epoch0)
        after
            _ = catch gproc:unreg({n, l, {quod_ns, A}}),
            _ = catch gproc:unreg({n, l, {quod_ns, B}}),
            _ = catch gproc:unreg({n, l, {quod_prolog, A}}),
            _ = [catch gproc:unreg({n, l, {quod_ns, Ns}})
                 || Ns <- Private],
            _ = catch gen_server:stop(NsSup),
            case quod_reg:where({directory, control}) of
                Pid when is_pid(Pid) -> _ = catch gen_server:stop(Pid);
                undefined -> ok
            end,
            case quod_reg:where({directory, node}) of
                DirectoryPid when is_pid(DirectoryPid) ->
                    _ = catch gen_server:stop(DirectoryPid);
                undefined ->
                    ok
            end
        end
    after
        restore_env(SavedEnv),
        delete_identity_dir(IdentityDir)
    end.

with_control(Opts, Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    Common = maps:merge(
               #{expire_tick_ms => 60000, ttl_ms => 10000,
                 renew_min_ms => 1},
               Opts),
    {ok, Directory} = quod_directory:start_link(Common),
    {ok, Control} = quod_directory_control:start_link(Common),
    try
        Fun()
    after
        _ = catch gen_server:stop(Control),
        _ = catch gen_server:stop(Directory)
    end.

signer() ->
    {Pub, Seed} = quod_identity:generate(),
    {Pub, quod_identity:key_term({Pub, Seed})}.

key(N) -> <<N:256>>.

flip_last_byte(Binary) ->
    PrefixSize = byte_size(Binary) - 1,
    <<Prefix:PrefixSize/binary, Last>> = Binary,
    <<Prefix/binary, (Last bxor 1)>>.

wait_until(_Fun, 0) ->
    timeout;
wait_until(Fun, Retries) ->
    case Fun() of
        true -> ok;
        _ -> timer:sleep(10), wait_until(Fun, Retries - 1)
    end.

temp_identity_dir() ->
    Name = lists:flatten(
             io_lib:format(
               "quod_directory_control_test_~B",
               [erlang:unique_integer([positive])])),
    filename:join("/tmp", Name).

save_env(Keys) ->
    [{Key, application:get_env(quod, Key)} || Key <- Keys].

restore_env(Saved) ->
    lists:foreach(
      fun({Key, {ok, Value}}) ->
              application:set_env(quod, Key, Value);
         ({Key, undefined}) ->
              application:unset_env(quod, Key)
      end, Saved).

delete_identity_dir(Dir) ->
    _ = file:delete(filename:join(Dir, "directory.epoch")),
    _ = file:del_dir(Dir),
    ok.

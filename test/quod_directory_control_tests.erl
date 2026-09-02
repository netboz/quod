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
                           Pub, Endpoint, hosted(Ns), 1, 1, Signer),
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
             [host(Ns, Pub, <<"node-a">>, 5001)],
             quod_directory:directory_hosts(Ns))
      end).

relay_and_resync_reverify_original_signature_test() ->
    {Pub, Signer} = signer(),
    Relay = key(30),
    Ns = <<"quod:agent">>,
    Endpoint = {<<"node-b">>, 5002},
    with_control(
      #{allowlist => #{Ns => [Pub]}},
      fun() ->
          Link = link_sink(),
          try
              ok = quod_directory_control:test_set_control_peers([Relay]),
              ok = quod_directory_control:test_set_control_link(
                     Relay, {<<"relay">>, 5030}, Link),
              {ok, Record1} = quod_directory_record:sign(
                                Pub, Endpoint, hosted(Ns), 3, 1, Signer),
              ok = quod_directory_control:test_ingest(
                     Record1, {relay, Relay}),
              ?assertEqual(
                 [host(Ns, Pub, <<"node-b">>, 5002)],
                 quod_directory:directory_hosts(Ns)),
              timer:sleep(2),
              {ok, Record2} = quod_directory_record:sign(
                                Pub, Endpoint, hosted(Ns), 3, 2, Signer),
              ok = quod_directory_control:test_ingest(
                     Record2, {resync, Relay, Link}),
              ?assertEqual(
                 1, maps:get(
                      records, quod_directory_control:stats()))
          after
              exit(Link, kill)
          end
      end).

tampered_record_is_rejected_for_every_ingress_kind_test() ->
    lists:foreach(
      fun(SourceKind) ->
          {Pub, Signer} = signer(),
          Relay = key(31),
          Ns = <<"quod:root">>,
          Endpoint = {<<"node-c">>, 5003},
          with_control(
            #{allowlist => #{Ns => [Pub]}},
            fun() ->
                Link = link_sink(),
                try
                    ok = quod_directory_control:test_set_control_peers(
                           [Relay]),
                    ok = quod_directory_control:test_set_control_link(
                           Relay, {<<"relay">>, 5031}, Link),
                    {ok, Record} = quod_directory_record:sign(
                                     Pub, Endpoint, hosted(Ns), 5, 1, Signer),
                    Tampered = tamper_signature(Record),
                    Source = case SourceKind of
                                 direct -> {direct, Pub, Endpoint};
                                 relay -> {relay, Relay};
                                 resync -> {resync, Relay, Link}
                             end,
                    ?assertEqual(
                       {error, bad_signature},
                       quod_directory_control:test_ingest(
                         Tampered, Source)),
                    ?assertEqual([], quod_directory:directory_hosts(Ns)),
                    ?assertEqual(
                       #{routes => 0, highwater => 0, known => 0},
                       quod_directory:stats())
                after
                    exit(Link, kill)
                end
            end)
      end,
      [direct, relay, resync]).

relay_fanout_skips_author_and_immediate_source_test() ->
    {Author, Signer} = signer(),
    SelfKey = key(33),
    Relay = key(34),
    Other = key(35),
    Ns = <<"quod:fanout">>,
    Endpoint = {<<"author">>, 5033},
    SavedEnv = save_env([node_pubkey]),
    try
        application:set_env(quod, node_pubkey, SelfKey),
        with_control(
          #{allowlist => #{Ns => [Author]}},
          fun() ->
              Control = quod_reg:where({directory, control}),
              Channel = quod_directory_control:channel(),
              AuthorLink = link_probe(self()),
              RelayLink = link_probe(self()),
              OtherLink = link_probe(self()),
              try
                  ok = quod_directory_control:test_set_control_peers(
                         [SelfKey, Author, Relay, Other]),
                  ok = quod_directory_control:test_set_control_link(
                         Author, Endpoint, AuthorLink),
                  ok = quod_directory_control:test_set_control_link(
                         Relay, {<<"relay">>, 5034}, RelayLink),
                  ok = quod_directory_control:test_set_control_link(
                         Other, {<<"other">>, 5035}, OtherLink),
                  {ok, Record} = quod_directory_record:sign(
                                   Author, Endpoint, hosted(Ns), 1, 1, Signer),
                  Announce = term_to_binary(
                               {quod_directory_announce, Record},
                               [deterministic]),
                  Control !
                      {quod_message, {Relay, RelayLink},
                       Channel, Announce},
                  _ = sys:get_state(Control),
                  ?assertEqual(
                     [host(Ns, Author, <<"author">>, 5033)],
                     quod_directory:directory_hosts(Ns)),
                  ?assertEqual(
                     ok, wait_for_announce(OtherLink, Record, 100)),
                  assert_no_announce(AuthorLink),
                  assert_no_announce(RelayLink)
              after
                  exit(AuthorLink, kill),
                  exit(RelayLink, kill),
                  exit(OtherLink, kill)
              end
          end)
    after
        restore_env(SavedEnv)
    end.

mixed_authorization_is_rejected_after_valid_signature_test() ->
    {Pub, Signer} = signer(),
    Relay = key(32),
    A = <<"quod:a">>,
    B = <<"quod:b">>,
    with_control(
      #{allowlist => #{A => [Pub]}},
      fun() ->
          ok = quod_directory_control:test_set_control_peers([Relay]),
          {ok, Record} = quod_directory_record:sign(
                           Pub, {<<"node-d">>, 5004}, hosted([A, B]),
                           1, 1, Signer),
          ?assertEqual(
             {error, not_allowed},
             quod_directory_control:test_ingest(
               Record, {relay, Relay})),
          ?assertEqual([], quod_directory:directory_hosts(A)),
          ?assertEqual(unknown, quod_directory:resolve(A))
      end).

public_reader_cannot_relay_or_push_captured_snapshot_test() ->
    {Author, Signer} = signer(),
    AllowlistedNonControl = key(41),
    Reader = key(42),
    ControlKey = key(43),
    Ns = <<"quod:published">>,
    RelayNs = <<"quod:relay">>,
    Endpoint = {<<"author">>, 5041},
    with_control(
      #{allowlist =>
            #{Ns => [Author],
              RelayNs => [AllowlistedNonControl]}},
      fun() ->
          Control = quod_reg:where({directory, control}),
          Channel = quod_directory_control:channel(),
          ok = quod_directory_control:test_set_control_peers(
                 [ControlKey]),
          {ok, Record} = quod_directory_record:sign(
                           Author, Endpoint, hosted(Ns), 1, 1, Signer),
          Announce = term_to_binary(
                       {quod_directory_announce, Record},
                       [deterministic]),
          Snapshot = term_to_binary(
                       {quod_directory_snapshot, [Record], done},
                       [deterministic]),

          %% A public reader is authenticated enough to request a snapshot,
          %% but has neither direct-author nor root-relay authority.
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

          %% Merely being allowlisted for another namespace does not grant
          %% relay authority for a third-party record.
          Control !
              {quod_message,
               {{AllowlistedNonControl,
                 {<<"non-control">>, 5043}}, self()},
               Channel, Announce},
          _ = sys:get_state(Control),
          ?assertEqual([], quod_directory:directory_hosts(Ns)),

          %% The exact same signed bytes are accepted from a current committed
          %% root control key.
          Control !
              {quod_message,
               {{ControlKey, {<<"control">>, 5044}}, self()},
               Channel, Announce},
          _ = sys:get_state(Control),
          ?assertEqual(
             [host(Ns, Author, <<"author">>, 5041)],
             quod_directory:directory_hosts(Ns))
      end).

root_peer_proof_result_validation_test() ->
    Peer = key(50),
    ?assertEqual(
       {ok, 7, #{Peer => true}},
       quod_directory_control:test_validate_peer_proof(
         {ok, [#{'DirectoryControlKeys' => [Peer]}], 7})),
    ?assertEqual(
       {ok, 8, #{}},
       quod_directory_control:test_validate_peer_proof(
         {ok, [#{'DirectoryControlKeys' => []}], 8})),
    ?assertEqual(
       {error, malformed_peer_keys},
       quod_directory_control:test_validate_peer_proof(
         {ok, [#{'DirectoryControlKeys' => [<<1>>, Peer]}], 9})),
    ?assertEqual(
       {error, malformed_peer_keys},
       quod_directory_control:test_validate_peer_proof(
         {ok, [#{'DirectoryControlKeys' => [Peer, Peer]}], 9})),
    ?assertEqual(
       {error, rebuilding},
       quod_directory_control:test_validate_peer_proof(
         {error, rebuilding})),
    ?assertEqual(
       {error, fail},
       quod_directory_control:test_validate_peer_proof(fail)),
    ?assertEqual(
       {error, fail},
       quod_directory_control:test_validate_peer_proof(
         {fail, [{directory_control_peer, unbound}]})).

successful_empty_replaces_failed_proof_retains_test() ->
    Peer = key(51),
    Endpoint = {<<"root-peer">>, 6051},
    with_control(
      #{},
      fun() ->
          Link = link_probe(self()),
          try
              ok = quod_directory_control:test_set_control_peers(
                     [Peer]),
              ok = quod_directory_control:test_set_control_link(
                     Peer, Endpoint, Link),
              ok = quod_directory_control:test_set_pending_link(
                     Peer, Endpoint, make_ref()),
              ok = quod_directory_control:test_apply_peer_result(
                     {error, rebuilding}),
              Failed =
                  quod_directory_control:test_control_state(),
              ?assertEqual(
                 #{Peer => true},
                 maps:get(control_peers, Failed)),
              ?assert(
                 maps:is_key(
                   Peer, maps:get(control_links, Failed))),
              ?assert(
                 maps:is_key(
                   Peer, maps:get(pending_links, Failed))),
              ?assertEqual(
                 {error, rebuilding},
                 maps:get(peer_status, Failed)),
              ?assertEqual(
                 ok, assert_no_link_close(Link)),

              ok = quod_directory_control:test_apply_peer_result(
                     {ok, 19, #{}}),
              Empty =
                  quod_directory_control:test_control_state(),
              ?assertEqual(
                 #{}, maps:get(control_peers, Empty)),
              ?assertEqual(
                 #{}, maps:get(control_links, Empty)),
              ?assertEqual(
                 #{}, maps:get(pending_links, Empty)),
              ?assertEqual(
                 19, maps:get(peer_height, Empty)),
              ?assertEqual(ok, maps:get(peer_status, Empty)),
              ?assertEqual(ok, wait_for_link_close(Link, 100))
          after
              exit(Link, kill)
          end
      end).

root_proof_worker_does_not_block_control_mailbox_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Parent = self(),
    Blocker =
        spawn(
          fun() ->
              true = quod_reg:reg(
                       {quod_prolog, <<"quod:root">>}),
              Parent ! root_blocker_ready,
              receive stop -> ok end
          end),
    receive root_blocker_ready -> ok end,
    try
        with_control(
          #{},
          fun() ->
              ?assertEqual(
                 ok,
                 wait_until(
                   fun() ->
                       maps:get(
                         root_proof_status,
                         quod_directory_control:stats())
                           =:= querying
                   end, 100)),
              {Micros, Stats} = timer:tc(
                                  quod_directory_control,
                                  stats, []),
              ?assert(is_map(Stats)),
              ?assert(Micros < 250000)
          end)
    after
        Blocker ! stop
    end.

snapshot_and_down_require_the_exact_current_link_test() ->
    {Author, Signer} = signer(),
    ControlKey = key(52),
    OtherKey = key(53),
    Ns = <<"quod:exact-link">>,
    Endpoint = {<<"exact-author">>, 5052},
    with_control(
      #{allowlist => #{Ns => [Author]}},
      fun() ->
          Control = quod_reg:where({directory, control}),
          Channel = quod_directory_control:channel(),
          OldLink = link_probe(self()),
          CurrentLink = link_probe(self()),
          OtherLink = link_sink(),
          try
              ok = quod_directory_control:test_set_control_peers(
                     [ControlKey]),
              ok = quod_directory_control:test_set_control_link(
                     ControlKey, {<<"old-control">>, 6052},
                     OldLink),
              OldState = quod_directory_control:test_control_state(),
              {_OldEndpoint, OldLink, OldMonitor} =
                  maps:get(
                    ControlKey,
                    maps:get(control_links, OldState)),
              ok = quod_directory_control:test_install_control_link(
                     ControlKey, {<<"current-control">>, 7052},
                     CurrentLink),
              CurrentState =
                  quod_directory_control:test_control_state(),
              CurrentEntry =
                  {_CurrentEndpoint, CurrentLink, CurrentMonitor} =
                  maps:get(
                    ControlKey,
                    maps:get(control_links, CurrentState)),
              ?assertEqual(
                 ok, wait_for_link_close(OldLink, 100)),
              ?assertEqual(
                 ok, wait_for_resync_cursor(
                       CurrentLink, 0, 100)),
              {ok, Record} = quod_directory_record:sign(
                               Author, Endpoint, hosted(Ns), 1, 1,
                               Signer),
              Snapshot = term_to_binary(
                           {quod_directory_snapshot,
                            [Record], 7},
                           [deterministic]),

              Control !
                  {quod_message,
                   {ControlKey, OldLink}, Channel, Snapshot},
              _ = sys:get_state(Control),
              ?assertEqual(
                 [], quod_directory:directory_hosts(Ns)),
              Control !
                  {quod_message,
                   {OtherKey, OtherLink}, Channel, Snapshot},
              _ = sys:get_state(Control),
              ?assertEqual(
                 [], quod_directory:directory_hosts(Ns)),
              Control !
                  {quod_message,
                   {ControlKey, CurrentLink}, Channel, Snapshot},
              _ = sys:get_state(Control),
              ?assertEqual(
                 [host(Ns, Author, <<"exact-author">>, 5052)],
                 quod_directory:directory_hosts(Ns)),
              ?assertEqual(
                 ok,
                 wait_for_resync_cursor(CurrentLink, 7, 100)),

              %% A retired link's stale DOWN cannot evict its replacement.
              Control !
                  {'DOWN', OldMonitor, process, OldLink, normal},
              _ = sys:get_state(Control),
              ?assertEqual(
                 CurrentEntry,
                 maps:get(
                   ControlKey,
                   maps:get(
                     control_links,
                     quod_directory_control:test_control_state()))),
              Control !
                  {'DOWN', CurrentMonitor, process,
                   CurrentLink, normal},
              _ = sys:get_state(Control),
              ?assertNot(
                 maps:is_key(
                   ControlKey,
                   maps:get(
                     control_links,
                     quod_directory_control:test_control_state())))
          after
              exit(OldLink, kill),
              exit(CurrentLink, kill),
              exit(OtherLink, kill)
          end
      end).

late_reused_link_and_dial_timeout_are_non_destructive_test() ->
    ControlKey = key(54),
    Endpoint = {<<"control">>, 7054},
    with_control(
      #{},
      fun() ->
          Control = quod_reg:where({directory, control}),
          Channel = quod_directory_control:channel(),
          Link = link_sink(),
          try
              ok = quod_directory_control:test_set_control_peers(
                     [ControlKey]),
              ok = quod_directory_control:test_set_control_link(
                     ControlKey, Endpoint, Link),
              Before = maps:get(
                         ControlKey,
                         maps:get(
                           control_links,
                           quod_directory_control:test_control_state())),
              _ = quod_quic:ensure_cache(),
              ok = quod_quic:learn(ControlKey, Endpoint),
              CurrentOpenRef = make_ref(),
              ok = quod_directory_control:test_set_pending_link(
                     ControlKey, Endpoint, CurrentOpenRef),
              Control !
                  {link_up, make_ref(), ControlKey, Channel, Link},
              _ = sys:get_state(Control),
              ?assertEqual(
                 Before,
                 maps:get(
                   ControlKey,
                   maps:get(
                     control_links,
                     quod_directory_control:test_control_state()))),
              ?assert(is_process_alive(Link)),
              ?assert(
                 maps:is_key(
                   ControlKey,
                   maps:get(
                     pending_links,
                     quod_directory_control:test_control_state()))),
              Control !
                  {link_up, CurrentOpenRef,
                   ControlKey, Channel, Link},
              _ = sys:get_state(Control),
              ?assertEqual(
                 Before,
                 maps:get(
                   ControlKey,
                   maps:get(
                     control_links,
                     quod_directory_control:test_control_state()))),
              ?assertEqual(
                 #{},
                 maps:get(
                   pending_links,
                   quod_directory_control:test_control_state())),
              ?assert(is_process_alive(Link)),

              OpenRef = make_ref(),
              ok = quod_directory_control:test_set_pending_link(
                     ControlKey, Endpoint, OpenRef),
              Control !
                  {directory_control_dial_timeout,
                   ControlKey, Endpoint, make_ref()},
              _ = sys:get_state(Control),
              ?assert(
                 maps:is_key(
                   ControlKey,
                   maps:get(
                     pending_links,
                     quod_directory_control:test_control_state()))),
              Control !
                  {directory_control_dial_timeout,
                   ControlKey, Endpoint, OpenRef},
              _ = sys:get_state(Control),
              ?assertEqual(
                 #{},
                 maps:get(
                   pending_links,
                   quod_directory_control:test_control_state())),
              ErrorRef = make_ref(),
              ok = quod_directory_control:test_set_pending_link(
                     ControlKey, Endpoint, ErrorRef),
              Control !
                  {link_error, ErrorRef, key(99), Channel},
              _ = sys:get_state(Control),
              ?assert(
                 maps:is_key(
                   ControlKey,
                   maps:get(
                     pending_links,
                     quod_directory_control:test_control_state()))),
              Control !
                  {link_error, ErrorRef, ControlKey, Channel},
              _ = sys:get_state(Control),
              ?assertEqual(
                 #{},
                 maps:get(
                   pending_links,
                   quod_directory_control:test_control_state())),
              ?assert(is_process_alive(Link))
          after
              exit(Link, kill)
          end
      end).

directory_owner_restart_requires_fresh_peer_lease_test() ->
    {Pub, Signer} = signer(),
    Ns = <<"quod:root">>,
    Opts = #{allowlist => #{Ns => [Pub]},
             expire_tick_ms => 60000, ttl_ms => 10000},
    {ok, _} = application:ensure_all_started(gproc),
    {ok, Directory0} = quod_directory:start_link(Opts),
    {ok, Control} = quod_directory_control:start_link(Opts),
    try
        {ok, Record} = quod_directory_record:sign(
                         Pub, {<<"node-e">>, 5005}, hosted(Ns),
                         1, 1, Signer),
        ok = quod_directory_control:test_ingest(
               Record,
               {direct, Pub, {<<"node-e">>, 5005}}),
        ?assertEqual(
           [host(Ns, Pub, <<"node-e">>, 5005)],
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
                          Pub, {<<"node-e">>, 5005}, hosted(Ns),
                          1, 2, Signer),
        ok = quod_directory_control:test_ingest(
               Renewal,
               {direct, Pub, {<<"node-e">>, 5005}}),
        ?assertEqual(
           ok,
           wait_until(
             fun() ->
                 quod_directory:directory_hosts(Ns)
                     =:= [host(Ns, Pub, <<"node-e">>, 5005)]
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
                           Pub, {<<"short-lived">>, 5007}, hosted(Ns),
                           1, 1, Signer),
          ok = quod_directory_control:test_ingest(
                 Record,
                 {direct, Pub, {<<"short-lived">>, 5007}}),
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

hosting_snapshot_is_bound_to_one_manager_epoch_test() ->
    with_control(
      #{},
      fun() ->
          OldManager = spawn(fun link_sink_loop/0),
          NewManager = spawn(fun link_sink_loop/0),
          try
              ok = quod_directory_control:test_set_manager_epoch(OldManager),
              ok = quod_directory_control:hosting_changed(
                     OldManager, 7, [<<"quod:old">>]),
              _ = sys:get_state(quod_reg:via({directory, control})),
              ?assertMatch(
                 #{hosting_revision := 7,
                   hosting_names := [<<"quod:old">>]},
                 quod_directory_control:test_control_state()),

              %% Registration of a replacement manager starts a new revision
              %% epoch. Late snapshots from the previous pid cannot cross it.
              ok = quod_directory_control:test_set_manager_epoch(NewManager),
              ok = quod_directory_control:hosting_changed(
                     OldManager, 100, [<<"quod:stale">>]),
              ok = quod_directory_control:hosting_changed(
                     NewManager, 1, [<<"quod:new">>]),
              _ = sys:get_state(quod_reg:via({directory, control})),
              ?assertMatch(
                 #{manager_pid := NewManager,
                   hosting_revision := 1,
                   hosting_names := [<<"quod:new">>]},
                 quod_directory_control:test_control_state())
          after
              exit(OldManager, kill),
              exit(NewManager, kill)
          end
      end).

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
                 expire_tick_ms => 60000, ttl_ms => 10000},
        {ok, _} = application:ensure_all_started(gproc),
        {ok, Directory0} = quod_directory:start_link(Opts),
        {ok, NsSup} = quod_ns_sup:start_link(),
        lists:foreach(
          fun(Ns) -> true = gproc:reg({n, l, {quod_ns, Ns}}) end,
          Private),
        AHost = start_hosted_namespace(A, validator),
        {ok, Control0} = quod_directory_control:start_link(Opts),
        try
            ok = quod_directory_control:test_set_hosting_snapshot(1, [A]),
            %% A snapshot before the application startup barrier cannot
            %% publish the partially booted hosted set.
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
                         =:= [host(A, Pub, <<"self">>, 5006)]
                 end, 100)),
            SequenceA = maps:get(
                          sequence, quod_directory_control:stats()),
            timer:sleep(5),
            stop_hosted_namespace(AHost),
            _BHost = start_hosted_namespace(B, observer),
            %% The manager snapshot is the hosted-set input. Renewal may
            %% re-read readiness, but never rediscover authority by scanning.
            ok = quod_directory_control:test_set_hosting_snapshot(2, [B]),
            Control0 ! directory_tick,
            ?assertEqual(
               ok,
               wait_until(
                 fun() ->
                     quod_directory:directory_hosts(A) =:= []
                         andalso quod_directory:directory_hosts(B)
                             =:= [host(B, Pub, <<"self">>, 5006)]
                 end, 100)),
            ?assert(
               maps:get(sequence, quod_directory_control:stats())
                   > SequenceA),
            {known, [BRoute]} = quod_directory:resolve(B),
            ?assertEqual(anchor(B), maps:get(genesis_anchor, BRoute)),
            ?assertEqual(observer, maps:get(role, BRoute)),
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
                         =:= [host(B, Pub, <<"self">>, 5006)]
                 end, 100)),

            %% A control-child restart must use the current registry under a
            %% fresh epoch, never its previous B advertisement.
            Epoch0 = maps:get(epoch, quod_directory_control:stats()),
            ok = gen_server:stop(Control0),
            stop_all_hosted_namespaces(),
            lists:foreach(
              fun(Ns) -> true = gproc:unreg({n, l, {quod_ns, Ns}}) end,
              Private),
            _AHost2 = start_hosted_namespace(A, validator),
            {ok, _Control1} = quod_directory_control:start_link(Opts),
            %% A real control restart obtains this complete snapshot from the
            %% registered namespace manager. This isolated test installs the
            %% same manager-epoch input explicitly.
            ok = quod_directory_control:test_set_hosting_snapshot(3, [A]),
            ?assertEqual(
               ok,
               wait_until(
                 fun() ->
                     quod_directory:directory_hosts(A)
                         =:= [host(A, Pub, <<"self">>, 5006)]
                         andalso quod_directory:directory_hosts(B) =:= []
                 end, 100)),
            ?assert(
               maps:get(epoch, quod_directory_control:stats()) > Epoch0)
        after
            stop_all_hosted_namespaces(),
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
    Common = maps:merge(#{expire_tick_ms => 60000, ttl_ms => 10000}, Opts),
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

hosted(Ns) when is_binary(Ns) ->
    [{Ns, anchor(Ns), validator}];
hosted(Namespaces) when is_list(Namespaces) ->
    [{Ns, anchor(Ns), validator} || Ns <- Namespaces].

host(Ns, NodeKey, Hostname, Port) ->
    {anchor(Ns), NodeKey, Hostname, Port}.

anchor(Ns) ->
    crypto:hash(sha256, Ns).

start_hosted_namespace(Ns, Role) ->
    Parent = self(),
    Pid = spawn(
            fun() ->
                true = gproc:reg({n, l, {quod_ns, Ns}}),
                true = gproc:reg({n, l, {quod_simplex, Ns}}),
                true = gproc:reg({n, l, {quod_prolog, Ns}}),
                Table = binary_to_atom(
                          <<"quod_simplex_genesis_", Ns/binary>>, utf8),
                _ = ets:new(Table, [named_table, protected, set]),
                true = ets:insert(Table, {anchor, anchor(Ns)}),
                Parent ! {hosted_namespace_ready, self()},
                hosted_namespace_loop(Role)
            end),
    receive
        {hosted_namespace_ready, Pid} -> ok
    after 1000 ->
        erlang:error(hosted_namespace_start_timeout)
    end,
    Existing = case get(hosted_namespace_pids) of
                   undefined -> [];
                   Pids -> Pids
               end,
    put(hosted_namespace_pids, [Pid | Existing]),
    Pid.

hosted_namespace_loop(Role) ->
    receive
        {'$gen_call', From, get_status} ->
            gen:reply(From, #{role => Role}),
            hosted_namespace_loop(Role);
        stop ->
            ok
    end.

stop_hosted_namespace(Pid) ->
    Ref = monitor(process, Pid),
    Pid ! stop,
    receive
        {'DOWN', Ref, process, Pid, _Reason} -> ok
    after 1000 ->
        erlang:error(hosted_namespace_stop_timeout)
    end.

stop_all_hosted_namespaces() ->
    Pids = erase(hosted_namespace_pids),
    lists:foreach(
      fun(Pid) when is_pid(Pid) ->
              case is_process_alive(Pid) of
                  true -> stop_hosted_namespace(Pid);
                  false -> ok
              end
      end,
      case Pids of undefined -> []; _ -> Pids end).

flip_last_byte(Binary) ->
    PrefixSize = byte_size(Binary) - 1,
    <<Prefix:PrefixSize/binary, Last>> = Binary,
    <<Prefix/binary, (Last bxor 1)>>.

tamper_signature(Record) ->
    {quod_directory_record, 2, Body, Signature} =
        binary_to_term(Record, [safe]),
    term_to_binary(
      {quod_directory_record, 2, Body,
       flip_last_byte(Signature)},
      [deterministic]).

link_sink() ->
    spawn(fun link_sink_loop/0).

link_sink_loop() ->
    receive
        _Message -> link_sink_loop()
    end.

link_probe(Parent) ->
    spawn(fun() -> link_probe_loop(Parent) end).

link_probe_loop(Parent) ->
    receive
        Message ->
            Parent ! {link_probe, self(), Message},
            link_probe_loop(Parent)
    end.

wait_for_resync_cursor(_Link, _Cursor, 0) ->
    timeout;
wait_for_resync_cursor(Link, Cursor, Retries) ->
    receive
        {link_probe, Link, {send, Payload}} ->
            case quod_directory_control:decode_control(Payload) of
                {resync_request, Cursor} ->
                    ok;
                _ ->
                    wait_for_resync_cursor(
                      Link, Cursor, Retries - 1)
            end
    after 10 ->
        wait_for_resync_cursor(Link, Cursor, Retries - 1)
    end.

wait_for_announce(_Link, _Record, 0) ->
    timeout;
wait_for_announce(Link, Record, Retries) ->
    receive
        {link_probe, Link, {send, Payload}} ->
            case quod_directory_control:decode_control(Payload) of
                {announce, Record} ->
                    ok;
                _ ->
                    wait_for_announce(
                      Link, Record, Retries - 1)
            end
    after 10 ->
        wait_for_announce(Link, Record, Retries - 1)
    end.

assert_no_announce(Link) ->
    receive
        {link_probe, Link, {send, Payload}} ->
            case quod_directory_control:decode_control(Payload) of
                {announce, _Record} ->
                    erlang:error(unexpected_announcement_echo);
                _ ->
                    assert_no_announce(Link)
            end
    after 30 ->
        ok
    end.

wait_for_link_close(_Link, 0) ->
    timeout;
wait_for_link_close(Link, Retries) ->
    receive
        {link_probe, Link, close} ->
            ok;
        {link_probe, Link, _Other} ->
            wait_for_link_close(Link, Retries - 1)
    after 10 ->
        wait_for_link_close(Link, Retries - 1)
    end.

assert_no_link_close(Link) ->
    receive
        {link_probe, Link, close} ->
            erlang:error(link_closed_on_failed_proof)
    after 30 ->
        ok
    end.

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

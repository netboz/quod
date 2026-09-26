-module(quod_feed_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

era_feed_receipts_coalesce_without_authorizing_or_replaying_history_test() ->
    F = #{identity := {Ns, Anchor}} = quod_ct:protocol_fixture(<<"feed:streamed-live">>),
    Peer = <<92:256>>, Worker = self(), Chan = quod_feed:channel(Ns),
    S0 = quod_feed:test_pull_state(Worker, 3, quod_feed:test_set_snapshot(
      {1, maps:get(projection, F), false}, quod_feed:test_recipient_state(Ns, Anchor))),
    Receive = fun(Height, State) ->
        Entry = feed_entry(Height),
        {noreply, Next} = quod_feed:handle_info(
            {quod_message, {{Peer, ignored}, self()}, Chan, quod_feed:encode(Ns, {block, Entry})}, State),
        Next
    end,
    ?assertEqual({none, Worker}, quod_feed:test_received(Receive(1, S0))),
    Cold = quod_feed:test_set_snapshot({0, maps:get(projection, F), true}, S0),
    ?assertEqual({none, Worker}, quod_feed:test_received(Receive(1, Cold))),
    S1 = Receive(2, S0), S2 = Receive(3, S1),
    ?assertEqual({{2, 3, Peer}, Worker}, quod_feed:test_received(S2)),
    %% A future gap, duplicate or malformed frame grants no wider live range.
    ?assertEqual({{2, 3, Peer}, Worker}, quod_feed:test_received(Receive(5, Receive(3, S2)))),
    {reply, {live, 2, 3}, S2} = quod_feed:handle_call(pull_live_interval, {Worker, make_ref()}, S2),
    Other = spawn(fun() -> receive stop -> ok end end),
    {reply, {error, unknown_call}, S2} =
        quod_feed:handle_call(pull_live_interval, {Other, make_ref()}, S2),
    Other ! stop,
    {noreply, S3} = quod_feed:handle_info({certified_head, Ns, 2}, S2),
    ?assertEqual({{3, 3, Peer}, Worker}, quod_feed:test_received(S3)),
    {noreply, S4} = quod_feed:handle_info({certified_head, Ns, 3}, S3),
    ?assertEqual({none, Worker}, quod_feed:test_received(S4)),
    Captured = quod_feed:test_set_snapshot({3, maps:get(projection, F), false}, S4),
    ?assertEqual({none, Worker}, quod_feed:test_received(Receive(1, Receive(3, Captured)))),
    %% A terminated attempt with no new receipt cannot restart itself.
    {noreply, S5} = quod_feed:handle_info({'DOWN', make_ref(), process, Worker, failed}, S4),
    ?assertEqual({none, false}, quod_feed:test_received(S5)),
    {noreply, Replay} = quod_feed:handle_info({certified_head, Ns, 9},
      quod_feed:test_recipient_state(Ns, Anchor)),
    ?assertEqual({none, false}, quod_feed:test_received(Replay)).

feed_entry(1) ->
    F = quod_ct:protocol_fixture(<<"feed:codec">>),
    quod_ledger:entry(1, maps:get(genesis, F), none);
feed_entry(Height) ->
    F = quod_ct:protocol_fixture(<<"feed:codec">>),
    {ok, B} = quod_ledger:new_block({maps:get(era, F), Height},
      maps:get(protocol_root, maps:get(projection, F)), Height, {batch, [maps:get(transaction, F)]}, 1),
    quod_ledger:entry(Height, B, quod_ct:protocol_certificate(B, F)).

%%%===================================================================
%%% wire: encode/decode roundtrip + defensive rejects
%%%===================================================================

roundtrip_test() ->
    Ns = <<"quod:root">>,
    E = feed_entry(7),
    Payload = quod_feed:encode(Ns, {block, E}),
    ?assertEqual({block, E}, quod_feed:decode(Payload, Ns)),
    {feed, Ns, Inner} = binary_to_term(Payload, [safe]),
    {block_bytes, EntryBlob} = binary_to_term(Inner, [safe]),
    ?assertEqual({ok, E}, quod_ledger:decode_entry(EntryBlob)).

decode_wrong_ns_test() ->
    E = feed_entry(1),
    Payload = quod_feed:encode(<<"a">>, {block, E}),
    ?assertEqual(error, quod_feed:decode(Payload, <<"b">>)).

decode_garbage_test() ->
    ?assertEqual(error, quod_feed:decode(<<0, 1, 2, 3>>, <<"quod:root">>)),
    ?assertEqual(error, quod_feed:decode(term_to_binary({not_feed, x}), <<"quod:root">>)).

progress_signal_checks_only_the_safe_namespace_envelope_test() ->
    Ns = <<"feed:progress">>,
    %% A progress observer deliberately leaves even malformed canonical-entry
    %% blobs opaque: this signal is only a wake, never evidence.
    Block = term_to_binary(
              {feed, Ns,
               term_to_binary({block_bytes, <<131, 100, 0, 13,
                                                    "unknown_atom">>},
                              [deterministic])},
              [deterministic]),
    Digest = quod_feed:encode(Ns, {digest, 7}),
    ?assert(quod_feed:progress_signal(Block, Ns)),
    ?assert(quod_feed:progress_signal(Digest, Ns)),
    ?assertNot(quod_feed:progress_signal(Block, <<"feed:other">>)),
    ?assertNot(quod_feed:progress_signal(<<0, 1, 2>>, Ns)),
    ?assertEqual({ok, 7}, quod_feed:progress_height(Digest, Ns)),
    ?assertEqual(unknown, quod_feed:progress_height(Block, Ns)),
    ?assertEqual(error, quod_feed:progress_height(Digest, <<"feed:other">>)),
    %% The wake parser never decodes the inner term.  Even malformed inner
    %% bytes are only a harmless wake for the certified verifier.
    OuterOnly = term_to_binary({feed, Ns, <<0, 1, 2>>}),
    ?assert(quod_feed:progress_signal(OuterOnly, Ns)).

recipient_control_codec_is_bounded_and_namespace_exact_test() ->
    Ns = <<"feed:recipient">>,
    Anchor = <<1:256>>,
    RegistrationId = <<2:128>>,
    Register = quod_feed:recipient_register_frame(
                 Ns, Anchor, RegistrationId),
    Ack = quod_feed:recipient_ack_frame(
            Ns, Anchor, RegistrationId, 17),
    Unregister = quod_feed:recipient_unregister_frame(
                   Ns, Anchor, RegistrationId),
    ?assertEqual(
       {register, RegistrationId, Anchor},
       quod_feed:decode_recipient(Register, Ns)),
    ?assertEqual(
       {ack, RegistrationId, Anchor, 17},
       quod_feed:decode_recipient(Ack, Ns)),
    ?assertEqual(
       {unregister, RegistrationId, Anchor},
       quod_feed:decode_recipient(Unregister, Ns)),
    ?assertEqual(error, quod_feed:decode_recipient(Register, <<"other">>)),
    ?assertEqual(
       error,
       quod_feed:decode_recipient(
         quod_feed:encode(
           Ns, {recipient_wake, 2, RegistrationId, Anchor, 18}), Ns)),
    ?assertEqual(
       error,
       quod_feed:decode_recipient(
         quod_feed:encode(
           Ns, {recipient_wake, 1, <<3:120>>, Anchor, 18}), Ns)),
    ?assertEqual(
       error,
       quod_feed:decode_recipient(
         quod_feed:encode(
           Ns, {recipient_wake, 1, RegistrationId, Anchor, -1}), Ns)).

recipient_late_commits_coalesce_behind_one_ordered_wake_test() ->
    Ns = <<"feed:recipient-coalesce">>,
    Anchor = <<4:256>>,
    Peer = <<5:256>>,
    RegistrationId = <<6:128>>,
    Link = fake_link(),
    S0 = quod_feed:test_recipient_state(Ns, Anchor),
    S1 = quod_feed:test_recipient_control(
           Peer, Link, {register, RegistrationId, Anchor}, 7, S0),
    ?assertEqual(
       {registered, RegistrationId, Anchor, 7},
       receive_control(Link, Ns)),
    ?assertEqual(1, fake_link_send_count(Link)),

    %% An exact duplicate on the same reliable ordered link is the same
    %% registration.  It creates neither another monitor nor another frame.
    S1Again = quod_feed:test_recipient_control(
                Peer, Link, {register, RegistrationId, Anchor}, 7, S1),
    ?assertEqual(quod_feed:test_recipient_rows(S1),
                 quod_feed:test_recipient_rows(S1Again)),
    ?assertEqual(1, fake_link_send_count(Link)),

    %% The initial registered height is still awaiting acknowledgement.  Any
    %% number of later commits becomes one newest pending height.
    S2 = quod_feed:test_recipient_commit(8, S1Again),
    S3 = quod_feed:test_recipient_commit(9, S2),
    Row3 = maps:get(Peer, quod_feed:test_recipient_rows(S3)),
    ?assertEqual(7, maps:get(in_flight, Row3)),
    ?assertEqual(9, maps:get(pending_height, Row3)),
    ?assertEqual(1, fake_link_send_count(Link)),

    %% Crossed acknowledgement shapes cannot release or advance this row.
    WrongLink = fake_link(),
    ?assertEqual(
       quod_feed:test_recipient_rows(S3),
       quod_feed:test_recipient_rows(
         quod_feed:test_recipient_control(
           Peer, WrongLink, {ack, RegistrationId, Anchor, 7}, ignored, S3))),
    ?assertEqual(
       quod_feed:test_recipient_rows(S3),
       quod_feed:test_recipient_rows(
         quod_feed:test_recipient_control(
           <<13:256>>, Link, {ack, RegistrationId, Anchor, 7}, ignored, S3))),
    ?assertEqual(
       quod_feed:test_recipient_rows(S3),
       quod_feed:test_recipient_rows(
         quod_feed:test_recipient_control(
           Peer, Link, {ack, <<7:128>>, Anchor, 7}, ignored, S3))),
    ?assertEqual(
       quod_feed:test_recipient_rows(S3),
       quod_feed:test_recipient_rows(
         quod_feed:test_recipient_control(
           Peer, Link, {ack, RegistrationId, Anchor, 8}, ignored, S3))),

    S4 = quod_feed:test_recipient_control(
           Peer, Link, {ack, RegistrationId, Anchor, 7}, ignored, S3),
    ?assertEqual(
       {wake, RegistrationId, Anchor, 9},
       receive_control(Link, Ns)),
    Row4 = maps:get(Peer, quod_feed:test_recipient_rows(S4)),
    ?assertEqual(9, maps:get(in_flight, Row4)),
    ?assertEqual(none, maps:get(pending_height, Row4)),

    S5 = quod_feed:test_recipient_control(
           Peer, Link, {ack, RegistrationId, Anchor, 9}, ignored, S4),
    Row5 = maps:get(Peer, quod_feed:test_recipient_rows(S5)),
    ?assertEqual(none, maps:get(in_flight, Row5)),
    S6 = quod_feed:test_recipient_commit(10, S5),
    ?assertEqual(
       {wake, RegistrationId, Anchor, 10},
       receive_control(Link, Ns)),

    _ = quod_feed:test_recipient_control(
          Peer, Link, {unregister, RegistrationId, Anchor}, ignored, S6),
    receive {feed_link, Link, closed} -> ok after 1000 -> error(close_timeout) end,
    fake_link_stop(WrongLink).

recipient_registration_replaces_one_peer_row_and_tracks_link_death_test() ->
    Ns = <<"feed:recipient-lifecycle">>,
    Anchor = <<8:256>>,
    WrongAnchor = <<9:256>>,
    Peer = <<10:256>>,
    RegistrationId1 = <<11:128>>,
    RegistrationId2 = <<12:128>>,
    Link1 = fake_link(),
    Link2 = fake_link(),
    S0 = quod_feed:test_recipient_state(Ns, Anchor),

    %% The target anchor is part of the exact registration identity.
    SBad = quod_feed:test_recipient_control(
             Peer, Link1, {register, RegistrationId1, WrongAnchor}, 3, S0),
    ?assertEqual(#{}, quod_feed:test_recipient_rows(SBad)),
    ?assertEqual(0, fake_link_send_count(Link1)),

    S1 = quod_feed:test_recipient_control(
           Peer, Link1, {register, RegistrationId1, Anchor}, 3, SBad),
    ?assertEqual(
       {registered, RegistrationId1, Anchor, 3},
       receive_control(Link1, Ns)),
    S2 = quod_feed:test_recipient_control(
           Peer, Link2, {register, RegistrationId2, Anchor}, 4, S1),
    receive {feed_link, Link1, closed} -> ok after 1000 -> error(close_timeout) end,
    ?assertEqual(
       {registered, RegistrationId2, Anchor, 4},
       receive_control(Link2, Ns)),
    #{Peer := Row2} = quod_feed:test_recipient_rows(S2),
    ?assertEqual(Link2, maps:get(link, Row2)),
    ?assertEqual(RegistrationId2, maps:get(registration_id, Row2)),

    MRef = maps:get(monitor, Row2),
    exit(Link2, kill),
    receive
        {'DOWN', MRef, process, Link2, Reason} ->
            S3 = quod_feed:test_recipient_down(MRef, Link2, S2),
            ?assertEqual(#{}, quod_feed:test_recipient_rows(S3)),
            ?assertEqual(killed, Reason)
    after 1000 ->
        error(down_timeout)
    end.

certified_catchup_head_wakes_recipients_without_a_block_replay_test() ->
    Ns = <<"feed:certified-head">>,
    Anchor = <<14:256>>,
    Peer = <<15:256>>,
    RegistrationId = <<16:128>>,
    Link = fake_link(),
    StaleProjection = quod_simplex:history_projection(),
    S0 = quod_feed:test_set_snapshot(
           {20, StaleProjection, false},
           quod_feed:test_recipient_state(Ns, Anchor)),
    S1 = quod_feed:test_recipient_control(
           Peer, Link, {register, RegistrationId, Anchor}, 20, S0),
    ?assertEqual(
       {registered, RegistrationId, Anchor, 20},
       receive_control(Link, Ns)),
    S2 = quod_feed:test_recipient_control(
           Peer, Link, {ack, RegistrationId, Anchor, 20}, ignored, S1),

    %% This is only a certified-height freshness signal.  It queues the same
    %% correlated wake as a live commit, without needing or re-publishing an
    %% historical #entry{}.
    {noreply, S3} = quod_feed:handle_info(
                      {certified_head, Ns, 24}, S2),
    ?assertEqual(
       {wake, RegistrationId, Anchor, 24},
       receive_control(Link, Ns)),
    Row = maps:get(Peer, quod_feed:test_recipient_rows(S3)),
    ?assertEqual(24, maps:get(in_flight, Row)),
    %% The signal has no entry to fold, so retaining the old height would let a
    %% later registration receive stale state.  The single snapshot owner is
    %% invalidated and will refresh from Simplex on that next read.
    ?assertEqual(none, quod_feed:test_snapshot(S3)),
    fake_link_stop(Link).

feed_start_resets_a_registration_lost_before_subscription_test() ->
    ok = ensure_registry(),
    Ns = <<"feed:start-reset">>,
    Anchor = <<17:256>>,
    Peer = <<18:256>>,
    RegistrationId = <<19:128>>,
    Chan = quod_feed:channel(Ns),
    with_feed_anchor(
      Ns, Anchor,
      fun() ->
          OldLink = fake_link(),
          OldMRef = monitor(process, OldLink),
          %% This is the real race: the authenticated link and its one-shot
          %% registration exist before a feed owner subscribes, so the property
          %% publication has no recipient and is lost.
          publish_recipient_registration(
            Chan, Ns, Peer, OldLink, Anchor, RegistrationId),
          ?assertEqual(0, fake_link_send_count(OldLink)),
          Conn = fake_channel_conn(Chan, OldLink),
          Feed = start_test_feed(Ns),
          try
              {Subscribers, OldLink} = receive_feed_channel_reset(Conn, Chan),
              %% The reset must be issued after subscription.  Otherwise a
              %% reconnect could deliver its replacement registration into the
              %% same gap and this test would remain wedged.
              ?assert(lists:member(Feed, Subscribers)),
              receive
                  {feed_link, OldLink, closed} -> ok
              after 1000 ->
                  error(old_link_not_reset)
              end,
              receive
                  {'DOWN', OldMRef, process, OldLink, normal} -> ok
              after 1000 ->
                  error(old_link_still_alive)
              end,

              NewLink = fake_link(),
              publish_recipient_registration(
                Chan, Ns, Peer, NewLink, Anchor, RegistrationId),
              ?assertEqual(
                 {registered, RegistrationId, Anchor, 0},
                 receive_control(NewLink, Ns)),
              ?assertEqual(1, maps:get(recipients, quod_feed:stats(Ns)))
          after
              stop_test_feed(Feed),
              fake_channel_conn_stop(Conn)
          end
      end).

feed_restart_resets_the_surviving_registered_link_test() ->
    ok = ensure_registry(),
    Ns = <<"feed:restart-reset">>,
    Anchor = <<20:256>>,
    Peer = <<21:256>>,
    RegistrationId = <<22:128>>,
    Chan = quod_feed:channel(Ns),
    with_feed_anchor(
      Ns, Anchor,
      fun() ->
          Conn = fake_channel_conn(Chan, none),
          Feed1 = start_test_feed(Ns),
          {Subscribers1, none} = receive_feed_channel_reset(Conn, Chan),
          ?assert(lists:member(Feed1, Subscribers1)),
          OldLink = fake_link(),
          ok = fake_channel_conn_track(Conn, OldLink),
          publish_recipient_registration(
            Chan, Ns, Peer, OldLink, Anchor, RegistrationId),
          ?assertEqual(
             {registered, RegistrationId, Anchor, 0},
             receive_control(OldLink, Ns)),
          ?assertEqual(1, maps:get(recipients, quod_feed:stats(Ns))),

          FeedMRef = monitor(process, Feed1),
          exit(Feed1, kill),
          receive
              {'DOWN', FeedMRef, process, Feed1, killed} -> ok
          after 1000 ->
              error(feed_did_not_die)
          end,
          %% The transport owns the inbound link independently; killing the old
          %% feed does not kill it or recreate its already-consumed registration.
          ?assert(is_process_alive(OldLink)),
          OldMRef = monitor(process, OldLink),

          Feed2 = start_test_feed(Ns),
          try
              {Subscribers2, OldLink} =
                  receive_feed_channel_reset(Conn, Chan),
              ?assert(lists:member(Feed2, Subscribers2)),
              receive
                  {feed_link, OldLink, closed} -> ok
              after 1000 ->
                  error(surviving_link_not_reset)
              end,
              receive
                  {'DOWN', OldMRef, process, OldLink, normal} -> ok
              after 1000 ->
                  error(surviving_link_still_alive)
              end,

              NewLink = fake_link(),
              publish_recipient_registration(
                Chan, Ns, Peer, NewLink, Anchor, RegistrationId),
              ?assertEqual(
                 {registered, RegistrationId, Anchor, 0},
                 receive_control(NewLink, Ns)),
              ?assertEqual(1, maps:get(recipients, quod_feed:stats(Ns)))
          after
              stop_test_feed(Feed2),
              fake_channel_conn_stop(Conn)
          end
      end).

%%%===================================================================
%%% peer_ready — the passive liveness verdict (fresh / stale / height slack)
%%%===================================================================

%% ready/4 is the pure classification: digest age ≤ 15 s AND height within one pull window (256) of
%% the judge's applied height.
ready_test_() ->
    Now = 100000,
    [ ?_assert(quod_feed:ready(50, Now, Now, 50)),            %% fresh, at the judge's height
      ?_assert(quod_feed:ready(50, Now - 15000, Now, 50)),    %% freshness boundary (inclusive)
      ?_assertNot(quod_feed:ready(50, Now - 15001, Now, 50)), %% one ms past: a dead/mute peer
      ?_assert(quod_feed:ready(50, Now, Now, 306)),           %% exactly one window (256) behind: ok
      ?_assertNot(quod_feed:ready(50, Now, Now, 307)),        %% beyond one window: too far behind
      ?_assert(quod_feed:ready(0, Now, Now, 0)) ].            %% fresh empty follower vs fresh judge

%% The table path peer_ready/3 reads: record → ready; unknown pubkey and non-pubkey ids are never ready.
peer_ready_table_test() ->
    Ns = <<"feed:ready">>,
    T  = ets:new(quod_feed:digest_table(Ns), [named_table, public, set]),
    ?assertNot(quod_feed:peer_ready(Ns, <<1>>, 0)),             %% no digest ever recorded
    true = quod_feed:record_digest(T, <<1>>, 7),
    ?assert(quod_feed:peer_ready(Ns, <<1>>, 7)),
    ?assert(quod_feed:peer_ready(Ns, <<1>>, 7 + 256)),          %% slack: one window behind the judge
    ?assertNot(quod_feed:peer_ready(Ns, <<1>>, 7 + 257)),
    true = quod_feed:record_digest(T, {"127.0.0.1", 1}, 9),     %% test/no-identity id: not tracked
    ?assertEqual([], ets:lookup(T, {"127.0.0.1", 1})),
    ets:delete(T).

%% No table at all (the feed is down/restarting, or never created): fail closed, never crash the proving
%% process. binary_to_existing_atom on a name whose table was never made throws badarg -> caught -> false.
peer_ready_no_table_test() ->
    ?assertNot(quod_feed:peer_ready(<<"feed:absent">>, <<1>>, 0)).

%%%===================================================================
%%% readiness_config_ok — the freshness↔digest-period boot guard
%%%===================================================================

%% The window (15000) must span at least two digest periods, so a node that digests too slowly (and could
%% never stay fresh enough to be admitted) is refused at boot instead of silently wedging committee growth.
readiness_config_test_() ->
    [ ?_assertEqual(ok, quod_feed:readiness_config_ok(3000)),            %% default: 5 periods fit
      ?_assertEqual(ok, quod_feed:readiness_config_ok(7500)),            %% boundary: window spans exactly 2
      ?_assertMatch({error, _}, quod_feed:readiness_config_ok(7501)),    %% one ms too slow
      ?_assertMatch({error, _}, quod_feed:readiness_config_ok(600000)) ].%% feed_SUITE's runtime push-isolation value

%%%===================================================================
%%% fold_snapshot/3 — the cached consensus snapshot advance (contiguity-guarded)
%%%===================================================================

%% The cache folds ordinary material, including a real empty-diff action;
%% empty protocol carriers have no material entry to give this cache.
fold_snapshot_test() ->
    F = #{identity := {Ns, Anchor}, signer := Signer, era := Era, projection := P,
          transaction := Tx} = quod_ct:protocol_fixture(<<"feed:fold">>),
    Pub = maps:get(pubkey, Signer), Added = <<25:256>>,
    Root = maps:get(protocol_root, P),
    {ok, B} = quod_ledger:new_block({Era, 1}, Root, 2, {batch, [Tx]}, 1),
    EmptyDiff = quod_ledger:entry(2, B, quod_ct:protocol_certificate(B, F)),
    {2, Ordinary, false} = quod_feed:fold_snapshot(Ns, EmptyDiff, {1, P, false}),
    ?assertEqual([Pub], quod_simplex:history_committee(Ordinary)),
    Unsigned = quod_transaction:bind_id({Ns, Anchor}, Tx#transaction{
      diff = [{assert, {{peer_admitted, Added, <<"host">>, 1, Added}, true}}],
      sig = none, signed_bytes = none, authentication = none}),
    {ok, Admit} = quod_transaction:sign({Ns, Anchor, maps:get(admission, F)}, Unsigned, Signer),
    {ok, M} = quod_ledger:new_block({Era, 1}, Root, 2, {batch, [Admit]}, 1),
    Membership = quod_ledger:entry(2, M, quod_ct:protocol_certificate(M, F)),
    {2, Admitted, false} = quod_feed:fold_snapshot(Ns, Membership, {1, P, false}),
    ?assertEqual(lists:sort([Pub, Added]), quod_simplex:history_committee(Admitted)),
    ?assertEqual(none, quod_feed:fold_snapshot(Ns, EmptyDiff, {0, P, false})),
    ?assertEqual(none, quod_feed:fold_snapshot(Ns, EmptyDiff, {2, Ordinary, false})),
    {ok, Control} = quod_ledger:new_block({Era, 1}, Root, 2, quod_ct:atomic_resolve_payload(), 1),
    Dtx = quod_ledger:entry(2, Control, quod_ct:protocol_certificate(Control, F)),
    ?assertEqual(none, quod_feed:fold_snapshot(Ns, Dtx, {1, P, false})),
    ?assertEqual(none, quod_feed:fold_snapshot(Ns, EmptyDiff, none)).

fake_link() ->
    Owner = self(),
    spawn(fun() -> fake_link_loop(Owner, 0) end).

fake_link_loop(Owner, SendCount) ->
    receive
        {send_ordered, Frame} ->
            Owner ! {feed_link, self(), {send_ordered, Frame}},
            fake_link_loop(Owner, SendCount + 1);
        {send_count, From, Ref} ->
            From ! {Ref, SendCount},
            fake_link_loop(Owner, SendCount);
        close ->
            Owner ! {feed_link, self(), closed};
        stop ->
            ok
    end.

fake_link_send_count(Link) ->
    Ref = make_ref(),
    Link ! {send_count, self(), Ref},
    receive {Ref, Count} -> Count after 1000 -> error(count_timeout) end.

fake_link_stop(Link) ->
    Link ! stop,
    ok.

receive_control(Link, Ns) ->
    receive
        {feed_link, Link, {send_ordered, Frame}} ->
            quod_feed:decode_recipient(Frame, Ns)
    after 1000 ->
        error(control_timeout)
    end.

with_feed_anchor(Ns, Anchor, Fun) ->
    Name = binary_to_atom(<<"quod_simplex_genesis_", Ns/binary>>, utf8),
    Table = ets:new(Name, [named_table, protected, set]),
    true = ets:insert(Table, {anchor, Anchor}),
    try Fun()
    after
        ets:delete(Table)
    end.

ensure_registry() ->
    case application:ensure_all_started(gproc) of
        {ok, _} -> ok;
        {error, {already_started, gproc}} -> ok
    end.

start_test_feed(Ns) ->
    {ok, Feed} = quod_feed:start_link(
                   Ns,
                   #{node_id => <<23:256>>,
                     data_dir => "/tmp/quod-feed-owner-tests"}),
    unlink(Feed),
    Feed.

stop_test_feed(Feed) ->
    case is_process_alive(Feed) of
        true -> gen_server:stop(Feed);
        false -> ok
    end.

publish_recipient_registration(
  Chan, Ns, Peer, Link, Anchor, RegistrationId) ->
    _ = quod_reg:publish(
          {channel, Chan},
          {quod_message,
           {{Peer, {"127.0.0.1", 1}}, Link},
           Chan,
           quod_feed:recipient_register_frame(
             Ns, Anchor, RegistrationId)}),
    ok.

fake_channel_conn(Chan, Link) ->
    Owner = self(),
    Conn = spawn(
             fun() ->
                 true = quod_reg:subscribe({connections, local}),
                 Owner ! {fake_channel_conn_ready, self()},
                 fake_channel_conn_loop(Owner, Chan, Link)
             end),
    receive
        {fake_channel_conn_ready, Conn} -> Conn
    after 1000 ->
        error(fake_channel_conn_start_timeout)
    end.

fake_channel_conn_loop(Owner, Chan, Link) ->
    receive
        {reset_inbound_channel, Chan} ->
            Subscribers =
                gproc:lookup_pids(quod_reg:prop({channel, Chan})),
            case Link of
                Pid when is_pid(Pid) -> quod_link:close(Pid);
                none -> ok
            end,
            Owner ! {feed_channel_reset, self(), Chan,
                     Subscribers, Link},
            fake_channel_conn_loop(Owner, Chan, none);
        {track, NewLink, From, Ref} when is_pid(NewLink) ->
            From ! {Ref, tracked},
            fake_channel_conn_loop(Owner, Chan, NewLink);
        stop ->
            ok;
        _Other ->
            fake_channel_conn_loop(Owner, Chan, Link)
    end.

fake_channel_conn_track(Conn, Link) ->
    Ref = make_ref(),
    Conn ! {track, Link, self(), Ref},
    receive
        {Ref, tracked} -> ok
    after 1000 ->
        error(fake_channel_conn_track_timeout)
    end.

fake_channel_conn_stop(Conn) ->
    Conn ! stop,
    ok.

receive_feed_channel_reset(Conn, Chan) ->
    receive
        {feed_channel_reset, Conn, Chan, Subscribers, Link} ->
            {Subscribers, Link}
    after 1000 ->
        error(feed_channel_reset_timeout)
    end.

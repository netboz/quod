-module(quod_feed_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

%%%===================================================================
%%% classify/2 — the ordering decision (drop / take-next / gap)
%%%===================================================================

classify_test_() ->
    [ ?_assertEqual(duplicate, quod_feed:classify(1, 5)),   %% below our height
      ?_assertEqual(duplicate, quod_feed:classify(5, 5)),   %% exactly our height
      ?_assertEqual(next,      quod_feed:classify(6, 5)),   %% the contiguous next block (fast path)
      ?_assertEqual(gap,       quod_feed:classify(7, 5)),   %% ahead ⇒ out of order (F2 anti-entropy)
      ?_assertEqual(next,      quod_feed:classify(1, 0)) ]. %% genesis onto an empty follower

%%%===================================================================
%%% wire: encode/decode roundtrip + defensive rejects
%%%===================================================================

roundtrip_test() ->
    Ns = <<"quod:root">>,
    E = quod_ledger:noop_entry(7, none),
    Payload = quod_feed:encode(Ns, {block, E}),
    ?assertEqual({block, E}, quod_feed:decode(Payload, Ns)),
    {feed, Ns, Inner} = binary_to_term(Payload, [safe]),
    {block_bytes, EntryBlob} = binary_to_term(Inner, [safe]),
    ?assertEqual({ok, E}, quod_ledger:decode_entry(EntryBlob)).

decode_wrong_ns_test() ->
    E = quod_ledger:noop_entry(1, none),
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

%% A contiguous content entry advances height + folds the committee together (the as-of pairing); a
%% `noop` preserves it; a membership entry folds the delta. A gap or DTX control resets to `none`: DTX
%% reduction needs group history, so the ephemeral feed cache refetches Simplex's authoritative projection.
fold_snapshot_test() ->
    A = <<1>>, B = <<2>>,
    Admit = #transaction{tx_id = <<"t">>, origin = {<<"n">>, <<0:256>>}, author = <<"a">>, sig = none, read_check = #{},
                         diff = [{assert, {{peer_admitted, B, "h", 1, B}, true}}]},
    Projection = quod_simplex:history_projection(
                   [A], <<3:256>>, #{A => <<4:256>>}, #{}, 0),
    Noop = quod_ledger:noop_entry(6, none),
    {ok, AdmitEntry} = quod_ledger:new_entry(
                         6, {batch, [Admit]}, 0, none),
    %% contiguous content/noop entry: height advances, committee unchanged
    {6, NoopProjection, done} =
        quod_feed:fold_snapshot(<<"n">>, Noop, {5, Projection, done}),
    ?assertEqual([A], quod_simplex:history_committee(NoopProjection)),
    %% contiguous membership entry: committee folds the admit, height advances
    {6, AdmitProjection, done} =
        quod_feed:fold_snapshot(
          <<"n">>, AdmitEntry, {5, Projection, done}),
    ?assertEqual(lists:usort([A, B]),
                 quod_simplex:history_committee(AdmitProjection)),
    %% NON-contiguous (gap or behind) → reset to none, so the next use refetches real status [DA#5]
    ?assertEqual(none, quod_feed:fold_snapshot(
                         <<"n">>, quod_ledger:noop_entry(8, none),
                         {5, Projection, done})),
    ?assertEqual(none, quod_feed:fold_snapshot(
                         <<"n">>, quod_ledger:noop_entry(5, none),
                         {5, Projection, done})),
    %% A real, signed DTX control must not enter the content-only projection
    %% fold (which deliberately fails closed without its phase-history index).
    {ok, Dtx} = quod_ledger:new_entry(
                  6, quod_ct:dtx_decision_payload(), 0, none),
    ?assertEqual(none, quod_feed:fold_snapshot(
                         <<"n">>, Dtx, {5, Projection, done})),
    %% folding onto an unprimed snapshot stays none (primed later by a status call)
    ?assertEqual(none, quod_feed:fold_snapshot(<<"n">>, Noop, none)).

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

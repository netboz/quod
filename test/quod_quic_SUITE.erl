-module(quod_quic_SUITE).
-moduledoc """
Integration test for the QUIC transport over a real loopback connection: a node
opens a link to itself, and a framed payload is pushed across a real QUIC stream
and observed via the gproc `{channel, _}` property as `{quod_message, ...}`.
""".

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([open_link_succeeds/1, message_roundtrip/1, bidirectional_reuse/1,
         channel_stream_reset_isolated/1,
         ordered_send_waits_for_send_ready_fifo/1,
         connection_death_resolves_pending_waiters/1,
         inbound_channel_reset_is_scoped/1,
         explicit_link_retires_with_last_owner/1,
         pinned_leases_share_link_until_last_release/1,
         pinned_lease_release_is_connection_exact/1,
         late_released_link_cannot_consume_replacement_waiter/1,
         non_dialable_node_id/1, unacked_stream_no_link_up/1, dialer_presents_cert/1,
         mismatched_header_cannot_poison_cache/1,
         authenticated_coalesced_header_payload_delivered_once/1,
         no_learn_is_monotone_across_streams/1,
         resolve_and_dial_by_pubkey/1, pinned_dial_suppresses_hint_learning/1,
         ordinary_pubkey_dial_rejects_wrong_cert/1,
         connection_is_owned_by_transport/1,
         pinned_reverse_stream_suppresses_hint_learning/1,
         identified_dial_suppresses_hint_learning/1,
         ordinary_dial_still_learns_hint/1,
         pinned_dial_rejects_wrong_cert/1]).

-define(PORT, 14599).
-define(SELF, {"127.0.0.1", ?PORT}).

all() -> [open_link_succeeds, message_roundtrip, bidirectional_reuse,
          channel_stream_reset_isolated,
          ordered_send_waits_for_send_ready_fifo,
          connection_death_resolves_pending_waiters,
          inbound_channel_reset_is_scoped,
          explicit_link_retires_with_last_owner,
          pinned_leases_share_link_until_last_release,
          pinned_lease_release_is_connection_exact,
          late_released_link_cannot_consume_replacement_waiter,
          non_dialable_node_id,
          unacked_stream_no_link_up, dialer_presents_cert,
          mismatched_header_cannot_poison_cache,
          authenticated_coalesced_header_payload_delivered_once,
          no_learn_is_monotone_across_streams,
          resolve_and_dial_by_pubkey,
          ordinary_pubkey_dial_rejects_wrong_cert,
          connection_is_owned_by_transport,
          pinned_dial_suppresses_hint_learning,
          pinned_reverse_stream_suppresses_hint_learning,
          identified_dial_suppresses_hint_learning,
          ordinary_dial_still_learns_hint, pinned_dial_rejects_wrong_cert].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(gproc),
    {ok, _} = application:ensure_all_started(quic),
    application:load(quod),
    %% Never inherit a developer/node effect journal through the user cache.
    %% The suite owns an isolated CT-private directory, so app startup really
    %% runs every transport case instead of failing before the suite begins.
    EffectJournalDir =
        filename:join(?config(priv_dir, Config), "effect-journal"),
    application:set_env(quod, effect_journal_data_dir, EffectJournalDir),
    %% the node's per-node Ed25519 identity cert — the production transport cert that
    %% quod_quic presents and verifies under mutual TLS (verify => true).
    {ok, #{pubkey := Pub, cert := Cert, key := Key}} = quod_identity:ensure(
        filename:join(?config(priv_dir, Config), "node-identity")),
    true = is_function(Key, 0),
    application:set_env(quod, listen_port, ?PORT),
    application:set_env(quod, node_addr, ?SELF),
    application:set_env(quod, node_pubkey, Pub),
    application:set_env(quod, identity_cert, Cert),
    application:set_env(quod, identity_key, Key),
    {ok, _} = application:ensure_all_started(quod),
    %% The app retains the opaque loaded key; synthetic peers below call the
    %% native TLS library directly and therefore need its native key term.
    [{cert_der, Cert}, {key_term, quod_identity:tls_key(Key)},
     {self_pubkey, Pub} | Config].

end_per_suite(_Config) ->
    _ = application:stop(quod),
    %% this suite runs the app IN the CT node (not a peer), so unset the env it set
    %% to avoid leaking a stale cert/port into any later same-node suite.
    _ = [application:unset_env(quod, K)
         || K <- [listen_port, node_addr, node_pubkey, identity_cert, identity_key,
                  effect_journal_data_dir]],
    ok.

%% Opening a link to our own listener over loopback yields a usable link pid.
open_link_succeeds(_Config) ->
    {ok, Key} = application:get_env(quod, identity_key),
    true = is_function(Key, 0),
    %% Real OTP status, not just a hand-built report. Both listener and dialer
    %% must still complete mutual TLS from the same loaded opaque identity.
    Transport = quod_reg:where({transport, node}),
    true = is_pid(Transport),
    Status = iolist_to_binary(io_lib:format("~p", [sys:get_status(Transport)])),
    nomatch = binary:match(Status, <<"ECPrivateKey">>),
    ok = quod_quic:open_link(?SELF, <<"chan-a">>),
    receive
        {link_up, ?SELF, <<"chan-a">>, LinkPid} when is_pid(LinkPid) -> ok
    after 5000 ->
        ct:fail(no_link_up)
    end.

%% A payload sent on the outbound link arrives at the inbound link and is
%% published on the channel property as {quod_message, {Peer, _}, Channel, _}.
message_roundtrip(_Config) ->
    true = quod_reg:subscribe({channel, <<"chan-b">>}),
    ok = quod_quic:open_link(?SELF, <<"chan-b">>),
    LinkPid = receive
                  {link_up, ?SELF, <<"chan-b">>, L} -> L
              after 5000 -> ct:fail(no_link_up)
              end,
    ok = quod_link:send(LinkPid, <<"hello">>),
    receive
        {quod_message, {_Peer, _InLink}, <<"chan-b">>, <<"hello">>} -> ok
    after 5000 ->
        ct:fail(no_message)
    end.

%% One stream is bidirectional: a reply sent on the *inbound* link arrives back
%% on the *outbound* link — proving a peer pair needs only one stream per channel.
bidirectional_reuse(_Config) ->
    true = quod_reg:subscribe({channel, <<"chan-c">>}),
    ok = quod_quic:open_link(?SELF, <<"chan-c">>),
    OutLink = receive
                  {link_up, ?SELF, <<"chan-c">>, L} -> L
              after 5000 -> ct:fail(no_link_up)
              end,
    %% out -> in
    ok = quod_link:send(OutLink, <<"ping">>),
    InLink = receive
                 {quod_message, {_, In}, <<"chan-c">>, <<"ping">>} -> In
             after 5000 -> ct:fail(no_ping)
             end,
    %% in -> out, on the SAME stream
    ok = quod_link:send(InLink, <<"pong">>),
    receive
        {quod_message, {_, OutLink}, <<"chan-c">>, <<"pong">>} -> ok
    after 5000 ->
        ct:fail(no_pong)
    end.

%% `{log,Ns}` consensus and `{ingress,Ns}` relay links are distinct streams on
%% the same QUIC connection. Deterministically force the real relay link through
%% its ordered-send failure arm: it counts the refusal, resets its actual QUIC
%% Sid, and exits. Consensus must stay live and deliver after that reset.
channel_stream_reset_isolated(_Config) ->
    LogChan = <<"isolation-log">>,
    IngressChan = <<"isolation-ingress">>,
    true = quod_reg:subscribe({channel, LogChan}),
    true = quod_reg:subscribe({channel, IngressChan}),
    ok = quod_quic:open_link(?SELF, LogChan),
    LogLink =
        receive
            {link_up, ?SELF, LogChan, LogPid} -> LogPid
        after 5000 ->
            ct:fail(no_log_link)
        end,
    ok = quod_quic:open_link(?SELF, IngressChan),
    IngressLink =
        receive
            {link_up, ?SELF, IngressChan, IngressPid} -> IngressPid
        after 5000 ->
            ct:fail(no_ingress_link)
        end,
    true = LogLink =/= IngressLink,
    ok = quod_link:send(LogLink, <<"before-reset">>),
    receive
        {quod_message, {_, _}, LogChan, <<"before-reset">>} -> ok
    after 5000 ->
        ct:fail(no_log_before_reset)
    end,
    IngressRef = monitor(process, IngressLink),
    ok = quod_link:test_fail_next_ordered(
           IngressLink, backpressure_timeout),
    ok = quod_link:send_ordered(
           IngressLink, <<"forced-ordered-failure">>),
    receive
        {'DOWN', IngressRef, process, IngressLink,
         {ordered_send_failed, backpressure_timeout}} ->
            ok
    after 5000 ->
        ct:fail(ingress_ordered_failure_did_not_reset)
    end,
    true = is_process_alive(LogLink),
    ok = quod_link:send(LogLink, <<"after-reset">>),
    receive
        {quod_message, {_, _}, LogChan, <<"after-reset">>} -> ok
    after 5000 ->
        ct:fail(consensus_stream_died_with_ingress)
    end.

%% A transient ordered-send refusal parks the exact stream FIFO. Nothing polls:
%% the QUIC owner's send_ready event is routed by quod_conn to that link, which
%% retries the head and then flushes its successor in order. A reliable send on
%% the same path also reports local acceptance to its caller.
ordered_send_waits_for_send_ready_fifo(_Config) ->
    Channel = <<"send-ready-fifo">>,
    true = quod_reg:subscribe({channel, Channel}),
    try
        ok = quod_quic:open_link(?SELF, Channel),
        Link =
            receive
                {link_up, ?SELF, Channel, Pid} -> Pid
            after 5000 ->
                ct:fail(no_send_ready_link)
            end,
        {links, [ConnOwner]} = process_info(Link, links),
        {ok, {Conn, Sid}} = quod_link:test_transport(Link),
        %% The existing failure seam can also inject a *transient* refusal. It
        %% is consumed by the next ordered attempt, which must park rather than
        %% reset the stream.
        ok = quod_link:test_fail_next_ordered(Link, send_queue_full),
        ok = quod_link:send_ordered(Link, <<"first">>),
        ok = quod_link:send_ordered(Link, <<"second">>),
        receive
            {quod_message, _, Channel, Unexpected} ->
                ct:fail({sent_before_send_ready, Unexpected})
        after 50 ->
            ok
        end,
        ConnOwner ! {quic, Conn, {send_ready, Sid}},
        receive
            {quod_message, {_, _}, Channel, <<"first">>} -> ok
        after 5000 ->
            ct:fail(first_not_woken)
        end,
        receive
            {quod_message, {_, _}, Channel, <<"second">>} -> ok
        after 5000 ->
            ct:fail(second_not_fifo)
        end,
        ok = quod_link:send_reliable(Link, <<"reliable">>, 1000),
        receive
            {quod_message, {_, _}, Channel, <<"reliable">>} -> ok
        after 5000 ->
            ct:fail(reliable_not_delivered)
        end,
        true = is_process_alive(Link)
    after
        true = quod_reg:unsubscribe({channel, Channel})
    end.

%% A connection can close before its opening streams emit their linked EXITs.
%% Both accepted callers must still receive one correlated link_error directly
%% from the connection ownership boundary; neither may remain parked forever.
connection_death_resolves_pending_waiters(Config) ->
    CertDer = ?config(cert_der, Config),
    KeyTerm = ?config(key_term, Config),
    Test = self(),
    Handler =
        fun(Conn) ->
            Test ! {pending_waiter_server_conn, Conn},
            {ok, spawn(fun Ignore() -> receive _ -> Ignore() end end)}
        end,
    Port = 14595,
    Target = {"127.0.0.1", Port},
    Channel = <<"pending-waiters-die-with-conn">>,
    {ok, _} = quic:start_server(
                pending_waiter_server, Port,
                #{cert => CertDer, key => KeyTerm,
                  alpn => [<<"quod">>], connection_handler => Handler}),
    try
        %% Establish the connection owner through the public authority, then add
        %% two ref-correlated opens directly. The stats request is a mailbox
        %% barrier from the same sender, proving both opens were accepted before
        %% the server connection is closed.
        ok = quod_quic:open_link(Target, Channel),
        ServerConn =
            receive
                {pending_waiter_server_conn, C} -> C
            after 5000 ->
                ct:fail(no_pending_waiter_connection)
            end,
        Transport = quod_reg:where({transport, node}),
        TransportState = sys:get_state(Transport),
        Conns = element(tuple_size(TransportState), TransportState),
        ConnOwner = maps:get(Target, Conns),
        ConnOwnerRef = monitor(process, ConnOwner),
        Ref1 = make_ref(),
        Ref2 = make_ref(),
        ok = quod_conn:open_link(ConnOwner, Channel, {self(), Ref1}),
        ok = quod_conn:open_link(ConnOwner, Channel, {self(), Ref2}),
        Barrier = make_ref(),
        ConnOwner ! {transport_stats, self(), Barrier},
        receive {Barrier, _} -> ok after 2000 -> ct:fail(no_conn_barrier) end,
        ok = quic:close(ServerConn, normal),
        receive
            {link_error, Ref1, Target, Channel} -> ok
        after 5000 ->
            ct:fail(first_waiter_not_resolved)
        end,
        receive
            {link_error, Ref2, Target, Channel} -> ok
        after 5000 ->
            ct:fail(second_waiter_not_resolved)
        end,
        receive
            {link_error, Ref1, Target, Channel} ->
                ct:fail(first_waiter_resolved_twice);
            {link_error, Ref2, Target, Channel} ->
                ct:fail(second_waiter_resolved_twice)
        after 100 ->
            ok
        end,
        receive
            {'DOWN', ConnOwnerRef, process, ConnOwner, _} -> ok
        after 2000 ->
            ct:fail(terminal_connection_not_retired)
        end,
        %% Removal precedes the terminal ACK/exit. A later public open must
        %% therefore create a different connection generation, never select
        %% the dead pid that produced the two errors above.
        ReplacementChannel = <<"replacement-after-terminal">>,
        ok = quod_quic:open_link(Target, ReplacementChannel),
        ReplacementServerConn =
            receive
                {pending_waiter_server_conn, C2} -> C2
            after 5000 ->
                ct:fail(no_replacement_connection)
            end,
        ReplacementState = sys:get_state(Transport),
        ReplacementConns =
            element(tuple_size(ReplacementState), ReplacementState),
        ReplacementOwner = maps:get(Target, ReplacementConns),
        true = ReplacementOwner =/= ConnOwner,
        ok = quic:close(ReplacementServerConn, normal)
    after
        _ = quic:stop_server(pending_waiter_server)
    end.

%% Channel-owner restart is a transport-wide broadcast but a link-local
%% decision: only a matching peer-opened stream resets. Outbound links ignore
%% the command, and another inbound channel remains usable.
inbound_channel_reset_is_scoped(_Config) ->
    ResetChannel = <<"reset-inbound-exact">>,
    OtherChannel = <<"reset-inbound-other">>,
    true = quod_reg:subscribe({channel, ResetChannel}),
    true = quod_reg:subscribe({channel, OtherChannel}),
    try
        ok = quod_quic:open_link(?SELF, ResetChannel),
        ResetOut =
            receive
                {link_up, ?SELF, ResetChannel, Pid1} -> Pid1
            after 5000 -> ct:fail(no_reset_outbound)
            end,
        ok = quod_quic:open_link(?SELF, OtherChannel),
        OtherOut =
            receive
                {link_up, ?SELF, OtherChannel, Pid2} -> Pid2
            after 5000 -> ct:fail(no_other_outbound)
            end,
        ok = quod_link:send(ResetOut, <<"find-reset-inbound">>),
        ResetIn =
            receive
                {quod_message, {_, In1}, ResetChannel,
                 <<"find-reset-inbound">>} -> In1
            after 5000 -> ct:fail(no_reset_inbound)
            end,
        ok = quod_link:send(OtherOut, <<"find-other-inbound">>),
        OtherIn =
            receive
                {quod_message, {_, In2}, OtherChannel,
                 <<"find-other-inbound">>} -> In2
            after 5000 -> ct:fail(no_other_inbound)
            end,
        %% Directly prove the two negative guards before exercising broadcast.
        ResetOut ! {reset_inbound_channel, ResetChannel},
        {ok, _} = quod_link:test_transport(ResetOut),
        ResetIn ! {reset_inbound_channel, OtherChannel},
        {ok, _} = quod_link:test_transport(ResetIn),
        ResetInRef = monitor(process, ResetIn),
        OtherInRef = monitor(process, OtherIn),
        OtherOutRef = monitor(process, OtherOut),
        ok = quod_conn:reset_inbound_channel(ResetChannel),
        receive
            {'DOWN', ResetInRef, process, ResetIn, normal} -> ok;
            {'DOWN', ResetInRef, process, ResetIn, Reason} ->
                ct:fail({bad_reset_reason, Reason})
        after 5000 ->
            ct:fail(matching_inbound_not_reset)
        end,
        receive
            {'DOWN', OtherInRef, process, OtherIn, Reason2} ->
                ct:fail({other_inbound_reset, Reason2});
            {'DOWN', OtherOutRef, process, OtherOut, Reason3} ->
                ct:fail({other_outbound_reset, Reason3})
        after 100 ->
            ok
        end,
        ok = quod_link:send(OtherOut, <<"other-still-live">>),
        receive
            {quod_message, {_, OtherIn}, OtherChannel,
             <<"other-still-live">>} -> ok
        after 5000 ->
            ct:fail(other_channel_not_live)
        end,
        demonitor(OtherInRef, [flush]),
        demonitor(OtherOutRef, [flush])
    after
        true = quod_reg:unsubscribe({channel, ResetChannel}),
        true = quod_reg:unsubscribe({channel, OtherChannel})
    end.

%% An explicit opener is the owner of its returned link. Monitoring that owner
%% closes the old is_process_alive/link_up race: even when it dies immediately
%% after receiving link_up, the connection retires the waiter-only stream rather
%% than caching an unowned link.
explicit_link_retires_with_last_owner(_Config) ->
    Channel = <<"explicit-link-owner">>,
    Parent = self(),
    {Opener, OpenerRef} =
        spawn_monitor(fun() ->
            ok = quod_quic:open_link(?SELF, Channel),
            receive
                {link_up, ?SELF, Channel, LinkPid} ->
                    Parent ! {owned_link, self(), LinkPid},
                    receive release_owner -> ok end
            after 5000 ->
                Parent ! {owned_link_failed, self()}
            end
        end),
    Link =
        receive
            {owned_link, Opener, Pid} -> Pid;
            {owned_link_failed, Opener} -> ct:fail(no_owned_link)
        after 6000 ->
            ct:fail(no_owned_link_result)
        end,
    LinkRef = monitor(process, Link),
    Opener ! release_owner,
    receive
        {'DOWN', OpenerRef, process, Opener, normal} -> ok
    after 1000 ->
        ct:fail(opener_did_not_exit)
    end,
    receive
        {'DOWN', LinkRef, process, Link, normal} -> ok;
        {'DOWN', LinkRef, process, Link, Reason} ->
            ct:fail({bad_owned_link_exit, Reason})
    after 3000 ->
        ct:fail(waiter_only_link_was_cached)
    end.

%% Two logical requests may deliberately reuse one pinned stream. Releasing
%% one exact `{Pid,OpenRef}` lease must leave the shared link usable; releasing
%% the final lease retires it.
pinned_leases_share_link_until_last_release(Config) ->
    Pub = ?config(self_pubkey, Config),
    Channel = <<"pinned-shared-request-leases">>,
    true = quod_reg:subscribe({channel, Channel}),
    try
        Ref1 = quod_quic:open_link_pinned_lease(Pub, ?SELF, Channel),
        Link = receive
                   {link_up, Ref1, Pub, Channel, Pid1} -> Pid1
               after 5000 -> ct:fail(no_first_pinned_lease)
               end,
        Ref2 = quod_quic:open_link_pinned_lease(Pub, ?SELF, Channel),
        Link = receive
                   {link_up, Ref2, Pub, Channel, Pid2} -> Pid2
               after 5000 -> ct:fail(no_shared_pinned_lease)
               end,
        LinkRef = monitor(process, Link),
        ok = quod_quic:release_link_pinned(Pub, ?SELF, Channel, Ref1),
        receive
            {'DOWN', LinkRef, process, Link, Reason1} ->
                ct:fail({shared_link_closed_on_first_release, Reason1})
        after 100 ->
            ok
        end,
        ok = quod_link:send(Link, <<"still-leased">>),
        receive
            {quod_message, {_, _}, Channel, <<"still-leased">>} -> ok
        after 5000 ->
            ct:fail(shared_link_not_usable_after_first_release)
        end,
        ok = quod_quic:release_link_pinned(Pub, ?SELF, Channel, Ref2),
        receive
            {'DOWN', LinkRef, process, Link, normal} -> ok;
            {'DOWN', LinkRef, process, Link, Reason2} ->
                ct:fail({bad_final_lease_exit, Reason2})
        after 3000 ->
            ct:fail(shared_link_survived_final_release)
        end
    after
        true = quod_reg:unsubscribe({channel, Channel})
    end.

%% Pinned pool identity includes the endpoint. The same peer/channel on two
%% endpoints therefore owns two connections and two links; releasing one lease
%% must retire only that exact connection's link.
pinned_lease_release_is_connection_exact(Config) ->
    Pub = ?config(self_pubkey, Config),
    Cert = ?config(cert_der, Config),
    Key = ?config(key_term, Config),
    Port = 14594,
    OtherEndpoint = {"127.0.0.1", Port},
    Channel = <<"pinned-endpoint-exact-lease">>,
    Owner = spawn(fun second_conn_owner/0),
    Handler =
        fun(Conn) ->
            {ok, quod_conn:start_inbound(
                   Conn, {Pub, OtherEndpoint}, Owner)}
        end,
    {ok, _} = quic:start_server(
                pinned_lease_second_endpoint, Port,
                maps:merge(
                  #{cert => Cert, key => Key, verify => true,
                    alpn => [<<"quod">>], connection_handler => Handler},
                  quod_quic:liveness_opts())),
    true = quod_reg:subscribe({channel, Channel}),
    try
        Ref1 = quod_quic:open_link_pinned_lease(Pub, ?SELF, Channel),
        Link1 = receive
                    {link_up, Ref1, Pub, Channel, Pid1} -> Pid1
                after 5000 -> ct:fail(no_primary_endpoint_lease)
                end,
        Ref2 = quod_quic:open_link_pinned_lease(
                 Pub, OtherEndpoint, Channel),
        Link2 = receive
                    {link_up, Ref2, Pub, Channel, Pid2} -> Pid2
                after 5000 -> ct:fail(no_secondary_endpoint_lease)
                end,
        true = Link1 =/= Link2,
        Link1Ref = monitor(process, Link1),
        Link2Ref = monitor(process, Link2),
        ok = quod_quic:release_link_pinned(Pub, ?SELF, Channel, Ref1),
        receive
            {'DOWN', Link1Ref, process, Link1, normal} -> ok;
            {'DOWN', Link1Ref, process, Link1, Reason1} ->
                ct:fail({bad_primary_lease_exit, Reason1})
        after 3000 ->
            ct:fail(primary_endpoint_lease_not_released)
        end,
        true = is_process_alive(Link2),
        ok = quod_link:send(Link2, <<"secondary-still-live">>),
        receive
            {quod_message, {_, _}, Channel,
             <<"secondary-still-live">>} -> ok
        after 5000 ->
            ct:fail(secondary_endpoint_link_was_disturbed)
        end,
        ok = quod_quic:release_link_pinned(
               Pub, OtherEndpoint, Channel, Ref2),
        receive
            {'DOWN', Link2Ref, process, Link2, normal} -> ok;
            {'DOWN', Link2Ref, process, Link2, Reason2} ->
                ct:fail({bad_secondary_lease_exit, Reason2})
        after 3000 ->
            ct:fail(secondary_endpoint_lease_not_released)
        end
    after
        true = quod_reg:unsubscribe({channel, Channel}),
        _ = quic:stop_server(pinned_lease_second_endpoint),
        Owner ! stop
    end.

second_conn_owner() ->
    receive
        {conn_terminal, ConnPid, Ref} ->
            ConnPid ! {conn_terminal_ack, self(), Ref},
            second_conn_owner();
        stop ->
            ok;
        _Other ->
            second_conn_owner()
    end.

%% Releasing the last L1 lease can be immediately followed by a replacement L2
%% open on the same connection/channel. If L1's already-queued link_up arrives
%% first, it must not consume L2's exact waiter or become the cached link.
late_released_link_cannot_consume_replacement_waiter(_Config) ->
    Channel = <<"late-l1-before-replacement-l2">>,
    Peer = crypto:strong_rand_bytes(32),
    Parent = self(),
    OldLink = spawn(fun() -> link_probe(Parent) end),
    NewLink = spawn(fun() -> link_probe(Parent) end),
    #{ref := Ref, pending_after_old := true,
      pending_after_new := false, active := NewLink} =
        quod_conn:test_late_link_up_generation(
          Channel, Peer, OldLink, NewLink),
    receive
        {probe_closed, OldLink} -> ok
    after 1000 ->
        ct:fail(stale_generation_link_not_closed)
    end,
    receive
        {link_up, Ref, Peer, Channel, NewLink} -> ok;
        {link_up, Ref, Peer, Channel, OldLink} ->
            ct:fail(stale_generation_consumed_replacement_waiter)
    after 1000 ->
        ct:fail(replacement_waiter_not_notified)
    end,
    NewLink ! stop.

link_probe(Parent) ->
    receive
        close -> Parent ! {probe_closed, self()};
        stop -> ok;
        _Other -> link_probe(Parent)
    end.

%% A peer that completes the QUIC handshake but never ACKs the opened stream must
%% NOT produce a link_up — the opener gets link_error after the ack timeout. This is
%% the liveness ACK: a connection alone is not a live link; only the peer's ack is.
%% (A revert to optimistic link_up would make this test see link_up and fail.)
unacked_stream_no_link_up(Config) ->
    CertDer = ?config(cert_der, Config),
    KeyTerm = ?config(key_term, Config),
    %% raw QUIC server that completes handshakes but whose owner ignores every
    %% stream event (so it never sends the ack frame quod_link expects).
    Handler = fun(_Conn) -> {ok, spawn(fun Ignore() -> receive _ -> Ignore() end end)} end,
    {ok, _} = quic:start_server(raw_noack, 14598,
                                #{cert => CertDer, key => KeyTerm,
                                  alpn => [<<"quod">>], connection_handler => Handler}),
    Dead = {"127.0.0.1", 14598},
    try
        ok = quod_quic:open_link(Dead, <<"chan-noack">>),
        receive
            {link_up, Dead, <<"chan-noack">>, _} -> ct:fail(unexpected_link_up_without_ack);
            {link_error, Dead, <<"chan-noack">>} -> ok
        after 9000 -> ct:fail(no_link_error)     %% ack timeout is 5s -> link_error well within 9s
        end
    after
        _ = quic:stop_server(raw_noack)
    end.

%% Mutual TLS: when quod_quic dials a peer it PRESENTS its own identity cert, which a
%% verify=>true server reads via quic:peercert/1 — proving the dialer authenticates
%% itself (not just verify=>false). The recovered pubkey is the node's identity key.
%% (Guards against a regression that drops the client cert or flips verify off.)
dialer_presents_cert(Config) ->
    SelfPub = ?config(self_pubkey, Config),
    CertDer = ?config(cert_der, Config),
    KeyTerm = ?config(key_term, Config),
    Test = self(),
    %% a verify=>true server (like quod_quic's own) that hands us each accepted Conn so
    %% we can inspect the client cert it received.
    Handler = fun(Conn) -> Test ! {srv_conn, Conn},
                           {ok, spawn(fun Ignore() -> receive _ -> Ignore() end end)} end,
    {ok, _} = quic:start_server(verify_srv, 14597,
                                #{cert => CertDer, key => KeyTerm, verify => true,
                                  alpn => [<<"quod">>], connection_handler => Handler}),
    Peer = {"127.0.0.1", 14597},
    try
        %% the link won't come up (the server ignores the stream) — we only need the
        %% handshake, where our client cert is presented + verified.
        ok = quod_quic:open_link(Peer, <<"chan-mtls">>),
        SConn = receive {srv_conn, C} -> C after 5000 -> ct:fail(no_server_conn) end,
        {ok, PeerCert} = peercert_retry(SConn, 40),
        case quod_identity:pubkey_of_cert(PeerCert) of
            {ok, SelfPub} -> ok;
            Other         -> ct:fail({peercert_pubkey_mismatch, Other})
        end
    after
        _ = quic:stop_server(verify_srv)
    end.

peercert_retry(Conn, 0) -> quic:peercert(Conn);
peercert_retry(Conn, N) ->
    case quic:peercert(Conn) of
        {ok, _} = R -> R;
        _           -> timer:sleep(50), peercert_retry(Conn, N - 1)
    end.

%% A structurally valid header is not authenticated until its claimed key is
%% compared with the connection's client certificate. Learning before that bind
%% lets one valid-cert node overwrite another key's shared address hint.
mismatched_header_cannot_poison_cache(_Config) ->
    {ActualPub, _} = ActualKeyPair = quod_identity:generate(),
    ActualCert = quod_identity:mint_cert(ActualKeyPair),
    ActualKey = quod_identity:key_term(ActualKeyPair),
    ForgedPub = crypto:strong_rand_bytes(32),
    true = ForgedPub =/= ActualPub,
    Existing = {"127.0.0.1", 14448},
    Claimed = {"127.0.0.1", 24448},
    Channel = <<"forged-header">>,
    Payload = <<"must-not-escape-before-auth">>,
    true = quod_reg:subscribe({channel, Channel}),
    ok = quod_quic:learn(ForgedPub, Existing),
    try
        {ok, Conn} = quic:connect(
                       element(1, ?SELF), element(2, ?SELF),
                       #{verify => false, cert => ActualCert, key => ActualKey,
                         alpn => [<<"quod">>]}, self()),
        receive
            {quic, Conn, {connected, _}} -> ok
        after 5000 -> ct:fail(no_mismatch_connection)
        end,
        {ok, Sid} = quic:open_stream(Conn),
        ConnRef = monitor(process, Conn),
        Header = quod_link:header(
                   {ForgedPub, Claimed}, Channel, learn),
        Packet = <<Header/binary,
                   (quod_link:frame(Payload))/binary>>,
        ok = quic:send_data(Conn, Sid, Packet, false),
        receive
            {quod_message, _, Channel, Payload} ->
                ct:fail(payload_published_before_identity_bind)
        after 200 ->
            ok
        end,
        {ok, Existing} = quod_quic:resolve(ForgedPub),
        receive
            {'DOWN', ConnRef, process, Conn, _} -> ok
        after 5000 ->
            ct:fail(rejected_identity_connection_not_closed)
        end,
        ok
    after
        true = quod_reg:unsubscribe({channel, Channel})
    end.

%% Header authentication is a barrier, not a payload drop: a matching client
%% certificate/header pair may publish coalesced bytes exactly once after bind.
authenticated_coalesced_header_payload_delivered_once(_Config) ->
    {ActualPub, _} = ActualKeyPair = quod_identity:generate(),
    ActualCert = quod_identity:mint_cert(ActualKeyPair),
    ActualKey = quod_identity:key_term(ActualKeyPair),
    Channel = <<"authenticated-coalesced">>,
    Payload = <<"after-auth-only">>,
    true = quod_reg:subscribe({channel, Channel}),
    try
        {ok, Conn} = quic:connect(
                       element(1, ?SELF), element(2, ?SELF),
                       #{verify => false, cert => ActualCert, key => ActualKey,
                         alpn => [<<"quod">>]}, self()),
        receive
            {quic, Conn, {connected, _}} -> ok
        after 5000 -> ct:fail(no_authenticated_connection)
        end,
        {ok, Sid} = quic:open_stream(Conn),
        Header = quod_link:header(
                   {ActualPub, {"127.0.0.1", 24449}},
                   Channel, no_learn),
        Packet = <<Header/binary,
                   (quod_link:frame(Payload))/binary>>,
        ok = quic:send_data(Conn, Sid, Packet, false),
        receive
            {quod_message, {{ActualPub, _}, _}, Channel, Payload} ->
                ok
        after 5000 ->
            ct:fail(authenticated_coalesced_payload_not_delivered)
        end,
        receive
            {quod_message, _, Channel, Payload} ->
                ct:fail(authenticated_coalesced_payload_duplicated)
        after 100 ->
            ok
        end,
        _ = catch quic:close(Conn, normal),
        ok
    after
        true = quod_reg:unsubscribe({channel, Channel})
    end.

%% no_learn is connection-wide and monotone. A later authenticated stream
%% cannot flip it back to learn and overwrite the shared address cache.
no_learn_is_monotone_across_streams(_Config) ->
    {ActualPub, _} = ActualKeyPair = quod_identity:generate(),
    ActualCert = quod_identity:mint_cert(ActualKeyPair),
    ActualKey = quod_identity:key_term(ActualKeyPair),
    Existing = {"127.0.0.1", 24450},
    FirstChannel = <<"no-learn-latch">>,
    SecondChannel = <<"learn-cannot-reenable">>,
    true = quod_reg:subscribe({channel, FirstChannel}),
    true = quod_reg:subscribe({channel, SecondChannel}),
    ok = quod_quic:learn(ActualPub, Existing),
    try
        {ok, Conn} = quic:connect(
                       element(1, ?SELF), element(2, ?SELF),
                       #{verify => false, cert => ActualCert, key => ActualKey,
                         alpn => [<<"quod">>]}, self()),
        receive
            {quic, Conn, {connected, _}} -> ok
        after 5000 -> ct:fail(no_monotone_policy_connection)
        end,
        send_raw_header_payload(
          Conn, ActualPub, {"127.0.0.1", 24451},
          FirstChannel, no_learn, <<"latch">>),
        receive
            {quod_message, {{ActualPub, _}, _},
             FirstChannel, <<"latch">>} -> ok
        after 5000 -> ct:fail(no_no_learn_latch_message)
        end,
        {ok, Existing} = quod_quic:resolve(ActualPub),
        send_raw_header_payload(
          Conn, ActualPub, {"127.0.0.1", 24452},
          SecondChannel, learn, <<"cannot-reenable">>),
        receive
            {quod_message, {{ActualPub, _}, _},
             SecondChannel, <<"cannot-reenable">>} -> ok
        after 5000 -> ct:fail(no_second_authenticated_message)
        end,
        {ok, Existing} = quod_quic:resolve(ActualPub),
        _ = catch quic:close(Conn, normal),
        ok
    after
        true = quod_reg:unsubscribe({channel, FirstChannel}),
        true = quod_reg:unsubscribe({channel, SecondChannel})
    end.

send_raw_header_payload(Conn, Pubkey, Endpoint, Channel, Policy, Payload) ->
    {ok, Sid} = quic:open_stream(Conn),
    Header = quod_link:header({Pubkey, Endpoint}, Channel, Policy),
    quic:send_data(
      Conn, Sid,
      <<Header/binary, (quod_link:frame(Payload))/binary>>, false).

%% A PUBKEY target (the production id form) is resolved to an endpoint via a learned hint,
%% then dialed — the resolver path end to end through the real transport. (We map a fresh
%% pubkey to our own loopback listener so the dial connects.)
resolve_and_dial_by_pubkey(Config) ->
    PK = ?config(self_pubkey, Config),
    ok = quod_quic:learn(PK, ?SELF),
    ok = quod_quic:open_link(PK, <<"chan-pk">>),
    receive
        {link_up, PK, <<"chan-pk">>, LinkPid} when is_pid(LinkPid) -> ok
    after 5000 -> ct:fail(no_link_up_by_pubkey)
    end.

%% An ordinary public-key target is still an identity claim, not merely a
%% cache lookup. Resolving that key to a live endpoint whose certificate
%% carries another key must fail before any stream becomes usable.
ordinary_pubkey_dial_rejects_wrong_cert(Config) ->
    Actual = ?config(self_pubkey, Config),
    Expected = crypto:strong_rand_bytes(32),
    true = Expected =/= Actual,
    ok = quod_quic:learn(Expected, ?SELF),
    Channel = <<"chan-ordinary-wrong-cert">>,
    ok = quod_quic:open_link(Expected, Channel),
    receive
        {link_error, Expected, Channel} -> ok;
        {link_up, Expected, Channel, _} ->
            ct:fail(ordinary_pubkey_dial_accepted_wrong_cert)
    after 5000 ->
        ct:fail(no_ordinary_pubkey_mismatch_result)
    end.

%% Every connection owner is linked to the transport authority. This makes a
%% transport restart one ownership boundary: old connections and their streams
%% cannot survive as an untracked duplicate generation.
connection_is_owned_by_transport(_Config) ->
    Channel = <<"chan-owned-connection">>,
    ok = quod_quic:open_link(?SELF, Channel),
    Link =
        receive
            {link_up, ?SELF, Channel, Pid} -> Pid
        after 5000 ->
            ct:fail(no_owned_link)
        end,
    {links, [ConnOwner]} = process_info(Link, links),
    Authority = quod_reg:where({transport, node}),
    {links, OwnerLinks} = process_info(ConnOwner, links),
    true = lists:member(Authority, OwnerLinks).

%% A successful pinned directory link must suppress the receiver's normal
%% header-driven Pubkey=>Addr learning. Preloading a divergent value makes the
%% assertion non-vacuous: an ordinary header would overwrite it with ?SELF.
pinned_dial_suppresses_hint_learning(Config) ->
    Pub = ?config(self_pubkey, Config),
    Existing = {"127.0.0.1", 14444},
    ok = quod_quic:learn(Pub, Existing),
    Ref = quod_quic:open_link_pinned(
            Pub, ?SELF, <<"chan-pinned-no-learn">>),
    receive
        {link_up, Ref, Pub, <<"chan-pinned-no-learn">>, LinkPid}
          when is_pid(LinkPid) -> ok
    after 5000 -> ct:fail(no_pinned_link_up)
    end,
    {ok, Existing} = quod_quic:resolve(Pub).

%% no_learn belongs to the isolated connection, not merely its first stream.
%% Force its accepted side to open a reverse stream: if the policy were not
%% inherited, that header would overwrite the deliberately divergent cache value.
pinned_reverse_stream_suppresses_hint_learning(Config) ->
    Pub = ?config(self_pubkey, Config),
    Forward = <<"chan-pinned-forward">>,
    Reverse = <<"chan-pinned-reverse">>,
    Existing = {"127.0.0.1", 14447},
    true = quod_reg:subscribe({channel, Forward}),
    Ref = quod_quic:open_link_pinned(Pub, ?SELF, Forward),
    OutLink = receive
                  {link_up, Ref, Pub, Forward, L} -> L
              after 5000 -> ct:fail(no_pinned_forward_link)
              end,
    ok = quod_link:send(OutLink, <<"find-inbound-connection">>),
    InLink = receive
                 {quod_message, {_, In}, Forward, <<"find-inbound-connection">>} -> In
             after 5000 -> ct:fail(no_pinned_forward_message)
             end,
    {links, [InboundConn]} = process_info(InLink, links),
    %% Publication happens only after the connection owner has authenticated
    %% the header and latched no_learn.
    ok = quod_quic:learn(Pub, Existing),
    ok = quod_conn:open_link(InboundConn, Reverse, self()),
    receive
        {link_up, _, Reverse, ReverseLink} when is_pid(ReverseLink) -> ok
    after 5000 -> ct:fail(no_pinned_reverse_link)
    end,
    {ok, Existing} = quod_quic:resolve(Pub).

%% Identity discovery derives the actual certificate key but leaves promotion
%% to its caller; its no-learn header must not touch the shared address cache.
identified_dial_suppresses_hint_learning(Config) ->
    Pub = ?config(self_pubkey, Config),
    Existing = {"127.0.0.1", 14445},
    ok = quod_quic:learn(Pub, Existing),
    Channel = <<"chan-identified-no-learn">>,
    Ref = quod_quic:open_link_identified(?SELF, Channel),
    receive
        {link_up, Ref, Pub, Channel, LinkPid}
          when is_pid(LinkPid) -> ok
    after 5000 -> ct:fail(no_identified_link_up)
    end,
    {ok, Existing} = quod_quic:resolve(Pub).

%% The new directory policy is scoped: existing endpoint/cache links keep
%% learning the authenticated header address exactly as before.
ordinary_dial_still_learns_hint(Config) ->
    Pub = ?config(self_pubkey, Config),
    Existing = {"127.0.0.1", 14446},
    ok = quod_quic:learn(Pub, Existing),
    ok = quod_quic:open_link(?SELF, <<"chan-ordinary-learn">>),
    receive
        {link_up, ?SELF, <<"chan-ordinary-learn">>, LinkPid} when is_pid(LinkPid) -> ok
    after 5000 -> ct:fail(no_ordinary_link_up)
    end,
    {ok, ?SELF} = quod_quic:resolve(Pub).

%% Dialing the right endpoint is insufficient: a different valid Ed25519
%% certificate must fail before any stream becomes usable.
pinned_dial_rejects_wrong_cert(Config) ->
    Expected = ?config(self_pubkey, Config),
    {_WrongPub, _} = WrongKP = quod_identity:generate(),
    WrongCert = quod_identity:mint_cert(WrongKP),
    WrongKey = quod_identity:key_term(WrongKP),
    Handler = fun(_Conn) ->
                  {ok, spawn(fun Ignore() -> receive _ -> Ignore() end end)}
              end,
    Port = 14596,
    Endpoint = {"127.0.0.1", Port},
    {ok, _} = quic:start_server(pinned_wrong_cert, Port,
                                #{cert => WrongCert, key => WrongKey, verify => true,
                                  alpn => [<<"quod">>], connection_handler => Handler}),
    try
        Ref = quod_quic:open_link_pinned(
                Expected, Endpoint, <<"chan-pinned-wrong-cert">>),
        receive
            {link_error, Ref, Expected, <<"chan-pinned-wrong-cert">>} -> ok;
            {link_up, Ref, Expected, <<"chan-pinned-wrong-cert">>, _} ->
                ct:fail(pinned_dial_accepted_wrong_cert)
        after 5000 -> ct:fail(no_pinned_mismatch_result)
        end
    after
        _ = quic:stop_server(pinned_wrong_cert)
    end.

%% A view id that is not a dialable {Host, Port} must be refused with link_error,
%% NOT crash the transport authority (it would take down every connection).
non_dialable_node_id(_Config) ->
    Authority = quod_reg:where({transport, node}),
    true = is_pid(Authority),
    ok = quod_quic:open_link(<<"not-a-host-port">>, <<"chan-x">>),
    receive
        {link_error, <<"not-a-host-port">>, <<"chan-x">>} -> ok
    after 3000 -> ct:fail(no_link_error)
    end,
    %% same pid still registered => the authority survived (did not crash/restart)
    Authority = quod_reg:where({transport, node}),
    true = is_process_alive(Authority).

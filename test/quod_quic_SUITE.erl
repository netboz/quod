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
         non_dialable_node_id/1, unacked_stream_no_link_up/1, dialer_presents_cert/1,
         mismatched_header_cannot_poison_cache/1,
         authenticated_coalesced_header_payload_delivered_once/1,
         no_learn_is_monotone_across_streams/1,
         resolve_and_dial_by_pubkey/1, pinned_dial_suppresses_hint_learning/1,
         pinned_reverse_stream_suppresses_hint_learning/1,
         private_seed_dial_suppresses_hint_learning/1,
         ordinary_dial_still_learns_hint/1,
         pinned_dial_rejects_wrong_cert/1]).

-define(PORT, 14599).
-define(SELF, {"127.0.0.1", ?PORT}).

all() -> [open_link_succeeds, message_roundtrip, bidirectional_reuse,
          channel_stream_reset_isolated, non_dialable_node_id,
          unacked_stream_no_link_up, dialer_presents_cert,
          mismatched_header_cannot_poison_cache,
          authenticated_coalesced_header_payload_delivered_once,
          no_learn_is_monotone_across_streams,
          resolve_and_dial_by_pubkey,
          pinned_dial_suppresses_hint_learning,
          pinned_reverse_stream_suppresses_hint_learning,
          private_seed_dial_suppresses_hint_learning,
          ordinary_dial_still_learns_hint, pinned_dial_rejects_wrong_cert].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(gproc),
    {ok, _} = application:ensure_all_started(quic),
    application:load(quod),
    %% the node's per-node Ed25519 identity cert — the production transport cert that
    %% quod_quic presents and verifies under mutual TLS (verify => true).
    {Pub, _} = KP = quod_identity:generate(),
    Cert = quod_identity:mint_cert(KP),
    Key  = quod_identity:key_term(KP),
    application:set_env(quod, listen_port, ?PORT),
    application:set_env(quod, node_addr, ?SELF),
    application:set_env(quod, node_pubkey, Pub),
    application:set_env(quod, identity_cert, Cert),
    application:set_env(quod, identity_key, Key),
    {ok, _} = application:ensure_all_started(quod),
    [{cert_der, Cert}, {key_term, Key}, {self_pubkey, Pub} | Config].

end_per_suite(_Config) ->
    _ = application:stop(quod),
    %% this suite runs the app IN the CT node (not a peer), so unset the env it set
    %% to avoid leaking a stale cert/port into any later same-node suite.
    _ = [application:unset_env(quod, K)
         || K <- [listen_port, node_addr, node_pubkey, identity_cert, identity_key]],
    ok.

%% Opening a link to our own listener over loopback yields a usable link pid.
open_link_succeeds(_Config) ->
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
        _ = catch quic:close(Conn, normal),
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
resolve_and_dial_by_pubkey(_Config) ->
    PK = crypto:strong_rand_bytes(32),
    ok = quod_quic:learn(PK, ?SELF),
    ok = quod_quic:open_link(PK, <<"chan-pk">>),
    receive
        {link_up, PK, <<"chan-pk">>, LinkPid} when is_pid(LinkPid) -> ok
    after 5000 -> ct:fail(no_link_up_by_pubkey)
    end.

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

%% Private direct-seed TOFU derives the actual certificate key but keeps it route-local;
%% its no-learn header must not touch the shared address cache either.
private_seed_dial_suppresses_hint_learning(Config) ->
    Pub = ?config(self_pubkey, Config),
    Existing = {"127.0.0.1", 14445},
    ok = quod_quic:learn(Pub, Existing),
    Channel = <<"chan-private-seed-no-learn">>,
    Ref = quod_quic:open_link_private_seed(?SELF, Channel),
    receive
        {link_up, Ref, Pub, Channel, LinkPid}
          when is_pid(LinkPid) -> ok
    after 5000 -> ct:fail(no_private_seed_link_up)
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

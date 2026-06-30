-module(quod_quic_SUITE).
-moduledoc """
Integration test for the QUIC transport over a real loopback connection: a node
opens a link to itself, and a framed payload is pushed across a real QUIC stream
and observed via the gproc `{channel, _}` property as `{quod_message, ...}`.
""".

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([open_link_succeeds/1, message_roundtrip/1, bidirectional_reuse/1,
         non_dialable_node_id/1, unacked_stream_no_link_up/1]).

-define(PORT, 14599).
-define(SELF, {"127.0.0.1", ?PORT}).

all() -> [open_link_succeeds, message_roundtrip, bidirectional_reuse, non_dialable_node_id,
          unacked_stream_no_link_up].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(gproc),
    {ok, _} = application:ensure_all_started(quic),
    application:load(quod),
    %% the node's per-node Ed25519 identity cert — the production transport cert that
    %% quod_quic presents and verifies under mutual TLS (verify => true).
    KP   = quod_identity:generate(),
    Cert = quod_identity:mint_cert(KP),
    Key  = quod_identity:key_term(KP),
    application:set_env(quod, listen_port, ?PORT),
    application:set_env(quod, node_id, ?SELF),
    application:set_env(quod, identity_cert, Cert),
    application:set_env(quod, identity_key, Key),
    {ok, _} = application:ensure_all_started(quod),
    [{cert_der, Cert}, {key_term, Key} | Config].

end_per_suite(_Config) ->
    _ = application:stop(quod),
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

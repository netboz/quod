-module(quod_quicer_SUITE).
-moduledoc """
Integration test for the QUIC transport over a real loopback connection: a node
opens a link to itself, and a framed payload is pushed across a real QUIC stream
and observed via the gproc `{channel, _}` property as `{quod_message, ...}`.
""".

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([open_link_succeeds/1, message_roundtrip/1, bidirectional_reuse/1,
         non_dialable_node_id/1]).

-define(PORT, 14599).
-define(SELF, {"127.0.0.1", ?PORT}).

all() -> [open_link_succeeds, message_roundtrip, bidirectional_reuse, non_dialable_node_id].

init_per_suite(Config) ->
    %% self-contained dev cert for the QUIC listener (TLS 1.3 is mandatory)
    CertDir = filename:join(?config(priv_dir, Config), "certs"),
    ok = filelib:ensure_dir(filename:join(CertDir, "x")),
    Cert = filename:join(CertDir, "cert.pem"),
    Key  = filename:join(CertDir, "key.pem"),
    _ = os:cmd("openssl req -x509 -newkey rsa:2048 -nodes -keyout " ++ Key ++
               " -out " ++ Cert ++ " -days 1 -subj /CN=quod-test 2>&1"),
    true = filelib:is_regular(Cert) andalso filelib:is_regular(Key),

    {ok, _} = application:ensure_all_started(gproc),
    {ok, _} = application:ensure_all_started(quicer),
    application:load(quod),
    application:set_env(quod, listen_port, ?PORT),
    application:set_env(quod, node_id, ?SELF),
    application:set_env(quod, certfile, Cert),
    application:set_env(quod, keyfile, Key),
    {ok, _} = application:ensure_all_started(quod),
    Config.

end_per_suite(_Config) ->
    _ = application:stop(quod),
    ok.

%% Opening a link to our own listener over loopback yields a usable link pid.
open_link_succeeds(_Config) ->
    ok = quod_quicer:open_link(?SELF, <<"chan-a">>),
    receive
        {link_up, ?SELF, <<"chan-a">>, LinkPid} when is_pid(LinkPid) -> ok
    after 5000 ->
        ct:fail(no_link_up)
    end.

%% A payload sent on the outbound link arrives at the inbound link and is
%% published on the channel property as {quod_message, {Peer, _}, Channel, _}.
message_roundtrip(_Config) ->
    true = quod_reg:subscribe({channel, <<"chan-b">>}),
    ok = quod_quicer:open_link(?SELF, <<"chan-b">>),
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
    ok = quod_quicer:open_link(?SELF, <<"chan-c">>),
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

%% A view id that is not a dialable {Host, Port} must be refused with link_error,
%% NOT crash the transport authority (it would take down every connection).
non_dialable_node_id(_Config) ->
    Authority = quod_reg:where({transport, node}),
    true = is_pid(Authority),
    ok = quod_quicer:open_link(<<"not-a-host-port">>, <<"chan-x">>),
    receive
        {link_error, <<"chan-x">>} -> ok
    after 3000 -> ct:fail(no_link_error)
    end,
    %% same pid still registered => the authority survived (did not crash/restart)
    Authority = quod_reg:where({transport, node}),
    true = is_process_alive(Authority).

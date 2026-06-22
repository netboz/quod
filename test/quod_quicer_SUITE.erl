-module(quod_quicer_SUITE).
-moduledoc """
Integration test for the QUIC transport: a single node listens, dials itself
over loopback, and a framed message is pushed across a real QUIC stream and
observed via the gproc per-peer event property.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([connect_succeeds/1, message_roundtrip/1]).

-define(PORT, 14599).

all() -> [connect_succeeds, message_roundtrip].

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
    application:set_env(quod, certfile, Cert),
    application:set_env(quod, keyfile, Key),
    {ok, _} = application:ensure_all_started(quod),
    Config.

end_per_suite(_Config) ->
    _ = application:stop(quod),
    ok.

%% Dialing our own listener over loopback yields a usable peer handle.
connect_succeeds(_Config) ->
    {ok, Peer} = quod_quicer:connect("127.0.0.1", ?PORT),
    ?assertMatch(#{conn := _, stream := _, id := _}, Peer),
    ok.

%% A frame sent on the outbound peer arrives at the inbound handler and is
%% published on that inbound peer's gproc property as {quod_message, ...}.
message_roundtrip(_Config) ->
    Before = peer_ids(),
    {ok, Out} = quod_quicer:connect("127.0.0.1", ?PORT),
    OutId = maps:get(id, Out),
    {ok, InId} = wait_new_inbound(Before, OutId, 60),
    true = quod_reg:subscribe({peer, InId}),
    ok = quod_quicer:send(Out, <<"c">>, <<"hello">>),
    receive
        {quod_message, _Peer, <<"c">>, <<"hello">>} -> ok
    after 3000 ->
        ct:fail({no_message, {inbound, InId}})
    end.

%% --- helpers -------------------------------------------------------------

peer_ids() ->
    gproc:select([{{{n, l, {peer, '$1'}}, '_', '_'}, [], ['$1']}]).

wait_new_inbound(_Before, _OutId, 0) ->
    {error, timeout};
wait_new_inbound(Before, OutId, N) ->
    case [Id || Id <- peer_ids() -- Before, Id =/= OutId] of
        [InId | _] -> {ok, InId};
        [] -> timer:sleep(50), wait_new_inbound(Before, OutId, N - 1)
    end.

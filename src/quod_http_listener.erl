-module(quod_http_listener).
-moduledoc """
The shared cowboy-listener boot used by every quod HTTP front.

Both the operational Explorer (`m:quod_explorer`) and the browser client
(`m:quod_client`) bring up a cowboy listener the same way: compile routes, bind,
tolerate a listener that survived a brutal restart, and stop it on the way out.
This module owns that sequence once.

What it deliberately does **not** own is the failure policy. A bind failure means
different things to different endpoints — the Explorer is optional tooling and
degrades to no listener, while the client endpoint is the only surface its users
can reach and must not pretend to be healthy without one. So `start/1` reports
the outcome and each caller decides, in view of its own users, what a failure
means.
""".

-export([start/1, stop/1]).

-type opts() :: #{name := atom(),
                  ip := inet:ip_address(),
                  port := inet:port_number(),
                  routes := cowboy_router:routes(),
                  stream_handlers => [module()],
                  tls => quod_client_tls:material()}.
-export_type([opts/0]).

-doc """
Bind one listener for `Routes`.

`started` and `already_started` are both success: the second means a listener
from a previous incarnation outlived its owner (a brutal kill skips `stop/1`),
and reusing it keeps the endpoint serving. Note that its **dispatch is the old
one** — a route change needs a real listener restart, not a supervisor bounce.

Passing `tls` serves HTTPS with that certificate; without it the listener is
plain HTTP, which is correct for a loopback-bound operational panel and wrong
for anything a browser must run Web Crypto on (see `m:quod_client_tls`).
""".
-spec start(opts()) -> {ok, started | already_started} | {error, term()}.
start(#{name := Name, ip := Ip, port := Port, routes := Routes} = Opts) ->
    Transport = [{port, Port}, {ip, Ip}],
    Protocol = protocol_opts(Routes, Opts),
    Result = case maps:find(tls, Opts) of
                 {ok, Tls} ->
                     cowboy:start_tls(Name, Transport ++ tls_opts(Tls), Protocol);
                 error ->
                     cowboy:start_clear(Name, Transport, Protocol)
             end,
    case Result of
        {ok, _Pid} -> {ok, started};
        {error, {already_started, _Pid}} -> {ok, already_started};
        {error, _} = Error -> Error
    end.

-doc "Stop a listener started by `start/1`; a listener that is already gone is fine.".
-spec stop(atom()) -> ok.
stop(Name) ->
    _ = cowboy:stop_listener(Name),
    ok.

protocol_opts(Routes, Opts) ->
    Base = #{env => #{dispatch => cowboy_router:compile(Routes)}},
    case maps:get(stream_handlers, Opts, []) of
        [] -> Base;
        Handlers -> Base#{stream_handlers => Handlers ++ [cowboy_stream_h]}
    end.

%% Either an operator's PEM files or in-memory material. `ssl` takes a DER key as
%% `{Type, Der}`, and the identity modules hand out decoded key records, so
%% re-encode under the record's own ASN.1 type.
tls_opts(#{certfile := CertFile, keyfile := KeyFile}) ->
    [{certfile, CertFile}, {keyfile, KeyFile}];
tls_opts(#{cert := Cert, key := Key}) ->
    Type = element(1, Key),
    [{cert, Cert}, {key, {Type, public_key:der_encode(Type, Key)}}].

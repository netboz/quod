-module(quod_http_headers_h).
-moduledoc """
A cowboy stream handler that stamps fixed security headers on every response.

The client endpoint hands a browser an encrypted Ed25519 key and a passphrase
prompt, so the page needs a content-security policy, and it needs one on *every*
response — including the ones `cowboy_static` produces for the bundle, which no
application handler ever sees. Intercepting the response command is the only
seam that covers all of them.

The policy is deliberately strict and matches what the client actually is: a
self-contained bundle served from its own origin, talking only to that origin.
It loads no third-party script, embeds no frame, and is never framed itself.
""".

-behaviour(cowboy_stream).

-export([init/3, data/4, info/3, terminate/3, early_error/5]).

%% `script-src 'self'` is enough because the bundle is a real file served from
%% this origin — Vite emits no inline script and no eval. Styles are a single
%% emitted stylesheet, so they need no inline allowance either.
-define(CSP,
        <<"default-src 'none'; "
          "script-src 'self'; "
          "style-src 'self'; "
          "img-src 'self' data:; "
          "font-src 'self'; "
          "connect-src 'self'; "
          "base-uri 'none'; "
          "form-action 'none'; "
          "frame-ancestors 'none'">>).

-define(HEADERS,
        #{<<"content-security-policy">> => ?CSP,
          <<"x-content-type-options">> => <<"nosniff">>,
          <<"referrer-policy">> => <<"no-referrer">>,
          %% The client has no use for any of these, and a page holding a
          %% signing key should not be able to reach for them by accident.
          <<"permissions-policy">> =>
              <<"geolocation=(), microphone=(), camera=(), payment=()">>}).

init(StreamID, Req, Opts) ->
    stamp(cowboy_stream:init(StreamID, Req, Opts)).

data(StreamID, IsFin, Data, Next) ->
    stamp(cowboy_stream:data(StreamID, IsFin, Data, Next)).

info(StreamID, Info, Next) ->
    stamp(cowboy_stream:info(StreamID, Info, Next)).

terminate(StreamID, Reason, Next) ->
    cowboy_stream:terminate(StreamID, Reason, Next).

early_error(StreamID, Reason, PartialReq, Resp, Opts) ->
    stamp_response(cowboy_stream:early_error(
                     StreamID, Reason, PartialReq, Resp, Opts)).

stamp({Commands, Next}) -> {[stamp_response(C) || C <- Commands], Next}.

%% Only the header-bearing commands are rewritten; every other command passes
%% through untouched. An explicit header already set by a handler wins, so a
%% route can still tighten (never silently loosen) one of these.
stamp_response({response, Status, Headers, Body}) ->
    {response, Status, merge(Headers), Body};
stamp_response({headers, Status, Headers}) ->
    {headers, Status, merge(Headers)};
stamp_response(Command) ->
    Command.

merge(Headers) when is_map(Headers) -> maps:merge(?HEADERS, Headers);
merge(Headers) when is_list(Headers) ->
    maps:to_list(maps:merge(?HEADERS, maps:from_list(Headers))).

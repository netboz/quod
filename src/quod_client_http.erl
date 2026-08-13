-module(quod_client_http).
-moduledoc """
Typed HTTP boundary for the dedicated browser client listener.

Only fixed authentication and user-registration messages are accepted here.
This module has no parser and no route that can receive a Prolog goal.
""".

-behaviour(cowboy_handler).

-export([init/2]).

-define(MAX_AUTH_BODY, 4096).

init(Req0, health) ->
    {ok, text_reply(200, <<"ok\n">>, Req0), health};
init(Req0, auth_challenge) ->
    post_json(Req0, auth_challenge, fun auth_challenge/2);
init(Req0, auth_complete) ->
    post_json(Req0, auth_complete, fun auth_complete/2);
init(Req0, user_register) ->
    post_json(Req0, user_register, fun user_register/2).

%% The handler is given the decoded body and the request, so a route that needs
%% something more from the request (the peer address, for registration) reads it
%% itself rather than forking this function.
post_json(Req0, State, Handler) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            {Code, Reply, Req} = read_json(Req0, Handler),
            {ok, json_reply(Code, Reply, Req), State};
        _ ->
            {ok, json_reply(405, #{error => method_not_allowed}, Req0), State}
    end.

read_json(Req0, Handler) ->
    case cowboy_req:read_body(Req0, #{length => ?MAX_AUTH_BODY}) of
        %% `length` is only the chunk size cowboy waits for, not a limit: a body
        %% that arrives in one piece is delivered whole however large it is. The
        %% cap is this size check, not the read option.
        {ok, Body, Req} when byte_size(Body) =< ?MAX_AUTH_BODY ->
            Decoded = try json:decode(Body) catch _:_ -> bad_json end,
            {Code, Reply} = Handler(Decoded, Req),
            {Code, Reply, Req};
        {ok, _Oversized, Req} ->
            {413, #{error => body_too_large}, Req};
        {more, _Partial, Req} ->
            {413, #{error => body_too_large}, Req}
    end.

auth_challenge(#{<<"public_key">> := PublicKey64,
                 <<"client_nonce">> := ClientNonce64}, Req) ->
    case {decode_b64url(PublicKey64, 32), decode_b64url(ClientNonce64, 32)} of
        {{ok, PublicKey}, {ok, ClientNonce}} ->
            auth_reply(quod_client_auth:issue_challenge(
                         PublicKey, ClientNonce, peer_ip(Req)));
        _ -> {400, #{error => invalid_auth_request}}
    end;
auth_challenge(_, _Req) ->
    {400, #{error => invalid_auth_request}}.

auth_complete(#{<<"challenge_id">> := ChallengeId64,
                <<"signature">> := Signature64}, _Req) ->
    case {decode_b64url(ChallengeId64, 16), decode_b64url(Signature64, 64)} of
        {{ok, ChallengeId}, {ok, Signature}} ->
            auth_reply(quod_client_auth:complete_challenge(ChallengeId, Signature));
        _ -> {400, #{error => invalid_auth_request}}
    end;
auth_complete(_, _Req) ->
    {400, #{error => invalid_auth_request}}.

user_register(#{<<"session_id">> := SessionId64,
                <<"client_nonce">> := ClientNonce64,
                <<"signature">> := Signature64}, Req) ->
    case {decode_b64url(SessionId64, 32), decode_b64url(ClientNonce64, 32),
          decode_b64url(Signature64, 64)} of
        {{ok, SessionId}, {ok, ClientNonce}, {ok, Signature}} ->
            registration_result(
              quod_client_registration:register(
                SessionId, ClientNonce, Signature, peer_ip(Req)));
        _ -> {400, #{error => invalid_registration_request}}
    end;
user_register(_, _Req) ->
    {400, #{error => invalid_registration_request}}.

registration_result({ok, #{user_id := UserId, namespace := Namespace,
                          registration_height := Height}}) ->
    {201, #{user_id => UserId, namespace => Namespace,
            registration_height => Height}};
registration_result({error, registration_not_authorized}) ->
    {403, #{error => registration_not_authorized}};
registration_result({error, invalid_registration_signature}) ->
    {401, #{error => invalid_registration_signature}};
registration_result({error, invalid_registration_request}) ->
    {400, #{error => invalid_registration_request}};
registration_result({error, invalid_session}) ->
    {401, #{error => authentication_failed}};
registration_result({error, client_registration_rate_limited}) ->
    {429, #{error => registration_rate_limited}};
registration_result({error, client_registration_busy}) ->
    {429, #{error => registration_busy}};
registration_result({error, client_auth_unavailable}) ->
    {503, #{error => client_auth_unavailable}};
registration_result({error, registration_unavailable}) ->
    {503, #{error => registration_unavailable}};
registration_result({error, outcome_unknown}) ->
    {503, #{error => registration_outcome_unknown}};
registration_result({error, _}) ->
    {503, #{error => registration_unavailable}};
registration_result(_) ->
    {403, #{error => registration_not_authorized}}.

auth_reply({ok, #{challenge_id := ChallengeId, server_nonce := ServerNonce,
                  expires_ms := ExpiresMs, node_key := NodeKey,
                  network_id := NetworkId}}) ->
    {200, #{challenge_id => b64url(ChallengeId),
            server_nonce => b64url(ServerNonce),
            expires_ms => ExpiresMs,
            node_key => b64url(NodeKey),
            network_id => b64url(NetworkId)}};
auth_reply({ok, #{session_id := SessionId, expires_ms := ExpiresMs,
                  public_key := PublicKey, user_id := UserId, namespace := Namespace}}) ->
    {200, #{session_id => b64url(SessionId),
            expires_ms => ExpiresMs,
            public_key => b64url(PublicKey),
            user_id => UserId,
            namespace => Namespace}};
auth_reply({error, client_auth_unavailable}) ->
    {503, #{error => client_auth_unavailable}};
auth_reply({error, client_auth_busy}) ->
    {429, #{error => client_auth_busy}};
auth_reply({error, client_session_busy}) ->
    {429, #{error => client_session_busy}};
auth_reply({error, client_auth_rate_limited}) ->
    {429, #{error => client_auth_rate_limited}};
%% A malformed request is not a failed login: reporting it as 401 sends a client
%% into a retry-authentication loop over what is really a bad field.
auth_reply({error, invalid_public_key}) ->
    {400, #{error => invalid_auth_request}};
auth_reply({error, invalid_client_nonce}) ->
    {400, #{error => invalid_auth_request}};
auth_reply({error, _}) ->
    {401, #{error => authentication_failed}}.

%% Strict url-safe base64 (OTP's own): unlike a hand-rolled alphabet swap it
%% refuses standard-alphabet input, so one request has exactly one encoding.
decode_b64url(Bin, Size) when is_binary(Bin), byte_size(Bin) =< 256 ->
    try base64:decode(Bin, #{mode => urlsafe, padding => false}) of
        <<Bytes:Size/binary>> -> {ok, Bytes};
        _ -> error
    catch error:_ -> error
    end;
decode_b64url(_, _) -> error.

b64url(Bytes) -> base64:encode(Bytes, #{mode => urlsafe, padding => false}).

peer_ip(Req) ->
    {Address, _Port} = cowboy_req:peer(Req),
    Address.

json_reply(Code, Json, Req) ->
    cowboy_req:reply(
      Code, #{<<"content-type">> => <<"application/json">>,
              <<"cache-control">> => <<"no-store">>},
      iolist_to_binary(json:encode(Json)), Req).

text_reply(Code, Body, Req) ->
    cowboy_req:reply(
      Code, #{<<"content-type">> => <<"text/plain">>,
              <<"cache-control">> => <<"no-store">>}, Body, Req).

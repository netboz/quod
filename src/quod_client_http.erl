-module(quod_client_http).
-moduledoc """
Typed HTTP boundary for the dedicated browser client listener.

Authentication, user registration, and the reviewed signed read request are
accepted here.  Goal text is never parsed in this Cowboy process: it remains
inside the signed binary request and crosses the atom-safe ingress boundary
only after session and signature validation.
""".

-behaviour(cowboy_handler).

-export([init/2]).
-ifdef(TEST).
-export([signed_read_result/1]).
-endif.

-include("quod_client_goal_limits.hrl").

-define(MAX_AUTH_BODY, 4096).
-define(MAX_SIGNED_GOAL_BODY,
        ((((?QUOD_CLIENT_GOAL_REQUEST_BYTES + 2) div 3) * 4) + 1024)).

init(Req0, health) ->
    {ok, text_reply(200, <<"ok\n">>, Req0), health};
init(Req0, auth_challenge) ->
    post_json(Req0, auth_challenge, ?MAX_AUTH_BODY, fun auth_challenge/2);
init(Req0, auth_complete) ->
    post_json(Req0, auth_complete, ?MAX_AUTH_BODY, fun auth_complete/2);
init(Req0, user_register) ->
    post_json(Req0, user_register, ?MAX_AUTH_BODY, fun user_register/2);
init(Req0, signed_goal_read) ->
    post_json(Req0, signed_goal_read, ?MAX_SIGNED_GOAL_BODY,
              fun signed_goal_read/2).

%% The handler is given the decoded body and the request, so a route that needs
%% something more from the request (the peer address, for registration) reads it
%% itself rather than forking this function.
post_json(Req0, State, MaxBody, Handler) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            {Code, Reply, Req} = read_json(Req0, MaxBody, Handler),
            {ok, json_reply(Code, Reply, Req), State};
        _ ->
            {ok, json_reply(405, #{error => method_not_allowed}, Req0), State}
    end.

read_json(Req0, MaxBody, Handler) ->
    case cowboy_req:read_body(Req0, #{length => MaxBody}) of
        %% `length` is only the chunk size cowboy waits for, not a limit: a body
        %% that arrives in one piece is delivered whole however large it is. The
        %% cap is this size check, not the read option.
        {ok, Body, Req} when byte_size(Body) =< MaxBody ->
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

signed_goal_read(#{<<"session_id">> := SessionId64,
                   <<"request">> := Request64,
                   <<"signature">> := Signature64}, Req) ->
    case {decode_b64url(SessionId64, 32),
          decode_b64url_bounded(
            Request64, ?QUOD_CLIENT_GOAL_REQUEST_BYTES),
          decode_b64url(Signature64, 64)} of
        {{ok, SessionId}, {ok, RequestBytes}, {ok, Signature}} ->
            signed_read_result(
              quod_client_goal_ingress:read(
                SessionId, RequestBytes, Signature, peer_ip(Req)));
        _ ->
            {400, #{error => invalid_signed_goal_request}}
    end;
signed_goal_read(_, _Req) ->
    {400, #{error => invalid_signed_goal_request}}.

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

signed_read_result({ok, Evidence, Result}) ->
    signed_proof_result(Evidence, Result);
signed_read_result({error, invalid_session}) ->
    {401, #{error => authentication_failed}};
signed_read_result({error, session_principal_mismatch}) ->
    {401, #{error => session_principal_mismatch}};
signed_read_result({error, invalid_signature}) ->
    {401, #{error => invalid_signature}};
signed_read_result({error, client_auth_unavailable}) ->
    {503, #{error => client_auth_unavailable}};
signed_read_result({error, client_goal_rate_limited}) ->
    {429, #{error => goal_rate_limited}};
signed_read_result({error, client_goal_busy}) ->
    {503, #{error => goal_ingress_busy}};
signed_read_result({error, client_symbol_budget_exhausted}) ->
    {503, #{error => symbol_budget_exhausted}};
signed_read_result({error, atom_limit}) ->
    {503, #{error => atom_table_pressure}};
signed_read_result({error, too_many_new_atoms}) ->
    {413, #{error => goal_vocabulary_too_large}};
signed_read_result({error, {too_large, Field}}) ->
    {413, #{error => field_too_large, field => atom_to_binary(Field)}};
signed_read_result({error, signed_target_unavailable}) ->
    {503, #{error => signed_target_unavailable}};
signed_read_result({error, signed_goal_unavailable}) ->
    {503, #{error => signed_goal_unavailable}};
signed_read_result({error, expired}) ->
    {410, #{error => signed_goal_expired}};
signed_read_result({error, Reason})
  when Reason =:= invalid_request; Reason =:= invalid_goal;
       Reason =:= wrong_network; Reason =:= wrong_target;
       Reason =:= invalid_admission_time;
       Reason =:= deadline_exceeds_session;
       Reason =:= unsupported_goal_mode;
       Reason =:= malformed_material;
       Reason =:= invalid_user_principal ->
    {400, #{error => Reason}};
signed_read_result({error, _}) ->
    {503, #{error => signed_goal_unavailable}}.

signed_proof_result(Evidence, {ok, Bindings, Height})
  when is_list(Bindings), is_integer(Height), Height >= 0 ->
    {200, evidence_json(
            Evidence,
            #{result => ok, height => Height,
              bindings => [signed_bindings(Evidence, B) || B <- Bindings]})};
signed_proof_result(Evidence, fail) ->
    {200, evidence_json(Evidence, #{result => fail})};
signed_proof_result(Evidence, {fail, Reasons}) when is_list(Reasons) ->
    {200, evidence_json(
            Evidence,
            #{result => fail,
              reasons => [quod_explorer_http:prolog_text(Reason)
                          || Reason <- Reasons]})};
signed_proof_result(_Evidence, {error, signed_scope_unavailable}) ->
    {409, #{error => signed_scope_unavailable}};
signed_proof_result(_Evidence, {error, read_only}) ->
    {409, #{error => read_only}};
signed_proof_result(_Evidence, {error, no_such_namespace}) ->
    {503, #{error => signed_target_unavailable}};
signed_proof_result(_Evidence, {error, wrong_genesis_anchor}) ->
    {503, #{error => signed_target_unavailable}};
signed_proof_result(_Evidence, {error, rebuilding}) ->
    {503, #{error => ontology_rebuilding}};
signed_proof_result(_Evidence, {error, busy}) ->
    {503, #{error => ontology_busy}};
signed_proof_result(_Evidence, {error, _}) ->
    {503, #{error => proof_unavailable}}.

evidence_json(#{request_digest := Digest,
                request := #{operation_id := OperationId}}, Result) ->
    Result#{request_digest => b64url(Digest),
            operation_id => b64url(OperationId)}.

signed_bindings(#{variables := Variables}, Bindings) when is_map(Bindings) ->
    maps:from_list(
      [{Name, quod_explorer_http:prolog_text(Value)}
       || {Name, Index} <- Variables,
          {ok, Value} <- [maps:find(Index, Bindings)]]).

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

decode_b64url_bounded(Bin, MaxBytes)
  when is_binary(Bin), is_integer(MaxBytes), MaxBytes >= 0,
       byte_size(Bin) =< ((MaxBytes + 2) div 3) * 4 ->
    try base64:decode(Bin, #{mode => urlsafe, padding => false}) of
        Bytes when byte_size(Bytes) =< MaxBytes -> {ok, Bytes};
        _ -> error
    catch error:_ -> error
    end;
decode_b64url_bounded(_, _) -> error.

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

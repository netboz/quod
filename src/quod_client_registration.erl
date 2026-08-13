-module(quod_client_registration).
-moduledoc """
Constrained user-home registration command.

This trusted in-VM boundary consumes an authenticated client session plus a
fresh user signature. It derives the namespace, fixed genesis options, and root
lifecycle action from the session public key. It never receives ontology source,
a namespace, or a Prolog goal from the browser.

The order of the checks is deliberate. The signature is proved **before** the
open-registration budget is charged, so requests that were never authentic
cannot spend the allowance that protects durable ontology creation — otherwise
anyone holding a single session could exhaust a node's registrations without
performing one.
""".

-export([register/4]).

-doc """
Register the user home for an authenticated session.

`Peer` is the requesting address, charged against the open-registration budget
once the request has proved itself.
""".
-spec register(binary(), binary(), binary(), term()) ->
          {ok, map()} | {error, term()}.
register(SessionId, ClientNonce, Signature, Peer) ->
    case quod_client_auth:session(SessionId) of
        {ok, #{public_key := PublicKey, principal := Principal}} ->
            verified(PublicKey, Principal, ClientNonce, Signature, Peer);
        {error, _} = Error -> Error
    end.

verified(PublicKey, Principal, ClientNonce, Signature, Peer) ->
    case quod_ontology:genesis_anchor(quod_ontology:root_ns()) of
        {ok, NetworkId} ->
            case quod_user:verify_registration(
                   NetworkId, PublicKey, ClientNonce, Signature) of
                {ok, Identity} -> charged(Identity, Principal, Peer);
                {error, _} = Error -> Error
            end;
        {error, _} ->
            {error, registration_unavailable}
    end.

charged(Identity, Principal, Peer) ->
    case quod_client_auth:reserve_registration(Peer) of
        ok -> found_home(Identity, Principal);
        {error, _} = Error -> Error
    end.

%% The action comes from `quod_user`, which owns what a registration may do; it
%% is built from the identity verification already produced rather than derived
%% from the key a second time.
found_home(Identity, Principal) ->
    outcome(Identity,
            quod_prolog:execute_as(
              quod_ontology:root_ns(), quod_user:home_action(Identity),
              Principal)).

%% Only the public triple leaves this boundary — the caller has no use for the
%% genesis terms and options that verification carried along.
outcome(Identity, {ok, _Bindings, Height}) ->
    {ok, maps:with([user_id, namespace, registration_height],
                   Identity#{registration_height => Height})};
outcome(_Identity, {error, _} = Error) -> Error;
outcome(_Identity, fail) -> {error, registration_not_authorized};
outcome(_Identity, {fail, _}) -> {error, registration_not_authorized}.

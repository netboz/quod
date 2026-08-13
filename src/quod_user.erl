-module(quod_user).
-moduledoc """
Pure identity rules for one user's home ontology.

`quod:user` is the shared user model and registration policy; it is *not* a
global table of people.  Each Ed25519 public key deterministically names one
small user-home ontology.  The client-registration ingress will use this
module to constrain its foundation request before it reaches the trusted
ontology lifecycle API.

This module deliberately does not authenticate a browser or create an
ontology. It only constructs the one fixed owner ACL used by a valid home;
it never accepts arbitrary invocation authority or source terms. Keeping the
namespace and genesis construction pure makes them independently testable.
""".

-export([identity/1, home_namespace/1, home_options/1, home_action/1,
         valid_home/2, registration_bytes/3, verify_registration/4,
         challenge_bytes/7, verify_challenge/7, principal/1]).

-define(USER_DOMAIN, <<"quod-user-id-v1:">>).
-define(REGISTRATION_DOMAIN, <<"quod_user_registration_v1", 0>>).
-define(CHALLENGE_DOMAIN, <<"quod_user_challenge_v1", 0>>).
-define(HOME_ACL_SOURCE,
        <<"can_invoke(_, user(Key), _, _) :- user_key(_, Key, active).\n">>).

-type public_key() :: <<_:256>>.
-type user_id() :: binary().
-type namespace() :: binary().

-spec identity(term()) ->
          {ok, #{user_id := user_id(), namespace := namespace(),
                 public_key := public_key()}} |
          {error, invalid_public_key}.
identity(<<_:256>> = PublicKey) ->
    Digest = crypto:hash(sha256, [?USER_DOMAIN, PublicKey]),
    Hex = binary:encode_hex(Digest, lowercase),
    {ok, #{user_id => <<"user-", Hex/binary>>,
           namespace => <<"user:", Hex/binary>>,
           public_key => PublicKey}};
identity(_PublicKey) ->
    {error, invalid_public_key}.

-doc "The only durable principal representation for an authenticated user key.".
-spec principal(term()) -> {ok, {user, public_key()}} | {error, invalid_public_key}.
principal(<<_:256>> = PublicKey) -> {ok, {user, PublicKey}};
principal(_PublicKey) -> {error, invalid_public_key}.

-spec home_namespace(term()) -> {ok, namespace()} | {error, invalid_public_key}.
home_namespace(PublicKey) ->
    case identity(PublicKey) of
        {ok, #{namespace := Namespace}} -> {ok, Namespace};
        {error, _} = Error -> Error
    end.

-doc """
Return the complete, fixed user-home genesis options for `PublicKey`: the four
data facts derived from the key, plus the one fixed owner ACL rule.
""".
-spec home_options(term()) -> {ok, [tuple()]} | {error, invalid_public_key}.
home_options(PublicKey) ->
    with_identity(PublicKey, fun options_of/1).

%% `identity/1` is the sole validator of a public key, so every derived value is
%% a pure function of its result. Deriving them from one identity keeps the hash
%% off the repeat path and leaves a single place to extend.
with_identity(PublicKey, Derive) ->
    case identity(PublicKey) of
        {ok, Identity} -> {ok, Derive(Identity)};
        {error, _} = Error -> Error
    end.

terms_of(#{user_id := UserId, namespace := Namespace, public_key := PublicKey}) ->
    [{user, UserId},
     {user_key, UserId, PublicKey, active},
     {user_home, UserId, Namespace},
     {user_home_version, 1}].

%% Variables in genesis facts materialize as `unbound`, so the owner ACL must be
%% a fixed source rule over the fixed key fact.
options_of(Identity) ->
    [{terms, terms_of(Identity)}, {source, ?HOME_ACL_SOURCE}].

-doc "Verify that `Options` are exactly the fixed genesis for `PublicKey`.".
-spec valid_home(term(), term()) -> boolean().
valid_home(PublicKey, Options) ->
    case home_options(PublicKey) of
        {ok, Options} -> true;
        _ -> false
    end.

-doc """
The sole legal lifecycle action founding this user's home.

Takes the identity map `verify_registration/4` already produced rather than a
key, so the one caller that needs it does not re-derive what it is holding — and
so this stays the single definition of what a registration is allowed to do.
""".
-spec home_action(#{namespace := namespace(), _ => _}) -> tuple().
home_action(#{namespace := Namespace} = Identity) ->
    {create_ontology, Namespace, options_of(Identity)}.

-doc """
Canonical bytes a new user signs before requesting foundation of its own home.

`NetworkId` is the pinned 32-byte root genesis anchor and `ClientNonce` is a
fresh 32-byte client-generated value.  Profile data is deliberately absent:
it is neither identity nor a reason to change a registration signature.
""".
-spec registration_bytes(term(), term(), term()) ->
          {ok, binary()} | {error, invalid_registration_request}.
registration_bytes(<<_:256>> = NetworkId, <<_:256>> = PublicKey,
                   <<_:256>> = ClientNonce) ->
    %% This is an explicit cross-language binary wire layout, not Erlang ETF:
    %% DomainNul || NetworkId32 || PublicKey32 || ClientNonce32.
    {ok, <<?REGISTRATION_DOMAIN/binary, NetworkId/binary, PublicKey/binary,
           ClientNonce/binary>>};
registration_bytes(_NetworkId, _PublicKey, _ClientNonce) ->
    {error, invalid_registration_request}.

-doc """
Verify a browser registration request and derive its only legal user home.

The caller still owns rate limiting, duplicate handling, and the subsequent
trusted lifecycle action.  It must never take a namespace, source, or genesis
term from the client.
""".
-spec verify_registration(term(), term(), term(), term()) ->
          {ok, #{user_id := user_id(), namespace := namespace(),
                 public_key := public_key(), terms := [tuple()],
                 options := [tuple()]}} |
          {error, invalid_registration_request | invalid_registration_signature}.
verify_registration(NetworkId, PublicKey, ClientNonce, Signature)
  when is_binary(Signature), byte_size(Signature) =:= 64 ->
    case registration_bytes(NetworkId, PublicKey, ClientNonce) of
        {ok, Bytes} ->
            verified_registration(
              quod_identity:verify(Signature, Bytes, PublicKey), PublicKey);
        {error, _} = Error ->
            Error
    end;
verify_registration(_NetworkId, _PublicKey, _ClientNonce, _Signature) ->
    {error, invalid_registration_request}.

verified_registration(true, PublicKey) ->
    with_identity(
      PublicKey,
      fun(Identity) ->
              Identity#{terms => terms_of(Identity),
                        options => options_of(Identity)}
      end);
verified_registration(false, _PublicKey) ->
    {error, invalid_registration_signature}.

-doc """
Canonical bytes for one short-lived login challenge.

The client signs these bytes.  They bind the receiving node and network as
well as both random values and the expiry, so a captured signature cannot be
replayed to another node or a later challenge.
""".
-spec challenge_bytes(term(), term(), term(), term(), term(), term(), term()) ->
          {ok, binary()} | {error, invalid_challenge}.
challenge_bytes(<<_:256>> = NetworkId, <<_:256>> = NodeKey,
                <<_:128>> = ChallengeId, <<_:256>> = PublicKey,
                <<_:256>> = ClientNonce, <<_:256>> = ServerNonce,
                ExpiresMs)
  when is_integer(ExpiresMs), ExpiresMs > 0, ExpiresMs =< 16#FFFFFFFFFFFFFFFF ->
    %% DomainNul || NetworkId32 || NodeKey32 || ChallengeId16 || PublicKey32
    %% || ClientNonce32 || ServerNonce32 || ExpiresMsU64BE.  Browser Web
    %% Crypto signs exactly this byte string without an Erlang codec.
    {ok, <<?CHALLENGE_DOMAIN/binary, NetworkId/binary, NodeKey/binary,
           ChallengeId/binary, PublicKey/binary, ClientNonce/binary,
           ServerNonce/binary, ExpiresMs:64/unsigned-big>>};
challenge_bytes(_NetworkId, _NodeKey, _ChallengeId, _PublicKey,
                _ClientNonce, _ServerNonce, _ExpiresMs) ->
    {error, invalid_challenge}.

-doc "Verify an Ed25519 signature over one complete, canonical challenge.".
-spec verify_challenge(term(), term(), term(), term(), term(), term(), term()) ->
          ok | {error, invalid_challenge | invalid_challenge_signature}.
verify_challenge(NetworkId, NodeKey, ChallengeId, PublicKey, ClientNonce,
                 ServerNonce, {ExpiresMs, Signature})
  when is_binary(Signature), byte_size(Signature) =:= 64 ->
    case challenge_bytes(NetworkId, NodeKey, ChallengeId, PublicKey,
                         ClientNonce, ServerNonce, ExpiresMs) of
        {ok, Bytes} ->
            case quod_identity:verify(Signature, Bytes, PublicKey) of
                true -> ok;
                false -> {error, invalid_challenge_signature}
            end;
        {error, _} = Error -> Error
    end;
verify_challenge(_NetworkId, _NodeKey, _ChallengeId, _PublicKey,
                 _ClientNonce, _ServerNonce, _Reply) ->
    {error, invalid_challenge}.

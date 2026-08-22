-module(quod_user).
-moduledoc """
Pure transitional identity rules for one human user's home ontology.

The target shared vocabulary is `quod:human_user`; it is *not* a global table
of people. The current `{user, Key}` protocol name remains transitional until
the reviewed agent-identity format break. Each Ed25519 public key
deterministically names one small home ontology. The ordinary signed
`create_user_home` Prolog convenience uses this module to derive the exact
arguments it passes to generic root-owned `create_ontology/2`.

This module deliberately does not authenticate a browser or create an
ontology. It only derives one identity and the fixed owner ACL used by a valid
home.
""".

-export([identity/1, home_namespace/1, home_options/1,
         challenge_bytes/7, verify_challenge/7, principal/1]).

-define(USER_DOMAIN, <<"quod-user-id-v1:">>).
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

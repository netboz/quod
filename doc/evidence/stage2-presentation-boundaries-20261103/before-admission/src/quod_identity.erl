-module(quod_identity).
-moduledoc """
A node's cryptographic **identity**: an Ed25519 keypair whose **public key is the
`node_id`** (the address is only a routing hint). Generated once on first boot and
persisted to the per-node data dir, so a node keeps its identity across restarts
**and across a move to a new host** — the whole point of the identity milestone.

## What is stored

Only the 32-byte Ed25519 **private seed**, at `<dir>/node.key` (mode `0600`). The
public key and a self-signed certificate are *derived* deterministically from the
seed on every load (`crypto:generate_key/3` + `mint_cert/1`), so there is one secret
to guard and nothing else to keep in sync.

## The cert and mutual TLS

`mint_cert/1` produces a minimal **self-signed** X.509 cert carrying the Ed25519
public key. The transport (`m:quod_quic`) presents it on every connection and reads
the *peer's* via `quic:peercert/1`; `pubkey_of_cert/1` recovers the 32-byte key.
There is **no CA** — a peer key is trusted because the committee admitted it
(`can_join`), not because of a chain. Verification rests on TLS 1.3's
CertificateVerify (proof the peer holds the key), which `quic` checks without a
chain, so a self-signed per-node cert authenticates cleanly.

> #### Signing {: .info }
>
> `sign/2` / `verify/3` provide Ed25519 signatures over canonical bytes. Consensus
> quorum certificates and signed directory generations share this node keypair.
""".

-include_lib("public_key/include/public_key.hrl").

-export([ensure/1, advance_directory_epoch/1,
         load_node_actor_pointer/1, store_node_actor_pointer/2,
         begin_node_enrollment/3, retain_node_allocation/2,
         begin_node_activation/3, reject_node_operation/3,
         generate/0, key_term/1, mint_cert/1, pubkey_of_cert/1, short/1,
         sign/2, verify/3, tls_key/1]).

-export_type([pubkey/0, seed/0, keypair/0, key_term/0, key_handle/0,
              signer/0, identity/0]).

-type pubkey()  :: binary().   %% 32-byte Ed25519 public key == the node_id
-type seed()    :: binary().   %% 32-byte Ed25519 private seed (the only persisted secret)
-type keypair() :: {pubkey(), seed()}.
%% The private-key term `public_key:pkix_sign/2` and `quic` (`convert_private_key`)
%% both sign with: the standard `#'ECPrivateKey'{}` carrying the Ed25519 namedCurve.
-type key_term() :: #'ECPrivateKey'{}.
-opaque key_handle() :: fun(() -> key_term()).
%% The signing subset used by consensus does not need the TLS certificate.
-type signer() :: #{pubkey := pubkey(), key := key_handle() | key_term()}.
%% A loaded identity adds the DER certificate used by the transport.
-type identity() :: #{pubkey := pubkey(), cert := binary(), key := key_handle()}.

-define(KEYFILE, "node.key").
-define(DIRECTORY_EPOCH_FILE, "directory.epoch").
-define(NODE_ACTOR_FILE, "node.actor").

%% ======================================================================
%% API
%% ======================================================================

-doc """
Load this node's identity from `Dir`, generating + persisting a fresh keypair on
first boot (no `node.key` yet). Returns the derived public key (the `node_id`), the
self-signed cert, and an opaque signing-key handle — see `t:identity/0`.
The closure prints as a function, not as private bytes, in process state,
application environment, and supervisor child arguments. It is protection
against accidental diagnostics, not a security boundary against code running
inside this VM (which can inspect a closure). Never serialize a key handle.
""".
-spec ensure(file:filename_all()) -> {ok, identity()} | {error, term()}.
ensure(Dir) ->
    KeyPath = filename:join(Dir, ?KEYFILE),
    case read_seed(KeyPath) of
        {ok, Seed} ->
            {ok, from_seed(Seed)};
        none ->
            {_Pub, Seed} = generate(),
            case write_secret(KeyPath, Seed) of
                ok    -> {ok, from_seed(Seed)};
                Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

-doc """
Durably advance and return the node's directory-serving lifetime counter.

The counter lives beside `node.key` and is persisted before a directory
service may advertise. A corrupt counter is a boot error rather than a silent
rollback that could make fresh announcements look stale.
""".
-spec advance_directory_epoch(file:filename_all()) ->
          {ok, pos_integer()} | {error, term()}.
advance_directory_epoch(Dir) ->
    Path = filename:join(Dir, ?DIRECTORY_EPOCH_FILE),
    case read_epoch(Path) of
        {ok, Previous} when Previous < 16#FFFFFFFFFFFFFFFF ->
            Next = Previous + 1,
            case quod_file:write_atomic(Path, <<Next:64/unsigned-big>>, 8#600) of
                ok -> {ok, Next};
                {error, _} = Error -> Error
            end;
        {ok, _} ->
            {error, directory_epoch_exhausted};
        {error, _} = Error ->
            Error
    end.

-doc """
Load the exact local node-actor reference stored beside `node.key`.

The file is only a bootstrap pointer.  Authority remains in the referenced
ontology: callers must verify its anchor, node instance and active key before
using the returned principal.
""".
-spec load_node_actor_pointer(file:filename_all()) ->
          none | {ok, binary()} | {pending, map()} | {error, term()}.
load_node_actor_pointer(Dir) ->
    Path = filename:join(Dir, ?NODE_ACTOR_FILE),
    case file:read_file(Path) of
        {ok, Bytes} -> decode_node_actor_pointer(Bytes);
        {error, enoent} -> none;
        {error, _} = Error -> Error
    end.

-doc """
Persist one exact node-actor reference.  Repeating the same binding is
idempotent; replacing it with another identity fails closed.
""".
-spec store_node_actor_pointer(file:filename_all(), binary()) ->
          ok | {error, term()}.
store_node_actor_pointer(Dir, Blob) when is_binary(Blob) ->
    case quod_agent_ref:decode(Blob) of
        {ok, _} ->
            case load_node_actor_pointer(Dir) of
                none ->
                    Path = filename:join(Dir, ?NODE_ACTOR_FILE),
                    Bytes = term_to_binary(
                              {quod_node_actor_pointer, 1, Blob},
                              [deterministic]),
                    quod_file:write_atomic(Path, Bytes, 8#600);
                {ok, Blob} -> ok;
                {pending, #{reference := Blob}} ->
                    write_node_pointer(Dir, {quod_node_actor_pointer, 1, Blob});
                {ok, _Other} -> {error, node_actor_identity_mismatch};
                {pending, _} -> {error, node_actor_identity_mismatch};
                {error, _} = Error -> Error
            end;
        {error, _} ->
            {error, invalid_node_actor_pointer}
    end;
store_node_actor_pointer(_Dir, _Blob) ->
    {error, invalid_node_actor_pointer}.

%% Pending request custody shares the existing pointer file. A surviving
%% pending row never grants permission to dispatch the request again.
begin_node_enrollment(Dir, Bytes, Signature) ->
    case load_node_actor_pointer(Dir) of
        none ->
            store_new_enrollment(Dir, Bytes, Signature);
        {pending, #{reference := none, rejected := enrollment}} ->
            store_new_enrollment(Dir, Bytes, Signature);
        _ -> {error, node_enrollment_already_retained}
    end.

store_new_enrollment(Dir, Bytes, Signature) ->
    store_pending_pointer(Dir, #{request => {Bytes, Signature}, reference => none,
                                activation => none, rejected => none}).

%% Only the worker receiving a definite refusal may record this transition.
%% A crash before this durable write leaves the old request unresolved.
reject_node_operation(Dir, Phase, Request) when Phase =:= enrollment; Phase =:= activation ->
    Field = case Phase of enrollment -> request; activation -> activation end,
    case load_node_actor_pointer(Dir) of
        {pending, #{Field := Request} = Pending} ->
            store_pending_pointer(Dir, Pending#{rejected => Phase});
        _ -> {error, node_enrollment_request_mismatch}
    end.

retain_node_allocation(Dir, Blob) ->
    case load_node_actor_pointer(Dir) of
        {pending, #{reference := none} = Pending} ->
            store_pending_pointer(Dir, Pending#{reference => Blob});
        {pending, #{reference := Blob}} -> ok;
        {ok, Blob} -> ok;
        {error, _} = Error -> Error;
        _ -> {error, node_actor_identity_mismatch}
    end.

begin_node_activation(Dir, Bytes, Signature) ->
    case load_node_actor_pointer(Dir) of
        {pending, #{reference := Blob, activation := none} = Pending} when is_binary(Blob) ->
            store_pending_pointer(Dir, Pending#{activation => {Bytes, Signature}});
        {pending, #{reference := Blob, rejected := activation} = Pending} when is_binary(Blob) ->
            store_pending_pointer(Dir, Pending#{activation => {Bytes, Signature}, rejected => none});
        {error, _} = Error -> Error;
        _ -> {error, node_activation_already_retained}
    end.

store_pending_pointer(Dir, Pending) ->
    case valid_pending_pointer(Pending) of
        true -> write_node_pointer(Dir, {quod_node_enrollment, 1, Pending});
        false -> {error, bad_node_actor_pointer}
    end.

write_node_pointer(Dir, Value) ->
    quod_file:write_atomic(filename:join(Dir, ?NODE_ACTOR_FILE),
                          term_to_binary(Value, [deterministic]), 8#600).

valid_pending_pointer(#{request := Request, reference := Reference, activation := Activation,
                        rejected := Rejected}) ->
    case pointer_request(Request) of
        {ok, #{request := #{mode := execute, signing_public_key := Key,
                            agent_namespace := <<"quod:node">>,
                            agent_genesis_anchor := Anchor,
                            network_identity := Network}} = Evidence} ->
            pointer_goal(Evidence,
                {agent_instance_ref, <<"quod:node">>, Anchor, {enrolling, Key}},
                {enroll_node, {0}}) andalso
            (Reference =:= none orelse valid_pointer_reference(Reference)) andalso
            valid_activation(Activation, Reference, Key, Network) andalso
            (Rejected =:= none orelse
             (Rejected =:= enrollment andalso Reference =:= none andalso Activation =:= none) orelse
             (Rejected =:= activation andalso Reference =/= none andalso Activation =/= none));
        _ -> false
    end;
valid_pending_pointer(_) -> false.

pointer_request({Bytes, Signature}) -> quod_client_goal:verify(Bytes, Signature);
pointer_request(_) -> {error, invalid_request}.

pointer_goal(#{agent_ref_blob := Agent, goal_blob := Goal}, ExpectedRef, ExpectedGoal) ->
    quod_wire_term:encode_canonical(ExpectedRef) =:= {ok, Agent} andalso
    quod_durable_term:encode_goal(ExpectedGoal) =:= {ok, Goal}.

valid_activation(none, _, _, _) -> true;
valid_activation(Request, Reference, Key, Network) ->
    case {pointer_request(Request), quod_agent_ref:decode(Reference)} of
        {{ok, #{request := #{mode := execute, signing_public_key := Key,
                             network_identity := Network}} = Evidence},
         {ok, #{identity := {Ns, Anchor}, reference := Ref}}} ->
            pointer_goal(Evidence, Ref, {host_ontology, Ref, Ns, Anchor, discoverable});
        _ -> false
    end.

valid_pointer_reference(Blob) ->
    case quod_agent_ref:decode(Blob) of {ok, _} -> true; _ -> false end.

-doc "Generate a fresh Ed25519 keypair `{PubKey, Seed}` (not persisted).".
-spec generate() -> keypair().
generate() -> crypto:generate_key(eddsa, ed25519).

-doc "The signing key term (`public_key`/`quic` `#'ECPrivateKey'{}` form) for a keypair.".
-spec key_term(keypair()) -> key_term().
key_term({Pub, Seed}) ->
    #'ECPrivateKey'{version = 1, privateKey = Seed,
                    parameters = {namedCurve, ?'id-Ed25519'}, publicKey = Pub}.

-doc """
Mint a minimal **self-signed** Ed25519 certificate (DER) for a keypair. Deterministic
(fixed serial + validity), so re-minting from the same seed yields the same identity.
""".
-spec mint_cert(keypair()) -> binary().
mint_cert({Pub, Seed}) ->
    Name = {rdnSequence, [[#'AttributeTypeAndValue'{
                type = ?'id-at-commonName', value = {utf8String, short(Pub)}}]]},
    SPKI = #'OTPSubjectPublicKeyInfo'{
              algorithm = #'PublicKeyAlgorithm'{algorithm = ?'id-Ed25519'},
              subjectPublicKey = #'ECPoint'{point = Pub}},
    TBS = #'OTPTBSCertificate'{
             version = v3,
             serialNumber = 1,
             signature = #'SignatureAlgorithm'{algorithm = ?'id-Ed25519'},
             issuer = Name,
             validity = #'Validity'{notBefore = {utcTime, "260101000000Z"},
                                    notAfter  = {utcTime, "360101000000Z"}},
             subject = Name,
             subjectPublicKeyInfo = SPKI},
    public_key:pkix_sign(TBS, key_term({Pub, Seed})).

-doc """
Recover the 32-byte Ed25519 public key from a DER cert (e.g. a `quic:peercert/1`
result). Returns `error` on a malformed/unexpected cert — the input is the *peer's*
cert on the TLS path, so a bad one must be rejected, never crash the caller.
""".
-spec pubkey_of_cert(binary()) -> {ok, pubkey()} | error.
pubkey_of_cert(DER) ->
    try public_key:pkix_decode_cert(DER, otp) of
        #'OTPCertificate'{tbsCertificate = #'OTPTBSCertificate'{
            subjectPublicKeyInfo = #'OTPSubjectPublicKeyInfo'{subjectPublicKey = K}}} ->
            case K of
                #'ECPoint'{point = P} when byte_size(P) =:= 32 -> {ok, P};
                P when is_binary(P), byte_size(P) =:= 32       -> {ok, P};
                _                                              -> error
            end
    catch _:_ -> error
    end.

-doc """
Ed25519-sign `Msg` (the canonical bytes of a share / block / vote) with this node's
identity (or a bare `t:key_term/0`). The signature is verified with `verify/3`
against the signer's public key (== its `node_id`). This is the primitive the
DispersedSimplex support/commit/complaint shares and the commit certificate are
built from.
""".
-spec sign(iodata(), signer() | key_handle() | key_term()) -> binary().
sign(Msg, #{key := KeyTerm}) ->
    sign(Msg, KeyTerm);
sign(Msg, Key) when is_function(Key, 0) ->
    sign(Msg, Key());
sign(Msg, #'ECPrivateKey'{privateKey = Seed}) ->
    try crypto:sign(eddsa, none, Msg, [Seed, ed25519])
    catch error:_ -> error(signing_failed)
    end.

-doc "Unwrap a node key only at the TLS adapter, whose API requires the raw key record.".
-spec tls_key(term()) -> term().
tls_key(Key) when is_function(Key, 0) -> Key();
%% Explicit PEM configurations also use the transport's native key formats.
tls_key(Key) -> Key.

-doc """
Verify an Ed25519 `Sig` over `Msg` against `PubKey` (a peer's `node_id`). `false` on
any malformed input — a certificate aggregates verified shares from *untrusted*
peers, so a bad signature must be rejected, never crash the verifier.
""".
-spec verify(binary(), iodata(), pubkey()) -> boolean().
verify(Sig, Msg, PubKey) when is_binary(Sig), is_binary(PubKey) ->
    try crypto:verify(eddsa, none, Msg, Sig, [PubKey, ed25519])
    catch _:_ -> false end;
verify(_Sig, _Msg, _PubKey) ->
    false.

-doc """
A short, log-readable rendering of a public key: `kp_` + the first 4 bytes as hex
(e.g. `kp_ab12cd34`). For display only — the canonical id is the full key.
""".
-spec short(pubkey()) -> binary().
short(Pub) when is_binary(Pub) ->
    Prefix = binary:part(Pub, 0, min(4, byte_size(Pub))),
    <<"kp_", (binary:encode_hex(Prefix, lowercase))/binary>>.

%% ======================================================================
%% helpers
%% ======================================================================

from_seed(Seed) ->
    {Pub, Seed} = crypto:generate_key(eddsa, ed25519, Seed),
    Key = key_term({Pub, Seed}),
    #{pubkey => Pub, cert => mint_cert({Pub, Seed}), key => fun() -> Key end}.

read_seed(Path) ->
    case file:read_file(Path) of
        {ok, <<Seed:32/binary>>} -> {ok, Seed};
        {ok, _Other}             -> {error, bad_identity_file};
        {error, enoent}          -> none;
        {error, _} = Error       -> Error
    end.

%% Write the secret seed durably and privately. Mirrors `quod_ledger_store`'s
%% atomic tmp+rename+dir-fsync, with two extra guards because this is a SECRET:
%%   - **exclusive** create (never write into a pre-existing file or attacker-planted
%%     symlink; a stale tmp is cleared first), and
%%   - **chmod 0600 before the seed is written**, so the key never touches disk at the
%%     umask-default world-readable mode.
%% Returns `{error, _}` (never a badmatch crash) so `ensure/1` can relay a failure.
write_secret(Path, Seed) ->
    quod_file:write_atomic(Path, Seed, 8#600).


read_epoch(Path) ->
    case file:read_file(Path) of
        {ok, <<Epoch:64/unsigned-big>>} -> {ok, Epoch};
        {ok, _} -> {error, bad_directory_epoch_file};
        {error, enoent} -> {ok, 0};
        {error, _} = Error -> Error
    end.

decode_node_actor_pointer(Bytes) ->
    try binary_to_term(Bytes, [safe]) of
        {quod_node_enrollment, 1, Pending} ->
            case valid_pending_pointer(Pending) of
                true -> {pending, Pending};
                false -> {error, bad_node_actor_pointer}
            end;
        {quod_node_actor_pointer, 1, Blob} when is_binary(Blob) ->
            case quod_agent_ref:decode(Blob) of
                {ok, _} -> {ok, Blob};
                {error, _} -> {error, bad_node_actor_pointer}
            end;
        _ ->
            {error, bad_node_actor_pointer}
    catch
        _:_ -> {error, bad_node_actor_pointer}
    end.

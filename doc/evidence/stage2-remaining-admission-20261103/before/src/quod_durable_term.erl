-module(quod_durable_term).
-moduledoc """
Canonical Prolog values stored in committed transaction envelopes.

Durable goals and selected bindings use the same atom-safe `m:quod_wire_term`
alphabet as distributed scopes, but this module owns their persistence
contract.  A durable goal is data, not an invocation: decoding therefore
preserves an unknown functor as an opaque symbol instead of rewriting it to
the non-callable invocation sentinel.

Every accepted blob is canonical deterministic ETF.  Result variable names
are non-empty binaries in strict ascending order, so duplicate names and
topology-dependent atom allocation are impossible.
""".

-export([encode_goal/1, decode_goal/1,
         encode_result/1, decode_result/1]).

-type codec_error() :: {error, bad_term | invalid_result}.

-doc "Encode one Prolog goal into canonical atom-safe durable bytes.".
-spec encode_goal(term()) -> {ok, binary()} | codec_error().
encode_goal(Goal) ->
    quod_wire_term:encode_canonical(Goal).

-doc "Decode and re-canonicalize one durable goal.".
-spec decode_goal(binary()) -> {ok, term()} | codec_error().
decode_goal(Blob) ->
    quod_wire_term:decode_canonical(Blob, unlimited).

-doc "Encode a solution map with non-empty canonical binary variable names.".
-spec encode_result(map()) -> {ok, binary()} | codec_error().
encode_result(Bindings) ->
    quod_wire_term:encode_bindings(Bindings, unlimited).

-doc "Decode and validate the canonical ordered durable solution pairs.".
-spec decode_result(binary()) -> {ok, [{binary(), term()}]} | codec_error().
decode_result(Blob) ->
    quod_wire_term:decode_bindings(Blob, unlimited).

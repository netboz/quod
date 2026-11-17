-module(quod_durable_term).
-moduledoc """
Canonical, bounded Prolog values stored in committed transaction envelopes.

Durable goals and selected bindings use the same atom-safe `m:quod_wire_term`
alphabet as distributed scopes, but this module owns their persistence
contract.  A durable goal is data, not an invocation: decoding therefore
preserves an unknown functor as an opaque symbol instead of rewriting it to
the non-callable invocation sentinel.

Every accepted blob is canonical deterministic ETF.  Result variable names
are non-empty binaries in strict ascending order, so duplicate names and
topology-dependent atom allocation are impossible.
""".

-include("quod_proof_limits.hrl").

-export([encode_goal/1, decode_goal/1,
         encode_result/1, decode_result/1]).

-type codec_error() :: {error, bad_term | invalid_result |
                                {too_large, goal | result}}.

-doc "Encode one bounded Prolog goal into canonical atom-safe durable bytes.".
-spec encode_goal(term()) -> {ok, binary()} | codec_error().
encode_goal(Goal) ->
    encode(goal, Goal, ?QUOD_MAX_TOPLEVEL_GOAL_BYTES).

-doc "Decode and re-canonicalize one bounded durable goal.".
-spec decode_goal(binary()) -> {ok, term()} | codec_error().
decode_goal(Blob) ->
    decode(goal, Blob, ?QUOD_MAX_TOPLEVEL_GOAL_BYTES).

-doc "Encode a solution map with non-empty canonical binary variable names.".
-spec encode_result(map()) -> {ok, binary()} | codec_error().
encode_result(Bindings) ->
    durable_result(quod_wire_term:encode_bindings(Bindings, ?QUOD_MAX_DURABLE_RESULT_BYTES)).

-doc "Decode and validate the canonical ordered durable solution pairs.".
-spec decode_result(binary()) -> {ok, [{binary(), term()}]} | codec_error().
decode_result(Blob) ->
    durable_result(quod_wire_term:decode_bindings(Blob, ?QUOD_MAX_DURABLE_RESULT_BYTES)).

durable_result({error, too_large}) -> {error, {too_large, result}};
durable_result(Result) -> Result.

encode(Kind, Term, MaxBytes) ->
    case quod_wire_term:encode(Term) of
        {ok, WireTerm} ->
            Blob = term_to_binary(WireTerm, [deterministic]),
            case byte_size(Blob) =< MaxBytes of
                true -> {ok, Blob};
                false -> {error, {too_large, Kind}}
            end;
        {error, bad_term} ->
            {error, bad_term}
    end.

decode(_Kind, Blob, MaxBytes)
  when is_binary(Blob), byte_size(Blob) =< MaxBytes ->
    %% The shared wire decoder checks the deterministic ETF bytes before it
    %% decodes the bounded Prolog term.  Re-encoding that decoded term here was
    %% the same canonicality check a second time and made ledger replay walk
    %% every durable goal/result twice.
    case quod_wire_term:decode_canonical(Blob, MaxBytes) of
        {ok, Term} -> {ok, Term};
        {error, _} -> {error, bad_term}
    end;
decode(Kind, Blob, MaxBytes) when is_binary(Blob), byte_size(Blob) > MaxBytes ->
    {error, {too_large, Kind}};
decode(_Kind, _Blob, _MaxBytes) ->
    {error, bad_term}.

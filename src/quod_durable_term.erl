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
encode_result(Bindings) when is_map(Bindings) ->
    case result_pairs(Bindings) of
        {ok, Pairs} ->
        case lists:all(
               fun({Name, _Value}) -> byte_size(Name) > 0 end, Pairs)
             andalso unique_result_names(Pairs) of
            true -> encode(result, Pairs, ?QUOD_MAX_DURABLE_RESULT_BYTES);
            false -> {error, invalid_result}
            end;
        error ->
            {error, invalid_result}
    end;
encode_result(_) ->
    {error, invalid_result}.

%% Keep input validation separate from the codec. Signed browser goals retain
%% their atom-free binary variable names; trusted in-VM callers still use the
%% traditional atom keys. Both converge on the same durable binary-name form.
result_pairs(Bindings) ->
    try
        {ok,
         lists:sort(
           [{result_name(Name), Value}
            || {Name, Value} <- maps:to_list(Bindings)])}
    catch
        error:badarg -> error
    end.

result_name(Name) when is_atom(Name) -> atom_to_binary(Name, utf8);
result_name(Name) when is_binary(Name) -> Name;
result_name(_Name) -> error(badarg).

unique_result_names([], _Previous) -> true;
unique_result_names([{Name, _Value} | _Rest], Name) -> false;
unique_result_names([{Name, _Value} | Rest], _Previous) ->
    unique_result_names(Rest, Name).

unique_result_names(Pairs) -> unique_result_names(Pairs, none).

-doc "Decode and validate the canonical ordered durable solution pairs.".
-spec decode_result(binary()) -> {ok, [{binary(), term()}]} | codec_error().
decode_result(Blob) ->
    case decode(result, Blob, ?QUOD_MAX_DURABLE_RESULT_BYTES) of
        {ok, Pairs} ->
            case valid_result(Pairs) of
                true -> {ok, Pairs};
                false -> {error, invalid_result}
            end;
        {error, _} = Error ->
            Error
    end.

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
    case quod_safe_term:decode(Blob, MaxBytes) of
        {ok, WireTerm} ->
            case quod_wire_term:decode(WireTerm) of
                {ok, Term} ->
                    case quod_wire_term:encode(Term) of
                        {ok, ReencodedWireTerm} ->
                            Canonical = term_to_binary(
                                          ReencodedWireTerm,
                                          [deterministic]),
                            case Canonical =:= Blob of
                                true -> {ok, Term};
                                false -> {error, bad_term}
                            end;
                        {error, bad_term} ->
                            {error, bad_term}
                    end;
                {error, bad_term} ->
                    {error, bad_term}
            end;
        {error, _} ->
            {error, bad_term}
    end;
decode(Kind, Blob, MaxBytes) when is_binary(Blob), byte_size(Blob) > MaxBytes ->
    {error, {too_large, Kind}};
decode(_Kind, _Blob, _MaxBytes) ->
    {error, bad_term}.

valid_result(Pairs) when is_list(Pairs) ->
    valid_result(Pairs, none);
valid_result(_) ->
    false.

valid_result([], _Previous) ->
    true;
valid_result([{Name, _Value} | Rest], Previous)
  when is_binary(Name), byte_size(Name) > 0,
       (Previous =:= none orelse Previous < Name) ->
    valid_result(Rest, Name);
valid_result(_, _) ->
    false.

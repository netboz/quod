-module(quod_safe_term).
-moduledoc """
Decode bounded untrusted Erlang external terms without atom creation,
compressed-term expansion, or ignored trailing bytes.

Callers remain responsible for validating the decoded term's protocol shape.
""".

-export([decode/2]).

-spec decode(binary(), non_neg_integer()) ->
          {ok, term()} |
          {error, bad_term | compressed | too_large | trailing_data}.
decode(Binary, MaxBytes)
  when is_binary(Binary), is_integer(MaxBytes), MaxBytes >= 0 ->
    case byte_size(Binary) =< MaxBytes of
        true -> decode_bounded(Binary);
        false -> {error, too_large}
    end;
decode(_, _) ->
    {error, bad_term}.

decode_bounded(<<131, 80, _/binary>>) ->
    {error, compressed};
decode_bounded(Binary) ->
    try binary_to_term(Binary, [safe, used]) of
        {Term, Used} when Used =:= byte_size(Binary) -> {ok, Term};
        {_Term, _Used} -> {error, trailing_data}
    catch
        _:_ -> {error, bad_term}
    end.

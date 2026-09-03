-module(quod_safe_term).
-moduledoc """
Decode bounded untrusted Erlang external terms without atom creation,
compressed-term expansion, or ignored trailing bytes.

`decode_wrapped/2` retains already-loaded atoms and represents every unknown
atom as `{'$quod_symbol', NameBytes}`. It additionally accepts only the
deterministic canonical ETF representation. Maps are values, but a map key
cannot itself contain a map because ETF does not provide a stable byte order
for that shape across fresh VMs. Callers remain responsible for validating the
decoded term's protocol shape.
""".

-include("quod_term_limits.hrl").

-export([decode/2, decode_wrapped/2]).

-type decode_error() :: bad_term | compressed | too_large | trailing_data.

-spec decode(binary(), non_neg_integer()) ->
          {ok, term()} |
          {error, decode_error()}.
decode(Binary, MaxBytes)
  when is_binary(Binary), is_integer(MaxBytes), MaxBytes >= 0 ->
    case byte_size(Binary) =< MaxBytes of
        true -> decode_bounded(Binary);
        false -> {error, too_large}
    end;
decode(_, _) ->
    {error, bad_term}.

-spec decode_wrapped(binary(), non_neg_integer()) ->
          {ok, term()} | {error, decode_error()}.
decode_wrapped(Binary, MaxBytes)
  when is_binary(Binary), is_integer(MaxBytes), MaxBytes >= 0 ->
    case byte_size(Binary) =< MaxBytes of
        true -> decode_wrapped_bounded(Binary);
        false -> {error, too_large}
    end;
decode_wrapped(_, _) ->
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

decode_wrapped_bounded(<<131, 80, _/binary>>) ->
    {error, compressed};
decode_wrapped_bounded(<<131, Body/binary>> = Binary) ->
    try
        case parse(Body, 0) of
            {Term, Ast, <<>>} ->
                Reencoded = iolist_to_binary([131, encode(Ast)]),
                case Reencoded =:= Binary of
                    true -> {ok, Term};
                    false -> {error, bad_term}
                end;
            {_Term, _Ast, _Trailing} -> {error, trailing_data}
        end
    catch
        throw:bad_etf -> {error, bad_term};
        error:_ -> {error, bad_term}
    end;
decode_wrapped_bounded(_) ->
    {error, bad_term}.

%% Protocol values are immutable data. Runtime identities and executable ETF
%% values (pids, ports, refs, funs and exports) are deliberately rejected.
parse(_Bytes, Depth) when Depth > ?QUOD_MAX_TERM_DEPTH -> throw(bad_etf);
parse(<<97, N:8, Rest/binary>>, _Depth) -> {N, {integer, N}, Rest};
parse(<<98, N:32/signed-big, Rest/binary>>, _Depth) -> {N, {integer, N}, Rest};
parse(<<70, F:64/float-big, Rest/binary>>, _Depth) -> {F, {float, F}, Rest};
parse(<<100, N:16/big, Name:N/binary, Rest/binary>>, _Depth) ->
    atom_term(Name, latin1, Rest);
parse(<<115, N:8, Name:N/binary, Rest/binary>>, _Depth) ->
    atom_term(Name, latin1, Rest);
parse(<<118, N:16/big, Name:N/binary, Rest/binary>>, _Depth) ->
    atom_term(Name, utf8, Rest);
parse(<<119, N:8, Name:N/binary, Rest/binary>>, _Depth) ->
    atom_term(Name, utf8, Rest);
parse(<<104, N:8, Rest/binary>>, Depth) ->
    {Terms, Asts, Tail} = parse_n(N, Rest, [], [], Depth + 1),
    {list_to_tuple(Terms), {tuple, Asts}, Tail};
parse(<<105, N:32/big, Rest/binary>>, Depth) ->
    {Terms, Asts, Tail} = parse_n(N, Rest, [], [], Depth + 1),
    {list_to_tuple(Terms), {tuple, Asts}, Tail};
parse(<<106, Rest/binary>>, _Depth) -> {[], nil, Rest};
parse(<<107, N:16/big, Bytes:N/binary, Rest/binary>>, _Depth) when N > 0 ->
    Values = binary_to_list(Bytes),
    {Values, {list, [{integer, V} || V <- Values], nil}, Rest};
parse(<<108, N:32/big, Rest/binary>>, Depth) when N > 0 ->
    {Terms, Asts, Tail0} = parse_n(N, Rest, [], [], Depth + 1),
    {TailTerm, TailAst, Tail} = parse(Tail0, Depth + 1),
    case TailAst of
        {list, _, _} -> throw(bad_etf);
        _ -> {make_list(Terms, TailTerm), {list, Asts, TailAst}, Tail}
    end;
parse(<<109, N:32/big, Bytes:N/binary, Rest/binary>>, _Depth) ->
    {Bytes, {binary, Bytes}, Rest};
parse(<<77, N:32/big, Bits:8, Bytes:N/binary, Rest/binary>>, _Depth)
  when N > 0, Bits >= 1, Bits =< 7 ->
    <<Prefix:(N - 1)/binary, LastByte:8>> = Bytes,
    Pad = 8 - Bits,
    <<Last:Bits, Zero:Pad>> = <<LastByte>>,
    case Zero of
        0 ->
            Value = <<Prefix/binary, Last:Bits>>,
            {Value, {bit_binary, Value}, Rest};
        _ -> throw(bad_etf)
    end;
parse(<<110, N:8, Sign:8, Digits:N/binary, Rest/binary>>, _Depth)
  when Sign =< 1 ->
    big_term(Sign, Digits, Rest);
parse(<<111, N:32/big, Sign:8, Digits:N/binary, Rest/binary>>, _Depth)
  when Sign =< 1 ->
    big_term(Sign, Digits, Rest);
parse(<<116, N:32/big, Rest/binary>>, Depth) ->
    {Pairs, Tail} = parse_pairs(N, Rest, [], Depth + 1),
    Material = maps:from_list([{K, V} || {K, _KA, V, _VA} <- Pairs]),
    case map_size(Material) =:= N andalso
         lists:all(fun({_K, KA, _V, _VA}) -> stable_map_key(KA) end, Pairs) of
        true ->
            {Material, {map, [{KA, VA} || {_K, KA, _V, VA} <- Pairs]}, Tail};
        false -> throw(bad_etf)
    end;
parse(_, _Depth) -> throw(bad_etf).

atom_term(Name, Encoding, Rest) ->
    case canonical_atom_name(Name, Encoding) of
        {ok, Utf8Name} ->
            try binary_to_existing_atom(Utf8Name, utf8) of
                Atom -> {Atom, {atom, Utf8Name}, Rest}
            catch
                error:badarg ->
                    {{'$quod_symbol', Utf8Name}, {atom, Utf8Name}, Rest}
            end;
        error -> throw(bad_etf)
    end.

canonical_atom_name(Name, Encoding) ->
    case unicode:characters_to_list(Name, Encoding) of
        Chars when is_list(Chars), length(Chars) =< 255 ->
            {ok, unicode:characters_to_binary(Chars, unicode, utf8)};
        _ -> error
    end.

parse_n(0, Rest, Terms, Asts, _Depth) ->
    {lists:reverse(Terms), lists:reverse(Asts), Rest};
parse_n(N, Bytes, Terms, Asts, Depth) when N > 0 ->
    {Term, Ast, Rest} = parse(Bytes, Depth),
    parse_n(N - 1, Rest, [Term | Terms], [Ast | Asts], Depth).

parse_pairs(0, Rest, Acc, _Depth) -> {lists:reverse(Acc), Rest};
parse_pairs(N, Bytes, Acc, Depth) when N > 0 ->
    {K, KA, Rest1} = parse(Bytes, Depth),
    {V, VA, Rest2} = parse(Rest1, Depth),
    parse_pairs(N - 1, Rest2, [{K, KA, V, VA} | Acc], Depth).

make_list([], Tail) -> Tail;
make_list([Head | Rest], Tail) -> [Head | make_list(Rest, Tail)].

big_term(Sign, Digits, Rest) ->
    Magnitude = little_unsigned(Digits, 0, 0),
    Value = case Sign of 0 -> Magnitude; 1 -> -Magnitude end,
    {Value, {integer, Value}, Rest}.

little_unsigned(<<>>, _Shift, Acc) -> Acc;
little_unsigned(<<Byte:8, Rest/binary>>, Shift, Acc) ->
    little_unsigned(Rest, Shift + 8, Acc bor (Byte bsl Shift)).

encode({integer, N}) when N >= 0, N =< 255 -> <<97, N:8>>;
encode({integer, N}) when N >= -2147483648, N =< 2147483647 ->
    <<98, N:32/signed-big>>;
encode({integer, N}) ->
    Sign = case N < 0 of true -> 1; false -> 0 end,
    Digits = unsigned_little(abs(N), []),
    Size = byte_size(Digits),
    case Size < 256 of
        true -> <<110, Size:8, Sign:8, Digits/binary>>;
        false -> <<111, Size:32/big, Sign:8, Digits/binary>>
    end;
encode({float, F}) -> <<70, F:64/float-big>>;
encode({atom, Name}) when byte_size(Name) < 256 ->
    <<119, (byte_size(Name)):8, Name/binary>>;
encode({atom, Name}) -> <<118, (byte_size(Name)):16/big, Name/binary>>;
encode({tuple, Values}) when length(Values) < 256 ->
    [<<104, (length(Values)):8>>, [encode(V) || V <- Values]];
encode({tuple, Values}) ->
    [<<105, (length(Values)):32/big>>, [encode(V) || V <- Values]];
encode(nil) -> <<106>>;
encode({list, Values, nil}) ->
    case byte_list(Values, []) of
        {ok, Bytes} when byte_size(Bytes) =< 65535 ->
            <<107, (byte_size(Bytes)):16/big, Bytes/binary>>;
        _ ->
            [<<108, (length(Values)):32/big>>, [encode(V) || V <- Values], <<106>>]
    end;
encode({list, Values, Tail}) ->
    [<<108, (length(Values)):32/big>>, [encode(V) || V <- Values], encode(Tail)];
encode({binary, Bytes}) -> <<109, (byte_size(Bytes)):32/big, Bytes/binary>>;
encode({bit_binary, Bits}) ->
    FullBytes = bit_size(Bits) div 8,
    TailBits = bit_size(Bits) rem 8,
    <<Prefix:FullBytes/binary, Last:TailBits>> = Bits,
    Size = FullBytes + 1,
    <<77, Size:32/big, TailBits:8, Prefix/binary, Last:TailBits,
      0:(8 - TailBits)>>;
encode({map, Pairs}) ->
    true = ordered_map_pairs(Pairs),
    [<<116, (length(Pairs)):32/big>>,
     [[encode(K), encode(V)] || {K, V} <- Pairs]].

unsigned_little(0, []) -> <<0>>;
unsigned_little(0, Acc) -> list_to_binary(lists:reverse(Acc));
unsigned_little(N, Acc) -> unsigned_little(N bsr 8, [N band 255 | Acc]).

byte_list([], Acc) -> {ok, list_to_binary(lists:reverse(Acc))};
byte_list([{integer, N} | Rest], Acc) when N >= 0, N =< 255 ->
    byte_list(Rest, [N | Acc]);
byte_list(_, _) -> error.

stable_map_key({tuple, Values}) -> lists:all(fun stable_map_key/1, Values);
stable_map_key({list, Values, Tail}) ->
    lists:all(fun stable_map_key/1, Values) andalso stable_map_key(Tail);
stable_map_key({map, _Pairs}) -> false;
stable_map_key(_Scalar) -> true.

%% ETF deterministic map order follows Erlang term order. Compare the AST
%% directly so unknown atoms keep atom ordering without entering the VM atom
%% table. The accepted subset has the same class order as Erlang terms.
ast_less(A, B) -> ast_compare(A, B) =:= lt.

ordered_map_pairs([]) -> true;
ordered_map_pairs([{K, _} | Rest]) -> ordered_map_pairs(K, Rest).

ordered_map_pairs(_Previous, []) -> true;
ordered_map_pairs(Previous, [{K, _} | Rest]) ->
    ast_less(Previous, K) andalso ordered_map_pairs(K, Rest).

ast_compare(A, B) ->
    case compare_value(ast_class(A), ast_class(B)) of
        eq -> ast_compare_same(A, B);
        Order -> Order
    end.

ast_compare_same({integer, A}, {integer, B}) -> compare_value(A, B);
ast_compare_same({float, A}, {float, B}) -> compare_value(A, B);
ast_compare_same({integer, A}, {float, B}) -> compare_number(A, integer, B, float);
ast_compare_same({float, A}, {integer, B}) -> compare_number(A, float, B, integer);
ast_compare_same({atom, A}, {atom, B}) -> compare_value(A, B);
ast_compare_same({tuple, A}, {tuple, B}) ->
    case compare_value(length(A), length(B)) of
        eq -> compare_asts(A, B);
        Order -> Order
    end;
ast_compare_same(nil, nil) -> eq;
ast_compare_same({list, AV, AT}, {list, BV, BT}) ->
    compare_list_asts(AV, AT, BV, BT);
ast_compare_same({binary, A}, {binary, B}) -> compare_value(A, B);
ast_compare_same({binary, A}, {bit_binary, B}) -> compare_value(A, B);
ast_compare_same({bit_binary, A}, {binary, B}) -> compare_value(A, B);
ast_compare_same({bit_binary, A}, {bit_binary, B}) -> compare_value(A, B).

compare_number(A, AType, B, BType) ->
    case compare_value(A, B) of
        eq -> compare_value(number_type_order(AType), number_type_order(BType));
        Order -> Order
    end.

number_type_order(integer) -> 1;
number_type_order(float) -> 2.

compare_asts([], []) -> eq;
compare_asts([A | ARest], [B | BRest]) ->
    case ast_compare(A, B) of
        eq -> compare_asts(ARest, BRest);
        Order -> Order
    end.

compare_list_asts([], AT, [], BT) -> ast_compare(AT, BT);
compare_list_asts([], AT, BV, BT) -> ast_compare(AT, {list, BV, BT});
compare_list_asts(AV, AT, [], BT) -> ast_compare({list, AV, AT}, BT);
compare_list_asts([A | ARest], AT, [B | BRest], BT) ->
    case ast_compare(A, B) of
        eq -> compare_list_asts(ARest, AT, BRest, BT);
        Order -> Order
    end.

ast_class({integer, _}) -> 1;
ast_class({float, _}) -> 1;
ast_class({atom, _}) -> 2;
ast_class({tuple, _}) -> 3;
ast_class(nil) -> 5;
ast_class({list, _, _}) -> 6;
ast_class({binary, _}) -> 7;
ast_class({bit_binary, _}) -> 7.

compare_value(A, B) when A < B -> lt;
compare_value(A, B) when A > B -> gt;
compare_value(_A, _B) -> eq.

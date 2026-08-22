-module(quod_client_goal_parser).
-moduledoc """
Atom-safe parser for the frozen signed-goal text grammar.

Each supported version owns its lexer, token bounds, variable numbering, and
exact operator table. Version 2 adds only Erlang-style `<<"...">>` byte terms;
version 1 remains frozen. Every non-operator symbol remains
`{'$quod_symbol', Utf8}` until the authenticated owning ontology performs
controlled callable materialization.
The parse result therefore cannot depend on which atoms happen to exist in a
validator VM.

Named variables become deterministic integer variables by first appearance.
Every anonymous `_` receives its own integer. The returned name table lets a
later client boundary render bindings without allocating atoms for user-chosen
variable names.

The final expression parser is the SHA-pinned Erlog parser, but it receives
only this module's tokens. Before use, the complete operator table it exposes is
compared with the frozen table below; a dependency change therefore fails closed
instead of silently changing how signed text is interpreted.
""".

-include("quod_client_goal_limits.hrl").
-include("quod_vm_limits.hrl").

-export([parse/2, supported_version/1]).

%% Guard BIFs cannot call local helpers, so keep the ASCII identifier contract
%% in one macro used by the lexer guard.
-define(IS_IDENT_CHAR(C),
        (((C) >= $A andalso (C) =< $Z) orelse
         ((C) >= $a andalso (C) =< $z) orelse
         ((C) >= $0 andalso (C) =< $9) orelse (C) =:= $_)).

-record(lex, {tokens = [] :: [tuple()],
              variables = #{} :: #{binary() => non_neg_integer()},
              variable_names = [] :: [{binary(), non_neg_integer()}],
              next_variable = 0 :: non_neg_integer(),
              token_count = 0 :: non_neg_integer(),
              parser_version = 1 :: 1 | 2}).

-type parse_error() :: invalid_syntax | unsupported_parser |
                       parser_contract_mismatch | {too_large, goal}.

-doc "Parse exactly one dot-terminated Prolog term under a frozen grammar version.".
-spec parse(term(), term()) ->
          {ok, #{goal := term(),
                 variables := [{binary(), non_neg_integer()}]}} |
          {error, parse_error()}.
parse(Text, Version)
  when is_binary(Text), byte_size(Text) > 0,
       byte_size(Text) =< ?QUOD_CLIENT_GOAL_TEXT_BYTES ->
    case supported_version(Version) of
        true ->
            case unicode:characters_to_list(Text, utf8) of
                Chars when is_list(Chars) ->
                    parse_chars(Chars, Version);
                _ ->
                    {error, invalid_syntax}
            end;
        false ->
            {error, unsupported_parser}
    end;
parse(Text, Version)
  when is_binary(Text), byte_size(Text) > ?QUOD_CLIENT_GOAL_TEXT_BYTES ->
    case supported_version(Version) of
        true -> {error, {too_large, goal}};
        false -> {error, unsupported_parser}
    end;
parse(_Text, Version) ->
    case supported_version(Version) of
        true -> {error, invalid_syntax};
        false -> {error, unsupported_parser}
    end.

-doc "Whether this signed-goal grammar version remains accepted.".
-spec supported_version(term()) -> boolean().
supported_version(1) -> true;
supported_version(2) -> true;
supported_version(_) -> false.

parse_chars(Chars, Version) ->
    case operator_contract() of
        false ->
            {error, parser_contract_mismatch};
        true ->
            case lex(Chars, 1, false, #lex{parser_version = Version}) of
                {ok, Tokens, Lex} ->
                    parsed(erlog_parse:term(Tokens), Lex);
                {error, _} = Error ->
                    Error
            end
    end.

parsed({ok, Goal}, #lex{variable_names = NamesRev}) ->
    %% The lexer emits only the wire alphabet and validates Unicode values.
    %% A remaining encoder rejection can therefore only be a structural/node
    %% bound, for which `too_large` is the accurate public result.
    case {quod_wire_term:encode(Goal),
          quod_wire_term:goal_symbol_names(Goal)} of
        {{ok, _}, {ok, CallableSymbols}}
          when length(CallableSymbols) =< ?QUOD_MAX_NEW_MATERIAL_ATOMS ->
            {ok, #{goal => Goal, variables => lists:reverse(NamesRev)}};
        {{ok, _}, {ok, _TooManySymbols}} ->
            {error, {too_large, goal}};
        _ ->
            {error, {too_large, goal}}
    end;
parsed({error, _}, _Lex) ->
    {error, invalid_syntax}.

%% ------------------------------------------------------------------
%% Lexer
%% ------------------------------------------------------------------

lex(Chars0, Line0, PriorLayout, Lex0) ->
    case skip_layout(Chars0, Line0, PriorLayout) of
        {ok, [], _Line, _Layout} ->
            {error, invalid_syntax};
        {ok, Chars, Line, Layout} ->
            lex_token(Chars, Line, Layout, Lex0);
        {error, _} = Error ->
            Error
    end.

lex_token([$. | Rest], Line, _Layout, Lex0) ->
    case only_layout(Rest, Line) of
        true ->
            case push({'.', Line}, Lex0) of
                {ok, Lex} -> {ok, lists:reverse(Lex#lex.tokens), Lex};
                {error, _} = Error -> Error
            end;
        false ->
            lex_graphic([$. | Rest], Line, Lex0)
    end;
lex_token([$( | Rest], Line, true, Lex0) ->
    continue(Rest, Line, push({' (', Line}, Lex0));
lex_token([$( | Rest], Line, false, Lex0) ->
    continue(Rest, Line, push({'(', Line}, Lex0));
lex_token([$) | Rest], Line, _Layout, Lex0) ->
    continue(Rest, Line, push({')', Line}, Lex0));
lex_token([$[ | Rest], Line, _Layout, Lex0) ->
    continue(Rest, Line, push({'[', Line}, Lex0));
lex_token([$] | Rest], Line, _Layout, Lex0) ->
    continue(Rest, Line, push({']', Line}, Lex0));
lex_token([${ | Rest], Line, _Layout, Lex0) ->
    continue(Rest, Line, push({'{', Line}, Lex0));
lex_token([$} | Rest], Line, _Layout, Lex0) ->
    continue(Rest, Line, push({'}', Line}, Lex0));
lex_token([$, | Rest], Line, _Layout, Lex0) ->
    continue(Rest, Line, push({',', Line}, Lex0));
lex_token([$| | Rest], Line, _Layout, Lex0) ->
    continue(Rest, Line, push({'|', Line}, Lex0));
lex_token([$<, $<, $" | Rest], Line, _Layout,
          #lex{parser_version = 2} = Lex0) ->
    lex_binary(Rest, Line, Lex0);
lex_token([$' | Rest], Line, _Layout, Lex0) ->
    lex_quoted(Rest, Line, $', atom, Lex0);
lex_token([$" | Rest], Line, _Layout, Lex0) ->
    lex_quoted(Rest, Line, $", string, Lex0);
lex_token([C | _] = Chars, Line, _Layout, Lex0)
  when C >= $0, C =< $9 ->
    lex_number(Chars, Line, Lex0);
lex_token([C | _] = Chars, Line, _Layout, Lex0)
  when C >= $a, C =< $z ->
    {Name, Rest} = take_identifier(Chars, []),
    lex_symbol(Name, Rest, Line, Lex0);
lex_token([C | _] = Chars, Line, _Layout, Lex0)
  when (C >= $A andalso C =< $Z) orelse C =:= $_ ->
    {NameChars, Rest} = take_identifier(Chars, []),
    lex_variable(unicode:characters_to_binary(NameChars), Rest, Line, Lex0);
lex_token([$! | Rest], Line, _Layout, Lex0) ->
    lex_symbol("!", Rest, Line, Lex0);
lex_token([$; | Rest], Line, _Layout, Lex0) ->
    lex_symbol(";", Rest, Line, Lex0);
lex_token([C | _] = Chars, Line, _Layout, Lex0) ->
    case graphic(C) of
        true -> lex_graphic(Chars, Line, Lex0);
        false -> {error, invalid_syntax}
    end.

continue(_Rest, _Line, {error, _} = Error) -> Error;
continue(Rest, Line, {ok, Lex}) -> lex(Rest, Line, false, Lex).

push(_Token, #lex{token_count = Count})
  when Count >= ?QUOD_CLIENT_GOAL_MAX_TOKENS ->
    {error, {too_large, goal}};
push(Token, #lex{tokens = Tokens, token_count = Count} = Lex) ->
    {ok, Lex#lex{tokens = [Token | Tokens], token_count = Count + 1}}.

skip_layout([C | Rest], Line, _Layout)
  when C >= 0, C =< 32 ->
    skip_layout(Rest, next_line(C, Line), true);
skip_layout([$% | Rest], Line, _Layout) ->
    {After, NextLine} = line_comment(Rest, Line),
    skip_layout(After, NextLine, true);
skip_layout([$/, $* | Rest], Line, _Layout) ->
    case block_comment(Rest, Line) of
        {ok, After, NextLine} -> skip_layout(After, NextLine, true);
        error -> {error, invalid_syntax}
    end;
skip_layout(Rest, Line, Layout) ->
    {ok, Rest, Line, Layout}.

only_layout(Chars, Line) ->
    case skip_layout(Chars, Line, false) of
        {ok, [], _NextLine, _} -> true;
        _ -> false
    end.

line_comment([C | Rest], Line) when C =:= $\n -> {Rest, Line + 1};
line_comment([_ | Rest], Line) -> line_comment(Rest, Line);
line_comment([], Line) -> {[], Line}.

block_comment([$*, $/ | Rest], Line) -> {ok, Rest, Line};
block_comment([C | Rest], Line) -> block_comment(Rest, next_line(C, Line));
block_comment([], _Line) -> error.

next_line($\n, Line) -> Line + 1;
next_line(_, Line) -> Line.

take_identifier([C | Rest], Acc) when ?IS_IDENT_CHAR(C) ->
    take_identifier(Rest, [C | Acc]);
take_identifier(Rest, Acc) ->
    {lists:reverse(Acc), Rest}.

lex_symbol(NameChars, Rest, Line, Lex0) when is_list(NameChars) ->
    Name = unicode:characters_to_binary(NameChars),
    case byte_size(Name) =< ?QUOD_CLIENT_GOAL_MAX_SYMBOL_BYTES of
        true ->
            Token = {atom, Line, symbol_value(Name)},
            continue(Rest, Line, push(Token, Lex0));
        false ->
            {error, {too_large, goal}}
    end.

lex_variable(Name, Rest, Line,
             #lex{variables = Variables, variable_names = Names,
                  next_variable = Next} = Lex0) ->
    case Name of
        <<"_">> ->
            Lex1 = Lex0#lex{next_variable = Next + 1},
            continue(Rest, Line, push({var, Line, Next}, Lex1));
        _ ->
            case byte_size(Name) =< ?QUOD_CLIENT_GOAL_MAX_SYMBOL_BYTES of
                false ->
                    {error, {too_large, goal}};
                true ->
                    case maps:find(Name, Variables) of
                        {ok, Index} ->
                            continue(Rest, Line,
                                     push({var, Line, Index}, Lex0));
                        error ->
                            Lex1 = Lex0#lex{
                                     variables = Variables#{Name => Next},
                                     variable_names = [{Name, Next} | Names],
                                     next_variable = Next + 1},
                            continue(Rest, Line,
                                     push({var, Line, Next}, Lex1))
                    end
            end
    end.

lex_graphic(Chars, Line, Lex0) ->
    {Graphic, Rest} = take_graphic(Chars, []),
    lex_symbol(Graphic, Rest, Line, Lex0).

take_graphic([C | Rest], Acc) ->
    case graphic(C) of
        true -> take_graphic(Rest, [C | Acc]);
        false -> {lists:reverse(Acc), [C | Rest]}
    end;
take_graphic([], Acc) ->
    {lists:reverse(Acc), []}.

graphic(C) -> lists:member(C, "-#$&*+./\\:<=>?@^~").

%% ------------------------------------------------------------------
%% Quoted values and escapes
%% ------------------------------------------------------------------

lex_quoted(Rest0, Line, Quote, Kind, Lex0) ->
    case quoted_chars(Rest0, Quote, Line, []) of
        {ok, Chars, Rest, NextLine} ->
            quoted_token(Kind, Chars, Rest, Line, NextLine, Lex0);
        error ->
            {error, invalid_syntax}
    end.

quoted_token(atom, Chars, Rest, TokenLine, NextLine, Lex0) ->
    case unicode:characters_to_binary(Chars, unicode, utf8) of
        Name when is_binary(Name) ->
            case byte_size(Name) =< ?QUOD_CLIENT_GOAL_MAX_SYMBOL_BYTES of
                true ->
                    continue(
                      Rest, NextLine,
                      push({atom, TokenLine, symbol_value(Name)}, Lex0));
                false ->
                    {error, {too_large, goal}}
            end;
        _ ->
            {error, invalid_syntax}
    end;
quoted_token(string, Chars, Rest, TokenLine, NextLine, Lex0) ->
    case unicode:characters_to_binary(Chars, unicode, utf8) of
        Bytes when is_binary(Bytes) ->
            continue(Rest, NextLine, push({string, TokenLine, Chars}, Lex0));
        _ ->
            {error, invalid_syntax}
    end.

%% Version 2 recognizes only the quoted byte form `<<"...">>`.  This is
%% intentionally not Erlang's full bit-syntax: each decoded character must be
%% an octet, and an unfinished or oversized value is ordinary invalid syntax.
lex_binary(Rest0, Line, Lex0) ->
    case quoted_chars(Rest0, $", Line, []) of
        {ok, Chars, [$>, $> | Rest], NextLine} ->
            case binary_chars(Chars) of
                {ok, Bytes} ->
                    continue(Rest, NextLine, push({binary, Line, Bytes}, Lex0));
                error ->
                    {error, invalid_syntax}
            end;
        _ ->
            {error, invalid_syntax}
    end.

binary_chars(Chars) ->
    case lists:all(fun(C) -> is_integer(C) andalso C >= 0 andalso C =< 255 end,
                   Chars) of
        true -> {ok, list_to_binary(Chars)};
        false -> error
    end.

quoted_chars([Quote | Rest], Quote, Line, Acc) ->
    {ok, lists:reverse(Acc), Rest, Line};
quoted_chars([$\\ | Rest0], Quote, Line, Acc) ->
    case escaped_char(Rest0) of
        {ok, Char, Rest} -> quoted_chars(Rest, Quote, Line, [Char | Acc]);
        error -> error
    end;
quoted_chars([C | Rest], Quote, Line, Acc) ->
    quoted_chars(Rest, Quote, next_line(C, Line), [C | Acc]);
quoted_chars([], _Quote, _Line, _Acc) ->
    error.

escaped_char([$x | Rest]) -> escaped_radix(Rest, 16);
escaped_char([C | _] = Rest) when C >= $0, C =< $7 ->
    escaped_radix(Rest, 8);
escaped_char([C | Rest]) ->
    case escape_char(C) of
        {ok, Char} -> {ok, Char, Rest};
        error -> error
    end;
escaped_char([]) -> error.

escaped_radix(Chars, Base) ->
    {Digits, Rest} = take_radix_digits(Chars, Base, []),
    case {Digits, Rest} of
        {[], _} -> error;
        {_, [$\\ | Tail]} ->
            case length(Digits) =< ?QUOD_CLIENT_GOAL_MAX_NUMBER_CHARS of
                true -> {ok, list_to_integer(Digits, Base), Tail};
                false -> error
            end;
        _ -> error
    end.

take_radix_digits([C | Rest], Base, Acc) ->
    case digit_value(C) of
        Value when is_integer(Value), Value < Base ->
            take_radix_digits(Rest, Base, [C | Acc]);
        _ ->
            {lists:reverse(Acc), [C | Rest]}
    end;
take_radix_digits([], _Base, Acc) ->
    {lists:reverse(Acc), []}.

escape_char($n) -> {ok, $\n};
escape_char($r) -> {ok, $\r};
escape_char($t) -> {ok, $\t};
escape_char($v) -> {ok, $\v};
escape_char($b) -> {ok, $\b};
escape_char($f) -> {ok, $\f};
escape_char($e) -> {ok, 27};
escape_char($s) -> {ok, $\s};
escape_char($d) -> {ok, 127};
escape_char($') -> {ok, $'};
escape_char($") -> {ok, $"};
escape_char($\\) -> {ok, $\\};
escape_char(_) -> error.

%% ------------------------------------------------------------------
%% Numbers
%% ------------------------------------------------------------------

lex_number([$0, $' | Rest], Line, Lex0) ->
    case escaped_or_plain_char(Rest) of
        {ok, Char, Tail} ->
            continue(Tail, Line, push({number, Line, Char}, Lex0));
        error ->
            {error, invalid_syntax}
    end;
lex_number([$0, Prefix | Rest], Line, Lex0)
  when Prefix =:= $b; Prefix =:= $o; Prefix =:= $x ->
    Base = case Prefix of $b -> 2; $o -> 8; $x -> 16 end,
    {Digits, Tail} = take_radix_digits(Rest, Base, []),
    case Digits =/= [] andalso
         length(Digits) =< ?QUOD_CLIENT_GOAL_MAX_NUMBER_CHARS of
        true ->
            continue(Tail, Line,
                     push({number, Line, list_to_integer(Digits, Base)}, Lex0));
        false ->
            {error, invalid_syntax}
    end;
lex_number(Chars, Line, Lex0) ->
    {Whole, Rest0} = take_decimal_digits(Chars, []),
    case {Rest0, Whole} of
        {[$., D | Rest], _} when D >= $0, D =< $9 ->
            {Fraction, Rest1} = take_decimal_digits([D | Rest], []),
            float_token(Whole ++ "." ++ Fraction, Rest1, Line, Lex0);
        _ ->
            number_token(Whole, Rest0, Line, Lex0)
    end.

float_token(BaseChars, [$e | Rest], Line, Lex0) ->
    exponent_token(BaseChars, Rest, Line, Lex0);
float_token(BaseChars, [$E | Rest], Line, Lex0) ->
    exponent_token(BaseChars, Rest, Line, Lex0);
float_token(BaseChars, Rest, Line, Lex0) ->
    number_value_token(float, BaseChars, Rest, Line, Lex0).

exponent_token(BaseChars, [Sign | Rest], Line, Lex0)
  when Sign =:= $+; Sign =:= $- ->
    {Digits, Tail} = take_decimal_digits(Rest, []),
    case Digits of
        [] -> {error, invalid_syntax};
        _ -> number_value_token(float, BaseChars ++ "e" ++ [Sign | Digits],
                                Tail, Line, Lex0)
    end;
exponent_token(BaseChars, Rest, Line, Lex0) ->
    {Digits, Tail} = take_decimal_digits(Rest, []),
    case Digits of
        [] -> {error, invalid_syntax};
        _ -> number_value_token(float, BaseChars ++ "e" ++ Digits,
                                Tail, Line, Lex0)
    end.

number_token(Digits, Rest, Line, Lex0) ->
    number_value_token(integer, Digits, Rest, Line, Lex0).

number_value_token(_Kind, Chars, _Rest, _Line, _Lex0)
  when length(Chars) > ?QUOD_CLIENT_GOAL_MAX_NUMBER_CHARS ->
    {error, {too_large, goal}};
number_value_token(integer, Chars, Rest, Line, Lex0) ->
    continue(Rest, Line,
             push({number, Line, list_to_integer(Chars)}, Lex0));
number_value_token(float, Chars, Rest, Line, Lex0) ->
    try list_to_float(Chars) of
        Value -> continue(Rest, Line, push({number, Line, Value}, Lex0))
    catch
        error:badarg -> {error, invalid_syntax}
    end.

take_decimal_digits([C | Rest], Acc) when C >= $0, C =< $9 ->
    take_decimal_digits(Rest, [C | Acc]);
take_decimal_digits(Rest, Acc) ->
    {lists:reverse(Acc), Rest}.

escaped_or_plain_char([$\\ | Rest]) -> escaped_char(Rest);
escaped_or_plain_char([Char | Rest]) -> {ok, Char, Rest};
escaped_or_plain_char([]) -> error.

digit_value(C) when C >= $0, C =< $9 -> C - $0;
digit_value(C) when C >= $a, C =< $f -> C - $a + 10;
digit_value(C) when C >= $A, C =< $F -> C - $A + 10;
digit_value(_) -> invalid.

%% ------------------------------------------------------------------
%% Frozen operator table
%% ------------------------------------------------------------------

symbol_value(Name) ->
    case operator_atom(Name) of
        {ok, Atom} -> Atom;
        error -> {'$quod_symbol', Name}
    end.

operator_atom(<<"?-">>) -> {ok, '?-'};
operator_atom(<<":-">>) -> {ok, ':-'};
operator_atom(<<"\\+">>) -> {ok, '\\+'};
operator_atom(<<"+">>) -> {ok, '+'};
operator_atom(<<"-">>) -> {ok, '-'};
operator_atom(<<"\\">>) -> {ok, '\\'};
operator_atom(<<";">>) -> {ok, ';'};
operator_atom(<<"->">>) -> {ok, '->'};
operator_atom(<<"=">>) -> {ok, '='};
operator_atom(<<"\\=">>) -> {ok, '\\='};
operator_atom(<<"\\==">>) -> {ok, '\\=='};
operator_atom(<<"==">>) -> {ok, '=='};
operator_atom(<<"@<">>) -> {ok, '@<'};
operator_atom(<<"@=<">>) -> {ok, '@=<'};
operator_atom(<<"@>">>) -> {ok, '@>'};
operator_atom(<<"@>=">>) -> {ok, '@>='};
operator_atom(<<"=..">>) -> {ok, '=..'};
operator_atom(<<"is">>) -> {ok, is};
operator_atom(<<"=:=">>) -> {ok, '=:='};
operator_atom(<<"=\\=">>) -> {ok, '=\\='};
operator_atom(<<"<">>) -> {ok, '<'};
operator_atom(<<"=<">>) -> {ok, '=<'};
operator_atom(<<">">>) -> {ok, '>'};
operator_atom(<<">=">>) -> {ok, '>='};
operator_atom(<<":">>) -> {ok, ':'};
operator_atom(<<"::">>) -> {ok, '::'};
operator_atom(<<"/\\">>) -> {ok, '/\\'};
operator_atom(<<"\\/">>) -> {ok, '\\/'};
operator_atom(<<"*">>) -> {ok, '*'};
operator_atom(<<"/">>) -> {ok, '/'};
operator_atom(<<"//">>) -> {ok, '//'};
operator_atom(<<"rem">>) -> {ok, 'rem'};
operator_atom(<<"mod">>) -> {ok, 'mod'};
operator_atom(<<"<<">>) -> {ok, '<<'};
operator_atom(<<">>">>) -> {ok, '>>'};
operator_atom(<<"**">>) -> {ok, '**'};
operator_atom(<<"^">>) -> {ok, '^'};
operator_atom(<<"-->">>) -> {ok, '-->'};
operator_atom(_) -> error.

operator_contract() ->
    prefix_contract() andalso infix_contract() andalso postfix_contract().

prefix_contract() ->
    erlog_parse:prefix_op('?-') =:= {yes, 1200, 1199} andalso
    erlog_parse:prefix_op(':-') =:= {yes, 1200, 1199} andalso
    erlog_parse:prefix_op('\\+') =:= {yes, 900, 900} andalso
    erlog_parse:prefix_op('+') =:= {yes, 200, 200} andalso
    erlog_parse:prefix_op('-') =:= {yes, 200, 200} andalso
    erlog_parse:prefix_op('\\') =:= {yes, 200, 200}.

postfix_contract() ->
    erlog_parse:postfix_op('+') =:= {yes, 500, 500} andalso
    erlog_parse:postfix_op('*') =:= {yes, 400, 400}.

infix_contract() ->
    %% Keep the actual table as data so every precedence and associativity is
    %% visible in one reviewable contract.
    lists:all(
      fun({Operator, Contract}) ->
              erlog_parse:infix_op(Operator) =:= Contract
      end,
      [{':-', {yes, 1199, 1200, 1199}},
       {'-->', {yes, 1199, 1200, 1199}},
       {';', {yes, 1099, 1100, 1100}},
       {'->', {yes, 1049, 1050, 1050}},
       {'=', {yes, 699, 700, 699}},
       {'\\=', {yes, 699, 700, 699}},
       {'\\==', {yes, 699, 700, 699}},
       {'==', {yes, 699, 700, 699}},
       {'@<', {yes, 699, 700, 699}},
       {'@=<', {yes, 699, 700, 699}},
       {'@>', {yes, 699, 700, 699}},
       {'@>=', {yes, 699, 700, 699}},
       {'=..', {yes, 699, 700, 699}},
       {is, {yes, 699, 700, 699}},
       {'=:=', {yes, 699, 700, 699}},
       {'=\\=', {yes, 699, 700, 699}},
       {'<', {yes, 699, 700, 699}},
       {'=<', {yes, 699, 700, 699}},
       {'>', {yes, 699, 700, 699}},
       {'>=', {yes, 699, 700, 699}},
       {':', {yes, 599, 600, 600}},
       {'::', {yes, 649, 650, 649}},
       {'+', {yes, 500, 500, 499}},
       {'-', {yes, 500, 500, 499}},
       {'/\\', {yes, 500, 500, 499}},
       {'\\/', {yes, 500, 500, 499}},
       {'*', {yes, 400, 400, 399}},
       {'/', {yes, 400, 400, 399}},
       {'//', {yes, 400, 400, 399}},
       {'rem', {yes, 400, 400, 399}},
       {'mod', {yes, 400, 400, 399}},
       {'<<', {yes, 400, 400, 399}},
       {'>>', {yes, 400, 400, 399}},
       {'**', {yes, 199, 200, 199}},
       {'^', {yes, 199, 200, 200}}]).

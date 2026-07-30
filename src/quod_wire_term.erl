-module(quod_wire_term).
-moduledoc """
Bounded, atom-safe encoding for Prolog values crossing an untrusted peer boundary.

Atoms are carried as UTF-8 binaries. Decoding reuses an existing VM atom when one is
already known; otherwise it returns the opaque `{'$quod_symbol', Binary}` value. The
opaque value re-encodes as the original atom symbol, so a symbol introduced by the
asker can pass through a target rule and return without allocating an atom there.

Only Prolog's data shapes are accepted. Node, structural-depth, and symbol-size caps
make the post-ETF validation cost deterministic. A list spine is iterative structure,
not nesting; its elements and an improper tail still increase structural depth.
""".

-export([encode/1, decode/1, decode_goal/1]).

-define(MAX_NODES, 20000).
-define(MAX_DEPTH, 64).
-define(MAX_SYMBOL_BYTES, 1024).

-type wire() :: term().

-spec encode(term()) -> {ok, wire()} | {error, bad_term}.
encode(Term) ->
    case encode(Term, 0, 0) of
        {ok, Wire, _Nodes} -> {ok, Wire};
        error -> {error, bad_term}
    end.

-spec decode(wire()) -> {ok, term()} | {error, bad_term}.
decode(Wire) ->
    case decode(Wire, 0, 0) of
        {ok, Term, _Nodes} -> {ok, Term};
        error -> {error, bad_term}
    end.

-spec decode_goal(wire()) -> {ok, term()} | {error, bad_term}.
decode_goal(Wire) ->
    case decode(Wire) of
        {ok, Goal} -> {ok, normalize_goal(Goal)};
        Error -> Error
    end.

encode(_Term, Depth, Nodes) when Depth > ?MAX_DEPTH; Nodes >= ?MAX_NODES -> error;
encode({'$quod_symbol', Binary}, _Depth, Nodes)
  when is_binary(Binary), byte_size(Binary) =< ?MAX_SYMBOL_BYTES ->
    {ok, {0, Binary}, Nodes + 1};
encode(Atom, _Depth, Nodes) when is_atom(Atom) ->
    Binary = atom_to_binary(Atom, utf8),
    case byte_size(Binary) =< ?MAX_SYMBOL_BYTES of
        true -> {ok, {0, Binary}, Nodes + 1};
        false -> error
    end;
encode(Binary, _Depth, Nodes) when is_binary(Binary) ->
    {ok, {1, Binary}, Nodes + 1};
encode(Integer, _Depth, Nodes) when is_integer(Integer) ->
    {ok, {2, Integer}, Nodes + 1};
encode(Float, _Depth, Nodes) when is_float(Float) ->
    {ok, {3, Float}, Nodes + 1};
encode(Tuple, Depth, Nodes) when is_tuple(Tuple) ->
    case encode_list(tuple_to_list(Tuple), Depth + 1, Nodes + 1, []) of
        {ok, Items, Nodes1} -> {ok, {4, Items}, Nodes1};
        error -> error
    end;
encode([], _Depth, Nodes) ->
    {ok, {5}, Nodes + 1};
encode([Head | Tail], Depth, Nodes) ->
    case encode(Head, Depth + 1, Nodes + 1) of
        {ok, Head1, Nodes1} ->
            case encode_list_tail(Tail, Depth, Nodes1) of
                {ok, Tail1, Nodes2} -> {ok, {6, Head1, Tail1}, Nodes2};
                error -> error
            end;
        error -> error
    end;
encode(_, _, _) -> error.

encode_list_tail([], Depth, Nodes) -> encode([], Depth, Nodes);
encode_list_tail([_ | _] = Tail, Depth, Nodes) -> encode(Tail, Depth, Nodes);
encode_list_tail(Tail, Depth, Nodes) -> encode(Tail, Depth + 1, Nodes).

encode_list([], _Depth, Nodes, Acc) -> {ok, lists:reverse(Acc), Nodes};
encode_list([Head | Tail], Depth, Nodes, Acc) ->
    case encode(Head, Depth, Nodes) of
        {ok, Head1, Nodes1} -> encode_list(Tail, Depth, Nodes1, [Head1 | Acc]);
        error -> error
    end.

decode(_Wire, Depth, Nodes) when Depth > ?MAX_DEPTH; Nodes >= ?MAX_NODES -> error;
decode({0, Binary}, _Depth, Nodes)
  when is_binary(Binary), byte_size(Binary) =< ?MAX_SYMBOL_BYTES ->
    Term = try binary_to_existing_atom(Binary, utf8)
           catch error:badarg -> {'$quod_symbol', Binary}
           end,
    {ok, Term, Nodes + 1};
decode({1, Binary}, _Depth, Nodes) when is_binary(Binary) ->
    {ok, Binary, Nodes + 1};
decode({2, Integer}, _Depth, Nodes) when is_integer(Integer) ->
    {ok, Integer, Nodes + 1};
decode({3, Float}, _Depth, Nodes) when is_float(Float) ->
    {ok, Float, Nodes + 1};
decode({4, Items}, Depth, Nodes) when is_list(Items) ->
    case decode_list(Items, Depth + 1, Nodes + 1, []) of
        {ok, Terms, Nodes1} -> {ok, list_to_tuple(Terms), Nodes1};
        error -> error
    end;
decode({5}, _Depth, Nodes) ->
    {ok, [], Nodes + 1};
decode({6, Head, Tail}, Depth, Nodes) ->
    case decode(Head, Depth + 1, Nodes + 1) of
        {ok, Head1, Nodes1} ->
            case decode_list_tail(Tail, Depth, Nodes1) of
                {ok, Tail1, Nodes2} -> {ok, [Head1 | Tail1], Nodes2};
                error -> error
            end;
        error -> error
    end;
decode(_, _, _) -> error.

decode_list_tail({5} = Tail, Depth, Nodes) -> decode(Tail, Depth, Nodes);
decode_list_tail({6, _, _} = Tail, Depth, Nodes) -> decode(Tail, Depth, Nodes);
decode_list_tail(Tail, Depth, Nodes) -> decode(Tail, Depth + 1, Nodes).

decode_list([], _Depth, Nodes, Acc) -> {ok, lists:reverse(Acc), Nodes};
decode_list([Head | Tail], Depth, Nodes, Acc) ->
    case decode(Head, Depth, Nodes) of
        {ok, Head1, Nodes1} -> decode_list(Tail, Depth, Nodes1, [Head1 | Acc]);
        error -> error
    end.

normalize_goal({'$quod_symbol', _Binary}) -> '$quod_unknown_goal';
normalize_goal(Tuple) when is_tuple(Tuple), tuple_size(Tuple) >= 2 ->
    case element(1, Tuple) of
        {'$quod_symbol', _Binary} -> setelement(1, Tuple, '$quod_unknown_goal');
        ',' -> normalize_goal_arg(Tuple, [2, 3]);
        ';' -> normalize_goal_arg(Tuple, [2, 3]);
        '->' -> normalize_goal_arg(Tuple, [2, 3]);
        '\\+' -> normalize_goal_arg(Tuple, [2]);
        'not' -> normalize_goal_arg(Tuple, [2]);
        once -> normalize_goal_arg(Tuple, [2]);
        call -> normalize_goal_arg(Tuple, [2]);
        findall -> normalize_goal_arg(Tuple, [3]);
        bagof -> normalize_goal_arg(Tuple, [3]);
        setof -> normalize_goal_arg(Tuple, [3]);
        _ -> Tuple
    end;
normalize_goal(Goal) -> Goal.

normalize_goal_arg(Tuple, Positions) ->
    lists:foldl(fun(Position, Acc) ->
                        setelement(Position, Acc,
                                   normalize_goal(element(Position, Acc)))
                end, Tuple, Positions).

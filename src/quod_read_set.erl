-module(quod_read_set).
-moduledoc """
One canonical read-set codec for plans, semantic identities and signatures.

Predicate identity is `{UTF8Name, Arity}`, never the local representation of
its symbol. Ascending name/arity order preserves the real .174 small-map
bytes; map traversal is not a wire contract. An atom and an opaque symbol
with the same name and arity are aliases, not two dependencies.

Consumers validate the carried pair list before constructing a lookup map or
materializing vocabulary. This library neither creates atoms nor drops reads.
""".

-export([encode/1, pairs/1, valid_pairs/1, valid/1]).

-doc "Encode a valid read set in canonical name/arity order without allocating atoms.".
-spec encode(term()) -> {ok, binary()} | {error, bad_term}.
encode(ReadSet) ->
    case pairs(ReadSet) of
        {ok, Pairs} -> quod_wire_term:encode_canonical(Pairs);
        error -> {error, bad_term}
    end.

-doc "Return canonical ordered pairs, refusing malformed entries and name/arity aliases.".
-spec pairs(term()) -> {ok, list()} | error.
pairs(ReadSet) when is_map(ReadSet) ->
    case indexed_pairs(maps:to_list(ReadSet), #{}, []) of
        {ok, Indexed} ->
            {ok, [Pair || {_NameArity, Pair} <- lists:keysort(1, Indexed)]};
        error -> error
    end;
pairs(_) -> error.

-doc "Validate a lookup map's key/token alphabet and representation-independent uniqueness.".
-spec valid(term()) -> boolean().
valid(ReadSet) when is_map(ReadSet) ->
    case indexed_pairs(maps:to_list(ReadSet), #{}, []) of
        {ok, _} -> true;
        error -> false
    end;
valid(_) -> false.

indexed_pairs([Pair | Rest], Seen, Acc) ->
    case pair_key(Pair) of
        {ok, Key} when not is_map_key(Key, Seen) ->
            indexed_pairs(Rest, Seen#{Key => true}, [{Key, Pair} | Acc]);
        _ -> error
    end;
indexed_pairs([], _Seen, Acc) -> {ok, Acc}.

-doc "Validate the carried order, unique name/arity keys and tokens before materialization.".
-spec valid_pairs(term()) -> boolean().
valid_pairs(Pairs) -> valid_pairs(Pairs, none).

valid_pairs([Pair | Rest], Previous) ->
    case pair_key(Pair) of
        {ok, Key} when Previous =:= none; Previous < Key ->
            valid_pairs(Rest, Key);
        _ -> false
    end;
valid_pairs([], _Previous) -> true;
valid_pairs(_, _) -> false.

pair_key({{Symbol, Arity}, Token}) when is_integer(Arity), Arity >= 0 ->
    case {symbol_name(Symbol), valid_token(Token)} of
        {{ok, Name}, true} -> {ok, {Name, Arity}};
        _ -> error
    end;
pair_key(_) -> error.

symbol_name(Atom) when is_atom(Atom) -> {ok, atom_to_binary(Atom, utf8)};
symbol_name({'$quod_symbol', Name} = Symbol) when is_binary(Name) ->
    case quod_wire_term:is_symbol(Symbol) andalso
         unicode:characters_to_binary(Name, utf8, utf8) =:= Name of
        true -> {ok, Name};
        false -> error
    end;
symbol_name(_) -> error.

valid_token(never_present) -> true;
valid_token(static) -> true;
valid_token({present, Height}) -> is_integer(Height) andalso Height >= 0;
valid_token({absent, Height}) -> is_integer(Height) andalso Height >= 0;
valid_token(_) -> false.

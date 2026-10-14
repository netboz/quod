-module(quod_read_set).
-moduledoc """
One canonical read-set codec for plans, semantic identities and signatures.

Predicate identity is `{UTF8Name, Arity}`, never the local representation of
its symbol. Ascending name/arity order preserves the real .174 small-map
bytes; map traversal is not a wire contract. An atom and an opaque symbol
with the same name and arity are aliases, not two dependencies.

Terminal operation evidence uses an atom-free three-tuple key and immutable
claim/result token. Tuple ordering puts it after all predicate keys without
changing any existing predicate-only bytes. It is still a signed, counted read;
only mutable predicate reads contribute atomic reservation keys.

Consumers validate the carried pair list before constructing a lookup map or
materializing vocabulary. This library neither creates atoms nor drops reads.
""".

-export([encode/1, pairs/1, valid_pairs/1, valid/1, kind/1, at_height/2]).

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
pair_key({{1, Agent, <<_:256>>} = Key,
          {<<_:256>>, Ref, Claim, Status, Terminal, Published}})
  when is_binary(Agent), is_integer(Claim), Claim > 0,
       is_integer(Status), Status >= 0, Status =< 2,
       is_integer(Terminal), Terminal >= Claim,
       is_integer(Published), Published >= Terminal ->
    case quod_agent_ref:valid_principal({agent, Agent}) andalso
         valid_outcome_ref(Ref, Status, Terminal, Published) of
        true -> {ok, Key};
        false -> error
    end;
pair_key(_) -> error.

%% Integer tags keep this extension atom-free before vocabulary materialization.
%% Existing two-tuple predicate keys retain their byte order before these keys.
valid_outcome_ref({0, <<_:256>>}, Status, H, H) -> Status < 2;
valid_outcome_ref({1, <<_:256>>, <<_:256>>, <<_:256>>}, Status, _, _) ->
    Status =:= 0 orelse Status =:= 2;
valid_outcome_ref(_, _, _, _) -> false.

kind({Symbol, Arity}) when is_integer(Arity), Arity >= 0 ->
    case symbol_name(Symbol) of {ok, _} -> predicate; error -> invalid end;
kind({1, Agent, <<_:256>>}) ->
    case quod_agent_ref:valid_principal({agent, Agent}) of
        true -> operation_outcome;
        false -> invalid
    end;
kind(_) -> invalid.

%% Terminal evidence is independent of capture time, but must have been fully
%% published in the anchored snapshot that the sealed plan names.
at_height(ReadSet, Height) when is_integer(Height), Height >= 0 ->
    valid(ReadSet) andalso maps:fold(
      fun({1, _, _}, {_, _, _, _, _, Published}, Acc) -> Acc andalso Published =< Height;
         (_, _, Acc) -> Acc
      end, true, ReadSet);
at_height(_, _) -> false.

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

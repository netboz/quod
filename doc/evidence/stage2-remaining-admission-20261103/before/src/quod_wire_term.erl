-module(quod_wire_term).
-moduledoc """
Atom-safe encoding for Prolog values crossing an untrusted peer boundary.

Atoms are carried as UTF-8 binaries. Decoding reuses an existing VM atom when one is
already known; otherwise it returns the opaque `{'$quod_symbol', Binary}` value. The
opaque value re-encodes as the original atom symbol, so a relay can pass a
target-owned symbol through without allocating an atom. The authenticated
target explicitly materializes its callable symbols before execution.

Only Prolog's data shapes are accepted. The owning protocol supplies any byte
allowance; this codec does not choose a population, nesting or symbol quota.

Failure-reason stacks add one shared canonical contract on top of that alphabet.
Scope completion and durable abort Decisions both use the same encoder/decoder, so a
stack accepted during a proof cannot acquire different byte, count, or shape semantics
at either boundary.

`materialize_symbols/1` is the sole controlled transition from decoded opaque
symbols to VM atoms.  Callers use it only after authenticating an ontology-owned
payload. New work is admitted by Prolog policy; historical materialization
checks the real VM headroom without re-admitting accepted history.
""".

-include("quod_vm_limits.hrl").
-include_lib("erlog/src/erlog_int.hrl").

-export([encode/1, decode/1,
         encode_canonical/1, decode_canonical/2,
         encode_bindings/2, decode_bindings/2,
         materialize_symbols/1, materialize_goal_symbols/1, materialize_goal_symbols/2,
         normalize_answer_symbols/2,
         goal_symbol_names/1, goal_symbol_names/2, symbol_names/1,
         is_symbol/1, callable_functor/1,
         is_ground/1,
         encode_failure_reasons/1, decode_failure_reasons/1,
         valid_failure_reason_stack/1]).

-type wire() :: term().

-doc "Whether a term is one atom symbol in materialized or opaque wire form.".
-spec is_symbol(term()) -> boolean().
is_symbol(Atom) when is_atom(Atom) -> true;
is_symbol({'$quod_symbol', Binary})
  when is_binary(Binary) -> true;
is_symbol(_) -> false.

-doc "Return a callable's functor without materializing an opaque symbol.".
-spec callable_functor(term()) ->
          {ok, {term(), non_neg_integer()}} | error.
callable_functor({'$quod_symbol', _} = Symbol) ->
    case is_symbol(Symbol) of
        true -> {ok, {Symbol, 0}};
        false -> error
    end;
callable_functor(Atom) when is_atom(Atom) ->
    {ok, {Atom, 0}};
callable_functor(Term) when is_tuple(Term), tuple_size(Term) >= 2 ->
    case is_symbol(element(1, Term)) of
        true -> {ok, {element(1, Term), tuple_size(Term) - 1}};
        false -> error
    end;
callable_functor(_) ->
    error.

-doc "Whether an Erlog term contains no unbound variable (including anonymous `_`).".
-spec is_ground(term()) -> boolean().
is_ground(T) when is_tuple(T), tuple_size(T) =:= 1 -> false;
is_ground(T) when is_tuple(T) ->
    lists:all(fun is_ground/1, tuple_to_list(T));
is_ground([H | T]) ->
    is_ground(H) andalso is_ground(T);
is_ground([]) ->
    true;
is_ground(_) ->
    true.

-spec encode(term()) -> {ok, wire()} | {error, bad_term}.
encode(Term) ->
    case encode_value(Term) of
        {ok, Wire} -> {ok, Wire};
        error -> {error, bad_term}
    end.

-spec decode(wire()) -> {ok, term()} | {error, bad_term}.
decode(Wire) ->
    case decode_value(Wire) of
        {ok, Term} -> {ok, Term};
        error -> {error, bad_term}
    end.

-doc """
Normalize a remote proof answer against the caller's retained goal vocabulary.

An atom-safe decode represents an unknown symbol as `{'$quod_symbol', Bytes}`,
while a later decode may return the atom after the target has materialized the
same callable. Both spellings denote the same Prolog symbol. This function
chooses the representation already retained by the caller (preferring the
opaque spelling if a concurrent first use left both spellings in that goal)
and applies it consistently to the goal and answer before unification.

Symbols absent from the retained goal are left untouched. No atom is created.
Network inputs have passed bounded wire validation; co-hosted inputs are
already valid Erlog terms from the same proof-session owner.
""".
-spec normalize_answer_symbols(term(), term()) -> {term(), term()}.
normalize_answer_symbols(Goal, Answer) ->
    Representations = retained_symbol_representations(Goal, #{}),
    {normalize_retained_symbols(Goal, Representations),
     normalize_retained_symbols(Answer, Representations)}.

-doc "Encode one bounded Prolog term as canonical deterministic wire bytes.".
-spec encode_canonical(term()) -> {ok, binary()} | {error, bad_term}.
encode_canonical(Term) ->
    case encode(Term) of
        {ok, Wire} -> {ok, canonical(Wire)};
        {error, bad_term} = Error -> Error
    end.

-doc "Safely decode one bounded, canonical wire binary without allocating atoms.".
-spec decode_canonical(term(), non_neg_integer() | unlimited) ->
          {ok, term()} | {error, bad_term | too_large}.
decode_canonical(Blob, MaxBytes)
  when is_binary(Blob),
       (MaxBytes =:= unlimited orelse (is_integer(MaxBytes) andalso MaxBytes >= 0)) ->
    case quod_safe_term:decode(Blob, MaxBytes) of
        {ok, Wire} ->
            case canonical(Wire) =:= Blob of
                true -> decode(Wire);
                false -> {error, bad_term}
            end;
        {error, too_large} -> {error, too_large};
        {error, _} -> {error, bad_term}
    end;
decode_canonical(_Blob, _MaxBytes) ->
    {error, bad_term}.

-doc "Encode canonical named bindings under the caller's owning byte allowance.".
-spec encode_bindings(map(), non_neg_integer() | unlimited) ->
          {ok, binary()} | {error, bad_term | invalid_result | too_large}.
encode_bindings(Bindings, MaxBytes) when is_map(Bindings),
                                        (MaxBytes =:= unlimited orelse (is_integer(MaxBytes) andalso MaxBytes >= 0)) ->
    case binding_pairs(Bindings) of
        {ok, Pairs} ->
            case valid_bindings(Pairs, none) of
                true ->
                    case encode_canonical(Pairs) of
                        {ok, Blob} when MaxBytes =:= unlimited; byte_size(Blob) =< MaxBytes -> {ok, Blob};
                        {ok, _} -> {error, too_large};
                        {error, _} = Error -> Error
                    end;
                false -> {error, invalid_result}
            end;
        error -> {error, invalid_result}
    end;
encode_bindings(_, _) -> {error, invalid_result}.

-doc "Decode canonical named bindings without allocating atoms or choosing a resource allowance.".
-spec decode_bindings(term(), non_neg_integer() | unlimited) ->
          {ok, [{binary(), term()}]} | {error, bad_term | invalid_result | too_large}.
decode_bindings(Blob, MaxBytes) ->
    case decode_canonical(Blob, MaxBytes) of
        {ok, Pairs} when is_list(Pairs) ->
            case valid_bindings(Pairs, none) of
                true -> {ok, Pairs};
                false -> {error, invalid_result}
            end;
        {ok, _} -> {error, invalid_result};
        {error, _} = Error -> Error
    end.

%% Signed requests use atom-free variable names; trusted VM proofs use atoms.
%% Both retain the same strictly ordered canonical names and wire bytes.
binding_pairs(Bindings) ->
    try
        {ok, lists:sort([{binding_name(Name), Value}
                         || {Name, Value} <- maps:to_list(Bindings)])}
    catch error:badarg -> error
    end.

binding_name(Name) when is_atom(Name) -> atom_to_binary(Name, utf8);
binding_name(Name) when is_binary(Name) -> Name;
binding_name(_) -> error(badarg).

valid_bindings([], _Previous) -> true;
valid_bindings([{Name, _Value} | Rest], Previous)
  when is_binary(Name), byte_size(Name) > 0,
       (Previous =:= none orelse Previous < Name) ->
    valid_bindings(Rest, Name);
valid_bindings(_, _) -> false.

-doc "Materialize authenticated material after admission, preserving real VM headroom.".
-spec materialize_symbols(term()) ->
          {ok, term()} |
          {error, malformed_material | atom_limit}.
materialize_symbols(Term) ->
    case collect_new_symbols(Term, #{}) of
        {ok, Symbols} ->
            Names = lists:sort(maps:keys(Symbols)),
            case materialize_symbol_names(Names) of
                ok -> {ok, replace_symbols(Term)};
                {error, _} = Error -> Error
            end;
        error ->
            {error, malformed_material}
    end.

%% Materialize only callable functors. A goal's ordinary argument values remain
%% opaque: a relay must not turn an arbitrary caller datum into a target atom.
-spec materialize_goal_symbols(term()) ->
          {ok, term()} |
          {error, malformed_material | too_many_new_atoms | atom_limit}.
materialize_goal_symbols(Goal) -> materialize_goal_symbols(Goal, undefined).

%% Only an authenticated owner may supply its canonical namespace. Self-scoped
%% goals execute in that same owner; foreign inner callables remain deferred.
-spec materialize_goal_symbols(term(), binary() | undefined) ->
          {ok, term()} | {error, malformed_material | too_many_new_atoms | atom_limit}.
materialize_goal_symbols(Goal, Owner) ->
    case collect_goal_symbols(Goal, #{}, Owner) of
        {ok, Symbols}
          when map_size(Symbols) =< ?QUOD_MAX_NEW_MATERIAL_ATOMS ->
            Names = lists:sort(maps:keys(Symbols)),
            case materialize_symbol_names(Names) of
                ok -> {ok, replace_goal_symbols(Goal, Owner)};
                {error, _} = Error -> Error
            end;
        {ok, _TooMany} ->
            {error, too_many_new_atoms};
        error ->
            {error, malformed_material}
    end.

-doc """
Return the distinct opaque callable symbols in one atom-safe goal.

This is the process-free admission half of `materialize_goal_symbols/1`: it
performs the identical callable-position walk but never creates an atom.
""".
-spec goal_symbol_names(term()) ->
          {ok, [binary()]} | {error, malformed_material}.
goal_symbol_names(Goal) -> goal_symbol_names(Goal, undefined).

-spec goal_symbol_names(term(), binary() | undefined) ->
          {ok, [binary()]} | {error, malformed_material}.
goal_symbol_names(Goal, Owner) ->
    case collect_goal_symbols(Goal, #{}, Owner) of
        {ok, Symbols} -> {ok, lists:sort(maps:keys(Symbols))};
        error -> {error, malformed_material}
    end.

-doc "Return every distinct symbol in one bounded wire term without allocating atoms.".
-spec symbol_names(term()) -> {ok, [binary()]} | {error, malformed_material}.
symbol_names(Term) ->
    case collect_symbol_names(Term, #{}) of
        {ok, Symbols} -> {ok, lists:sort(maps:keys(Symbols))};
        error -> {error, malformed_material}
    end.

collect_symbol_names({'$quod_symbol', Binary}, Symbols)
  when is_binary(Binary) ->
    {ok, Symbols#{Binary => true}};
collect_symbol_names(Atom, Symbols) when is_atom(Atom) ->
    Binary = atom_to_binary(Atom, utf8),
    {ok, Symbols#{Binary => true}};
collect_symbol_names(Tuple, Symbols) when is_tuple(Tuple) ->
    collect_symbol_names_list(tuple_to_list(Tuple), Symbols);
collect_symbol_names([Head | Tail], Symbols0) ->
    case collect_symbol_names(Head, Symbols0) of
        {ok, Symbols1} -> collect_symbol_names(Tail, Symbols1);
        error -> error
    end;
collect_symbol_names([], Symbols) ->
    {ok, Symbols};
collect_symbol_names(Value, Symbols)
  when is_binary(Value); is_integer(Value); is_float(Value) ->
    {ok, Symbols};
collect_symbol_names(_Malformed, _Symbols) ->
    error.

collect_symbol_names_list([], Symbols) ->
    {ok, Symbols};
collect_symbol_names_list([Value | Rest], Symbols0) ->
    case collect_symbol_names(Value, Symbols0) of
        {ok, Symbols1} -> collect_symbol_names_list(Rest, Symbols1);
        error -> error
    end.

retained_symbol_representations({'$quod_symbol', Name}, Acc)
  when is_binary(Name) ->
    Acc#{Name => {'$quod_symbol', Name}};
retained_symbol_representations(Tuple, Acc)
  when is_tuple(Tuple), tuple_size(Tuple) =:= 1 ->
    %% Erlog variables are not vocabulary, even when their names are atoms.
    Acc;
retained_symbol_representations(Tuple, Acc) when is_tuple(Tuple) ->
    lists:foldl(
      fun retained_symbol_representations/2, Acc, tuple_to_list(Tuple));
retained_symbol_representations([Head | Tail], Acc0) ->
    retained_symbol_representations(
      Tail, retained_symbol_representations(Head, Acc0));
retained_symbol_representations([], Acc) ->
    Acc;
retained_symbol_representations(Atom, Acc) when is_atom(Atom) ->
    Name = atom_to_binary(Atom, utf8),
    case maps:get(Name, Acc, Atom) of
        {'$quod_symbol', Name} -> Acc;
        _ -> Acc#{Name => Atom}
    end;
retained_symbol_representations(_Value, Acc) ->
    Acc.

normalize_retained_symbols({'$quod_symbol', Name}, Representations)
  when is_binary(Name) ->
    maps:get(Name, Representations, {'$quod_symbol', Name});
normalize_retained_symbols(Tuple, _Representations)
  when is_tuple(Tuple), tuple_size(Tuple) >= 1,
       element(1, Tuple) =:= '$quod_symbol' ->
    %% Bounded wire validation rejects malformed reserved markers. Keep a
    %% trusted malformed term indivisible here too instead of treating the
    %% reserved marker atom as ordinary vocabulary.
    Tuple;
normalize_retained_symbols(Tuple, _Representations)
  when is_tuple(Tuple), tuple_size(Tuple) =:= 1 ->
    Tuple;
normalize_retained_symbols(Tuple, Representations) when is_tuple(Tuple) ->
    list_to_tuple(
      [normalize_retained_symbols(Value, Representations)
       || Value <- tuple_to_list(Tuple)]);
normalize_retained_symbols([Head | Tail], Representations) ->
    [normalize_retained_symbols(Head, Representations) |
     normalize_retained_symbols(Tail, Representations)];
normalize_retained_symbols([], _Representations) ->
    [];
normalize_retained_symbols(Atom, Representations) when is_atom(Atom) ->
    Name = atom_to_binary(Atom, utf8),
    maps:get(Name, Representations, Atom);
normalize_retained_symbols(Value, _Representations) ->
    Value.

materialize_symbol_names(Names) ->
    case lists:all(fun valid_symbol_name/1, Names) of
        false -> {error, malformed_material};
        true -> materialize_valid_symbol_names(Names)
    end.

materialize_valid_symbol_names(Names) ->
    case atom_headroom(length(Names)) of
        true ->
            try
                _ = [binary_to_atom(Name, utf8) || Name <- Names],
                ok
            catch
                error:system_limit -> {error, atom_limit};
                error:badarg -> {error, malformed_material}
            end;
        false ->
            {error, atom_limit}
    end.

atom_headroom(NewAtoms) ->
    erlang:system_info(atom_count) + NewAtoms + ?QUOD_ATOM_SAFETY_MARGIN <
        erlang:system_info(atom_limit).

collect_new_symbols({'$quod_symbol', Name}, Acc) when is_binary(Name) ->
    {ok, Acc#{Name => true}};
collect_new_symbols(Tuple, _Acc)
  when is_tuple(Tuple), tuple_size(Tuple) >= 1,
       element(1, Tuple) =:= '$quod_symbol' ->
    %% The opaque-symbol marker is reserved and has exactly one binary
    %% argument.  Reject malformed lookalikes before replacement can reach
    %% binary_to_existing_atom/2 with attacker-controlled non-binary input.
    error;
collect_new_symbols(Tuple, Acc) when is_tuple(Tuple) ->
    collect_new_symbol_list(tuple_to_list(Tuple), Acc);
collect_new_symbols([Head | Tail], Acc) ->
    case collect_new_symbols(Head, Acc) of
        {ok, Acc1} -> collect_new_symbols(Tail, Acc1);
        error -> error
    end;
collect_new_symbols([], Acc) ->
    {ok, Acc};
collect_new_symbols(Term, Acc)
  when is_atom(Term); is_binary(Term); is_integer(Term); is_float(Term) ->
    {ok, Acc};
collect_new_symbols(_Term, _Acc) ->
    error.

collect_new_symbol_list([], Acc) ->
    {ok, Acc};
collect_new_symbol_list([Term | Rest], Acc) ->
    case collect_new_symbols(Term, Acc) of
        {ok, Acc1} -> collect_new_symbol_list(Rest, Acc1);
        error -> error
    end.

valid_symbol_name(Name) ->
    try unicode:characters_to_binary(Name, utf8, utf8) of
        Name -> true;
        _ -> false
    catch
        _:_ -> false
    end.

replace_symbols({'$quod_symbol', Name}) ->
    binary_to_existing_atom(Name, utf8);
replace_symbols(Tuple) when is_tuple(Tuple) ->
    list_to_tuple([replace_symbols(Term) || Term <- tuple_to_list(Tuple)]);
replace_symbols([Head | Tail]) ->
    [replace_symbols(Head) | replace_symbols(Tail)];
replace_symbols([]) ->
    [];
replace_symbols(Term) ->
    Term.

collect_goal_symbols({'$quod_symbol', Name}, Acc, Owner) when is_binary(Name) ->
    {ok, Acc#{Name => true}};
collect_goal_symbols(Tuple, _Acc, Owner)
  when is_tuple(Tuple), tuple_size(Tuple) >= 1,
       element(1, Tuple) =:= '$quod_symbol' ->
    error;
collect_goal_symbols(Tuple, Acc, Owner) when is_tuple(Tuple), tuple_size(Tuple) >= 2 ->
    case element(1, Tuple) of
        {'$quod_symbol', Name} when is_binary(Name) ->
            collect_opaque_goal_positions(Name, Tuple, Acc#{Name => true}, Owner);
        Marker when is_tuple(Marker), tuple_size(Marker) >= 1,
                    element(1, Marker) =:= '$quod_symbol' -> error;
        ',' -> collect_goal_positions(Tuple, [2, 3], Acc, Owner);
        ';' -> collect_goal_positions(Tuple, [2, 3], Acc, Owner);
        '->' -> collect_goal_positions(Tuple, [2, 3], Acc, Owner);
        '\\+' -> collect_goal_positions(Tuple, [2], Acc, Owner);
        'not' -> collect_goal_positions(Tuple, [2], Acc, Owner);
        once -> collect_goal_positions(Tuple, [2], Acc, Owner);
        call -> collect_goal_positions(Tuple, [2], Acc, Owner);
        independent when tuple_size(Tuple) =:= 2 -> collect_goal_positions(Tuple, [2], Acc, Owner);
        transaction when tuple_size(Tuple) =:= 2 -> collect_goal_positions(Tuple, [2], Acc, Owner);
        findall -> collect_goal_positions(Tuple, [3], Acc, Owner);
        bagof -> collect_goal_positions(Tuple, [3], Acc, Owner);
        setof -> collect_goal_positions(Tuple, [3], Acc, Owner);
        asserta -> collect_clause_symbol(Tuple, 2, Acc, Owner);
        assertz -> collect_clause_symbol(Tuple, 2, Acc, Owner);
        retract -> collect_clause_symbol(Tuple, 2, Acc, Owner);
        retractall -> collect_clause_symbol(Tuple, 2, Acc, Owner);
        '::' -> collect_selector_symbol(Tuple, 2, Acc, Owner);
        _ -> {ok, Acc}
    end;
collect_goal_symbols(_Goal, Acc, Owner) ->
    {ok, Acc}.

%% Parser V2 deliberately keeps every source identifier opaque. Once an
%% opaque callable names one of Prolog's goal-bearing built-ins, its executable
%% positions still need the same walk as the already-materialized spelling.
%% Unknown callables keep ordinary arguments opaque.
collect_opaque_goal_positions(<<"::">>, Tuple, Acc, Owner) ->
    collect_selector_symbol(Tuple, 2, Acc, Owner);
collect_opaque_goal_positions(<<"once">>, Tuple, Acc, Owner) ->
    collect_goal_positions(Tuple, [2], Acc, Owner);
collect_opaque_goal_positions(<<"call">>, Tuple, Acc, Owner) ->
    collect_goal_positions(Tuple, [2], Acc, Owner);
collect_opaque_goal_positions(<<"independent">>, Tuple, Acc, Owner) when tuple_size(Tuple) =:= 2 ->
    collect_goal_positions(Tuple, [2], Acc, Owner);
collect_opaque_goal_positions(<<"transaction">>, Tuple, Acc, Owner) when tuple_size(Tuple) =:= 2 ->
    collect_goal_positions(Tuple, [2], Acc, Owner);
collect_opaque_goal_positions(<<"not">>, Tuple, Acc, Owner) ->
    collect_goal_positions(Tuple, [2], Acc, Owner);
collect_opaque_goal_positions(<<"findall">>, Tuple, Acc, Owner) ->
    collect_goal_positions(Tuple, [3], Acc, Owner);
collect_opaque_goal_positions(<<"bagof">>, Tuple, Acc, Owner) ->
    collect_goal_positions(Tuple, [3], Acc, Owner);
collect_opaque_goal_positions(<<"setof">>, Tuple, Acc, Owner) ->
    collect_goal_positions(Tuple, [3], Acc, Owner);
collect_opaque_goal_positions(<<"asserta">>, Tuple, Acc, Owner) ->
    collect_clause_symbol(Tuple, 2, Acc, Owner);
collect_opaque_goal_positions(<<"assertz">>, Tuple, Acc, Owner) ->
    collect_clause_symbol(Tuple, 2, Acc, Owner);
collect_opaque_goal_positions(<<"retract">>, Tuple, Acc, Owner) ->
    collect_clause_symbol(Tuple, 2, Acc, Owner);
collect_opaque_goal_positions(<<"retractall">>, Tuple, Acc, Owner) ->
    collect_clause_symbol(Tuple, 2, Acc, Owner);
collect_opaque_goal_positions(_Name, _Tuple, Acc, Owner) ->
    {ok, Acc}.

%% A clause passed to a database-update predicate contains executable syntax:
%% its head is a callable and a rule body is a goal.  Ordinary arguments of
%% that head remain opaque data, exactly like arguments of any other goal.
collect_clause_symbol(Tuple, Position, Acc, Owner)
  when Position =< tuple_size(Tuple) ->
    collect_clause_symbols(element(Position, Tuple), Acc, Owner);
collect_clause_symbol(_Tuple, _Position, _Acc, Owner) ->
    error.

collect_clause_symbols({{'$quod_symbol', <<":-">>}, Head, Body}, Acc, Owner) ->
    collect_clause_symbols({':-',Head,Body},Acc, Owner);
collect_clause_symbols({':-', Head, Body}, Acc, Owner) ->
    case collect_goal_symbols(Head, Acc, Owner) of
        {ok, Acc1} -> collect_goal_symbols(Body, Acc1, Owner);
        error -> error
    end;
collect_clause_symbols(Clause, Acc, Owner) ->
    collect_goal_symbols(Clause, Acc, Owner).

%% The selector belongs to this scope. Only a selector for the authenticated
%% current owner also owns its inner goal; a foreign destination admits its own.
collect_selector_symbol(Tuple, Position, Acc, Owner)
  when Position =< tuple_size(Tuple) ->
    case collect_new_symbols(element(Position, Tuple), Acc) of
        {ok, Acc1} when tuple_size(Tuple) =:= 3, is_binary(Owner) ->
            case quod_ontology_name:flatten(element(Position, Tuple)) of
                Owner -> collect_goal_symbols(element(3, Tuple), Acc1, Owner);
                _ -> {ok, Acc1}
            end;
        Result -> Result
    end;
collect_selector_symbol(_Tuple, _Position, _Acc, _Owner) -> error.

collect_goal_positions(_Tuple, [], Acc, Owner) ->
    {ok, Acc};
collect_goal_positions(Tuple, [Position | Rest], Acc, Owner) ->
    case Position =< tuple_size(Tuple) of
        true ->
            case collect_goal_symbols(element(Position, Tuple), Acc, Owner) of
                {ok, Acc1} -> collect_goal_positions(Tuple, Rest, Acc1, Owner);
                error -> error
            end;
        false ->
            error
    end.

replace_goal_symbols({'$quod_symbol', Name}, Owner) ->
    binary_to_existing_atom(Name, utf8);
replace_goal_symbols(Tuple, Owner) when is_tuple(Tuple), tuple_size(Tuple) >= 2 ->
    case element(1, Tuple) of
        {'$quod_symbol', Name} ->
            %% Re-enter after replacing the callable so a V2 spelling such as
            %% opaque assertz(opaque_head(...)) receives the same executable-
            %% position treatment as an already-materialized assertz/1.
            replace_goal_symbols(
              setelement(1, Tuple, binary_to_existing_atom(Name, utf8)), Owner);
        ',' -> replace_goal_positions(Tuple, [2, 3], Owner);
        ';' -> replace_goal_positions(Tuple, [2, 3], Owner);
        '->' -> replace_goal_positions(Tuple, [2, 3], Owner);
        '\\+' -> replace_goal_positions(Tuple, [2], Owner);
        'not' -> replace_goal_positions(Tuple, [2], Owner);
        once -> replace_goal_positions(Tuple, [2], Owner);
        call -> replace_goal_positions(Tuple, [2], Owner);
        independent when tuple_size(Tuple) =:= 2 -> replace_goal_positions(Tuple, [2], Owner);
        transaction when tuple_size(Tuple) =:= 2 -> replace_goal_positions(Tuple, [2], Owner);
        findall -> replace_goal_positions(Tuple, [3], Owner);
        bagof -> replace_goal_positions(Tuple, [3], Owner);
        setof -> replace_goal_positions(Tuple, [3], Owner);
        asserta -> replace_clause_symbol(Tuple, 2, Owner);
        assertz -> replace_clause_symbol(Tuple, 2, Owner);
        retract -> replace_clause_symbol(Tuple, 2, Owner);
        retractall -> replace_clause_symbol(Tuple, 2, Owner);
        '::' -> replace_selector_symbol(Tuple, 2, Owner);
        _ -> Tuple
    end;
replace_goal_symbols(Goal, Owner) ->
    Goal.

replace_clause_symbol(Tuple, Position, Owner) when Position =< tuple_size(Tuple) ->
    setelement(Position, Tuple,
               replace_clause_symbols(element(Position, Tuple), Owner));
replace_clause_symbol(Tuple, _Position, Owner) ->
    Tuple.

replace_clause_symbols({{'$quod_symbol', <<":-">>}, Head, Body}, Owner) ->
    replace_clause_symbols({':-',Head,Body}, Owner);
replace_clause_symbols({':-', Head, Body}, Owner) ->
    {':-', replace_goal_symbols(Head, Owner), replace_goal_symbols(Body, Owner)};
replace_clause_symbols(Clause, Owner) ->
    replace_goal_symbols(Clause, Owner).

replace_selector_symbol(Tuple, Position, Owner) when Position =< tuple_size(Tuple) ->
    Selected = setelement(Position, Tuple, replace_symbols(element(Position, Tuple))),
    case is_binary(Owner) andalso tuple_size(Tuple) =:= 3 andalso
         quod_ontology_name:flatten(element(Position, Tuple)) =:= Owner of
        true -> setelement(3, Selected, replace_goal_symbols(element(3, Tuple), Owner));
        false -> Selected
    end;
replace_selector_symbol(Tuple, _Position, _Owner) -> Tuple.

replace_goal_positions(Tuple, Positions, Owner) ->
    lists:foldl(
      fun(Position, Acc) ->
              setelement(Position, Acc,
                         replace_goal_symbols(element(Position, Acc), Owner))
      end, Tuple, Positions).

-doc "Encode one complete, possibly-empty Erlog failure-reason stack.".
-spec encode_failure_reasons(term()) ->
          {ok, binary()} | {error, bad_term | too_large}.
encode_failure_reasons(Reasons) ->
    case validate_failure_reasons(Reasons, 0) of
        ok -> encode_failure_reason_stack(Reasons);
        {error, _} = Error -> Error
    end.

-doc "Decode and re-canonicalize one complete Erlog failure-reason stack.".
-spec decode_failure_reasons(term()) ->
          {ok, [term()]} | {error, bad_term | too_large}.
decode_failure_reasons(Blob)
  when is_binary(Blob),
       byte_size(Blob) =< ?ERLOG_MAX_FAILURE_REASONS_BYTES ->
    case quod_safe_term:decode(Blob, ?ERLOG_MAX_FAILURE_REASONS_BYTES) of
        {ok, Wire} -> decode_failure_reason_wire(Blob, Wire);
        {error, too_large} -> {error, too_large};
        {error, _} -> {error, bad_term}
    end;
decode_failure_reasons(Blob) when is_binary(Blob) ->
    {error, too_large};
decode_failure_reasons(_) ->
    {error, bad_term}.

-doc "Return whether a full stack satisfies the canonical Quod wire contract.".
-spec valid_failure_reason_stack(term()) -> boolean().
valid_failure_reason_stack(Reasons) ->
    case encode_failure_reasons(Reasons) of
        {ok, _Blob} -> true;
        {error, _} -> false
    end.

validate_failure_reasons([], _Count) ->
    ok;
validate_failure_reasons([_ | _], Count)
  when Count >= ?ERLOG_MAX_FAILURE_REASONS ->
    {error, too_large};
validate_failure_reasons([Reason | Rest], Count) ->
    case validate_failure_reason(Reason) of
        ok -> validate_failure_reasons(Rest, Count + 1);
        {error, _} = Error -> Error
    end;
validate_failure_reasons(_, _Count) ->
    {error, bad_term}.

validate_failure_reason(Reason) ->
    %% The bounded structural pass runs first, so the portability walk below
    %% never traverses an application term beyond the codec's depth bound.
    case encode(Reason) of
        {ok, Wire} ->
            case erlog_int:valid_failure_reason(Reason) of
                true ->
                    case byte_size(canonical(Wire)) =<
                         ?ERLOG_MAX_FAILURE_REASON_BYTES of
                        true -> ok;
                        false -> {error, too_large}
                    end;
                false ->
                    {error, bad_term}
            end;
        {error, bad_term} ->
            {error, bad_term}
    end.

encode_failure_reason_stack(Reasons) ->
    case encode(Reasons) of
        {ok, Wire} ->
            Blob = canonical(Wire),
            case byte_size(Blob) =< ?ERLOG_MAX_FAILURE_REASONS_BYTES of
                true -> {ok, Blob};
                false -> {error, too_large}
            end;
        {error, bad_term} ->
            {error, bad_term}
    end.

decode_failure_reason_wire(Blob, Wire) ->
    case canonical(Wire) =:= Blob of
        true -> decode_canonical_failure_reason_wire(Blob, Wire);
        false ->
            {error, bad_term}
    end.

decode_canonical_failure_reason_wire(Blob, Wire) ->
    case decode(Wire) of
        {ok, Reasons} ->
            case encode_failure_reasons(Reasons) of
                {ok, Blob} -> {ok, Reasons};
                {ok, _Other} -> {error, bad_term};
                {error, _} = Error -> Error
            end;
        {error, bad_term} ->
            {error, bad_term}
    end.

canonical(Term) ->
    term_to_binary(Term, [deterministic]).

encode_value({'$quod_symbol', Binary})
  when is_binary(Binary) ->
    {ok, {0, Binary}};
encode_value(Atom) when is_atom(Atom) ->
    Binary = atom_to_binary(Atom, utf8),
    {ok, {0, Binary}};
encode_value(Binary) when is_binary(Binary) ->
    {ok, {1, Binary}};
encode_value(Integer) when is_integer(Integer) ->
    {ok, {2, Integer}};
encode_value(Float) when is_float(Float) ->
    {ok, {3, Float}};
encode_value(Tuple) when is_tuple(Tuple) ->
    case encode_list(tuple_to_list(Tuple), []) of
        {ok, Items} -> {ok, {4, Items}};
        error -> error
    end;
encode_value([]) ->
    {ok, {5}};
encode_value([Head | Tail]) ->
    case encode_value(Head) of
        {ok, Head1} ->
            case encode_value(Tail) of
                {ok, Tail1} -> {ok, {6, Head1, Tail1}};
                error -> error
            end;
        error -> error
    end;
encode_value(_) -> error.

encode_list([], Acc) -> {ok, lists:reverse(Acc)};
encode_list([Head | Tail], Acc) ->
    case encode_value(Head) of
        {ok, Head1} -> encode_list(Tail, [Head1 | Acc]);
        error -> error
    end.

decode_value({0, Binary})
  when is_binary(Binary) ->
    Term = try binary_to_existing_atom(Binary, utf8)
           catch error:badarg -> {'$quod_symbol', Binary}
           end,
    {ok, Term};
decode_value({1, Binary}) when is_binary(Binary) ->
    {ok, Binary};
decode_value({2, Integer}) when is_integer(Integer) ->
    {ok, Integer};
decode_value({3, Float}) when is_float(Float) ->
    {ok, Float};
decode_value({4, Items}) when is_list(Items) ->
    case decode_list(Items, []) of
        %% This tuple is the in-memory representation of an opaque symbol;
        %% its only canonical wire representation is tag 0 above.  Rejecting
        %% the tuple spelling here makes decode_canonical/2 itself enforce the
        %% same decode/encode identity that callers previously recomputed.
        {ok, ['$quod_symbol', Binary]} when is_binary(Binary) ->
            error;
        {ok, Terms} -> {ok, list_to_tuple(Terms)};
        error -> error
    end;
decode_value({5}) ->
    {ok, []};
decode_value({6, Head, Tail}) ->
    case decode_value(Head) of
        {ok, Head1} ->
            case decode_value(Tail) of
                {ok, Tail1} -> {ok, [Head1 | Tail1]};
                error -> error
            end;
        error -> error
    end;
decode_value(_) -> error.

decode_list([], Acc) -> {ok, lists:reverse(Acc)};
decode_list([Head | Tail], Acc) ->
    case decode_value(Head) of
        {ok, Head1} -> decode_list(Tail, [Head1 | Acc]);
        error -> error
    end;
decode_list(_ImproperTail, _Acc) ->
    error.

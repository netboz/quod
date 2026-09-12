-module(quod_wire_term).
-moduledoc """
Bounded, atom-safe encoding for Prolog values crossing an untrusted peer boundary.

Atoms are carried as UTF-8 binaries. Decoding reuses an existing VM atom when one is
already known; otherwise it returns the opaque `{'$quod_symbol', Binary}` value. The
opaque value re-encodes as the original atom symbol, so a relay can pass a
target-owned symbol through without allocating an atom. The authenticated
target explicitly materializes its bounded callable symbols before execution.

Only Prolog's data shapes are accepted. Node, structural-depth, and symbol-size caps
make the post-ETF validation cost deterministic. A list spine is iterative structure,
not nesting; its elements and an improper tail still increase structural depth.

Failure-reason stacks add one shared canonical contract on top of that alphabet.
Scope completion and durable abort Decisions both use the same encoder/decoder, so a
stack accepted during a proof cannot acquire different byte, count, or shape semantics
at either boundary.

`materialize_symbols/1` is the sole controlled transition from decoded opaque
symbols to VM atoms.  Callers use it only after authenticating an ontology-owned
payload; one aggregate payload gets one bounded allocation budget.
""".

-include("quod_vm_limits.hrl").
-include("quod_term_limits.hrl").
-include_lib("erlog/src/erlog_int.hrl").

-export([encode/1, decode/1,
         encode_canonical/1, decode_canonical/2,
         materialize_symbols/1, materialize_goal_symbols/1,
         normalize_answer_symbols/2,
         goal_symbol_names/1, symbol_names/1,
         is_symbol/1, callable_functor/1,
         is_ground/1,
         encode_failure_reasons/1, decode_failure_reasons/1,
         valid_failure_reason_stack/1]).

-define(MAX_NODES, 20000).
-define(MAX_SYMBOL_BYTES, 1024).

-type wire() :: term().

-doc "Whether a term is one atom symbol in materialized or opaque wire form.".
-spec is_symbol(term()) -> boolean().
is_symbol(Atom) when is_atom(Atom) -> true;
is_symbol({'$quod_symbol', Binary})
  when is_binary(Binary), byte_size(Binary) =< ?MAX_SYMBOL_BYTES -> true;
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
-spec decode_canonical(term(), non_neg_integer()) ->
          {ok, term()} | {error, bad_term | too_large}.
decode_canonical(Blob, MaxBytes)
  when is_binary(Blob), is_integer(MaxBytes), MaxBytes >= 0 ->
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

-doc "Materialize all unknown symbols in one authenticated payload under one budget.".
-spec materialize_symbols(term()) ->
          {ok, term()} |
          {error, malformed_material | too_many_new_atoms | atom_limit}.
materialize_symbols(Term) ->
    case collect_new_symbols(Term, #{}) of
        {ok, Symbols}
          when map_size(Symbols) =< ?QUOD_MAX_NEW_MATERIAL_ATOMS ->
            Names = lists:sort(maps:keys(Symbols)),
            case materialize_symbol_names(Names) of
                ok -> {ok, replace_symbols(Term)};
                {error, _} = Error -> Error
            end;
        {ok, _TooMany} ->
            {error, too_many_new_atoms};
        error ->
            {error, malformed_material}
    end.

%% Materialize only callable functors. A goal's ordinary argument values remain
%% opaque: a relay must not turn an arbitrary caller datum into a target atom.
-spec materialize_goal_symbols(term()) ->
          {ok, term()} |
          {error, malformed_material | too_many_new_atoms | atom_limit}.
materialize_goal_symbols(Goal) ->
    case collect_goal_symbols(Goal, #{}) of
        {ok, Symbols}
          when map_size(Symbols) =< ?QUOD_MAX_NEW_MATERIAL_ATOMS ->
            Names = lists:sort(maps:keys(Symbols)),
            case materialize_symbol_names(Names) of
                ok -> {ok, replace_goal_symbols(Goal)};
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
goal_symbol_names(Goal) ->
    case collect_goal_symbols(Goal, #{}) of
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
  when is_binary(Binary), byte_size(Binary) =< ?MAX_SYMBOL_BYTES ->
    {ok, Symbols#{Binary => true}};
collect_symbol_names(Atom, Symbols) when is_atom(Atom) ->
    Binary = atom_to_binary(Atom, utf8),
    case byte_size(Binary) =< ?MAX_SYMBOL_BYTES of
        true -> {ok, Symbols#{Binary => true}};
        false -> error
    end;
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
  when is_binary(Name), byte_size(Name) =< ?MAX_SYMBOL_BYTES ->
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
  when is_binary(Name), byte_size(Name) =< ?MAX_SYMBOL_BYTES ->
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

collect_goal_symbols({'$quod_symbol', Name}, Acc) when is_binary(Name) ->
    {ok, Acc#{Name => true}};
collect_goal_symbols(Tuple, _Acc)
  when is_tuple(Tuple), tuple_size(Tuple) >= 1,
       element(1, Tuple) =:= '$quod_symbol' ->
    error;
collect_goal_symbols(Tuple, Acc) when is_tuple(Tuple), tuple_size(Tuple) >= 2 ->
    case element(1, Tuple) of
        {'$quod_symbol', Name} when is_binary(Name) ->
            collect_opaque_goal_positions(Name, Tuple, Acc#{Name => true});
        Marker when is_tuple(Marker), tuple_size(Marker) >= 1,
                    element(1, Marker) =:= '$quod_symbol' -> error;
        ',' -> collect_goal_positions(Tuple, [2, 3], Acc);
        ';' -> collect_goal_positions(Tuple, [2, 3], Acc);
        '->' -> collect_goal_positions(Tuple, [2, 3], Acc);
        '\\+' -> collect_goal_positions(Tuple, [2], Acc);
        'not' -> collect_goal_positions(Tuple, [2], Acc);
        once -> collect_goal_positions(Tuple, [2], Acc);
        call -> collect_goal_positions(Tuple, [2], Acc);
        independent when tuple_size(Tuple) =:= 2 -> collect_goal_positions(Tuple, [2], Acc);
        transaction when tuple_size(Tuple) =:= 2 -> collect_goal_positions(Tuple, [2], Acc);
        findall -> collect_goal_positions(Tuple, [3], Acc);
        bagof -> collect_goal_positions(Tuple, [3], Acc);
        setof -> collect_goal_positions(Tuple, [3], Acc);
        asserta -> collect_clause_symbol(Tuple, 2, Acc);
        assertz -> collect_clause_symbol(Tuple, 2, Acc);
        retract -> collect_clause_symbol(Tuple, 2, Acc);
        retractall -> collect_clause_symbol(Tuple, 2, Acc);
        '::' -> collect_selector_symbol(Tuple, 2, Acc);
        _ -> {ok, Acc}
    end;
collect_goal_symbols(_Goal, Acc) ->
    {ok, Acc}.

%% Parser V2 deliberately keeps every source identifier opaque. Once an
%% opaque callable names one of Prolog's goal-bearing built-ins, its executable
%% positions still need the same walk as the already-materialized spelling.
%% Unknown callables keep ordinary arguments opaque.
collect_opaque_goal_positions(<<"once">>, Tuple, Acc) ->
    collect_goal_positions(Tuple, [2], Acc);
collect_opaque_goal_positions(<<"call">>, Tuple, Acc) ->
    collect_goal_positions(Tuple, [2], Acc);
collect_opaque_goal_positions(<<"independent">>, Tuple, Acc) when tuple_size(Tuple) =:= 2 ->
    collect_goal_positions(Tuple, [2], Acc);
collect_opaque_goal_positions(<<"transaction">>, Tuple, Acc) when tuple_size(Tuple) =:= 2 ->
    collect_goal_positions(Tuple, [2], Acc);
collect_opaque_goal_positions(<<"not">>, Tuple, Acc) ->
    collect_goal_positions(Tuple, [2], Acc);
collect_opaque_goal_positions(<<"findall">>, Tuple, Acc) ->
    collect_goal_positions(Tuple, [3], Acc);
collect_opaque_goal_positions(<<"bagof">>, Tuple, Acc) ->
    collect_goal_positions(Tuple, [3], Acc);
collect_opaque_goal_positions(<<"setof">>, Tuple, Acc) ->
    collect_goal_positions(Tuple, [3], Acc);
collect_opaque_goal_positions(<<"asserta">>, Tuple, Acc) ->
    collect_clause_symbol(Tuple, 2, Acc);
collect_opaque_goal_positions(<<"assertz">>, Tuple, Acc) ->
    collect_clause_symbol(Tuple, 2, Acc);
collect_opaque_goal_positions(<<"retract">>, Tuple, Acc) ->
    collect_clause_symbol(Tuple, 2, Acc);
collect_opaque_goal_positions(<<"retractall">>, Tuple, Acc) ->
    collect_clause_symbol(Tuple, 2, Acc);
collect_opaque_goal_positions(_Name, _Tuple, Acc) ->
    {ok, Acc}.

%% A clause passed to a database-update predicate contains executable syntax:
%% its head is a callable and a rule body is a goal.  Ordinary arguments of
%% that head remain opaque data, exactly like arguments of any other goal.
collect_clause_symbol(Tuple, Position, Acc)
  when Position =< tuple_size(Tuple) ->
    collect_clause_symbols(element(Position, Tuple), Acc);
collect_clause_symbol(_Tuple, _Position, _Acc) ->
    error.

collect_clause_symbols({':-', Head, Body}, Acc) ->
    case collect_goal_symbols(Head, Acc) of
        {ok, Acc1} -> collect_goal_symbols(Body, Acc1);
        error -> error
    end;
collect_clause_symbols(Clause, Acc) ->
    collect_goal_symbols(Clause, Acc).

%% The current ontology owns the route selector but not the selected
%% ontology's inner goal. Materialize only the selector here; the target will
%% perform the same goal walk after it authenticates and opens that scope.
collect_selector_symbol(Tuple, Position, Acc)
  when Position =< tuple_size(Tuple) ->
    collect_new_symbols(element(Position, Tuple), Acc);
collect_selector_symbol(_Tuple, _Position, _Acc) ->
    error.

collect_goal_positions(_Tuple, [], Acc) ->
    {ok, Acc};
collect_goal_positions(Tuple, [Position | Rest], Acc) ->
    case Position =< tuple_size(Tuple) of
        true ->
            case collect_goal_symbols(element(Position, Tuple), Acc) of
                {ok, Acc1} -> collect_goal_positions(Tuple, Rest, Acc1);
                error -> error
            end;
        false ->
            error
    end.

replace_goal_symbols({'$quod_symbol', Name}) ->
    binary_to_existing_atom(Name, utf8);
replace_goal_symbols(Tuple) when is_tuple(Tuple), tuple_size(Tuple) >= 2 ->
    case element(1, Tuple) of
        {'$quod_symbol', Name} ->
            %% Re-enter after replacing the callable so a V2 spelling such as
            %% opaque assertz(opaque_head(...)) receives the same executable-
            %% position treatment as an already-materialized assertz/1.
            replace_goal_symbols(
              setelement(1, Tuple, binary_to_existing_atom(Name, utf8)));
        ',' -> replace_goal_positions(Tuple, [2, 3]);
        ';' -> replace_goal_positions(Tuple, [2, 3]);
        '->' -> replace_goal_positions(Tuple, [2, 3]);
        '\\+' -> replace_goal_positions(Tuple, [2]);
        'not' -> replace_goal_positions(Tuple, [2]);
        once -> replace_goal_positions(Tuple, [2]);
        call -> replace_goal_positions(Tuple, [2]);
        independent when tuple_size(Tuple) =:= 2 -> replace_goal_positions(Tuple, [2]);
        transaction when tuple_size(Tuple) =:= 2 -> replace_goal_positions(Tuple, [2]);
        findall -> replace_goal_positions(Tuple, [3]);
        bagof -> replace_goal_positions(Tuple, [3]);
        setof -> replace_goal_positions(Tuple, [3]);
        asserta -> replace_clause_symbol(Tuple, 2);
        assertz -> replace_clause_symbol(Tuple, 2);
        retract -> replace_clause_symbol(Tuple, 2);
        retractall -> replace_clause_symbol(Tuple, 2);
        '::' -> replace_selector_symbol(Tuple, 2);
        _ -> Tuple
    end;
replace_goal_symbols(Goal) ->
    Goal.

replace_clause_symbol(Tuple, Position) when Position =< tuple_size(Tuple) ->
    setelement(Position, Tuple,
               replace_clause_symbols(element(Position, Tuple)));
replace_clause_symbol(Tuple, _Position) ->
    Tuple.

replace_clause_symbols({':-', Head, Body}) ->
    {':-', replace_goal_symbols(Head), replace_goal_symbols(Body)};
replace_clause_symbols(Clause) ->
    replace_goal_symbols(Clause).

replace_selector_symbol(Tuple, Position) when Position =< tuple_size(Tuple) ->
    setelement(Position, Tuple, replace_symbols(element(Position, Tuple)));
replace_selector_symbol(Tuple, _Position) ->
    Tuple.

replace_goal_positions(Tuple, Positions) ->
    lists:foldl(
      fun(Position, Acc) ->
              setelement(Position, Acc,
                         replace_goal_symbols(element(Position, Acc)))
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
    %% never traverses an application term beyond the codec's node/depth caps.
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

encode(_Term, Depth, Nodes)
  when Depth > ?QUOD_MAX_TERM_DEPTH; Nodes >= ?MAX_NODES -> error;
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

decode(_Wire, Depth, Nodes)
  when Depth > ?QUOD_MAX_TERM_DEPTH; Nodes >= ?MAX_NODES -> error;
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
        %% This tuple is the in-memory representation of an opaque symbol;
        %% its only canonical wire representation is tag 0 above.  Rejecting
        %% the tuple spelling here makes decode_canonical/2 itself enforce the
        %% same decode/encode identity that callers previously recomputed.
        {ok, ['$quod_symbol', Binary], _Nodes1} when is_binary(Binary) ->
            error;
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
    end;
decode_list(_ImproperTail, _Depth, _Nodes, _Acc) ->
    error.

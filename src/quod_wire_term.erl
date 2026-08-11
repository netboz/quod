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
-include_lib("erlog/src/erlog_int.hrl").

-export([encode/1, decode/1,
         encode_canonical/1, decode_canonical/2,
         materialize_symbols/1, materialize_goal_symbols/1,
         encode_failure_reasons/1, decode_failure_reasons/1,
         valid_failure_reason_stack/1]).

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
        {'$quod_symbol', Name} when is_binary(Name) -> {ok, Acc#{Name => true}};
        Marker when is_tuple(Marker), tuple_size(Marker) >= 1,
                    element(1, Marker) =:= '$quod_symbol' -> error;
        ',' -> collect_goal_positions(Tuple, [2, 3], Acc);
        ';' -> collect_goal_positions(Tuple, [2, 3], Acc);
        '->' -> collect_goal_positions(Tuple, [2, 3], Acc);
        '\\+' -> collect_goal_positions(Tuple, [2], Acc);
        'not' -> collect_goal_positions(Tuple, [2], Acc);
        once -> collect_goal_positions(Tuple, [2], Acc);
        call -> collect_goal_positions(Tuple, [2], Acc);
        findall -> collect_goal_positions(Tuple, [3], Acc);
        bagof -> collect_goal_positions(Tuple, [3], Acc);
        setof -> collect_goal_positions(Tuple, [3], Acc);
        _ -> {ok, Acc}
    end;
collect_goal_symbols(_Goal, Acc) ->
    {ok, Acc}.

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
            setelement(1, Tuple, binary_to_existing_atom(Name, utf8));
        ',' -> replace_goal_positions(Tuple, [2, 3]);
        ';' -> replace_goal_positions(Tuple, [2, 3]);
        '->' -> replace_goal_positions(Tuple, [2, 3]);
        '\\+' -> replace_goal_positions(Tuple, [2]);
        'not' -> replace_goal_positions(Tuple, [2]);
        once -> replace_goal_positions(Tuple, [2]);
        call -> replace_goal_positions(Tuple, [2]);
        findall -> replace_goal_positions(Tuple, [3]);
        bagof -> replace_goal_positions(Tuple, [3]);
        setof -> replace_goal_positions(Tuple, [3]);
        _ -> Tuple
    end;
replace_goal_symbols(Goal) ->
    Goal.

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
    end;
decode_list(_ImproperTail, _Depth, _Nodes, _Acc) ->
    error.

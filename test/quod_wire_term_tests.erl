-module(quod_wire_term_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

roundtrip_existing_terms_test() ->
    Term = {diet, dog, [kibble, <<"raw">>, 42, 1.5 | tail]},
    {ok, Wire} = quod_wire_term:encode(Term),
    ?assertEqual({ok, Term}, quod_wire_term:decode(Wire)).

unknown_symbol_does_not_allocate_atom_test() ->
    Symbol = <<"quod_wire_never_intern_", (integer_to_binary(
                 erlang:unique_integer([positive])))/binary>>,
    ?assertException(error, badarg, binary_to_existing_atom(Symbol, utf8)),
    ?assertEqual({ok, {'$quod_symbol', Symbol}},
                 quod_wire_term:decode({0, Symbol})),
    ?assertException(error, badarg, binary_to_existing_atom(Symbol, utf8)),
    {ok, Wire} = quod_wire_term:encode({'$quod_symbol', Symbol}),
    ?assertEqual({0, Symbol}, Wire).

answer_bytes_bind_identically_before_and_after_atom_creation_test() ->
    Name = <<"quod_wire_answer_race_", (integer_to_binary(
                 erlang:unique_integer([positive])))/binary>>,
    Wire = {4, [{0, Name}, {0, <<"ok">>}]},
    {ok, Before = {{'$quod_symbol', Name}, ok}} =
        quod_wire_term:decode(Wire),
    {Goal1, Answer1} = quod_wire_term:normalize_answer_symbols(Before, Before),
    _ = binary_to_atom(Name, utf8),
    {ok, After} = quod_wire_term:decode(Wire),
    {Goal2, Answer2} = quod_wire_term:normalize_answer_symbols(Before, After),
    ?assertEqual({Goal1, Answer1}, {Goal2, Answer2}),
    {ok, St} = erlog_int:new(erlog_db_dict, null),
    ?assertMatch({succeed, _}, erlog_int:unify(Goal1, Answer1, St#est.bs)),
    ?assertMatch({succeed, _}, erlog_int:unify(Goal2, Answer2, St#est.bs)).

variable_name_is_not_treated_as_goal_vocabulary_test() ->
    Name = <<"X">>,
    Goal = {{'$quod_symbol', Name}, {'X'}},
    Answer = {'X', {'X'}},
    ?assertEqual({Goal, Goal},
                 quod_wire_term:normalize_answer_symbols(Goal, Answer)).

opaque_spelling_wins_when_retained_goal_contains_both_test() ->
    Name = <<"quod_wire_both_spellings_", (integer_to_binary(
                 erlang:unique_integer([positive])))/binary>>,
    Opaque = {'$quod_symbol', Name},
    Atom = binary_to_atom(Name, utf8),
    Goal = {pair, {Opaque, ok}, {Atom, ok}},
    Expected = {pair, {Opaque, ok}, {Opaque, ok}},
    ?assertEqual({Expected, Expected},
                 quod_wire_term:normalize_answer_symbols(Goal, Goal)).

malformed_reserved_marker_is_not_walked_as_vocabulary_test() ->
    Malformed = {'$quod_symbol', not_binary},
    ?assertEqual({Malformed, Malformed},
                 quod_wire_term:normalize_answer_symbols(Malformed,
                                                           Malformed)).

unknown_predicate_stays_opaque_until_target_materializes_test() ->
    Symbol = <<"quod_unknown_predicate">>,
    WireGoal = {4, [{0, Symbol}, {0, <<"x">>}]},
    ?assertEqual({ok, {{'$quod_symbol', Symbol}, x}},
                 quod_wire_term:decode(WireGoal)).

malformed_reserved_symbol_markers_are_rejected_test() ->
    ?assertEqual(
       {error, malformed_material},
       quod_wire_term:materialize_symbols({'$quod_symbol', 42})),
    ?assertEqual(
       {error, malformed_material},
       quod_wire_term:materialize_goal_symbols({'$quod_symbol', 42})),
    ?assertEqual(
       {error, malformed_material},
       quod_wire_term:materialize_goal_symbols(
         {{'$quod_symbol', 42}, argument})),
    ?assertEqual(
       {error, malformed_material},
       quod_wire_term:materialize_goal_symbols({',', true})).

goal_symbol_names_is_atom_safe_and_uses_callable_positions_test() ->
    Callable = <<"new_callable">>,
    Data = <<"opaque_data">>,
    Goal = {{'$quod_symbol', Callable},
            {'$quod_symbol', Data}},
    ?assertEqual({ok, [Callable]},
                 quod_wire_term:goal_symbol_names(Goal)),
    ?assertEqual({error, malformed_material},
                 quod_wire_term:goal_symbol_names(
                   {{'$quod_symbol', not_binary}, ok})).

remote_selector_is_materialized_but_inner_goal_stays_opaque_test() ->
    Target = <<"wire_route_",
               (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Inner = <<"wire_inner_",
              (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Goal = {'::', {'$quod_symbol', Target},
            {{'$quod_symbol', Inner}, ok}},
    ?assertEqual({ok, [Target]}, quod_wire_term:goal_symbol_names(Goal)),
    {ok, {'::', TargetAtom,
          {{'$quod_symbol', Inner}, ok}}} =
        quod_wire_term:materialize_goal_symbols(Goal),
    ?assertEqual(Target, atom_to_binary(TargetAtom, utf8)),
    ?assertError(badarg, binary_to_existing_atom(Inner, utf8)).

database_update_clause_heads_are_callable_positions_test() ->
    HeadName = <<"wire_new_clause_head_",
                 (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    BodyName = <<"wire_new_clause_body_",
                 (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    OpaqueData = <<"wire_opaque_clause_data">>,
    Goal = {assertz,
            {':-', {{'$quod_symbol', HeadName},
                    {'$quod_symbol', OpaqueData}},
             {{'$quod_symbol', BodyName}, ok}}},
    ?assertEqual({ok, lists:sort([HeadName, BodyName])},
                 quod_wire_term:goal_symbol_names(Goal)),
    {ok, Materialized} = quod_wire_term:materialize_goal_symbols(Goal),
    {assertz, {':-', {HeadAtom, {'$quod_symbol', OpaqueData}},
                       {BodyAtom, ok}}} = Materialized,
    ?assertEqual(HeadName, atom_to_binary(HeadAtom, utf8)),
    ?assertEqual(BodyName, atom_to_binary(BodyAtom, utf8)).

independent_walks_owned_goals_but_not_foreign_goals_or_data_test() ->
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    Head = <<"s6_wire_owned_", Suffix/binary>>,
    Foreign = <<"s6_wire_foreign_", Suffix/binary>>,
    Data = <<"s6_wire_data_", Suffix/binary>>,
    Inner = {',', {assertz, {{'$quod_symbol', Head}, {'$quod_symbol', Data}}},
              {'::', {'$quod_symbol', <<"other">>}, {'$quod_symbol', Foreign}}},
    lists:foreach(fun(Wrapper) ->
        Goal = {Wrapper, Inner},
        {ok, Names} = quod_wire_term:goal_symbol_names(Goal),
        ?assert(lists:member(Head, Names)),
        ?assertNot(lists:member(Foreign, Names)),
        ?assertNot(lists:member(Data, Names)),
        {ok, {independent, {',', {assertz, {HeadAtom, {'$quod_symbol', Data}}},
                               {'::', other, {'$quod_symbol', Foreign}}}}} =
            quod_wire_term:materialize_goal_symbols(Goal),
        ?assertEqual(Head, atom_to_binary(HeadAtom, utf8)),
        ?assertError(badarg, binary_to_existing_atom(Foreign, utf8)),
        ?assertError(badarg, binary_to_existing_atom(Data, utf8))
    end, [independent, {'$quod_symbol', <<"independent">>}]).

independent_with_other_arity_does_not_materialize_data_test() ->
    Name = <<"s6_not_a_goal_", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Data = {'$quod_symbol', Name},
    lists:foreach(fun(Wrapper) ->
        Goal = {Wrapper, Data, other},
        {ok, Names} = quod_wire_term:goal_symbol_names(Goal),
        ?assertNot(lists:member(Name, Names)),
        ?assertEqual({ok, {independent, Data, other}},
                     quod_wire_term:materialize_goal_symbols(Goal)),
        ?assertError(badarg, binary_to_existing_atom(Name, utf8))
    end, [independent, {'$quod_symbol', <<"independent">>}]).

depth_limit_test() ->
    Deep = lists:foldl(fun(_, Acc) -> [Acc] end, ok, lists:seq(1, 70)),
    ?assertEqual({error, bad_term}, quod_wire_term:encode(Deep)).

flat_list_spine_does_not_consume_depth_test() ->
    Flat = lists:seq(1, 1000),
    {ok, Wire} = quod_wire_term:encode(Flat),
    ?assertEqual({ok, Flat}, quod_wire_term:decode(Wire)).

improper_tuple_item_list_is_rejected_test() ->
    ?assertEqual(
       {error, bad_term},
       quod_wire_term:decode({4, [{2, 1} | improper_tail]})).

real_erlog_failure_stack_roundtrips_canonically_test() ->
    {ok, St0} = erlog_int:new(erlog_db_dict, null),
    Db1 = erlog_bips:load(St0#est.db),
    {fail, St1} = erlog_int:prove_goal(
                    {fail_with_reason, {impossible_to_link, bob, tom}},
                    St0#est{db = Db1}),
    Reasons = St1#est.fail_reasons,
    ?assertEqual([{impossible_to_link, bob, tom}], Reasons),
    {ok, Blob} = quod_wire_term:encode_failure_reasons(Reasons),
    ?assert(quod_wire_term:valid_failure_reason_stack(Reasons)),
    ?assertEqual({ok, Reasons},
                 quod_wire_term:decode_failure_reasons(Blob)),
    ?assertEqual(Blob, canonical_failure_reasons(Reasons)).

quod_policy_bounds_the_real_erlog_stack_before_encoding_test() ->
    {ok, Native0} = erlog_int:new(erlog_db_dict, null),
    St0 = erlog_int:set_failure_reason_policy(
            {quod_wire_term, valid_failure_reason_stack}, Native0),
    St1 = lists:foldl(
            fun(_, St) -> erlog_int:add_failure_reason(refused, St) end,
            St0, lists:seq(1, ?ERLOG_MAX_FAILURE_REASONS + 20)),
    CountBounded = St1#est.fail_reasons,
    ?assertEqual(?ERLOG_MAX_FAILURE_REASONS, length(CountBounded)),
    ?assertEqual(fail_reasons_truncated, hd(CountBounded)),
    ?assert(quod_wire_term:valid_failure_reason_stack(CountBounded)),
    {ok, CountBlob} = quod_wire_term:encode_failure_reasons(CountBounded),
    ?assertEqual(
       {ok, CountBounded},
       quod_wire_term:decode_failure_reasons(CountBlob)),

    %% Native ETF counts this high-arity reason below 4 KiB, while the
    %% atom-safe wire form is above it. The installed policy truncates at the
    %% creation seam instead of letting scope completion or Decision reject it.
    CanonicallyLarge = list_to_tuple(lists:duplicate(1200, a)),
    ?assert(erlang:external_size(CanonicallyLarge) =<
                ?ERLOG_MAX_FAILURE_REASON_BYTES),
    St2 = erlog_int:add_failure_reason(CanonicallyLarge, St0),
    ?assertEqual([fail_reasons_truncated], St2#est.fail_reasons),
    ?assert(quod_wire_term:valid_failure_reason_stack(
              St2#est.fail_reasons)).

failure_reason_count_and_shape_bounds_are_exact_test() ->
    AtCount = lists:duplicate(?ERLOG_MAX_FAILURE_REASONS, refused),
    ?assertMatch({ok, _}, quod_wire_term:encode_failure_reasons(AtCount)),
    ?assertEqual(
       {error, too_large},
       quod_wire_term:encode_failure_reasons([refused | AtCount])),
    ?assertNot(quod_wire_term:valid_failure_reason_stack(
                 [refused | AtCount])),
    ?assertEqual(
       {error, bad_term},
       quod_wire_term:encode_failure_reasons([{'Unbound'}])),
    ?assertEqual(
       {error, bad_term},
       quod_wire_term:encode_failure_reasons([{42, not_a_functor}])),
    ?assertEqual(
       {error, bad_term},
       quod_wire_term:encode_failure_reasons([ok | improper_tail])).

failure_reason_canonical_byte_bounds_are_exact_test() ->
    AtReason = reason_binary_at_wire_size(?ERLOG_MAX_FAILURE_REASON_BYTES),
    ?assertMatch(
       {ok, _}, quod_wire_term:encode_failure_reasons([AtReason])),
    ?assertEqual(
       {error, too_large},
       quod_wire_term:encode_failure_reasons(
         [<<AtReason/binary, 0>>])),

    AtStack = failure_reason_stack_at_wire_limit(),
    {ok, AtLimitBlob} = quod_wire_term:encode_failure_reasons(AtStack),
    ?assertEqual(?ERLOG_MAX_FAILURE_REASONS_BYTES,
                 byte_size(AtLimitBlob)),
    ?assertEqual({ok, AtStack},
                 quod_wire_term:decode_failure_reasons(AtLimitBlob)),
    Prefix = lists:droplast(AtStack),
    Last = lists:last(AtStack),
    ?assertEqual(
       {error, too_large},
       quod_wire_term:encode_failure_reasons(
         Prefix ++ [<<Last/binary, 0>>])).

empty_failure_stack_is_a_canonical_scope_completion_test() ->
    {ok, Blob} = quod_wire_term:encode_failure_reasons([]),
    ?assert(quod_wire_term:valid_failure_reason_stack([])),
    ?assertEqual({ok, []}, quod_wire_term:decode_failure_reasons(Blob)).

failure_stack_decode_rejects_noncanonical_etf_test() ->
    {ok, Canonical} = quod_wire_term:encode_failure_reasons([refused]),
    <<131, 104, 3, Rest/binary>> = Canonical,
    Noncanonical = <<131, 105, 0, 0, 0, 3, Rest/binary>>,
    ?assertEqual(
       {error, bad_term},
       quod_wire_term:decode_failure_reasons(Noncanonical)).

reason_wire_size(Reason) ->
    {ok, Wire} = quod_wire_term:encode(Reason),
    byte_size(term_to_binary(Wire, [deterministic])).

reason_stack_wire_size(Reasons) ->
    byte_size(canonical_failure_reasons(Reasons)).

canonical_failure_reasons(Reasons) ->
    {ok, Wire} = quod_wire_term:encode(Reasons),
    term_to_binary(Wire, [deterministic]).

reason_binary_at_wire_size(Size) ->
    EmptySize = reason_wire_size(<<>>),
    true = Size >= EmptySize,
    Binary = binary:copy(<<"r">>, Size - EmptySize),
    Size = reason_wire_size(Binary),
    Binary.

failure_reason_stack_at_wire_limit() ->
    MaxReason = reason_binary_at_wire_size(?ERLOG_MAX_FAILURE_REASON_BYTES),
    Prefix = lists:duplicate(7, MaxReason),
    BaseSize = reason_stack_wire_size(Prefix ++ [<<>>]),
    Growth = ?ERLOG_MAX_FAILURE_REASONS_BYTES - BaseSize,
    true = Growth >= 0,
    Last = binary:copy(<<"s">>, Growth),
    true = reason_wire_size(Last) =< ?ERLOG_MAX_FAILURE_REASON_BYTES,
    Reasons = Prefix ++ [Last],
    ?ERLOG_MAX_FAILURE_REASONS_BYTES = reason_stack_wire_size(Reasons),
    Reasons.

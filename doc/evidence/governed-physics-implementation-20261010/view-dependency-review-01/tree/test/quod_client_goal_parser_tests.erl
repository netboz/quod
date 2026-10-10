-module(quod_client_goal_parser_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_client_goal_limits.hrl").

source_formatter_request_spelling_is_stable_test() ->
    %% Existing prepared operations can bind these exact bytes, independently
    %% of the more readable formatting used for result values.
    ?assertEqual({ok, <<"'\\x61\\'(<<\"\\x0\\\\x41\\\">>).">>},
                 quod_client_goal_parser:format({a, <<0, 65>>})).

program_clause_boundaries_and_variable_scopes_test() ->
    Source = <<"% initial comment\np(X, _, X, _). /* . */\n"
               "p(Y, <<\"a.b\">>, 'quoted.dot', 1.25) :- q(Y), !.\n"
               "q([X|Xs]) :- (X = a -> q(Xs); true). % tail">>,
    {ok, [One, Two, Three]} = quod_client_goal_parser:parse_program(Source, 2),
    ?assertEqual(canonical({p, {0}, {1}, {0}, {2}}), canonical(maps:get(goal, One))),
    ?assertEqual([{<<"X">>, 0}], maps:get(variables, One)),
    ?assertEqual([{<<"Y">>, 0}], maps:get(variables, Two)),
    ?assertEqual([{<<"X">>, 0}, {<<"Xs">>, 1}], maps:get(variables, Three)),
    ?assertEqual({ok, []}, quod_client_goal_parser:parse_program(<<"/* empty */">>, 2)),
    ?assertEqual({error, invalid_syntax}, quod_client_goal_parser:parse(Source, 2)),
    lists:foreach(fun(Bad) ->
        ?assertEqual({error, invalid_syntax}, quod_client_goal_parser:parse_program(Bad, 2))
    end, [<<"p. q">>, <<"p. /* unfinished">>, <<"p.q.">>, <<"p([a).">>]),
    ?assertEqual({error, unsupported_parser},
                 quod_client_goal_parser:parse_program(<<>>, 4)).

readable_clause_formatter_preserves_program_semantics_test() ->
    Terms = [{':-', {choose, {0}},
              {',', {';', {'->', {test, {0}}, {accept, {0}}}, fail}, '!'}},
             {':-', {arith, {0}}, {is, {0}, {'*', {'+', 1, 2}, {'-', 3, 4}}}},
             {':-', {path, [{0} | {1}]}, {'::', {':', a, b}, {call, {1}}}},
             {payload, <<0, 255, 34, 92>>, 'has spaces', {'$quod_symbol', <<"novel">>}},
             {':-', {negation, {0}}, {'\\+', {';', {check, {0}}, fallback}}}],
    lists:foreach(fun(Clause) ->
        {ok, Source} = quod_client_goal_parser:format_clause(Clause),
        {ok, [#{goal := Parsed}]} = quod_client_goal_parser:parse_program(Source, 2),
        ?assertEqual(canonical(Clause), canonical(Parsed))
    end, Terms),
    ?assertEqual({ok, <<"p(V0) :- q(V0) , !.">>},
        quod_client_goal_parser:format_clause({':-', {p, {0}}, {',', {q, {0}}, '!'}})),
    ?assertEqual({ok, <<"payload((-3)).">>}, quod_client_goal_parser:format_clause({payload, -3})).

source_formatter_preserves_terms_and_byte_values_test() ->
    Terms = [{agent_instance_ref, <<"agents">>, <<1:256>>, {worker, 'quoted name'}},
             {'::', <<"target">>, {',', {sign, <<0, 255, 34, 92>>, {0}}, {check, {0}}}},
             {payload, [a, b | tail], {'-', 3}, 1.25, {'$quod_symbol', <<"unknown_symbol">>}}],
    lists:foreach(fun(Term) ->
        {ok, Text} = quod_client_goal_parser:format(Term),
        {ok, #{goal := Parsed}} = quod_client_goal_parser:parse(Text, 2),
        ?assertEqual(canonical(Term), canonical(Parsed))
    end, Terms),
    ?assertEqual({error, invalid_term}, quod_client_goal_parser:format(self())),
    ?assertMatch({ok, _}, quod_client_goal_parser:format({payload, -3})).

basic_goal_and_variable_numbering_test() ->
    {ok, #{goal := Goal, variables := Variables}} =
        parse(<<"pair(X, _, X, _Tail, _Tail, _).">>),
    ?assertEqual(
       canonical({pair, {0}, {1}, {0}, {2}, {2}, {3}}),
       canonical(Goal)),
    ?assertEqual([{<<"X">>, 0}, {<<"_Tail">>, 2}], Variables).

operator_precedence_is_frozen_test() ->
    {ok, #{goal := Arithmetic}} = parse(<<"X is 1 + 2 * 3 ^ 4.">>),
    ?assertEqual(
       canonical({is, {0}, {'+', 1, {'*', 2, {'^', 3, 4}}}}),
       canonical(Arithmetic)),
    {ok, #{goal := CrossOntology}} = parse(<<"a:b::c:d.">>),
    ?assertEqual(canonical({'::', {':', a, b}, {':', c, d}}),
                 canonical(CrossOntology)),
    {ok, #{goal := Control}} = parse(<<"a, b -> c ; d.">>),
    ?assertEqual(canonical({';', {'->', {',', a, b}, c}, d}),
                 canonical(Control)).

every_v1_operator_has_an_exact_parse_fixture_test() ->
    Prefix =
        [{<<"?- a.">>, {'?-', a}},
         {<<":- a.">>, {':-', a}},
         {<<"\\+ a.">>, {'\\+', a}},
         {<<"+ a.">>, {'+', a}},
         {<<"- a.">>, {'-', a}},
         {<<"\\ a.">>, {'\\', a}}],
    Postfix =
        [{<<"a + .">>, {'+', a}},
         {<<"a * .">>, {'*', a}}],
    Infix =
        [{<<"a :- b.">>, {':-', a, b}},
         {<<"a --> b.">>, {'-->', a, b}},
         {<<"a ; b.">>, {';', a, b}},
         {<<"a -> b.">>, {'->', a, b}},
         {<<"a = b.">>, {'=', a, b}},
         {<<"a \\= b.">>, {'\\=', a, b}},
         {<<"a \\== b.">>, {'\\==', a, b}},
         {<<"a == b.">>, {'==', a, b}},
         {<<"a @< b.">>, {'@<', a, b}},
         {<<"a @=< b.">>, {'@=<', a, b}},
         {<<"a @> b.">>, {'@>', a, b}},
         {<<"a @>= b.">>, {'@>=', a, b}},
         {<<"a =.. b.">>, {'=..', a, b}},
         {<<"a is b.">>, {'is', a, b}},
         {<<"a =:= b.">>, {'=:=', a, b}},
         {<<"a =\\= b.">>, {'=\\=', a, b}},
         {<<"a < b.">>, {'<', a, b}},
         {<<"a =< b.">>, {'=<', a, b}},
         {<<"a > b.">>, {'>', a, b}},
         {<<"a >= b.">>, {'>=', a, b}},
         {<<"a : b.">>, {':', a, b}},
         {<<"a :: b.">>, {'::', a, b}},
         {<<"a + b.">>, {'+', a, b}},
         {<<"a - b.">>, {'-', a, b}},
         {<<"a /\\ b.">>, {'/\\', a, b}},
         {<<"a \\/ b.">>, {'\\/', a, b}},
         {<<"a * b.">>, {'*', a, b}},
         {<<"a / b.">>, {'/', a, b}},
         {<<"a // b.">>, {'//', a, b}},
         {<<"a rem b.">>, {'rem', a, b}},
         {<<"a mod b.">>, {'mod', a, b}},
         {<<"a << b.">>, {'<<', a, b}},
         {<<"a >> b.">>, {'>>', a, b}},
         {<<"a ** b.">>, {'**', a, b}},
         {<<"a ^ b.">>, {'^', a, b}}],
    lists:foreach(
      fun({Text, Expected}) ->
              {ok, #{goal := Goal}} = parse(Text),
              ?assertEqual(canonical(Expected), canonical(Goal))
      end, Prefix ++ Postfix ++ Infix).

existing_non_operator_atoms_still_parse_opaquely_test() ->
    %% VM atom history must not change a validator's parsed term.
    ?assert(is_atom(true)),
    {ok, #{goal := Goal}} = parse(<<"true.">>),
    ?assertEqual({'$quod_symbol', <<"true">>}, Goal).

leading_parentheses_are_part_of_the_frozen_grammar_test() ->
    {ok, #{goal := Conjunction}} = parse(<<"(a , b).">>),
    ?assertEqual(canonical({',', a, b}), canonical(Conjunction)),
    {ok, #{goal := Atom}} = parse(<<"( a ).">>),
    ?assertEqual(canonical(a), canonical(Atom)).

negative_number_spacing_is_prefix_syntax_test() ->
    {ok, #{goal := Tight}} = parse(<<"f(-1).">>),
    {ok, #{goal := Spaced}} = parse(<<"f(- 1).">>),
    ?assertEqual(canonical({f, {'-', 1}}), canonical(Tight)),
    ?assertEqual(canonical(Tight), canonical(Spaced)).

v3_numeric_literals_preserve_subtraction_and_old_signed_meanings_test() ->
    Cases = [{<<"p(-3).">>, {p, -3}},
             {<<"p(- 3).">>, {p, {'-', 3}}},
             {<<"p(-(3)).">>, {p, {'-', 3}}},
             {<<"p('-'(3)).">>, {p, {'-', 3}}},
             {<<"p(- -3).">>, {p, {'-', -3}}},
             {<<"p(X-3).">>, {p, {'-', {0}, 3}}},
             {<<"p(-3 ** 2).">>, {p, {'-', {'**', 3, 2}}}},
             {<<"p((-3) ** 2).">>, {p, {'**', -3, 2}}},
             {<<"p(-0x2a,-0b11,-0'a).">>, {p, -42, -3, -97}},
             {<<"p(-3.5,1.0e-3).">>, {p, -3.5, 0.001}},
             {<<"p(- /* gap */ 3, '-3', <<\"-3\">>).">>,
              {p, {'-', 3}, '-3', <<"-3">>}},
             {<<"p('$quod_lexical_magnitude'(3)).">>,
              {p, {'$quod_lexical_magnitude', 3}}}],
    lists:foreach(fun({Text, Expected}) ->
        {ok, #{goal := Parsed}} = quod_client_goal_parser:parse(Text, 3),
        ?assertEqual(canonical(Expected), canonical(Parsed))
    end, Cases),
    lists:foreach(fun(Version) ->
        {ok, #{goal := Old}} = quod_client_goal_parser:parse(<<"p(-3).">>, Version),
        ?assertEqual(canonical({p, {'-', 3}}), canonical(Old))
    end, [1, 2]).

negative_numeric_code_roundtrips_exactly_test() ->
    Terms = [{p, -3, -3.5, -0.0, 0.0},
             {p, [1, -2 | -3]}, {p, {'-', -3}},
             {':-', {p, -2}, {is, {0}, {'**', -3, 2}}}],
    lists:foreach(fun(Term) ->
        lists:foreach(fun(Formatter) ->
            {ok, Text} = Formatter(Term),
            {ok, #{goal := Parsed}} = quod_client_goal_parser:parse(Text, 3),
            %% Canonical bytes distinguish negative zero, unlike numeric equality.
            ?assertEqual(canonical(Term), canonical(Parsed))
        end, [fun quod_client_goal_parser:format/1,
              fun quod_client_goal_parser:format_clause/1])
    end, Terms).

numbers_strings_quoted_atoms_and_lists_test() ->
    Text = <<"values(12, 1.25e+2, 0b101, 0o17, 0x2a, "
             "0'\\n, 'quoted atom', \"a\\tb\", [one,two|Tail]).">>,
    {ok, #{goal := Goal, variables := [{<<"Tail">>, 0}]}} = parse(Text),
    Expected = {values, 12, 125.0, 5, 15, 42, $\n, 'quoted atom',
                "a\tb", [one, two | {0}]},
    ?assertEqual(canonical(Expected), canonical(Goal)).

numeric_and_generic_escape_contract_test() ->
    {ok, #{goal := Goal}} =
        parse(<<"escapes('A\\x42\\\\101\\n', "
                "\"\\x43\\\\104\\\\n\", 0'\\x45\\).">>),
    ?assertEqual(canonical({escapes, 'ABAn', "CD\n", $E}), canonical(Goal)).

unknown_escapes_and_invalid_codepoints_are_rejected_test() ->
    ?assertEqual({error, invalid_syntax}, parse(<<"f(\"\\q\").">>)),
    ?assertEqual({error, invalid_syntax},
                 parse(<<"f(\"\\x110000\\\").">>)),
    ?assertEqual({error, invalid_syntax},
                 parse(<<"f('\\x110000\\').">>)).

iso_quote_doubling_is_deliberately_not_v1_syntax_test() ->
    ?assertEqual({error, invalid_syntax}, parse(<<"'don''t'.">>)),
    ?assertEqual({error, invalid_syntax},
                 parse(<<"\"say \"\"hi\"\"\".">>)).

comments_are_layout_and_function_call_spacing_is_preserved_test() ->
    {ok, #{goal := Goal}} =
        parse(<<"% heading\nouter(/* gap */ inner(ok)). % tail">>),
    ?assertEqual(canonical({outer, {inner, ok}}), canonical(Goal)),
    %% As in Prolog, layout between a functor and `(` is not a compound call.
    ?assertEqual({error, invalid_syntax}, parse(<<"outer (ok).">>)).

one_dot_terminated_term_only_test() ->
    ?assertEqual({error, invalid_syntax}, parse(<<"true">>)),
    ?assertEqual({error, invalid_syntax}, parse(<<"true. false.">>)),
    ?assertEqual({error, invalid_syntax}, parse(<<"/* unfinished">>)),
    ?assertEqual({error, invalid_syntax}, parse(<<"f([a,b).">>)),
    ?assertEqual({error, invalid_syntax}, parse(<<"1.0e+.">>)),
    ?assertEqual({error, unsupported_parser},
                 quod_client_goal_parser:parse(<<"true.">>, 4)).

v2_binary_literals_use_erlang_notation_without_changing_v1_test() ->
    Literal = <<"payload(<<\"a\\n\">>).">>,
    ?assertEqual({error, invalid_syntax},
                 quod_client_goal_parser:parse(Literal, 1)),
    {ok, #{goal := Goal}} = quod_client_goal_parser:parse(Literal, 2),
    ?assertEqual(canonical({payload, <<"a\n">>}), canonical(Goal)),
    ?assertEqual({error, invalid_syntax},
                 quod_client_goal_parser:parse(
                   <<"payload(<<\"\\x100\\\">>).">>, 2)),
    Shift = <<"X is X << 2.">>,
    {ok, #{goal := V1Shift}} = quod_client_goal_parser:parse(Shift, 1),
    {ok, #{goal := V2Shift}} = quod_client_goal_parser:parse(Shift, 2),
    ?assertEqual(canonical({is, {0}, {'<<', {0}, 2}}), canonical(V1Shift)),
    ?assertEqual(canonical(V1Shift), canonical(V2Shift)),
    %% V2 deliberately reserves a contiguous <<" sequence.  V1 retains its
    %% prior shift/string reading, and requests bind the version byte.
    Collision = <<"X<<\"a\">>Y.">>,
    ?assertMatch({ok, _}, quod_client_goal_parser:parse(Collision, 1)),
    ?assertEqual({error, invalid_syntax},
                 quod_client_goal_parser:parse(Collision, 2)),
    ?assertEqual({error, invalid_syntax},
                 quod_client_goal_parser:parse(<<"payload(<<\"abc).">>, 2)),
    ?assertEqual({error, invalid_syntax},
                 quod_client_goal_parser:parse(<<"payload(<<\"x\" >>).">>, 2)).

unknown_symbols_do_not_allocate_atoms_test() ->
    %% Warm every called module before taking the VM count.
    {ok, _} = parse(<<"true.">>),
    Prefix = integer_to_binary(erlang:unique_integer([positive])),
    Name = <<"signed_goal_unknown_", Prefix/binary>>,
    Text = <<Name/binary, "(", Name/binary, ").">>,
    Before = erlang:system_info(atom_count),
    {ok, #{goal := Goal}} = parse(Text),
    After = erlang:system_info(atom_count),
    ?assertEqual(Before, After),
    ?assertMatch({{'$quod_symbol', Name}, {'$quod_symbol', Name}}, Goal).

unknown_callable_symbol_budget_is_enforced_test() ->
    Prefix = integer_to_binary(erlang:unique_integer([positive])),
    Calls = [iolist_to_binary(
               ["unknown_callable_", Prefix, "_", integer_to_binary(N), "(1)"])
             || N <- lists:seq(1, 65)],
    Text = iolist_to_binary([lists:join(<<",">>, Calls), <<".">>]),
    Before = erlang:system_info(atom_count),
    ?assertEqual({error, {too_large, goal}}, parse(Text)),
    ?assertEqual(Before, erlang:system_info(atom_count)).

goal_text_and_token_bounds_are_enforced_test() ->
    Exact = iolist_to_binary(
              [lists:duplicate(?QUOD_CLIENT_GOAL_TEXT_BYTES - 5, " "),
               "true."]),
    ?assertMatch({ok, _}, parse(Exact)),
    ?assertEqual(
       {error, {too_large, goal}},
       quod_client_goal_parser:parse(
         <<0:(?QUOD_CLIENT_GOAL_TEXT_BYTES + 1)/unit:8>>, 1)),
    Many = iolist_to_binary(
             [lists:duplicate(?QUOD_CLIENT_GOAL_MAX_TOKENS + 1, "1,"),
              "1."]),
    ?assertEqual({error, {too_large, goal}}, parse(Many)).

parser_is_total_on_hostile_bytes_and_truncations_test() ->
    _ = rand:seed(exsplus, {17, 29, 43}),
    Random =
        [list_to_binary([rand:uniform(256) - 1 ||
                           _ <- lists:seq(1, Length)])
         || Length <- [N rem 97 || N <- lists:seq(0, 255)]],
    Valid = <<"outer([1,2|Tail], 'quoted', \"utf8 ",
              16#e2, 16#98, 16#83, "\").">>,
    Truncations =
        [binary:part(Valid, 0, N)
         || N <- lists:seq(0, byte_size(Valid))],
    lists:foreach(fun assert_parse_total/1, Random ++ Truncations).

parse(Text) -> quod_client_goal_parser:parse(Text, 1).

canonical(Term) ->
    {ok, Bytes} = quod_durable_term:encode_goal(Term),
    Bytes.

assert_parse_total(Text) ->
    case catch parse(Text) of
        {ok, _} -> ok;
        {error, _} -> ok;
        {'EXIT', Reason} -> erlang:error({parser_crashed, Text, Reason});
        Other -> erlang:error({invalid_parser_result, Text, Other})
    end.

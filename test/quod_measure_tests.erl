-module(quod_measure_tests).

%% The `quod:measure` ontology (priv/ontologies/quod_measure.pl): what a unit
%% measures, exact conversion between commensurable units, a sum that refuses to
%% cross dimensions, prefixes parsed rather than enumerated, and the class view
%% derived from the relations. No result anywhere is a floating point number.

-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_vm_limits.hrl").

signature_test() ->
    with_measure(fun(St) ->
        Sig = fun(U) -> value({'S'}, {signature, U, {'S'}}, St) end,
        ?assertEqual([{d, <<"length">>, 1}], Sig(<<"m">>)),
        ?assertEqual([{d, <<"length">>, 1}], Sig(<<"ft">>)),
        ?assertEqual([{d, <<"length">>, 2}], Sig(<<"acre">>)),
        ?assertEqual([{d, <<"length">>, 3}], Sig(<<"cup">>)),
        ?assertEqual([{d, <<"time">>, -1}], Sig(<<"Hz">>)),
        ?assertEqual([{d, <<"length">>, 1}, {d, <<"time">>, -1}], Sig(<<"kn">>)),
        %% canonical order is dimension/1's order, not the order they were written
        ?assertEqual([{d, <<"length">>, 2}, {d, <<"mass">>, 1}, {d, <<"time">>, -2}],
                     Sig(<<"J">>)),
        %% the same thing measured two ways
        holds({commensurable, <<"J">>, <<"Wh">>}, St),
        holds({commensurable, <<"J">>, <<"cal">>}, St),
        holds({commensurable, <<"kn">>, <<"mph">>}, St),
        holds({commensurable, <<"L">>, <<"gal">>}, St),
        fails({commensurable, <<"m">>, <<"s">>}, St),
        fails({commensurable, <<"m">>, <<"acre">>}, St),
        fails({commensurable, <<"J">>, <<"W">>}, St)
    end).

exact_conversion_test() ->
    with_measure(fun(St) ->
        C = fun(V, From, To) -> value({'O'}, {convert, V, From, To, {'O'}}, St) end,
        %% whole answers stay whole
        ?assertEqual(12, C(1, <<"ft">>, <<"in">>)),
        ?assertEqual(3600, C(1, <<"h">>, <<"s">>)),
        ?assertEqual(5000, C(5, <<"km">>, <<"m">>)),
        ?assertEqual(1048576, C(1, <<"MiB">>, <<"B">>)),
        ?assertEqual(3600, C(1, <<"Wh">>, <<"J">>)),
        ?assertEqual(1852, C(1, <<"nmi">>, <<"m">>)),
        %% and the rest are exact rationals in lowest terms, never floats
        ?assertEqual({'/', 25146, 15625}, C(1, <<"mi">>, <<"km">>)),
        ?assertEqual({'/', 127, 5000}, C(1, <<"in">>, <<"m">>)),
        ?assertEqual({'/', 523, 125}, C(1, <<"cal">>, <<"J">>)),
        %% a rational going in comes back reduced
        ?assertEqual(6, C({'/', 1, 2}, <<"ft">>, <<"in">>)),
        ?assertEqual(900, C({'/', 1, 4}, <<"h">>, <<"s">>)),
        %% round trips land exactly back where they started
        ?assertEqual(1, C(C(1, <<"mi">>, <<"km">>), <<"km">>, <<"mi">>)),
        ?assertEqual(7, C(C(7, <<"cal">>, <<"eV">>), <<"eV">>, <<"cal">>)),
        %% and nothing converts across dimensions
        fails({convert, 1, <<"m">>, <<"s">>, {'O'}}, St),
        fails({convert, 1, <<"J">>, <<"W">>, {'O'}}, St)
    end).

prefixes_are_parsed_not_listed_test() ->
    with_measure(fun(St) ->
        C = fun(V, From, To) -> value({'O'}, {convert, V, From, To, {'O'}}, St) end,
        %% no fact defines any of these; the prefix composes with the unit
        ?assertEqual(1000, C(1, <<"km">>, <<"m">>)),
        ?assertEqual(100, C(1, <<"m">>, <<"cm">>)),
        ?assertEqual(1000000, C(1, <<"s">>, <<"us">>)),
        ?assertEqual(1000, C(1, <<"kJ">>, <<"J">>)),
        ?assertEqual(8000000, C(1, <<"MB">>, <<"bit">>)),
        ?assertEqual(1000, C(1, <<"kN">>, <<"N">>)),
        %% a prefixed unit is commensurable with its base, and the binary and
        %% decimal sizes differ by exactly the amount they should
        holds({commensurable, <<"km">>, <<"mi">>}, St),
        ?assertEqual({'/', 131072, 125}, C(1, <<"MiB">>, <<"kB">>)),
        %% an unknown symbol has no answer rather than a wrong one
        fails({convert, 1, <<"zz">>, <<"m">>, {'O'}}, St),
        fails({convert, 1, <<"kzz">>, <<"m">>, {'O'}}, St)
    end).

sum_refuses_to_cross_dimensions_test() ->
    with_measure(fun(St) ->
        S = fun(Qs, U) -> value({'T'}, {sum, Qs, U, {'T'}}, St) end,
        ?assertEqual(1500, S([{q, 1, <<"km">>}, {q, 500, <<"m">>}], <<"m">>)),
        ?assertEqual(63, S([{q, 1, <<"yd">>}, {q, 27, <<"in">>}], <<"in">>)),
        ?assertEqual(0, S([], <<"m">>)),
        %% one quantity of another dimension and there is no total at all
        fails({sum, [{q, 1, <<"m">>}, {q, 1, <<"s">>}], <<"m">>, {'T'}}, St),
        fails({sum, [{q, 1, <<"J">>}, {q, 1, <<"W">>}], <<"J">>, {'T'}}, St)
    end).

%% The house vocabulary is a view over the relations, so a generic caller can
%% enumerate what is here without knowing unit/5, and neither copy can drift.
class_view_test() ->
    with_measure(fun(St) ->
        holds({isa, unit, thing}, St),
        holds({instance_of, unit, <<"m">>}, St),
        holds({instance_of, dimension, <<"length">>}, St),
        fails({instance_of, unit, <<"length">>}, St),
        ?assertEqual({'/', 1143, 3750}, value({'R'}, {attribute, <<"ft">>, ratio, {'R'}}, St)),
        ?assertEqual([{d, <<"length">>, 1}],
                     value({'S'}, {attribute, <<"ft">>, signature, {'S'}}, St)),
        Units = solutions({'U'}, {instance_of, unit, {'U'}}, St),
        ?assertEqual(length(Units), length(lists:usort(Units))),
        ?assert(length(Units) > 50),
        ?assert(lists:all(fun is_binary/1, Units))
    end).

policy_test() ->
    with_committed_measure(<<"peer_admitted(k, h, p, k).">>, fun(_C, St) ->
        lists:foreach(fun(Goal) -> holds({can_invoke, Goal, anyone, [], ns}, St) end,
                      [{convert, 1, <<"m">>, <<"cm">>, {'O'}},
                       {commensurable, <<"m">>, <<"ft">>},
                       {instance_of, unit, {'U'}},
                       {attribute, <<"m">>, ratio, {'R'}}]),
        fails({can_invoke, {assertz, {unit, <<"zz">>, [], [], 1, 1}}, anyone, [], ns}, St),
        holds({can_invoke, {assertz, {unit, <<"zz">>, [], [], 1, 1}}, {node, k}, [], ns}, St)
    end).

vocabulary_fits_the_genesis_budget_test() ->
    Terms = quod_committed_projection:read_terms(source()),
    New = quod_wire_term:cold_new_symbols(Terms),
    ?assert(length(New) =< ?QUOD_MAX_NEW_MATERIAL_ATOMS - 10, {New, length(New)}),
    %% no float reaches the committed content
    ?assertNot(lists:any(fun has_float/1, Terms)).

has_float(T) when is_float(T) -> true;
has_float([Head | Tail]) -> has_float(Head) orelse has_float(Tail);
has_float(T) when is_tuple(T) -> lists:any(fun has_float/1, tuple_to_list(T));
has_float(_) -> false.

%% --- helpers ---------------------------------------------------------------

source() -> filename:join(code:priv_dir(quod), "ontologies/quod_measure.pl").

holds(Goal, St) -> ?assertMatch({succeed, _}, erlog_int:prove_goal(Goal, St)).
fails(Goal, St) -> ?assertMatch({fail, _}, erlog_int:prove_goal(Goal, St)).

value(Var, Goal, St) ->
    {succeed, Final} = erlog_int:prove_goal(Goal, St),
    erlog_int:dderef(Var, Final#est.bs).

solutions(Template, Goal, St) ->
    value({'L'}, {findall, Template, Goal, {'L'}}, St).

with_measure(Fun) ->
    with_committed_measure(<<>>, fun(_Committed, St) -> Fun(St) end).

with_committed_measure(Extra, Fun) ->
    Base = quod_committed_projection:new_est(),
    Loaded = load_terms(quod_committed_projection:read_terms(source()), Base),
    Committed = quod_ct:commit_kb(load_source(Extra, Loaded)),
    St = quod_erlog_db_local_prove:wrap_state(Committed, #{read_set => true}),
    try Fun(Committed, St)
    after
        #est{db = #db{ref = Ref}} = Committed,
        quod_erlog_db_mvcc:delete(Ref)
    end.

load_source(<<>>, St) -> St;
load_source(Source, St) ->
    {ok, Terms} = erlog_io:read_string_terms(unicode:characters_to_list(Source)),
    load_terms(Terms, St).

load_terms(Terms, #est{db = Db0} = St) ->
    St#est{db = lists:foldl(fun erlog_int:assertz_clause/2, Db0, Terms)}.

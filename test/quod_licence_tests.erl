-module(quod_licence_tests).

%% The `quod:licence` ontology (priv/ontologies/quod_licence.pl) on the base
%% engine every ontology starts from: what may include what, which licence a
%% combination may be released under, why a combination has none, and the
%% obligations it inherits. Licence ids, families and obligations are binaries;
%% the source must stay within the genesis vocabulary budget a cold node admits.

-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_vm_limits.hrl").

-define(NS, <<"quod:licence">>).

may_include_test() ->
    with_licences(fun(St) ->
        %% a part with no copyleft goes anywhere it is not refused
        holds({may_include, <<"GPL-3.0-only">>, <<"MIT">>}, St),
        holds({may_include, <<"Proprietary">>, <<"Apache-2.0">>}, St),
        holds({may_include, <<"MIT">>, <<"ISC">>}, St),
        %% copyleft does not travel outwards
        fails({may_include, <<"MIT">>, <<"GPL-3.0-only">>}, St),
        %% copyleft that stops at the file or the library leaves the work alone
        holds({may_include, <<"Apache-2.0">>, <<"MPL-2.0">>}, St),
        holds({may_include, <<"Proprietary">>, <<"LGPL-3.0-only">>}, St),
        holds({may_include, <<"MIT">>, <<"OGL-1.0a">>}, St),
        %% within a family, same strength or stronger
        holds({may_include, <<"GPL-3.0-only">>, <<"GPL-3.0-only">>}, St),
        holds({may_include, <<"AGPL-3.0-only">>, <<"GPL-3.0-only">>}, St),
        fails({may_include, <<"GPL-3.0-only">>, <<"AGPL-3.0-only">>}, St),
        %% allowances across families are deliberate, not derived
        fails({may_include, <<"MPL-2.0">>, <<"GPL-3.0-only">>}, St),
        %% a refusal beats the no-copyleft rule
        fails({may_include, <<"GPL-2.0-only">>, <<"Apache-2.0">>}, St),
        %% and the two GPL majors never meet, in either direction
        fails({may_include, <<"GPL-3.0-only">>, <<"GPL-2.0-only">>}, St),
        fails({may_include, <<"GPL-2.0-only">>, <<"GPL-3.0-only">>}, St),
        fails({may_include, <<"MIT">>, <<"CC-BY-NC-4.0">>}, St)
    end).

effective_test() ->
    with_licences(fun(St) ->
        Under = fun(Ls) -> solutions({'U'}, {effective, Ls, {'U'}}, St) end,
        Permissive = Under([<<"MIT">>, <<"ISC">>]),
        ?assert(lists:member(<<"MIT">>, Permissive)),
        ?assert(lists:member(<<"GPL-3.0-only">>, Permissive)),
        ?assert(lists:member(<<"Proprietary">>, Permissive)),
        %% one copyleft part rules out every permissive release
        WithGpl = Under([<<"MIT">>, <<"GPL-3.0-only">>]),
        ?assertEqual([<<"GPL-3.0-only">>, <<"AGPL-3.0-only">>], WithGpl),
        %% and a pair that no licence carries has no answer at all
        ?assertEqual([], Under([<<"GPL-2.0-only">>, <<"Apache-2.0">>])),
        ?assertEqual([], Under([<<"GPL-3.0-only">>, <<"CC-BY-NC-4.0">>]))
    end).

blocks_names_the_pair_and_the_reason_test() ->
    with_licences(fun(St) ->
        %% the pair comes back in standard order, once, never twice
        ?assertEqual([{<<"Apache-2.0">>, <<"GPL-2.0-only">>,
                       <<"Apache-2.0 adds patent terms GPL-2.0 treats as a further restriction">>}],
                     blocking([<<"GPL-2.0-only">>, <<"Apache-2.0">>], St)),
        %% a combination with no stated reason still names the pair
        ?assertEqual([{<<"AGPL-3.0-only">>, <<"CC-BY-SA-4.0">>,
                       <<"neither may include the other">>}],
                     blocking([<<"AGPL-3.0-only">>, <<"CC-BY-SA-4.0">>], St)),
        %% nothing blocks a combination that works
        ?assertEqual([], blocking([<<"MIT">>, <<"GPL-3.0-only">>], St))
    end).

obligations_test() ->
    with_licences(fun(St) ->
        Carry = fun(Ls) -> solutions({'W'}, {must_carry, Ls, {'_'}, {'W'}}, St) end,
        ?assertEqual([<<"keep the copyright notice and licence text">>],
                     Carry([<<"MIT">>])),
        Apache = Carry([<<"Apache-2.0">>]),
        ?assertEqual(3, length(Apache)),
        ?assert(lists:member(<<"state the changes you made">>, Apache)),
        ?assert(lists:member(<<"carry the section 15 copyright notice">>,
                             Carry([<<"MIT">>, <<"OGL-1.0a">>]))),
        %% the obligation is reported with the licence that imposes it
        ?assertEqual([<<"AGPL-3.0-only">>],
                     solutions({'L'},
                               {must_carry, [<<"MIT">>, <<"AGPL-3.0-only">>], {'L'},
                                <<"offer the source to anyone using it over a network">>}, St))
    end).

a_work_and_its_notice_test() ->
    Parts = <<"component(<<\"demo\">>, <<\"cowboy\">>, <<\"ISC\">>).\n"
              "component(<<\"demo\">>, <<\"erlog\">>, <<\"Apache-2.0\">>).\n"
              "component(<<\"demo\">>, <<\"tables\">>, <<\"OGL-1.0a\">>).\n">>,
    with_committed_licences(Parts, fun(_Committed, St) ->
        Under = solutions({'U'}, {ships, <<"demo">>, {'U'}}, St),
        ?assert(lists:member(<<"Apache-2.0">>, Under)),
        ?assert(lists:member(<<"GPL-3.0-only">>, Under)),
        %% the OGL files stay under the OGL; the work itself may be anything
        ?assert(lists:member(<<"MIT">>, Under)),
        %% every notice line names the part, its licence and what it asks
        Lines = solutions({'-', {'P'}, {'W'}},
                          {notice, <<"demo">>, {'P'}, {'_'}, {'W'}}, St),
        ?assert(lists:member({'-', <<"tables">>, <<"carry the section 15 copyright notice">>},
                             Lines)),
        ?assert(lists:member({'-', <<"erlog">>, <<"state the changes you made">>}, Lines)),
        ?assertEqual(6, length(Lines))
    end).

%% The class view is a projection of the relations, not a second copy: a
%% family is a class of licences, every licence is an instance of the family it
%% names, and its attributes come straight from licence/3 and obligation/2.
class_view_test() ->
    with_licences(fun(St) ->
        holds({isa, licence, thing}, St),
        holds({isa, <<"gpl">>, licence}, St),
        fails({isa, <<"not-a-family">>, licence}, St),
        holds({instance_of, licence, <<"MIT">>}, St),
        holds({instance_of, <<"permissive">>, <<"MIT">>}, St),
        holds({instance_of, <<"gpl">>, <<"AGPL-3.0-only">>}, St),
        fails({instance_of, <<"gpl">>, <<"MIT">>}, St),
        ?assertEqual(<<"permissive">>, value({'F'}, {attribute, <<"MIT">>, family, {'F'}}, St)),
        ?assertEqual(4, value({'R'}, {attribute, <<"AGPL-3.0-only">>, reach, {'R'}}, St)),
        ?assertEqual([<<"keep the copyright notice and licence text">>],
                     solutions({'W'}, {attribute, <<"MIT">>, obligation, {'W'}}, St)),
        %% every licence names a family that is declared as a class
        Licences = solutions({'I'}, {instance_of, licence, {'I'}}, St),
        ?assertEqual(21, length(Licences)),
        lists:foreach(
          fun(Id) -> holds({isa, value({'F'}, {attribute, Id, family, {'F'}}, St), licence}, St) end,
          Licences),
        %% a work is a thing, listed once however many parts it has
        holds({isa, work, thing}, St)
    end).

a_work_is_one_instance_however_many_parts_test() ->
    Parts = <<"component(<<\"demo\">>, <<\"a\">>, <<\"MIT\">>).\n"
              "component(<<\"demo\">>, <<\"b\">>, <<\"ISC\">>).\n"
              "component(<<\"other\">>, <<\"c\">>, <<\"MIT\">>).\n">>,
    with_committed_licences(Parts, fun(_C, St) ->
        ?assertEqual([<<"demo">>, <<"other">>],
                     solutions({'W'}, {instance_of, work, {'W'}}, St)),
        ?assertEqual([<<"a">>, <<"b">>],
                     solutions({'P'}, {attribute, <<"demo">>, part, {'P'}}, St))
    end).

policy_test() ->
    with_committed_licences(<<"peer_admitted(k, h, p, k).">>, fun(_Committed, St) ->
        lists:foreach(
          fun(Goal) ->
                  holds({can_invoke, Goal, anyone, [], ns}, St)
          end,
          [{may_include, <<"GPL-3.0-only">>, <<"MIT">>},
           {effective, [<<"MIT">>], {'U'}},
           {blocks, [<<"MIT">>], {'A'}, {'B'}, {'W'}},
           {must_carry, [<<"MIT">>], {'L'}, {'W'}},
           {ships, <<"demo">>, {'U'}},
           {notice, <<"demo">>, {'P'}, {'L'}, {'W'}}]),
        fails({can_invoke, {assertz, {licence, <<"Mine">>, <<"permissive">>, 0}},
               anyone, [], ns}, St),
        fails({can_invoke, {retract, {refuses, {'_'}, {'_'}, {'_'}}}, {node, stranger}, [], ns}, St),
        holds({can_invoke, {assertz, {licence, <<"Mine">>, <<"permissive">>, 0}},
               {node, k}, [], ns}, St)
    end).

%% The founding source must fit the vocabulary a cold node will admit.
vocabulary_fits_the_genesis_budget_test() ->
    Terms = quod_committed_projection:read_terms(source()),
    New = quod_wire_term:cold_new_symbols(Terms),
    ?assert(length(New) =< ?QUOD_MAX_NEW_MATERIAL_ATOMS - 10,
            {New, length(New)}),
    ?assert(lists:all(fun({licence, Id, Family, Strength}) ->
                              is_binary(Id) andalso is_binary(Family)
                                  andalso is_integer(Strength);
                         (_) -> true
                      end, Terms)).

%% --- helpers ---------------------------------------------------------------

source() -> filename:join(code:priv_dir(quod), "ontologies/quod_licence.pl").

holds(Goal, St) -> ?assertMatch({succeed, _}, erlog_int:prove_goal(Goal, St)).

fails(Goal, St) ->
    ?assertMatch({fail, _}, erlog_int:prove_goal(Goal, St)).

value(Var, Goal, St) ->
    {succeed, Final} = erlog_int:prove_goal(Goal, St),
    erlog_int:dderef(Var, Final#est.bs).

solutions(Template, Goal, St) ->
    {succeed, Final} = erlog_int:prove_goal(
                         {findall, Template, Goal, {'Solutions'}}, St),
    erlog_int:dderef({'Solutions'}, Final#est.bs).

blocking(Licences, St) ->
    [{A, B, W} || {'-', A, {'-', B, W}} <-
                      solutions({'-', {'A'}, {'-', {'B'}, {'W'}}},
                                {blocks, Licences, {'A'}, {'B'}, {'W'}}, St)].

with_licences(Fun) ->
    with_committed_licences(<<>>, fun(_Committed, St) -> Fun(St) end).

with_committed_licences(Extra, Fun) ->
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
    {ok, Terms} = erlog_io:read_string_terms(
                    unicode:characters_to_list(Source)),
    load_terms(Terms, St).

load_terms(Terms, #est{db = Db0} = St) ->
    St#est{db = lists:foldl(fun erlog_int:assertz_clause/2, Db0, Terms)}.

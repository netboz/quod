-module(quod_names_tests).

%% The `quod:names` ontology (priv/ontologies/quod_names.pl) on the base
%% engine every ontology starts from: a pool enumerates and counts the same
%% names, name_nth/5 follows that order, recognition runs the recipes
%% backwards, draw/5 and draw/2 pick real names under a real proof session
%% (proof_draw/3 -> '$quod_draw'/3), and can_invoke/4 opens only the naming
%% questions. Names are binaries throughout; no stub stands in for a primitive.

-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

-define(NS, <<"quod:names">>).
-define(HALFLING_MALES, 48 * 8).
-define(POOLS, 21).

generation_matches_count_test() ->
    with_names(fun(St) ->
        Names = halfling_males(St),
        ?assertEqual(?HALFLING_MALES, length(Names)),
        ?assertEqual(?HALFLING_MALES,
                     value({'N'}, {count, halfling, personal, male, {'N'}}, St)),
        ?assertEqual(<<"Adald">>, hd(Names)),
        ?assertEqual(<<"Wydwise">>, lists:last(Names)),
        ?assert(lists:all(fun is_binary/1, Names))
    end).

name_nth_follows_enumeration_order_test() ->
    with_names(fun(St) ->
        Names = halfling_males(St),
        lists:foreach(
          fun({I, Name}) ->
                  ?assertEqual(Name, value({'N'}, {name_nth, halfling, personal,
                                                    male, I, {'N'}}, St))
          end, lists:zip(lists:seq(0, ?HALFLING_MALES - 1), Names)),
        fails({name_nth, halfling, personal, male, ?HALFLING_MALES, {'N'}}, St),
        fails({name_nth, halfling, personal, male, -1, {'N'}}, St),
        fails({name_nth, halfling, personal, male, one, {'N'}}, St)
    end).

recognition_test() ->
    with_names(fun(St) ->
        ?assertEqual([orc_male], classes(<<"Ugbash">>, St)),
        Dain = classes(<<"Dain">>, St),
        ?assert(lists:member(norse_dwarf, Dain)),
        ?assert(lists:member(dwarf_male, Dain)),
        ?assertEqual([], classes(<<"Sally">>, St)),
        ?assertEqual([], classes(<<"ugbash">>, St)),
        ?assertEqual([], classes(<<"UGBASH">>, St)),
        ?assertEqual([], classes(<<>>, St)),
        ?assertEqual([], classes('Ugbash', St)),
        ?assertEqual([], classes(42, St)),
        ?assertEqual([], classes([$U, $g], St)),
        ?assertMatch({succeed, _},
                     erlog_int:prove_goal({name, orc_male, <<"Ugbash">>}, St)),
        fails({name, goblin_male, <<"Ugbash">>}, St),
        ?assertEqual([orc],
                     solutions({'C'}, {name, <<"Ugbash">>, {'C'}, personal, male}, St))
    end).

round_trip_test() ->
    with_names(fun(St) ->
        lists:foreach(
          fun({Class, Culture, Gender}) ->
                  Count = value({'N'}, {count, Culture, personal, Gender, {'N'}}, St),
                  lists:foreach(
                    fun(I) ->
                            Name = value({'N'}, {name_nth, Culture, personal,
                                                 Gender, I, {'N'}}, St),
                            ?assert(is_binary(Name)),
                            ?assert(lists:member(Class, classes(Name, St)),
                                    {Class, I, Name})
                    end, [0, Count div 2, Count - 1])
          end,
          [{orc_female, orc, female},
           {primitive_male, primitive, male},
           {primitive_female, primitive, female},
           {gnome_female, gnome, female},
           {elf_male, elf, male},
           {faerie_female, faerie, female},
           {greek_siren, siren, female}])
    end).

recipe_shapes_test() ->
    with_names(fun(St) ->
        Nth = fun(Culture, Gender, I) ->
                      value({'N'}, {name_nth, Culture, personal, Gender, I, {'N'}}, St)
              end,
        %% rep(1, 3): the 100 one-part names, then 100^2 two-part, then three-part.
        ?assertEqual(100 + 100 * 100 + 100 * 100 * 100,
                     value({'N'}, {count, primitive, personal, male, {'N'}}, St)),
        ?assertEqual(<<"Ahg">>, Nth(primitive, male, 0)),
        ?assertEqual(<<"Ahg-Ahg">>, Nth(primitive, male, 100)),
        ?assertEqual(<<"Ahg-Ahg-Ahg">>, Nth(primitive, male, 100 + 100 * 100)),
        ?assertEqual(<<"Zham-Zham-Zham">>,
                     Nth(primitive, male, 100 + 100 * 100 + 100 * 100 * 100 - 1)),
        %% one_of over two join shapes, the sung element at either end.
        ?assertEqual((100 + 100 * 100) * 8 * 2,
                     value({'N'}, {count, primitive, personal, female, {'N'}}, St)),
        ?assertEqual(<<"Ahg-Doh">>, Nth(primitive, female, 0)),
        ?assertEqual(<<"Doh-Ahg">>, Nth(primitive, female, (100 + 100 * 100) * 8)),
        %% concat of three tables: last part varies fastest.
        ?assertEqual(<<"Agagah">>, Nth(orc, female, 0)),
        ?assertEqual(<<"Agagay">>, Nth(orc, female, 1)),
        ?assertEqual(<<"Agaugah">>, Nth(orc, female, 6))
    end).

wider_culture_test() ->
    with_names(fun(St) ->
        Count = fun(Culture, Gender) ->
                        value({'N'}, {count, Culture, personal, Gender, {'N'}}, St)
                end,
        ?assertEqual(3 * 100 * 100 * 6, Count(vile, female)),
        ?assertEqual(60 * 16 + 71 + 60 * 8 + 48 * 8, Count(doughty, male)),
        ?assertEqual(Count(fantastic, male) + Count(fantastic, female),
                     Count(fantastic, {'_'})),
        ?assertEqual(Count(fantastic, {'_'}), Count({'_'}, {'_'})),
        ?assertEqual(0, Count(dragon, male)),
        %% An unbound culture comes back as the pool's own culture, once.
        ?assertEqual([goblin, orc, ogre, primitive, dwarf, dwarf, gnome, halfling,
                      elf, faerie],
                     solutions({'C'}, {pool, {'_'}, {'C'}, personal, male}, St))
    end).

draw_test() ->
    ProofId = crypto:strong_rand_bytes(32),
    with_committed_names(<<>>, fun(Committed, St) ->
        with_origin(ProofId, fun() ->
            Draw = fun(Goal, Var) ->
                           {ok, Bindings} = quod_ct:session_prove(
                                              Committed, {origin, test},
                                              proof_ctx(), Goal),
                           maps:get(Var, Bindings)
                   end,
            Halfling = Draw({draw, halfling, personal, male, salt, {'N'}}, 'N'),
            ?assert(is_binary(Halfling)),
            ?assert(lists:member(Halfling, halfling_males(St))),
            ?assertEqual(Halfling,
                         Draw({draw, halfling, personal, male, salt, {'N'}}, 'N')),
            %% Two salts in one proof: distinct questions, independent answers.
            ?assertEqual([Halfling, Halfling],
                         Draw({findall, {'N'},
                               {';', {draw, halfling, personal, male, salt, {'N'}},
                                {draw, halfling, personal, male, salt, {'N'}}},
                               {'L'}}, 'L')),
            Any = Draw({draw, salt, {'N'}}, 'N'),
            ?assert(is_binary(Any)),
            ?assertNotEqual([], classes(Any, St)),
            ?assertEqual(Any, Draw({draw, salt, {'N'}}, 'N')),
            %% Every draw is a recognised name of its selection.
            lists:foreach(
              fun(Salt) ->
                      Elf = Draw({draw, elf, personal, female, Salt, {'N'}}, 'N'),
                      ?assert(lists:member(elf_female, classes(Elf, St)), Elf)
              end, [a, b, c]),
            ?assertEqual(fail, quod_ct:session_prove(
                                 Committed, {origin, test}, proof_ctx(),
                                 {draw, dragon, personal, male, salt, {'N'}}))
        end),
        %% Outside a proof nothing is drawn.
        fails({draw, halfling, personal, male, salt, {'N'}}, St),
        fails({draw, salt, {'N'}}, St)
    end).

policy_test() ->
    with_committed_names(<<"peer_admitted(k, h, p, k).">>, fun(_Committed, St) ->
        lists:foreach(
          fun(Goal) ->
                  ?assertMatch({succeed, _},
                               erlog_int:prove_goal(
                                 {can_invoke, Goal, anyone, [], ns}, St))
          end,
          [{name, {'N'}, orc, personal, male}, {name, {'C'}, <<"Ugbash">>},
           {count, {'_'}, {'_'}, {'_'}, {'N'}},
           {name_nth, elf, personal, female, 3, {'N'}},
           {draw, orc, personal, male, salt, {'N'}}, {draw, salt, {'N'}}]),
        fails({can_invoke, {assertz, {orc_male, x}}, anyone, [], ns}, St),
        fails({can_invoke, {',', {name, {'N'}, orc, personal, male},
                            {assertz, {orc_male, x}}}, anyone, [], ns}, St),
        fails({can_invoke, {assertz, {orc_male, x}}, {node, stranger}, [], ns}, St),
        ?assertMatch({succeed, _},
                     erlog_int:prove_goal(
                       {can_invoke, {assertz, {orc_male, x}}, {node, k}, [], ns}, St))
    end).

%% --- helpers ---------------------------------------------------------------

halfling_males(St) ->
    solutions({'N'}, {name, {'N'}, halfling, personal, male}, St).

classes(Name, St) ->
    solutions({'C'}, {name, {'C'}, Name}, St).

solutions(Template, Goal, St) ->
    {succeed, Final} =
        erlog_int:prove_goal({findall, Template, Goal, {'L'}}, St),
    erlog_int:dderef({'L'}, Final#est.bs).

value(Var, Goal, St) ->
    {succeed, Final} = erlog_int:prove_goal(Goal, St),
    erlog_int:dderef(Var, Final#est.bs).

fails(Goal, St) ->
    ?assertMatch({fail, _}, erlog_int:prove_goal(Goal, St)).

proof_ctx() -> quod_predicates:proof_context(?NS, 1, undefined).

with_origin(ProofId, Fun) ->
    _ = quod_proof_context:start(
          ProofId, false, {?NS, <<0:256>>},
          quod_time:mono_ms() + 60000, anonymous),
    try Fun()
    after quod_proof_context:stop(fun(_) -> ok end, fun(_) -> ok end)
    end.

with_names(Fun) ->
    with_committed_names(<<>>, fun(_Committed, St) -> Fun(St) end).

%% The ontology's source over the base engine (primitives + common
%% predicates), committed once; Fun gets the committed state and a wrapped
%% read state over it.
with_committed_names(Extra, Fun) ->
    Base = quod_committed_projection:new_est(),
    File = filename:join(code:priv_dir(quod), "ontologies/quod_names.pl"),
    Loaded = load_terms(quod_committed_projection:read_terms(File), Base),
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

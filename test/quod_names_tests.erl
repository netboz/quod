-module(quod_names_tests).

%% The `quod:names` ontology (priv/ontologies/quod_names.pl) on the base
%% engine every ontology starts from: a pool enumerates and counts the same
%% names, name_nth/5 follows that order, recognition runs the recipes
%% backwards, draw/5 and draw/2 pick real names under a real proof session
%% (proof_draw/3 -> '$quod_draw'/3), and can_invoke/4 opens only the naming
%% questions. Names, syllables and table names are binaries throughout; the
%% source must stay within the genesis vocabulary budget a cold node admits.

-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_vm_limits.hrl").

-define(NS, <<"quod:names">>).
-define(HALFLING_MALES, 48 * 8).
-define(POOLS, 21).

generation_matches_count_test() ->
    with_names(fun(St) ->
        Names = halfling_males(St),
        ?assertEqual(?HALFLING_MALES, length(Names)),
        ?assertEqual(?HALFLING_MALES,
                     value({'N'}, {count, <<"halfling">>, <<"personal">>, <<"male">>, {'N'}}, St)),
        ?assertEqual(<<"Adald">>, hd(Names)),
        ?assertEqual(<<"Wydwise">>, lists:last(Names)),
        ?assert(lists:all(fun is_binary/1, Names))
    end).

name_nth_follows_enumeration_order_test() ->
    with_names(fun(St) ->
        Names = halfling_males(St),
        lists:foreach(
          fun({I, Name}) ->
                  ?assertEqual(Name, value({'N'}, {name_nth, <<"halfling">>, <<"personal">>,
                                                    <<"male">>, I, {'N'}}, St))
          end, lists:zip(lists:seq(0, ?HALFLING_MALES - 1), Names)),
        fails({name_nth, <<"halfling">>, <<"personal">>, <<"male">>, ?HALFLING_MALES, {'N'}}, St),
        fails({name_nth, <<"halfling">>, <<"personal">>, <<"male">>, -1, {'N'}}, St),
        fails({name_nth, <<"halfling">>, <<"personal">>, <<"male">>, one, {'N'}}, St)
    end).

%% A pool grown by ordinary writes arrives in chunks: several listed facts
%% for one pool. It counts, enumerates, indexes and recognises exactly as the
%% same names in a single fact would, and the pool ordering is the order the
%% chunks were committed.
chunked_pool_reads_as_one_list_test() ->
    Chunks = <<"isa(<<\"testfolk\">>, <<\"thing\">>).\n"
               "pool(<<\"testfolk\">>, <<\"personal\">>, <<\"any\">>, listed).\n"
               "listed(<<\"testfolk\">>, <<\"personal\">>, <<\"any\">>, [<<\"Ada\">>, <<\"Bo\">>]).\n"
               "listed(<<\"testfolk\">>, <<\"personal\">>, <<\"any\">>, [<<\"Cy\">>]).\n"
               "listed(<<\"testfolk\">>, <<\"personal\">>, <<\"any\">>, [<<\"Di\">>, <<\"Ed\">>]).\n">>,
    One = <<"isa(<<\"oldfolk\">>, <<\"thing\">>).\n"
            "pool(<<\"oldfolk\">>, <<\"personal\">>, <<\"any\">>, listed).\n"
            "listed(<<\"oldfolk\">>, <<\"personal\">>, <<\"any\">>, "
            "[<<\"Ada\">>, <<\"Bo\">>, <<\"Cy\">>, <<\"Di\">>, <<\"Ed\">>]).\n">>,
    Names = [<<"Ada">>, <<"Bo">>, <<"Cy">>, <<"Di">>, <<"Ed">>],
    with_committed_names(<<Chunks/binary, One/binary>>, fun(_Committed, St) ->
        lists:foreach(
          fun(Culture) ->
                  ?assertEqual(5, value({'N'}, {count, Culture, <<"personal">>, <<"any">>, {'N'}}, St)),
                  ?assertEqual(Names,
                               value({'L'}, {findall, {'N'},
                                             {name, {'N'}, Culture, <<"personal">>, <<"any">>},
                                             {'L'}}, St)),
                  lists:foreach(
                    fun({I, Name}) ->
                            ?assertEqual(Name, value({'N'}, {name_nth, Culture, <<"personal">>,
                                                             <<"any">>, I, {'N'}}, St))
                    end, lists:zip(lists:seq(0, 4), Names)),
                  fails({name_nth, Culture, <<"personal">>, <<"any">>, 5, {'N'}}, St),
                  fails({name_nth, Culture, <<"personal">>, <<"any">>, -1, {'N'}}, St),
                  ?assertMatch({succeed, _},
                               erlog_int:prove_goal(
                                 {name, <<"Cy">>, Culture, <<"personal">>, <<"any">>}, St)),
                  fails({name, <<"Zz">>, Culture, <<"personal">>, <<"any">>}, St)
          end, [<<"testfolk">>, <<"oldfolk">>]),
        %% the chunks are one pool, not three
        ?assertEqual([{<<"testfolk">>, <<"personal">>, <<"any">>},
                      {<<"oldfolk">>, <<"personal">>, <<"any">>}],
                     selections(<<"Cy">>, St))
    end).

recognition_test() ->
    with_names(fun(St) ->
        ?assertEqual([{<<"orc">>, <<"personal">>, <<"male">>}], selections(<<"Ugbash">>, St)),
        %% Dain is both da+in and a listed Norse <<"dwarf">>: one answer per pool.
        ?assertEqual([{<<"dwarf">>, <<"personal">>, <<"male">>}, {<<"dwarf">>, <<"personal">>, <<"male">>}],
                     selections(<<"Dain">>, St)),
        ?assertEqual([], selections(<<"Sally">>, St)),
        ?assertEqual([], selections(<<"ugbash">>, St)),
        ?assertEqual([], selections(<<"UGBASH">>, St)),
        ?assertEqual([], selections(<<>>, St)),
        ?assertEqual([], selections('Ugbash', St)),
        ?assertEqual([], selections(42, St)),
        ?assertEqual([], selections([$U, $g], St)),
        ?assertMatch({succeed, _},
                     erlog_int:prove_goal({name, <<"Ugbash">>, <<"orc">>, <<"personal">>, <<"male">>}, St)),
        ?assertMatch({succeed, _},
                     erlog_int:prove_goal({name, <<"Ugbash">>, <<"vile">>, <<"personal">>, <<"male">>}, St)),
        fails({name, <<"Ugbash">>, <<"goblin">>, <<"personal">>, <<"male">>}, St),
        fails({name, <<"Ugbash">>, <<"orc">>, <<"personal">>, <<"female">>}, St)
    end).

round_trip_test() ->
    with_names(fun(St) ->
        lists:foreach(
          fun({Culture, Gender}) ->
                  Count = value({'N'}, {count, Culture, <<"personal">>, Gender, {'N'}}, St),
                  lists:foreach(
                    fun(I) ->
                            Name = value({'N'}, {name_nth, Culture, <<"personal">>,
                                                 Gender, I, {'N'}}, St),
                            ?assert(is_binary(Name)),
                            ?assert(lists:member({Culture, <<"personal">>, Gender},
                                                 selections(Name, St)),
                                    {Culture, Gender, I, Name})
                    end, [0, Count div 2, Count - 1])
          end,
          [{<<"orc">>, <<"female">>}, {<<"primitive">>, <<"male">>}, {<<"primitive">>, <<"female">>},
           {<<"gnome">>, <<"female">>}, {<<"elf">>, <<"male">>}, {<<"faerie">>, <<"female">>}, {<<"siren">>, <<"female">>},
           {<<"dwarf">>, <<"male">>}])
    end).

recipe_shapes_test() ->
    with_names(fun(St) ->
        Nth = fun(Culture, Gender, I) ->
                      value({'N'}, {name_nth, Culture, <<"personal">>, Gender, I, {'N'}}, St)
              end,
        %% rep(1, 3): the 100 one-part names, then 100^2 two-part, then three-part.
        ?assertEqual(100 + 100 * 100 + 100 * 100 * 100,
                     value({'N'}, {count, <<"primitive">>, <<"personal">>, <<"male">>, {'N'}}, St)),
        ?assertEqual(<<"Ahg">>, Nth(<<"primitive">>, <<"male">>, 0)),
        ?assertEqual(<<"Ahg-Ahg">>, Nth(<<"primitive">>, <<"male">>, 100)),
        ?assertEqual(<<"Ahg-Ahg-Ahg">>, Nth(<<"primitive">>, <<"male">>, 100 + 100 * 100)),
        ?assertEqual(<<"Zham-Zham-Zham">>,
                     Nth(<<"primitive">>, <<"male">>, 100 + 100 * 100 + 100 * 100 * 100 - 1)),
        %% one_of over two join shapes, the sung element at either end.
        ?assertEqual((100 + 100 * 100) * 8 * 2,
                     value({'N'}, {count, <<"primitive">>, <<"personal">>, <<"female">>, {'N'}}, St)),
        ?assertEqual(<<"Ahg-Doh">>, Nth(<<"primitive">>, <<"female">>, 0)),
        ?assertEqual(<<"Doh-Ahg">>, Nth(<<"primitive">>, <<"female">>, (100 + 100 * 100) * 8)),
        %% concat of three tables: last part varies fastest.
        ?assertEqual(<<"Agagah">>, Nth(<<"orc">>, <<"female">>, 0)),
        ?assertEqual(<<"Agagay">>, Nth(<<"orc">>, <<"female">>, 1)),
        ?assertEqual(<<"Agaugah">>, Nth(<<"orc">>, <<"female">>, 6)),
        %% two pools for <<"dwarf">> male: the recipe pool first, then the list.
        ?assertEqual(<<"Balbor">>, Nth(<<"dwarf">>, <<"male">>, 0)),
        ?assertEqual(<<"Ai">>, Nth(<<"dwarf">>, <<"male">>, 60 * 16)),
        ?assertEqual(<<"Yingi">>, Nth(<<"dwarf">>, <<"male">>, 60 * 16 + 70))
    end).

wider_culture_test() ->
    with_names(fun(St) ->
        Count = fun(Culture, Gender) ->
                        value({'N'}, {count, Culture, <<"personal">>, Gender, {'N'}}, St)
                end,
        ?assertEqual(3 * 100 * 100 * 6, Count(<<"vile">>, <<"female">>)),
        ?assertEqual(60 * 16 + 71 + 60 * 8 + 48 * 8, Count(<<"doughty">>, <<"male">>)),
        ?assertEqual(Count(<<"fantastic">>, <<"male">>) + Count(<<"fantastic">>, <<"female">>),
                     Count(<<"fantastic">>, {'_'})),
        ?assertEqual(Count(<<"fantastic">>, {'_'}), Count({'_'}, {'_'})),
        ?assertEqual(1449227, Count({'_'}, {'_'})),
        ?assertEqual(0, Count(<<"dragon">>, <<"male">>)),
        %% An unbound culture comes back as the pool's own culture, once per
        %% pool, in pool order.
        ?assertEqual([<<"goblin">>, <<"orc">>, <<"ogre">>, <<"primitive">>, <<"dwarf">>,
                      <<"dwarf">>, <<"gnome">>, <<"halfling">>, <<"elf">>, <<"faerie">>],
                     solutions({'C'}, {select, {'C'}, <<"personal">>, <<"male">>, {'_'}, {'_'}}, St))
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
            Halfling = Draw({draw, <<"halfling">>, <<"personal">>, <<"male">>, salt, {'N'}}, 'N'),
            ?assert(is_binary(Halfling)),
            ?assert(lists:member(Halfling, halfling_males(St))),
            ?assertEqual(Halfling,
                         Draw({draw, <<"halfling">>, <<"personal">>, <<"male">>, salt, {'N'}}, 'N')),
            ?assertEqual([Halfling, Halfling],
                         Draw({findall, {'N'},
                               {';', {draw, <<"halfling">>, <<"personal">>, <<"male">>, salt, {'N'}},
                                {draw, <<"halfling">>, <<"personal">>, <<"male">>, salt, {'N'}}},
                               {'L'}}, 'L')),
            Any = Draw({draw, salt, {'N'}}, 'N'),
            ?assert(is_binary(Any)),
            ?assertNotEqual([], selections(Any, St)),
            ?assertEqual(Any, Draw({draw, salt, {'N'}}, 'N')),
            lists:foreach(
              fun(Salt) ->
                      Elf = Draw({draw, <<"elf">>, <<"personal">>, <<"female">>, Salt, {'N'}}, 'N'),
                      ?assert(lists:member({<<"elf">>, <<"personal">>, <<"female">>},
                                           selections(Elf, St)), Elf)
              end, [a, b, c]),
            ?assertEqual(fail, quod_ct:session_prove(
                                 Committed, {origin, test}, proof_ctx(),
                                 {draw, <<"dragon">>, <<"personal">>, <<"male">>, salt, {'N'}}))
        end),
        %% Outside a proof nothing is drawn.
        fails({draw, <<"halfling">>, <<"personal">>, <<"male">>, salt, {'N'}}, St),
        fails({draw, salt, {'N'}}, St)
    end).

%% draw with no salt at all: the proof itself is the entropy. One proof gets
%% one name and keeps giving that name; another proof draws again. No clock is
%% consulted, so every node asking the same proof reaches the same answer.
saltless_draw_test() ->
    Run = fun(ProofId) ->
                  with_committed_names(<<>>, fun(Committed, St) ->
                      with_origin(ProofId, fun() ->
                          Draw = fun(Goal, Var) ->
                                         {ok, B} = quod_ct:session_prove(
                                                     Committed, {origin, test},
                                                     proof_ctx(), Goal),
                                         maps:get(Var, B)
                                 end,
                          Any = Draw({draw, {'N'}}, 'N'),
                          ?assert(is_binary(Any)),
                          ?assertNotEqual([], selections(Any, St)),
                          %% a bare draw names a person, never a title or an
                          %% epithet, whatever other kinds the ontology holds
                          ?assert(lists:all(
                                    fun({_C, K, _G}) ->
                                            lists:member(K, [<<"personal">>, <<"family">>,
                                                             <<"byname">>, <<"theophoric">>])
                                    end, selections(Any, St))),
                          ?assertEqual(Any, Draw({draw, {'N'}}, 'N')),
                          ?assertEqual([Any, Any],
                                       Draw({findall, {'N'},
                                             {';', {draw, {'N'}}, {draw, {'N'}}}, {'L'}}, 'L')),
                          Halfling = Draw({draw, <<"halfling">>, <<"personal">>,
                                           <<"male">>, {'N'}}, 'N'),
                          ?assert(lists:member(Halfling, halfling_males(St))),
                          ?assertEqual(Halfling,
                                       Draw({draw, <<"halfling">>, <<"personal">>,
                                             <<"male">>, {'N'}}, 'N')),
                          %% the salted form with the same constant is the same draw
                          ?assertEqual(Any, Draw({draw, 0, {'N'}}, 'N')),
                          {Any, Halfling}
                      end)
                  end)
          end,
    First = Run(crypto:strong_rand_bytes(32)),
    Others = [Run(crypto:strong_rand_bytes(32)) || _ <- lists:seq(1, 6)],
    ?assert(lists:any(fun(Drawn) -> Drawn =/= First end, Others)),
    %% and outside a proof it draws nothing
    with_names(fun(St) ->
        fails({draw, {'N'}}, St),
        fails({draw, <<"halfling">>, <<"personal">>, <<"male">>, {'N'}}, St)
    end).

%% The class view is a projection of the pools, not a second copy of them: a
%% browser that knows only the house vocabulary sees the same 21 pools, the
%% same kinds and genders, and the same sizes that count/4 reports.
class_view_test() ->
    with_names(fun(St) ->
        ?assertMatch({succeed, _}, erlog_int:prove_goal({isa, pool, thing}, St)),
        ?assertEqual([<<"personal">>],
                     solutions({'K'}, {instance_of, kind, {'K'}}, St)),
        ?assertEqual([<<"female">>, <<"male">>],
                     solutions({'G'}, {instance_of, gender, {'G'}}, St)),
        Pools = solutions({'P'}, {instance_of, pool, {'P'}}, St),
        ?assertEqual(?POOLS, length(Pools)),
        ?assert(lists:member({pool, <<"halfling">>, <<"personal">>, <<"male">>}, Pools)),
        %% an attribute agrees with the predicate it is derived from
        ?assertEqual(?HALFLING_MALES,
                     value({'S'}, {attribute, {pool, <<"halfling">>, <<"personal">>, <<"male">>},
                                   size, {'S'}}, St)),
        ?assertEqual(<<"halfling">>,
                     value({'C'}, {attribute, {pool, <<"halfling">>, <<"personal">>, <<"male">>},
                                   culture, {'C'}}, St)),
        %% and the sizes of every pool add up to what count/4 says
        Sizes = solutions({'S'}, {attribute, {'_'}, size, {'S'}}, St),
        ?assertEqual(value({'N'}, {count, {'_'}, {'_'}, {'_'}, {'N'}}, St),
                     lists:sum(Sizes)),
        %% a culture reaches its pools
        ?assertEqual([{pool, <<"orc">>, <<"personal">>, <<"female">>},
                      {pool, <<"orc">>, <<"personal">>, <<"male">>}],
                     lists:sort(solutions({'P'}, {attribute, <<"orc">>, pool, {'P'}}, St)))
    end).

policy_test() ->
    with_committed_names(<<"peer_admitted(k, h, p, k).">>, fun(_Committed, St) ->
        lists:foreach(
          fun(Goal) ->
                  ?assertMatch({succeed, _},
                               erlog_int:prove_goal(
                                 {can_invoke, Goal, anyone, [], ns}, St))
          end,
          [{name, {'N'}, <<"orc">>, <<"personal">>, <<"male">>}, {name, <<"Ugbash">>, {'C'}, {'K'}, {'G'}},
           {count, {'_'}, {'_'}, {'_'}, {'N'}},
           {name_nth, <<"elf">>, <<"personal">>, <<"female">>, 3, {'N'}},
           {draw, <<"orc">>, <<"personal">>, <<"male">>, salt, {'N'}}, {draw, salt, {'N'}},
           {draw, <<"orc">>, <<"personal">>, <<"male">>, {'N'}}, {draw, {'N'}}]),
        fails({can_invoke, {assertz, {elements, <<"zz">>, [<<"zzz">>]}}, anyone, [], ns}, St),
        fails({can_invoke, {',', {name, {'N'}, <<"orc">>, <<"personal">>, <<"male">>},
                            {assertz, {elements, <<"zz">>, [<<"zzz">>]}}}, anyone, [], ns}, St),
        fails({can_invoke, {assertz, {pool, <<"x">>, <<"personal">>, <<"male">>, listed}}, {node, stranger}, [], ns}, St),
        ?assertMatch({succeed, _},
                     erlog_int:prove_goal(
                       {can_invoke, {assertz, {pool, <<"x">>, <<"personal">>, <<"male">>, listed}}, {node, k}, [], ns}, St))
    end).

%% The genesis of this source must fit what a node that never saw it can
%% admit in one envelope: every atom of the source counts, since a cold
%% receiver may know none of them. Data must stay binaries.
vocabulary_fits_the_genesis_budget_test() ->
    File = filename:join(code:priv_dir(quod), "ontologies/quod_names.pl"),
    Terms = quod_committed_projection:read_terms(File),
    New = quod_wire_term:cold_new_symbols(Terms),
    ?assert(length(New) =< ?QUOD_MAX_NEW_MATERIAL_ATOMS - 10,
            {new_symbols, length(New), New}),
    ?assertEqual(?POOLS,
                 length([T || {pool, _, _, _, _} = T <- Terms])),
    ?assert(lists:all(fun({elements, Table, Fragments}) ->
                              is_binary(Table) andalso lists:all(fun is_binary/1, Fragments);
                         ({listed, _, _, _, Names}) -> lists:all(fun is_binary/1, Names);
                         (_) -> true
                      end, Terms)).

%% --- helpers ---------------------------------------------------------------

halfling_males(St) ->
    solutions({'N'}, {name, {'N'}, <<"halfling">>, <<"personal">>, <<"male">>}, St).

%% Every (culture, kind, gender) selection a name belongs to, one per pool.
selections(Name, St) ->
    [{C, K, G} || {s, C, K, G} <-
        solutions({s, {'C'}, {'K'}, {'G'}}, {name, Name, {'C'}, {'K'}, {'G'}}, St)].

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

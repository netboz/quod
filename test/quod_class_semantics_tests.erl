-module(quod_class_semantics_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

transitive_isa_is_shared_ontology_semantics_test() ->
    with_classes(
      [
       {isa, northern_red_oak, american_red_oak},
       {isa, american_red_oak, oak_wood},
       {isa, oak_wood, wood},
       {isa, wood, material},
       {isa, oak_wood, hardwood}
      ],
      fun(St) ->
          holds({isa, northern_red_oak, wood}, St),
          holds({isa, northern_red_oak, material}, St),
          holds({isa, northern_red_oak, hardwood}, St),
          holds({isa, northern_red_oak, northern_red_oak}, St),
          holds({isa, material, material}, St),
          fails({isa, undeclared, undeclared}, St),
          fails({isa, northern_red_oak, stone}, St)
      end).

rule_declarations_participate_in_transitive_isa_test() ->
    with_classes(
      [
       {family, permissive},
       {':-', {isa, {'Family'}, licence}, {family, {'Family'}}},
       {isa, licence, thing}
      ],
      fun(St) -> holds({isa, permissive, thing}, St) end).

cycles_terminate_without_inventing_an_answer_test() ->
    with_classes(
      [{isa, alpha, beta}, {isa, beta, alpha}, {isa, beta, thing}],
      fun(St) ->
          holds({isa, alpha, thing}, St),
          fails({isa, alpha, missing}, St)
      end).

staged_assert_and_retract_keep_the_same_semantics_test() ->
    with_classes(
      [{isa, wood, material}],
      fun(St0) ->
          {succeed, St1} = erlog_int:prove_goal(
                             {assertz, {isa, oak, wood}}, St0),
          holds({isa, oak, material}, St1),
          ?assertMatch(
             [{assert, {{isa, oak, wood}, _}}],
             quod_erlog_db_local_prove:get_local_changes(db_ref(St1))),
          %% An entailed edge is not a stored fact and cannot be retracted.
          ?assertMatch({fail, _}, erlog_int:prove_goal(
                                    {retract, {isa, oak, material}}, St1)),
          holds({isa, oak, material}, St1),
          {succeed, St2} = erlog_int:prove_goal(
                             {retract, {isa, oak, wood}}, St1),
          fails({isa, oak, material}, St2),
          ?assertEqual([], quod_erlog_db_local_prove:get_local_changes(db_ref(St2)))
      end).

with_classes(Terms, Fun) ->
    Base = quod_committed_projection:new_est(),
    Loaded = load_terms(Terms, Base),
    Committed = quod_ct:commit_kb(Loaded),
    St = quod_erlog_db_local_prove:wrap_state(Committed, #{read_set => true}),
    try Fun(St)
    after
        #est{db = #db{ref = Ref}} = Committed,
        quod_erlog_db_mvcc:delete(Ref)
    end.

load_terms(Terms, #est{db = Db0} = St) ->
    St#est{db = lists:foldl(fun erlog_int:assertz_clause/2, Db0, Terms)}.

db_ref(#est{db = #db{ref = Ref}}) -> Ref.

holds(Goal, St) ->
    ?assertMatch({succeed, _}, erlog_int:prove_goal(Goal, St)).

fails(Goal, St) ->
    ?assertMatch({fail, _}, erlog_int:prove_goal(Goal, St)).

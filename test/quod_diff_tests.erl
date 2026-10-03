-module(quod_diff_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").

%%%===================================================================
%%% Shared validation of untrusted durable material.
%%%===================================================================

valid_read_check_test() ->
    ?assert(quod_diff:valid_read_check(#{})),
    ?assert(quod_diff:valid_read_check(
              #{{fact, 1} => {present, 0},
                {gone, 2} => {absent, 9},
                {new, 0} => never_present,
                {built_in, 3} => static})),
    ?assertNot(quod_diff:valid_read_check([])),
    ?assertNot(quod_diff:valid_read_check(#{fact => never_present})),
    ?assertNot(quod_diff:valid_read_check(#{{fact, -1} => never_present})),
    ?assertNot(quod_diff:valid_read_check(#{{fact, 1} => staged})),
    ?assertNot(quod_diff:valid_read_check(#{{fact, 1} => {present, -1}})),
    ?assertNot(quod_diff:valid_read_check(#{{fact, 1} => {absent, 1.0}})).

opaque_foreign_functor_is_a_normal_map_key_test() ->
    Name = <<"quod_r3_foreign_", (binary:encode_hex(
                                    crypto:strong_rand_bytes(8)))/binary>>,
    Symbol = {'$quod_symbol', Name},
    Functor = {Symbol, 1},
    Head = {Symbol, value},
    Op = {assert, {Head, {[], false}}},
    ?assertException(error, badarg, binary_to_existing_atom(Name, utf8)),
    ?assert(quod_diff:valid_read_check(#{Functor => never_present})),
    ?assert(quod_diff:valid_ops([Op])),
    Est0 = quod_committed_projection:new_est(),
    try
        {ok, Est1, [Op]} = quod_diff:apply_ops_report(Est0, [Op]),
        ?assertEqual(
           {ok, [{Head, {[], false}}]},
           quod_diff:interpreted_clauses(Est1, Functor)),
        ?assert(quod_diff:touches_functor([Op], Functor)),
        ?assertException(
           error, badarg, binary_to_existing_atom(Name, utf8))
    after
        #est{db = #db{ref = Ref}} = Est0,
        quod_erlog_db_mvcc:delete(Ref)
    end.

valid_ops_test() ->
    Raw = {assert, {{fact, {0}, [nested, value]}, true}},
    Compiled =
        {retract,
         {{rule, {variable}},
          {[{{if_then_else},
             [{left, {0}}],
             [{{once}, [{right, {1}}], 2}],
             [{{cut}, label, false}],
             branch_label}],
           true}}},
    ?assert(quod_diff:valid_ops([])),
    ?assert(quod_diff:valid_ops(
              [Raw, Compiled, {event, alarm}, {event, {alarm, disk}}])),
    ?assertNot(quod_diff:valid_ops(not_a_list)),
    ?assertNot(quod_diff:valid_ops([Raw | improper_tail])),
    ?assertNot(quod_diff:valid_ops([{replace, {{fact, x}, true}}])),
    ?assertNot(quod_diff:valid_ops([{assert, {42, true}}])),
    ?assertNot(quod_diff:valid_ops([{assert, {{fact, x}, 42}}])),
    ?assertNot(quod_diff:valid_ops(
                 [{assert, {{fact, x}, {[{{cut}, -1, false}], false}}}])),
    ?assertNot(quod_diff:valid_ops(
                 [{assert, {{fact, {1.5}}, true}}])),
    ?assertNot(quod_diff:valid_ops([{event, {'Variable'}}])),
    ?assertNot(quod_diff:valid_ops([{event, 42}])),
    ?assertNot(quod_diff:valid_ops([{event, {assert, fact}}])),
    ?assertNot(quod_diff:valid_ops([{event, {retract, fact}}])),
    ?assertNot(quod_diff:valid_ops(
                 [{event, {from, <<"ns">>, <<0:256>>, signal}}])).

explicit_events_are_applied_occurrences_without_fact_mutation_test() ->
    Est0 = quod_ct:committed_kb([]),
    Events = [{event, {alarm, disk}}, {event, {alarm, disk}}],
    {ok, Est1, Applied} = quod_diff:apply_ops_report(Est0, Events),
    ?assertEqual(Events, Applied),
    ?assertEqual((Est0#est.db)#db.ref, (Est1#est.db)#db.ref).

interpreted_clauses_returns_content_not_proved_answers_test() ->
    Fact = {catalog_entry, fact},
    Enabled = {catalog_enabled, rule},
    Rule = {':-', {catalog_entry, rule}, Enabled},
    Est = quod_ct:committed_kb([Fact, Enabled, Rule]),
    {ok, Clauses} = quod_diff:interpreted_clauses(Est, {catalog_entry, 1}),
    ?assertEqual(2, length(Clauses)),
    ?assert(lists:any(fun({Head, {[], false}}) -> Head =:= Fact;
                         (_) -> false
                      end, Clauses)),
    ?assert(lists:any(fun({{catalog_entry, rule}, Body}) -> Body =/= {[], false};
                         (_) -> false
                      end, Clauses)),
    ?assertEqual({ok, []},
                 quod_diff:interpreted_clauses(Est, {catalog_absent, 1})).

%% The same ordered program must answer identically while staged and after
%% the ordinary canonical reducer has applied the sealed proof's diff.
front_insertion_preserves_first_solution_on_apply_test() ->
    with_ordered_proof([{choose, general}], fun(Committed, Wrapped) ->
        {succeed, Edited} = erlog_int:prove_goal(
                             {asserta, {choose, specific}}, Wrapped),
        ?assertEqual([specific, general], choices(Edited)),
        Ops = local_changes(Edited),
        ?assert(quod_diff:valid_ops(Ops)),
        {ok, Applied, _} = quod_diff:apply_ops_report(Committed, Ops),
        ?assertEqual([specific, general], choices(Applied))
    end).

mixed_insertions_preserve_program_order_on_apply_test() ->
    with_ordered_proof([{choose, first}, {choose, last}],
      fun(Committed, Wrapped) ->
          Edited = lists:foldl(fun(Goal, St) ->
              {succeed, Next} = erlog_int:prove_goal(Goal, St),
              Next
          end, Wrapped,
          [{asserta, {choose, front_one}},
           {assertz, {choose, tail_one}},
           {asserta, {choose, front_two}},
           {assertz, {choose, tail_two}},
           {retract, {choose, first}}]),
          Expected = [front_two, front_one, last, tail_one, tail_two],
          ?assertEqual(Expected, choices(Edited)),
          {ok, Applied, _} = quod_diff:apply_ops_report(
                               Committed, local_changes(Edited)),
          ?assertEqual(Expected, choices(Applied))
      end).

front_insertion_keeps_content_dedup_and_fact_event_contract_test() ->
    with_ordered_proof([{choose, original}], fun(Committed, _Wrapped) ->
        Ops = [{asserta, {{choose, original}, true}},
               {asserta, {{choose, new}, true}},
               {assert, {{choose, new}, true}},
               {event, code_saved}],
        {ok, Applied, Changes} = quod_diff:apply_ops_report(Committed, Ops),
        ?assertEqual([new, original], choices(Applied)),
        ?assertEqual([{assert, {choose, new}}, code_saved],
                     quod_runtime_predicates:diff_to_events(Changes)),
        {ok, Repeated, NoChanges} = quod_diff:apply_ops_report(
                                    Applied, lists:sublist(Ops, 3)),
        ?assertEqual([new, original], choices(Repeated)),
        ?assertEqual([], NoChanges)
    end).

ordered_edit_rollback_keeps_reads_but_discards_writes_and_events_test() ->
    with_ordered_proof([{choose, original}, {input, old}],
      fun(Committed, Wrapped) ->
          Checkpoint = quod_erlog_db_local_prove:checkpoint(Wrapped),
          {succeed, Read} = erlog_int:prove_goal({input, old}, Wrapped),
          {succeed, Inserted} = erlog_int:prove_goal(
                                 {asserta, {choose, discarded}}, Read),
          {ok, Event} = quod_erlog_db_local_prove:stage_event(Inserted, discarded),
          Restored = quod_erlog_db_local_prove:restore(Event, Checkpoint),
          ?assertEqual([], local_changes(Restored)),
          ?assertEqual([original], choices(Restored)),
          Reads = quod_erlog_db_local_prove:get_read_set(
                    (Restored#est.db)#db.ref),
          ?assertEqual({present, 1}, maps:get({input, 1}, Reads)),
          {ok, Changed} = quod_diff:apply_ops(
                            Committed, quod_ct:diff_for({input, new})),
          Published = quod_ct:commit_kb(Changed, 2, 1),
          ?assertEqual({conflict, {input, 1}},
                       quod_diff:validate(Reads, (Published#est.db)#db.ref))
      end).

with_ordered_proof(Facts, Fun) ->
    Committed = quod_ct:committed_kb(Facts),
    Wrapped = quod_erlog_db_local_prove:wrap_state(
                Committed, #{read_set => true}),
    try Fun(Committed, Wrapped)
    after
        quod_erlog_db_local_prove:cleanup_read_set(Wrapped),
        quod_erlog_db_mvcc:delete((Committed#est.db)#db.ref)
    end.

local_changes(#est{db = #db{ref = Ref}}) ->
    quod_erlog_db_local_prove:get_local_changes(Ref).

choices(St) ->
    {succeed, Answer} = erlog_int:prove_goal(
                         {findall, {'Choice'}, {choose, {'Choice'}}, {'Choices'}}, St),
    erlog_int:dderef({'Choices'}, Answer#est.bs).

%%%===================================================================
%%% The pure genesis policy-presence primitives (slice 3).
%%%===================================================================

assertion_only_test() ->
    ?assert(quod_diff:assertion_only([])),
    ?assert(quod_diff:assertion_only(
              [{assert, {{can_invoke, a, b, c, d}, true}},
               {assert, {{fact, x}, true}}])),
    %% any retract disqualifies it — including an assert-then-retract trick
    ?assertNot(quod_diff:assertion_only(
                 [{assert, {{can_invoke, a, b, c, d}, true}},
                  {retract, {{can_invoke, a, b, c, d}, true}}])),
    ?assertNot(quod_diff:assertion_only([{retract, {{f, x}, true}}])),
    ?assertNot(quod_diff:assertion_only([{event, founded}])).

asserts_functor_test() ->
    %% head is `{can_invoke, _, _, _, _}` ⇒ functor {can_invoke, 4}
    Policy = {assert, {{can_invoke, {'G'}, {'P'}, {'C'}, {'N'}}, true}},
    ?assert(quod_diff:asserts_functor([Policy], {can_invoke, 4})),
    ?assert(quod_diff:asserts_functor(
              [{assert, {{other, x}, true}}, Policy], {can_invoke, 4})),
    %% wrong arity is a different functor
    ?assertNot(quod_diff:asserts_functor(
                 [{assert, {{can_invoke, {'G'}, {'P'}, {'N'}}, true}}],
                 {can_invoke, 4})),
    %% a retract of the head does not count as asserting it
    ?assertNot(quod_diff:asserts_functor(
                 [{retract, {{can_invoke, a, b, c, d}, true}}],
                 {can_invoke, 4})),
    ?assertNot(quod_diff:asserts_functor([], {can_invoke, 4})).

%% The genesis policy-presence invariant is exactly the conjunction the founding
%% and creation seams enforce: assertion-only AND asserts a {can_invoke,4} head.
policy_presence_invariant_test() ->
    Ok = [{assert, {{can_invoke, {'G'}, {'P'}, {'C'}, {'N'}}, true}},
          {assert, {{welcome, all}, true}}],
    ?assert(quod_diff:assertion_only(Ok)
            andalso quod_diff:asserts_functor(Ok, {can_invoke, 4})),
    %% policy-less genesis fails presence
    NoPolicy = [{assert, {{welcome, all}, true}}],
    ?assertNot(quod_diff:asserts_functor(NoPolicy, {can_invoke, 4})),
    %% assert-then-retract fails assertion_only even though the head appears
    Sneaky = [{assert, {{can_invoke, a, b, c, d}, true}},
              {retract, {{can_invoke, a, b, c, d}, true}}],
    ?assertNot(quod_diff:assertion_only(Sneaky)).

%%%===================================================================
%%% The post-diff policy self-seal invariant.
%%%===================================================================

policy_self_seal_uses_final_state_test() ->
    Old = {can_invoke, {'Goal'}, {'Principal'}, [], {'Namespace'}},
    New = {can_invoke, {'Goal'}, {'Principal'}, {'Chain'}, {'Namespace'}},
    Est0 = quod_ct:committed_kb([Old]),
    [OldAssert] = quod_ct:diff_for(Old),
    [NewAssert] = quod_ct:diff_for(New),
    OldRetract = as_retract(OldAssert),

    %% Removing the last policy is refused and the immutable parent is intact.
    ?assertEqual(
       {error, policy_self_seal_forbidden},
       quod_diff:apply_ops_preserving_policy(Est0, [OldRetract])),
    ?assert(policy_present(Est0)),

    %% The helper judges the final candidate: replacement is valid in either
    %% operation order and does not expose an intermediate policy-less state.
    {ok, Replaced1} = quod_diff:apply_ops_preserving_policy(
                        Est0, [OldRetract, NewAssert]),
    {ok, Replaced2} = quod_diff:apply_ops_preserving_policy(
                        Est0, [NewAssert, OldRetract]),
    ?assert(policy_present(Replaced1)),
    ?assert(policy_present(Replaced2)).

abolish_expansion_cannot_remove_all_policy_test() ->
    P1 = {can_invoke, one, principal, [], namespace},
    P2 = {can_invoke, two, principal, [], namespace},
    Est0 = quod_ct:committed_kb([P1, P2]),
    %% The prove overlay represents abolish/1 as one exact retract per clause;
    %% the shared helper therefore needs no abolish-specific operation.
    [Assert1] = quod_ct:diff_for(P1),
    [Assert2] = quod_ct:diff_for(P2),
    Retracts = [as_retract(Assert1), as_retract(Assert2)],
    ?assertEqual(
       {error, policy_self_seal_forbidden},
       quod_diff:apply_ops_preserving_policy(Est0, Retracts)),
    ?assert(policy_present(Est0)).

unrelated_diff_does_not_revalidate_policy_test() ->
    %% Creation/replay establish the invariant. This helper deliberately does
    %% not turn every ordinary write into a policy lookup: an unrelated diff
    %% returns its candidate even for this synthetic policy-less parent.
    Est0 = quod_ct:committed_kb([]),
    {ok, Est1} = quod_diff:apply_ops_preserving_policy(
                   Est0, quod_ct:diff_for({ordinary_fact, true})),
    ?assertNot(policy_present(Est1)).

as_retract({assert, Clause}) -> {retract, Clause}.

policy_present(#est{db = #db{mod = M, ref = R}}) ->
    case M:get_procedure(R, {can_invoke, 4}) of
        {clauses, [_ | _]} -> true;
        _ -> false
    end.

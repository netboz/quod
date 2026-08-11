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
    ?assert(quod_diff:valid_ops([Raw, Compiled])),
    ?assertNot(quod_diff:valid_ops(not_a_list)),
    ?assertNot(quod_diff:valid_ops([Raw | improper_tail])),
    ?assertNot(quod_diff:valid_ops([{replace, {{fact, x}, true}}])),
    ?assertNot(quod_diff:valid_ops([{assert, {42, true}}])),
    ?assertNot(quod_diff:valid_ops([{assert, {{fact, x}, 42}}])),
    ?assertNot(quod_diff:valid_ops(
                 [{assert, {{fact, x}, {[{{cut}, -1, false}], false}}}])),
    ?assertNot(quod_diff:valid_ops(
                 [{assert, {{fact, {1.5}}, true}}])).

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
    ?assertNot(quod_diff:assertion_only([{retract, {{f, x}, true}}])).

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

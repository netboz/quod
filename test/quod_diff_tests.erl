-module(quod_diff_tests).
-include_lib("eunit/include/eunit.hrl").

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

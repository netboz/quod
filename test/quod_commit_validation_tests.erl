-module(quod_commit_validation_tests).

-include_lib("eunit/include/eunit.hrl").

content_check_and_committed_claim_share_one_validator_test() ->
    with_signed_fixture(
      fun(Fixture, Context0) ->
          Transaction = maps:get(transaction, Fixture),
          {ok, valid, Checked} =
              quod_commit_validation:content(
                [Transaction], 1, check, Context0),
          %% A vote check observes but does not reserve the operation.
          ?assertMatch(
             {ok, valid, _},
             quod_commit_validation:content(
               [Transaction], 1, check, Checked)),
          {ok, valid, Claimed} =
              quod_commit_validation:content(
                [Transaction], 1, {claim, 2}, Context0),
          %% The committed slot owns the claim. A later proposal is a
          %% duplicate, while replaying that exact slot stays idempotent.
          ?assertMatch(
             {ok, {invalid, duplicate_operation}, _},
             quod_commit_validation:content(
               [Transaction], 1, check, Claimed)),
          ?assertMatch(
             {ok, valid, _},
             quod_commit_validation:content(
               [Transaction], 1, {claim, 2}, Claimed))
      end).

dtx_begin_check_and_committed_claim_share_one_validator_test() ->
    with_signed_fixture(
      fun(Fixture, Context0) ->
          Control = maps:get(begin_control, Fixture),
          {ok, {valid, CheckHistory}, _Checked} =
              quod_commit_validation:dtx(Control, 1, check, Context0),
          {ok, {valid, ClaimHistory}, Claimed} =
              quod_commit_validation:dtx(
                Control, 1, {claim, 2}, Context0),
          ?assertEqual(CheckHistory, ClaimHistory),
          ?assertMatch(
             {ok, {invalid, duplicate_operation}, _},
             quod_commit_validation:dtx(Control, 1, check, Claimed)),
          ?assertMatch(
             {ok, {valid, _}, _},
             quod_commit_validation:dtx(
               Control, 1, {claim, 2}, Claimed))
      end).

with_signed_fixture(Fun) ->
    Ns = <<"quod:commit-validation">>,
    Anchor = <<221:256>>,
    Network = <<222:256>>,
    Fixture = quod_ct:signed_dtx_begin_fixture(
                #{target => {Ns, Anchor}, network => Network,
                  submitted_at => 1}),
    #{goal := FrozenGoal} = maps:get(evidence, Fixture),
    {ok, Goal} = quod_wire_term:materialize_symbols(FrozenGoal),
    Principal = {user, maps:get(user, Fixture)},
    ParentEst = quod_ct:committed_kb(
                  [{can_invoke, Goal, Principal, [], Ns}]),
    {ok, Outcomes} = quod_outcome:open(
                       Ns, Anchor, #{outcome_backend => memory}),
    Context = quod_commit_validation:new(
                {Ns, Anchor}, 1, ParentEst, Outcomes, none),
    try
        quod_ct:with_network_identity(
          Network, fun() -> Fun(Fixture, Context) end)
    after
        ok = quod_outcome:close(Outcomes)
    end.

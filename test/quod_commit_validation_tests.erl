-module(quod_commit_validation_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

remote_application_uses_one_target_evaluator_for_apply_reject_and_invalid_test() ->
    Fixture = quod_ct:remote_operation_fixture(#{}),
    Application = maps:get(application, Fixture),
    Plan = maps:get(plan, Fixture),
    {TargetNs, TargetAnchor} = maps:get(participant_target, Fixture),
    Signer = maps:get(pubkey, maps:get(node_identity, Fixture)),
    [{_InvocationId, FullChain, GoalBlob, _Verdict, _Answers,
      _ReadDigest, _Tag}] = quod_dtx:transcript(Plan),
    {ok, Goal} = quod_durable_term:decode_goal(GoalBlob),
    {ok, Principal} = quod_agent_ref:materialize_principal(
                        quod_dtx:principal(Plan)),
    CallerNamespaces = [Ns || {Ns, _Anchor} <- tl(FullChain)],
    Policy = {can_invoke, Goal, Principal, CallerNamespaces, TargetNs},
    Member = {peer_admitted, Signer, "validator", 14567, Signer},
    with_context(
      TargetNs, TargetAnchor, [Policy, Member],
      fun(Context) ->
          ?assertMatch(
             {apply, _EventContext, #{diff := [_ | _]}},
             quod_commit_validation:remote_application(Application, Context)),
          ?assertMatch(
             {invalid, _},
             quod_commit_validation:remote_application(
               Application#transaction{tx_id = <<0:256>>}, Context))
      end),
    %% The claim is authentic, but current target policy refuses it.  That is a
    %% durable rejection, not a malformed record which could strand the claim.
    with_context(
      TargetNs, TargetAnchor, [Member],
      fun(Context) ->
          ?assertEqual(
             {reject, not_authorized},
             quod_commit_validation:remote_application(Application, Context))
      end).

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

missing_network_identity_splits_check_from_committed_claim_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    {Fixture, Context, Outcomes} = signed_fixture(),
    try
        without_network_identity(
          fun() ->
              Transaction = maps:get(transaction, Fixture),
              Control = maps:get(begin_control, Fixture),
              ?assertMatch(
                 {ok, abstain, _},
                 quod_commit_validation:content(
                   [Transaction], 1, check, Context)),
              ?assertMatch(
                 {ok, {unavailable, network_identity, not_hosted}, _},
                 quod_commit_validation:content(
                   [Transaction], 1, {claim, 2}, Context)),
              ?assertMatch(
                 {ok, abstain, _},
                 quod_commit_validation:dtx(Control, 1, check, Context)),
              ?assertMatch(
                 {ok, {unavailable, network_identity, not_hosted}, _},
                 quod_commit_validation:dtx(
                   Control, 1, {claim, 2}, Context))
          end)
    after
        ok = quod_outcome:close(Outcomes)
    end.

membership_validation_contract_is_owned_here_test() ->
    Ns = <<"quod:commit-membership">>,
    Anchor = <<223:256>>,
    Candidate = <<224:256>>,
    Host = "member.example",
    Port = 14567,
    Assert = membership_assert(Candidate, Host, Port),
    CanJoin = {can_join, Ns, [Host, Port], Candidate},
    with_context(
      Ns, Anchor, [CanJoin],
      fun(Context) ->
          ?assertMatch(
             {ok, valid, _},
             validate_membership(Ns, Assert, Context))
      end),
    %% Live admission policy is a pre-vote check. A certified record is
    %% projected without consulting this node's current peer_ready state.
    with_context(
      Ns, Anchor, [],
      fun(Context) ->
          ?assertMatch(
             {ok, {invalid, can_join}, _},
             validate_membership(Ns, Assert, Context)),
          ?assertMatch(
             {ok, valid, _},
             validate_committed_membership(Ns, Assert, Context))
      end),
    with_context(
      Ns, Anchor,
      [{peer_admitted, Candidate, Host, Port, Candidate}, CanJoin],
      fun(Context) ->
          ?assertMatch(
             {ok, {invalid, already_admitted}, _},
             validate_membership(Ns, Assert, Context))
      end),
    SideEffectingCanJoin =
        {':-', {can_join, Ns, [Host, Port], Candidate},
               {assertz, {membership_side_effect, true}}},
    with_context(
      Ns, Anchor, [SideEffectingCanJoin],
      fun(Context) ->
          ?assertMatch(
             {ok, {invalid, can_join_side_effects}, _},
             validate_membership(Ns, Assert, Context))
      end),
    Missing = <<225:256>>,
    Retract = membership_retract(Missing, Host, Port),
    with_context(
      Ns, Anchor, [],
      fun(Context) ->
          ?assertMatch(
             {ok, {invalid, no_such_member}, _},
             validate_membership(Ns, Retract, Context))
      end).

prepare_validation_and_materialization_are_owned_here_test() ->
    Fixture = valid_prepare_fixture(),
    {TargetNs, TargetAnchor} = maps:get(participant_target, Fixture),
    Signer = maps:get(pubkey, maps:get(node_identity, Fixture)),
    Control = maps:get(prepare_control, Fixture),
    {ok, Manifest, PlanDigest, PlanBlob} =
        quod_dtx:prepare_payload(Control),
    {ok, Plan} = quod_dtx:decode(PlanBlob),
    [{_InvocationId, FullChain, GoalBlob, _Verdict, _Answers,
      _Digest, _Tag}] = quod_dtx:transcript(Plan),
    {ok, Goal} = quod_durable_term:decode_goal(GoalBlob),
    CallerNamespaces = [Ns || {Ns, _Anchor} <- tl(FullChain)],
    {ok, PolicyPrincipal} = quod_agent_ref:materialize_principal(
                              quod_dtx:principal(Plan)),
    Policy = {can_invoke, Goal, PolicyPrincipal,
              CallerNamespaces, TargetNs},
    Member = {peer_admitted, Signer, "validator", 14567, Signer},
    with_context(
      TargetNs, TargetAnchor,
      quod_ct:signed_agent_facts(Fixture) ++ [Policy, Member],
      fun(Context) ->
          ?assertMatch(
             {ok, {valid, _History}, _},
             quod_commit_validation:dtx(Control, 1, check, Context)),
          ?assertMatch(
             {ok, _EventContext, #{diff := _}},
             quod_commit_validation:prepared_material(
               Manifest, PlanDigest, PlanBlob, Context)),
          %% The successful event-context path owns signature and digest
          %% authentication once. Rejections retain their established public
          %% distinction even though they no longer share the hot path.
          {quod_plan, Core, PlanSigner, _Signature} = Plan,
          {ok, BadSignatureBlob} = quod_dtx:encode(
                                     {quod_plan, Core, PlanSigner,
                                      <<0:512>>}),
          ?assertEqual(
             {error, bad_plan_binding},
             quod_commit_validation:prepared_material(
               Manifest, PlanDigest, BadSignatureBlob, Context)),
          ?assertEqual(
             {error, bad_manifest_binding},
             quod_commit_validation:prepared_material(
               Manifest, <<0:256>>, PlanBlob, Context))
      end),
    with_context(
      TargetNs, TargetAnchor, [Policy],
      fun(Context) ->
          ?assertMatch(
             {ok, {invalid, [signer_not_admitted]}, _},
             quod_commit_validation:dtx(Control, 1, check, Context))
      end).

external_predicate_manifest_is_immutable_after_genesis_test() ->
    Ns = <<"quod:immutable-predicate-manifest">>,
    Anchor = <<229:256>>,
    Diff = quod_ct:diff_for({external_predicate_modules, []}),
    with_context(
      Ns, Anchor, [],
      fun(Context) ->
          ?assertMatch(
             {ok, {invalid, immutable_external_predicate_manifest}, _},
             quod_commit_validation:content(
               [quod_ct:change(Ns, Diff, #{})], 1, check, Context))
      end).

dtx_prepare_cannot_change_external_predicate_manifest_test() ->
    Fixture = valid_prepare_fixture(
                #{goal_text =>
                      <<"assertz(external_predicate_modules([])).">>}),
    {TargetNs, TargetAnchor} = maps:get(participant_target, Fixture),
    Signer = maps:get(pubkey, maps:get(node_identity, Fixture)),
    Control = maps:get(prepare_control, Fixture),
    #{goal := FrozenGoal} = maps:get(evidence, Fixture),
    {ok, Goal} = quod_wire_term:materialize_symbols(FrozenGoal),
    {ok, Principal} = quod_agent_ref:materialize_principal(
                        maps:get(principal, Fixture)),
    Policy = {can_invoke, Goal, Principal, [], TargetNs},
    Member = {peer_admitted, Signer, "validator", 14567, Signer},
    with_context(
      TargetNs, TargetAnchor,
      quod_ct:signed_agent_facts(Fixture) ++ [Policy, Member],
      fun(Context) ->
          ?assertMatch(
             {ok, {invalid,
                   [immutable_external_predicate_manifest]}, _},
             quod_commit_validation:dtx(Control, 1, check, Context))
      end).

with_signed_fixture(Fun) ->
    {Fixture, Context, Outcomes} = signed_fixture(),
    Network = maps:get(network, Fixture),
    try
        quod_ct:with_network_identity(
          Network, fun() -> Fun(Fixture, Context) end)
    after
        ok = quod_outcome:close(Outcomes)
    end.

signed_fixture() ->
    Ns = <<"quod:commit-validation">>,
    Anchor = <<221:256>>,
    Network = <<222:256>>,
    Fixture = quod_ct:signed_dtx_begin_fixture(
                #{target => {Ns, Anchor}, network => Network,
                  submitted_at => 1}),
    #{goal := FrozenGoal} = maps:get(evidence, Fixture),
    {ok, Goal} = quod_wire_term:materialize_symbols(FrozenGoal),
    {ok, Principal} = quod_agent_ref:materialize_principal(
                        maps:get(principal, Fixture)),
    ParentEst = quod_ct:committed_kb(
                  quod_ct:signed_agent_facts(Fixture) ++
                  [{can_invoke, Goal, Principal, [], Ns},
                   {peer_admitted,
                    maps:get(pubkey, maps:get(node_identity, Fixture)),
                    "validator", 14567,
                    maps:get(pubkey, maps:get(node_identity, Fixture))}]),
    {ok, Outcomes} = quod_outcome:open(
                       Ns, Anchor, #{outcome_backend => memory}),
    Context = quod_commit_validation:new(
                {Ns, Anchor}, 1, ParentEst, Outcomes, none),
    {Fixture, Context, Outcomes}.

without_network_identity(Fun) ->
    Root = quod_ontology:root_ns(),
    undefined = quod_reg:where({quod_simplex, Root}),
    SavedDesired = application:get_env(quod, namespace_desired),
    Desired0 = application:get_env(quod, namespace_desired, #{}),
    Content0 = maps:get(content, Desired0, #{}),
    application:set_env(
      quod, namespace_desired,
      Desired0#{content => maps:remove(Root, Content0)}),
    try
        Fun()
    after
        case SavedDesired of
            {ok, Desired} ->
                application:set_env(quod, namespace_desired, Desired);
            undefined ->
                application:unset_env(quod, namespace_desired)
        end
    end.

valid_prepare_fixture() ->
    valid_prepare_fixture(#{}).

valid_prepare_fixture(Overrides) ->
    Target = {<<"quod:commit-prepare">>, <<226:256>>},
    Origin = {<<"quod:commit-origin">>, <<225:256>>},
    Fixture0 = quod_ct:signed_dtx_begin_fixture(
                 maps:merge(
                   #{target => Origin, participant_target => Target,
                     network => <<227:256>>,
                     submitted_at => 1},
                   Overrides)),
    Begin = maps:get('begin', Fixture0),
    {ok, BeginRef} = quod_dtx:certified_ref(
                       element(1, Origin), element(2, Origin), 1, <<228:256>>,
                       quod_dtx:group_id(Begin), <<"qc">>),
    {ok, Prepare} = quod_dtx:new_prepare(Begin, BeginRef, Target),
    {ok, PrepareControl} = quod_dtx:sign_control(
                             Target, Prepare, maps:get(admission, Fixture0),
                             1, 1, maps:get(node_identity, Fixture0)),
    Fixture0#{prepare => Prepare, prepare_control => PrepareControl}.

with_context(Ns, Anchor, Facts, Fun) ->
    ParentEst = quod_ct:committed_kb(Facts),
    {ok, Outcomes} = quod_outcome:open(
                       Ns, Anchor, #{outcome_backend => memory}),
    Context = quod_commit_validation:new(
                {Ns, Anchor}, 1, ParentEst, Outcomes, none),
    try Fun(Context)
    after ok = quod_outcome:close(Outcomes)
    end.

validate_membership(Ns, Diff, Context) ->
    Change = quod_ct:change(Ns, Diff, #{}),
    quod_commit_validation:content([Change], 1, check, Context).

validate_committed_membership(Ns, Diff, Context) ->
    Change = quod_ct:change(Ns, Diff, #{}),
    quod_commit_validation:content([Change], 1, {claim, 2}, Context).

membership_assert(Pubkey, Host, Port) ->
    quod_ct:diff_for({peer_admitted, Pubkey, Host, Port, Pubkey}).

membership_retract(Pubkey, Host, Port) ->
    [{assert, Clause}] = quod_ct:diff_for(
                           {peer_admitted, Pubkey, Host, Port, Pubkey}),
    [{retract, Clause}].

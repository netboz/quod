-module(quod_commit_validation_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

receipt_application_envelope_equality_ignores_symbol_representation_test() ->
    F = quod_ct:remote_operation_fixture(#{receipt_kind => certified,
      goal_text => <<"\\+(receipt_absent(ok)), assertz(saved(ok)).">>}),
    App = maps:get(application, F), Ref = maps:get(certified_target_ref, F),
    Wrapped = App#transaction{read_check = maps:from_list([
      {{{'$quod_symbol', atom_to_binary(Name, utf8)}, Arity}, Value}
      || {{Name, Arity}, Value} <- maps:to_list(App#transaction.read_check)])},
    ?assertNotEqual(App, Wrapped),
    ?assert(quod_transaction:same_ledger_transaction(App, Wrapped)),
    Complete0 = maps:get(completion, F),
    Complete = Complete0#transaction{evidence = {applications, [{Ref, Wrapped}]}},
    Exact = #{identity => maps:get(participant_target, F), phase => transaction,
      slot => 3, block_hash => <<214:256>>, committee_id => <<215:256>>,
      transaction => App, committee => [maps:get(pubkey, maps:get(node_identity, F))]},
    quod_ct:with_network_identity(maps:get(network, F), fun() ->
        ?assertEqual(ok, quod_commit_validation:validate_evidence(Complete, #{Ref => Exact})),
        ?assertEqual({error, operation_receipt_reference_binding},
          quod_commit_validation:validate_evidence(Complete, #{})),
        ?assertEqual({error, operation_receipt_reference_binding},
          quod_commit_validation:validate_evidence(Complete, #{Ref => Exact#{transaction := App#transaction{sig = <<0:512>>}}}))
    end).

inclusion_only_receipts_are_refused_in_admission_and_replay_test() ->
        F = quod_ct:remote_operation_fixture(#{}),
        Origin = {Ns, Anchor} = maps:get(origin, F),
        Completion = maps:get(completion, F),
        {ok, ClaimData} = quod_transaction:request_claim(maps:get(claim, F)),
        Op = maps:get(operation_ref, ClaimData),
        {ok, I0} = quod_outcome:open(Ns, Anchor, #{outcome_backend => memory}),
        try
            {new, I1} = quod_outcome:claim_operation(
                         I0, 2, ClaimData, {applications, [maps:get(target_ref, F)]}),
            C0 = quod_commit_validation:new(Origin, 1, quod_ct:committed_kb([]), I1, none, none),
            #transaction{role = {remote_complete, Op, Digest, _}} = Completion,
            TargetRef = maps:get(target_ref, F),
            Old = Completion#transaction{role = {remote_complete, Op, Digest,
                      [{maps:get(participant_target, F), {included, TargetRef}}]}},
            %% Current admission and projection share one format. Neither
            %% accepts old inclusion-only receipts during the clean break.
            [?assertEqual({outcome_error, outcome_index_bad_operation},
                quod_commit_validation:content([Old], 1, Mode, C0))
             || Mode <- [check, {claim, 4}]],
            ?assertEqual({error, invalid_operation_receipt},
                         quod_commit_validation:validate_evidence(Old, #{})),
            {ok, valid, Checked} = quod_commit_validation:content([Completion], 1, check, C0),
            {{ok, #{state := unresolved}}, _} = quod_outcome:lookup_ref(
                                                quod_commit_validation:outcomes(Checked), Op),
            {ok, valid, Replayed} = quod_commit_validation:content(
                                      [Completion], 1, {claim, 4}, C0),
            {{ok, #{state := {terminal, 4}}}, _} = quod_outcome:lookup_ref(
                                                  quod_commit_validation:outcomes(Replayed), Op),
            {ok, valid, _} = quod_commit_validation:content([Completion], 1, check, Replayed)
        after ok = quod_outcome:close(I0) end.

read_certificate(ProofId, N) ->
    Target = {<<"quod:certified-read-", (integer_to_binary(N))/binary>>,
              <<N:256>>},
    {Ns, Anchor} = Target,
    {Signer, Seed} = quod_identity:generate(),
    Identity = #{pubkey => Signer,
                 key => quod_identity:key_term({Signer, Seed})},
    {ok, AnchorRef} = quod_dtx:certified_ref(
                        Ns, Anchor, 2, <<(N + 100):256>>, <<(N + 200):256>>,
                        quod_ct:fixture_finality(1, <<(N + 100):256>>)),
    PlanDigest = <<(N + 300):256>>,
    CommitteeId = <<(N + 400):256>>,
    {ok, Vote} = quod_read_certificate:sign(
                   Target, ProofId, PlanDigest, AnchorRef, CommitteeId,
                   Identity),
    {ok, Certificate} = quod_read_certificate:new(
                          Target, ProofId, PlanDigest, AnchorRef, CommitteeId,
                          [Vote]),
    Evidence = #{identity => Target, committee => [Signer],
                 committee_id => CommitteeId},
    {Certificate, AnchorRef, Evidence}.

foreign_read_certificates_use_exact_reference_committees_test() ->
    ProofId = <<71:256>>,
    {CertificateA, RefA, EvidenceA} = read_certificate(ProofId, 72),
    {CertificateB, RefB, EvidenceB} = read_certificate(ProofId, 73),
    Transaction = #transaction{tx_id = <<>>, role = application,
                               foreign_reads = lists:sort(
                                                 [CertificateA, CertificateB]),
                               origin = {<<"quod:writer">>, <<74:256>>},
                               proof_id = ProofId, plan_digest = <<75:256>>,
                               goal = <<>>, result = <<>>, diff = [],
                               read_check = #{}, effects = []},
    Evidence = #{RefA => EvidenceA, RefB => EvidenceB},
    ?assertEqual(ok, quod_commit_validation:validate_evidence(
                       Transaction, Evidence)),
    ?assertEqual(
       {error, foreign_read_reference_binding},
       quod_commit_validation:validate_evidence(
         Transaction, maps:remove(RefB, Evidence))),
    ?assertEqual(
       {error, foreign_read_reference_binding},
       quod_commit_validation:validate_evidence(
         Transaction,
         Evidence#{RefA := EvidenceA#{committee_id => <<0:256>>}})),
    ?assertEqual(
       {error, foreign_read_proof_binding},
       quod_commit_validation:validate_evidence(
         Transaction#transaction{proof_id = <<76:256>>}, Evidence)),
    #{committee := [_Signer]} = EvidenceA,
    ?assertEqual(
       {error, invalid_foreign_read_certificate},
       quod_commit_validation:validate_evidence(
         Transaction, Evidence#{RefA := EvidenceA#{committee => []}})).

remote_completion_cannot_carry_foreign_reads_test() ->
    ProofId = <<77:256>>,
    {Certificate, _Ref, _Evidence} = read_certificate(ProofId, 78),
    Completion = #transaction{tx_id = <<>>, role = {remote_complete, op,
                                                     <<79:256>>, target},
                              foreign_reads = [Certificate],
                              origin = {<<"quod:writer">>, <<80:256>>},
                              proof_id = ProofId, plan_digest = <<81:256>>,
                              goal = <<>>, result = <<>>, diff = [],
                              read_check = #{}, effects = []},
    ?assertEqual(
       {error, invalid_operation_receipt},
       quod_commit_validation:validate_evidence(Completion, #{})).

duplicate_remote_completion_is_valid_and_keeps_first_terminal_slot_test() ->
    Fixture = quod_ct:remote_operation_fixture(#{receipt_kind => certified}),
    Origin = {Ns, Anchor} = maps:get(origin, Fixture),
    Claim = maps:get(claim, Fixture),
    Completion = maps:get(completion, Fixture),
    TargetRef = maps:get(target_ref, Fixture),
    {ok, ClaimData} = quod_transaction:request_claim(Claim),
    OperationRef = maps:get(operation_ref, ClaimData),
    {ok, Outcomes0} = quod_outcome:open(
                        Ns, Anchor, #{outcome_backend => memory}),
    {new, Outcomes1} = quod_outcome:claim_operation(
                         Outcomes0, 2, ClaimData, {applications, [TargetRef]}),
    Context0 = quod_commit_validation:new(
                 Origin, 1, quod_ct:committed_kb([]), Outcomes1, none, none),
    try
        {ok, valid, Context1} = quod_commit_validation:content(
                                  [Completion], 1, {claim, 4}, Context0),
        %% Two validators may submit the same deterministic receipt before
        %% slot 4 is applied. Once either copy commits, the other candidate
        %% must remain valid: rejecting that already-in-flight receipt skips
        %% consensus slots and can starve unrelated source claims. The exact
        %% operation, digest, and target binding make only a byte-equivalent
        %% receipt a replay.
        {ok, valid, Checked} = quod_commit_validation:content(
                                 [Completion], 1, check, Context1),
        {ok, valid, Context2} = quod_commit_validation:content(
                                  [Completion], 1, {claim, 5}, Checked),
        {{ok, #{state := {terminal, 4}}}, _} = quod_outcome:lookup_ref(
                                                  quod_commit_validation:outcomes(
                                                    Context2),
                                                  OperationRef)
    after
        ok = quod_outcome:close(Outcomes0)
    end.

non_identical_remote_completion_remains_invalid_in_proposal_check_test() ->
    Fixture = quod_ct:remote_operation_fixture(#{receipt_kind => certified}),
    Origin = {Ns, Anchor} = maps:get(origin, Fixture),
    Claim = maps:get(claim, Fixture),
    Completion = maps:get(completion, Fixture),
    TargetRef = maps:get(target_ref, Fixture),
    {ok, ClaimData} = quod_transaction:request_claim(Claim),
    OperationRef = maps:get(operation_ref, ClaimData),
    RequestDigest = maps:get(digest, ClaimData),
    {ok, Outcomes0} = quod_outcome:open(
                        Ns, Anchor, #{outcome_backend => memory}),
    {new, Outcomes1} = quod_outcome:claim_operation(
                         Outcomes0, 2, ClaimData, {applications, [TargetRef]}),
    Context0 = quod_commit_validation:new(
                 Origin, 1, quod_ct:committed_kb([]), Outcomes1, none, none),
    try
        {ok, valid, Terminal} = quod_commit_validation:content(
                                  [Completion], 1, {claim, 4}, Context0),
        {transaction, TargetNs, TargetAnchor, _TargetTxId} = TargetRef,
        DifferentTarget = {transaction, TargetNs, TargetAnchor,
                           key(different_target)},
        {ok, DifferentReceipt} = quod_ct:certified_receipt([DifferentTarget]),
        #transaction{role = {remote_complete, _, _, Receipt}} = Completion,
        DifferentTargetCompletion = Completion#transaction{
          role = {remote_complete, OperationRef,
                  RequestDigest, DifferentReceipt}},
        DifferentDigestCompletion = Completion#transaction{
          role = {remote_complete, OperationRef,
                  key(different_digest), Receipt}},
        {operation, OperationNs, OperationAnchor,
         AgentRef, _OperationId} = OperationRef,
        DifferentOperation = {operation, OperationNs, OperationAnchor,
                              AgentRef, key(different_operation)},
        DifferentOperationCompletion = Completion#transaction{
          role = {remote_complete, DifferentOperation,
                  RequestDigest, Receipt}},
        ?assertEqual(
           {outcome_error, outcome_index_conflict},
           quod_commit_validation:content(
             [DifferentTargetCompletion], 1, check, Terminal)),
        ?assertEqual(
           {outcome_error, outcome_index_conflict},
           quod_commit_validation:content(
             [DifferentDigestCompletion], 1, check, Terminal)),
        ?assertEqual(
           {outcome_error, outcome_index_bad_operation},
           quod_commit_validation:content(
             [DifferentOperationCompletion], 1, check, Terminal))
    after
        ok = quod_outcome:close(Outcomes0)
    end.

remote_application_uses_one_target_evaluator_for_apply_reject_and_invalid_test() ->
    Fixture = quod_ct:remote_operation_fixture(#{}),
    Application = maps:get(application, Fixture),
    Plan = maps:get(plan, Fixture),
    {TargetNs, TargetAnchor} = maps:get(participant_target, Fixture),
    Signer = maps:get(pubkey, maps:get(node_identity, Fixture)),
    [{_InvocationId, FullChain, GoalBlob, _Verdict, _Answers,
      _ReadDigest, _Tag}] = quod_ct:plan_material(transcript, Plan),
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

source_vote_check_and_committed_claim_share_one_validator_test() ->
    with_signed_fixture(
      fun(Fixture, Context0) ->
          Control = maps:get(vote_control, Fixture),
          {ok, {valid, CheckHistory}, _Checked} =
              quod_commit_validation:dtx(Control, 1, check, Context0),
          {ok, {valid, ClaimHistory}, Claimed} =
              quod_commit_validation:dtx(
                Control, 1, {claim, 2}, Context0),
          ?assertEqual(CheckHistory, ClaimHistory),
          %% The same source vote claims this request for the same group.
          %% Exact redelivery stays valid; a different group's claim is
          %% covered by the source-claim conflict projection controls.
          ?assertMatch(
             {ok, {valid, _}, _},
             quod_commit_validation:dtx(Control, 1, check, Claimed)),
          ?assertMatch(
             {ok, {valid, _}, _},
             quod_commit_validation:dtx(
               Control, 1, {claim, 2}, Claimed))
      end).

expired_request_cannot_acquire_a_first_source_claim_test() ->
    with_signed_fixture(fun(Fixture, Context) ->
        Deadline = maps:get(deadline, Fixture),
        Transaction = maps:get(transaction, Fixture),
        Vote = maps:get(vote_control, Fixture),
        Operation = maps:get(operation_ref, Fixture),
        %% Admission uses certified block time, including the exact boundary.
        %% Wall-clock expiry alone is deliberately not a terminal outcome.
        ?assertMatch({ok, valid, _}, quod_commit_validation:content(
            [Transaction], Deadline, check, Context)),
        ?assertMatch({ok, {valid, _}, _}, quod_commit_validation:dtx(
            Vote, Deadline, check, Context)),
        {ok, {invalid, _}, ContentAfter} = quod_commit_validation:content(
            [Transaction], Deadline + 1, {claim, 2}, Context),
        {ok, {invalid, _}, VoteAfter} = quod_commit_validation:dtx(
            Vote, Deadline + 1, {claim, 2}, Context),
        [?assertMatch({not_found, _}, quod_outcome:lookup_ref(
            quod_commit_validation:outcomes(C), Operation))
            || C <- [ContentAfter, VoteAfter]],
        %% A previously prepared source remains claimed after expiry, even
        %% before Resolve/Complete. It must never satisfy an absence proof.
        {ok, {valid, _}, Prepared} = quod_commit_validation:dtx(
            Vote, Deadline, {claim, 2}, Context),
        {ok, GroupRef} = quod_atomic:source_group_ref(quod_atomic:control_material(Vote)),
        ?assertMatch({{ok, #{first_slot := 2, outcome_ref := GroupRef}}, _},
            quod_outcome:lookup_ref(quod_commit_validation:outcomes(Prepared), Operation)),
        %% Historical revalidation retains its original certified timestamp.
        ?assertMatch({ok, {valid, _}, _}, quod_commit_validation:dtx(
            Vote, Deadline, {claim, 2}, Prepared))
    end).

expired_independent_source_claim_is_not_admissible_test() ->
    Fixture = quod_ct:remote_operation_fixture(#{}),
    Claim = maps:get(claim, Fixture),
    Deadline = maps:get(deadline, Fixture),
    Network = maps:get(network, Fixture),
    Origin = maps:get(origin, Fixture),
    ?assertMatch({ok, _}, quod_transaction:validate_request(
        Network, Origin, Deadline, Claim)),
    ?assertEqual({error, expired}, quod_transaction:validate_request(
        Network, Origin, Deadline + 1, Claim)).

missing_network_identity_splits_check_from_committed_claim_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    {Fixture, Context, Outcomes} = signed_fixture(),
    try
        without_network_identity(
          fun() ->
              Transaction = maps:get(transaction, Fixture),
              Control = maps:get(vote_control, Fixture),
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

captured_network_survives_readiness_loss_in_content_and_vote_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    {Fixture, Context, Outcomes} = signed_fixture(),
    Network = maps:get(network, Fixture),
    Transaction = maps:get(transaction, Fixture),
    Control = maps:get(vote_control, Fixture),
    try
        {Content, Vote} = quod_ct:with_network_identity(Network, fun() ->
            {ok, valid, C} = quod_commit_validation:content([Transaction], 1, check, Context),
            {ok, {valid, _}, V} = quod_commit_validation:dtx(Control, 1, check, Context),
            {C, V}
        end),
        ?assertEqual(Network, quod_commit_validation:network(Content)),
        ?assertEqual(Network, quod_commit_validation:network(Vote)),
        without_network_identity(fun() ->
            quod_lobby_tests:assert_read_has_no_io(fun() ->
                lists:foreach(fun(_) ->
                    ?assertMatch({ok, valid, _},
                        quod_commit_validation:content([Transaction], 1, check, Content)),
                    ?assertMatch({ok, {valid, _}, _},
                        quod_commit_validation:dtx(Control, 1, check, Vote))
                end, lists:seq(1, 20))
            end),
            %% Captured trust still checks the request's network; it does not
            %% take the embedded request's network as authority.
            Other = quod_ct:signed_atomic_fixture(#{target => maps:get(target, Fixture),
                network => <<223:256>>, submitted_at => 1}),
            ?assertMatch({ok, {invalid, invalid_request_auth}, _},
                quod_commit_validation:content([maps:get(transaction, Other)], 1, check, Content))
        end)
    after
        ok = quod_outcome:close(Outcomes)
    end.

membership_validation_contract_is_owned_here_test_() ->
    [{atom_to_list(Kind), fun() -> membership_validation_contract(Kind) end}
     || Kind <- [assert, asserta]].

membership_validation_contract(Kind) ->
    Ns = <<"quod:commit-membership">>,
    Anchor = <<223:256>>,
    Candidate = <<224:256>>,
    Host = "member.example",
    Port = 14567,
    [{assert, Clause}] = membership_assert(Candidate, Host, Port),
    Assert = [{Kind, Clause}],
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

vote_validation_and_materialization_are_owned_here_test() ->
    Fixture = valid_vote_fixture(),
    {TargetNs, TargetAnchor} = maps:get(participant_target, Fixture),
    Signer = maps:get(pubkey, maps:get(node_identity, Fixture)),
    Control = maps:get(vote_control, Fixture),
    Material = {Vote, _, _} = quod_atomic:control_material(Control),
    {quod_dtx_vote, 4, _, _, Bundle, prepared} = Vote,
    Plan = maps:get(plan, Fixture),
    [{_InvocationId, FullChain, GoalBlob, _Verdict, _Answers,
      _Digest, _Tag}] = quod_ct:plan_material(transcript, Plan),
    {ok, Goal} = quod_durable_term:decode_goal(GoalBlob),
    CallerNamespaces = [Ns || {Ns, _Anchor} <- tl(FullChain)],
    {ok, PolicyPrincipal} = quod_agent_ref:materialize_principal(
                              quod_dtx:principal(Plan)),
    Policy = {can_invoke, Goal, PolicyPrincipal,
              CallerNamespaces, TargetNs},
    Member = {peer_admitted, Signer, "validator", 14567, Signer},
    quod_ct:with_network_identity(maps:get(network, Fixture), fun() -> with_context(
      TargetNs, TargetAnchor,
      quod_ct:signed_agent_facts(Fixture) ++ [Policy, Member],
      fun(Context) ->
          ?assertMatch(
             {ok, {valid, _History}, _},
             quod_commit_validation:dtx(Control, 1, check, Context)),
          ?assertMatch(
             {ok, _EventContext, #{diff := _}},
             quod_commit_validation:prepared_material(Material)),
          %% Authentication belongs to the single ingress decoder, not the
          %% reducer's materializer. Neither a signature nor digest mismatch
          %% may produce the trusted material consumed above.
          {quod_plan, Core, PlanSigner, _Signature} = Plan,
          {ok, BadSignatureBlob} = quod_dtx:encode(
                                     {quod_plan, Core, PlanSigner,
                                      <<0:512>>}),
          ?assertEqual(
             error, quod_atomic:admission_material(
               setelement(5, Vote, setelement(3, Bundle, BadSignatureBlob)))),
          ?assertEqual(
             error, quod_atomic:admission_material(
               setelement(5, Vote, setelement(2, Bundle, <<0:256>>))))
      end),
    with_context(
      TargetNs, TargetAnchor, [Policy],
      fun(Context) ->
          ?assertMatch(
             {ok, {invalid, {atomic_vote_choice, {refused, [signer_not_admitted]}}}, _},
             quod_commit_validation:dtx(Control, 1, check, Context))
      end) end).

expiry_remote_application_captures_network_before_its_second_check_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    F = quod_ct:remote_operation_fixture(#{}),
    Origin = {OriginNs, OriginAnchor} = maps:get(origin, F),
    Target = {Ns, Anchor} = maps:get(participant_target, F),
    Network = maps:get(network, F), Signer = maps:get(node_identity, F),
    Pub = maps:get(pubkey, Signer), Admission = maps:get(admission, F),
    Old = quod_ct:signed_goal_fixture(#{target => Target, network => Network, deadline => 10}),
    {operation, _, _, Agent, Id} = maps:get(operation_ref, Old),
    Key = {2, Agent, Id}, Token = {maps:get(request_bytes, Old), 2, 11},
    P0 = maps:get(plan, F),
    Plan = with_outcome_read(setelement(2, P0, (quod_dtx:core(P0))#{base_height := 2}), Key, Token, Signer),
    {ok, Manifest} = quod_dtx:new_manifest(#{proof_id => maps:get(proof_id, F),
        coordinator => {OriginNs, OriginAnchor, Pub, Admission}, nonce => <<207:256>>,
        principal => maps:get(principal, F), goal => maps:get(goal_blob, F),
        result => maps:get(result_blob, F), request_binding => maps:get(binding, F),
        vote_deadline_ms => none, participants => [{Target, quod_dtx:digest(Plan)}]}),
    {ok, Attestation} = quod_dtx:attest_plan(1, Target, Plan, Manifest, Signer),
    {ok, Blob} = quod_dtx:encode(Plan),
    Claim0 = quod_transaction:remote_claim(Origin, Manifest,
        [{Target, quod_dtx:digest(Plan), Blob, Attestation}], maps:get(auth, F), []),
    {ok, Claim} = quod_transaction:sign({OriginNs, OriginAnchor, Admission},
        Claim0#transaction{author = Pub, author_seq = 1, submitted_at = 1}, Signer),
    ClaimRef = {transaction, OriginNs, OriginAnchor, Claim#transaction.tx_id},
    {ok, CertifiedRef} = quod_dtx:certified_ref(OriginNs, OriginAnchor, 2, <<213:256>>,
        Claim#transaction.tx_id, quod_ct:fixture_finality(1, <<213:256>>)),
    App0 = quod_transaction:attach_evidence(
        quod_transaction:remote_application(ClaimRef, Claim, Target), CertifiedRef, Claim),
    {ok, App} = quod_transaction:sign({Ns, Anchor, Admission},
        App0#transaction{author = Pub, author_seq = 1, submitted_at = 12}, Signer),
    ?assertEqual(quod_ct:plan_material(read_check, Plan), App#transaction.read_check),
    ?assertEqual(Token, maps:get(Key, App#transaction.read_check)),
    ?assertEqual(none, App#transaction.request_auth),
    Est = quod_ct:committed_kb([{can_invoke, {'G'}, {'P'}, {'C'}, Ns},
                              {peer_admitted, Pub, "validator", 14567, Pub}]),
    {ok, I0} = quod_outcome:open(Ns, Anchor, #{outcome_backend => memory}),
    {ok, I1} = quod_outcome:advance_applied(I0, 1, 0),
    {ok, I2} = quod_outcome:advance_applied(I1, 2, 11), {ok, I3} = quod_outcome:flush(I2),
    Ctx = quod_commit_validation:new(Target, 2, Est, I3, none, none),
    Projection = quod_committed_projection:new(Target, 2, Est, I3, none),
    Era = quod_ledger:initial_era(Target),
    {ok, Block} = quod_ledger:new_block({Era, 2}, {Era, 1, <<0:256>>}, 3, {batch, [App]}, 12),
    Cert = #cert{kind = commit, era = Era, slot = 2,
        block_hash = quod_simplex:block_hash(Block), sigs = [{<<1:256>>, <<0:512>>}]},
    Entry = quod_ledger:entry(3, Block, Cert),
    try
        without_network_identity(fun() ->
            ?assertMatch({unavailable, network_identity, _}, quod_commit_validation:remote_application(App, Ctx)),
            ?assertMatch({ok, abstain, _}, quod_commit_validation:content([App], 12, check, Ctx)),
            ?assertMatch({wait, network_identity, _, Projection},
                         quod_committed_projection:apply_entry(Entry, 3, Projection)),
            ?assertMatch({invalid, _}, quod_commit_validation:remote_application(App#transaction{read_check = #{}}, Ctx))
        end),
        quod_ct:with_network_identity(Network, fun() ->
            ?assertMatch({apply, _, _}, quod_commit_validation:remote_application(App, Ctx)),
            {ok, Next, #{transactions := [#{status := applied}]}} =
                quod_committed_projection:apply_entry(Entry, 3, Projection),
            ?assertMatch({ok, _, _, _}, quod_prolog:prove_est({saved, ok}, quod_committed_projection:est(Next)))
        end)
    after quod_outcome:close(I0) end.

expiry_read_uses_certification_and_vote_admission_owners_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    F = quod_ct:signed_atomic_fixture(#{goal_text => <<"\\+(missing(ok)).">>}),
    Target = {Ns, Anchor} = maps:get(origin, F), Network = maps:get(network, F),
    Signer = maps:get(node_identity, F), Pub = maps:get(pubkey, Signer),
    Old = quod_ct:signed_goal_fixture(#{target => Target, network => Network, deadline => 10}),
    Bytes = maps:get(request_bytes, Old),
    {operation, _, _, Agent, Id} = maps:get(operation_ref, Old),
    Key = {2, Agent, Id}, Token = {Bytes, 2, 11},
    P0 = maps:get(plan, F),
    Plan = with_outcome_read(setelement(2, P0, (quod_dtx:core(P0))#{base_height := 2}), Key, Token, Signer),
    Est = quod_ct:committed_kb(quod_ct:signed_agent_facts(F) ++
        [{can_invoke, {'G'}, {'P'}, {'C'}, Ns}, {peer_admitted, Pub, "validator", 14567, Pub}]),
    {ok, I0} = quod_outcome:open(Ns, Anchor, #{outcome_backend => memory}),
    {ok, I1} = quod_outcome:advance_applied(I0, 1, 0),
    {ok, I2} = quod_outcome:advance_applied(I1, 2, 11), {ok, I3} = quod_outcome:flush(I2),
    Ctx = quod_commit_validation:new(Target, 2, Est, I3, none, none),
    Plans = (maps:get(plans, F))#{Target := Plan},
    {ok, Manifest} = quod_dtx:new_manifest(#{proof_id => maps:get(proof_id, F),
        coordinator => {Ns, Anchor, Pub, maps:get(admission, F)}, nonce => <<207:256>>,
        principal => maps:get(principal, F), goal => maps:get(goal_blob, F),
        result => maps:get(result_blob, F), request_binding => maps:get(binding, F),
        vote_deadline_ms => maps:get(deadline, F),
        participants => [{T, quod_dtx:digest(P)} || {T, P} <- maps:to_list(Plans)]}),
    {ok, Attestation} = quod_dtx:attest_plan(1, Target, Plan, Manifest, Signer),
    {ok, Group} = quod_atomic:new_group(Manifest, maps:get(auth, F), Attestation),
    {ok, Blob} = quod_dtx:encode(Plan),
    {ok, Vote} = quod_atomic:new_vote(Group, Target,
        {Target, quod_dtx:digest(Plan), Blob, Attestation}, prepared),
    {ok, Material} = quod_atomic:admission_material(Vote),
    {ok, Control} = quod_atomic:sign_control(Target, Material, maps:get(admission, F), 1, 12, Signer),
    try
        without_network_identity(fun() ->
            ?assertMatch({error, {unavailable, network_identity, _}},
                         quod_commit_validation:read_only_plan(Plan, Ctx)),
            ?assertMatch({ok, {selection, abstain, _}, _},
                         quod_commit_validation:prepare_vote(Material, 12, Ctx)),
            ?assertMatch({ok, {unavailable, network_identity, _}, _},
                         quod_commit_validation:dtx(Control, 12, {claim, 3}, Ctx))
        end),
        quod_ct:with_network_identity(Network, fun() ->
            ?assertEqual(ok, quod_commit_validation:read_only_plan(Plan, Ctx)),
            {ok, {selection, {vote, Material}, _}, Captured} =
                quod_commit_validation:prepare_vote(Material, 12, Ctx),
            ?assertEqual(Network, quod_commit_validation:network(Captured)),
            ?assertMatch({ok, {valid, _}, _}, quod_commit_validation:dtx(Control, 12, {claim, 3}, Ctx)),
            Bad = with_outcome_read(Plan, Key, {Bytes, 2, 12}, Signer),
            ?assertEqual({error, conflict_retry}, quod_commit_validation:read_only_plan(Bad, Ctx))
        end)
    after quod_outcome:close(I0) end.

read_certificate_validates_terminal_outcome_evidence_test() ->
    Fixture = valid_vote_fixture(#{goal_text => <<"\\+(missing(ok)).">>}),
    Target = {Ns,Anchor} = maps:get(participant_target,Fixture),
    Signer = maps:get(node_identity,Fixture),Pub = maps:get(pubkey,Signer),
    Plan0 = maps:get(plan,Fixture),
    [{_,Chain,GoalBlob,_,_,_,_}] = quod_ct:plan_material(transcript,Plan0),
    {ok,Goal} = quod_durable_term:decode_goal(GoalBlob),
    {ok,Principal} = quod_agent_ref:materialize_principal(maps:get(principal,Fixture)),
    Est = quod_ct:committed_kb(quod_ct:signed_agent_facts(Fixture) ++
        [{can_invoke,Goal,Principal,[N || {N,_} <- tl(Chain)],Ns},
         {peer_admitted,Pub,"validator",14567,Pub}]),
    Original = quod_ct:signed_atomic_fixture(#{target => Target}),
    T = maps:get(transaction,Original),
    {ok,Claim} = quod_transaction:request_claim(T),
    {operation,_,_,Agent,Id} = maps:get(operation_ref,Claim),Key = {1,Agent,Id},
    {ok,I0} = quod_outcome:open(Ns,Anchor,#{outcome_backend => memory}),
    {new,I1} = quod_outcome:claim_operation(I0,1,Claim,{transaction,Ns,Anchor,T#transaction.tx_id}),
    {new,Candidate,I2} = quod_outcome:classify(I1,T),
    {new,_,I3} = quod_outcome:terminal(I2,1,{rejected,conflict_retry},{new,Candidate}),
    {ok,I4} = quod_outcome:advance_applied(I3, 1, 1),{ok,I5} = quod_outcome:flush(I4),
    {{ok,Token},I6} = quod_outcome:operation_dependency(I5,Key,1),
    Plan = with_outcome_read(Plan0,Key,Token,Signer),
    Ctx = quod_commit_validation:new(Target,1,Est,I6,none, none),
    ?assertEqual(ok,quod_commit_validation:read_only_plan(Plan,Ctx)),
    Forged = with_outcome_read(Plan0,Key,setelement(1,Token,<<99:256>>),Signer),
    ?assertEqual({error,conflict_retry},quod_commit_validation:read_only_plan(Forged,Ctx)),
    Dir = filename:join("/tmp","quod-outcome-validation-" ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok,Disk} = quod_outcome:open(Ns,Anchor,#{data_dir => Dir,outcome_backend => disk}),
    ok = quod_outcome:close(Disk),
    Broken = quod_commit_validation:new(Target,1,Est,Disk,none, none),
    ?assertMatch({outcome_error,_},quod_commit_validation:read_only_plan(Plan,Broken)),
    ok = quod_outcome:close(I6).

with_outcome_read(Plan,Key,Token,Signer) ->
    Reads = (quod_ct:plan_material(read_check,Plan))#{Key => Token},
    {ok,Bytes} = quod_read_set:encode(Reads),
    Core = (quod_dtx:core(Plan))#{read_check := Bytes,read_functors := map_size(Reads)},
    Signature = quod_identity:sign(term_to_binary({<<"quod.dtx.plan">>,8,Core},[deterministic]),Signer),
    {quod_plan,Core,maps:get(pubkey,Signer),Signature}.

read_certificate_refuses_a_stale_read_token_test() ->
    Fixture = valid_vote_fixture(
                #{goal_text => <<"\\+(missing(ok)).">>}),
    {TargetNs, TargetAnchor} = maps:get(participant_target, Fixture),
    Signer = maps:get(pubkey, maps:get(node_identity, Fixture)),
    Plan = maps:get(plan, Fixture),
    [{_InvocationId, FullChain, GoalBlob, _Verdict, _Answers,
      _ReadDigest, _Tag}] = quod_ct:plan_material(transcript, Plan),
    {ok, Goal} = quod_durable_term:decode_goal(GoalBlob),
    CallerNamespaces = [Ns || {Ns, _Anchor} <- tl(FullChain)],
    {ok, Principal} = quod_agent_ref:materialize_principal(
                        maps:get(principal, Fixture)),
    Policy = {can_invoke, Goal, Principal, CallerNamespaces, TargetNs},
    Member = {peer_admitted, Signer, "validator", 14567, Signer},
    BaseFacts = quod_ct:signed_agent_facts(Fixture) ++ [Policy, Member],
    %% The sealed read observed missing/1 as absent.  The unchanged snapshot
    %% certifies, while the same plan against a snapshot where missing/1 was
    %% asserted is refused by the shared plan OCC validator.
    with_context(
      TargetNs, TargetAnchor, BaseFacts,
      fun(Context) ->
          ?assertEqual(ok, quod_commit_validation:read_only_plan(Plan, Context))
      end),
    with_context(
      TargetNs, TargetAnchor, [{missing, ok} | BaseFacts],
      fun(Context) ->
          ?assertEqual(
             {error, conflict_retry},
             quod_commit_validation:read_only_plan(Plan, Context))
      end).

external_predicate_manifest_is_immutable_after_genesis_test() ->
    Ns = <<"quod:immutable-predicate-manifest">>,
    Anchor = <<229:256>>,
    Diffs = [quod_ct:diff_for({external_predicate_modules, []}),
             [{abolish, {external_predicate_modules, 1}}]],
    with_context(
      Ns, Anchor, [],
      fun(Context) ->
          [?assertMatch(
             {ok, {invalid, immutable_external_predicate_manifest}, _},
             quod_commit_validation:content(
               [quod_ct:change(Ns, Diff, #{})], 1, check, Context)) || Diff <- Diffs]
      end).

atomic_vote_cannot_change_external_predicate_manifest_test() ->
    Fixture = valid_vote_fixture(
                #{goal_text =>
                      <<"assertz(external_predicate_modules([])).">>}),
    {TargetNs, TargetAnchor} = maps:get(participant_target, Fixture),
    Signer = maps:get(pubkey, maps:get(node_identity, Fixture)),
    Control = maps:get(vote_control, Fixture),
    #{goal := FrozenGoal} = maps:get(evidence, Fixture),
    {ok, Goal} = quod_wire_term:materialize_symbols(FrozenGoal),
    {ok, Principal} = quod_agent_ref:materialize_principal(
                        maps:get(principal, Fixture)),
    Policy = {can_invoke, Goal, Principal, [], TargetNs},
    Member = {peer_admitted, Signer, "validator", 14567, Signer},
    quod_ct:with_network_identity(maps:get(network, Fixture), fun() -> with_context(
      TargetNs, TargetAnchor,
      quod_ct:signed_agent_facts(Fixture) ++ [Policy, Member],
      fun(Context) ->
          ?assertMatch(
             {ok, {invalid, {atomic_vote_choice,
                   {refused, [immutable_external_predicate_manifest]}}}, _},
             quod_commit_validation:dtx(Control, 1, check, Context))
      end) end).

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
    Fixture = quod_ct:signed_atomic_fixture(
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
                {Ns, Anchor}, 1, ParentEst, Outcomes, none, none),
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

valid_vote_fixture() ->
    valid_vote_fixture(#{}).

valid_vote_fixture(Overrides) ->
    Target = {<<"quod:commit-vote">>, <<226:256>>},
    Origin = {<<"quod:commit-origin">>, <<225:256>>},
    Fixture0 = quod_ct:signed_atomic_fixture(
                 maps:merge(
                   #{target => Origin, participant_target => Target,
                     second_participant_target => Target,
                     network => <<227:256>>,
                     submitted_at => 1},
                   Overrides)),
    {ok, Vote} = quod_atomic:new_vote(maps:get(group, Fixture0), Target,
                   lists:keyfind(Target, 1, maps:get(bundles, Fixture0)), prepared),
    {ok, Material} = quod_atomic:admission_material(Vote),
    {ok, Control} = quod_atomic:sign_control(Target, Material,
                      maps:get(admission, Fixture0), 1, 1, maps:get(node_identity, Fixture0)),
    Fixture0#{vote => Vote, vote_control => Control}.

with_context(Ns, Anchor, Facts, Fun) ->
    ParentEst = quod_ct:committed_kb(Facts),
    {ok, Outcomes} = quod_outcome:open(
                       Ns, Anchor, #{outcome_backend => memory}),
    Context = quod_commit_validation:new(
                {Ns, Anchor}, 1, ParentEst, Outcomes, none, none),
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

key(Term) ->
    crypto:hash(sha256, term_to_binary(Term, [deterministic])).

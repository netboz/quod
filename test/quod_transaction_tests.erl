-module(quod_transaction_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").
-include("quod_vm_limits.hrl").

-define(NS, <<"test:transactions">>).
-define(ANCHOR, <<11:256>>).
-define(ADMISSION, <<13:256>>).
-define(BINDING, {?NS, ?ANCHOR, ?ADMISSION}).
-define(GENESIS_TX_VERSION, 1).
-define(GENESIS_TX_TAG, "quod/genesis").

identity() ->
    {Pub, Seed} = quod_identity:generate(),
    {Pub, #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})}}.

unsigned(Pub) ->
    {ok, Goal} = quod_durable_term:encode_goal({set, alpha, 1}),
    {ok, Result} = quod_durable_term:encode_result(#{'X' => 1}),
    quod_transaction:bind_id(
      {?NS, ?ANCHOR},
      #transaction{
         tx_id = <<>>,
         origin = {?NS, <<0:256>>},
         proof_id = <<21:256>>,
         plan_digest = <<22:256>>,
         goal = Goal,
         result = Result,
         diff = [{assert, {{value, alpha, 1}, true}}],
         read_check = #{{value, 3} => {present, 42},
                        {policy, 1} => {present, 7}},
         author = Pub,
         author_seq = 1,
         submitted_at = 1750000000000,
         sig = none}).

signed() ->
    {Pub, Identity} = identity(),
    Tx0 = unsigned(Pub),
    {ok, Tx} = quod_transaction:sign(?BINDING, Tx0, Identity),
    {Tx, Identity}.

read_certificate(ProofId, N) ->
    Target = {<<"quod:read-", (integer_to_binary(N))/binary>>, <<N:256>>},
    {Ns, Anchor} = Target,
    {Signer, Identity} = identity(),
    {ok, AnchorRef} = quod_dtx:certified_ref(
                        Ns, Anchor, 3, <<(N + 100):256>>, <<(N + 200):256>>,
                        <<"read-qc">>),
    PlanDigest = <<(N + 300):256>>,
    CommitteeId = <<(N + 400):256>>,
    {ok, Vote} = quod_read_certificate:sign(
                   Target, ProofId, PlanDigest, AnchorRef, CommitteeId,
                   Identity),
    {ok, Certificate} = quod_read_certificate:new(
                          Target, ProofId, PlanDigest, AnchorRef, CommitteeId,
                          [Vote]),
    {Certificate, Target, AnchorRef, [Signer]}.

empty_projection() -> quod_simplex:history_projection().
projection(Pub) ->
    quod_simplex:history_projection(
      [Pub], undefined, #{Pub => ?ADMISSION}, #{}, 0).

sign_and_verify_test() ->
    {Tx, _Identity} = signed(),
    ?assertEqual(64, byte_size(Tx#transaction.sig)),
    ?assert(quod_transaction:verify(?BINDING, Tx)),
    ?assertEqual(quod_transaction:bytes(?BINDING, Tx#transaction{sig = none}),
                 quod_transaction:bytes(?BINDING, Tx)).

sign_submission_matches_separate_operations_test() ->
    {Pub, Identity} = identity(),
    Unsigned = unsigned(Pub),
    {ok, ExpectedSigned} = quod_transaction:sign(?BINDING, Unsigned, Identity),
    {ok, ExpectedSubmission} =
        quod_transaction:submission(?BINDING, ExpectedSigned),
    {ok, ExpectedSigned, ExpectedSubmission} =
        quod_transaction:sign_submission(?BINDING, Unsigned, Identity).

deterministic_read_check_order_test() ->
    {Pub, _Identity} = identity(),
    A = (unsigned(Pub))#transaction{
          read_check = maps:from_list(
                         [{{value, 3}, {present, 42}}, {{policy, 1}, {present, 7}}])},
    B = A#transaction{
          read_check = maps:from_list(
                         [{{policy, 1}, {present, 7}}, {{value, 3}, {present, 42}}])},
    ?assertEqual(quod_transaction:bytes(?BINDING, A),
                 quod_transaction:bytes(?BINDING, B)).

semantic_id_rejects_unstable_map_keys_before_signing_test() ->
    {Pub, _Identity} = identity(),
    Unstable = #transaction{
                  tx_id = <<>>,
                  origin = {?NS, <<0:256>>},
                  proof_id = <<21:256>>,
                  plan_digest = <<22:256>>,
                  goal = (unsigned(Pub))#transaction.goal,
                  result = (unsigned(Pub))#transaction.result,
                  diff = [], read_check = #{}, effects = [],
                  %% This is deliberately malformed request evidence. Before
                  %% the byte-canonical cut it could acquire a semantic id
                  %% even though the signing encoder later rejected it.
                  request_auth = #{#{nested => map_key} => value},
                  author = Pub, author_seq = 1},
    ?assertError(
       bad_transaction_material,
       quod_transaction:bind_id({?NS, ?ANCHOR}, Unstable)).

foreign_reads_are_signed_but_do_not_change_semantic_id_test() ->
    {Pub, Identity} = identity(),
    Base = unsigned(Pub),
    {Certificate, _Target, _AnchorRef, _Committee} =
        read_certificate(Base#transaction.proof_id, 32),
    WithReads = quod_transaction:bind_id(
                  {?NS, ?ANCHOR},
                  Base#transaction{tx_id = <<>>, foreign_reads = [Certificate]}),
    ?assertEqual(Base#transaction.tx_id, WithReads#transaction.tx_id),
    ?assertNotEqual(quod_transaction:bytes(?BINDING, Base),
                    quod_transaction:bytes(?BINDING, WithReads)),
    {ok, Signed} = quod_transaction:sign(?BINDING, WithReads, Identity),
    ?assert(quod_transaction:verify(?BINDING, Signed)),
    ?assertNot(quod_transaction:verify(
                 ?BINDING, Signed#transaction{foreign_reads = []})).

from_plan_carries_canonical_foreign_reads_test() ->
    Fixture = quod_ct:signed_dtx_begin_fixture(#{}),
    Plan = maps:get(plan, Fixture),
    {ok, Material0} = quod_dtx:material(Plan),
    {Certificate, _Target, _AnchorRef, _Committee} =
        read_certificate(quod_dtx:proof_id(Plan), 33),
    Transaction = quod_transaction:from_plan(
                    Plan, Material0#{foreign_reads => [Certificate]},
                    maps:get(goal_blob, Fixture),
                    maps:get(result_blob, Fixture), maps:get(auth, Fixture)),
    ?assertEqual([Certificate], Transaction#transaction.foreign_reads),
    ?assertMatch([{entry, _}],
                 quod_transaction:required_references(Transaction)).

remote_claim_carries_foreign_reads_into_application_test() ->
    ProofId = <<204:256>>,
    {Certificate, _ReadTarget, AnchorRef, _Committee} =
        read_certificate(ProofId, 34),
    Fixture = quod_ct:remote_operation_fixture(
                #{proof_id => ProofId, foreign_reads => [Certificate]}),
    Claim = maps:get(claim, Fixture),
    Application = maps:get(application, Fixture),
    ?assertEqual([Certificate], Claim#transaction.foreign_reads),
    ?assertEqual([Certificate], Application#transaction.foreign_reads),
    ?assertMatch([{transaction, _}, {entry, AnchorRef}],
                 quod_transaction:required_references(Application)),
    ?assertMatch([{entry, AnchorRef}],
                 quod_transaction:required_references(Claim)),
    %% The target application must carry the exact certificate list committed
    %% by its source claim. Dropping it is a malformed role, not a different
    %% but otherwise valid application.
    {TargetNs, TargetAnchor} = maps:get(participant_target, Fixture),
    ?assertEqual(
       {error, bad_term},
       quod_transaction:bytes(
         {TargetNs, TargetAnchor, <<205:256>>},
                 Application#transaction{foreign_reads = [], author = <<206:256>>,
                                 author_seq = 1, submitted_at = 1})).

foreign_read_carrier_round_trips_canonically_test() ->
    ProofId = <<208:256>>,
    {CertificateA, _, _, _} = read_certificate(ProofId, 36),
    {CertificateB, _, _, _} = read_certificate(ProofId, 37),
    Certificates = lists:sort([CertificateB, CertificateA]),
    {ok, Blob} = quod_transaction:encode_foreign_reads(Certificates),
    ?assertEqual({ok, Certificates},
                 quod_transaction:decode_foreign_reads(Blob)),
    ?assertEqual({error, bad_foreign_reads},
                 quod_transaction:encode_foreign_reads(
                   [CertificateA, CertificateA])),
    ?assertEqual({error, bad_foreign_reads},
                 quod_transaction:decode_foreign_reads(
                   term_to_binary({quod_foreign_reads, 1, [<<"bad">>]},
                                  [deterministic]))).

noncanonical_foreign_reads_are_rejected_test() ->
    {Pub, _Identity} = identity(),
    Tx = unsigned(Pub),
    {Certificate, _Target, _AnchorRef, _Committee} =
        read_certificate(Tx#transaction.proof_id, 35),
    ?assertEqual(
       {error, bad_term},
       quod_transaction:bytes(
         ?BINDING,
         Tx#transaction{foreign_reads = [Certificate, Certificate]})),
    ?assertEqual(
       error,
       quod_transaction:required_references(
         Tx#transaction{foreign_reads = [Certificate, Certificate]})).

malformed_v13_foreign_reads_fail_during_full_decode_test() ->
    {Tx, Identity} = signed(),
    {ok, Canonical} = quod_transaction:bytes(?BINDING, Tx),
    Decoded = binary_to_term(Canonical),
    lists:foreach(
      fun(ForeignReads) ->
          MalformedCanonical = term_to_binary(
                                 setelement(16, Decoded, ForeignReads),
                                 [deterministic]),
          Signature = quod_identity:sign(MalformedCanonical, Identity),
          Submission = {submit, Tx#transaction.author, Signature,
                        MalformedCanonical},
          ?assert(quod_transaction:verify_submission(Submission)),
          ?assertEqual(
             {error, malformed_material},
             quod_transaction:decode_verified_submission(
               ?BINDING, Submission))
      end,
      [not_a_list, [not_a_certificate]]).

current_semantic_id_domain_differs_from_v4_test() ->
    Tx = unsigned(<<0:256>>),
    ?assertNotEqual(Tx#transaction.tx_id, semantic_v4_id(Tx)).

namespace_binding_test() ->
    {Tx, _Identity} = signed(),
    ?assert(quod_transaction:verify(?BINDING, Tx)),
    ?assertNot(quod_transaction:verify(
                 {<<"other:ontology">>, ?ANCHOR, ?ADMISSION}, Tx)),
    %% The anchor closes cross-founding replay: the same namespace re-founded
    %% mints a different genesis hash, so every old signature dies with it.
    ?assertNot(quod_transaction:verify({?NS, <<12:256>>, ?ADMISSION}, Tx)),
    %% Leaving and rejoining changes only this author's admission generation.
    ?assertNot(quod_transaction:verify({?NS, ?ANCHOR, <<14:256>>}, Tx)).

every_committed_field_is_bound_test() ->
    {Tx, _Identity} = signed(),
    {ok, OtherGoal} = quod_durable_term:encode_goal({set, alpha, 2}),
    {ok, OtherResult} = quod_durable_term:encode_result(#{'X' => 2}),
    Mutations = [
      Tx#transaction{tx_id = <<"tx-2">>},
      Tx#transaction{origin = {<<"other">>, <<0:256>>}},
      Tx#transaction{proof_id = <<23:256>>},
      Tx#transaction{plan_digest = <<24:256>>},
      Tx#transaction{goal = OtherGoal},
      Tx#transaction{result = OtherResult},
      Tx#transaction{diff = [{assert, {{value, alpha, 2}, true}}]},
      Tx#transaction{read_check = #{{value, 3} => {present, 43}}},
      Tx#transaction{foreign_reads =
                       [element(1, read_certificate(Tx#transaction.proof_id, 31))]},
      Tx#transaction{author = <<0:256>>},
      Tx#transaction{author_seq = 2},
      Tx#transaction{submitted_at = 1750000000001}
    ],
    [?assertNot(quod_transaction:verify(?BINDING, Mutated)) || Mutated <- Mutations].

malformed_and_wrong_author_test() ->
    {Pub, Identity} = identity(),
    {OtherPub, OtherIdentity} = identity(),
    Tx = unsigned(Pub),
    ?assertEqual({error, author_mismatch},
                 quod_transaction:sign(?BINDING, Tx, OtherIdentity)),
    {ok, Signed} = quod_transaction:sign(?BINDING, Tx, Identity),
    ?assertNot(quod_transaction:verify(?BINDING, Signed#transaction{sig = <<1, 2, 3>>})),
    ?assertNot(quod_transaction:verify(?BINDING, Signed#transaction{author = OtherPub})),
    ?assertEqual({error, already_signed},
                 quod_transaction:sign(?BINDING, Signed, Identity)).

history_genesis_exemption_test() ->
    {Pub, Identity} = identity(),
    Nonce = <<7:256>>,
    %% A valid genesis is assertion-only and asserts a {can_invoke,4} head:
    %% the rule gates every entry, so an ontology born without a policy could
    %% never be given one.
    Policy = {assert, {{can_invoke, {'G'}, {'P'}, {'C'}, {'N'}}, true}},
    Manifest = {assert, {{external_predicate_modules, []}, {[], false}}},
    Genesis = (unsigned(Pub))#transaction{
                tx_id = genesis_id(?NS, Nonce),
                proof_id = none, plan_digest = none,
                goal = undefined, result = undefined,
                diff = [
                  {assert, {{consensus_incarnation, Nonce}, true}},
                  {assert, {{peer_admitted, Pub, undefined, undefined, Pub}, true}},
                  Manifest,
                  Policy
                ],
                read_check = #{},
                author_seq = 0, submitted_at = 0, sig = none},
    ?assert(quod_simplex:valid_history_entry(
              {?NS, ?ANCHOR}, 1, {batch, [Genesis]}, empty_projection())),
    %% policy-less genesis is rejected at the founding/replay/catch-up seam
    ?assertNot(
       quod_simplex:valid_history_entry(
         {?NS, ?ANCHOR}, 1,
         {batch, [Genesis#transaction{
                    diff = [{assert, {{consensus_incarnation, Nonce}, true}},
                            {assert, {{peer_admitted, Pub, undefined,
                                       undefined, Pub}, true}}]}]}, empty_projection())),
    %% assert-then-retract cannot smuggle a policy-less genesis past the
    %% assertion-only rule, even though the {can_invoke,4} head appears
    ?assertNot(
       quod_simplex:valid_history_entry(
         {?NS, ?ANCHOR}, 1,
         {batch, [Genesis#transaction{
                    diff = [{assert, {{consensus_incarnation, Nonce}, true}},
                            {assert, {{peer_admitted, Pub, undefined,
                                       undefined, Pub}, true}},
                            Policy,
                            {retract, {{can_invoke, {'G'}, {'P'},
                                        {'C'}, {'N'}}, true}}]}]}, empty_projection())),
    ?assertNot(
       quod_simplex:valid_history_entry(
         {?NS, ?ANCHOR}, 1,
         {batch, [Genesis#transaction{tx_id = <<"genesis:test">>}]}, empty_projection())),
    ?assertNot(
       quod_simplex:valid_history_entry(
         {?NS, ?ANCHOR}, 1,
         {batch, [Genesis#transaction{tx_id = genesis_id(?NS, <<8:256>>)}]}, empty_projection())),
    ?assertNot(
       quod_simplex:valid_history_entry(
         {?NS, ?ANCHOR}, 1,
         {batch, [Genesis#transaction{
                    diff = [{assert,
                             {{peer_admitted, Pub, undefined, undefined, Pub},
                              true}}]}]}, empty_projection())),
    ?assertNot(
       quod_simplex:valid_history_entry(
         {?NS, ?ANCHOR}, 1,
         {batch, [Genesis#transaction{author_seq = 1}]}, empty_projection())),
    %% `#{}` in a head pattern matches any map: a non-empty read set on the
    %% founding transaction must still be refused explicitly
    ?assertNot(
       quod_simplex:valid_history_entry(
         {?NS, ?ANCHOR}, 1,
         {batch, [Genesis#transaction{
                    read_check = #{{x, 1} => {present, 7}}}]}, empty_projection())),
    ?assertNot(quod_simplex:valid_history_entry(
                 {?NS, ?ANCHOR}, 2, {batch, [Genesis]}, projection(Pub))),
    {ok, Signed} = quod_transaction:sign(
                     ?BINDING, (unsigned(Pub))#transaction{author_seq = 1},
                     Identity),
    ?assert(quod_simplex:valid_history_entry(
              {?NS, ?ANCHOR}, 2, {batch, [Signed]}, projection(Pub))),
    ?assertNot(quod_simplex:valid_history_entry(
                 {<<"other">>, ?ANCHOR}, 2, {batch, [Signed]}, projection(Pub))).

genesis_id(Ns, Nonce) ->
    <<?GENESIS_TX_TAG, 0, ?GENESIS_TX_VERSION:8,
      (byte_size(Ns)):32, Ns/binary, Nonce/binary>>.

signed_user_request_is_bound_and_revalidated_at_admission_test() ->
    Fixture = quod_ct:signed_dtx_begin_fixture(#{}),
    Transaction = maps:get(transaction, Fixture),
    Network = maps:get(network, Fixture),
    Target = maps:get(target, Fixture),
    Deadline = maps:get(deadline, Fixture),
    {ok, #{principal := Principal, claim := Claim}} =
        quod_transaction:validate_request(
          Network, Target, Deadline, Transaction),
    ?assertEqual(maps:get(principal, Fixture), Principal),
    ?assertEqual(maps:get(operation_ref, Fixture),
                 maps:get(operation_ref, Claim)),
    ?assertEqual(
       {error, expired},
       quod_transaction:validate_request(
         Network, Target, Deadline + 1, Transaction)),
    ?assertMatch({ok, #{digest := _, operation_ref := _}},
                 quod_transaction:request_claim(Transaction)).

signed_user_request_and_authorization_transcript_are_not_interchangeable_test() ->
    Fixture = quod_ct:signed_dtx_begin_fixture(#{}),
    Transaction = maps:get(transaction, Fixture),
    Network = maps:get(network, Fixture),
    Target = maps:get(target, Fixture),
    Deadline = maps:get(deadline, Fixture),
    {agent_goal_v1, Digest, Bytes, Signature} =
        Transaction#transaction.request_auth,
    ForgedAuth = {agent_goal_v1, Digest, flip_first(Bytes), Signature},
    ?assertMatch(
       {error, _},
       quod_transaction:validate_request(
         Network, Target, Deadline,
         Transaction#transaction{request_auth = ForgedAuth})),
    {ok, OtherGoal} = quod_durable_term:encode_goal({saved, other}),
    {ok, WrongTranscript} =
        quod_wire_term:encode_canonical(
          [{<<1:128>>, [Target], OtherGoal, allowed, 1, <<2:256>>, complete}]),
    WrongAuthorization =
        Transaction#transaction{
          auth_transcript = {agent_goal_v1, WrongTranscript}},
    ?assertEqual(
       {error, invalid_authorization_transcript},
       quod_transaction:validate_request(
         Network, Target, Deadline, WrongAuthorization)),
    ?assertEqual(error, quod_transaction:request_claim(WrongAuthorization)).

signed_request_replay_uses_the_certified_block_time_test() ->
    Network = <<82:256>>,
    Fixture = quod_ct:signed_dtx_begin_fixture(
                #{network => Network, target => {?NS, ?ANCHOR}}),
    Transaction = maps:get(transaction, Fixture),
    #{pubkey := Author} = maps:get(node_identity, Fixture),
    Admission = maps:get(admission, Fixture),
    Projection = quod_simplex:history_projection(
                   [Author], undefined, #{Author => Admission}, #{}, 0),
    Deadline = maps:get(deadline, Fixture),
    quod_ct:with_network_identity(
      Network,
      fun() ->
          ?assert(quod_simplex:valid_history_entry(
                    {?NS, ?ANCHOR}, 2, {batch, [Transaction]},
                    Deadline, Projection)),
          ?assertNot(quod_simplex:valid_history_entry(
                       {?NS, ?ANCHOR}, 2, {batch, [Transaction]},
                       Deadline + 1, Projection))
      end).

same_agent_request_has_one_semantic_transaction_across_validator_authors_test() ->
    Fixture = quod_ct:signed_dtx_begin_fixture(#{}),
    First = maps:get(transaction, Fixture),
    {OtherAuthor, OtherIdentity} = identity(),
    Admission = maps:get(admission, Fixture),
    {Ns, Anchor} = Target = maps:get(target, Fixture),
    {ok, Second} = quod_transaction:sign(
                     {Ns, Anchor, Admission},
                     First#transaction{author = OtherAuthor,
                                       author_seq = 2, sig = none,
                                       signed_bytes = none},
                     OtherIdentity),
    ?assertNotEqual(First#transaction.author, Second#transaction.author),
    ?assertNotEqual(First#transaction.sig, Second#transaction.sig),
    ?assertEqual(First#transaction.tx_id, Second#transaction.tx_id),
    ?assertEqual(quod_transaction:request_claim(First),
                 quod_transaction:request_claim(Second)),
    {ok, Claim} = quod_transaction:request_claim(Second),
    ?assert(quod_transaction:verify(
              {Ns, Anchor, Admission}, First)),
    ?assert(quod_transaction:verify(
              {Ns, Anchor, Admission}, Second)),
    ?assertEqual(Target, maps:get(target, Claim)).

remote_operation_ids_are_acyclic_and_evidence_independent_test() ->
    Fixture = quod_ct:remote_operation_fixture(#{}),
    Origin = maps:get(origin, Fixture),
    Target = maps:get(participant_target, Fixture),
    Claim = maps:get(claim, Fixture),
    ClaimRef = maps:get(claim_ref, Fixture),
    Application = maps:get(application, Fixture),
    TargetRef = maps:get(target_ref, Fixture),
    Completion = maps:get(completion, Fixture),
    ?assert(quod_transaction:valid_id(Origin, Claim)),
    ?assert(quod_transaction:valid_id(Target, Application)),
    ?assert(quod_transaction:valid_id(Origin, Completion)),
    ?assertEqual({ok, true},
                 quod_durable_term:decode_goal(
                   Completion#transaction.goal)),
    ?assertEqual({ok, []},
                 quod_durable_term:decode_result(
                   Completion#transaction.result)),
    ?assertEqual(
       Application#transaction.tx_id,
       (quod_transaction:remote_application(ClaimRef, Claim))#transaction.tx_id),
    {TargetNs, TargetAnchor} = Target,
    ?assertEqual({transaction, TargetNs, TargetAnchor,
                  Application#transaction.tx_id}, TargetRef),
    %% Certified block/proof bytes accelerate verification but are not semantic
    %% input: replacing only the proof leaves the target transaction id fixed.
    {OriginNs, OriginAnchor} = Origin,
    {ok, OtherCertifiedClaimRef} = quod_dtx:certified_ref(
                                      OriginNs, OriginAnchor, 9, <<215:256>>,
                                      Claim#transaction.tx_id, <<"other-qc">>),
    OtherEvidence = quod_transaction:attach_evidence(
                      quod_transaction:remote_application(ClaimRef, Claim),
                      OtherCertifiedClaimRef, Claim),
    ?assertEqual(Application#transaction.tx_id,
                 OtherEvidence#transaction.tx_id),
    ?assertNotEqual(Application#transaction.evidence,
                    OtherEvidence#transaction.evidence).

remote_operation_role_and_evidence_roundtrip_test() ->
    Fixture = quod_ct:remote_operation_fixture(#{}),
    Claim = maps:get(claim, Fixture),
    Application = maps:get(application, Fixture),
    Completion = maps:get(completion, Fixture),
    ?assertEqual(shared, quod_transaction:remote_claim_route(Claim)),
    ?assertMatch([{transaction, _}],
                 quod_transaction:required_references(Application)),
    ?assertMatch([{transaction, _}],
                 quod_transaction:required_references(Completion)),
    ?assertEqual([], quod_transaction:required_references(Claim)),
    {CertifiedClaimRef, StoredClaim} = Application#transaction.evidence,
    {ok, EvidenceBlob} = quod_transaction:encode_evidence(
                           CertifiedClaimRef, StoredClaim),
    ?assertEqual({ok, CertifiedClaimRef, StoredClaim},
                 quod_transaction:decode_evidence(EvidenceBlob)),
    ?assertEqual({error, bad_remote_evidence},
                 quod_transaction:decode_evidence(flip_first(EvidenceBlob))).

operation_submission_is_one_verified_custody_artifact_test() ->
    Fixture = quod_ct:signed_effect_operation_submission(),
    Submission = maps:get(submission, Fixture),
    {submit, SourceKey, Signature, _Canonical} = Submission,
    {ok, Blob} = quod_transaction:encode_operation_submission(Submission),
    ?assertMatch(
       {ok,
        #{submission := Submission, claim := #transaction{},
          claim_ref := {transaction, _, <<_:256>>, <<_:256>>},
          target := {_, <<_:256>>},
          target_ref := {transaction, _, <<_:256>>, <<_:256>>},
          plan := {quod_plan, _, _, _}, plan_digest := <<_:256>>,
          manifest_digest := <<_:256>>,
          effect := {quod_direct_effect, 2, _, _, _, _, _, _, _, _, _},
          author := SourceKey, admission := <<_:256>>,
          cancel_digest := <<_:256>>}},
       quod_transaction:decode_operation_submission(Blob)),
    {ok, Decoded} = quod_transaction:decode_operation_submission(Blob),
    ?assertEqual(
       crypto:hash(
         sha256, <<"quod.operation.cancel.v1", Signature/binary>>),
       maps:get(cancel_digest, Decoded)),
    ?assertEqual(
       quod_dtx:manifest_digest(maps:get(manifest, Fixture)),
       maps:get(manifest_digest, Decoded)),
    ?assertEqual(maps:get(effect, Fixture), maps:get(effect, Decoded)).

operation_submission_rejects_before_inner_decode_test() ->
    Fixture = quod_ct:signed_effect_operation_submission(),
    {submit, Author, Signature, Canonical} = maps:get(submission, Fixture),
    Tampered = {submit, Author, flip_first(Signature), Canonical},
    TamperedBlob = term_to_binary(Tampered, [deterministic]),
    ?assertEqual(
       {error, invalid_operation_submission},
       quod_transaction:decode_operation_submission(TamperedBlob)),
    %% A valid outer signature under another key cannot detach the custody
    %% artifact from the source author embedded in its signed transaction.
    {OtherKey, OtherSeed} = quod_identity:generate(),
    OtherIdentity =
        #{pubkey => OtherKey,
          key => quod_identity:key_term({OtherKey, OtherSeed})},
    WrongAuthorSubmission =
        {submit, OtherKey,
         quod_identity:sign(Canonical, OtherIdentity), Canonical},
    ?assert(quod_transaction:verify_submission(WrongAuthorSubmission)),
    ?assertEqual(
       {error, invalid_operation_submission},
       quod_transaction:decode_operation_submission(
         term_to_binary(WrongAuthorSubmission, [deterministic]))),
    %% The manifest names the source node/admission that may claim this
    %% attested plan. A different coordinator remains a well-signed claim but
    %% cannot become an operation-custody capability.
    CoordinatorMismatch =
        quod_ct:signed_effect_operation_submission(
          #{coordinator => mismatch}),
    MismatchSubmission = maps:get(submission, CoordinatorMismatch),
    ?assert(quod_transaction:verify_submission(MismatchSubmission)),
    ?assertEqual(
       {error, invalid_operation_submission},
       quod_transaction:decode_operation_submission(
         term_to_binary(MismatchSubmission, [deterministic]))),
    %% A valid signed remote claim without an effect belongs to the ordinary
    %% application path and can never authorize private-effect cancellation.
    NoEffect = quod_ct:remote_operation_fixture(#{}),
    Claim0 = maps:get(claim, NoEffect),
    {OriginNs, OriginAnchor} = maps:get(origin, NoEffect),
    Admission = maps:get(admission, NoEffect),
    {ok, NoEffectSubmission} = quod_transaction:submission(
                                 {OriginNs, OriginAnchor, Admission}, Claim0),
    ?assertEqual(
       {error, invalid_operation_submission},
       quod_transaction:encode_operation_submission(NoEffectSubmission)).

network_identity_requirement_is_total_and_fail_closed_test() ->
    Fixture = quod_ct:signed_dtx_begin_fixture(#{}),
    Signed = maps:get(transaction, Fixture),
    Unsigned = Signed#transaction{request_auth = none,
                                  auth_transcript = none},
    Mismatched = Unsigned#transaction{
                   auth_transcript = {agent_goal_v1, <<>>}},
    ?assertNot(quod_transaction:requires_network_identity([])),
    ?assertNot(quod_transaction:requires_network_identity([Unsigned])),
    ?assert(quod_transaction:requires_network_identity([Mismatched])),
    ?assert(quod_transaction:requires_network_identity([Unsigned, Signed])),
    ?assert(quod_transaction:requires_network_identity([malformed])),
    ?assert(quod_transaction:requires_network_identity(not_a_list)).

relay_submission_roundtrip_test() ->
    {Tx, _Identity} = signed(),
    {ok, Submission} = quod_transaction:submission(?BINDING, Tx),
    {submit, _Author, _Signature, Canonical} = Submission,
    ?assertEqual(16, byte_size(quod_transaction:submission_id(Submission))),
    ?assert(quod_transaction:verify_submission(Submission)),
    ?assertEqual({ok, Tx},
                 quod_transaction:decode_verified_submission(?BINDING, Submission)),
    ?assertMatch(
       {ok, #{target := {?NS, ?ANCHOR}, admission := ?ADMISSION,
              tx_id := <<_:256>>, effects := [], author := <<_:256>>,
              sequence := 1}},
       quod_transaction:decode_submission_metadata(Canonical)),
    ?assertMatch({error, namespace_or_author_mismatch},
                 quod_transaction:decode_verified_submission(
                   {<<"other">>, ?ANCHOR, ?ADMISSION}, Submission)).

superseded_v12_transaction_is_explicitly_rejected_test() ->
    {Tx, Identity} = signed(),
    {ok, V13Bytes} = quod_transaction:bytes(?BINDING, Tx),
    {quod_transaction, 13, Ns, Anchor, Admission,
     TxId, Origin, ProofId, PlanDigest, Goal, Result,
     MaterialWire, EffectsWire, _Role, _Evidence,
     _ForeignReads,
     RequestAuth, AuthorizationTranscript,
     Author, AuthorSeq, SubmittedAt} = binary_to_term(V13Bytes),
    V12Bytes = term_to_binary(
                {quod_transaction, 12, Ns, Anchor, Admission,
                 TxId, Origin, ProofId, PlanDigest, Goal, Result,
                 MaterialWire, EffectsWire, application, none, RequestAuth,
                 AuthorizationTranscript,
                 Author, AuthorSeq, SubmittedAt},
                [deterministic]),
    V12Signature = quod_identity:sign(V12Bytes, Identity),
    V12Submission = {submit, Author, V12Signature, V12Bytes},
    ?assert(quod_transaction:verify_submission(V12Submission)),
    ?assertEqual(
       {error, malformed_submission},
       quod_transaction:decode_submission_metadata(V12Bytes)),
    ?assertEqual(
       {error, unsupported_version},
       quod_transaction:decode_verified_submission(?BINDING, V12Submission)).

different_canonical_submissions_have_different_ids_test() ->
    {Tx, Identity} = signed(),
    {ok, Submission1} = quod_transaction:submission(?BINDING, Tx),
    {ok, OtherGoal} = quod_durable_term:encode_goal({set, alpha, 2}),
    Tx0 = quod_transaction:bind_id(
            {?NS, ?ANCHOR},
            Tx#transaction{tx_id = <<>>, goal = OtherGoal, sig = none,
                           signed_bytes = none}),
    {ok, Tx2} = quod_transaction:sign(?BINDING, Tx0, Identity),
    {ok, Submission2} = quod_transaction:submission(?BINDING, Tx2),
    ?assertNotEqual(
       quod_transaction:submission_id(Submission1),
       quod_transaction:submission_id(Submission2)).

relay_attempt_identity_test() ->
    {Tx, _Identity} = signed(),
    {ok, Submission} = quod_transaction:submission(?BINDING, Tx),
    SubmissionId = quod_transaction:submission_id(Submission),
    CommitteeId = <<6:256>>,
    Target = <<7:256>>,
    AttemptId =
        quod_transaction:relay_attempt_id(
          ?NS, SubmissionId, CommitteeId, 17, Target),
    ?assertEqual(16, byte_size(AttemptId)),
    ?assertEqual(
       AttemptId,
       quod_transaction:relay_attempt_id(
         ?NS, SubmissionId, CommitteeId, 17, Target)),
    ?assertEqual(
       16,
       byte_size(
         quod_transaction:relay_attempt_id(
           ?NS, SubmissionId, CommitteeId,
           16#FFFFFFFFFFFFFFFF, Target))),
    Mutations =
        [quod_transaction:relay_attempt_id(
           <<"other:ontology">>, SubmissionId, CommitteeId, 17, Target),
         quod_transaction:relay_attempt_id(
           ?NS, flip_first(SubmissionId), CommitteeId, 17, Target),
         quod_transaction:relay_attempt_id(
           ?NS, SubmissionId, <<9:256>>, 17, Target),
         quod_transaction:relay_attempt_id(
           ?NS, SubmissionId, CommitteeId, 18, Target),
         quod_transaction:relay_attempt_id(
           ?NS, SubmissionId, CommitteeId, 17, <<8:256>>)],
    [?assertNotEqual(AttemptId, Mutated) || Mutated <- Mutations].

relay_attempt_identity_golden_vector_test() ->
    ?assertEqual(
       <<16#00, 16#0d, 16#3c, 16#41, 16#6f, 16#b2, 16#78, 16#63,
         16#7c, 16#96, 16#d7, 16#08, 16#79, 16#75, 16#fe, 16#e9>>,
       quod_transaction:relay_attempt_id(
         <<"relay:test">>, <<1:128>>, <<3:256>>, 17, <<2:256>>)).

relay_attempt_identity_rejects_malformed_test() ->
    Sid = <<1:128>>,
    CommitteeId = <<3:256>>,
    Target = <<2:256>>,
    BadInputs =
        [{not_binary, Sid, CommitteeId, 1, Target},
         {?NS, <<1:120>>, CommitteeId, 1, Target},
         {?NS, Sid, <<3:248>>, 1, Target},
         {?NS, Sid, not_binary, 1, Target},
         {?NS, Sid, CommitteeId, 0, Target},
         {?NS, Sid, CommitteeId, 16#10000000000000000, Target},
         {?NS, Sid, CommitteeId, <<"1">>, Target},
         {?NS, Sid, CommitteeId, 1, <<2:248>>},
         {?NS, Sid, CommitteeId, 1, not_binary}],
    [?assertEqual(
       error,
       quod_transaction:relay_attempt_id(
         Ns, SubmissionId, Committee, Slot, Peer))
     || {Ns, SubmissionId, Committee, Slot, Peer} <- BadInputs].

relay_verifies_before_decode_test() ->
    {Tx, _Identity} = signed(),
    {ok, {submit, Author, Signature, Canonical}} =
        quod_transaction:submission(?BINDING, Tx),
    Tampered = {submit, Author, flip_first(Signature), Canonical},
    ?assertNot(quod_transaction:verify_submission(Tampered)),
    %% A valid signature over a non-canonical term is authenticated but still not
    %% a transaction in the versioned canonical format.
    {_OtherPub, OtherIdentity} = identity(),
    Opaque = term_to_binary({'not', a, transaction}, [deterministic]),
    OtherAuthor = maps:get(pubkey, OtherIdentity),
    OtherSig = quod_identity:sign(Opaque, OtherIdentity),
    AuthenticatedGarbage = {submit, OtherAuthor, OtherSig, Opaque},
    ?assert(quod_transaction:verify_submission(AuthenticatedGarbage)),
    ?assertMatch({error, malformed_submission},
                 quod_transaction:decode_verified_submission(
                   ?NS, AuthenticatedGarbage)).

authenticated_relay_etf_cannot_allocate_atoms_test() ->
    Prefix = integer_to_binary(erlang:unique_integer([positive])),
    AtomNames =
        [<<"qtx_", Prefix/binary, "_", (integer_to_binary(N))/binary>>
         || N <- lists:seq(1, ?QUOD_MAX_NEW_MATERIAL_ATOMS + 1)],
    [?assertException(
        error, badarg, binary_to_existing_atom(Name, utf8))
     || Name <- AtomNames],
    %% The signed envelope itself contains only fixed atoms. Agent vocabulary is
    %% represented by bounded wire symbols; exceeding the explicit allocation
    %% cap rejects the complete material before any symbol is interned.
    DiffWire = wire_list([{0, Name} || Name <- AtomNames]),
    MaterialWire = {4, [DiffWire, {5}]},
    EffectsWire = quod_wire_term:encode_canonical([]),
    {ok, CanonicalEffects} = EffectsWire,
    {Author, Identity} = identity(),
    Canonical =
        term_to_binary(
          {quod_transaction, 13, ?NS, ?ANCHOR, ?ADMISSION,
           <<1:256>>, {?NS, <<0:256>>}, <<2:256>>, <<3:256>>,
           <<>>, <<>>, term_to_binary(MaterialWire, [deterministic]),
           CanonicalEffects,
           application, none, [], none, none, Author, 1, 0},
          [deterministic]),
    Signature = quod_identity:sign(Canonical, Identity),
    Submission = {submit, Author, Signature, Canonical},
    ?assert(quod_transaction:verify_submission(Submission)),
    ?assertEqual(
       {error, too_many_new_atoms},
       quod_transaction:decode_verified_submission(?BINDING, Submission)),
    [?assertException(
        error, badarg, binary_to_existing_atom(Name, utf8))
     || Name <- AtomNames].

bounded_material_failure_is_total_test() ->
    {Author, Identity} = identity(),
    %% The wire codec's existing maximum depth is 64. Use a clearly deeper
    %% fixture so the surrounding material wrappers cannot leave it on the edge.
    DeepTerm = deep_term(70, leaf),
    %% Invalid material is rejected by the signing codec itself; it does not
    %% need (and cannot acquire) a canonical semantic id first.
    Transaction = (unsigned(Author))#transaction{
                    tx_id = <<1:256>>,
                    diff = [{assert, {{deep, DeepTerm}, true}}]},
    ?assertEqual(
       {error, bad_term},
       quod_transaction:bytes(?BINDING, Transaction)),
    ?assertEqual(
       {error, bad_term},
       quod_transaction:sign_submission(
         ?BINDING, Transaction, Identity)),
    SignedShape = Transaction#transaction{sig = <<0:512>>},
    ?assertNot(quod_transaction:verify(?BINDING, SignedShape)),
    %% Drive the same value through history validation: a validator must reject
    %% the proposal rather than crashing while reconstructing signed bytes.
    ?assertNot(
       quod_simplex:valid_history_entry(
         {?NS, ?ANCHOR}, 2, {batch, [SignedShape]},
         projection(Author))).

deep_term(0, Term) -> Term;
deep_term(Depth, Term) -> deep_term(Depth - 1, {nested, Term}).

wire_list([]) -> {5};
wire_list([Head | Tail]) -> {6, Head, wire_list(Tail)}.

flip_first(<<Byte, Rest/binary>>) -> <<(Byte bxor 1), Rest/binary>>.

semantic_v4_id(
  #transaction{origin = Origin, proof_id = ProofId,
               plan_digest = PlanDigest, goal = Goal, result = Result,
               diff = Diff, read_check = ReadCheck, effects = Effects,
               request_auth = RequestAuth,
               auth_transcript = AuthTranscript}) ->
    {ok, DiffBytes} = quod_wire_term:encode_canonical(Diff),
    {ok, ReadCheckBytes} =
        quod_wire_term:encode_canonical(maps:to_list(ReadCheck)),
    {ok, EffectsBytes} = quod_wire_term:encode_canonical(Effects),
    crypto:hash(
      sha256,
      term_to_binary(
        {quod_semantic_transaction, 4, ?NS, ?ANCHOR, Origin, ProofId,
         PlanDigest, Goal, Result, DiffBytes, ReadCheckBytes, EffectsBytes,
         RequestAuth, AuthTranscript},
        [deterministic])).

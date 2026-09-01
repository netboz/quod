-module(quod_read_certificate_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_proof_limits.hrl").

f_plus_one_signatures_verify_test() ->
    F = fixture(4),
    [A, B | _] = maps:get(signers, F),
    Certificate = certificate(F, [A, B]),
    ?assert(quod_read_certificate:verify(
              Certificate, committee(F), maps:get(committee_id, F))).

one_below_threshold_does_not_verify_test() ->
    F = fixture(7),
    [A, B | _] = maps:get(signers, F),
    Certificate = certificate(F, [A, B]),
    ?assertNot(quod_read_certificate:verify(
                 Certificate, committee(F), maps:get(committee_id, F))).

noncommittee_signatures_are_ignored_test() ->
    F = fixture(4),
    [A | _] = maps:get(signers, F),
    Outsider = signer(),
    Certificate = certificate(F, [A, Outsider]),
    ?assertNot(quod_read_certificate:verify(
                 Certificate, committee(F), maps:get(committee_id, F))).

canonical_codec_roundtrips_and_rejects_noncanonical_or_wrong_shape_test() ->
    F = fixture(4),
    [A, B | _] = maps:get(signers, F),
    Certificate = certificate(F, [A, B]),
    {ok, Blob} = quod_read_certificate:encode(Certificate),
    ?assertEqual({ok, Certificate}, quod_read_certificate:decode(Blob)),
    ?assertEqual(
       {error, invalid_read_certificate},
       quod_read_certificate:decode(
         term_to_binary(Certificate, [{minor_version, 1}]))),
    ?assertEqual(
       {error, invalid_read_certificate},
       quod_read_certificate:decode(
         term_to_binary({quod_read_certificate, 99}, [deterministic]))).

codec_bound_is_owned_by_the_dtx_body_limit_test() ->
    AtLimit = binary:copy(<<0>>, ?QUOD_MAX_DTX_BODY_BYTES),
    AboveLimit = <<AtLimit/binary, 0>>,
    %% The exact-limit blob reaches decoding and fails only because it is not
    %% a certificate; the next byte is rejected by the shared byte owner.
    ?assertEqual(
       {error, invalid_read_certificate},
       quod_read_certificate:decode(AtLimit)),
    ?assertEqual(
       {error, too_large},
       quod_read_certificate:decode(AboveLimit)).

every_read_statement_field_is_signature_bound_test() ->
    F = fixture(1),
    [A] = maps:get(signers, F),
    Certificate = certificate(F, [A]),
    {quod_read_certificate, 3, Target, ProofId, PlanDigest,
     AnchorRef, CommitteeId, Rows} = Certificate,
    OtherTarget = {<<"quod:other">>, digest(41)},
    OtherRef = certified_ref(F, OtherTarget, 8, digest(42)),
    OtherBlockRef = setelement(6, AnchorRef, digest(48)),
    Mutations =
        [{quod_read_certificate, 3, OtherTarget, ProofId, PlanDigest,
          OtherRef, CommitteeId, Rows},
         {quod_read_certificate, 3, Target, digest(43), PlanDigest,
          AnchorRef, CommitteeId, Rows},
         {quod_read_certificate, 3, Target, ProofId, digest(44),
          AnchorRef, CommitteeId, Rows},
         {quod_read_certificate, 3, Target, ProofId, PlanDigest,
          certified_ref(F, Target, 9, digest(45)), CommitteeId, Rows},
         {quod_read_certificate, 3, Target, ProofId, PlanDigest,
          OtherBlockRef, CommitteeId, Rows},
         {quod_read_certificate, 3, Target, ProofId, PlanDigest,
          AnchorRef, digest(46), Rows}],
    lists:foreach(
      fun(Mutated) ->
              ?assertNot(quod_read_certificate:verify(
                           Mutated, committee(F), CommitteeId))
      end, Mutations).

equivalent_finality_subsets_sign_one_state_statement_test() ->
    F = fixture(4),
    [A, B, C, D] = maps:get(signers, F),
    Target = maps:get(target, F),
    RecordDigest = digest(47),
    RefA = certified_ref(F, Target, 11, RecordDigest, [A, B, C]),
    RefB = certified_ref(F, Target, 11, RecordDigest, [B, C, D]),
    ?assertNotEqual(element(8, RefA), element(8, RefB)),
    ?assertEqual(
       quod_dtx:certified_ref_claim(RefA),
       quod_dtx:certified_ref_claim(RefB)),
    {ok, RowA} = quod_read_certificate:sign(
                   Target, maps:get(proof_id, F),
                   maps:get(plan_digest, F), RefA,
                   maps:get(committee_id, F), A),
    {ok, RowB} = quod_read_certificate:sign(
                   Target, maps:get(proof_id, F),
                   maps:get(plan_digest, F), RefB,
                   maps:get(committee_id, F), B),
    {ok, Certificate} = quod_read_certificate:new(
                          Target, maps:get(proof_id, F),
                          maps:get(plan_digest, F), RefA,
                          maps:get(committee_id, F), [RowA, RowB]),
    ?assert(quod_read_certificate:verify(
              Certificate, committee(F), maps:get(committee_id, F))),
    %% Finality subsets prove the signed anchor claim but are not its identity.
    ?assert(quod_read_certificate:verify(
              setelement(6, Certificate, RefB),
              committee(F), maps:get(committee_id, F))).

fixture(N) ->
    Signers = [signer() || _ <- lists:seq(1, N)],
    Target = {<<"quod:read-target">>, digest(1)},
    F = #{target => Target, proof_id => digest(2), plan_digest => digest(3),
          committee_id => digest(5), signers => Signers},
    F#{anchor_ref => certified_ref(F, Target, 7, digest(4))}.

certificate(F, Signers) ->
    Rows =
        [begin
             {ok, Row} = quod_read_certificate:sign(
                           maps:get(target, F), maps:get(proof_id, F),
                           maps:get(plan_digest, F), maps:get(anchor_ref, F),
                           maps:get(committee_id, F), Signer),
             Row
         end || Signer <- Signers],
    {ok, Certificate} = quod_read_certificate:new(
                          maps:get(target, F), maps:get(proof_id, F),
                          maps:get(plan_digest, F), maps:get(anchor_ref, F),
                          maps:get(committee_id, F), Rows),
    Certificate.

committee(F) ->
    lists:sort([maps:get(pubkey, Signer) || Signer <- maps:get(signers, F)]).

signer() ->
    {Pub, Seed} = quod_identity:generate(),
    #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})}.

certified_ref(F, Target, Slot, RecordDigest) ->
    certified_ref(F, Target, Slot, RecordDigest, maps:get(signers, F)).

certified_ref(F, {Ns, Anchor}, Slot, RecordDigest, Signers) ->
    BlockHash = digest(20 + Slot),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    Shares = [quod_simplex:make_share(
                Domain, commit, Slot, BlockHash, Signer)
              || Signer <- Signers],
    {ok, Cert} = quod_simplex:form_cert(
                   Domain, commit, Slot, BlockHash, Shares, committee(F)),
    {ok, Ref} = quod_dtx:certified_ref(
                  Ns, Anchor, Slot, BlockHash, RecordDigest,
                  term_to_binary(Cert, [deterministic])),
    Ref.

digest(N) ->
    crypto:hash(sha256, <<N:64/unsigned-big>>).

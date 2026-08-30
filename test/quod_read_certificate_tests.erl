-module(quod_read_certificate_tests).

-include_lib("eunit/include/eunit.hrl").

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

every_statement_field_is_signature_bound_test() ->
    F = fixture(1),
    [A] = maps:get(signers, F),
    Certificate = certificate(F, [A]),
    {quod_read_certificate, 2, Target, ProofId, PlanDigest,
     AnchorRef, CommitteeId, Rows} = Certificate,
    OtherTarget = {<<"quod:other">>, digest(41)},
    OtherRef = certified_ref(OtherTarget, 8, digest(42)),
    Mutations =
        [{quod_read_certificate, 2, OtherTarget, ProofId, PlanDigest,
          OtherRef, CommitteeId, Rows},
         {quod_read_certificate, 2, Target, digest(43), PlanDigest,
          AnchorRef, CommitteeId, Rows},
         {quod_read_certificate, 2, Target, ProofId, digest(44),
          AnchorRef, CommitteeId, Rows},
         {quod_read_certificate, 2, Target, ProofId, PlanDigest,
          certified_ref(Target, 9, digest(45)), CommitteeId, Rows},
         {quod_read_certificate, 2, Target, ProofId, PlanDigest,
          AnchorRef, digest(46), Rows}],
    lists:foreach(
      fun(Mutated) ->
              ?assertNot(quod_read_certificate:verify(
                           Mutated, committee(F), CommitteeId))
      end, Mutations).

fixture(N) ->
    Signers = [signer() || _ <- lists:seq(1, N)],
    Target = {<<"quod:read-target">>, digest(1)},
    #{target => Target, proof_id => digest(2), plan_digest => digest(3),
      anchor_ref => certified_ref(Target, 7, digest(4)),
      committee_id => digest(5),
      signers => Signers}.

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

certified_ref({Ns, Anchor}, Slot, RecordDigest) ->
    {ok, Ref} = quod_dtx:certified_ref(
                  Ns, Anchor, Slot, digest(20 + Slot), RecordDigest,
                  term_to_binary({qc, Slot}, [deterministic])),
    Ref.

digest(N) ->
    crypto:hash(sha256, <<N:64/unsigned-big>>).

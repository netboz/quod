-module(quod_atomic_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").
-include("quod_proof_limits.hrl").

%% Real signatures and sealed proof plans, not consensus-admitted votes.
%% References in codec-only cases below are deliberately shape fixtures.

presentation_is_compact_authenticated_and_not_a_vote_test() ->
    F = fixture(), Group = group(F),
    Blob = quod_atomic:encode_group(Group),
    ?assertEqual(quod_atomic:group_binding(Group), quod_atomic:decode_group(Blob)),
    ?assertEqual(error, quod_atomic:decode_material(Blob)),
    ?assertEqual(error, quod_atomic:encoded_record_digest(Blob)),
    [?assertEqual(nomatch, binary:match(Blob, Plan)) || Plan <- maps:values(maps:get(plan_blobs, F))],
    ?assertEqual(error, quod_atomic:decode_group(<<Blob/binary, 0>>)),
    ?assertEqual(error, quod_atomic:decode_group(term_to_binary(setelement(4, Group, none)))).

transport_correlation_does_not_reauthenticate_or_admit_material_test() ->
    F = fixture(), G = group(F), {Ns, _} = T = maps:get(origin, F),
    {ok, Vote} = quod_atomic:new_vote(G, T, bundle(T, F), prepared),
    {ok, Blob} = quod_atomic:encode_record(Vote),
    Digest = quod_atomic:record_digest(Vote), Ref = ref(T, Digest),
    Id = <<55:128>>, Request = {submit, Id, Blob},
    Response = {accepted, Id, Digest, Ref},
    {ok, Count} = signature_count(fun() ->
        {ok, Digest} = quod_atomic:encoded_record_digest(Blob),
        {ok, _} = quod_dtx_endpoint:encode_request(Ns, Request, []),
        true = quod_dtx_endpoint:correlates(Request, Response), ok
    end),
    ?assertEqual(0, Count),
    BadVote = setelement(5, Vote, none),
    BadBlob = term_to_binary(BadVote, [deterministic]),
    %% Framing/correlation is not authorization. The only semantic boundary
    %% rejects the missing own material even though it has canonical bytes.
    ?assertMatch({ok, _}, quod_dtx_endpoint:encode_request(Ns, {submit, Id, BadBlob}, [])),
    ?assertEqual(error, quod_atomic:decode_material(BadBlob)).

presentation_acknowledgment_is_not_a_certified_vote_test() ->
    F = fixture(), G = group(F), {Ns, _} = maps:get(origin, F),
    Id = <<66:128>>, GroupId = quod_atomic:group_id(G),
    Request = {present, Id, GroupId, quod_atomic:encode_group(G)},
    {ok, Encoded} = quod_dtx_endpoint:encode_request(Ns, Request, []),
    ?assertMatch({ok, Request, _, _}, quod_dtx_endpoint:decode_request(Ns, Encoded)),
    ?assert(quod_dtx_endpoint:correlates(Request, {presented, Id, GroupId})),
    ?assertNot(quod_dtx_endpoint:correlates(Request, {presented, Id, <<0:256>>})),
    ?assertNot(quod_dtx_endpoint:correlates(Request, {accepted, Id, <<0:256>>, ref(maps:get(origin, F), <<0:256>>)})),
    ?assertMatch({error, _}, quod_dtx_endpoint:encode_request(Ns, {phase, Id, GroupId, prepare}, [])),
    ?assertMatch({error, _}, quod_dtx_endpoint:encode_response(Ns,
                  {refused, Id, maps:get(origin, F), <<0:256>>, 0, <<>>}, [])).

vote_retains_only_the_voting_roles_bundle_test() ->
    F = fixture(), Group = group(F),
    lists:foreach(fun(Target) ->
        {ok, Vote} = quod_atomic:new_vote(Group, Target, bundle(Target, F), prepared),
        {ok, {Vote, _, #{plans := Plans}}} = quod_atomic:admission_material(Vote),
        ?assertEqual([Target], maps:keys(Plans)),
        {ok, Blob} = quod_atomic:encode_record(Vote),
        ?assertEqual(quod_atomic:admission_material(Vote), quod_atomic:decode_material(Blob)),
        [begin
             ForeignBlob = maps:get(Foreign, maps:get(plan_blobs, F)),
             ?assertEqual(nomatch, binary:match(Blob, ForeignBlob))
         end || Foreign <- maps:get(participant_targets, F), Foreign =/= Target]
    end, maps:get(participant_targets, F)).

negative_vote_can_authenticate_without_any_plan_test() ->
    F = fixture(), Group = group(F), Target = maps:get(origin, F),
    {ok, Vote} = quod_atomic:new_vote(Group, Target, none, {refused, [vote_deadline]}),
    {ok, {Vote, _, #{plans := Plans}}} = quod_atomic:admission_material(Vote),
    ?assertEqual(#{}, Plans),
    ?assertEqual({error, invalid_record}, quod_atomic:new_vote(Group, Target, none, prepared)).

expired_signed_request_remains_authenticatable_for_cleanup_test() ->
    F = fixture(#{deadline => 10}), Group = group(F),
    ?assertMatch({ok, _}, quod_atomic:new_vote(Group, maps:get(origin, F), none,
                                               {refused, [vote_deadline]})),
    %% Positive temporal admission is a certified-block-time check, not codec
    %% validity. Historical positives remain authentic after wall-clock expiry.
    Origin = maps:get(origin, F),
    ?assertMatch({ok, _}, quod_atomic:new_vote(Group, Origin, bundle(Origin, F), prepared)).

changing_deadline_requires_new_source_authentication_test() ->
    F = fixture(), Group = group(F), Manifest = element(3, Group),
    Changed = setelement(13, Manifest, quod_dtx:manifest_deadline(Manifest) - 1),
    ?assertEqual(error, quod_atomic:group_binding(setelement(3, Group, Changed))),
    NewGroup = resigned_group(F, Changed),
    ?assertNotEqual(quod_atomic:group_id(Group), quod_atomic:group_id(NewGroup)),
    ?assertEqual(error, quod_atomic:admission_material(
                         {quod_dtx_vote, 4, NewGroup, maps:get(origin, F),
                          bundle(maps:get(origin, F), F), prepared})).

vote_deadline_may_not_extend_signed_expiry_test() ->
    F = fixture(), M = maps:get(manifest, F),
    Bad = setelement(13, M, maps:get(deadline, F) + 1),
    Origin = maps:get(origin, F),
    {ok, Attestation} = quod_dtx:attest_plan(1, Origin,
                        maps:get(Origin, maps:get(plans, F)), Bad,
                        maps:get(node_identity, F)),
    ?assertEqual({error, invalid_group},
                 quod_atomic:new_group(Bad, maps:get(auth, F), Attestation)).

source_attestation_is_not_optional_or_substitutable_test() ->
    F = fixture(), Group = group(F), Source = element(5, Group),
    [_Origin, Foreign | _] = maps:get(participant_targets, F),
    BadSignature = setelement(7, Source, flipped(element(7, Source))),
    [?assertEqual(error, quod_atomic:group_binding(setelement(5, Group, Bad)))
     || Bad <- [none, BadSignature, element(4, bundle(Foreign, F))]].

signed_request_cannot_be_removed_or_substituted_test() ->
    F = fixture(), Group = group(F), Other = fixture(),
    {agent_goal_v1, Digest, RequestBytes, Signature} = maps:get(auth, F),
    Tampered = {agent_goal_v1, Digest, flipped(RequestBytes), Signature},
    [?assertEqual(error, quod_atomic:group_binding(setelement(4, Group, Bad)))
     || Bad <- [none, maps:get(auth, Other), Tampered]].

own_plan_signature_is_not_replaced_by_source_witness_test() ->
    F = fixture(), Origin = maps:get(origin, F),
    {Origin, D, Blob, A} = bundle(Origin, F),
    {ok, Plan} = quod_dtx:decode(Blob),
    BadPlan = setelement(4, Plan, flipped(element(4, Plan))),
    BadBlob = term_to_binary(BadPlan, [deterministic]),
    ?assertEqual(quod_dtx:digest(Plan), quod_dtx:digest(BadPlan)),
    ?assertEqual({error, invalid_record},
                 quod_atomic:new_vote(group(F), Origin, {Origin, D, BadBlob, A}, prepared)).

foreign_bundle_cannot_stand_in_for_own_material_test() ->
    F = fixture(), [Origin, Target | _] = maps:get(participant_targets, F),
    ?assertEqual({error, invalid_record},
                 quod_atomic:new_vote(group(F), Target, bundle(Origin, F), prepared)).

one_source_attestation_check_even_when_source_votes_test() ->
    F = fixture(), Group = group(F),
    lists:foreach(fun(Target) ->
        {ok, Vote} = quod_atomic:new_vote(Group, Target, bundle(Target, F), prepared),
        {{ok, _}, Count} = signature_count(fun() -> quod_atomic:admission_material(Vote) end),
        %% Client request + own plan + source witness, plus the foreign own
        %% attestation when different. The source witness is not checked twice.
        Expected = case Target =:= maps:get(origin, F) of true -> 3; false -> 4 end,
        ?assertEqual(Expected, Count)
    end, maps:get(participant_targets, F)).

resolve_requires_certified_reference_shapes_not_endpoint_answers_test() ->
    F = fixture(), Group = group(F), Origin = maps:get(origin, F),
    Ref = ref(Origin, <<1:256>>),
    [?assertEqual({error, invalid_record},
                  quod_atomic:new_resolve(Group, Ref, Origin, {abort, [conflict]}, E, none, 0))
     || E <- [{refused, retry}, {refused, not_found}, {refused, {error, refused}}, timeout]],
    ?assertMatch({ok, _}, quod_atomic:new_resolve(Group, Ref, Origin, {abort, [conflict]},
                                                 {refused, Ref}, none, 0)).

reference_vectors_require_exact_name_order_and_unique_targets_test() ->
    F = fixture(), Group = group(F), [Origin, Target | _] = maps:get(participant_targets, F),
    A = ref(Origin, <<1:256>>), B = ref(Target, <<2:256>>),
    [?assertEqual({error, invalid_record},
                  quod_atomic:new_resolve(Group, A, Origin, commit, {all_prepared, Rows}, A, 1))
     || Rows <- [[{Target, B}, {Origin, A}], [{Origin, A}, {Origin, A}],
                  [{Origin, B}], [{Origin, A} | improper], []]].

complete_cannot_omit_any_role_test() ->
    F = fixture(), Group = group(F), Roles = maps:get(participant_targets, F),
    Rows = [{T, ref(T, <<1:256>>), 0} || T <- Roles],
    ?assertMatch({ok, _}, quod_atomic:new_complete(Group, abort, Rows, [])),
    ?assertEqual({error, invalid_record}, quod_atomic:new_complete(Group, abort, tl(Rows), [])),
    ?assertEqual({error, invalid_record}, quod_atomic:new_complete(Group, abort,
                                                                  lists:reverse(Rows), [])).

reference_enumeration_is_exhaustive_and_shared_with_decoded_material_test() ->
    F = fixture(), G = group(F), Origin = maps:get(origin, F), Votes = prepared_votes(F),
    VoteRows = vote_rows(Votes), ORef = vote_ref(Origin, Votes),
    {ok, Vote} = quod_atomic:new_vote(G, Origin, bundle(Origin, F), prepared),
    {ok, Resolve} = quod_atomic:new_resolve(G, ORef, Origin, commit,
                                           {all_prepared, VoteRows}, ORef, 2),
    CompleteRows = [{T, ref(T, <<16:256>>), 0} || T <- maps:get(participant_targets, F)],
    {ok, Complete} = quod_atomic:new_complete(G, abort, CompleteRows, []),
    lists:foreach(fun({Record, Expected}) ->
        {ok, Material} = quod_atomic:admission_material(Record),
        ?assertEqual(Expected, quod_atomic:reference_requirements(Record)),
        ?assertEqual(Expected, quod_atomic:reference_requirements(Material)),
        {ok, Blob} = quod_atomic:encode_record(Record),
        ?assertEqual(Blob, term_to_binary(Record, [deterministic])),
        ?assertMatch({ok, {Record, _, _}}, quod_atomic:decode_material(Blob)),
        ?assertEqual(error, quod_atomic:decode_material(<<Blob/binary, 0>>)),
        ?assertEqual(error, quod_atomic:decode_material(term_to_binary(Record, [compressed]))),
        {ok, Control} = signed(F, Record, quod_atomic:record_target(Record), 1),
        ?assertEqual(Expected, quod_atomic:reference_requirements(Control)),
        {ok, Envelope} = quod_atomic:encode_control(Control),
        ?assertEqual({ok, Control}, quod_atomic:decode_control(Envelope)),
        ?assert(quod_atomic:verify_control(quod_atomic:record_target(Record), Control)),
        ?assert(byte_size(Envelope) =< ?QUOD_MAX_DTX_CONTROL_BYTES),
        ?assert(byte_size(term_to_binary({batch, [{dtx, Envelope}]}, [deterministic]))
                =< ?MAX_BLOCK_BYTES),
        {{ok, Expected}, {call_time, Auth}} = tprof:profile(fun() ->
            quod_atomic:encoded_reference_requirements(Blob)
        end, #{type => call_time, report => return, set_on_spawn => false,
               pattern => [{quod_identity, verify, 3}]}),
        ?assertEqual([], Auth)
    end, [{Vote, []}, {Resolve, [{vote, R} || {_, R} <- VoteRows]},
          {Complete, [{resolve, R} || {_, R, _} <- CompleteRows]}]),
    ?assertEqual(?QUOD_DTX_BATCH_PAYLOAD_OVERHEAD_BYTES,
                 byte_size(term_to_binary({batch, [{dtx, <<>>}]}, [deterministic]))),
    ?assertEqual(?MAX_BLOCK_BYTES - ?QUOD_DTX_BATCH_PAYLOAD_OVERHEAD_BYTES,
                 ?QUOD_MAX_DTX_CONTROL_BYTES),
    ?assertEqual(error, quod_atomic:decode_material(not_binary)),
    ?assertEqual(error, quod_atomic:decode_material(<<0:(?QUOD_MAX_DTX_BODY_BYTES + 1)/unit:8>>)).

optional_hint_selection_never_authenticates_or_admits_a_vote_test() ->
    %% Even malformed group/plan bytes request no foreign references. The
    %% ordinary decoder still rejects them; the selector grants no authority.
    Fake = term_to_binary({quod_dtx_vote, 4, bad_group, bad_target, bad_plan, prepared}, [deterministic]),
    ?assertEqual({ok, []}, quod_atomic:encoded_reference_requirements(Fake)),
    ?assertEqual(error, quod_atomic:decode_material(Fake)),
    [?assertEqual(error, quod_atomic:encoded_reference_requirements(Blob)) ||
        Blob <- [<<>>, <<131>>, term_to_binary({quod_dtx_resolve, 4, bad}),
                 term_to_binary({quod_dtx_complete, 4, bad, bad, bad, abort, [bad], []})]],
    ?assertEqual([], quod_simplex:test_relevant_validation_sidecar({submit, <<1:128>>, Fake}, [])).

old_record_family_has_no_decode_arm_test() ->
    F = fixture(),
    Old = {quod_dtx_begin, 3, maps:get(manifest, F), maps:get(auth, F), maps:get(bundles, F)},
    ?assertEqual(invalid, quod_atomic:record_kind(Old)),
    ?assertEqual(error,
                 quod_atomic:decode_material(term_to_binary(Old, [deterministic]))).

control_decode_carries_material_without_reverification_test() ->
    F = fixture(), Origin = maps:get(origin, F), Group = group(F),
    {ok, Vote} = quod_atomic:new_vote(Group, Origin, bundle(Origin, F), prepared),
    {ok, Control} = signed(F, Vote, Origin, 1),
    {ok, Blob} = quod_atomic:encode_control(Control),
    {{ok, Decoded}, DecodeCount} = signature_count(fun() -> quod_atomic:decode_control(Blob) end),
    ?assertEqual(3, DecodeCount),
    {true, AuthorCount} = signature_count(fun() -> quod_atomic:verify_control(Origin, Decoded) end),
    ?assertEqual(1, AuthorCount),
    {ok, ReadCount} = signature_count(fun() ->
        [begin
            ?assertEqual(Vote, quod_atomic:control_body(Decoded)),
            ?assertMatch({Vote, _, #{plans := _}}, quod_atomic:control_material(Decoded)),
            ?assertEqual(quod_atomic:record_digest(Vote), quod_atomic:record_digest(Decoded)),
            ?assertEqual(vote, quod_atomic:control_kind(Decoded)),
            ?assertEqual(Origin, quod_atomic:control_target(Decoded)),
            ?assertMatch(#{sequence := 1}, quod_atomic:control_metadata(Decoded))
         end || _ <- lists:seq(1, 20)], ok
    end),
    ?assertEqual(0, ReadCount),
    ?assertEqual({ok, Blob}, quod_atomic:encode_control(Decoded)).

owned_control_signing_and_renewal_do_not_reauthenticate_plans_test() ->
    F = fixture(), T = maps:get(origin, F),
    {ok, Vote} = quod_atomic:new_vote(group(F), T, bundle(T, F), prepared),
    {ok, Material} = quod_atomic:admission_material(Vote),
    Signer = maps:get(node_identity, F), Admission = maps:get(admission, F),
    {Controls, Count} = signature_count(fun() ->
        [begin
             {ok, C} = quod_atomic:sign_control(T, Material, Admission, Seq, Seq, Signer), C
         end || Seq <- lists:seq(1, 5)]
    end),
    ?assertEqual(0, Count),
    lists:foreach(fun(C) ->
        ?assertEqual(Material, quod_atomic:control_material(C)),
        ?assert(quod_atomic:verify_control(T, C)),
        {ok, Bytes} = quod_atomic:encode_control(C),
        ?assertEqual({ok, C}, quod_atomic:decode_control(Bytes))
    end, Controls),
    %% Owned material is process-local; a raw record cannot bypass admission.
    ?assertEqual({error, invalid_control}, quod_atomic:sign_control(T, Vote, Admission, 6, 6, Signer)),
    ?assertEqual({error, invalid_control}, quod_atomic:sign_control(
        {<<"wrong">>, <<9:256>>}, Material, Admission, 6, 6, Signer)).

control_wire_cannot_inject_cached_material_test() ->
    F = fixture(), Origin = maps:get(origin, F),
    {ok, Vote} = quod_atomic:new_vote(group(F), Origin, bundle(Origin, F), prepared),
    {ok, Control} = signed(F, Vote, Origin, 1),
    {ok, Blob} = quod_atomic:encode_control(Control),
    Wire = binary_to_term(Blob, [safe]),
    FakeBody = term_to_binary(quod_atomic:control_material(Control), [deterministic]),
    ?assertEqual({error, invalid_control}, quod_atomic:decode_control(
         term_to_binary(setelement(5, Wire, FakeBody), [deterministic]))),
    [?assertEqual({error, invalid_control}, quod_atomic:decode_control(Bad)) ||
        Bad <- [<<0:(?QUOD_MAX_DTX_CONTROL_BYTES + 1)/unit:8>>,
                term_to_binary({'not', a, control}), <<Blob/binary, 0>>,
                term_to_binary(Wire, [compressed])]].

vote_selection_changes_only_the_uncommitted_choice_test() ->
    F = fixture(), T = maps:get(origin, F),
    {ok, Vote} = quod_atomic:new_vote(group(F), T, bundle(T, F), prepared),
    {ok, Material} = quod_atomic:admission_material(Vote),
    {{ok, Negative}, Count} = signature_count(fun() ->
        quod_atomic:select_vote(Material, {refused, [vote_deadline]})
    end),
    ?assertEqual(0, Count),
    {NegativeRecord, NegativeDigest, Meta} = Negative,
    {_, PositiveDigest, Meta} = Material,
    ?assertNotEqual(PositiveDigest, NegativeDigest),
    ?assertEqual(quod_atomic:intent_id(Material), quod_atomic:intent_id(Negative)),
    ?assertEqual(Material, element(2, quod_atomic:select_vote(Negative, prepared))),
    ?assertEqual({ok, Negative}, quod_atomic:select_vote(Negative, {refused, [vote_deadline]})),
    ?assertEqual({ok, Negative}, quod_atomic:admission_material(NegativeRecord)),
    ?assertEqual(error, quod_atomic:select_vote(Material, {refused, []})),
    {ok, EmptyVote} = quod_atomic:new_vote(group(F), T, none, {refused, [vote_deadline]}),
    {ok, Empty} = quod_atomic:admission_material(EmptyVote),
    ?assertEqual(error, quod_atomic:select_vote(Empty, prepared)),
    ?assertEqual(error, quod_atomic:select_vote(Vote, prepared)),
    %% Refusal reasons have one canonical byte identity inside the signed
    %% vote. Selection itself grants no authority to change exposed bytes.
    {ok, {Other, OtherDigest, _}} = quod_atomic:select_vote(Material, {refused, [conflict]}),
    ?assertNotEqual(NegativeDigest, OtherDigest),
    {ok, C} = signed(F, NegativeRecord, T, 1),
    {ok, Encoded} = quod_atomic:encode_control(C),
    Wire = binary_to_term(Encoded, [safe]),
    {ok, OtherBytes} = quod_atomic:encode_record(Other),
    {ok, Tampered} = quod_atomic:decode_control(term_to_binary(
                        setelement(5, Wire, OtherBytes), [deterministic])),
    ?assertNot(quod_atomic:verify_control(T, Tampered)),
    {refused, ReasonsBlob} = element(6, NegativeRecord),
    <<131, 104, Arity, Rest/binary>> = ReasonsBlob,
    Noncanonical = <<131, 105, Arity:32, Rest/binary>>,
    ?assertEqual(binary_to_term(ReasonsBlob, [safe]), binary_to_term(Noncanonical, [safe])),
    ?assertEqual(error, quod_atomic:admission_material(
                         setelement(6, NegativeRecord, {refused, Noncanonical}))).

installed_vote_classification_and_reduction_do_no_signature_work_test() ->
    F = fixture(), Origin = maps:get(origin, F),
    {ok, V} = quod_atomic:new_vote(group(F), Origin, bundle(Origin, F), prepared),
    {ok, C} = signed(F, V, Origin, 1),
    M = quod_atomic:control_material(C), P = quod_atomic:initial_projection(Origin, 0),
    R = ref(Origin, quod_atomic:record_digest(C)),
    {ok, Count} = signature_count(fun() ->
        [begin
            ?assertEqual(ready, quod_atomic:proposal_readiness(M, P)),
            ?assertMatch({ok, _, _, []},
                quod_atomic:reduce(C, R, quod_atomic:initial_group_history(), P))
         end || _ <- lists:seq(1, 20)], ok
    end),
    ?assertEqual(0, Count).

vote_deadline_uses_certified_time_without_renewal_or_signature_work_test() ->
    F = fixture(), Group = group(F), Origin = maps:get(origin, F),
    {ok, #{vote_deadline_ms := Deadline,
           request := #{evidence := #{request := #{network_identity := Network}}}}} =
        quod_atomic:group_binding(Group),
    lists:foreach(fun(Target) ->
        {ok, Positive} = quod_atomic:new_vote(Group, Target, bundle(Target, F), prepared),
        {ok, PC} = signed(F, Positive, Target, 1),
        {ok, Negative} = quod_atomic:new_vote(Group, Target, none, {refused, [vote_deadline]}),
        {ok, NC} = signed(F, Negative, Target, 2),
        PM = quod_atomic:control_material(PC), NM = quod_atomic:control_material(NC),
        {ok, Count} = signature_count(fun() ->
            ?assert(quod_atomic:requires_network_identity(PM)),
            ?assertMatch({ok, _}, quod_atomic:validate_request(Network, Target, Deadline, PM)),
            ?assertEqual({error, vote_deadline},
                         quod_atomic:validate_request(Network, Target, Deadline + 1, PM)),
            ?assertMatch({ok, _}, quod_atomic:validate_request(Network, Target, 16#FFFFFFFFFFFFFFFF, NM)),
            ?assertEqual({error, wrong_network}, quod_atomic:validate_request(<<44:256>>, Target, 0, NM)),
            ?assertEqual({error, invalid_request_binding},
                         quod_atomic:validate_request(Network, {<<"wrong">>, <<1:256>>}, 0, PM)),
            ok
        end),
        ?assertEqual(0, Count)
    end, maps:get(participant_targets, F)),
    ?assert(lists:member(Origin, maps:get(participant_targets, F))).

author_signature_binds_target_sequence_phase_and_timestamp_test() ->
    F = fixture(), [Origin, Target | _] = maps:get(participant_targets, F),
    {ok, Vote} = quod_atomic:new_vote(group(F), Origin, bundle(Origin, F), prepared),
    {ok, Control} = signed(F, Vote, Origin, 1),
    ?assertNot(quod_atomic:verify_control(Target, Control)),
    {ok, Blob} = quod_atomic:encode_control(Control), Wire = binary_to_term(Blob, [safe]),
    lists:foreach(fun({Position, Value}) ->
        {ok, Changed} = quod_atomic:decode_control(term_to_binary(setelement(Position, Wire, Value),
                                                                  [deterministic])),
        ?assertNot(quod_atomic:verify_control(Origin, Changed))
    end, [{8, 2}, {9, 2}, {10, flipped(element(10, Wire))}]),
    [?assertEqual({error, invalid_control}, quod_atomic:decode_control(
         term_to_binary(setelement(P, Wire, V), [deterministic])))
     || {P, V} <- [{3, resolve}, {4, Target}, {2, 2}]].

control_wave_preserves_one_signing_sequence_per_lane_test() ->
    F = fixture(), Origin = maps:get(origin, F),
    {ok, Vote} = quod_atomic:new_vote(group(F), Origin, bundle(Origin, F), prepared),
    {ok, First} = signed(F, Vote, Origin, 1),
    {ok, Second} = signed(F, Vote, Origin, 2),
    ?assert(quod_atomic:canonical_control_wave([First, Second])),
    ?assertNot(quod_atomic:canonical_control_wave([Second, First])),
    ?assertNot(quod_atomic:canonical_control_wave([First, First])),
    ?assertEqual(quod_atomic:record_digest(First), quod_atomic:record_digest(Second)).

commit_evidence_requires_every_roles_exact_positive_vote_test() ->
    F = fixture(), Votes = prepared_votes(F), [Origin, Target | _] = maps:get(participant_targets, F),
    Rows = vote_rows(Votes), ORef = vote_ref(Origin, Votes), Own = vote_ref(Target, Votes),
    {ok, Resolve} = quod_atomic:new_resolve(group(F), ORef, Target, commit,
                                            {all_prepared, Rows}, Own, 1),
    {ok, M} = quod_atomic:admission_material(Resolve),
    ?assertEqual(3, length(quod_atomic:reference_requirements(M))),
    ?assertMatch({ok, {Resolve, _, #{outcome := commit, reasons := none}}},
                 checked(M, Votes)),
    {ok, Omitted} = quod_atomic:new_resolve(group(F), ORef, Target, commit,
        {all_prepared, lists:sublist(Rows, 2)}, Own, 1),
    {ok, Bad} = quod_atomic:admission_material(Omitted),
    ?assertEqual({error, invalid_references}, checked(Bad, Votes)).

positive_vote_is_not_abort_evidence_test() ->
    F = fixture(), Votes = prepared_votes(F), [Origin, Target | _] = maps:get(participant_targets, F),
    {ok, Resolve} = quod_atomic:new_resolve(group(F), vote_ref(Origin, Votes), Target, {abort, [conflict]},
                       {refused, vote_ref(Origin, Votes)}, vote_ref(Target, Votes), 0),
    {ok, M} = quod_atomic:admission_material(Resolve),
    ?assertEqual({error, invalid_references}, checked(M, Votes)).

negative_only_enrollment_supports_an_unvoted_roles_tombstone_test() ->
    F = fixture(), Group = group(F), [Origin, Target, Unvoted] = maps:get(participant_targets, F),
    {ok, O} = quod_atomic:new_vote(Group, Origin, none, {refused, [vote_deadline]}),
    {ok, B} = quod_atomic:new_vote(Group, Target, none, {refused, [conflict]}),
    Votes = [evidence_record(O), evidence_record(B)],
    {ok, Resolve} = quod_atomic:new_resolve(Group, vote_ref(Origin, Votes), Unvoted, {abort, [conflict]},
                                            {refused, vote_ref(Target, Votes)}, none, 0),
    {ok, M} = quod_atomic:admission_material(Resolve),
    ?assertMatch({ok, {Resolve, _, #{outcome := abort, reasons := [conflict]}}}, checked(M, Votes)),
    %% A participant's vote cannot stand in for the source's enrollment.
    Forged = setelement(7, Resolve, vote_ref(Target, Votes)),
    {ok, Bad} = quod_atomic:admission_material(Forged),
    ?assertEqual({error, invalid_references}, checked(Bad, Votes)).

source_refusal_is_sufficient_without_another_groups_claim_test() ->
    F = fixture(), Group = group(F), [Origin, _, Target] = maps:get(participant_targets, F),
    {ok, O} = quod_atomic:new_vote(Group, Origin, none, {refused, [request_claimed]}),
    Votes = [evidence_record(O)],
    [{ORef, _}] = Votes,
    {ok, Resolve} = quod_atomic:new_resolve(Group, ORef, Target, {abort, [request_claimed]},
                                            {refused, ORef}, none, 0),
    {ok, M} = quod_atomic:admission_material(Resolve),
    ?assertEqual([{vote, ORef}], quod_atomic:reference_requirements(M)),
    ?assertMatch({ok, {_, _, #{reasons := [request_claimed]}}}, checked(M, Votes)),
    ?assertEqual(error, quod_atomic:admission_material(
        setelement(8, Resolve, {claimed_elsewhere, ORef}))),
    %% The persisted reason must be exactly the certified refusal's reason,
    %% so replay needs no foreign lookup and the producer cannot invent it.
    {ok, Blob} = quod_wire_term:encode_failure_reasons([vote_deadline]),
    {ok, Changed} = quod_atomic:admission_material(setelement(11, Resolve, Blob)),
    ?assertEqual({error, invalid_references}, checked(Changed, Votes)).

surplus_and_substituted_reference_evidence_is_rejected_test() ->
    F = fixture(), [Origin | _] = maps:get(participant_targets, F), Votes = prepared_votes(F),
    Ref = vote_ref(Origin, Votes),
    {ok, Resolve} = quod_atomic:new_resolve(group(F), Ref, Origin, commit,
                                            {all_prepared, vote_rows(Votes)}, Ref, 1),
    {ok, M} = quod_atomic:admission_material(Resolve), Rows = evidence_rows(M, Votes),
    ?assertEqual({error, invalid_references}, checked_rows(M, tl(Rows))),
    ?assertEqual({error, invalid_references}, checked_rows(M, Rows ++ Rows)),
    [{K, R, _} | Rest] = Rows, [{_, _, Wrong} | _] = Rest,
    ?assertEqual({error, invalid_references}, checked_rows(M, [{K, R, Wrong} | Rest])).

resolve_materialization_uses_the_owned_plan_without_signature_work_test() ->
    F = fixture(), Target = maps:get(origin, F),
    {ok, Vote} = quod_atomic:new_vote(group(F), Target, bundle(Target, F), prepared),
    {ok, Material = {_, _, #{context := Context}}} = quod_atomic:admission_material(Vote),
    Expected = quod_ct:plan_material(diff, maps:get(Target, maps:get(plans, F))),
    {{ok, Context, #{diff := Expected}}, Count} = signature_count(fun() ->
        quod_commit_validation:prepared_material(Material)
    end),
    ?assertEqual(0, Count).

fixture() -> fixture(#{}).
fixture(Options) ->
    Roles = [{<<"quod:atomic-a">>, <<1:256>>}, {<<"quod:atomic-b">>, <<2:256>>},
             {<<"quod:atomic-c">>, <<3:256>>}],
    quod_ct:signed_plan_fixture(Options#{target => hd(Roles), atomic => true}, Roles).
group(F) ->
    Origin = maps:get(origin, F),
    {ok, Group} = quod_atomic:new_group(maps:get(manifest, F), maps:get(auth, F),
                                        maps:get(Origin, maps:get(attestations, F))), Group.
resigned_group(F, M) ->
    Origin = maps:get(origin, F),
    {ok, A} = quod_dtx:attest_plan(1, Origin, maps:get(Origin, maps:get(plans, F)),
                                   M, maps:get(node_identity, F)),
    {ok, G} = quod_atomic:new_group(M, maps:get(auth, F), A), G.
bundle(Target, F) -> lists:keyfind(Target, 1, maps:get(bundles, F)).
signed(F, Vote, Target, Sequence) ->
    {ok, Material} = quod_atomic:admission_material(Vote),
    quod_atomic:sign_control(Target, Material, maps:get(admission, F), Sequence, 1,
                             maps:get(node_identity, F)).
prepared_votes(F) ->
    Group = group(F),
    [begin {ok, V} = quod_atomic:new_vote(Group, T, bundle(T, F), prepared), evidence_record(V) end
     || T <- maps:get(participant_targets, F)].
evidence_record(Record) ->
    {ok, Material} = quod_atomic:admission_material(Record),
    Target = case Record of {quod_dtx_vote, 4, _, T, _, _} -> T;
                           {quod_dtx_resolve, 4, _, T, _, _, _, _, _, _, _} -> T end,
    {ref(Target, quod_atomic:record_digest(Record)), Material}.
vote_rows(Votes) -> lists:sort([{T, Ref} || {Ref, _} <- Votes,
                                           {ok, T, _, _} <- [quod_dtx:certified_ref_binding(Ref)]]).
vote_ref(Target, Votes) -> proplists:get_value(Target, vote_rows(Votes)).
checked(Material, Votes) -> checked_rows(Material, evidence_rows(Material, Votes)).
checked_rows(Material = {Record, _, _}, Rows) ->
    {Pub, Seed} = quod_identity:generate(),
    Signer = #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})},
    Target = element(4, Record),
    {ok, Control} = quod_atomic:sign_control(Target, Material, <<1:256>>, 1, 0, Signer),
    case quod_atomic:validate_references(Control, Rows) of
        ok -> {ok, quod_atomic:control_material(Control)};
        {error, _} = Error -> Error
    end.
evidence_rows(Material, Records) ->
    [begin
         [M] = [M || {R, M} <- Records, quod_dtx:same_certified_ref(R, Required)],
         {Kind, Required, M}
     end || {Kind, Required} <- quod_atomic:reference_requirements(Material)].
ref({Ns, Anchor}, Digest) ->
    {ok, Ref} = quod_dtx:certified_ref(Ns, Anchor, 1, <<44:256>>, Digest,
                                      <<"shape-only-not-certified">>), Ref.
flipped(<<Byte, Rest/binary>>) -> <<(Byte bxor 1), Rest/binary>>.
signature_count(Fun) ->
    {module, quod_identity} = code:ensure_loaded(quod_identity),
    {{Result, Owner}, {call_time, Rows}} = tprof:profile(fun() -> {Fun(), self()} end,
        #{type => call_time, report => return, set_on_spawn => false,
          pattern => [{quod_identity, verify, 3}]}),
    {Result, lists:sum([N || {quod_identity, verify, 3, Ps} <- Rows,
                            {Pid, N, _} <- Ps, Pid =:= Owner])}.

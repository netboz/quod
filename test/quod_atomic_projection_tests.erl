-module(quod_atomic_projection_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_ledger.hrl").
-include("quod_dtx_owner.hrl").
-include("quod_ingress_limits.hrl").

%% These are pure installed-transition tests with real signed/sealed plans.
%% Reference QCs are deliberately shape fixtures, not consensus admission.
%% Time/OCC, real finality and owner/follow integration have separate I1 gates.

source_and_target_use_the_same_vote_and_resolve_transition_test() ->
    F = fixture(), Votes = votes(F),
    lists:foreach(fun(Target) ->
        {H1, P1} = fold(maps:get(Target, Votes), fresh(Target)),
        ?assert(quod_atomic:valid_projection(P1)),
        ?assertEqual([quod_atomic:group_id(maps:get(group, F))], maps:keys(maps:get(groups, P1))),
        ?assertNot(maps:is_key(conflicts, P1)),
        Resolve = resolve(F, Target, commit, Votes, 2),
        {H2, P2} = fold(Resolve, {H1, P1}),
        ?assertEqual(1, maps:get(generation, P2)),
        ?assert(quod_atomic:valid_projection(P2)),
        #{control := C, ref := Ref} = Resolve,
        ?assertMatch({ok, H2, P2, []}, quod_atomic:reduce(C, Ref, H2, P2))
    end, maps:get(participant_targets, F)).

generation_exhaustion_and_restored_material_are_checked_for_both_roles_test() ->
    F = fixture(), Votes = votes(F), Max = 16#FFFFFFFFFFFFFFFF,
    lists:foreach(fun(T) ->
        Vote = maps:get(T, Votes), Id = quod_atomic:group_id(maps:get(control, Vote)),
        {H0, P0} = fresh(T),
        {H, P} = fold(Vote, {H0, P0#{generation := Max}}),
        ?assert(quod_atomic:valid_projection(P)),
        ?assertEqual({error, {invalid_transition, generation_exhausted}},
                     reduce(resolve(F, T, commit, Votes, 2), H, P)),
        {_, BelowLimit} = fold(resolve(F, T, commit, Votes, 2), {H, P#{generation := Max - 1}}),
        ?assertEqual(Max, maps:get(generation, BelowLimit)),
        ?assertEqual({error, invalid_record}, quod_atomic:new_resolve(maps:get(group, F),
            maps:get(ref, maps:get(maps:get(origin, F), Votes)), T, commit,
            {all_prepared, lists:sort([{Role, maps:get(ref, V)} || {Role, V} <- maps:to_list(Votes)])},
            maps:get(ref, Vote), Max + 1)),
        Groups = maps:get(groups, P), Row = maps:get(Id, Groups),
        {Record, Digest, Meta} = maps:get(material, Row),
        Binding = maps:get(group, Meta),
        %% A restored cache must agree with the signed own plan, not merely
        %% with another derived copy of its metadata or conflict descriptor.
        [?assertNot(quod_atomic:valid_projection(P#{groups := Groups#{Id :=
            Row#{material := {Record, Digest, Bad}}}})) || Bad <-
            [Meta#{group := Binding#{principal := anonymous}}, Meta#{plans := #{}}]],
        [?assertNot(quod_atomic:valid_group_history(BadHistory)) || BadHistory <-
            [H#{group_id := none}, H#{records := #{}},
             H#{records := #{vote => #{digest => Digest, ref => maps:get(ref, Vote), surplus => true}}}]],
        ?assertMatch({error, {invalid_transition, bad_binding}},
                     reduce(Vote, H#{group_id := none}, P0))
    end, maps:get(participant_targets, F)).

unvoted_tombstone_leaves_unrelated_reservations_and_apply_fences_unchanged_test() ->
    F = fixture(), Target = foreign(F), Votes = votes(F),
    {H, Locked} = fold(maps:get(Target, Votes), fresh(Target)),
    {_, Applying} = fold(resolve(F, Target, commit, Votes, 2), {H, Locked}),
    Other = fork(F), O = maps:get(origin, Other),
    Negative = #{O => vote(Other, O, none, {refused, [vote_deadline]})},
    Tombstone = resolve(Other, Target, abort, Negative, 0),
    lists:foreach(fun(P) ->
        {_, P} = fold(Tombstone, {quod_atomic:initial_group_history(), P}),
        ?assert(quod_atomic:valid_projection(P))
    end, [Locked, Applying]).

one_vote_is_immutable_even_after_resolution_and_eviction_test() ->
    F = fixture(), Target = foreign(F), Votes = votes(F),
    First = maps:get(Target, Votes),
    {H1, P1} = fold(First, fresh(Target)),
    #{record := {quod_dtx_vote, 4, G, Target, Own, _}} = First,
    {ok, Negative} = quod_atomic:new_vote(G, Target, Own, {refused, [vote_deadline]}),
    Other = envelope(F, Target, Negative, 3),
    ?assertMatch({error, {invalid_transition, semantic_conflict}}, reduce(Other, H1, P1)),
    {H2, P2} = fold(resolve(F, Target, commit, Votes, 2), {H1, P1}),
    ?assertEqual(#{}, maps:get(groups, P2)),
    ?assertMatch({error, {invalid_transition, semantic_conflict}}, reduce(Other, H2, P2)),
    ?assertMatch({ok, H2, P2, []}, reduce(First, H2, P2)).

unvoted_abort_is_an_inert_tombstone_not_an_expiring_vote_test() ->
    F = fixture(), Origin = maps:get(origin, F), Target = foreign(F),
    Negative = vote(F, Origin, none, {refused, [vote_deadline]}),
    Votes = #{Origin => Negative},
    Resolve = resolve(F, Target, abort, Votes, 0),
    {H, P} = fold(Resolve, fresh(Target)),
    ?assertEqual(0, maps:get(generation, P)),
    ?assertEqual(#{}, maps:get(groups, P)),
    ?assertEqual(#{}, maps:get(apply_fences, P)),
    ?assertMatch({error, {invalid_transition, phase_reversal}},
                 reduce(vote(F, Target, own(F, Target), prepared), H, P)),
    ?assert(quod_atomic:valid_projection(P)).

negative_only_source_still_closes_the_complete_group_test() ->
    F = fixture(), Origin = maps:get(origin, F),
    Votes = #{Origin => vote(F, Origin, none, {refused, [vote_deadline]})},
    {H1, P1} = fold(maps:get(Origin, Votes), fresh(Origin)),
    Resolves = maps:from_list([{T, resolve(F, T, abort, Votes, 0)}
                              || T <- maps:get(participant_targets, F)]),
    {H2, P2} = fold(maps:get(Origin, Resolves), {H1, P1}),
    Complete = complete(F, abort, Resolves),
    ?assertEqual(ready, readiness(Complete, P2)),
    {H3, P3} = fold(Complete, {H2, P2}),
    ?assertEqual([complete, resolve, vote], lists:sort(maps:keys(maps:get(records, H3)))),
    ?assertEqual(#{}, maps:get(groups, P3)),
    ?assertEqual(#{}, maps:get(apply_fences, P3)),
    ?assertMatch({ok, H3, P3, []}, reduce(maps:get(Origin, Votes), H3, P3)).

every_committed_vote_activates_only_the_existing_role_duty_test() ->
    F = fixture(), G = maps:get(group, F), Id = quod_atomic:group_id(G),
    {ok, #{vote_deadline_ms := Deadline}} = quod_atomic:group_binding(G),
    Origin = maps:get(origin, F), Target = foreign(F),
    lists:foreach(fun(Choice) ->
        {_, Source} = fold(vote(F, Origin, own(F, Origin), Choice), fresh(Origin)),
        {H, Participant} = fold(vote(F, Target, own(F, Target), Choice), fresh(Target)),
        ?assertEqual([Id], maps:keys(quod_atomic:recovery_rows(Source, Deadline - 1))),
        ?assertEqual(#{}, quod_atomic:recovery_rows(Participant, Deadline - 1)),
        ?assertEqual(#{}, quod_atomic:recovery_rows(Participant, Deadline)),
        ?assertEqual([Id], maps:keys(quod_atomic:recovery_rows(Participant, Deadline + 1))),
        Votes = #{Origin => vote(F, Origin, none, {refused, [vote_deadline]}),
                  Target => vote(F, Target, own(F, Target), Choice)},
        {_, Resolved} = fold(resolve(F, Target, abort, Votes, 1), {H, Participant}),
        ?assertEqual(#{}, quod_atomic:recovery_rows(Resolved, Deadline + 1))
    end, [prepared, {refused, [conflict]}]).

owner_reuses_own_material_with_committed_truth_dominating_pending_test() ->
    F = fixture(), Origin = maps:get(origin, F), Target = foreign(F),
    Source = vote(F, Origin, own(F, Origin), prepared),
    #{control := C, ref := Ref} = Source,
    Id = quod_atomic:group_id(C),
    Pending = [quod_atomic:control_material(C)],
    {_, Empty} = fresh(Origin),
    #{Id := #{material := Material, ref := none}} =
        quod_dtx_owner:desired(binding(Origin), Empty, Pending, 0),
    ?assertEqual(quod_atomic:control_material(C), Material),
    {_, P} = fold(Source, fresh(Origin)),
    ?assertMatch(#{Id := #{material := Material, ref := Ref}},
        quod_dtx_owner:desired(binding(Origin), P, Pending, 0)),
    %% No dependency on the original executor's key: all current source
    %% committee members derive the same own-role work.
    ?assertEqual(quod_dtx_owner:desired(binding(Origin), P, Pending, 0),
        quod_dtx_owner:desired(other_binding(Origin), P, Pending, 0)),
    #{control := TargetC} = vote(F, Target, own(F, Target), prepared),
    {_, TargetEmpty} = fresh(Target),
    ?assertEqual(#{}, quod_dtx_owner:desired(binding(Target), TargetEmpty, [quod_atomic:control_material(TargetC)],
                                            16#FFFFFFFFFFFFFFFF)),
    ?assertEqual(#{}, quod_dtx_owner:desired({error, not_in_charge}, P, Pending, 0)).

indexed_tombstone_refuses_a_late_vote_after_active_row_eviction_test() ->
    F = fixture(), Origin = maps:get(origin, F), Target = foreign(F),
    Votes = #{Origin => vote(F, Origin, none, {refused, [vote_deadline]})},
    {H, P} = fold(resolve(F, Target, abort, Votes, 0), fresh(Target)),
    #{control := C} = vote(F, Target, own(F, Target), prepared),
    ?assertEqual(stale, quod_dtx_owner:admission(quod_atomic:control_material(C), H, P)),
    First = #{control := C1, ref := Ref} = maps:get(Origin, Votes),
    {H1, P1} = fold(First, fresh(Origin)),
    ?assertEqual({included, Ref},
        quod_dtx_owner:admission(quod_atomic:control_material(C1), H1, P1)).

retained_control_has_no_second_material_copy_test() ->
    F = fixture(), Origin = maps:get(origin, F),
    #{control := C} = vote(F, Origin, own(F, Origin), prepared),
    ?assertEqual(1, quod_dtx_owner:count(retained(C))),
    [Row] = maps:values(quod_dtx_owner:rows(retained(C))),
    ?assertNot(lists:member(material, record_info(fields, dtx_submission))),
    Other = vote(F, Origin, own(F, Origin), {refused, [vote_deadline]}),
    ?assertException(error, {badmatch, _},
        quod_dtx_owner:put_new(Row#dtx_submission{control = maps:get(control, Other)},
                              quod_dtx_owner:new())).

complete_requires_exact_source_application_ack_live_but_not_on_replay_test() ->
    F = fixture(), Origin = maps:get(origin, F), Votes = votes(F),
    {H1, P1} = fold(maps:get(Origin, Votes), fresh(Origin)),
    Resolves = maps:from_list([{T, resolve(F, T, commit, Votes, 2)}
                              || T <- maps:get(participant_targets, F)]),
    OwnResolve = maps:get(Origin, Resolves),
    {H2, P2} = fold(OwnResolve, {H1, P1}),
    Complete = complete(F, commit, Resolves),
    ?assertEqual({blocked, apply}, readiness(Complete, P2)),
    #{control := CompleteControl} = Complete,
    ?assertEqual({error, {invalid_transition, apply}},
                 quod_atomic:preview_batch([{CompleteControl, Origin, 3, <<3:256>>}],
                   #{quod_atomic:group_id(maps:get(group, F)) => H2}, P2)),
    Id = quod_atomic:group_id(maps:get(group, F)),
    ?assertEqual({error, stale_resolve_ack}, quod_atomic:acknowledge_resolve(Id, 3, 0, P2)),
    ?assertEqual({error, stale_resolve_ack}, quod_atomic:acknowledge_resolve(Id, 4, 2, P2)),
    {ok, P3} = quod_atomic:acknowledge_resolve(Id, 3, 2, P2),
    ?assertEqual(ready, readiness(Complete, P3)),
    ?assert(quod_atomic:valid_projection(P3)),
    %% Certified replay consumes the exact fence represented in Complete.
    %% Live proposal eligibility is separately checked before certification.
    ?assertEqual(fold(Complete, {H2, P3}), fold(Complete, {H2, P2})).

verified_suffix_does_not_resurrect_an_acknowledged_prefix_fence_test() ->
    F = fixture(), Target = foreign(F), Votes = votes(F),
    {H1, P1} = fold(maps:get(Target, Votes), fresh(Target)),
    {_H2, P2} = fold(resolve(F, Target, commit, Votes, 2), {H1, P1}),
    Id = quod_atomic:group_id(maps:get(group, F)),
    {ok, P3} = quod_atomic:acknowledge_resolve(Id, 3, 2, P2),
    ?assertEqual(#{}, maps:get(apply_fences, P3)),
    ?assertEqual(P3, quod_atomic:install_projection(P2, P3, 3)),
    ?assertEqual(P2, quod_atomic:install_projection(P2, P3, 2)),
    ?assertEqual(P3, quod_atomic:install_projection(P3, P2, 3)).

resolve_must_bind_the_exact_local_vote_and_generation_test() ->
    F = fixture(), Target = foreign(F), Votes = votes(F),
    {H, P} = fold(maps:get(Target, Votes), fresh(Target)),
    ?assertMatch({error, {invalid_transition, participant_phase}},
                 reduce(resolve(F, Target, commit, Votes, 0), H, P)),
    ?assertMatch({error, {invalid_transition, participant_phase}},
                 reduce(resolve(F, Target, commit, Votes, 3), H, P)),
    BadTarget = maps:get(origin, F),
    ?assertMatch({error, {invalid_transition, bad_binding}},
                 reduce(resolve(F, BadTarget, commit, Votes, 2), H, P)).

certified_replay_needs_no_ephemeral_foreign_validation_state_test() ->
    F = fixture(), Target = foreign(F), Votes = votes(F),
    {H, P} = fold(maps:get(Target, Votes), fresh(Target)),
    R = #{control := C} = resolve(F, Target, commit, Votes, 2),
    {ok, Wire} = quod_atomic:encode_control(C),
    {ok, Decoded} = quod_atomic:decode_control(Wire),
    %% Voting still requires exact foreign evidence. Once certified, the same
    %% reducer can restore from local bytes without re-fetching other ledgers.
    ?assertEqual({error, invalid_references}, quod_atomic:validate_references(Decoded, [])),
    ?assertEqual(reduce(R, H, P), reduce(R#{control := Decoded}, H, P)),
    ?assertEqual(quod_atomic:control_material(C), quod_atomic:control_material(Decoded)).

complete_verifies_required_certificates_from_its_record_not_sidecars_test() ->
    %% Resolve blocks have real quorum signatures here. The earlier Vote refs
    %% remain the explicit shape fixtures: this tests the AM3 boundary, not
    %% complete ledger founding or end-to-end consensus admission.
    F = fixture(), Votes = votes(F), Origin = maps:get(origin, F), Target = foreign(F),
    Signers = lists:sort([maps:get(node_identity, F) | [signer() || _ <- lists:seq(1, 3)]]),
    Committee = lists:sort([maps:get(pubkey, S) || S <- Signers]),
    Resolves = maps:from_list([{T, certified_resolve(resolve(F, T, commit, Votes, 2), Signers)}
                               || T <- maps:get(participant_targets, F)]),
    TargetRef = maps:get(ref, maps:get(Target, Resolves)), Id = quod_atomic:group_id(maps:get(group, F)),
    SignedRows = lists:sort([begin
        {ok, Row} = quod_applied_certificate:sign_applied_vote(
                      <<8:256>>, Target, <<9:256>>, Id, TargetRef, 2, commit, Signer), Row
    end || Signer <- lists:sublist(Signers, 2)]),
    {ok, Certificate} = quod_applied_certificate:applied_certificate(
                         {<<8:256>>, Target, <<9:256>>, Id, TargetRef, 2, commit}, SignedRows),
    ResolveRows = lists:sort([{T, maps:get(ref, R), 2} || {T, R} <- maps:to_list(Resolves)]),
    {ok, Record} = quod_atomic:new_complete(maps:get(group, F), commit, ResolveRows, [{Target, Certificate}]),
    #{control := C} = checked(envelope(F, Origin, Record, 3), maps:values(Resolves)),
    Evidence = [{resolve, maps:get(ref, R), #{identity => T, phase => resolve,
                  control => maps:get(control, R), entry => maps:get(entry, R),
                  committee => Committee, committee_id => <<9:256>>}}
                || {T, R} <- lists:sort(maps:to_list(Resolves))],
    ?assertEqual(valid, quod_simplex:test_verify_complete_applied(C, Evidence, <<8:256>>)),
    ?assertEqual({invalid, malformed_applied_claim},
                 quod_simplex:test_verify_complete_applied(C, Evidence, <<88:256>>)),
    [{Key, _} | Rest] = SignedRows,
    BadCertificate = setelement(10, Certificate, [{Key, <<0:512>>} | Rest]),
    BadRecord = setelement(8, Record, [{Target, BadCertificate}]),
    #{control := Bad} = checked(envelope(F, Origin, BadRecord, 3), maps:values(Resolves)),
    ?assertEqual({invalid, malformed_applied_claim},
                 quod_simplex:test_verify_complete_applied(Bad, Evidence, <<8:256>>)),
    #{control := Omitted} = envelope(F, Origin, setelement(8, Record, []), 3),
    ?assertEqual({error, invalid_references}, quod_simplex:test_validate_dtx_reference_evidence(
      Omitted, [{K, R, maps:get(control, E)} || {K, R, E} <- Evidence])),
    ?assertEqual({ok, Origin}, quod_simplex:test_dtx_source_identity(
      maps:get(record, maps:get(Target, Resolves)), Target)).

resolve_application_certificate_uses_the_published_floor_not_a_staged_row_test() ->
    F = fixture(), T = foreign(F), {Ns, Anchor} = T,
    Signers = [maps:get(node_identity, F) | [signer() || _ <- lists:seq(1, 3)]],
    Committee = lists:sort([maps:get(pubkey, S) || S <- Signers]),
    #{control := C, ref := Ref, entry := Entry} =
        certified_control(resolve(F, T, commit, votes(F), 2), Signers, 2),
    Id = quod_atomic:group_id(C), Signer = hd(Signers), Self = maps:get(pubkey, Signer),
    Evidence = #{identity => T, phase => resolve, control => C, entry => Entry,
                 committee => Committee, committee_id => <<9:256>>},
    Request = {applied, <<52:128>>, Id, Ref, 2, commit},
    Key = {Id, Ref, 2, commit},
    %% Even a matching staged row is not the publication boundary.
    Staged = #{applied => #{resolve_ref => Ref, generation => 2, verdict => commit},
               applied_floor => 1, generation => 999},
    ?assertEqual({wait, Key}, quod_simplex:test_waiting_applied_key(
                              Request, {applied_state, Evidence, Staged})),
    quod_ct:with_network_identity(<<8:256>>, fun() ->
        lists:foreach(fun(AppliedRow) ->
            Snapshot = #{applied => AppliedRow, applied_floor => 2, generation => 999},
            S = state(#{ns => Ns, genesis_hash => Anchor,
                  self => Self, id => Signer, validators => Committee, slot => 2,
                  sync => ready, prolog_ready => true, store => memory,
                  dtx_projection => quod_atomic:initial_projection(T, 999)}),
            ?assertEqual(ready, quod_simplex:test_waiting_applied_key(
                                 Request, {applied_state, Evidence, Snapshot})),
            {applied, _, T, <<9:256>>, Id, Ref, 2, commit, Self, Signature} =
                quod_simplex:test_dtx_endpoint_result(Request, {applied_state, Evidence, Snapshot}, S),
            ?assert(quod_applied_certificate:applied_vote_valid(
                <<8:256>>, T, <<9:256>>, Id, Ref, 2, commit, Self, Signature)),
            ?assertMatch({error, _, not_found}, quod_simplex:test_dtx_endpoint_result(
                Request, {applied_state, Evidence, Staged},
                quod_simplex:test_state_set(slot, 1, S)))
        end, [maps:get(applied, Staged), none])
    end).

resolve_application_certificate_rejects_every_mismatched_binding_test() ->
    F = fixture(), T = foreign(F), {Ns, Anchor} = T, Signer = maps:get(node_identity, F),
    #{control := C, ref := Ref, entry := Entry} =
        certified_control(resolve(F, T, commit, votes(F), 2), [Signer], 2),
    Id = quod_atomic:group_id(C), Self = maps:get(pubkey, Signer),
    E = #{identity => T, phase => resolve, control => C, entry => Entry,
          committee => [Self], committee_id => <<9:256>>},
    R = {applied, <<53:128>>, Id, Ref, 2, commit},
    Snapshot = #{applied => none, applied_floor => 2, generation => 0},
    S = state(#{ns => Ns, genesis_hash => Anchor, self => Self,
          id => Signer, validators => [Self], slot => 2, sync => ready,
          prolog_ready => true, store => memory}),
    Cases = [{setelement(3, R, <<99:256>>), E},
             {setelement(4, R, setelement(6, Ref, <<99:256>>)), E},
             {setelement(5, R, 3), E}, {setelement(6, R, abort), E},
             {R, E#{identity := maps:get(origin, F)}}, {R, E#{phase := vote}},
             {R, E#{control := maps:get(control, maps:get(T, votes(F)))}}],
    quod_ct:with_network_identity(<<8:256>>, fun() ->
        lists:foreach(fun({Request, Evidence}) ->
            ?assertMatch({error, _, not_found}, quod_simplex:test_dtx_endpoint_result(
                Request, {applied_state, Evidence, Snapshot}, S))
        end, Cases)
    end).

signer() ->
    {Pub, Seed} = quod_identity:generate(),
    #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})}.

submission_correlation_does_not_substitute_for_the_certified_vote_test() ->
    F = fixture(), T = foreign(F), {Ns, Anchor} = T, Id = quod_atomic:group_id(maps:get(group, F)),
    #{record := Proposed} = vote(F, T, own(F, T), prepared),
    {ok, Blob} = quod_atomic:encode_record(Proposed), Digest = quod_atomic:record_digest(Proposed),
    Signers = [maps:get(node_identity, F) | [signer() || _ <- lists:seq(1, 3)]],
    Committee = lists:sort([maps:get(pubkey, S) || S <- Signers]),
    #{control := Negative, ref := Ref, entry := Entry} =
        certified_control(vote(F, T, own(F, T), {refused, [vote_deadline]}), Signers, 2),
    Request = {submit, <<67:128>>, Blob}, Response = {accepted, <<67:128>>, Digest, Ref},
    ?assertNotEqual(Digest, quod_atomic:record_digest(Negative)),
    ?assert(quod_dtx_endpoint:correlates(Request, Response)),
    ?assertNot(quod_dtx_endpoint:correlates(Request, setelement(2, Response, <<68:128>>))),
    ?assertNot(quod_dtx_endpoint:correlates(Request, setelement(3, Response, <<99:256>>))),
    S = state(#{ns => Ns, genesis_hash => Anchor}),
    ?assertEqual(Response, quod_simplex:test_dtx_endpoint_result(
                             Request, {submit_result, Digest, {ok, Ref, []}}, S)),
    ?assert(quod_dtx:certified_entry_claim_matches(T, Entry, Negative, Ref)),
    Evidence = #{identity => T, phase => vote, ref => Ref, control => Negative, entry => Entry,
                  committee => Committee, committee_id => <<9:256>>, routes => #{}},
    ?assertMatch({ok, Negative, _, _},
        quod_dtx_coordinator:test_valid_phase_evidence(T, Id, vote, Ref, Evidence)),
    %% Correlation alone cannot admit another group or a substituted entry.
    ?assertEqual(error, quod_dtx_coordinator:test_valid_phase_evidence(T, <<99:256>>, vote, Ref, Evidence)),
    #{entry := OtherEntry} = certified_control(vote(F, T, own(F, T), prepared), Signers, 2),
    ?assertEqual(error, quod_dtx_coordinator:test_valid_phase_evidence(
                        T, Id, vote, Ref, Evidence#{entry := OtherEntry})).

certified_resolve(Row, Signers) ->
    certified_control(Row, Signers, 2).

certified_control(#{control := Control} = Row, Signers, Slot) ->
    {Ns, Anchor} = Target = quod_atomic:control_target(Control),
    Era = quod_ledger:initial_era(Target), Position = {Era, Slot - 1},
    {ok, Block} = quod_ledger:new_block(Position, {Era, Slot - 2, Anchor},
                                      Slot, {batch, [{dtx, Control}]}, 1),
    Hash = quod_simplex:block_hash(Block), Domain = quod_simplex:consensus_domain(Ns, Anchor),
    Shares = lists:sort([begin
        #share{sig = Sig} = quod_simplex:make_share(Domain, commit, Position, Hash, S),
        {maps:get(pubkey, S), Sig}
    end || S <- lists:sublist(Signers, 3)]),
    Cert = #cert{kind = commit, era = Era, slot = Slot - 1, block_hash = Hash, sigs = Shares},
    ?assert(quod_simplex:verify_cert(Domain, Cert, lists:sort([maps:get(pubkey, S) || S <- Signers]))),
    Entry = quod_ledger:entry(Slot, Block, Cert),
    {ok, Ref} = quod_dtx:certified_entry_ref(Target, Entry, Control),
    ?assert(quod_dtx:certified_entry_claim_matches(Target, Entry, Control, Ref)),
    Row#{ref := Ref, entry => Entry}.

same_request_conflict_waits_in_both_group_orders_test() ->
    F = fixture(), F2 = fork(F), Target = foreign(F),
    lists:foreach(fun({First, Second}) ->
        {_, P} = fold(vote(First, Target, own(First, Target), prepared), fresh(Target)),
        Candidate = vote(Second, Target, own(Second, Target), prepared),
        ?assertEqual({blocked, active_group}, readiness(Candidate, P))
    end, [{F, F2}, {F2, F}]).

different_request_conflicts_keep_one_wait_die_order_test() ->
    A = fixture(), B = fixture(#{operation_id => <<123:256>>}),
    Target = foreign(A),
    {Older, Younger} = case quod_atomic:group_id(maps:get(group, A)) <
                           quod_atomic:group_id(maps:get(group, B)) of
                          true -> {A, B}; false -> {B, A}
                      end,
    {_, PO} = fold(vote(Older, Target, own(Older, Target), prepared), fresh(Target)),
    {_, PY} = fold(vote(Younger, Target, own(Younger, Target), prepared), fresh(Target)),
    ?assertEqual({refused, conflict}, readiness(vote(Younger, Target, own(Younger, Target), prepared), PO)),
    ?assertEqual({blocked, active_group}, readiness(vote(Older, Target, own(Older, Target), prepared), PY)).

negative_vote_reserves_nothing_even_with_retained_own_material_test() ->
    F = fixture(), F2 = fork(F), Target = foreign(F),
    {_, P} = fold(vote(F, Target, own(F, Target), {refused, [vote_deadline]}), fresh(Target)),
    ?assertEqual(ready, readiness(vote(F2, Target, own(F2, Target), prepared), P)).

content_uses_the_same_reservation_until_resolve_test() ->
    F = fixture(), Target = foreign(F), Votes = votes(F),
    Plan = maps:get(Target, maps:get(plans, F)),
    {ok, #{diff := Diff, read_check := Reads, effects := Effects}} = quod_dtx:material(Plan),
    Content = #transaction{diff = Diff, read_check = Reads, effects = Effects},
    {H, P} = fold(maps:get(Target, Votes), fresh(Target)),
    ?assertEqual({blocked, active_group}, quod_atomic:content_readiness(Content, P)),
    {_, Applied} = fold(resolve(F, Target, commit, Votes, 2), {H, P}),
    ?assertEqual(ready, quod_atomic:content_readiness(Content, Applied)).

phase_index_captures_hide_later_records_of_the_same_group_test() ->
    with_index(fun(Index) ->
        F = fixture(), Target = foreign(F), Votes = votes(F),
        V = #{control := VC, ref := VR} = maps:get(Target, Votes),
        R = #{control := RC, ref := RR} = resolve(F, Target, commit, Votes, 2),
        {_, Initial} = fresh(Target),
        {ok, P1, _} = quod_dtx_phase_index:apply_batch(Index, [{VC, VR}], Initial),
        {ok, Capture} = quod_dtx_phase_index:capture(Index, 2),
        {ok, P2, _} = quod_dtx_phase_index:apply_batch(Index, [{RC, RR}], P1),
        {H1, P1} = fold(V, fresh(Target)),
        {H2, P2} = fold(R, {H1, P1}),
        Id = quod_atomic:group_id(maps:get(group, F)),
        ?assertEqual({ok, H1}, quod_dtx_phase_index:history(Capture, Id)),
        ?assertEqual({ok, H2}, quod_dtx_phase_index:history(Index, Id)),
        ?assertEqual({error, bad_phase_index_delta},
                     quod_dtx_phase_index:commit_delta(Capture, quod_dtx_phase_index:new_delta()))
    end).

phase_index_delta_needs_the_existing_explicit_install_test() ->
    with_index(fun(Index) ->
        F = fixture(), Target = foreign(F),
        #{control := C, ref := R} = vote(F, Target, own(F, Target), prepared),
        {_, Initial} = fresh(Target),
        Id = quod_atomic:group_id(maps:get(group, F)),
        {ok, Delta, P, _} = quod_dtx_phase_index:preview_batch(
                             Index, quod_dtx_phase_index:new_delta(), [{C, R}], Initial),
        ?assertEqual({ok, quod_atomic:initial_group_history()}, quod_dtx_phase_index:history(Index, Id)),
        ok = quod_dtx_phase_index:commit_delta(Index, Delta),
        ?assertEqual({ok, P, [#{control => C, ref => R, history =>
            element(2, quod_dtx_phase_index:history(Index, Id)), projection => P, effects => []}]},
            quod_dtx_phase_index:apply_batch(Index, [{C, R}], P))
    end).

phase_index_refuses_old_format_and_wrong_group_key_test() ->
    with_index(fun(Index) ->
        F = fixture(), Target = foreign(F),
        {H, _} = fold(vote(F, Target, own(F, Target), prepared), fresh(Target)),
        Id = quod_atomic:group_id(maps:get(group, F)), Other = <<55:256>>,
        ok = quod_dtx_phase_index:test_insert_raw(Index, Id,
               term_to_binary({quod_dtx_phase_history, 1, H}, [deterministic])),
        ?assertEqual({error, {unsupported_dtx_phase_history, 1}}, quod_dtx_phase_index:history(Index, Id)),
        ok = quod_dtx_phase_index:test_insert_raw(Index, Other,
               term_to_binary({quod_dtx_phase_history, 2, H}, [deterministic])),
        ?assertEqual({error, phase_index_corrupt}, quod_dtx_phase_index:history(Index, Other))
    end).

restored_projection_rejects_missing_or_substituted_source_fence_test() ->
    F = fixture(), Target = maps:get(origin, F), Votes = votes(F),
    {H, P} = fold(maps:get(Target, Votes), fresh(Target)),
    {_, Resolved} = fold(resolve(F, Target, commit, Votes, 2), {H, P}),
    ?assertNot(quod_atomic:valid_projection(Resolved#{apply_fences := #{}})),
    Id = quod_atomic:group_id(maps:get(group, F)),
    ?assertNot(quod_atomic:valid_projection(Resolved#{apply_fences :=
                  #{Id => #{slot => 99, generation => 2, blocking => true}}})),
    ?assertNot(quod_atomic:valid_projection(P#{conflicts => #{}})).

era_preview_uses_the_shared_transition_without_a_fake_certificate_test() ->
    F = quod_ct:atomic_role_fixture(), Target = maps:get(origin, F),
    Control = maps:get(source_control, F), Certified = maps:get(source_ref, F),
    Id = quod_atomic:group_id(Control), Empty = quod_atomic:initial_group_history(),
    Projection = quod_atomic:initial_projection(Target, 0),
    {ok, Histories, Preview, [#{ref := Provisional, effects := []}]} =
        quod_atomic:preview_batch([{Control, Target, 2, <<106:256>>}], #{}, Projection),
    ?assertEqual(error, quod_dtx:certified_ref_binding(Provisional)),
    ?assertNot(quod_atomic:valid_group_history(maps:get(Id, Histories))),
    ?assertNot(quod_atomic:valid_projection(Preview)),
    ?assertEqual({error, {invalid_transition, bad_binding}},
                 quod_atomic:reduce(Control, Provisional, Empty, Projection)),
    %% Certified application performs the same transition, with the actual
    %% reference replacing the provisional location. No preview result can
    %% be mistaken for durable evidence at the public reducer boundary.
    {ok, History, Committed, []} = quod_atomic:reduce(Control, Certified, Empty, Projection),
    PH = maps:get(Id, Histories), Vote = maps:get(vote, maps:get(records, PH)),
    ?assertEqual(PH#{records := #{vote => Vote#{ref := Certified}}}, History),
    Rows = maps:get(groups, Preview), Role = maps:get(Id, Rows),
    ?assertEqual(Preview#{groups := Rows#{Id => Role#{ref := Certified}}}, Committed).

planner_queries_before_any_exact_submission_test() ->
    F = fixture(), Origin = maps:get(origin, F),
    Vote = vote(F, Origin, own(F, Origin), prepared),
    Own = (role(Vote))#{ref := none}, Id = quod_atomic:group_id(maps:get(group, F)),
    Empty = quod_dtx_recovery:empty(),
    ?assertEqual({ok, {ordered, vote, [{phase, Origin, Id, vote}]}},
                 quod_dtx_recovery:next(Own, Empty)),
    Absent = quod_dtx_recovery:absent(Origin, vote, Empty),
    ?assertEqual({ok, {ordered, vote, [{submit, Origin, maps:get(record, Vote)}]}},
                 quod_dtx_recovery:next(Own, Absent)),
    ?assertEqual(Empty, quod_dtx_recovery:progress(Origin, Absent)).

planner_all_positive_votes_go_directly_to_one_resolve_wave_test() ->
    F = fixture(), Votes = votes(F), Origin = maps:get(origin, F),
    Own = role(maps:get(Origin, Votes)),
    S0 = observed(Own, maps:values(Votes), quod_dtx_recovery:empty()),
    Id = quod_atomic:group_id(maps:get(group, F)),
    Targets = maps:get(participant_targets, F),
    ?assertEqual({ok, {independent, resolve, [{phase, T, Id, resolve} || T <- Targets]}},
                 quod_dtx_recovery:next(Own, S0)),
    S1 = absent_resolves(Targets, S0),
    {ok, {independent, resolve, Commands}} = quod_dtx_recovery:next(Own, S1),
    ?assertEqual(Targets, [T || {submit, T, _} <- Commands]),
    [?assertMatch({quod_dtx_resolve, 4, Id, T, _, commit, _, {all_prepared, _}, _, 2, none}, R)
     || {submit, T, R} <- Commands],
    %% Verification may transiently read a peer's entry. The planner snapshot
    %% retains neither its plan nor its control/entry wrapper.
    SnapshotBytes = term_to_binary(S1),
    [?assertEqual(nomatch, binary:match(SnapshotBytes, Blob))
     || {_, _, Blob, _} <- maps:get(bundles, F)].

planner_delivery_requires_new_progress_after_consumed_absence_test() ->
    F = fixture(), Origin = maps:get(origin, F), Target = foreign(F), G = maps:get(group, F),
    Id = quod_atomic:group_id(G),
    Source = (role(vote(F, Origin, own(F, Origin), prepared)))#{ref := none},
    Participant = role(vote(F, Target, none, {refused, [vote_deadline]})),
    lists:foreach(fun(Own) ->
        Absent = quod_dtx_recovery:absent(Origin, vote, quod_dtx_recovery:empty()),
        ?assertMatch({ok, {ordered, vote, [_]}}, quod_dtx_recovery:next(Own, Absent)),
        Sent = quod_dtx_recovery:attempted(Origin, vote, Absent),
        ?assertEqual(wait, quod_dtx_recovery:next(Own, Sent)),
        ?assertEqual(wait, quod_dtx_recovery:next(Own, quod_dtx_recovery:absent(Origin, vote, Sent))),
        ?assertEqual(wait, quod_dtx_recovery:next(Own, quod_dtx_recovery:progress(Target, Sent))),
        Wake = quod_dtx_recovery:progress(Origin, Sent),
        ?assertEqual({ok, {ordered, vote, [{phase, Origin, Id, vote}]}},
                     quod_dtx_recovery:next(Own, Wake)),
        ?assertMatch({ok, {ordered, vote, [_]}},
                     quod_dtx_recovery:next(Own, quod_dtx_recovery:absent(Origin, vote, Wake)))
    end, [Source, Participant]).

planner_consumed_target_does_not_block_other_resolves_test() ->
    F = fixture(), Origin = maps:get(origin, F), Target = foreign(F), Votes = votes(F),
    Own = role(maps:get(Origin, Votes)),
    Snapshot = absent_resolves(maps:get(participant_targets, F),
                 observed(Own, maps:values(Votes), quod_dtx_recovery:empty())),
    Sent = quod_dtx_recovery:attempted(Target, resolve, Snapshot),
    {ok, {independent, resolve, Commands}} = quod_dtx_recovery:next(Own, Sent),
    ?assertEqual([Origin], [T || {submit, T, _} <- Commands]),
    ?assertEqual(wait, quod_dtx_recovery:next(Own,
                      quod_dtx_recovery:attempted(Origin, resolve, Sent))).

coordinator_observation_retains_no_foreign_vote_and_does_not_reauthenticate_test() ->
    F = fixture(), Origin = maps:get(origin, F), Target = foreign(F), Votes = votes(F),
    Own = role(maps:get(Origin, Votes)),
    Signers = lists:sort([maps:get(node_identity, F) | [signer() || _ <- lists:seq(1, 3)]]),
    Committee = lists:sort([maps:get(pubkey, S) || S <- Signers]),
    V = certified_resolve(maps:get(Target, Votes), Signers),
    R = certified_resolve(resolve(F, Target, commit, Votes, 2), Signers),
    SourceR = certified_resolve(resolve(F, Origin, commit, Votes, 2), Signers),
    Rows = [begin
        #{ref := Ref, control := Control, entry := Entry} = Row,
        T = quod_atomic:control_target(Control), K = quod_atomic:control_kind(Control),
        {T, K, Ref, #{identity => T, phase => K, ref => Ref, control => Control, entry => Entry,
                     generation => 999, committee => Committee, committee_id => <<9:256>>, routes => #{}}}
    end || Row <- [V, R, SourceR]],
    {module, quod_identity} = code:ensure_loaded(quod_identity),
    {{View, Owner}, {call_time, Counts}} = tprof:profile(fun() ->
        {quod_dtx_coordinator:test_observation_updates(Own, Rows ++ Rows,
                                                      quod_dtx_recovery:empty()), self()}
    end, #{type => call_time, report => return, set_on_spawn => false,
           pattern => [{quod_identity, verify, 3}]}),
    ?assertEqual(0, lists:sum([N || {quod_identity, verify, 3, Ps} <- Counts,
                                   {Pid, N, _} <- Ps, Pid =:= Owner])),
    #{snapshot := Snapshot, resolve_evidence := Artifacts} = View,
    ?assertEqual([Target], maps:keys(Artifacts)),
    ?assertEqual(1, maps:get(generation, maps:get({vote, Target}, maps:get(evidence, Snapshot)))),
    [?assertEqual(nomatch, binary:match(term_to_binary(View), Blob)) || {_, _, Blob, _} <- maps:get(bundles, F)].

planner_negative_only_participant_has_only_source_presentation_duty_test() ->
    F = fixture(), Origin = maps:get(origin, F), T = foreign(F), G = maps:get(group, F),
    Id = quod_atomic:group_id(G),
    Own = role(vote(F, T, none, {refused, [vote_deadline]})),
    S0 = quod_dtx_recovery:empty(),
    ?assertEqual({ok, {ordered, vote, [{phase, Origin, Id, vote}]}},
                 quod_dtx_recovery:next(Own, S0)),
    S1 = quod_dtx_recovery:absent(Origin, vote, S0),
    ?assertEqual({ok, {ordered, vote, [{present, Origin, G}]}},
                 quod_dtx_recovery:next(Own, S1)),
    ?assertEqual(pending, quod_dtx_recovery:terminal(Own, S1)),
    lists:foreach(fun(Choice) ->
        SourceVote = vote(F, Origin, own(F, Origin), Choice),
        S2 = observed(Own, [SourceVote], S1),
        ?assertEqual(wait, quod_dtx_recovery:next(Own, S2)),
        %% Real source progress never deletes certified authority. There is
        %% no repeated presentation once O's vote has been observed.
        ?assertEqual(wait, quod_dtx_recovery:next(Own, quod_dtx_recovery:progress(Origin, S2)))
    end, [prepared, {refused, [vote_deadline]}]).

coordinator_start_uses_own_role_and_requires_committed_participant_enrollment_test() ->
    F = fixture(), Id = quod_atomic:group_id(maps:get(group, F)),
    Origin = {OriginNs, _} = maps:get(origin, F), Target = {TargetNs, _} = foreign(F),
    lists:foreach(fun(Choice) ->
        SourceVote = vote(F, Origin, own(F, Origin), Choice),
        TargetVote = vote(F, Target, own(F, Target), Choice),
        {_, SourceP} = fold(SourceVote, fresh(Origin)),
        {_, TargetP} = fold(TargetVote, fresh(Target)),
        SourceRow = maps:get(Id, maps:get(groups, SourceP)),
        TargetRow = maps:get(Id, maps:get(groups, TargetP)),
        ?assertEqual({ok, {ordered, vote, [{phase, Origin, Id, vote}]}},
                     quod_dtx_coordinator:test_initial_commands(TargetNs, TargetRow)),
        ?assertEqual({error, invalid_own_vote},
                     quod_dtx_coordinator:test_initial_commands(TargetNs, TargetRow#{ref := none})),
        ?assertEqual({ok, {ordered, vote, [{phase, Origin, Id, vote}]}},
                     quod_dtx_coordinator:test_initial_commands(OriginNs, SourceRow#{ref := none})),
        ?assertEqual({error, invalid_own_vote},
                     quod_dtx_coordinator:test_initial_commands(TargetNs, SourceRow)),
        ?assertEqual({ok, quod_dtx_recovery:empty()},
                     quod_dtx_coordinator:test_initial_snapshot(OriginNs, SourceRow))
    end, [prepared, {refused, [vote_deadline]}]).

planner_source_negative_resolves_unvoted_roles_with_tombstones_test() ->
    F = fixture(), Origin = maps:get(origin, F), T = foreign(F),
    Own = role(vote(F, Origin, none, {refused, [vote_deadline]})),
    S0 = quod_dtx_recovery:absent(T, vote, quod_dtx_recovery:empty()),
    S1 = absent_resolves(maps:get(participant_targets, F), S0),
    {ok, {independent, resolve, Commands}} = quod_dtx_recovery:next(Own, S1),
    {submit, T, TargetResolve} = lists:keyfind(T, 2, Commands),
    ?assertMatch({quod_dtx_resolve, 4, _, T, _, abort, _, {refused, _}, none, 0, _}, TargetResolve),
    {submit, Origin, SourceResolve} = lists:keyfind(Origin, 2, Commands),
    ?assertMatch({quod_dtx_resolve, 4, _, Origin, _, abort, _, {refused, _}, _, 0, _}, SourceResolve).

planner_absence_or_endpoint_refusal_never_decides_abort_test() ->
    F = fixture(), Origin = maps:get(origin, F), T = foreign(F), G = maps:get(group, F),
    Own = role(vote(F, Origin, own(F, Origin), prepared)),
    S = quod_dtx_recovery:absent(T, vote, quod_dtx_recovery:empty()),
    {ok, {independent, vote, [{submit, T, MissingVote}]}} = quod_dtx_recovery:next(Own, S),
    ?assertMatch({quod_dtx_vote, 4, G, T, none, {refused, _}}, MissingVote),
    {ok, Material} = quod_atomic:admission_material(MissingVote),
    {ok, Blob} = quod_atomic:encode_record(MissingVote),
    ?assertEqual({ok, Material}, quod_atomic:decode_material(Blob)),
    %% A source proposal is not a target verdict: the same target policy
    %% waits before the deadline and can certify refusal only after it.
    I = memory_outcome(T), Context = admission_context(F, T, I, 1),
    Deadline = maps:get(deadline, F),
    try quod_ct:with_network_identity(maps:get(network, F), fun() ->
        ?assertMatch({ok, {selection, abstain, _}, _},
                     quod_commit_validation:prepare_vote(Material, Deadline, Context)),
        ?assertMatch({ok, {selection, {vote, Material}, _}, _},
                     quod_commit_validation:prepare_vote(Material, Deadline + 1, Context))
    end)
    after ok = quod_outcome:close(I) end,
    ?assertEqual(pending, quod_dtx_recovery:terminal(Own, S)),
    ?assertNot(lists:member(refusal, maps:keys(S))).

planner_terminal_uses_source_resolve_and_waits_for_exact_application_test() ->
    F = fixture(), Origin = maps:get(origin, F), T = foreign(F), Votes = votes(F),
    Own = role(maps:get(Origin, Votes)),
    Resolves = maps:from_list([{Role, resolve(F, Role, commit, Votes, 2)}
                              || Role <- maps:get(participant_targets, F)]),
    S = observed(Own, maps:values(Votes) ++ maps:values(Resolves), quod_dtx_recovery:empty()),
    Ref = maps:get(ref, maps:get(T, Resolves)), Id = quod_atomic:group_id(maps:get(group, F)),
    ?assertEqual({ok, {independent, applied, [{applied, T, Id, Ref, 2, commit}]}},
                 quod_dtx_recovery:next(Own, S)),
    ?assertEqual(pending, quod_dtx_recovery:terminal(Own, S)),
    #{record := {quod_dtx_complete, 4, _, _, _, _, _, [{T, Certificate}]}} = complete(F, commit, Resolves),
    ?assertEqual({error, invalid_applied_evidence}, quod_dtx_recovery:applied(Own, Origin, Certificate, S)),
    {ok, Ready} = quod_dtx_recovery:applied(Own, T, Certificate, S),
    ?assertMatch({ok, #{verdict := commit, source_slot := 3, participant_slots := [{_, 3, 2}, {_, 3, 2}]}},
                 quod_dtx_recovery:terminal(Own, Ready)),
    ?assertMatch({ok, {ordered, complete, [_]}}, quod_dtx_recovery:next(Own, Ready)),
    PendingComplete = quod_dtx_recovery:attempted(Origin, complete, Ready),
    ?assertEqual(wait, quod_dtx_recovery:next(Own, PendingComplete)),
    ?assertEqual(quod_dtx_recovery:terminal(Own, Ready),
                 quod_dtx_recovery:terminal(Own, PendingComplete)).

planner_rejects_cross_group_or_cross_phase_evidence_test() ->
    F = fixture(), Origin = maps:get(origin, F), T = foreign(F),
    Own = role(vote(F, Origin, own(F, Origin), prepared)),
    Other = fork(F), #{control := C, ref := Ref} = vote(Other, T, own(Other, T), prepared),
    ?assertEqual({error, invalid_phase_evidence},
                 quod_dtx_recovery:observe(Own, {T, C, Ref}, quod_dtx_recovery:empty())),
    Positive = vote(F, T, own(F, T), prepared),
    Negative = #{control := NC, ref := NR} = vote(F, T, own(F, T), {refused, [conflict]}),
    S = observed(Own, [Positive], quod_dtx_recovery:empty()),
    ?assertEqual({error, conflicting_phase_evidence}, quod_dtx_recovery:observe(Own, {T, NC, NR}, S)),
    ?assertEqual(S, quod_dtx_recovery:absent(T, vote, S)),
    ?assertNotEqual(maps:get(record, Positive), maps:get(record, Negative)).

role(#{control := C, ref := Ref}) ->
    #{material => quod_atomic:control_material(C), ref => Ref, resolution => none}.
observed(Own, Rows, S) ->
    lists:foldl(fun(#{control := C, ref := Ref}, Acc) ->
        {ok, Next} = quod_dtx_recovery:observe(Own, {quod_atomic:control_target(C), C, Ref}, Acc), Next
    end, S, Rows).
absent_resolves(Targets, S) ->
    lists:foldl(fun(T, Acc) -> quod_dtx_recovery:absent(T, resolve, Acc) end, S, Targets).

with_index(Fun) ->
    Dir = filename:join("/tmp", "quod_atomic_index_" ++
          binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    {ok, Index} = quod_dtx_phase_index:open(Dir, <<"atomic:index">>),
    try Fun(Index)
    after
        ok = quod_dtx_phase_index:close(Index),
        ok = file:del_dir_r(Dir)
    end.

vote_admission_claims_only_a_positive_source_vote_test() ->
    F = fixture(), O = maps:get(origin, F),
    #{claim := Claim} = request(F), Op = maps:get(operation_ref, Claim),
    quod_ct:with_network_identity(maps:get(network, F), fun() ->
        lists:foreach(fun(T) ->
            I0 = memory_outcome(T), Context = admission_context(F, T, I0, 1),
            #{control := C} = vote(F, T, own(F, T), prepared),
            {ok, {valid, _}, Checked} = quod_commit_validation:dtx(C, 1, check, Context),
            ?assertMatch({not_found, _}, quod_outcome:lookup_ref(quod_commit_validation:outcomes(Checked), Op)),
            {ok, {valid, _}, Applied} = quod_commit_validation:dtx(C, 1, {claim, 2}, Context),
            Result = quod_outcome:lookup_ref(quod_commit_validation:outcomes(Applied), Op),
            case T of
                O -> ?assertMatch({{ok, #{first_slot := 2, outcome_ref := {group, _, _, _, _, _}}}, _}, Result);
                _ -> ?assertMatch({not_found, _}, Result)
            end,
            ok = quod_outcome:close(I0)
        end, maps:get(participant_targets, F))
    end).

vote_refusal_is_certified_and_justified_not_a_peer_opinion_test() ->
    F = fixture(),
    quod_ct:with_network_identity(maps:get(network, F), fun() ->
        lists:foreach(fun(T) ->
            I0 = memory_outcome(T), Context = admission_context(F, T, I0, 1),
            #{control := C} = vote(F, T, own(F, T), {refused, [conflict]}),
            ?assertMatch({ok, {invalid, {atomic_vote_choice, prepared}}, _},
                         quod_commit_validation:dtx(C, 1, check, Context)),
            #{control := Missing} = vote(F, T, none, {refused, [vote_deadline]}),
            ?assertMatch({ok, abstain, _}, quod_commit_validation:dtx(Missing, 1, check, Context)),
            ok = quod_outcome:close(I0)
        end, maps:get(participant_targets, F))
    end).

vote_deadline_uses_block_time_and_negative_never_claims_request_test() ->
    F = fixture(), O = maps:get(origin, F), D = maps:get(deadline, F),
    #{claim := #{operation_ref := Op}} = request(F),
    quod_ct:with_network_identity(maps:get(network, F), fun() ->
        I0 = memory_outcome(O), Context = admission_context(F, O, I0, 1),
        #{control := Positive} = vote(F, O, own(F, O), prepared),
        #{control := Negative} = vote(F, O, none, {refused, [vote_deadline]}),
        ?assertMatch({ok, {valid, _}, _}, quod_commit_validation:dtx(Positive, D, check, Context)),
        ?assertMatch({ok, {invalid, vote_deadline}, _},
                     quod_commit_validation:dtx(Positive, D + 1, check, Context)),
        ?assertMatch({ok, abstain, _}, quod_commit_validation:dtx(Negative, D, check, Context)),
        {ok, {valid, _}, Closed} = quod_commit_validation:dtx(Negative, D + 1, {claim, 2}, Context),
        ?assertMatch({not_found, _}, quod_outcome:lookup_ref(quod_commit_validation:outcomes(Closed), Op)),
        ok = quod_outcome:close(I0)
    end).

source_claim_refusal_waits_for_the_claims_committed_parent_test() ->
    F = fixture(), Other = fork(F), O = maps:get(origin, F),
    #{claim := Claim} = request(F),
    {ok, OtherRef} = quod_dtx:manifest_group_ref(maps:get(manifest, Other),
                                               quod_atomic:group_id(maps:get(group, Other))),
    I0 = memory_outcome(O),
    {new, I1} = quod_outcome:claim_operation(I0, 5, Claim, OtherRef),
    #{control := C} = vote(F, O, none, {refused, [vote_deadline]}),
    Material = quod_atomic:control_material(C), D = maps:get(deadline, F),
    ?assertMatch({ok, {refused, [vote_deadline]}, _},
      quod_commit_validation:vote_choice(Material, D + 1, admission_context(F, O, I1, 4))),
    ?assertMatch({ok, {refused, [duplicate_operation]}, _},
      quod_commit_validation:vote_choice(Material, D + 1, admission_context(F, O, I1, 5))),
    quod_ct:with_network_identity(maps:get(network, F), fun() ->
        %% A preserved future claim must not rewrite this earlier certified
        %% refusal during disk replay. Claim bytes are fixtures here; the
        %% full ledger replay witness is a separate integration gate.
        ?assertMatch({ok, {valid, _}, _},
          quod_commit_validation:dtx(C, D + 1, {claim, 5}, admission_context(F, O, I1, 4)))
    end),
    ok = quod_outcome:close(I1).

same_request_reservation_waits_while_other_request_keeps_wait_die_test() ->
    F = fixture(), Same = fork(F), T = foreign(F),
    {I1, [none]} = outcome_wave(memory_outcome(T), [vote(F, T, own(F, T), prepared)]),
    #{control := C} = vote(Same, T, own(Same, T), {refused, [conflict]}),
    ?assertMatch({ok, wait, _}, quod_commit_validation:vote_choice(
        quod_atomic:control_material(C), 1, admission_context(Same, T, I1, 1))),
    Other = fixture(#{operation_id => <<999:256>>}),
    #{control := C2} = vote(Other, T, own(Other, T), {refused, [conflict]}),
    Expected = case quod_atomic:group_id(maps:get(group, F)) <
                    quod_atomic:group_id(maps:get(group, Other)) of
        true -> {refused, [conflict]}; false -> wait
    end,
    ?assertMatch({ok, Expected, _}, quod_commit_validation:vote_choice(
        quod_atomic:control_material(C2), 1, admission_context(Other, T, I1, 1))),
    ok = quod_outcome:close(I1).

future_parent_is_not_a_negative_vote_test() ->
    F = fixture(), T = foreign(F), I0 = memory_outcome(T),
    #{control := C} = vote(F, T, own(F, T), {refused, [future_base_height]}),
    ?assertMatch({ok, wait, _}, quod_commit_validation:vote_choice(
        quod_atomic:control_material(C), 1, admission_context(F, T, I0, 0))),
    ok = quod_outcome:close(I0).


admission_context(F, Target, Index, Parent) ->
    quod_commit_validation:new(Target, Parent, admission_est(F, Target), Index, none).

admission_est(F, {Ns, _} = Target) ->
    #{goal := FrozenGoal} = maps:get(evidence, F),
    {ok, Goal} = quod_wire_term:materialize_symbols(FrozenGoal),
    {ok, Principal} = quod_agent_ref:materialize_principal(maps:get(principal, F)),
    {OriginNs, _} = Origin = maps:get(origin, F),
    SourceFacts = case Target of Origin -> quod_ct:signed_agent_facts(F); _ -> [] end,
    Callers = case Target of Origin -> []; _ -> [OriginNs] end,
    #{pubkey := Pub} = maps:get(node_identity, F),
    quod_ct:committed_kb(SourceFacts ++
        [{can_invoke, Goal, Principal, Callers, Ns}, {peer_admitted, Pub, "validator", 14567, Pub}]).
request(F) ->
    {ok, #{request := Request}} = quod_atomic:group_binding(maps:get(group, F)), Request.

committed_materializer_keeps_vote_hidden_and_publishes_resolve_before_ack_test() ->
    %% Real signed controls and entry QCs through the production materializer.
    %% The admitted height-1 KB is a fixture, not a full founding/network run.
    F = fixture(), Signers = [maps:get(node_identity, F) | [signer() || _ <- lists:seq(1, 3)]],
    Votes = maps:map(fun(_, V) -> certified_control(V, Signers, 2) end, votes(F)),
    Id = quod_atomic:group_id(maps:get(group, F)),
    quod_ct:with_network_identity(maps:get(network, F), fun() ->
        lists:foreach(fun(Target) ->
            I0 = publish_outcome(memory_outcome(Target), 1),
            P0 = quod_committed_projection:new(Target, 1, admission_est(F, Target), I0, none),
            Vote = maps:get(Target, Votes),
            {ok, P1, #{kind := dtx_batch, applied_ops := [], deferred_acks := []}} =
                quod_committed_projection:apply_entry(maps:get(entry, Vote), 1, P0),
            ?assertNot(projection_proves({saved, ok}, P1)),
            Resolve = certified_control(resolve(F, Target, commit, Votes, 2), Signers, 3),
            {ok, P2, #{kind := dtx_batch, applied_ops := [_], selection_changes := Released,
                        publications := [{group_applied, Id, _, _, []}],
                        deferred_acks := [{resolve_applied, Id, 3, 2}]}} =
                quod_committed_projection:apply_entry(maps:get(entry, Resolve), 1, P1),
            ?assert(projection_proves({saved, ok}, P2)),
            ?assert(lists:all(fun(K) -> maps:is_key(K, Released) end,
                quod_selection_basis:reservation_keys(quod_atomic:control_material(maps:get(control, Vote))))),
            I2 = quod_committed_projection:outcomes(P2),
            ?assertEqual(3, quod_outcome:applied_floor(I2)),
            ?assert(lists:all(fun(R) -> not maps:get(blocking, R) end,
                             maps:values(outcome_fences(I2)))),
            ?assertMatch({ok, P2, #{kind := already_applied}},
                quod_committed_projection:apply_entry(maps:get(entry, Resolve), 1, P2)),
            ok = quod_outcome:close(I2)
        end, maps:get(participant_targets, F))
    end).

projection_proves(Goal, Projection) ->
    case erlog_int:prove_goal(Goal, quod_committed_projection:est(Projection)) of
        {succeed, _} -> true;
        {fail, _} -> false
    end.

own_vote_selection_matches_validator_policy_without_claiming_or_reauthenticating_test() ->
    F = fixture(), Deadline = maps:get(deadline, F),
    quod_ct:with_network_identity(maps:get(network, F), fun() ->
        lists:foreach(fun(T) ->
            I = memory_outcome(T), Context = admission_context(F, T, I, 1),
            #{control := C} = vote(F, T, own(F, T), prepared),
            M = quod_atomic:control_material(C),
            Owner = self(),
            {Results, {call_time, Counts}} = tprof:profile(fun() ->
                [quod_commit_validation:prepare_vote(M, Time, Context)
                 || Time <- [Deadline, Deadline + 1]]
            end, #{type => call_time, report => return, set_on_spawn => false,
                   pattern => [{quod_identity, verify, 3}]}),
            ?assertEqual(0, lists:sum([N || {quod_identity, verify, 3, Ps} <- Counts,
                                           {Pid, N, _} <- Ps, Pid =:= Owner])),
            [{ok, {selection, {vote, M}, Basis}, _}, {ok, {selection, {vote, Negative}, _}, _}] = Results,
            ?assertNot(maps:is_key(parent, Basis)),
            ?assertNot(maps:is_key({context, height}, Basis)),
            ?assertEqual({ok, Negative}, quod_atomic:select_vote(M, {refused, [vote_deadline]})),
            lists:foreach(fun({Time, {ok, {selection, {vote, Selected}, _}, Ctx}}) ->
                {ok, Control} = quod_atomic:sign_control(T, Selected, maps:get(admission, F),
                                                        1, Time, maps:get(node_identity, F)),
                ?assertMatch({ok, {valid, _}, _}, quod_commit_validation:dtx(Control, Time, check, Ctx))
            end, lists:zip([Deadline, Deadline + 1], Results)),
            #{control := Missing} = vote(F, T, none, {refused, [vote_deadline]}),
            MissingMaterial = quod_atomic:control_material(Missing),
            ?assertMatch({ok, {selection, abstain, _}, _},
                         quod_commit_validation:prepare_vote(MissingMaterial, Deadline, Context)),
            ?assertMatch({ok, {selection, {vote, MissingMaterial}, _}, _},
                         quod_commit_validation:prepare_vote(MissingMaterial, Deadline + 1, Context)),
            ?assertEqual(not_found, element(1, quod_outcome:lookup_ref(I, maps:get(operation_ref, F)))),
            ok = quod_outcome:close(I)
        end, maps:get(participant_targets, F))
    end).

four_disjoint_groups_select_once_across_real_vote_publications_test() ->
    {ok, {call_time, Counts}} = tprof:profile(fun disjoint_selection_probe/0,
        #{type => call_time, report => return, set_on_spawn => false,
          pattern => [{quod_commit_validation, prepare_vote, 3}]}),
    ?assertEqual(4, lists:sum([N || {quod_commit_validation, prepare_vote, 3, Ps} <- Counts,
                                  {_Pid, N, _} <- Ps])).

disjoint_selection_probe() ->
    F0 = fixture(), Node = maps:get(node_identity, F0), KeyPair = maps:get(key_pair, F0),
    Fs = [fixture(#{node_identity => Node, key_pair => KeyPair, operation_id => <<N:256>>,
                    proof_id => <<N:256>>, goal_text => Goal}) ||
          {N, Goal} <- lists:zip(lists:seq(1, 4),
              [<<"assertz(first(ok)).">>, <<"assertz(second(ok)).">>,
               <<"assertz(third(ok)).">>, <<"assertz(fourth(ok)).">>])],
    [F | _] = Fs, T = maps:get(origin, F), {Ns, _} = T,
    Member = maps:get(pubkey, Node),
    Est = quod_ct:committed_kb(quod_ct:signed_agent_facts(F) ++
        [{peer_admitted, Member, "validator", 14567, Member},
         {':-', {can_invoke, {'Goal'}, {'Principal'}, {'Chain'}, Ns}, unadvertised_policy},
         unadvertised_policy]),
    I = publish_outcome(memory_outcome(T), 1),
    P = quod_committed_projection:new(T, 1, Est, I, none),
    Materials = [quod_atomic:control_material(maps:get(control, vote(X, T, own(X, T), prepared))) || X <- Fs],
    Q = lists:foldl(fun(M, Acc) -> quod_atomic_admission:admit(M, none, #{}, Acc) end,
                    quod_atomic_admission:new(), Materials),
    Parent = {self(), {1, <<1:256>>}},
    Signers = [Node | [signer() || _ <- lists:seq(1, 3)]],
    try quod_ct:with_network_identity(maps:get(network, F), fun() ->
        {Done, _} = (fun() ->
            {Commands, Checking} = quod_atomic_admission:next(Parent, 1, Q),
            ?assertEqual(4, length(Commands)),
            Context = quod_commit_validation:new(T, 1, Est, I, none),
            Ready = lists:foldl(fun({_Id, Tag, M, _}, Rows) ->
                {ok, {selection, {vote, M}, Basis}, _} = quod_commit_validation:prepare_vote(M, 1, Context),
                ?assert(maps:is_key({fact, {unadvertised_policy, 0}}, Basis)),
                ?assert(maps:is_key({fact, {agent_key, 3}}, Basis)),
                ?assert(maps:is_key({fact, {peer_admitted, 4}}, Basis)),
                ?assertNot(maps:is_key(parent, Basis)),
                {selected, _, Next} = quod_atomic_admission:verdict(Tag, Parent, {{vote, M}, Basis}, Rows),
                Next
            end, Checking, Commands),
            lists:foldl(fun({X, Slot}, {Rows, Projection}) ->
                M = quod_atomic:control_material(maps:get(control, vote(X, T, own(X, T), prepared))),
                {#{material := M}, Remaining} = quod_atomic_admission:take(quod_atomic:group_id(maps:get(group, X)), Rows),
                Certified = certified_control(vote(X, T, own(X, T), prepared), Signers, Slot),
                Entry = maps:get(entry, Certified),
                {ok, NextProjection, #{selection_changes := Changes}} =
                    quod_committed_projection:apply_entry(Entry, 1, Projection),
                ?assert(lists:all(fun(K) -> maps:is_key(K, Changes) end,
                                 quod_selection_basis:reservation_keys(M))),
                ?assert(maps:is_key({request, maps:get(key, maps:get(claim, request(X)))}, Changes)),
                NextParent = {self(), {Slot, quod_simplex:entry_history_hash(Entry)}},
                Rebased = quod_atomic_admission:parent_applied(NextParent, Changes, Remaining),
                {NextCommands, Rebased} = quod_atomic_admission:next(NextParent, 1, Rebased),
                ?assertEqual(5 - Slot, length(NextCommands)),
                ?assert(lists:all(fun({_, Tag, _, _}) -> Tag =:= selected end, NextCommands)),
                {Rebased, NextProjection}
            end, {Ready, P}, lists:zip(Fs, lists:seq(2, 5)))
        end)(),
        ?assertEqual({0, 0}, quod_atomic_admission:counts(Done)),
        ok
    end)
    after ok = quod_outcome:close(I),
          #est{db = #db{ref = Kb}} = Est, quod_erlog_db_mvcc:delete(Kb)
    end.

key_revocation_and_signer_admission_invalidate_real_selections_test_() ->
    [{atom_to_list(Name), fun() ->
        F = fixture(), T = maps:get(origin, F), I = memory_outcome(T),
        Est = #est{db = #db{ref = Ref}} = admission_est(F, T),
        #{control := Control} = vote(F, T, own(F, T), prepared),
        Material = quod_atomic:control_material(Control),
        try quod_ct:with_network_identity(maps:get(network, F), fun() ->
            {ok, {selection, {vote, Material}, Basis}, _} = quod_commit_validation:prepare_vote(
                Material, 1, quod_commit_validation:new(T, 1, Est, I, none)),
            {ok, Dropped} = quod_erlog_db_mvcc:abolish_clauses(Ref, {Name, Arity}),
            Changes = maps:from_keys([{fact, K} || K <- quod_erlog_db_mvcc:changed_functors(Dropped)], true),
            ?assert(quod_selection_basis:affected(Basis, Changes)),
            ?assertEqual(none, quod_atomic_admission:advance_selection(
                {{{self(), {1, <<1:256>>}}, false}, Basis}, {self(), {2, <<2:256>>}}, Changes)),
            NewEst = quod_ct:commit_kb(quod_ct:set_ref(Est, Dropped), 2, 1),
            {ok, {selection, {vote, Negative}, _}, _} = quod_commit_validation:prepare_vote(
                Material, 1, quod_commit_validation:new(T, 2, NewEst, I, none)),
            ?assertEqual({ok, Negative}, quod_atomic:select_vote(Material, {refused, [Reason]}))
        end)
        after ok = quod_outcome:close(I), quod_erlog_db_mvcc:delete(Ref) end
    end} || {Name, Arity, Reason} <- [{agent_key, 3, invalid_agent_key}, {peer_admitted, 4, signer_not_admitted}]].

vote_selection_uses_the_existing_parent_queue_and_timeout_test() ->
    %% A real bare Prolog owner and production apply/validation callbacks.
    %% The zero anchor and injected committed policy are not fleet founding.
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"atomic:parent:", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    O = {Ns, <<0:256>>}, T = {<<"atomic:remote">>, <<1:256>>},
    F = bind(quod_ct:signed_plan_fixture(#{target => O, atomic => true}, [O, T])),
    #{control := C} = vote(F, O, own(F, O), prepared),
    M = quod_atomic:control_material(C), Tag = make_ref(),
    {ok, Engine} = quod_prolog:start_link(Ns, #{outcome_backend => memory}),
    try quod_ct:with_network_identity(maps:get(network, F), fun() ->
        ok = quod_prolog:request_dtx_verdict(Ns, {vote, M}, 1, 2, self(), Tag),
        ?assertEqual(0, quod_prolog:applied(Ns)),
        receive {dtx_verdict, Tag, _, _, _} -> error(early_parent_verdict) after 0 -> ok end,
        Member = maps:get(pubkey, maps:get(node_identity, F)),
        Facts = [{can_invoke, {'Goal'}, {'Principal'}, {'Chain'}, {'Namespace'}},
                 {peer_admitted, Member, "validator", 14567, Member} | quod_ct:signed_agent_facts(F)],
        Change = quod_ct:change(Ns, lists:append([quod_ct:diff_for(Fact) || Fact <- Facts]), #{}),
        ok = quod_prolog:apply_entry(Ns, quod_ct:committed_entry(Ns, 1, quod_ct:batch(Change)), live),
        receive
            {dtx_verdict, Tag, Engine, 1, {selection, {vote, M}, _}} -> ok
        after 1000 -> error(vote_selection_not_released_at_parent) end,
        WaveTag = make_ref(),
        ok = quod_prolog:request_dtx_verdict(Ns, {wave, [C]}, 1, 2, self(), WaveTag),
        receive
            {dtx_verdict, WaveTag, Engine, 1, {valid, _}} -> ok
        after 1000 -> error(wave_did_not_share_parent_policy) end,
        TimeoutTag = make_ref(),
        ok = quod_prolog:request_dtx_verdict(Ns, {vote, M}, 1, 10, self(), TimeoutTag),
        ?assertEqual(1, quod_prolog:applied(Ns)),
        Engine ! {validation_timeout, TimeoutTag},
        receive
            {dtx_verdict, TimeoutTag, Engine, 1, abstain} -> ok
        after 1000 -> error(vote_selection_did_not_use_existing_timeout) end
    end)
    after gen_server:stop(Engine)
    end.

timed_out_selection_wakes_from_real_parent_apply_test_() ->
    %% Receive tracing belongs to this fixture alone, including notifications
    %% still in flight when tracing is disabled. Never leak them to another test.
    {spawn, fun timed_out_selection_wakes_from_real_parent_apply/0}.

timed_out_selection_wakes_from_real_parent_apply() ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"atomic:wake:", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    O = {Ns, <<0:256>>}, T = {<<"atomic:remote">>, <<1:256>>},
    F = bind(quod_ct:signed_plan_fixture(#{target => O, atomic => true}, [O, T])),
    #{control := C} = vote(F, O, own(F, O), prepared), M = quod_atomic:control_material(C),
    {ok, Ref} = quod_atomic:source_group_ref(M),
    Node = maps:get(node_identity, F), Member = maps:get(pubkey, Node),
    Dir = filename:join("/tmp", "quod-admission-wake-" ++
        binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    {ok, Engine} = quod_prolog:start_link(Ns, #{outcome_backend => memory}),
    {ok, J} = quod_signing_journal:initialize(Ns, <<99:256>>, Dir),
    true = quod_reg:subscribe({quod_prolog, Ns}),
    Facts = [{can_invoke, {'Goal'}, {'Principal'}, {'Chain'}, {'Namespace'}},
             {peer_admitted, Member, "validator", 14567, Member} | quod_ct:signed_agent_facts(F)],
    Change = quod_ct:change(Ns, lists:append([quod_ct:diff_for(Fact) || Fact <- Facts]), #{}),
    Entry = quod_ct:committed_entry(Ns, 1, quod_ct:batch(Change)),
    Parent = {1, quod_simplex:entry_history_hash(Entry)},
    try quod_ct:with_network_identity(maps:get(network, F), fun() ->
        %% The fixture owner has dispatched parent 1; the real Prolog engine
        %% has not consumed it. These are production callbacks, not consensus.
        S0 = state(#{ns => Ns, genesis_hash => element(2, O),
            self => Member, id => Node, validators => [Member],
            author_admissions => #{Member => maps:get(admission, F)},
            signing_journal => J, slot => 1, history_head => Parent,
            sync => ready, prolog_ready => true}),
        Token = make_ref(),
        {ok, Reserved} = quod_simplex:test_enqueue_dtx_intent(
            {self(), make_ref()}, Engine, Token, M, Ref, quod_time:mono_ms() + 1000, S0),
        Active = quod_simplex:test_activate_dtx_intent(Engine, Token, Reserved),
        1 = erlang:trace(Engine, true, ['receive']),
        {Checking, []} = quod_simplex:test_progress_dtx_admission(Active),
        WireTag = receive
            {trace, Engine, 'receive', {'$gen_cast',
              {dtx_verdict_req, {vote, M}, _, 2, _, Tag0, _}}} -> Tag0
        after 1000 -> error(parent_selection_request_missing) end,
        1 = erlang:trace(Engine, false, ['receive']),
        ?assertEqual(0, quod_prolog:applied(Ns)),
        Engine ! {validation_timeout, WireTag},
        {dtx_admission, Tag, Key, Ts} = WireTag,
        receive {dtx_verdict, WireTag, Engine, 0, abstain} -> ok
        after 1000 -> error(parent_timeout_missing) end,
        Parked = quod_simplex:on_admission_verdict(Tag, Key, Ts, Engine, 0, abstain, Checking),
        lists:foreach(fun(_) ->
            ?assertEqual({Parked, []}, quod_simplex:test_progress_dtx_admission(Parked))
        end, lists:seq(1, 10)),
        ?assertEqual(Parked, quod_simplex:on_admission_parent_applied(self(), {Parent, #{}}, Parked)),
        ok = quod_prolog:apply_entry(Ns, Entry, live),
        Changes = receive {projection_advanced, Engine, Parent, ChangedKeys} -> ChangedKeys
        after 1000 -> error(parent_application_signal_missing) end,
        Woken = quod_simplex:on_admission_parent_applied(Engine, {Parent, Changes}, Parked),
        ?assertEqual(Woken, quod_simplex:on_admission_parent_applied(Engine, {Parent, Changes}, Woken)),
        {Rechecking, []} = quod_simplex:test_progress_dtx_admission(Woken),
        ?assertEqual(Rechecking, quod_simplex:on_admission_parent_applied(Engine, {Parent, Changes}, Rechecking)),
        receive
            {dtx_verdict, {dtx_admission, NewTag, Key, NewTs}, Engine, 1, {selection, {vote, M}, _}} ->
                ?assertNotEqual(Tag, NewTag),
                %% A non-vote with the parent already published waits on
                %% something else. A duplicate apply edge cannot restart it.
                PolicyWait = quod_simplex:on_admission_verdict(
                    NewTag, Key, NewTs, Engine, 1, abstain, Rechecking),
                ?assertEqual(PolicyWait,
                    quod_simplex:on_admission_parent_applied(Engine, {Parent, Changes}, PolicyWait))
        after 1000 -> error(applied_parent_did_not_wake_selection) end
    end)
    after
        _ = erlang:trace(Engine, false, ['receive']),
        true = quod_reg:unsubscribe({quod_prolog, Ns}),
        gen_server:stop(Engine),
        ok = quod_signing_journal:close(J),
        ok = file:del_dir_r(Dir)
    end.

compact_presentation_authenticates_only_the_source_manifest_test() ->
    F = fixture(), G = maps:get(group, F), O = maps:get(origin, F), T = foreign(F),
    Id = quod_atomic:group_id(G), Blob = quod_atomic:encode_group(G),
    {ok, M = {Record, _, #{plans := Plans}}} = quod_atomic:decode_presentation(O, Id, Blob),
    ?assertEqual(#{}, Plans),
    ?assertMatch({quod_dtx_vote, 4, G, O, none, {refused, _}}, Record),
    ?assertEqual({ok, M}, quod_atomic:admission_material(Record)),
    ?assertEqual(error, quod_atomic:decode_presentation(T, Id, Blob)),
    ?assertEqual(error, quod_atomic:decode_presentation(O, <<0:256>>, Blob)),
    Attestation = element(5, G),
    Bad = setelement(5, G, setelement(tuple_size(Attestation), Attestation, <<0:512>>)),
    ?assertEqual(error, quod_atomic:decode_presentation(O, Id, quod_atomic:encode_group(Bad))).

presentation_receipt_retains_work_without_an_rpc_worker_or_readiness_test() ->
    %% Production owner/codec boundary with real signed material. No transport,
    %% consensus quorum or full founding is claimed by this local state fixture.
    {ok, _} = application:ensure_all_started(gproc),
    F = fixture(), {Ns, Anchor} = maps:get(origin, F), G = maps:get(group, F),
    Id = quod_atomic:group_id(G), RequestId = <<7:128>>,
    Request = {present, RequestId, Id, quod_atomic:encode_group(G)},
    Node = maps:get(node_identity, F), Member = maps:get(pubkey, Node),
    S = state(#{ns => Ns, genesis_hash => Anchor, self => Member,
          id => Node, validators => [Member], author_admissions => #{Member => maps:get(admission, F)},
          sync => unconfirmed, prolog_ready => false}),
    ?assert(quod_simplex:test_dtx_endpoint_ready(Request, S)),
    From = {self(), make_ref()},
    {ok, Accepted, Actions} = quod_simplex:test_start_local_dtx_endpoint_request(Request, [], 1, From, S),
    ?assertEqual([{reply, From, {ok, {presented, RequestId, Id}, []}}], Actions),
    ?assertMatch(#{active := 1, reserved := 0}, quod_simplex:test_dtx_admission_state(Accepted)),
    ?assertMatch(#{rows := Rows} when map_size(Rows) =:= 0, quod_simplex:test_retained_dtx_state(Accepted)),
    ?assertMatch(#{workers := 0, correlations := 0, submissions := 0},
                 quod_simplex:test_dtx_endpoint_counts(Accepted)),
    ?assertEqual({Accepted, []}, quod_simplex:test_progress_dtx_admission(Accepted)),
    {ok, Duplicate, Actions} = quod_simplex:test_start_local_dtx_endpoint_request(Request, [], 1, From, Accepted),
    ?assertEqual(Accepted, Duplicate),
    ?assertEqual({error, invalid_request}, quod_simplex:test_start_local_dtx_endpoint_request(
        setelement(3, Request, <<0:256>>), [], 1, From, S)),
    ?assertEqual(error, quod_atomic:decode_presentation(foreign(F), Id, quod_atomic:encode_group(G))).

presentation_capacity_returns_busy_without_losing_existing_work_test_() ->
    {timeout, 30, {spawn, fun() ->
        {ok, _} = application:ensure_all_started(gproc),
        F = fixture(), {Ns, Anchor} = maps:get(origin, F),
        Node = maps:get(node_identity, F), Member = maps:get(pubkey, Node),
        S0 = state(#{ns => Ns, genesis_hash => Anchor,
            self => Member, id => Node, validators => [Member],
            author_admissions => #{Member => maps:get(admission, F)},
            sync => unconfirmed, prolog_ready => false}),
        %% Authenticated endpoint callback, not consensus admission: each
        %% manifest is real, but remains volatile while the owner is unready.
        Request = fun(Fixture) ->
            Group = maps:get(group, Fixture),
            {present, <<7:128>>, quod_atomic:group_id(Group), quod_atomic:encode_group(Group)}
        end,
        From = {self(), make_ref()}, First = Request(F),
        Enroll = fun(R, S) ->
            {ok, Next, [{reply, From, {ok, {presented, _, _}, []}}]} =
                quod_simplex:test_start_local_dtx_endpoint_request(R, [], 1, From, S), Next
        end,
        Full = lists:foldl(fun(_, S) ->
            Enroll(Request(fixture(#{node_identity => Node})), S)
        end, Enroll(First, S0), lists:seq(2, ?MAX_INGRESS_TXS)),
        ?assertMatch(#{active := ?MAX_INGRESS_TXS, reserved := 0},
                     quod_simplex:test_dtx_admission_state(Full)),
        Extra = Request(fixture(#{node_identity => Node})),
        ?assertEqual(Full, Enroll(First, Full)),
        %% A newly registered engine must not leak a monitor through a rejected
        %% callback's discarded tentative state. This stand-in performs no proof.
        Caller = self(),
        Engine = spawn(fun() ->
            true = quod_reg:reg({quod_prolog, Ns}),
            Caller ! {self(), registered},
            receive stop -> ok end
        end),
        try
            receive {Engine, registered} -> ok
            after 1000 -> error(capacity_engine_missing) end,
            Before = process_info(self(), monitors),
            ?assertEqual({error, busy},
                quod_simplex:test_start_local_dtx_endpoint_request(Extra, [], 1, From, Full)),
            ?assertEqual(Before, process_info(self(), monitors))
        after
            Monitor = monitor(process, Engine), Engine ! stop,
            receive {'DOWN', Monitor, process, Engine, normal} -> ok
            after 1000 -> error(capacity_engine_survived) end
        end,
        ?assertMatch(#{workers := 0, correlations := 0, submissions := 0},
                     quod_simplex:test_dtx_endpoint_counts(Full))
    end}}.

committed_vote_answers_its_exact_group_intent_without_resigning_test() ->
    F = fixture(), O = maps:get(origin, F), T = foreign(F),
    Signers = [maps:get(node_identity, F)],
    #{control := Proposed} = vote(F, O, own(F, O), prepared),
    Negative = certified_control(vote(F, O, none, {refused, [vote_deadline]}), Signers, 2),
    #{ref := Ref, control := NegativeControl} = Negative,
    {H, P} = fold(Negative, fresh(O)),
    M = quod_atomic:control_material(Proposed),
    {Result, {call_time, Counts}} = tprof:profile(fun() ->
        quod_dtx_owner:admission(M, H, P)
    end, #{type => call_time, report => return, set_on_spawn => false,
           pattern => [{quod_identity, verify, 3}]}),
    ?assertEqual({included, Ref}, Result),
    ?assertEqual([], Counts),
    ?assertEqual({included, Ref}, quod_dtx_owner:admission(M, H, quod_atomic:initial_projection(O, 9))),
    #{control := Foreign} = vote(F, T, own(F, T), prepared),
    ?assertEqual(stale, quod_dtx_owner:admission(quod_atomic:control_material(Foreign), H, P)),
    OtherF = fixture(), #{control := Other} = vote(OtherF, O, own(OtherF, O), prepared),
    ?assertEqual(stale, quod_dtx_owner:admission(quod_atomic:control_material(Other), H, P)),
    ?assertMatch({quod_dtx_vote, 4, _, O, none, {refused, _}}, quod_atomic:control_body(NegativeControl)),
    ?assert(quod_dtx:certified_entry_claim_matches(O, maps:get(entry, Negative),
                                                 NegativeControl, Ref)).

committed_negative_answers_waiting_positive_with_exact_certificate_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    F = fixture(), {Ns, Anchor} = O = maps:get(origin, F),
    Signers = [maps:get(node_identity, F)],
    #{control := Proposed} = vote(F, O, own(F, O), prepared),
    #{ref := Ref, entry := Entry} = certified_control(
        vote(F, O, own(F, O), {refused, [vote_deadline]}), Signers, 2),
    S = quod_simplex:test_seed_dtx_submission(Proposed, [{dtx_endpoint, self()}],
          state(#{ns => Ns, genesis_hash => Anchor})),
    #entry{data = Payload} = quod_ledger:entry_view(Entry),
    Done = quod_simplex:test_resolve_committed_dtx(Entry, Payload, S),
    ?assertMatch(#{rows := Empty} when map_size(Empty) =:= 0,
                 quod_simplex:test_retained_dtx_state(Done)),
    receive
        {dtx_submit_result, {ok, Ref, [{Ref, Entry}]}} -> ok
    after 1000 -> error(committed_negative_not_delivered) end,
    ?assertEqual(Done, quod_simplex:test_resolve_committed_dtx(Entry, Payload, Done)),
    receive {dtx_submit_result, _} -> error(duplicate_vote_reply) after 0 -> ok end.

source_reservation_during_recovery_checks_binding_and_caller_deadline_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    F = fixture(), {Ns, Anchor} = O = maps:get(origin, F),
    #{control := C} = vote(F, O, own(F, O), prepared),
    M = quod_atomic:control_material(C), {ok, Ref} = quod_atomic:source_group_ref(M),
    Node = maps:get(node_identity, F), Member = maps:get(pubkey, Node),
    Dir = filename:join("/tmp", "quod-reservation-binding-" ++
                       binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    {ok, J} = quod_signing_journal:initialize(Ns, <<99:256>>, Dir),
    true = quod_reg:reg({quod_prolog, Ns}),
    try
        S = state(#{ns => Ns, genesis_hash => Anchor,
              self => Member, id => Node, validators => [Member],
              author_admissions => #{Member => maps:get(admission, F)},
              signing_journal => J, slot => 1, history_head => {1, <<7:256>>},
              sync => {pulling, self()}, prolog_ready => true}),
        From = {self(), make_ref()}, Token = make_ref(), D = quod_time:mono_ms() + 10000,
        Binding = quod_dtx:manifest_coordinator(maps:get(manifest, F)),
        ?assertEqual({keep_state, S, [{reply, From, {ok, Binding}}]},
                     quod_simplex:running({call, From}, get_dtx_binding, S)),
        ?assertEqual({keep_state, S, [{reply, From, {error, {ontology_unavailable, Ns}}}]},
                     quod_simplex:running({call, From}, get_dtx_ready_binding, S)),
        ?assertEqual({error, {proof_limit_exceeded, Ns}},
                     quod_simplex:test_enqueue_dtx_intent(From, self(), Token, M, Ref,
                                                         quod_time:mono_ms() - 1, S)),
        ?assertEqual({error, invalid_dtx_intent}, quod_simplex:test_enqueue_dtx_intent(
                         From, self(), Token, M, setelement(6, Ref, <<91:256>>), D, S)),
        NotMember = quod_simplex:test_state_set(validators, [], S),
        ?assertEqual({error, invalid_dtx_intent}, quod_simplex:test_enqueue_dtx_intent(
                         From, self(), Token, M, Ref, D, NotMember)),
        ?assertEqual(#{}, quod_signing_journal:pending_dtx(J)),
        {ok, Reserved} = quod_simplex:test_enqueue_dtx_intent(From, self(), Token, M, Ref, D, S),
        Activated = quod_simplex:test_activate_dtx_intent(self(), Token, Reserved),
        {Held, []} = quod_simplex:test_progress_dtx_admission(Activated),
        ?assertMatch(#{active := 1, reserved := 0}, quod_simplex:test_dtx_admission_state(Held)),
        ?assertMatch(#{rows := Empty} when map_size(Empty) =:= 0,
                     quod_simplex:test_retained_dtx_state(Held)),
        ?assertEqual(0, quod_signing_journal:dtx_floor(J, {maps:get(admission, F), Member}))
    after
        ok = quod_signing_journal:close(J),
        true = gproc:unreg(quod_reg:name({quod_prolog, Ns})),
        receive {'$gen_cast', {project_pending_votes, _}} -> ok after 0 -> ok end,
        ok = file:del_dir_r(Dir)
    end.

source_enrollment_survives_cancellation_engine_loss_and_reopen_test_() ->
    [{atom_to_list(Edge), fun() -> source_enrollment_edge(Edge) end}
     || Edge <- [reserved, cancelled, engine_lost, activated]].

source_enrollment_edge(Edge) ->
    %% Production owner callbacks and on-disk restart, with real signed plans.
    %% No private action is executed by this fixture: the activation edge is
    %% supplied explicitly, and full multi-node/effect acceptance stays separate.
    {ok, _} = application:ensure_all_started(gproc),
    F = fixture(), {Ns, Anchor} = O = maps:get(origin, F),
    #{control := C} = vote(F, O, own(F, O), prepared),
    M = quod_atomic:control_material(C), Missing = quod_atomic:source_presentation(M),
    Id = quod_atomic:group_id(C), {ok, Ref} = quod_atomic:source_group_ref(M),
    Node = maps:get(node_identity, F), Member = maps:get(pubkey, Node),
    Dir = filename:join("/tmp", "quod-enrollment-edge-" ++
                       binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    {ok, J} = quod_signing_journal:initialize(Ns, <<99:256>>, Dir),
    true = quod_reg:reg({quod_prolog, Ns}),
    try
        S0 = state(#{ns => Ns, genesis_hash => Anchor,
              self => Member, id => Node, validators => [Member],
              author_admissions => #{Member => maps:get(admission, F)},
              signing_journal => J, slot => 1, history_head => {1, <<7:256>>},
              sync => ready, prolog_ready => true}),
        Token = make_ref(),
        {ok, Reserved} = quod_simplex:test_enqueue_dtx_intent(
            {self(), make_ref()}, self(), Token, M, Ref, quod_time:mono_ms() + 10000, S0),
        ?assertMatch(#{Id := #{sequence := 0, envelope := none, material := Missing}},
          quod_signing_journal:pending_dtx(quod_simplex:test_signing_journal(Reserved))),
        Changed = case Edge of
            reserved -> Reserved;
            cancelled -> quod_simplex:test_cancel_dtx_intent(self(), Token, Reserved);
            engine_lost -> {true, Lost} = quod_simplex:test_drop_dtx_admission_owner(Reserved), Lost;
            activated -> quod_simplex:test_activate_dtx_intent(self(), Token, Reserved)
        end,
        Expected = case Edge of activated -> M; _ -> Missing end,
        Saved = quod_signing_journal:pending_dtx(quod_simplex:test_signing_journal(Changed)),
        ?assertEqual({error, invalid_dtx_intent}, quod_simplex:test_enqueue_dtx_intent(
            {self(), make_ref()}, self(), make_ref(), M, Ref, quod_time:mono_ms() + 10000,
            quod_simplex:test_state_set(signing_journal, quod_simplex:test_signing_journal(Changed), S0))),
        ?assertMatch(#{Id := #{sequence := 0, envelope := none, material := Expected}}, Saved),
        ?assertMatch(#{rows := Empty} when map_size(Empty) =:= 0,
                     quod_simplex:test_retained_dtx_state(Changed)),
        ok = quod_signing_journal:close(quod_simplex:test_signing_journal(Changed)),
        {ok, Reopened} = quod_signing_journal:recover(Ns, <<99:256>>, Dir),
        try
            ?assertEqual(Saved, quod_signing_journal:pending_dtx(Reopened)),
            Rebuilt = quod_simplex:test_restore_pending_dtx(
                quod_simplex:test_state_set(signing_journal, Reopened, S0), Reopened),
            %% A duplicate full-own Vote must not promote the restored
            %% missing row or fabricate a successful private binding.
            {ok, VoteBytes} = quod_atomic:encode_record(quod_atomic:control_body(C)),
            {ok, StillOwned, []} = quod_simplex:test_start_local_dtx_endpoint_request(
                {submit, <<19:128>>, VoteBytes}, [], 10000, {self(), make_ref()}, Rebuilt),
            {_, []} = quod_simplex:test_progress_dtx_admission(StillOwned),
            receive
                {'$gen_cast', {dtx_verdict_req, {vote, Expected}, _, _, _, _, _}} -> ok;
                {'$gen_cast', {dtx_verdict_req, {vote, _}, _, _, _, _, _}} -> error(premature_preparation)
            after 1000 -> error(no_restored_selection) end,
            ok = quod_simplex:test_close_dtx_endpoint(StillOwned),
            {_, _, #{group := #{vote_deadline_ms := D}}} = Expected,
            P = quod_atomic:initial_projection(O, 0),
            Pending = [Expected],
            Index = memory_outcome(O),
            try quod_ct:with_network_identity(maps:get(network, F), fun() ->
                Context = admission_context(F, O, Index, 1),
                ?assertMatch({ok, wait, _}, quod_commit_validation:vote_choice(Missing, D, Context)),
                ?assertMatch({ok, {refused, [vote_deadline]}, _},
                             quod_commit_validation:vote_choice(Missing, D + 1, Context))
            end)
            after ok = quod_outcome:close(Index) end,
            case Edge of
                activated -> ?assertMatch(#{Id := _}, quod_dtx_owner:desired(binding(O), P, Pending, D));
                _ -> ?assertEqual(#{}, quod_dtx_owner:desired(binding(O), P, Pending, D))
            end,
            ?assertMatch(#{Id := _}, quod_dtx_owner:desired({error, not_in_charge}, P, Pending, D + 1))
        after ok = quod_signing_journal:close(Reopened) end
    after
        _ = quod_signing_journal:close(J),
        true = gproc:unreg(quod_reg:name({quod_prolog, Ns})),
        receive {'$gen_cast', {project_pending_votes, _}} -> ok after 0 -> ok end,
        ok = file:del_dir_r(Dir)
    end.

source_owner_caches_parent_selection_until_journal_handoff_test() ->
    source_owner_parent_selection(no_relay).

peer_vote_relay_during_cached_parent_selection_test() ->
    source_owner_parent_selection(peer_relay).

own_vote_echo_during_cached_parent_selection_test() ->
    source_owner_parent_selection(own_echo).

source_owner_parent_selection(Scenario) ->
    %% Real Prolog callbacks and a real signing-journal reopen, with Simplex's
    %% production admission functions called directly. The installed height-1
    %% policy is a fixture, not a full founding/consensus-node test.
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"atomic:handoff:", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    O = {Ns, <<0:256>>}, T = {<<"atomic:remote">>, <<1:256>>},
    F = bind(quod_ct:signed_plan_fixture(#{target => O, atomic => true}, [O, T])),
    #{control := C} = vote(F, O, own(F, O), prepared), M = quod_atomic:control_material(C),
    Id = quod_atomic:group_id(C),
    {ok, Ref} = quod_dtx:manifest_group_ref(maps:get(manifest, F), Id),
    Dir = filename:join("/tmp", "quod_admission_journal_" ++
          binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    {ok, Engine} = quod_prolog:start_link(Ns, #{outcome_backend => memory}),
    {ok, J} = quod_signing_journal:initialize(Ns, <<99:256>>, Dir),
    ExpectedEnvelope = try quod_ct:with_network_identity(maps:get(network, F), fun() ->
        Node = maps:get(node_identity, F), Member = maps:get(pubkey, Node),
        Peer = signer(), PeerKey = maps:get(pubkey, Peer),
        Validators = case Scenario of no_relay -> [Member]; _ -> lists:sort([Member, PeerKey]) end,
        Admissions = maps:from_list([{K, maps:get(admission, F)} || K <- Validators]),
        Facts = [{can_invoke, {'Goal'}, {'Principal'}, {'Chain'}, {'Namespace'}},
                 {peer_admitted, Member, "validator", 14567, Member}] ++
                [{peer_admitted, K, "validator", 14568, K} || K <- Validators -- [Member]] ++
                quod_ct:signed_agent_facts(F),
        Change = quod_ct:change(Ns, lists:append([quod_ct:diff_for(Fact) || Fact <- Facts]), #{}),
        ok = quod_prolog:apply_entry(Ns, quod_ct:committed_entry(Ns, 1, quod_ct:batch(Change)), live),
        ?assertEqual(1, quod_prolog:applied(Ns)),
        S0 = state(#{ns => Ns, genesis_hash => element(2, O),
              self => Member, id => Node, validators => Validators,
              author_admissions => Admissions,
              signing_journal => J, slot => 1, history_head => {1, <<7:256>>},
              sync => ready, prolog_ready => true}),
        Token = make_ref(),
        {ok, Reserved} = quod_simplex:test_enqueue_dtx_intent(
                          {self(), make_ref()}, Engine, Token, M, Ref,
                          quod_time:mono_ms() + 1000, S0),
        ?assertMatch(#{reserved := 1, active := 0}, quod_simplex:test_dtx_admission_state(Reserved)),
        Active = quod_simplex:test_activate_dtx_intent(Engine, Token, Reserved),
        {Checking, []} = quod_simplex:test_progress_dtx_admission(Active),
        {Tag, Key, Timestamp, Reply} = receive
            {dtx_verdict, {dtx_admission, Tag0, Key0, Ts0}, Engine, 1,
              {selection, {vote, M}, _} = R} -> {Tag0, Key0, Ts0, R}
        after 1000 -> error(owner_selection_missing) end,
        Paused = quod_simplex:test_state_set(prolog_ready, false, Checking),
        Selected = quod_simplex:on_admission_verdict(Tag, Key, Timestamp, Engine, 1, Reply, Paused),
        {Selected, []} = quod_simplex:test_progress_dtx_admission(Selected),
        ?assertMatch(#{rows := Rows} when map_size(Rows) =:= 0, quod_simplex:test_retained_dtx_state(Selected)),
        ?assertEqual(Selected, quod_simplex:on_admission_verdict(
                                 Tag, Key, Timestamp, Engine, 1, Reply, Selected)),
        {Signed0, []} = quod_simplex:test_progress_dtx_admission(
                        quod_simplex:test_state_set(prolog_ready, true, Selected)),
        Signed = case Scenario of
            no_relay -> Signed0;
            _ ->
                {ok, WithWaiter} = quod_simplex:test_retain_dtx_record(
                    quod_atomic:control_body(C), {dtx_endpoint, self()}, Signed0),
                WithWaiter
        end,
        ?assertMatch(#{active := 0, reserved := 0}, quod_simplex:test_dtx_admission_state(Signed)),
        #{rows := SignedRows} = quod_simplex:test_retained_dtx_state(Signed),
        [#{envelope := Envelope}] = maps:values(SignedRows),
        {ok, SignedControl} = quod_atomic:decode_control(Envelope),
        ?assertEqual(M, quod_atomic:control_material(SignedControl)),
        PresentId = <<10:128>>, PresentFrom = {self(), make_ref()},
        Present = {present, PresentId, Id, quod_atomic:encode_group(maps:get(group, F))},
        {ok, StillSigned, PresentActions} = quod_simplex:test_start_local_dtx_endpoint_request(
                                             Present, [], 1, PresentFrom, Signed),
        ?assertEqual([{reply, PresentFrom, {ok, {presented, PresentId, Id}, []}}], PresentActions),
        ?assertEqual(Signed, StillSigned),
        receive {dtx_verdict, {dtx_admission, _, _, _}, _, _, _} -> error(revalidated_selected_material)
        after 0 -> ok end,
        %% A new committed parent with no relevant changes reuses both the
        %% selection and exact durable envelope (zero re-proof/signing/fsync).
        ok = quod_prolog:apply_entry(Ns, quod_ct:committed_entry(Ns, 2, {batch, [quod_ct:change(Ns, [], #{})]}), live),
        ?assertEqual(2, quod_prolog:applied(Ns)),
        Advanced = quod_simplex:test_state_set(history_head, {2, <<8:256>>},
                     quod_simplex:test_state_set(slot, 2, Signed)),
        AwaitingApply = quod_simplex:test_refresh_retained_readiness(Advanced),
        ?assertMatch(#{retained := 0}, quod_simplex:test_retained_dtx_state(AwaitingApply)),
        ?assertMatch(#{active := 1}, quod_simplex:test_dtx_admission_state(AwaitingApply)),
        ?assertEqual([], quod_simplex:test_eligible_dtx_wave(AwaitingApply)),
        case Scenario of
        no_relay ->
        Applied = quod_simplex:on_admission_parent_applied(Engine, {{2, <<8:256>>}, #{}}, AwaitingApply),
        {{Reused, []}, {call_time, Signing}} = tprof:profile(fun() ->
            quod_simplex:test_progress_dtx_admission(Applied)
        end, #{type => call_time, report => return, set_on_spawn => false,
               pattern => [{quod_atomic, sign_control, 6}, {quod_signing_journal, record_dtx, 2},
                           {quod_prolog, request_dtx_verdict, 6}]}),
        ?assertEqual([], Signing),
        ?assertEqual(quod_simplex:test_signing_journal(Signed),
                     quod_simplex:test_signing_journal(Reused)),
        ?assertEqual(SignedRows, maps:get(rows, quod_simplex:test_retained_dtx_state(Reused))),
        Classified = quod_simplex:test_refresh_retained_readiness(Reused),
        ?assertEqual(Classified, quod_simplex:test_refresh_retained_readiness(Classified)),
        %% Pin a prospective block time beyond the deadline without sleeping
        %% or changing the manifest. This is injected owner time, not a claim
        %% that consensus certified a future wall-clock timestamp.
        {_, _, #{group := #{vote_deadline_ms := Deadline}}} = M,
        ?assertMatch([_], quod_simplex:test_eligible_dtx_wave(Reused)),
        Era = quod_ledger:initial_era(O), Root = {Era, 1, <<8:256>>},
        LateCandidate = quod_simplex:test_state_set(eng,
            quod_simplex:eng_new(<<0:256>>, [Member], {Root, element(1, maps:get(history_head, quod_simplex:test_state_projection(Reused))), Deadline + 1}), Reused),
        ?assertEqual([], quod_simplex:test_eligible_dtx_wave(LateCandidate)),
        %% The approved parent can also be ahead of the committed floor. Both
        %% selection and consumption must use that same prospective time, not
        %% disagree because one still reads the committed parent's timestamp.
        {ok, AheadParent} = quod_ledger:new_block({Era, 2}, Root,
                                                element(1, maps:get(history_head, quod_simplex:test_state_projection(Reused))) + 1, {batch, [{dtx, SignedControl}]}, Deadline + 1),
        AheadOwner = quod_simplex:test_blocked_dtx_owner(AheadParent,
            quod_simplex:test_state_set(eng, quod_simplex:eng_new(<<0:256>>, [Member], {Root, element(1, maps:get(history_head, quod_simplex:test_state_projection(Reused))), 0}), Reused)),
        ?assertEqual([], quod_simplex:test_eligible_dtx_wave(AheadOwner)),
        Expired = quod_simplex:test_refresh_retained_readiness(AheadOwner),
        {ok, Negative} = quod_atomic:select_vote(M, {refused, [vote_deadline]}),
        Refused = select_owner_vote(Engine, 2, Negative, Expired),
        #{rows := RefusedRows} = quod_simplex:test_retained_dtx_state(Refused),
        [#{envelope := NegativeEnvelope, inserted_at := At, observation_started_at := Started}] =
            maps:values(RefusedRows),
        [#{inserted_at := At, observation_started_at := Started}] = maps:values(SignedRows),
        {ok, NegativeControl} = quod_atomic:decode_control(NegativeEnvelope),
        ?assertEqual(Negative, quod_atomic:control_material(NegativeControl)),
        ?assertEqual(quod_atomic:intent_id(M), quod_atomic:intent_id(Negative)),
        ?assert(maps:get(sequence, quod_atomic:control_metadata(NegativeControl)) >
                maps:get(sequence, quod_atomic:control_metadata(SignedControl))),
        NegativeEnvelope;
        _ ->
            source_owner_relay_selection(Scenario, F, Peer, Engine, SignedControl,
                                        Signed, AwaitingApply)
        end
    end)
    after
        ok = quod_signing_journal:close(J),
        gen_server:stop(Engine)
    end,
    try
        {ok, Reopened} = quod_signing_journal:recover(Ns, <<99:256>>, Dir),
        #{Id := #{envelope := Saved}} = quod_signing_journal:pending_dtx(Reopened),
        ?assertEqual(ExpectedEnvelope, Saved),
        Rebuilt = quod_simplex:test_restore_pending_dtx(
                    state(#{ns => Ns, genesis_hash => element(2, O),
                                             signing_journal => Reopened}), Reopened),
        ?assertMatch(#{active := 1}, quod_simplex:test_dtx_admission_state(Rebuilt)),
        ?assertMatch(#{rows := Empty} when map_size(Empty) =:= 0,
                     quod_simplex:test_retained_dtx_state(Rebuilt)),
        ok = quod_signing_journal:close(Reopened)
    after ok = file:del_dir_r(Dir)
    end.

source_owner_relay_selection(Scenario, F, Peer, Engine, OwnControl, Signed, AwaitingApply) ->
    {Ns, _} = Target = maps:get(origin, F),
    Material = quod_atomic:control_material(OwnControl),
    Digest = quod_atomic:record_digest(OwnControl), Id = quod_atomic:group_id(OwnControl),
    Admission = maps:get(admission, F), Node = maps:get(node_identity, F),
    Member = maps:get(pubkey, Node), PeerKey = maps:get(pubkey, Peer),
    {ok, OwnEnvelope} = quod_atomic:encode_control(OwnControl),
    RelayControl = case Scenario of
        peer_relay ->
            {ok, C} = quod_atomic:sign_control(Target, Material, Admission, 1, 0, Peer), C;
        own_echo -> OwnControl
    end,
    {ok, RelayEnvelope} = quod_atomic:encode_control(RelayControl),
    ?assertEqual(Digest, quod_atomic:record_digest(RelayControl)),
    %% Keep transport/coordinator effects in this fixture process; the real
    %% running callback still performs its entire post-ingress reconciliation.
    Linked = quod_simplex:test_state_set(conns, #{PeerKey => {self(), make_ref()}},
        quod_simplex:test_state_set(inbound_conns, #{PeerKey => {self(), make_ref()}},
        quod_simplex:test_state_set(eng, quod_simplex:eng_new(
            quod_simplex:consensus_domain(Ns, element(2, Target)),
            lists:sort([Member, PeerKey]), {{quod_ledger:initial_era(Target), 1, <<8:256>>}, element(1, maps:get(history_head, quod_simplex:test_state_projection(AwaitingApply))), 0}),
        quod_simplex:test_seed_running_dtx_coordinator(Id, self(), AwaitingApply)))),
    Journal = quod_simplex:test_signing_journal(Signed),
    OwnFloor = quod_signing_journal:dtx_floor(Journal, {Admission, Member}),
    PeerFloor = quod_signing_journal:dtx_floor(Journal, {Admission, PeerKey}),
    Caller = self(),
    Profile = #{type => call_time, report => return, set_on_spawn => false,
                pattern => [{quod_atomic, sign_control, 6}, {quod_signing_journal, record_dtx, 2},
                            {quod_prolog, request_dtx_verdict, 6}]},
    {{keep_state, Relayed, _}, {call_time, RelayCalls}} = tprof:profile(fun() ->
        %% test_state's consensus channel is fixed even with a unique Ns.
        quod_simplex:running(info,
            {quod_message, {{PeerKey, ignored}, Caller},
             term_to_binary({log, <<"t">>}, [deterministic]),
             quod_simplex:encode(Ns, {dtx_submit, [RelayEnvelope], []})}, Linked)
    end, Profile),
    ?assertEqual([], RelayCalls),
    ?assertMatch(#{active := 1}, quod_simplex:test_dtx_admission_state(Relayed)),
    %% An ordinary duplicate submit adds another real endpoint waiter to the
    %% accepted group while the cached local selection is still detached.
    {Record, _, _} = Material,
    {ok, RecordBlob} = quod_atomic:encode_record(Record),
    {ok, Waiting, []} = quod_simplex:test_start_local_dtx_endpoint_request(
        {submit, <<11:128>>, RecordBlob}, [], 10000, {Caller, make_ref()}, Relayed),
    try
        {{Reused, []}, {call_time, Calls}} = tprof:profile(fun() ->
            Reconciled = quod_simplex:test_refresh_retained_readiness(Waiting),
            Applied = quod_simplex:on_admission_parent_applied(
                Engine, {{2, <<8:256>>}, #{}}, Reconciled),
            quod_simplex:test_progress_dtx_admission(Applied)
        end, Profile),
        ?assertEqual([], Calls),
        AfterJournal = quod_simplex:test_signing_journal(Reused),
        ?assertEqual(Journal, AfterJournal),
        ?assertEqual(OwnFloor, quod_signing_journal:dtx_floor(AfterJournal, {Admission, Member})),
        ?assertEqual(PeerFloor, quod_signing_journal:dtx_floor(AfterJournal, {Admission, PeerKey})),
        ?assertMatch(#{active := 0, reserved := 0}, quod_simplex:test_dtx_admission_state(Reused)),
        #{retained := 1, bytes := Bytes, waiters := 2, waiter_index := Waiters,
          rows := Rows} = quod_simplex:test_retained_dtx_state(Reused),
        [Waiter] = maps:keys(Waiters) -- [Caller],
        ?assertEqual(#{Caller => Digest, Waiter => Digest}, Waiters),
        ?assertEqual(byte_size(RelayEnvelope), Bytes),
        [#{envelope := RelayEnvelope, bytes := Bytes, inserted_at := At,
           observation_started_at := Started}] = maps:values(Rows),
        [#{inserted_at := At, observation_started_at := Started}] =
            maps:values(maps:get(rows, quod_simplex:test_retained_dtx_state(Signed))),
        ?assertEqual(quod_simplex:test_retained_dtx_state(Reused),
            quod_simplex:test_retained_dtx_state(quod_simplex:test_refresh_retained_readiness(Reused))),
        #{entry := Entry, ref := Ref} = certified_control(
            #{control => RelayControl, ref => none}, [Node, Peer], 3),
        #entry{data = Payload} = quod_ledger:entry_view(Entry),
        Done = quod_simplex:test_resolve_committed_dtx(Entry, Payload, Reused),
        Reply = {ok, Ref, [{Ref, Entry}]},
        receive {dtx_submit_result, Reply} -> ok after 1000 -> error(lost_original_waiter) end,
        receive {dtx_endpoint_worker_result, Waiter, {submit_result, Digest, Reply}} -> ok
        after 1000 -> error(lost_relay_waiter) end,
        ?assertMatch(#{retained := 0, bytes := 0, waiters := 0},
                     quod_simplex:test_retained_dtx_state(Done)),
        OwnEnvelope
    after quod_simplex:test_close_dtx_endpoint(Waiting)
    end.

select_owner_vote(Engine, Floor, Expected, S) ->
    {Checking, []} = quod_simplex:test_progress_dtx_admission(S),
    {Tag, Key, Timestamp, Reply} = receive
        {dtx_verdict, {dtx_admission, T, K, Ts}, Engine, Floor,
          {selection, {vote, Expected}, _} = R} -> {T, K, Ts, R};
        {dtx_verdict, _, Engine, Floor, Other} -> error({wrong_owner_choice, Other})
    after 1000 -> error(owner_reselection_missing) end,
    Selected = quod_simplex:on_admission_verdict(Tag, Key, Timestamp, Engine, Floor,
                                                Reply, Checking),
    {Retained, []} = quod_simplex:test_progress_dtx_admission(Selected),
    Retained.

installed_admission_loss_keeps_source_custody_until_certified_history_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    F = fixture(), {Ns, Anchor} = O = maps:get(origin, F),
    #{control := Control} = vote(F, O, own(F, O), prepared),
    Id = quod_atomic:group_id(Control), Node = maps:get(node_identity, F),
    Member = maps:get(pubkey, Node), Admission = maps:get(admission, F),
    Dir = filename:join("/tmp", "quod-admission-loss-" ++
                       binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    {ok, J0} = quod_signing_journal:initialize(Ns, <<99:256>>, Dir),
    {ok, J1, _} = quod_signing_journal:record_dtx(J0, Control),
    {ok, Phase} = quod_dtx_phase_index:open(Dir, Ns),
    try
        S0 = state(#{ns => Ns, genesis_hash => Anchor,
               self => Member, id => Node, validators => [Member],
               author_admissions => #{Member => Admission},
               signing_journal => J1, phase_index => Phase, slot => 1,
               sync => ready, prolog_ready => true}),
        Restored = quod_simplex:test_restore_pending_dtx(S0, J1),
        Projection = quod_simplex:test_state_projection(Restored),
        [?assertMatch(#{active := 1}, quod_simplex:test_dtx_admission_state(
              quod_simplex:test_install_projection(Projection, Paused)))
         || Paused <- [quod_simplex:test_state_set(sync, unconfirmed, Restored),
                       quod_simplex:test_state_set(sync, {pulling, self()}, Restored),
                       quod_simplex:test_state_set(prolog_ready, false, Restored)]],
        Removed = Projection#{committee := [], admissions := #{}},
        Released = quod_simplex:test_install_projection(Removed, Restored),
        ?assertMatch(#{active := 0, reserved := 0}, quod_simplex:test_dtx_admission_state(Released)),
        %% Volatile release itself has neither journal nor outcome authority.
        ?assert(maps:is_key(Id, quod_signing_journal:pending_dtx(
                                quod_simplex:test_signing_journal(Released)))),
        {Reconciled, none} =
            quod_simplex:test_reconcile_signing_state(Released),
        Saved = quod_signing_journal:pending_dtx(quod_simplex:test_signing_journal(Reconciled)),
        ?assertMatch(#{Id := #{material := _}}, Saved),
        %% Losing signing rights is not losing the duty to deliver source work
        %% to today's committee. The old node has no local vote authority.
        ?assertMatch(#{Id := #{ref := none}}, quod_dtx_owner:desired(
            {error, not_in_charge}, maps:get(dtx, Removed),
            [maps:get(material, maps:get(Id, Saved))], quod_time:now_ms())),
        ?assertEqual(maps:get(dtx, Projection),
                     maps:get(dtx, quod_simplex:test_state_projection(Reconciled))),
        Rejoined = quod_simplex:test_install_projection(
                     Projection#{admissions := #{Member => <<123:256>>}}, Reconciled),
        ?assertMatch(#{active := 0, reserved := 0}, quod_simplex:test_dtx_admission_state(Rejoined))
    after
        ok = quod_signing_journal:close(J1),
        ok = quod_dtx_phase_index:close(Phase),
        ok = file:del_dir_r(Dir)
    end.

snapshot_absence_never_becomes_gateway_exclusion_test() ->
    F = fixture(), {Ns, Anchor} = O = maps:get(origin, F),
    {ok, Ref} = quod_dtx:manifest_group_ref(maps:get(manifest, F),
                                          quod_atomic:group_id(maps:get(group, F))),
    Coordinator = element(4, Ref),
    %% Protocol fixtures for an authenticated current-view collector: no
    %% consensus nodes or physical transport, and no exact-entry claim.
    OtherKeys = [<<I:256>> || I <- lists:seq(41, 44)],
    lists:foreach(fun(Keys) ->
        Routes = [{K, [{"127.0.0.1", 14000 + I}]} ||
                  {K, I} <- lists:zip(Keys, lists:seq(1, 4))],
        View = #{identity => O, slot => 8, committee => Keys,
                 committee_id => <<88:256>>, route_candidates => Routes},
        ProbesTable = ets:new(outcome_probes, [set, public]),
        Reply = fun(_, _, Key, _, Request, _) ->
            true = ets:insert(ProbesTable, {{Key, Request}}),
            case Request of
                {outcome, Id, Ref, CommitteeId, 8} ->
                    {ok, {outcome, Id, O, CommitteeId, 8, not_found}, []};
                _ -> {error, not_ready}
            end
        end,
        Deps = #{view => fun(_, _, _) -> {ok, View} end,
                 remote => Reply, resolve => fun(_) -> error end,
                 node_key => fun() -> none end},
        try
            ?assertEqual({error, retry}, quod_dtx_current_view:test_lookup_outcome(
                <<"atomic:observer">>, {remote, Routes}, Ref,
                quod_time:mono_ms() + 1000, Deps)),
            Probes = [P || {P} <- ets:tab2list(ProbesTable)],
            ?assert(length(Probes) >= 2),
            ?assert(lists:all(fun({_, {outcome, _, Ref0, _, 8}}) -> Ref0 =:= Ref;
                                (_) -> false end, Probes)),
            ?assertEqual({ok, {Ns, Anchor}}, quod_outcome:ref_identity(Ref))
        after ets:delete(ProbesTable)
        end
    end, [lists:sort([Coordinator | tl(OtherKeys)]), OtherKeys]).

old_gateway_exclusion_wire_is_not_an_atomic_outcome_test() ->
    Ns = <<"atomic:absence">>, O = {Ns, <<1:256>>},
    Ref = {group, Ns, <<1:256>>, <<2:256>>, <<3:256>>, <<4:256>>},
    Id = <<1:128>>, Committee = <<5:256>>,
    Request = {outcome_barrier, Id, Ref, Committee, 1},
    ?assertMatch({error, _}, quod_dtx_endpoint:encode_request(Ns, Request, [])),
    ?assertEqual(error, quod_dtx_endpoint:request_id(Request)),
    lists:foreach(fun(Status) ->
        Response = {outcome_barrier, Id, O, Committee, 1, Status},
        ?assertMatch({error, _}, quod_dtx_endpoint:encode_response(Ns, Response, [])),
        ?assertEqual(error, quod_dtx_endpoint:response_id(Response)),
        ?assertNot(quod_dtx_endpoint:correlates(Request, Response))
    end, [not_found, pending_vote, coordinator_retired]),
    Rejected = {outcome, Id, O, Committee, 1,
                #{status => rejected, reason => coordinator_retired, ref => Ref}},
    ?assertMatch({error, _}, quod_dtx_endpoint:encode_response(Ns, Rejected, [])).

absent_local_group_preserves_outcome_uncertainty_test() ->
    %% Empty admitted boot, not full founding. Exercise the real public API;
    %% readiness is explicitly installed only for this lookup fixture.
    {ok, _} = application:ensure_all_started(gproc),
    Ns = <<"atomic:absent:", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Ref = {group, Ns, <<0:256>>, <<2:256>>, <<3:256>>, <<4:256>>},
    {ok, Engine} = quod_prolog:start_link(Ns, #{outcome_backend => memory}),
    try
        ok = quod_prolog:mark_ready(Ns),
        ?assertEqual({error, {outcome_unknown, Ref}}, quod_prolog:outcome(Ref)),
        ?assertEqual({ok, #{applied_floor => 0, outcome => not_found}},
                     quod_prolog:outcome_snapshot(Ns, Ref, 1000)),
        ok = quod_prolog:project_pending_votes(Ns, [Ref]),
        ?assertEqual({ok, #{status => pending, phase => pending_vote, ref => Ref}},
                     quod_prolog:outcome(Ref)),
        ok = quod_prolog:project_pending_votes(Ns, []),
        ?assertEqual({error, {outcome_unknown, Ref}}, quod_prolog:outcome(Ref)),
        %% Only the genesis directory entry is a fixture; effect resolution
        %% itself uses both real production owner lookups. Absence must not
        %% release/cancel a privately prepared effect.
        TableName = binary_to_atom(<<"quod_simplex_genesis_", Ns/binary>>, utf8),
        Table = ets:new(TableName, [named_table, public, set]),
        try
            true = ets:insert(Table, {anchor, <<0:256>>}),
            ?assertEqual({error, {outcome_unknown, Ref}},
                quod_prolog:effect_resolution({Ns, <<0:256>>}, Ref, <<5:256>>, <<6:256>>))
        after ets:delete(Table)
        end,
        ok = quod_prolog_tests:absent_pending_group_keeps_exact_waiter_test()
    after gen_server:stop(Engine)
    end.

outcome_stores_source_resolve_height_but_waits_for_complete_publication_test() ->
    F = fixture(), O = maps:get(origin, F), Votes = votes(F),
    Resolves = maps:from_list([{T, resolve(F, T, commit, Votes, 2)}
                              || T <- maps:get(participant_targets, F)]),
    I0 = publish_outcome(memory_outcome(O), 1),
    {I1, [none]} = outcome_wave(I0, [maps:get(O, Votes)]),
    {I2, [{resolve_applied, Id, 3, 2}]} =
        outcome_wave(publish_outcome(I1, 2), [maps:get(O, Resolves)]),
    ?assertEqual(quod_atomic:group_id(maps:get(group, F)), Id),
    ?assertMatch(#{Id := #{blocking := true}}, outcome_fences(I2)),
    I3 = publish_outcome(I2, 3),
    ?assertMatch(#{Id := #{blocking := false}}, outcome_fences(I3)),
    {I4, [none]} = outcome_wave(I3, [complete(F, commit, Resolves)]),
    ?assertMatch({ok, #{status := pending, phase := publication}}, public_group(F, I4)),
    {ok, I5} = quod_outcome:advance_applied(I4, 4),
    ?assertMatch({ok, #{status := pending, phase := publication}}, public_group(F, I5)),
    {ok, I6} = quod_outcome:flush(I5),
    ?assertMatch({ok, #{status := committed, height := 3,
                       participant_slots := [{_, 3, 2}, {_, 3, 2}]}}, public_group(F, I6)),
    {I7, [none]} = outcome_wave(I6, [maps:get(O, Resolves)]),
    ?assertEqual(public_group(F, I6), public_group(F, I7)),
    ?assertEqual(#{}, outcome_fences(I7)),
    ok = quod_outcome:close(I7).

negative_only_outcome_keeps_reasons_without_a_decision_or_foreign_bundle_test() ->
    F = fixture(), O = maps:get(origin, F),
    Votes = #{O => vote(F, O, none, {refused, [vote_deadline]})},
    Resolves = maps:from_list([{T, resolve(F, T, abort, Votes, 0)}
                              || T <- maps:get(participant_targets, F)]),
    {I1, [none]} = outcome_wave(publish_outcome(memory_outcome(O), 1), [maps:get(O, Votes)]),
    {I2, [_]} = outcome_wave(publish_outcome(I1, 2), [maps:get(O, Resolves)]),
    {I3, [none]} = outcome_wave(publish_outcome(I2, 3), [complete(F, abort, Resolves)]),
    I4 = publish_outcome(I3, 4),
    ?assertMatch({ok, #{status := aborted, height := 3, reasons := [vote_deadline]}},
                 public_group(F, I4)),
    Id = quod_atomic:group_id(maps:get(group, F)),
    {{ok, #{history := #{records := Records}}}, _} = quod_outcome:lookup_group(I4, Id),
    ?assertEqual([complete, resolve, vote], lists:sort(maps:keys(Records))),
    [?assertEqual([digest, ref], lists:sort(maps:keys(Row))) || Row <- maps:values(Records)],
    ?assertEqual(#{}, maps:get(groups, maps:get(projection, quod_outcome:dtx_state(I4)))),
    ok = quod_outcome:close(I4).

whole_outcome_wave_acknowledges_every_resolve_at_one_applied_boundary_test() ->
    F1 = fixture(), F2 = fixture(#{goal_text => <<"assertz(other(ok)).">>}),
    O = maps:get(origin, F1), V1 = votes(F1), V2 = votes(F2),
    {I1, [none, none]} = outcome_wave(publish_outcome(memory_outcome(O), 1), [maps:get(O, V1), maps:get(O, V2)]),
    {I2, Acks} = outcome_wave(publish_outcome(I1, 2),
        [resolve(F1, O, commit, V1, 2), resolve(F2, O, commit, V2, 2)]),
    ?assertEqual(2, length(Acks)),
    ?assertEqual([true, true], [maps:get(blocking, R) || R <- maps:values(outcome_fences(I2))]),
    I3 = publish_outcome(I2, 3),
    ?assertEqual([false, false], [maps:get(blocking, R) || R <- maps:values(outcome_fences(I3))]),
    ?assert(quod_atomic:valid_projection(maps:get(projection, quod_outcome:dtx_state(I3)))),
    ok = quod_outcome:close(I3).

outcome_disk_replay_rebuilds_own_projection_and_retains_tombstones_test() ->
    F = fixture(), O = maps:get(origin, F), T = foreign(F),
    Votes = #{O => vote(F, O, none, {refused, [vote_deadline]})},
    R = resolve(F, T, abort, Votes, 0),
    {Ns, Anchor} = T, Id = quod_atomic:group_id(maps:get(group, F)),
    Dir = filename:join("/tmp", "quod_atomic_outcome_" ++
          binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    Config = #{data_dir => Dir, outcome_backend => disk},
    try
        {ok, I0} = quod_outcome:open(Ns, Anchor, Config),
        {I1, [{resolve_applied, Id, 3, 0}]} = outcome_wave(publish_outcome(publish_outcome(I0, 1), 2), [R]),
        I2 = publish_outcome(I1, 3),
        %% I0 has no cached row: this lookup checks the actual disk decoder.
        {{ok, Row}, _} = quod_outcome:lookup_group(I0, Id),
        ?assertMatch(#{applied := #{verdict := abort, resolve_ref := _, reasons := [vote_deadline]}}, Row),
        ok = quod_outcome:close(I2),
        {ok, Reopened} = quod_outcome:open(Ns, Anchor, Config),
        ?assertEqual(0, quod_outcome:applied_floor(Reopened)),
        {not_found, _} = quod_outcome:lookup_group(Reopened, Id),
        %% Reopening intentionally resets the derived projection. The ledger
        %% replay reinstalls its tombstone; no new network evidence is fetched.
        {R1, [_]} = outcome_wave(publish_outcome(publish_outcome(Reopened, 1), 2), [R]),
        R2 = publish_outcome(R1, 3),
        {{ok, Row}, _} = quod_outcome:lookup_group(R2, Id),
        {H, _} = quod_outcome:group_history(R2, Id),
        P = maps:get(projection, quod_outcome:dtx_state(R2)),
        ?assertMatch({error, {invalid_transition, phase_reversal}},
                     reduce(vote(F, T, own(F, T), prepared), H, P)),
        ok = quod_outcome:close(R2)
    after ok = file:del_dir_r(Dir)
    end.

pending_vote_projection_uses_only_exact_journal_identity_test() ->
    F = fixture(), O = maps:get(origin, F), Id = quod_atomic:group_id(maps:get(group, F)),
    {ok, Pending} = quod_dtx:manifest_group_ref(maps:get(manifest, F), Id),
    I0 = memory_outcome(O),
    {ok, I1} = quod_outcome:project_pending_votes(I0, [Pending]),
    ?assertMatch({ok, #{status := pending, phase := pending_vote}}, public_group(F, I1)),
    {I2, [none]} = outcome_wave(I1, [vote(F, O, own(F, O), prepared)]),
    ?assertEqual(#{}, maps:get(pending_votes, quod_outcome:dtx_state(I2))),
    ?assertMatch({ok, #{status := pending, phase := voted}}, public_group(F, I2)),
    ok = quod_outcome:close(I2).

%% Reducer/index adapter tests, not consensus or MVCC integration witnesses.
outcome_wave(I0, Rows) ->
    ControlRefs = lists:sort(fun({A, _}, {B, _}) ->
        quod_atomic:control_order_key(A) < quod_atomic:control_order_key(B)
    end, [{C, R} || #{control := C, ref := R} <- Rows]),
    {Histories, I1} = lists:foldl(fun({C, _}, {Hs, Acc}) ->
        Id = quod_atomic:group_id(C), {H, Next} = quod_outcome:group_history(Acc, Id),
        {Hs#{Id => H}, Next}
    end, {#{}, I0}, ControlRefs),
    P = maps:get(projection, quod_outcome:dtx_state(I1)),
    {ok, _, _, Items} = quod_atomic:reduce_batch(ControlRefs, Histories, P),
    {I2, ReverseAcks} = lists:foldl(fun(Item, {Acc, Acks}) ->
        {ok, Next, Ack} = quod_outcome:apply_dtx(Acc, Item), {Next, [Ack | Acks]}
    end, {I1, []}, Items),
    {I2, lists:reverse(ReverseAcks)}.
memory_outcome({Ns, Anchor}) ->
    {ok, Index} = quod_outcome:open(Ns, Anchor, #{outcome_backend => memory}), Index.
publish_outcome(Index, Slot) ->
    {ok, I1} = quod_outcome:advance_applied(Index, Slot),
    {ok, I2} = quod_outcome:flush(I1), I2.
outcome_fences(Index) ->
    maps:get(apply_fences, maps:get(projection, quod_outcome:dtx_state(Index))).
public_group(F, Index) ->
    {ok, Ref} = quod_dtx:manifest_group_ref(maps:get(manifest, F),
                                          quod_atomic:group_id(maps:get(group, F))),
    {{ok, Row}, _} = quod_outcome:lookup_ref(Index, Ref), quod_outcome:public(Row).

state(Overrides) ->
    Ns = maps:get(ns, Overrides, <<"t">>),
    Anchor = maps:get(genesis_hash, Overrides, <<0:256>>),
    Height = maps:get(slot, Overrides, 0),
    {_, Hash} = maps:get(history_head, Overrides, {Height, Anchor}),
    Root = {quod_ledger:initial_era({Ns, Anchor}), max(0, Height - 1), Hash},
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    Eng = quod_simplex:eng_new(Domain, maps:get(validators, Overrides, []),
                              {Root, max(1, Height), maps:get(last_ts, Overrides, 0)}),
    quod_simplex:test_state(maps:merge(#{eng => Eng, consensus_domain => Domain}, Overrides)).

fixture() -> fixture(#{}).
fixture(Overrides) ->
    Origin = {<<"atomic:origin">>, <<1:256>>},
    Target = {<<"atomic:target">>, <<2:256>>},
    F = quod_ct:signed_plan_fixture(Overrides#{target => Origin, atomic => true}, [Origin, Target]),
    %% Staging assertz advances each proof overlay once. Resolve commits use
    %% prepared-generation + 1, independent of the owner's global generation.
    [?assertEqual(1, quod_dtx:overlay_generation(P)) || P <- maps:values(maps:get(plans, F))],
    bind(F).
bind(F) ->
    Origin = maps:get(origin, F),
    {ok, G} = quod_atomic:new_group(maps:get(manifest, F), maps:get(auth, F),
                                   maps:get(Origin, maps:get(attestations, F))),
    F#{group => G}.
fork(F) ->
    Manifest = setelement(5, maps:get(manifest, F), <<99:256>>),
    Bundles = [begin
        {ok, A} = quod_dtx:attest_plan(1, T, maps:get(T, maps:get(plans, F)),
                                      Manifest, maps:get(node_identity, F)),
        {T, D, B, A}
    end || {T, D, B, _} <- maps:get(bundles, F)],
    bind(F#{manifest := Manifest, bundles := Bundles,
            attestations := maps:from_list([{T, A} || {T, _, _, A} <- Bundles])}).
foreign(F) -> [T] = maps:get(participant_targets, F) -- [maps:get(origin, F)], T.
own(F, T) -> lists:keyfind(T, 1, maps:get(bundles, F)).
votes(F) -> maps:from_list([{T, vote(F, T, own(F, T), prepared)}
                            || T <- maps:get(participant_targets, F)]).
vote(F, T, Bundle, Choice) ->
    {ok, V} = quod_atomic:new_vote(maps:get(group, F), T, Bundle, Choice),
    envelope(F, T, V, 1).
envelope(F, {Ns, Anchor} = T, Record, Slot) ->
    {ok, Material} = quod_atomic:admission_material(Record),
    {ok, C} = quod_atomic:sign_control(T, Material, maps:get(admission, F), Slot, 0,
                                      maps:get(node_identity, F)),
    {ok, R} = quod_dtx:certified_ref(Ns, Anchor, Slot + 1, <<Slot:256>>,
                                    quod_atomic:record_digest(C), quod_ct:fixture_finality(Slot, <<Slot:256>>)),
    #{control => C, record => Record, ref => R}.
resolve(F, T, Outcome, Votes, Generation) ->
    ORef = maps:get(ref, maps:get(maps:get(origin, F), Votes)),
    Evidence = case Outcome of
                   commit -> {all_prepared, lists:sort([{V, maps:get(ref, Row)}
                                                       || {V, Row} <- maps:to_list(Votes)])};
                   abort ->
                       [Negative | _] = [maps:get(ref, Row) ||
                           {_, #{record := {quod_dtx_vote, 4, _, _, _, {refused, _}}} = Row} <-
                               lists:sort(maps:to_list(Votes))],
                       {refused, Negative}
               end,
    Own = case maps:find(T, Votes) of {ok, V} -> maps:get(ref, V); error -> none end,
    Result = case Evidence of
        {all_prepared, _} -> commit;
        {refused, NegativeRef} ->
            [ReasonsBlob] = [B || #{ref := Ref, record := {quod_dtx_vote, 4, _, _, _, {refused, B}}}
                                  <- maps:values(Votes), Ref =:= NegativeRef],
            {ok, Reasons} = quod_wire_term:decode_failure_reasons(ReasonsBlob),
            {abort, Reasons}
    end,
    {ok, R} = quod_atomic:new_resolve(maps:get(group, F), ORef, T, Result, Evidence, Own, Generation),
    checked(envelope(F, T, R, 2), maps:values(Votes)).
complete(F, Outcome, Resolves) ->
    Rows = lists:sort([{T, maps:get(ref, Row), element(10, maps:get(record, Row))}
                        || {T, Row} <- maps:to_list(Resolves)]),
    Applied = [{T, applied(F, R, Gen, Outcome)} || {T, R, Gen} <- Rows,
                  T =/= maps:get(origin, F),
                  element(9, maps:get(record, maps:get(T, Resolves))) =/= none],
    {ok, C} = quod_atomic:new_complete(maps:get(group, F), Outcome, Rows, Applied),
    checked(envelope(F, maps:get(origin, F), C, 3), maps:values(Resolves)).
applied(F, Ref, Generation, Outcome) ->
    {ok, Target, _, _} = quod_dtx:certified_ref_binding(Ref),
    Id = quod_atomic:group_id(maps:get(group, F)),
    {ok, Vote} = quod_applied_certificate:sign_applied_vote(
                   <<8:256>>, Target, <<9:256>>, Id, Ref, Generation, Outcome,
                   maps:get(node_identity, F)),
    {ok, Cert} = quod_applied_certificate:applied_certificate(
                   {<<8:256>>, Target, <<9:256>>, Id, Ref, Generation, Outcome}, [Vote]),
    Cert.
checked(#{control := C} = Row, Evidence) ->
    Needed = quod_atomic:reference_requirements(quod_atomic:control_material(C)),
    Rows = [begin
        [EC] = [Other || #{ref := R, control := Other} <- Evidence, quod_dtx:same_certified_ref(R, Ref)],
        {K, Ref, quod_atomic:control_material(EC)}
    end || {K, Ref} <- Needed],
    ok = quod_atomic:validate_references(C, Rows),
    Row.
fresh(Target) -> {quod_atomic:initial_group_history(), quod_atomic:initial_projection(Target, 0)}.
binding({Ns, Anchor}) -> {ok, {Ns, Anchor, <<71:256>>, <<72:256>>}}.
other_binding({Ns, Anchor}) -> {ok, {Ns, Anchor, <<73:256>>, <<74:256>>}}.
retained(C) ->
    {ok, Envelope} = quod_atomic:encode_control(C),
    Row = #dtx_submission{control = C, envelope = Envelope, group_id = quod_atomic:group_id(C),
        digest = quod_atomic:record_digest(C), inserted_at = 0, observation_started_at = 0,
        placement = ready, bytes = byte_size(Envelope)},
    quod_dtx_owner:put_new(Row, quod_dtx_owner:new()).
readiness(#{control := C}, P) -> quod_atomic:proposal_readiness(quod_atomic:control_material(C), P).
reduce(#{control := C, ref := Ref}, H, P) -> quod_atomic:reduce(C, Ref, H, P).
fold(Row, {H, P}) -> {ok, H1, P1, _Effects} = reduce(Row, H, P), {H1, P1}.

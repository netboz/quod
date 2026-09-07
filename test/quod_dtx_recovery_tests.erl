-module(quod_dtx_recovery_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_proof_limits.hrl").

commit_recovery_reconstructs_every_phase_in_target_order_test() ->
    with_fixture(
      fun(F) ->
          Begin = maps:get('begin', F),
          Origin = maps:get(origin, F),
          [A, B] = Targets = maps:get(targets, F),
          GroupId = maps:get(group_id, F),

          ?assertEqual(
             {ok, {ordered, 'begin', [{submit, Origin, Begin}]}},
             quod_dtx_recovery:next(Begin, quod_dtx_recovery:empty())),

          BeginEvidence = evidence(Origin, Begin, 1, F),
          S1 = snapshot([BeginEvidence], [], [], none),
          {ok, {independent, prepare, PrepareCommands}} =
              quod_dtx_recovery:next(Begin, S1),
          ?assertEqual(Targets, command_targets(PrepareCommands)),
          [{submit, A, PrepareA}, {submit, B, PrepareB}] = PrepareCommands,

          PrepareAEvidence = evidence(A, PrepareA, 2, F),
          PrepareBEvidence = evidence(B, PrepareB, 3, F),
          Generations = [{A, 1}, {B, 4}],
          S2 = snapshot(
                 [BeginEvidence, PrepareAEvidence, PrepareBEvidence],
                 Generations, [], none),
          {ok, {ordered, decision, [{submit, Origin, Decision}]}} =
              quod_dtx_recovery:next(Begin, S2),
          ?assertEqual(
             {ok, #{kind => decision, group_id => GroupId,
                    begin_ref => evidence_ref(BeginEvidence),
                    verdict => commit,
                    prepare_rows =>
                        [{A, evidence_ref(PrepareAEvidence)},
                         {B, evidence_ref(PrepareBEvidence)}],
                    reasons => none}},
             quod_dtx:recovery_phase(Decision)),

          DecisionEvidence = evidence(Origin, Decision, 4, F),
          S3 = snapshot(
                 [BeginEvidence, PrepareAEvidence, PrepareBEvidence,
                  DecisionEvidence], Generations, [], none),
          {ok, {independent, finalize, FinalizeCommands}} =
              quod_dtx_recovery:next(Begin, S3),
          ?assertEqual(Targets, command_targets(FinalizeCommands)),
          [{submit, A, FinalizeA}, {submit, B, FinalizeB}] =
              FinalizeCommands,
          ?assertMatch(
             {ok, #{kind := finalize, verdict := commit, generation := 2}},
             quod_dtx:recovery_phase(FinalizeA)),
          ?assertMatch(
             {ok, #{kind := finalize, verdict := commit, generation := 5}},
             quod_dtx:recovery_phase(FinalizeB)),

          FinalizeAEvidence = evidence(A, FinalizeA, 5, F),
          FinalizeBEvidence = evidence(B, FinalizeB, 6, F),
          PhaseEvidence =
              [BeginEvidence, PrepareAEvidence, PrepareBEvidence,
               DecisionEvidence, FinalizeAEvidence, FinalizeBEvidence],
          S4 = snapshot(PhaseEvidence, Generations, [], none),
          ?assertEqual(
             {ok, {independent, applied,
              [{applied, A, GroupId, evidence_ref(FinalizeAEvidence), 2,
                commit},
               {applied, B, GroupId, evidence_ref(FinalizeBEvidence), 5,
                commit}]}},
             quod_dtx_recovery:next(Begin, S4)),

          Applied =
              [applied(A, GroupId, FinalizeAEvidence, 2, commit),
               applied(B, GroupId, FinalizeBEvidence, 5, commit)],
          S5 = snapshot(PhaseEvidence, Generations, Applied, none),
          {ok, {ordered, complete, [{submit, Origin, Complete}]}} =
              quod_dtx_recovery:next(Begin, S5),
          %% Arrival-dependent quorum signatures are validation sidecar data,
          %% never semantic Complete bytes.  A different valid certificate
          %% shape for the same two exact applied claims must therefore
          %% reconstruct the identical Complete record.
          AlternateApplied =
              [replace_applied_signer(Row, digest(243), <<244:512>>)
               || Row <- Applied],
          ?assertEqual(
             {ok, {ordered, complete,
                   [{submit, Origin, Complete}]}},
             quod_dtx_recovery:next(
               Begin,
               snapshot(PhaseEvidence, Generations,
                        AlternateApplied, none))),

          %% Applied attestations bind the immutable Finalize claim, not one
          %% replica's interchangeable quorum-proof subset.  Recovery may
          %% therefore combine a verified attestation naming another valid
          %% subset with the certified Finalize entry already in its index.
          AlternateFinalizeRef =
              setelement(8, evidence_ref(FinalizeAEvidence),
                         <<"alternate-finalize-quorum">>),
          [AppliedA, AppliedB] = Applied,
          EquivalentAppliedA =
              setelement(
                2, AppliedA,
                setelement(7, element(2, AppliedA), AlternateFinalizeRef)),
          ?assertMatch(
             {ok, {ordered, complete, [{submit, Origin, _}]}},
             quod_dtx_recovery:next(
               Begin,
               snapshot(PhaseEvidence, Generations,
                        [EquivalentAppliedA, AppliedB], none))),
          DifferentFinalizeClaim =
              setelement(6, AlternateFinalizeRef, digest(249)),
          MisboundAppliedA =
              setelement(
                2, AppliedA,
                setelement(7, element(2, AppliedA), DifferentFinalizeClaim)),
          ?assertEqual(
             {error, invalid_applied_evidence},
             quod_dtx_recovery:next(
               Begin,
               snapshot(PhaseEvidence, Generations,
                        [MisboundAppliedA, AppliedB], none))),
          CompleteEvidence = evidence(Origin, Complete, 7, F),
          S6 = snapshot(
                 PhaseEvidence ++ [CompleteEvidence], Generations, [], none),
          ?assertEqual(
             {done, evidence_ref(CompleteEvidence)},
             quod_dtx_recovery:next(Begin, S6))
      end).

first_definite_refusal_builds_reasoned_abort_and_direct_tombstone_test() ->
    with_fixture(
      fun(F) ->
          Begin = maps:get('begin', F),
          Origin = maps:get(origin, F),
          [A, B] = maps:get(targets, F),
          GroupId = maps:get(group_id, F),
          BeginEvidence = evidence(Origin, Begin, 10, F),
          {ok, {independent, prepare, PrepareCommands}} =
              quod_dtx_recovery:next(
                Begin, snapshot([BeginEvidence], [], [], none)),
          [{submit, A, PrepareA}, {submit, B, PrepareB}] = PrepareCommands,
          PrepareAEvidence = evidence(A, PrepareA, 11, F),
          Unknown = <<"quod_target_only_prepare_reason_814fb7">>,
          ?assertException(error, badarg,
                           binary_to_existing_atom(Unknown, utf8)),
          Reasons =
              [{prepare_refused,
                {ontology, element(1, B), element(2, B)}},
               {{'$quod_symbol', Unknown}, {goal, {cannot_link, bob, tom}}}],
          ReasonsBlob = reasons_blob(Reasons),
          Refusal =
              {B, quod_dtx:record_digest(PrepareB), 7, ReasonsBlob},
          S1 = snapshot(
                 [BeginEvidence, PrepareAEvidence],
                 [{A, 3}, {B, 7}], [], Refusal),
          {ok, {ordered, decision,
                [{submit, Origin, AbortDecision}]}} =
              quod_dtx_recovery:next(Begin, S1),
          ?assertEqual(
             {ok,
             #{kind => decision, group_id => GroupId,
                begin_ref => evidence_ref(BeginEvidence), verdict => abort,
                prepare_rows => [{A, evidence_ref(PrepareAEvidence)}],
                reasons => Reasons}},
             quod_dtx:recovery_phase(AbortDecision)),
          {ok, DecisionReasons} =
              quod_dtx:decision_failure_reasons(AbortDecision),
          ?assertEqual(Reasons, DecisionReasons),
          ?assertEqual(
             {ok, ReasonsBlob},
             quod_wire_term:encode_failure_reasons(DecisionReasons)),
          ?assertException(error, badarg,
                           binary_to_existing_atom(Unknown, utf8)),

          DecisionEvidence = evidence(Origin, AbortDecision, 12, F),
          Phase1 = [BeginEvidence, PrepareAEvidence, DecisionEvidence],
          {ok, {independent, finalize,
                [{submit, A, FinalizeA}, {submit, B, FinalizeB}]}} =
              quod_dtx_recovery:next(
                Begin, snapshot(Phase1, [{A, 3}, {B, 7}], [], none)),
          ?assertMatch(
             {ok, #{kind := finalize, verdict := abort,
                    prepare_ref := _, generation := 3}},
             quod_dtx:recovery_phase(FinalizeA)),
          ?assertMatch(
             {ok, #{kind := finalize, verdict := abort,
                    prepare_ref := none, generation := 7}},
             quod_dtx:recovery_phase(FinalizeB)),

          FinalizeAEvidence = evidence(A, FinalizeA, 13, F),
          FinalizeBEvidence = evidence(B, FinalizeB, 14, F),
          Phase2 = Phase1 ++ [FinalizeAEvidence, FinalizeBEvidence],
          ?assertEqual(
             {ok, {independent, applied,
              [{applied, A, GroupId, evidence_ref(FinalizeAEvidence), 3,
                abort}]}},
             quod_dtx_recovery:next(
               Begin, snapshot(Phase2, [{A, 3}, {B, 7}], [], none))),
          Applied = [applied(A, GroupId, FinalizeAEvidence, 3, abort)],
          TerminalSnapshot =
              snapshot(Phase2, [{A, 3}, {B, 7}], Applied, none),
          ?assertEqual(
             {ok, #{verdict => abort, reasons => Reasons,
                    decision_slot => 12,
                    participant_slots => [{A, 13, 3}, {B, 14, 7}]}},
             quod_dtx_recovery:terminal(Begin, TerminalSnapshot)),
          ?assertMatch(
             {ok, {ordered, complete,
                   [{submit, Origin, _Complete}]}},
             quod_dtx_recovery:next(Begin, TerminalSnapshot))
      end).

%% Several origin replicas may drive the same durable group.  One can certify
%% a Prepare and commit the abort Decision while another learns that Decision
%% before it has locally re-read the Prepare.  The Decision's certified row is
%% durable; the second coordinator's observation order is not.  Recovery must
%% bind the row to the unique Prepare derived from Begin, then request the
%% missing target state needed for Finalize instead of rejecting the chain.
certified_decision_does_not_require_volatile_prepare_observation_test() ->
    with_fixture(
      fun(F) ->
          Begin = maps:get('begin', F),
          Origin = maps:get(origin, F),
          [A, B] = maps:get(targets, F),
          GroupId = maps:get(group_id, F),
          BeginEvidence = evidence(Origin, Begin, 20, F),
          BeginRef = evidence_ref(BeginEvidence),
          {ok, PrepareA} = quod_dtx:new_prepare(Begin, BeginRef, A),
          PrepareAEvidence = evidence(A, PrepareA, 21, F),
          Reasons =
              [{prepare_refused,
                {ontology, element(1, B), element(2, B)}},
               conflict_retry],
          {ok, Decision} =
              quod_dtx:new_decision(
                GroupId, BeginRef, {abort, Reasons},
                [{A, evidence_ref(PrepareAEvidence)}]),
          DecisionEvidence = evidence(Origin, Decision, 22, F),
          Sparse = snapshot(
                     [BeginEvidence, DecisionEvidence], [], [], none),
          ?assertEqual(
             {ok, {independent, prepare,
                   [{phase, A, GroupId, prepare}]}},
             quod_dtx_recovery:next(Begin, Sparse)),

          %% A digest alone cannot prove unseen Prepare content, so recovery
          %% first requests the exact referenced entry.  Once the genuine
          %% Prepare is present, a Decision naming another digest fails.
          BadPrepareRef =
              setelement(7, evidence_ref(PrepareAEvidence), digest(250)),
          {ok, MismatchedDecision} =
              quod_dtx:new_decision(
                GroupId, BeginRef, {abort, Reasons},
                [{A, BadPrepareRef}]),
          ?assertMatch(
             {ok, {independent, prepare, [_]}},
             quod_dtx_recovery:next(
               Begin,
               snapshot(
                 [BeginEvidence,
                  evidence(Origin, MismatchedDecision, 23, F)],
                 [], [], none))),
          ?assertEqual(
             {error, invalid_phase_chain},
             quod_dtx_recovery:next(
               Begin,
               snapshot(
                 [BeginEvidence, PrepareAEvidence,
                  evidence(Origin, MismatchedDecision, 23, F)],
                 [], [], none)))
      end).

equivalent_begin_finality_subsets_bind_one_prepare_chain_test() ->
    with_fixture(
      fun(F) ->
          Begin = maps:get('begin', F),
          Origin = maps:get(origin, F),
          [A, B] = Targets = maps:get(targets, F),
          GroupId = maps:get(group_id, F),
          BeginEvidence = evidence(Origin, Begin, 24, F),
          BeginRef = evidence_ref(BeginEvidence),
          EquivalentBeginRef = setelement(8, BeginRef, <<"other-quorum">>),
          ?assertNotEqual(BeginRef, EquivalentBeginRef),
          ?assertEqual(
             quod_dtx:certified_ref_claim(BeginRef),
             quod_dtx:certified_ref_claim(EquivalentBeginRef)),
          {ok, PrepareA} =
              quod_dtx:new_prepare(Begin, EquivalentBeginRef, A),
          {ok, PrepareB} = quod_dtx:new_prepare(Begin, BeginRef, B),
          ?assert(quod_dtx:prepare_matches_certified_begin(
                    PrepareA, Begin, BeginRef)),
          PrepareAEvidence = evidence(A, PrepareA, 25, F),
          PrepareBEvidence = evidence(B, PrepareB, 26, F),
          AlternatePrepareARef =
              setelement(8, evidence_ref(PrepareAEvidence),
                         <<"other-prepare-quorum">>),
          {ok, Decision} =
              quod_dtx:new_decision(
                GroupId, BeginRef, commit,
                [{A, AlternatePrepareARef},
                 {B, evidence_ref(PrepareBEvidence)}]),
          DecisionEvidence = evidence(Origin, Decision, 27, F),
          {ok, {independent, finalize, Commands}} =
              quod_dtx_recovery:next(
                Begin,
                snapshot(
                  [BeginEvidence, PrepareAEvidence, PrepareBEvidence,
                   DecisionEvidence],
                  [{A, 1}, {B, 1}], [], none)),
          ?assertEqual(Targets, command_targets(Commands)),

          %% Changing the certified block claim is not an equivalent quorum
          %% subset and remains a hard phase-chain failure.
          OtherBlockRef = setelement(6, EquivalentBeginRef, digest(251)),
          {ok, MisboundPrepare} = quod_dtx:new_prepare(Begin, OtherBlockRef, A),
          ?assertNot(quod_dtx:prepare_matches_certified_begin(
                       MisboundPrepare, Begin, BeginRef)),
          MisboundEvidence = evidence(A, MisboundPrepare, 28, F),
          {ok, MisboundDecision} =
              quod_dtx:new_decision(
                GroupId, BeginRef, commit,
                [{A, evidence_ref(MisboundEvidence)},
                 {B, evidence_ref(PrepareBEvidence)}]),
          ?assertEqual(
             {error, invalid_phase_chain},
             quod_dtx_recovery:next(
               Begin,
               snapshot(
                 [BeginEvidence, MisboundEvidence, PrepareBEvidence,
                  evidence(Origin, MisboundDecision, 29, F)],
                 [{A, 1}, {B, 1}], [], none)))
      end).

missing_generation_emits_phase_queries_and_statuses_bind_exactly_test() ->
    with_fixture(
      fun(F) ->
          Begin = maps:get('begin', F),
          Origin = maps:get(origin, F),
          [A, B] = maps:get(targets, F),
          GroupId = maps:get(group_id, F),
          BeginEvidence = evidence(Origin, Begin, 20, F),
          {ok, {independent, prepare, PrepareCommands}} =
              quod_dtx_recovery:next(
                Begin, snapshot([BeginEvidence], [], [], none)),
          [{submit, A, PrepareA}, {submit, B, PrepareB}] = PrepareCommands,
          PrepareAEvidence = evidence(A, PrepareA, 21, F),
          PrepareBEvidence = evidence(B, PrepareB, 22, F),
          Phase0 = [BeginEvidence, PrepareAEvidence, PrepareBEvidence],
          {ok, {ordered, decision, [{submit, Origin, Decision}]}} =
              quod_dtx_recovery:next(
                Begin, snapshot(Phase0, [], [], none)),
          DecisionEvidence = evidence(Origin, Decision, 23, F),
          Phase1 = Phase0 ++ [DecisionEvidence],
          ?assertEqual(
             {ok, {independent, finalize,
                   [{phase, A, GroupId, prepare},
                    {phase, B, GroupId, prepare}]}},
             quod_dtx_recovery:next(
               Begin, snapshot(Phase1, [], [], none))),
          {ok, {independent, finalize, FinalizeCommands}} =
              quod_dtx_recovery:next(
                Begin, snapshot(Phase1, [{A, 1}, {B, 1}], [], none)),
          [{submit, A, FinalizeA}, {submit, B, FinalizeB}] =
              FinalizeCommands,
          FinalizeAEvidence = evidence(A, FinalizeA, 24, F),
          FinalizeBEvidence = evidence(B, FinalizeB, 25, F),
          Phase2 = Phase1 ++ [FinalizeAEvidence, FinalizeBEvidence],
          BadApplied =
              [applied(A, GroupId, FinalizeAEvidence, 2, commit),
               applied(B, GroupId, FinalizeBEvidence, 3, commit)],
          ?assertEqual(
             {error, invalid_applied_evidence},
             quod_dtx_recovery:next(
               Begin, snapshot(
                        Phase2, [{A, 1}, {B, 1}], BadApplied, none)))
      end).

malformed_noncanonical_or_misbound_evidence_fails_closed_test() ->
    with_fixture(
      fun(F) ->
          Begin = maps:get('begin', F),
          Origin = maps:get(origin, F),
          [A, B] = maps:get(targets, F),
          BeginEvidence = evidence(Origin, Begin, 30, F),
          {ok, {independent, prepare,
                [{submit, A, PrepareA}, {submit, B, PrepareB}]}} =
              quod_dtx_recovery:next(
                Begin, snapshot([BeginEvidence], [], [], none)),
          PrepareAEvidence = evidence(A, PrepareA, 31, F),
          PrepareBEvidence = evidence(B, PrepareB, 32, F),
          ?assertEqual(
             {error, invalid_phase_evidence},
             quod_dtx_recovery:next(
               Begin,
               snapshot([BeginEvidence, PrepareBEvidence, PrepareAEvidence],
                        [], [], none))),
          {Target, Control, Ref} = PrepareAEvidence,
          BadRef = setelement(7, Ref, digest(250)),
          ?assertEqual(
             {error, invalid_phase_evidence},
             quod_dtx_recovery:next(
               Begin,
               snapshot([BeginEvidence, {Target, Control, BadRef}],
                        [], [], none))),
          ?assertEqual(
             {error, invalid_generations},
             quod_dtx_recovery:next(
               Begin,
               snapshot([BeginEvidence], [{B, 0}, {A, 0}], [], none))),
          ?assertEqual(
             {error, invalid_refusal},
             quod_dtx_recovery:next(
               Begin,
               snapshot([BeginEvidence], [], [],
                        {{<<"quod:other">>, digest(1)}, digest(2), 0,
                         reasons_blob([bad_target])}))),
          RefusalReasons =
              reasons_blob(
                [{prepare_refused,
                  {ontology, element(1, B), element(2, B)}},
                 conflict_retry]),
          Refusal =
              {B, quod_dtx:record_digest(PrepareB), 0, RefusalReasons},
          ?assertEqual(
             {error, invalid_refusal},
             quod_dtx_recovery:next(
               Begin,
               snapshot([BeginEvidence], [{B, 1}], [], Refusal))),
          ?assertEqual(
             {error, invalid_refusal},
             quod_dtx_recovery:next(
               Begin,
               snapshot([BeginEvidence], [{B, 0}], [],
                        setelement(2, Refusal, digest(251))))),
          ?assertEqual(
             {error, invalid_refusal},
             quod_dtx_recovery:next(
               Begin,
               snapshot([BeginEvidence, PrepareBEvidence], [{B, 0}], [],
                        Refusal))),
          EmptyReasons = reasons_blob([]),
          ?assertEqual(
             {error, invalid_refusal},
             quod_dtx_recovery:next(
               Begin,
               snapshot([BeginEvidence], [{B, 0}], [],
                        setelement(4, Refusal, EmptyReasons)))),
          MarkerOnly =
              reasons_blob(
                [{prepare_refused,
                  {ontology, element(1, B), element(2, B)}}]),
          ?assertEqual(
             {error, invalid_refusal},
             quod_dtx_recovery:next(
               Begin,
               snapshot([BeginEvidence], [{B, 0}], [],
                        setelement(4, Refusal, MarkerOnly)))),
          WrongMarker =
              reasons_blob(
                [{prepare_refused, {ontology, <<"quod:wrong">>, digest(99)}},
                 conflict_retry]),
          ?assertEqual(
             {error, invalid_refusal},
             quod_dtx_recovery:next(
               Begin,
               snapshot([BeginEvidence], [{B, 0}], [],
                        setelement(4, Refusal, WrongMarker))))
      end).

accessors_are_total_and_history_phase_is_representation_safe_test() ->
    with_fixture(
      fun(F) ->
          Begin = maps:get('begin', F),
          Origin = maps:get(origin, F),
          [A, B] = maps:get(targets, F),
          GroupId = maps:get(group_id, F),
          ?assertMatch(
             {ok, Origin, GroupId, [{A, _}, {B, _}]},
             quod_dtx:begin_recovery_rows(Begin)),
          ?assertEqual(error, quod_dtx:begin_recovery_rows(malformed)),
          BeginEvidence = evidence(Origin, Begin, 40, F),
          Ref = evidence_ref(BeginEvidence),
          ?assertMatch(
             {ok, Origin, 40, GroupId},
             quod_dtx:certified_ref_binding(Ref)),
          ?assertEqual(error, quod_dtx:certified_ref_binding(malformed)),
          ?assertEqual(error, quod_dtx:recovery_phase(Begin)),
          {_Target, BeginControl, Ref} = BeginEvidence,
          {ok, History, _Projection, _Effects} =
              quod_dtx:reduce(
                BeginControl, Ref, quod_dtx:initial_group_history(),
                quod_dtx:initial_projection(Origin, 0)),
          ?assertEqual(
             {ok, Ref}, quod_dtx:history_phase('begin', History)),
          ?assertEqual(
             not_found,
             quod_dtx:history_phase('begin', quod_dtx:initial_group_history())),
          ?assertEqual(not_found,
                       quod_dtx:history_phase(unknown, #{}))
      end).

material_source_reuses_begin_and_decision_without_source_commands_test() ->
    with_fused_fixture(
      fun(F) ->
          Begin = maps:get('begin', F),
          Origin = maps:get(origin, F),
          [Origin, Remote] = maps:get(targets, F),
          GroupId = maps:get(group_id, F),
          BeginEvidence = evidence(Origin, Begin, 60, F),
          BeginRef = evidence_ref(BeginEvidence),
          {ok, {independent, prepare, [{submit, Remote, Prepare}]}} =
              quod_dtx_recovery:next(
                Begin, snapshot([BeginEvidence], [], [], none)),
          PrepareEvidence = evidence(Remote, Prepare, 61, F),
          {_Remote, PrepareControl, PrepareRef} = PrepareEvidence,
          ?assertEqual(
             {error, invalid_phase_evidence},
             quod_dtx_recovery:next(
               Begin,
               snapshot(
                 [BeginEvidence, {Origin, PrepareControl, PrepareRef}],
                 [], [], none))),
          Generations = [{Origin, 1}, {Remote, 4}],
          {ok, {ordered, decision, [{submit, Origin, Decision}]}} =
              quod_dtx_recovery:next(
                Begin,
                snapshot([BeginEvidence, PrepareEvidence],
                         Generations, [], none)),
          ?assertMatch(
             {ok, #{prepare_rows :=
                        [{Origin, BeginRef}, {Remote, _}] }},
             quod_dtx:recovery_phase(Decision)),
          DecisionEvidence = evidence(Origin, Decision, 62, F),
          DecisionRef = evidence_ref(DecisionEvidence),
          Phase0 = [BeginEvidence, PrepareEvidence, DecisionEvidence],
          {ok, {independent, finalize,
                [{submit, Remote, Finalize}]}} =
              quod_dtx_recovery:next(
                Begin, snapshot(Phase0, Generations, [], none)),
          FinalizeEvidence = evidence(Remote, Finalize, 63, F),
          Phase1 = Phase0 ++ [FinalizeEvidence],
          {ok, {independent, applied,
                [{applied, Remote, GroupId, _, 5, commit}]}} =
              quod_dtx_recovery:next(
                Begin, snapshot(Phase1, Generations, [], none)),
          Applied = [applied(Remote, GroupId, FinalizeEvidence, 5, commit)],
          TerminalSnapshot = snapshot(Phase1, Generations, Applied, none),
          ?assertEqual(
             {ok, #{verdict => commit, reasons => none,
                    decision_slot => 62,
                    participant_slots =>
                        [{Origin, 62, 2}, {Remote, 63, 5}]}},
             quod_dtx_recovery:terminal(Begin, TerminalSnapshot)),
          {ok, {ordered, complete, [{submit, Origin, Complete}]}} =
              quod_dtx_recovery:next(
                Begin, TerminalSnapshot),
          {quod_dtx_complete, 3, GroupId, DecisionRef, FinalizeRows} = Complete,
          ?assertEqual(
             [{Origin, DecisionRef, 2},
              {Remote, evidence_ref(FinalizeEvidence), 5}],
             FinalizeRows)
      end).

%% Applied certificates are deliberately volatile validation evidence.  If
%% the coordinator dies after certifying Finalize but before Complete commits,
%% restart reconstructs only the durable phase chain.  The one recovery
%% planner must therefore request the same applied claim again, accept a new
%% certificate, and reconstruct byte-identical Complete semantics.  Once that
%% Complete is certified, replay needs no copy of either certificate.
lost_volatile_applied_certificate_is_recertified_before_complete_test() ->
    with_fused_fixture(
      fun(F) ->
          Begin = maps:get('begin', F),
          Origin = maps:get(origin, F),
          [Origin, Remote] = maps:get(targets, F),
          GroupId = maps:get(group_id, F),
          BeginEvidence = evidence(Origin, Begin, 70, F),
          {ok, {independent, prepare,
                [{submit, Remote, Prepare}]}} =
              quod_dtx_recovery:next(
                Begin, snapshot([BeginEvidence], [], [], none)),
          PrepareEvidence = evidence(Remote, Prepare, 71, F),
          Generations = [{Origin, 1}, {Remote, 4}],
          {ok, {ordered, decision,
                [{submit, Origin, Decision}]}} =
              quod_dtx_recovery:next(
                Begin,
                snapshot([BeginEvidence, PrepareEvidence],
                         Generations, [], none)),
          DecisionEvidence = evidence(Origin, Decision, 72, F),
          {ok, {independent, finalize,
                [{submit, Remote, Finalize}]}} =
              quod_dtx_recovery:next(
                Begin,
                snapshot([BeginEvidence, PrepareEvidence,
                          DecisionEvidence],
                         Generations, [], none)),
          FinalizeEvidence = evidence(Remote, Finalize, 73, F),
          DurableEvidence =
              [BeginEvidence, PrepareEvidence,
               DecisionEvidence, FinalizeEvidence],
          FinalizeRef = evidence_ref(FinalizeEvidence),
          AppliedCommand =
              {applied, Remote, GroupId, FinalizeRef, 5, commit},
          DurableOnly =
              snapshot(DurableEvidence, Generations, [], none),

          %% This is the exact post-crash state: Finalize is durable, but the
          %% certificate collected immediately before the crash is gone.
          ?assertEqual(
             {ok, {independent, applied, [AppliedCommand]}},
             quod_dtx_recovery:next(Begin, DurableOnly)),
          FirstApplied =
              applied(Remote, GroupId, FinalizeEvidence, 5, commit),
          {ok, {ordered, complete,
                [{submit, Origin, CompleteBeforeCrash}]}} =
              quod_dtx_recovery:next(
                Begin,
                snapshot(DurableEvidence, Generations,
                         [FirstApplied], none)),

          %% A replacement quorum can arrive in another order and contain
          %% different signatures.  It certifies the same applied statement
          %% and must reconstruct the same semantic Complete record.
          ReplacementApplied =
              replace_applied_signer(
                FirstApplied, digest(245), <<246:512>>),
          {ok, {ordered, complete,
                [{submit, Origin, CompleteAfterRestart}]}} =
              quod_dtx_recovery:next(
                Begin,
                snapshot(DurableEvidence, Generations,
                         [ReplacementApplied], none)),
          ?assertEqual(CompleteBeforeCrash, CompleteAfterRestart),

          %% Complete is durable; neither volatile certificate is.  A later
          %% coordinator/replay still recognizes the transaction as done.
          CompleteEvidence =
              evidence(Origin, CompleteAfterRestart, 74, F),
          ?assertEqual(
             {done, evidence_ref(CompleteEvidence)},
             quod_dtx_recovery:next(
               Begin,
               snapshot(DurableEvidence ++ [CompleteEvidence],
                        Generations, [], none)))
      end).

semantic_record_codec_is_canonical_bounded_and_total_test() ->
    with_fixture(
      fun(F) ->
          Begin = maps:get('begin', F),
          Origin = maps:get(origin, F),
          [A, B] = maps:get(targets, F),
          GroupId = maps:get(group_id, F),
          {ok, _Origin, _GroupId, [{A, _PlanA}, {B, _PlanB}]} =
              quod_dtx:begin_recovery_rows(Begin),
          BeginEvidence = evidence(Origin, Begin, 50, F),
          BeginRef = evidence_ref(BeginEvidence),
          {ok, PrepareA} = quod_dtx:new_prepare(Begin, BeginRef, A),
          {ok, PrepareB} = quod_dtx:new_prepare(Begin, BeginRef, B),
          PrepareAEvidence = evidence(A, PrepareA, 51, F),
          PrepareBEvidence = evidence(B, PrepareB, 52, F),
          {ok, Decision} =
              quod_dtx:new_decision(
                GroupId, BeginRef, commit,
                [{A, evidence_ref(PrepareAEvidence)},
                 {B, evidence_ref(PrepareBEvidence)}]),
          DecisionEvidence = evidence(Origin, Decision, 53, F),
          DecisionRef = evidence_ref(DecisionEvidence),
          {ok, FinalizeA} =
              quod_dtx:new_finalize(
                GroupId, DecisionRef, commit,
                evidence_ref(PrepareAEvidence), 1),
          {ok, FinalizeB} =
              quod_dtx:new_finalize(
                GroupId, DecisionRef, commit,
                evidence_ref(PrepareBEvidence), 1),
          FinalizeAEvidence = evidence(A, FinalizeA, 54, F),
          FinalizeBEvidence = evidence(B, FinalizeB, 55, F),
          {ok, Complete} =
              quod_dtx:new_complete(
                GroupId, DecisionRef,
                [{A, evidence_ref(FinalizeAEvidence), 1},
                 {B, evidence_ref(FinalizeBEvidence), 1}]),
          Records =
              [Begin, PrepareA, PrepareB, Decision,
               FinalizeA, FinalizeB, Complete],
          lists:foreach(
            fun(Record) ->
                {ok, Blob} = quod_dtx:encode_record(Record),
                ?assertEqual({ok, Record}, quod_dtx:decode_record(Blob)),
                ?assertEqual(Blob, term_to_binary(Record, [deterministic]))
            end, Records),
          {ok, BeginBlob} = quod_dtx:encode_record(Begin),
          NonCanonical = term_to_binary(Begin, [compressed]),
          ?assertNotEqual(BeginBlob, NonCanonical),
          ?assertEqual(
             {error, {protocol_error, bad_payload}},
             quod_dtx:decode_record(NonCanonical)),
          ?assertEqual(
             {error, {protocol_error, bad_payload}},
             quod_dtx:decode_record(<<BeginBlob/binary, 0>>)),
          ?assertEqual(
             {error, {protocol_error, bad_payload}},
             quod_dtx:encode_record(
               {quod_dtx_begin, 2, bad, none, none, []})),
          ?assertEqual(
             {error, {protocol_error, bad_payload}},
             quod_dtx:decode_record(not_binary)),
          ?assertEqual(
             {error, {too_large, dtx_body}},
             quod_dtx:decode_record(
               <<0:(?QUOD_MAX_DTX_BODY_BYTES + 1)/unit:8>>))
      end).

%% ------------------------------------------------------------------
%% Fixture and exact evidence helpers
%% ------------------------------------------------------------------

with_fixture(Fun) ->
    {Pub, Seed} = quod_identity:generate(),
    Signer = #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})},
    Fun(fixture(Signer)).

with_fused_fixture(Fun) ->
    {Pub, Seed} = quod_identity:generate(),
    Signer = #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})},
    Fun(fused_fixture(Signer)).

fixture(#{pubkey := Pub} = Signer) ->
    Origin = {<<"quod:origin">>, digest(1)},
    A = {<<"quod:a">>, digest(2)},
    B = {<<"quod:b">>, digest(3)},
    Targets = [A, B],
    ProofId = digest(3),
    {PlanA, PlanABlob} = plan(A, ProofId, Origin, Signer, a),
    {PlanB, PlanBBlob} = plan(B, ProofId, Origin, Signer, b),
    {ok, GoalBlob} = quod_durable_term:encode_goal({recover, group}),
    {ok, ResultBlob} = quod_durable_term:encode_result(#{}),
    Admission = digest(4),
    {ok, Manifest} =
        quod_dtx:new_manifest(
          #{proof_id => ProofId,
            coordinator =>
                {element(1, Origin), element(2, Origin), Pub, Admission},
            nonce => digest(5), principal => anonymous,
            goal => GoalBlob, result => ResultBlob,
            request_binding => none,
            participants =>
                [{A, quod_dtx:digest(PlanA)},
                 {B, quod_dtx:digest(PlanB)}]}),
    {ok, AttA} = quod_dtx:attest_plan(A, PlanA, Manifest, Signer),
    {ok, AttB} = quod_dtx:attest_plan(B, PlanB, Manifest, Signer),
    {ok, Begin} =
        quod_dtx:new_begin(
          Manifest, none,
          [{A, quod_dtx:digest(PlanA), PlanABlob, AttA},
           {B, quod_dtx:digest(PlanB), PlanBBlob, AttB}]),
    #{signer => Signer, admission => Admission,
      origin => Origin, targets => Targets,
      'begin' => Begin, group_id => quod_dtx:group_id(Begin)}.

fused_fixture(#{pubkey := Pub} = Signer) ->
    Origin = {<<"quod:a">>, digest(11)},
    Remote = {<<"quod:b">>, digest(12)},
    ProofId = digest(13),
    {PlanA, PlanABlob} = plan(Origin, ProofId, Origin, Signer, source),
    {PlanB, PlanBBlob} = plan(Remote, ProofId, Origin, Signer, remote),
    {ok, GoalBlob} = quod_durable_term:encode_goal({recover, fused}),
    {ok, ResultBlob} = quod_durable_term:encode_result(#{}),
    Admission = digest(14),
    {ok, Manifest} =
        quod_dtx:new_manifest(
          #{proof_id => ProofId,
            coordinator =>
                {element(1, Origin), element(2, Origin), Pub, Admission},
            nonce => digest(15), principal => anonymous,
            goal => GoalBlob, result => ResultBlob,
            request_binding => none,
            participants =>
                [{Origin, quod_dtx:digest(PlanA)},
                 {Remote, quod_dtx:digest(PlanB)}]}),
    {ok, AttA} = quod_dtx:attest_plan(Origin, PlanA, Manifest, Signer),
    {ok, AttB} = quod_dtx:attest_plan(Remote, PlanB, Manifest, Signer),
    {ok, Begin} = quod_dtx:new_begin(
                    Manifest, none,
                    [{Origin, quod_dtx:digest(PlanA), PlanABlob, AttA},
                     {Remote, quod_dtx:digest(PlanB), PlanBBlob, AttB}]),
    #{signer => Signer, admission => Admission,
      origin => Origin, targets => [Origin, Remote],
      'begin' => Begin, group_id => quod_dtx:group_id(Begin)}.

plan(Target = {Ns, _Anchor}, ProofId, Origin, Signer, Value) ->
    Session =
        quod_proof_session:start(
          quod_ct:committed_kb([]),
          #{read_set => true, proof_context => {origin, test},
            signer => Signer}),
    try
        InvocationId = crypto:strong_rand_bytes(16),
        Context = quod_predicates:proof_context(
                    Ns, 1, undefined, [Origin]),
        ok = quod_proof_session:open(
               Session, InvocationId, {assertz, {recovery_fact, Value}},
               allowed, Context, quod_transaction_scope:empty_selection()),
        {solution, _} = quod_proof_session:next(Session, InvocationId),
        {ok, Plan} =
            quod_dtx:seal_session(
              Session,
              #{target => Target, base_height => 1, proof_id => ProofId,
                origin => Origin, principal => anonymous,
                request_binding => none}),
        {ok, Blob} = quod_dtx:encode(Plan),
        {Plan, Blob}
    after
        quod_proof_session:stop(Session)
    end.

evidence(Target, Record, Slot,
         #{signer := Signer, admission := Admission}) ->
    {ok, Control} =
        quod_dtx:sign_control(
          Target, Record, Admission, Slot, Slot, Signer),
    {Ns, Anchor} = Target,
    {ok, Ref} =
        quod_dtx:certified_ref(
          Ns, Anchor, Slot, digest(100 + Slot),
          quod_dtx:record_digest(Control), <<"qc">>),
    {Target, Control, Ref}.

snapshot(Evidence, Generations, Applied, Refusal) ->
    #{evidence => Evidence, generations => Generations,
      applied => Applied, refusal => Refusal}.

applied(Target, GroupId, FinalizeEvidence, Generation, Verdict) ->
    FinalizeRef = evidence_ref(FinalizeEvidence),
    Certificate =
        {quod_dtx_applied_certificate, 1,
         digest(239), Target, digest(240), GroupId, FinalizeRef,
         Generation, Verdict, [{digest(241), <<242:512>>}]},
    %% Recovery consumes a certificate only after the coordinator's exact
    %% Finalize-era quorum verifier produced it.  This pure planner rechecks
    %% the complete semantic binding and bounded certificate shape; signature
    %% verification deliberately remains at that verifier boundary.
    ?assert(quod_dtx_current_view:valid_applied_certificate_shape(
              Certificate)),
    {Target, Certificate}.

replace_applied_signer(
  {Target,
   {quod_dtx_applied_certificate, 1, NetworkIdentity, Target, CommitteeId,
    GroupId, FinalizeRef, Generation, Verdict, _Signatures}},
  Signer, Signature) ->
    Certificate =
        {quod_dtx_applied_certificate, 1, NetworkIdentity, Target,
         CommitteeId, GroupId, FinalizeRef, Generation, Verdict,
         [{Signer, Signature}]},
    ?assert(quod_dtx_current_view:valid_applied_certificate_shape(
              Certificate)),
    {Target, Certificate}.

evidence_ref({_Target, _Control, Ref}) -> Ref.

command_targets(Commands) ->
    [Target || {submit, Target, _Record} <- Commands].

reasons_blob(Reasons) ->
    {ok, Blob} = quod_wire_term:encode_failure_reasons(Reasons),
    Blob.

digest(N) -> <<N:256>>.

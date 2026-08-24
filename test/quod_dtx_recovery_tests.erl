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
             {ok, [{submit, Origin, Begin}]},
             quod_dtx_recovery:next(Begin, quod_dtx_recovery:empty())),

          BeginEvidence = evidence(Origin, Begin, 1, F),
          S1 = snapshot([BeginEvidence], [], [], none),
          {ok, PrepareCommands} = quod_dtx_recovery:next(Begin, S1),
          ?assertEqual(Targets, command_targets(PrepareCommands)),
          [{submit, A, PrepareA}, {submit, B, PrepareB}] = PrepareCommands,

          PrepareAEvidence = evidence(A, PrepareA, 2, F),
          PrepareBEvidence = evidence(B, PrepareB, 3, F),
          Generations = [{A, 1}, {B, 4}],
          S2 = snapshot(
                 [BeginEvidence, PrepareAEvidence, PrepareBEvidence],
                 Generations, [], none),
          {ok, [{submit, Origin, Decision}]} =
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
          {ok, FinalizeCommands} = quod_dtx_recovery:next(Begin, S3),
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
             {ok,
              [{applied, A, GroupId, evidence_ref(FinalizeAEvidence), 2,
                commit},
               {applied, B, GroupId, evidence_ref(FinalizeBEvidence), 5,
                commit}]},
             quod_dtx_recovery:next(Begin, S4)),

          Applied =
              [applied(A, GroupId, FinalizeAEvidence, 2, commit),
               applied(B, GroupId, FinalizeBEvidence, 5, commit)],
          S5 = snapshot(PhaseEvidence, Generations, Applied, none),
          {ok, [{submit, Origin, Complete}]} =
              quod_dtx_recovery:next(Begin, S5),
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
          {ok, PrepareCommands} =
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
          {ok, [{submit, Origin, AbortDecision}]} =
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
          {ok, [{submit, A, FinalizeA}, {submit, B, FinalizeB}]} =
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
             {ok,
              [{applied, A, GroupId, evidence_ref(FinalizeAEvidence), 3,
                abort}]},
             quod_dtx_recovery:next(
               Begin, snapshot(Phase2, [{A, 3}, {B, 7}], [], none))),
          Applied = [applied(A, GroupId, FinalizeAEvidence, 3, abort)],
          ?assertMatch(
             {ok, [{submit, Origin, _Complete}]},
             quod_dtx_recovery:next(
               Begin, snapshot(
                        Phase2, [{A, 3}, {B, 7}], Applied, none)))
      end).

missing_generation_emits_phase_queries_and_statuses_bind_exactly_test() ->
    with_fixture(
      fun(F) ->
          Begin = maps:get('begin', F),
          Origin = maps:get(origin, F),
          [A, B] = maps:get(targets, F),
          GroupId = maps:get(group_id, F),
          BeginEvidence = evidence(Origin, Begin, 20, F),
          {ok, PrepareCommands} =
              quod_dtx_recovery:next(
                Begin, snapshot([BeginEvidence], [], [], none)),
          [{submit, A, PrepareA}, {submit, B, PrepareB}] = PrepareCommands,
          PrepareAEvidence = evidence(A, PrepareA, 21, F),
          PrepareBEvidence = evidence(B, PrepareB, 22, F),
          Phase0 = [BeginEvidence, PrepareAEvidence, PrepareBEvidence],
          {ok, [{submit, Origin, Decision}]} =
              quod_dtx_recovery:next(
                Begin, snapshot(Phase0, [], [], none)),
          DecisionEvidence = evidence(Origin, Decision, 23, F),
          Phase1 = Phase0 ++ [DecisionEvidence],
          ?assertEqual(
             {ok, [{phase, A, GroupId, prepare},
                   {phase, B, GroupId, prepare}]},
             quod_dtx_recovery:next(
               Begin, snapshot(Phase1, [], [], none))),
          {ok, FinalizeCommands} =
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
          {ok, [{submit, A, PrepareA}, {submit, B, PrepareB}]} =
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

fixture(#{pubkey := Pub} = Signer) ->
    Origin = {<<"quod:a">>, digest(1)},
    Other = {<<"quod:b">>, digest(2)},
    Targets = [Origin, Other],
    ProofId = digest(3),
    {PlanA, PlanABlob} = plan(Origin, ProofId, Origin, Signer, a),
    {PlanB, PlanBBlob} = plan(Other, ProofId, Origin, Signer, b),
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
                [{Origin, quod_dtx:digest(PlanA)},
                 {Other, quod_dtx:digest(PlanB)}]}),
    {ok, AttA} = quod_dtx:attest_plan(Origin, PlanA, Manifest, Signer),
    {ok, AttB} = quod_dtx:attest_plan(Other, PlanB, Manifest, Signer),
    {ok, Begin} =
        quod_dtx:new_begin(
          Manifest, none,
          [{Origin, quod_dtx:digest(PlanA), PlanABlob, AttA},
           {Other, quod_dtx:digest(PlanB), PlanBBlob, AttB}]),
    #{signer => Signer, admission => Admission,
      origin => Origin, targets => Targets,
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
    {Target, digest(240), GroupId, evidence_ref(FinalizeEvidence),
     Generation, Verdict}.

evidence_ref({_Target, _Control, Ref}) -> Ref.

command_targets(Commands) ->
    [Target || {submit, Target, _Record} <- Commands].

reasons_blob(Reasons) ->
    {ok, Blob} = quod_wire_term:encode_failure_reasons(Reasons),
    Blob.

digest(N) -> <<N:256>>.

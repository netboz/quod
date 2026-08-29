-module(quod_ct).
-moduledoc """
Shared test helpers (Common Test AND eunit), extracted from the per-module copies
(deferred cleanup #1).

These were byte-identical across suites/modules, so they live here once and are pulled in
via `-import(quod_ct, [...])` so call sites read unchanged (`eventually(F, T)`, `rp(Ns, G)`,
`diff_for(Fact)`, …). Helpers that genuinely vary — node boot (`start_peer`/`start_member`),
the self-signed dev cert (`make_cert`, whose CN differs), and the `?NS`-bound query helpers
(`status`/`role`/`prove`) — stay in their suites. `replica_SUITE` keeps its own
slightly-different `eventually`/`match_ok`/`datadir` variants.
""".
-include_lib("common_test/include/ct.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-include("quod_ledger.hrl").
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
-export([eventually/2, stop_all/1, match_ok/1, ordinary_write_ok/1,
         peer_prove/3,
         datadir/2, generate_key_gt/1]).
-export([rp/2, rp/3, diff_for/1, change/2, change/3, batch/1,
         dtx_decision_payload/0, dtx_prepare_blob/0, dtx_prepare_fixture/0,
         signed_goal_fixture/1, signed_dtx_begin_fixture/1,
         remote_operation_fixture/1,
         signed_effect_operation_submission/0,
         signed_effect_operation_submission/1,
         signed_agent_facts/1,
         with_network_identity/2,
         wait_until/1, wait_until/2]).
-export([commit_kb/1, commit_kb/3, set_ref/2, committed_kb/1, assert_facts/2]).
-export([proof_gate_row/3]).

%% Test-only constructor for the protected Simplex proof-gate row. Production
%% deliberately accepts only the current layout; fixtures must not become a
%% compatibility specification for retired ETS rows.
proof_gate_row(Ready, Generation, BlockingFences)
  when is_boolean(Ready), is_integer(Generation), Generation >= 0,
       is_list(BlockingFences) ->
    Self = <<250:256>>,
    {proof_gate, Ready, Generation, lists:sort(BlockingFences),
     Self, [Self], <<251:256>>, #{}}.

%% Smallest self-contained valid DTX fixture for consumers that only need to
%% distinguish a control barrier from content. Foreign-reference semantics are
%% not under test at those sites; the signed envelope and canonical codec are.
dtx_decision_payload() ->
    Target = {TargetNs, TargetAnchor} =
        {<<"quod:dtx-origin">>, <<2:256>>},
    {Pubkey, Seed} = quod_identity:generate(),
    Signer = #{pubkey => Pubkey,
               key => quod_identity:key_term({Pubkey, Seed})},
    GroupId = <<4:256>>,
    {ok, BeginRef} = quod_dtx:certified_ref(
                       TargetNs, TargetAnchor, 1,
                       <<3:256>>, GroupId, <<"qc">>),
    {ok, Record} = quod_dtx:new_decision(
                     GroupId, BeginRef,
                     {abort, [{test_abort, dtx_fixture}]}, []),
    {ok, Control} = quod_dtx:sign_control(
                      Target, Record, <<6:256>>, 1, 0, Signer),
    {ok, Blob} = quod_dtx:encode_control(Control),
    {batch, [{dtx, Blob}]}.

%% One real self-contained Prepare record for endpoint tests.  Building it
%% through the public plan/manifest/Begin APIs keeps refusal correlation pinned
%% to the protocol shape instead of a forged tuple fixture.
dtx_prepare_blob() ->
    maps:get(prepare_blob, dtx_prepare_fixture()).

dtx_prepare_fixture() ->
    {Pubkey, Seed} = quod_identity:generate(),
    Signer = #{pubkey => Pubkey,
               key => quod_identity:key_term({Pubkey, Seed})},
    Origin = {<<"quod:dtx-fixture-a">>, <<101:256>>},
    Target = {<<"quod:dtx-fixture-b">>, <<102:256>>},
    ProofId = <<103:256>>,
    {OriginPlan, OriginBlob} =
        dtx_fixture_plan(Origin, ProofId, Origin, Signer, origin),
    {TargetPlan, TargetBlob} =
        dtx_fixture_plan(Target, ProofId, Origin, Signer, target),
    {ok, GoalBlob} = quod_durable_term:encode_goal({fixture, prepare}),
    {ok, ResultBlob} = quod_durable_term:encode_result(#{}),
    Admission = <<104:256>>,
    {ok, Manifest} =
        quod_dtx:new_manifest(
          #{proof_id => ProofId,
            coordinator =>
                {element(1, Origin), element(2, Origin), Pubkey, Admission},
            nonce => <<105:256>>, principal => anonymous,
            goal => GoalBlob, result => ResultBlob,
            request_binding => none,
            participants =>
                [{Origin, quod_dtx:digest(OriginPlan)},
                 {Target, quod_dtx:digest(TargetPlan)}]}),
    {ok, OriginAttestation} =
        quod_dtx:attest_plan(Origin, OriginPlan, Manifest, Signer),
    {ok, TargetAttestation} =
        quod_dtx:attest_plan(Target, TargetPlan, Manifest, Signer),
    {ok, Begin} =
        quod_dtx:new_begin(
          Manifest, none,
          [{Origin, quod_dtx:digest(OriginPlan), OriginBlob,
            OriginAttestation},
           {Target, quod_dtx:digest(TargetPlan), TargetBlob,
            TargetAttestation}]),
    {ok, BeginRef} =
        quod_dtx:certified_ref(
          element(1, Origin), element(2, Origin), 1, <<106:256>>,
          quod_dtx:group_id(Begin), <<"qc">>),
    {ok, Prepare} = quod_dtx:new_prepare(Begin, BeginRef, Target),
    {ok, Blob} = quod_dtx:encode_record(Prepare),
    {ok, BeginControl} = quod_dtx:sign_control(
                           Origin, Begin, Admission, 1, 1, Signer),
    {ok, PrepareControl} = quod_dtx:sign_control(
                             Target, Prepare, Admission, 1, 1, Signer),
    #{origin => Origin, target => Target,
      signer => Signer, admission => Admission,
      'begin' => Begin, begin_ref => BeginRef, begin_control => BeginControl,
      prepare => Prepare, prepare_blob => Blob,
      prepare_control => PrepareControl}.

%% One browser-equivalent signed request for protocol consumers.  Keeping the
%% fixture here prevents transaction, DTX, outcome, and Explorer tests from
%% growing their own subtly different request encoders.
signed_goal_fixture(Overrides) when is_map(Overrides) ->
    Target = {TargetNs, TargetAnchor} =
        maps:get(target, Overrides, {<<"quod:signed-fixture">>, <<201:256>>}),
    Network = maps:get(network, Overrides, <<202:256>>),
    Mode = maps:get(mode, Overrides, execute),
    Deadline = maps:get(deadline, Overrides, 1_800_000_000_000),
    OperationId = maps:get(operation_id, Overrides, <<203:256>>),
    GoalText = maps:get(goal_text, Overrides, <<"assertz(saved(ok)).">>),
    AgentInstanceText = maps:get(
                          agent_instance_text, Overrides,
                          <<"human_user(test_agent).">>),
    {PublicKey, Seed} = maps:get(key_pair, Overrides, quod_identity:generate()),
    Identity = #{pubkey => PublicKey,
                 key => quod_identity:key_term({PublicKey, Seed})},
    Request =
        #{network_identity => Network,
          signing_public_key => PublicKey,
          operation_id => OperationId,
          agent_namespace => TargetNs,
          agent_genesis_anchor => TargetAnchor,
          agent_instance_text => AgentInstanceText,
          mode => Mode,
          parser_version => 1,
          not_after_ms => Deadline,
          goal_text => GoalText},
    {ok, RequestBytes} = quod_client_goal:encode(Request),
    Signature = quod_identity:sign(RequestBytes, maps:get(key, Identity)),
    {ok, Evidence} = quod_client_goal:verify(RequestBytes, Signature),
    {ok, AgentReference = {agent_instance_ref, _, _, AgentInstance}} =
        quod_agent_ref:materialize(maps:get(agent_ref_blob, Evidence)),
    #{target => Target, network => Network, mode => Mode,
      deadline => Deadline, operation_id => OperationId,
      signing_key => PublicKey,
      agent_ref => maps:get(agent_ref_blob, Evidence),
      agent_reference => AgentReference, agent_instance => AgentInstance,
      principal => {agent, maps:get(agent_ref_blob, Evidence)},
      key_pair => {PublicKey, Seed},
      identity => Identity, request => Request,
      request_bytes => RequestBytes, signature => Signature,
      request_digest => maps:get(request_digest, Evidence),
      goal_blob => maps:get(goal_blob, Evidence),
      operation_ref => maps:get(operation_ref, Evidence),
      evidence => Evidence, auth => quod_client_goal:request_auth(Evidence),
      binding => quod_client_goal:request_binding(Evidence)}.

%% The minimum identity fact that makes a signed fixture authoritative in its
%% exact containing ontology. ACL facts remain explicit in each test because
%% those tests intentionally exercise different policy.
signed_agent_facts(#{agent_instance := Instance,
                     signing_key := SigningKey}) ->
    [{agent_key, Instance, SigningKey, active}].

with_network_identity(<<_:256>> = Network, Fun) when is_function(Fun, 0) ->
    SavedDesired = application:get_env(quod, namespace_desired),
    Desired0 = application:get_env(quod, namespace_desired, #{}),
    Content0 = maps:get(content, Desired0, #{}),
    Root = quod_ontology:root_ns(),
    application:set_env(
      quod, namespace_desired,
      Desired0#{content => Content0#{Root => #{genesis_hash => Network}}}),
    try Fun()
    after
        case SavedDesired of
            {ok, Desired} ->
                application:set_env(quod, namespace_desired, Desired);
            undefined ->
                application:unset_env(quod, namespace_desired)
        end
    end.

%% A signed Begin built through the real proof/plan/manifest constructors.
%% Real multi-participant DTX tests reuse it; remote-operation tests derive the
%% one sealed target plan before the planner selects the ordinary claim path.
signed_dtx_begin_fixture(Overrides) when is_map(Overrides) ->
    Origin = maps:get(target, Overrides,
                      {<<"quod:signed-fixture">>, <<201:256>>}),
    Primary = maps:get(participant_target, Overrides, Origin),
    Secondary =
        case Primary =:= Origin of
            true -> fixture_secondary_target(Primary, Overrides);
            false -> Origin
        end,
    false = Primary =:= Secondary,
    Base = signed_plan_fixture(Overrides, [Primary, Secondary]),
    Begin = begin_from_signed_fixture(Base),
    {ok, Control} =
        quod_dtx:sign_control(
          maps:get(origin, Base), Begin, maps:get(admission, Base), 1,
          maps:get(submitted_at, Overrides, 1),
          maps:get(node_identity, Base)),
    maybe_add_fixture_transaction(
      Base#{'begin' => Begin, begin_control => Control}, Overrides).

signed_remote_plan_fixture(Overrides) when is_map(Overrides) ->
    Origin = maps:get(target, Overrides,
                      {<<"quod:remote-origin">>, <<211:256>>}),
    Target = maps:get(participant_target, Overrides,
                      {<<"quod:remote-target">>, <<212:256>>}),
    false = Target =:= Origin,
    signed_plan_fixture(
      Overrides#{target => Origin, participant_target => Target}, [Target]).

signed_plan_fixture(Overrides, ParticipantTargets0) ->
    Request = signed_goal_fixture(Overrides),
    Origin = {Ns, Anchor} = maps:get(target, Request),
    Target = maps:get(participant_target, Overrides, Origin),
    ParticipantTargets = lists:usort(ParticipantTargets0),
    true = lists:member(Target, ParticipantTargets),
    #{goal := FrozenGoal} = maps:get(evidence, Request),
    {ok, Goal} = quod_wire_term:materialize_symbols(FrozenGoal),
    NodeIdentity =
        case maps:get(node_identity, Overrides, undefined) of
            #{pubkey := <<_:256>>, key := _} = Identity -> Identity;
            undefined ->
                {NodeKey0, NodeSeed} = quod_identity:generate(),
                #{pubkey => NodeKey0,
                  key => quod_identity:key_term({NodeKey0, NodeSeed})}
        end,
    #{pubkey := NodeKey} = NodeIdentity,
    ProofId = maps:get(proof_id, Overrides, <<204:256>>),
    Admission = maps:get(admission, Overrides, <<205:256>>),
    PlanRows =
        [begin
             {Plan, PlanBlob} = signed_fixture_plan(
                                  Participant, Origin, Goal, ProofId,
                                  Request, NodeIdentity),
             {Participant, Plan, PlanBlob}
         end || Participant <- ParticipantTargets],
    {ok, ResultBlob} = quod_durable_term:encode_result(#{}),
    {ok, Manifest} =
        quod_dtx:new_manifest(
          #{proof_id => ProofId,
            coordinator => {Ns, Anchor, NodeKey, Admission},
            nonce => <<207:256>>,
            principal => maps:get(principal, Request),
            goal => maps:get(goal_blob, Request),
            result => ResultBlob,
            request_binding => maps:get(binding, Request),
            participants =>
                [{Participant, quod_dtx:digest(Plan)}
                 || {Participant, Plan, _PlanBlob} <- PlanRows]}),
    BundleRows =
        [begin
             {ok, Attestation} = quod_dtx:attest_plan(
                                   Participant, Plan, Manifest, NodeIdentity),
             {Participant, quod_dtx:digest(Plan), PlanBlob, Attestation}
         end || {Participant, Plan, PlanBlob} <- PlanRows],
    Plans = maps:from_list(
              [{Participant, Plan}
               || {Participant, Plan, _PlanBlob} <- PlanRows]),
    PlanBlobs = maps:from_list(
                  [{Participant, PlanBlob}
                   || {Participant, _Plan, PlanBlob} <- PlanRows]),
    Attestations = maps:from_list(
                     [{Participant, Attestation}
                      || {Participant, _Digest, _Blob, Attestation} <-
                             BundleRows]),
    Request#{node_identity => NodeIdentity, admission => Admission,
             origin => Origin, participant_target => Target,
             participant_targets => ParticipantTargets,
             proof_id => ProofId, result_blob => ResultBlob,
             plans => Plans, plan_blobs => PlanBlobs,
             attestations => Attestations, bundles => BundleRows,
             plan => maps:get(Target, Plans),
             plan_blob => maps:get(Target, PlanBlobs),
             attestation => maps:get(Target, Attestations),
             manifest => Manifest}.

signed_fixture_plan(Target, Origin, Goal, ProofId, Request, NodeIdentity) ->
    Session = quod_proof_session:start(
                committed_kb([]),
                #{read_set => true,
                  proof_context => {origin, signed_fixture},
                  signer => NodeIdentity}),
    try
        InvocationDigest = crypto:hash(
                             sha256,
                             term_to_binary(Target, [deterministic])),
        InvocationId = binary:part(InvocationDigest, 0, 16),
        %% The transcript records the selected target first. A foreign plan
        %% then carries the origin as its caller; the origin plan itself has
        %% only its ordinary top-level identity.
        Chain = case Target =:= Origin of
                    true -> [Origin];
                    false -> [Target, Origin]
                end,
        Context = quod_predicates:proof_context(
                    element(1, Target), 1, undefined, Chain),
        ok = quod_proof_session:open(
               Session, InvocationId, Goal, allowed, Context,
               quod_transaction_scope:empty_selection()),
        {solution, _} = quod_proof_session:next(Session, InvocationId),
        {ok, Plan} = quod_dtx:seal_session(
                       Session,
                       #{target => Target, base_height => 1,
                         proof_id => ProofId, origin => Origin,
                         principal => maps:get(principal, Request),
                         request_binding => maps:get(binding, Request)}),
        {ok, PlanBlob} = quod_dtx:encode(Plan),
        {Plan, PlanBlob}
    after
        quod_proof_session:stop(Session)
    end.

begin_from_signed_fixture(Fixture) ->
    {ok, Begin} = quod_dtx:new_begin(
                    maps:get(manifest, Fixture), maps:get(auth, Fixture),
                    maps:get(bundles, Fixture)),
    Begin.

maybe_add_fixture_transaction(
  Fixture = #{origin := {Ns, Anchor} = Origin,
              participant_target := Origin,
              plan := Plan, result_blob := ResultBlob,
              node_identity := #{pubkey := NodeKey} = NodeIdentity,
              admission := Admission}, Overrides) ->
    {ok, Material} = quod_dtx:material(Plan),
    UnsignedTransaction = quod_transaction:from_plan(
                            Plan, Material, maps:get(goal_blob, Fixture),
                            ResultBlob, maps:get(auth, Fixture)),
    SubmittedAt = maps:get(submitted_at, Overrides, 1),
    {ok, Transaction} = quod_transaction:sign(
                          {Ns, Anchor, Admission},
                          UnsignedTransaction#transaction{
                            author = NodeKey, author_seq = 1,
                            submitted_at = SubmittedAt},
                          NodeIdentity),
    Fixture#{transaction => Transaction};
maybe_add_fixture_transaction(Fixture, _Overrides) ->
    Fixture.

fixture_secondary_target(Primary, Overrides) ->
    case maps:find(second_participant_target, Overrides) of
        {ok, Secondary} ->
            Secondary;
        error ->
            Candidate = {<<"quod:signed-fixture-secondary">>, <<208:256>>},
            case Candidate =:= Primary of
                false -> Candidate;
                true -> {<<"quod:signed-fixture-secondary">>, <<209:256>>}
            end
    end.

%% One complete source-claim/target-application/source-receipt family.  The
%% certified references are structurally valid test evidence; tests of actual
%% certificate verification build committed entries through Simplex instead.
remote_operation_fixture(Overrides) when is_map(Overrides) ->
    Origin = maps:get(target, Overrides,
                      {<<"quod:remote-origin">>, <<211:256>>}),
    Target = maps:get(participant_target, Overrides,
                      {<<"quod:remote-target">>, <<212:256>>}),
    Fixture = signed_remote_plan_fixture(
                Overrides#{target => Origin, participant_target => Target}),
    Plan = maps:get(plan, Fixture),
    Bundle = {Target, quod_dtx:digest(Plan), maps:get(plan_blob, Fixture),
              maps:get(attestation, Fixture)},
    Claim = quod_transaction:remote_claim(
              Origin, maps:get(manifest, Fixture), Bundle,
              maps:get(auth, Fixture), maps:get(foreign_reads, Overrides, [])),
    {OriginNs, OriginAnchor} = Origin,
    ClaimRef = {transaction, OriginNs, OriginAnchor,
                Claim#transaction.tx_id},
    {ok, CertifiedClaimRef} = quod_dtx:certified_ref(
                                OriginNs, OriginAnchor, 2, <<213:256>>,
                                Claim#transaction.tx_id, <<"claim-qc">>),
    Application0 = quod_transaction:remote_application(ClaimRef, Claim),
    Application = quod_transaction:attach_evidence(
                    Application0, CertifiedClaimRef, Claim),
    {TargetNs, TargetAnchor} = Target,
    TargetRef = {transaction, TargetNs, TargetAnchor,
                 Application#transaction.tx_id},
    {ok, CertifiedTargetRef} = quod_dtx:certified_ref(
                                 TargetNs, TargetAnchor, 3, <<214:256>>,
                                 Application#transaction.tx_id, <<"target-qc">>),
    {ok, ClaimData} = quod_transaction:request_claim(Claim),
    Completion0 = quod_transaction:remote_complete(
                    Origin, maps:get(operation_ref, ClaimData),
                    maps:get(digest, ClaimData), TargetRef),
    Completion = quod_transaction:attach_evidence(
                   Completion0, CertifiedTargetRef, Application),
    Fixture#{origin => Origin, participant_target => Target,
             claim => Claim, claim_ref => ClaimRef,
             certified_claim_ref => CertifiedClaimRef,
             application => Application,
             target_ref => TargetRef,
             certified_target_ref => CertifiedTargetRef,
             completion => Completion}.

signed_effect_operation_submission() ->
    signed_effect_operation_submission(#{}).

signed_effect_operation_submission(Options) ->
    Request = signed_goal_fixture(
                #{target => {<<"quod:operation-source">>, <<221:256>>}}),
    Origin = {OriginNs, OriginAnchor} = maps:get(target, Request),
    Target = {<<"quod:operation-target">>, <<222:256>>},
    {SourceKey, SourceSeed} = quod_identity:generate(),
    SourceIdentity =
        #{pubkey => SourceKey,
          key => quod_identity:key_term({SourceKey, SourceSeed})},
    CoordinatorKey =
        case maps:get(coordinator, Options, source) of
            source -> SourceKey;
            mismatch -> element(1, quod_identity:generate())
        end,
    {TargetKey, TargetSeed} = quod_identity:generate(),
    TargetIdentity =
        #{pubkey => TargetKey,
          key => quod_identity:key_term({TargetKey, TargetSeed})},
    ProofId = <<223:256>>,
    Admission = <<224:256>>,
    {Effect, PreparedEffect} =
        case maps:get(prepared_effect, Options, false) of
            true ->
                CreatedNs = <<"quod:operation-created">>,
                Action = {create_ontology, CreatedNs, []},
                Desired = {ontology_hosted, CreatedNs},
                {ok, Structural} = quod_ontology:validate_action(Action),
                {ok, Prepared} = quod_ontology:prepare_action(Structural),
                {ok, PreparedDescriptor} = quod_ontology:prepared_effect(
                                             Action, Prepared, TargetKey,
                                             maps:get(principal, Request)),
                {PreparedDescriptor,
                 {Action, Desired, PreparedDescriptor, Prepared}};
            false ->
                {ok, Descriptor} = quod_effect:new(
                                     create, TargetKey,
                                     maps:get(principal, Request),
                                     {<<"quod:operation-created">>,
                                      <<225:256>>},
                                     <<226:256>>, <<227:256>>),
                {Descriptor, none}
        end,
    EffectTarget = quod_effect:target(Effect),
    {ok, EmptyWire} = quod_wire_term:encode_canonical([]),
    {ok, EffectWire} = quod_wire_term:encode_canonical([Effect]),
    Core = #{target => Target, base_height => 1, proof_id => ProofId,
             origin => Origin, principal => maps:get(principal, Request),
             request_binding => maps:get(binding, Request),
             overlay_generation => 0, diff_ops => 0, read_functors => 0,
             effects_count => 1,
             conflict_descriptor =>
                 #{reads => [], writes => [], custody => [EffectTarget]},
             diff => EmptyWire, read_check => EmptyWire,
             effects => EffectWire, live_bridges => EmptyWire,
             transcript => EmptyWire},
    PlanBytes = term_to_binary(
                  {<<"quod.dtx.plan">>, 8, Core}, [deterministic]),
    Plan = {quod_plan, Core, TargetKey,
            quod_identity:sign(PlanBytes, TargetIdentity)},
    true = quod_dtx:verify(Plan),
    {ok, Material} = quod_dtx:material(Plan),
    true = quod_effect:validate_plan(Plan, Material),
    PlanDigest = quod_dtx:digest(Plan),
    {ok, Manifest} = quod_dtx:new_manifest(
                       #{proof_id => ProofId,
                         coordinator =>
                             {OriginNs, OriginAnchor,
                              CoordinatorKey, Admission},
                         nonce => <<228:256>>,
                         principal => maps:get(principal, Request),
                         goal => maps:get(goal_blob, Request),
                         result => durable_empty_result(),
                         request_binding => maps:get(binding, Request),
                         participants => [{Target, PlanDigest}]}),
    {ok, Attestation} = quod_dtx:attest_plan(
                          Target, Plan, Manifest, TargetIdentity),
    {ok, PlanBlob} = quod_dtx:encode(Plan),
    Claim0 = quod_transaction:remote_claim(
               Origin, Manifest,
               {Target, PlanDigest, PlanBlob, Attestation},
               maps:get(auth, Request), []),
    {ok, Claim, Submission} = quod_transaction:sign_submission(
                                {OriginNs, OriginAnchor, Admission},
                                Claim0#transaction{author = SourceKey,
                                                   author_seq = 1,
                                                   submitted_at = 1},
                                SourceIdentity),
    #{submission => Submission, claim => Claim, effect => Effect,
      prepared_effect => PreparedEffect,
      manifest => Manifest, origin => Origin, target => Target,
      source_identity => SourceIdentity, admission => Admission,
      target_identity => TargetIdentity}.

durable_empty_result() ->
    {ok, Result} = quod_durable_term:encode_result(#{}),
    Result.

dtx_fixture_plan(Target = {Ns, _Anchor}, ProofId, Origin, Signer, Value) ->
    Session =
        quod_proof_session:start(
          committed_kb([]),
          #{read_set => true, proof_context => {origin, test},
            signer => Signer}),
    try
        InvocationId = crypto:strong_rand_bytes(16),
        Context = quod_predicates:proof_context(
                    Ns, 1, undefined, [Origin]),
        ok = quod_proof_session:open(
               Session, InvocationId, {assertz, {dtx_fixture, Value}},
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

%% Poll `F` every 150ms until it returns `true` or the budget runs out.
eventually(_F, Timeout) when Timeout =< 0 -> false;
eventually(F, Timeout) ->
    case (catch F()) of
        true ->
            true;
        {quod_retry_stop, Reason} ->
            erlang:error({unsafe_retry, Reason});
        _ ->
            timer:sleep(150),
            eventually(F, Timeout - 150)
    end.

%% Best-effort stop of a list of `peer` nodes (never throws).
stop_all(Peers) -> _ = [catch peer:stop(P) || P <- Peers], ok.

%% A `quod_prolog:prove/2` result with at least one binding.
%% A local deadline does not prove that a write failed. Tag it so even a nested
%% `lists:any/2` callback escapes `eventually/2` instead of resubmitting it.
match_ok({error, {outcome_unknown, OutcomeRef}}) ->
    throw({quod_retry_stop, {outcome_unknown, OutcomeRef}});
match_ok({badrpc, timeout}) ->
    throw({quod_retry_stop, {transport_timeout, peer_call}});
match_ok({ok, [_ | _], _}) -> true;
match_ok(_)                -> false.

%% Ordinary writes own their signed submission once accepted. A test may
%% resubmit only when the first attempt provably never entered custody.
%% In particular, skipped/retry/not_leader must fail the test: accepting any
%% of them here would hide a regression back to public slot-closure retries.
ordinary_write_ok({error, rebuilding}) ->
    false;
ordinary_write_ok({error, conflict_retry}) ->
    false;
ordinary_write_ok(Result) ->
    case match_ok(Result) of
        true ->
            true;
        false ->
            throw({quod_retry_stop, {ordinary_write_failed, Result}})
    end.

-ifdef(TEST).
eventually_stops_on_unknown_outcome_test() ->
    OutcomeRef = {transaction, <<"quod:test">>, <<1:256>>, <<2:256>>},
    try eventually(
          fun() -> match_ok({error, {outcome_unknown, OutcomeRef}}) end, 1000) of
        _ ->
            erlang:error(unknown_outcome_was_retried)
    catch
        error:{unsafe_retry, {outcome_unknown, OutcomeRef}} ->
            ok
    end.

eventually_stops_on_transport_timeout_test() ->
    try eventually(fun() -> match_ok({badrpc, timeout}) end, 1000) of
        _ ->
            erlang:error(transport_timeout_was_retried)
    catch
        error:{unsafe_retry, {transport_timeout, peer_call}} ->
            ok
    end.

ordinary_write_does_not_retry_slot_closure_test() ->
    try eventually(
          fun() -> ordinary_write_ok({error, skipped}) end, 1000) of
        _ ->
            erlang:error(slot_closure_was_retried)
    catch
        error:{unsafe_retry, {ordinary_write_failed, {error, skipped}}} ->
            ok
    end.
-endif.

%% peer:call/4 defaults to five seconds, shorter than quod_prolog's 30-second
%% parked-write deadline. Let the application report outcome_unknown itself;
%% otherwise a test poll can resubmit a write that is still able to commit.
peer_prove(Peer, Ns, Goal) ->
    peer:call(Peer, quod_prolog, prove, [Ns, Goal], 35000).

%% A per-port data_dir under the suite's private dir.
datadir(Config, Port) -> filename:join(?config(priv_dir, Config), "data_" ++ integer_to_list(Port)).

%% A fresh Ed25519 keypair whose pubkey sorts strictly after `Lo` (Erlang term order = the order
%% quod_simplex:leader/2 sorts by), so a suite can pin round-robin leadership deterministically.
generate_key_gt(Lo) ->
    {P, _} = Key = quod_identity:generate(),
    case P > Lo of true -> Key; false -> generate_key_gt(Lo) end.

%% prove, retrying only while the engine is still rebuilding (a transient state right after a
%% (re)start). `fail`/`{ok,_,_}`/other answers are returned as-is. Was copied per-module 4x.
rp(Ns, Goal) -> rp(Ns, Goal, 300).
rp(_Ns, _Goal, 0) -> {error, timeout};
rp(Ns, Goal, N) ->
    case quod_prolog:prove(Ns, Goal) of
        {error, rebuilding} -> timer:sleep(10), rp(Ns, Goal, N - 1);
        R -> R
    end.

%% a real content-diff asserting `Fact` (erlog term) — built via the overlay so the clause
%% body form matches what quod_prolog produces. No read set: only the write-set matters.
diff_for(Fact) ->
    {ok, C} = erlog_int:new(erlog_db_dict, null),
    W0 = quod_erlog_db_local_prove:wrap_state(C),
    {succeed, W1} = erlog_int:prove_goal({assertz, Fact}, W0),
    quod_erlog_db_local_prove:get_local_changes((W1#est.db)#db.ref).

%% publish a staged MVCC kb at `Version` with pruning floor `Floor` — the
%% committed state over which read-set overlays capture real version tokens.
commit_kb(Est) -> commit_kb(Est, 1, 1).

commit_kb(#est{db = #db{mod = quod_erlog_db_mvcc, ref = Ref} = Db} = Est,
          Version, Floor) ->
    Est#est{db = Db#db{ref = quod_erlog_db_mvcc:commit(Ref, Version, Floor)}}.

%% swap the db handle of an `#est{}` (e.g. after a direct mvcc mutation)
set_ref(#est{db = Db} = Est, Ref) -> Est#est{db = Db#db{ref = Ref}}.

%% a committed MVCC kb (unknown=fail) holding `Facts`, published at height 1
committed_kb(Facts) ->
    {ok, Erl} = erlog:new(quod_erlog_db_mvcc, null),
    State0 = element(3, Erl),
    {succeed, State1} =
        erlog_int:prove_goal({set_prolog_flag, unknown, fail}, State0),
    commit_kb(assert_facts(Facts, State1)).

%% assertz each erlog `Fact` into `Est`, failing loudly on the first refusal
assert_facts(Facts, Est) ->
    lists:foldl(
      fun(Fact, State) ->
              {succeed, Next} = erlog_int:prove_goal({assertz, Fact}, State),
              Next
      end, Est, Facts).

%% a well-shaped unsigned test transaction carrying `Diff` (+ optional OCC read_check)
change(Ns, Diff) -> change(Ns, Diff, #{}).
change(Ns, Diff, RC) ->
    PlanDigest = crypto:hash(
                   sha256,
                   term_to_binary(
                     {test_plan, erlang:unique_integer([positive]), Diff, RC},
                     [deterministic])),
    Anchor = case quod_simplex:genesis_hash(Ns) of
                 <<_:256>> = GenesisAnchor -> GenesisAnchor;
                 undefined -> <<0:256>>
             end,
    {ok, Goal} = quod_durable_term:encode_goal({test_change, Ns}),
    {ok, Result} = quod_durable_term:encode_result(#{}),
    quod_transaction:bind_id(
      {Ns, Anchor},
      #transaction{tx_id = <<>>, origin = {Ns, <<0:256>>},
                   proof_id = <<0:256>>, plan_digest = PlanDigest,
                   goal = Goal, result = Result,
                   diff = Diff, read_check = RC,
                   author = {"127.0.0.1", 5000}, sig = none}).

batch(Tx) -> {batch, [Tx]}.

%% Poll `F` (a boolean condition, side effects allowed) every 50 ms until true; error out
%% after `N` tries. The eunit sibling of `eventually/2`.
wait_until(F) -> wait_until(F, 100).
wait_until(_F, 0) -> erlang:error(condition_never_true);
wait_until(F, N) ->
    case F() of
        true -> ok;
        _    -> timer:sleep(50), wait_until(F, N - 1)
    end.

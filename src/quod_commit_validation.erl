-module(quod_commit_validation).
-moduledoc """
Deterministic validation for content and DTX records at one committed parent.

This module is deliberately process-free.  It owns no knowledge base, outcome
store, worker, timer, or authorization policy.  `quod_prolog` supplies one
frozen parent context, uses the returned outcome projection, and remains the
only owner of scheduling, ordered apply, replay, and publication.

Consensus checking and committed apply both enter through `content/4` and
`dtx/4`; the mode selects whether admission policy is being checked before a
vote or a certified record is being projected at its committed slot.  Apply
records the operation claim but does not rerun live `can_join` policy: the
commit certificate proves that the voting committee already did so.  Keeping
that stage distinction here prevents replay from depending on node-local
liveness observations while preserving the one existing authorization path
(`quod_ask:validate_authorization_transcript/6`).
""".

-include_lib("erlog/src/erlog_int.hrl").
-include("quod_ledger.hrl").

-export([new/5, outcomes/1, content/4, dtx/4, read_only_plan/2,
         prepared_material/4,
         remote_application/2, validate_foreign_reads/2]).
-export_type([context/0, mode/0]).

-record(context, {
          target   :: {binary() | undefined, <<_:256>>},
          applied  :: non_neg_integer(),
          est      :: tuple() | undefined,
          outcomes :: quod_outcome:index(),
          signer   :: quod_identity:signer() | none
         }).

-opaque context() :: #context{}.
-type mode() :: check | {claim, pos_integer()}.
-type result(Verdict) ::
        {ok, Verdict, context()} | {outcome_error, term()}.

-spec new({binary() | undefined, <<_:256>>}, non_neg_integer(),
          tuple() | undefined,
          quod_outcome:index(), quod_identity:signer() | none) -> context().
new({_Ns, <<_:256>>} = Target, Applied, Est, Outcomes, Signer)
  when is_integer(Applied), Applied >= 0,
       (is_tuple(Est) orelse Est =:= undefined) ->
    #context{target = Target, applied = Applied, est = Est,
             outcomes = Outcomes, signer = Signer}.

-spec outcomes(context()) -> quod_outcome:index().
outcomes(#context{outcomes = Outcomes}) -> Outcomes.

-doc "Verify carried read certificates against exact certified-entry evidence.".
-spec validate_foreign_reads(#transaction{}, map()) -> ok | {error, term()}.
validate_foreign_reads(#transaction{role = {remote_complete, _, _, _},
                                    foreign_reads = []}, _Evidence) ->
    ok;
validate_foreign_reads(#transaction{role = {remote_complete, _, _, _}},
                       _Evidence) ->
    {error, malformed_foreign_reads};
validate_foreign_reads(#transaction{foreign_reads = Certificates,
                                    proof_id = ProofId}, Evidence)
  when is_list(Certificates), is_map(Evidence) ->
    validate_foreign_reads(Certificates, ProofId, Evidence);
validate_foreign_reads(#transaction{}, _Evidence) ->
    {error, malformed_foreign_reads}.

validate_foreign_reads([], _ProofId, _Evidence) ->
    ok;
validate_foreign_reads([Certificate | Rest], ProofId, Evidence) ->
    case quod_read_certificate:binding(Certificate) of
        {ok, #{target := Target, proof_id := ProofId,
               anchor_ref := AnchorRef,
               committee_id := CommitteeId}} ->
            case maps:get(AnchorRef, Evidence, none) of
                #{identity := Target, committee := Committee,
                  committee_id := CommitteeId} ->
                    case quod_read_certificate:verify(
                           Certificate, Committee, CommitteeId) of
                        true -> validate_foreign_reads(Rest, ProofId, Evidence);
                        false -> {error, invalid_foreign_read_certificate}
                    end;
                _ -> {error, foreign_read_reference_binding}
            end;
        {ok, _OtherBinding} -> {error, foreign_read_proof_binding};
        error -> {error, malformed_foreign_reads}
    end.

-spec content(term(), term(), mode(), context()) -> result(term()).
content(Transactions, BlockTimestamp, Mode,
        Context = #context{target = Target})
  when is_list(Transactions), is_integer(BlockTimestamp),
       BlockTimestamp >= 0 ->
    case quod_ontology:network_identity(
           quod_transaction:requires_network_identity(Transactions),
           Target) of
        {ok, Network} ->
            validate_content_transactions(
              Transactions, Network, BlockTimestamp, Mode, #{}, Context);
        {error, Reason} ->
            dependency_verdict(Mode, Reason, Context)
    end;
content(_Transactions, _BlockTimestamp, _Mode, Context) ->
    {ok, {invalid, malformed_content}, Context}.

-spec dtx(term(), term(), mode(), context()) -> result(term()).
dtx(Control, BlockTimestamp, Mode,
    Context0 = #context{outcomes = Outcomes0}) ->
    case safe_dtx_group_id(Control) of
        {ok, GroupId} ->
            case quod_outcome:group_history(Outcomes0, GroupId) of
                {History, Outcomes1} when is_map(History) ->
                    Context1 = Context0#context{outcomes = Outcomes1},
                    case dtx_request_verdict(
                           Control, BlockTimestamp, Mode, Context1) of
                        {ok, valid, Context2} ->
                            {ok, dtx_policy_verdict(
                                   Control, History, Context2), Context2};
                        Other ->
                            Other
                    end;
                {error, Reason} ->
                    {outcome_error, Reason}
            end;
        error ->
            {ok, {invalid, malformed_control}, Context0}
    end.

prepared_plan(Manifest, PlanDigest, PlanBlob,
              Context) ->
    case prepared_application(Manifest, PlanDigest, PlanBlob, Context) of
        {ok, _EventContext, _Material} -> ok;
        {error, _} = Error -> Error
    end.

-doc "Validate one sealed read-only plan through the ordinary Prepare checks.".
-spec read_only_plan(quod_dtx:plan(), context()) -> ok | {error, term()}.
read_only_plan(Plan, Context = #context{target = Target}) ->
    case quod_dtx:verify(Plan) andalso quod_dtx:target(Plan) =:= Target andalso
         quod_dtx:diff_ops(Plan) =:= 0 andalso
         quod_dtx:effects_count(Plan) =:= 0 andalso
         maps:get(read_functors, quod_dtx:core(Plan), 0) > 0 of
        true ->
            case validate_prepared_plan_header(Plan, Context) of
                {ok, _Material} -> ok;
                {error, _} = Error -> Error
            end;
        false ->
            {error, invalid_read_plan}
    end.

-spec prepared_material(quod_dtx:manifest(), <<_:256>>, binary(), context()) ->
          {ok, map(), map()} | {error, term()}.
prepared_material(Manifest, PlanDigest, PlanBlob, Context) ->
    case decode_prepared_plan(Manifest, PlanDigest, PlanBlob, Context) of
        {ok, Plan, EventContext} ->
            case materialize_prepared_plan(Plan) of
                {ok, Material} -> {ok, EventContext, Material};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

dependency_verdict(check, _Reason, Context) ->
    {ok, abstain, Context};
dependency_verdict({claim, _Slot}, Reason, Context) ->
    {ok, {unavailable, network_identity, Reason}, Context}.

validate_content_transactions(
  [], _Network, _BlockTimestamp, _Mode, _Seen, Context) ->
    {ok, valid, Context};
validate_content_transactions(
  [#transaction{role = {remote_claim, _, Bundles, _}} | _],
  _Network, _BlockTimestamp, _Mode, _Seen, Context)
  when is_list(Bundles), length(Bundles) > 1 ->
    %% C1's temporary slice-7 availability boundary applies to admission too.
    %% A node author must not bypass the public proof route by submitting an
    %% N-target claim directly. Slice 8 replaces this guard only with its
    %% reviewed original-signed-goal intent authority and verdict evidence.
    {ok, {invalid, independent_lane_unavailable}, Context};
validate_content_transactions(
  [#transaction{role = {remote_application, _, _, _}} = Change | Rest],
  Network, BlockTimestamp, Mode, Seen, Context0) ->
    case remote_application(Change, Context0) of
        {apply, _EventContext, _Material} ->
            validate_content_transactions(
              Rest, Network, BlockTimestamp, Mode, Seen, Context0);
        {reject, _Reason} ->
            %% A valid durable claim must receive one durable B outcome even
            %% when current target policy or OCC refuses it.
            validate_content_transactions(
              Rest, Network, BlockTimestamp, Mode, Seen, Context0);
        {invalid, Reason} ->
            {ok, {invalid, Reason}, Context0};
        abstain when Mode =:= check ->
            {ok, abstain, Context0};
        abstain ->
            {ok, {unavailable, remote_application, future_parent}, Context0}
    end;
validate_content_transactions(
  [#transaction{role = {remote_complete, OperationRef,
                        RequestDigest, TargetRef}} | Rest],
  Network, BlockTimestamp, Mode, Seen,
  Context0 = #context{outcomes = Outcomes0}) ->
    Transition = case Mode of
                     check -> quod_outcome:check_completion(
                                Outcomes0, OperationRef,
                                RequestDigest, TargetRef);
                     {claim, Slot} -> quod_outcome:complete_operation(
                                       Outcomes0, Slot, OperationRef,
                                       RequestDigest, TargetRef)
                 end,
    case Transition of
        {TransitionKind, Outcomes1}
          when TransitionKind =:= new; TransitionKind =:= replay ->
            validate_content_transactions(
              Rest, Network, BlockTimestamp, Mode, Seen,
              Context0#context{outcomes = Outcomes1});
        {error, Reason} ->
            {outcome_error, Reason}
    end;
validate_content_transactions(
  [#transaction{} = Change | Rest], Network, BlockTimestamp,
  Mode, Seen, Context0 = #context{target = Target}) ->
    case quod_transaction:validate_request(
           Network, Target, BlockTimestamp, Change) of
        {ok, none} ->
            continue_content_validation(
              Change, Rest, Network, BlockTimestamp,
              Mode, Seen, Context0);
        {ok, RequestEvidence} ->
            Validator = case Change#transaction.role of
                            {remote_claim, _, _, _} ->
                                fun validate_signed_begin_request/5;
                            application ->
                                fun validate_signed_request/5
                        end,
            case Validator(
                   RequestEvidence, transaction_outcome_ref(Target, Change),
                   Mode, Seen, Context0) of
                {ok, Seen1, Context1} ->
                    continue_content_validation(
                      Change, Rest, Network, BlockTimestamp,
                      Mode, Seen1, Context1);
                {invalid, Reason, Context1} ->
                    {ok, {invalid, Reason}, Context1};
                {outcome_error, _} = Error ->
                    Error
            end;
        {error, _} ->
            {ok, {invalid, invalid_request_auth}, Context0}
    end;
validate_content_transactions(
  _Malformed, _Network, _BlockTimestamp, _Mode, _Seen, Context) ->
    {ok, {invalid, malformed_content}, Context}.

continue_content_validation(
  Change, Rest, Network, BlockTimestamp, Mode, Seen,
  Context = #context{applied = 0, target = {Ns, _Anchor}}) ->
    case Rest =:= [] andalso
         quod_simplex:valid_genesis_transaction(Ns, Change) of
        true ->
            validate_content_transactions(
              Rest, Network, BlockTimestamp, Mode, Seen, Context);
        false ->
            continue_ordinary_content_validation(
              Change, Rest, Network, BlockTimestamp, Mode, Seen, Context)
    end;
continue_content_validation(
  Change, Rest, Network, BlockTimestamp, Mode, Seen, Context) ->
    continue_ordinary_content_validation(
      Change, Rest, Network, BlockTimestamp, Mode, Seen, Context).

continue_ordinary_content_validation(
  Change, Rest, Network, BlockTimestamp, Mode, Seen, Context) ->
    case quod_diff:touches_functor(
           Change#transaction.diff, {external_predicate_modules, 1}) of
        true ->
            {ok, {invalid, immutable_external_predicate_manifest}, Context};
        false ->
            case is_membership_change(Change) of
                false ->
                    validate_content_transactions(
                      Rest, Network, BlockTimestamp, Mode, Seen, Context);
                true ->
                    case membership_verdict(Mode, Change, Context) of
                        valid ->
                            validate_content_transactions(
                              Rest, Network, BlockTimestamp,
                              Mode, Seen, Context);
                        {invalid, Reason} ->
                            {ok, {invalid, Reason}, Context}
                    end
            end
    end.

validate_signed_request(
  #{evidence := #{request := #{signing_public_key := SigningKey}},
    principal := Principal, transcript := Transcript, claim := Claim},
  OutcomeRef, Mode, Seen,
  Context0 = #context{target = Target, applied = Parent, est = Est}) ->
    case quod_ask:validate_agent_key(
           Target, Principal, SigningKey, Parent, Est) of
        ok ->
            case quod_ask:validate_authorization_transcript(
                   Target, Target, Principal, Parent, Transcript, Est) of
                ok ->
                    validate_operation_claim(
                      Claim, OutcomeRef, Mode, Seen, Context0);
                {error, _} ->
                    {invalid, invalid_authorization_transcript, Context0}
            end;
        {error, _} ->
            {invalid, invalid_agent_key, Context0}
    end.

validate_signed_begin_request(
  #{evidence := #{request := #{signing_public_key := SigningKey}},
    principal := Principal, claim := Claim},
  OutcomeRef, Mode, Seen,
  Context0 = #context{target = Target, applied = Parent, est = Est}) ->
    case quod_ask:validate_agent_key(
           Target, Principal, SigningKey, Parent, Est) of
        ok ->
            validate_operation_claim(
              Claim, OutcomeRef, Mode, Seen, Context0);
        {error, _} ->
            {invalid, invalid_agent_key, Context0}
    end.

validate_operation_claim(
  #{key := Key, digest := Digest} = Claim, OutcomeRef,
  Mode, Seen, Context0 = #context{outcomes = Outcomes0}) ->
    case maps:find(Key, Seen) of
        {ok, Digest} ->
            {invalid, duplicate_operation, Context0};
        {ok, _OtherDigest} ->
            {invalid, operation_conflict, Context0};
        error ->
            case operation_projection_transition(
                   Mode, Outcomes0, Claim, OutcomeRef) of
                {new, Outcomes1} ->
                    {ok, Seen#{Key => Digest},
                     Context0#context{outcomes = Outcomes1}};
                {{claimed, #{request_digest := Digest}}, Outcomes1} ->
                    {invalid, duplicate_operation,
                     Context0#context{outcomes = Outcomes1}};
                {{claimed, _Other}, Outcomes1} ->
                    {invalid, operation_conflict,
                     Context0#context{outcomes = Outcomes1}};
                {error, Reason} ->
                    {outcome_error, Reason}
            end
    end.

operation_projection_transition(check, Outcomes, Claim, OutcomeRef) ->
    quod_outcome:check_operation(Outcomes, Claim, OutcomeRef);
operation_projection_transition({claim, Slot}, Outcomes, Claim, OutcomeRef) ->
    case quod_outcome:claim_operation(Outcomes, Slot, Claim, OutcomeRef) of
        {new, Outcomes1} -> {new, Outcomes1};
        %% Replaying the exact same committed slot is an idempotent apply, so
        %% the owner follows its normal publication path without reporting a
        %% duplicate client operation.
        {replay, Outcomes1} -> {new, Outcomes1};
        {error, _} = Error -> Error
    end.

transaction_outcome_ref(
  {_Ns, _Anchor},
  #transaction{role = {remote_claim, _, _, _}} = Change) ->
    {ok, Refs} = quod_transaction:remote_claim_references(Change),
    {applications, Refs};
transaction_outcome_ref(
  {Ns, Anchor}, #transaction{tx_id = <<_:256>> = TxId}) ->
    {transaction, Ns, Anchor, TxId}.

-doc "Evaluate one certified remote application at the target parent.".
-spec remote_application(#transaction{}, context()) ->
          {apply, map(), map()} | {reject, term()} |
          {invalid, term()} | abstain.
remote_application(
  Change = #transaction{
             role = {remote_application, ClaimRef, _OperationRef, _Digest},
             evidence = {CertifiedRef,
                         #transaction{
                           role = {remote_claim, Manifest,
                                   Bundles, _Predicted}} = Claim}},
  Context = #context{target = Target}) ->
    Expected = try quod_transaction:remote_application(ClaimRef, Claim, Target)
               catch _:_ -> invalid
               end,
    case Expected of
        #transaction{tx_id = TxId}
          when TxId =:= Change#transaction.tx_id ->
            case quod_dtx:certified_ref_binding(CertifiedRef) of
                {ok, _ClaimIdentity, _Slot, ClaimTxId}
                  when ClaimTxId =:= Claim#transaction.tx_id ->
                    case quod_transaction:valid_id(
                           Context#context.target, Change) of
                        true ->
                            {Target, PlanDigest, PlanBlob, _Attestation} =
                                lists:keyfind(Target, 1, Bundles),
                            classify_remote_prepared(
                              prepared_application(
                                Manifest, PlanDigest, PlanBlob, Context));
                        false ->
                            {invalid, remote_application_target}
                    end;
                _ -> {invalid, foreign_claim_binding}
            end;
        _ ->
            {invalid, remote_application_binding}
    end;
remote_application(_Change, _Context) ->
    {invalid, malformed_remote_application}.

prepared_application(Manifest, PlanDigest, PlanBlob, Context) ->
    %% Authenticate and bind the opaque plan before materializing its
    %% target-owned symbols.  Return that exact material to the caller so the
    %% validation and application classification cannot decode it twice.
    case decode_prepared_plan(Manifest, PlanDigest, PlanBlob, Context) of
        {ok, Plan, EventContext} ->
            case validate_prepared_plan_header(Plan, Context) of
                {ok, Material} -> {ok, EventContext, Material};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

classify_remote_prepared(
  {ok, EventContext, Material}) ->
    {apply, EventContext, Material};
classify_remote_prepared({error, future_base_height}) ->
    abstain;
classify_remote_prepared({error, Reason}) ->
    case remote_rejection_reason(Reason) of
        {true, PublicReason} -> {reject, PublicReason};
        false -> {invalid, Reason}
    end.

remote_rejection_reason(signer_not_admitted) -> {true, signer_not_admitted};
remote_rejection_reason(conflict_retry) -> {true, conflict_retry};
remote_rejection_reason(policy_self_seal_forbidden) ->
    {true, policy_self_seal_forbidden};
remote_rejection_reason(invalid_membership) -> {true, invalid_membership};
remote_rejection_reason(invalid_authorization_transcript) ->
    {true, not_authorized};
remote_rejection_reason(_) -> false.

dtx_request_verdict(Control, BlockTimestamp, Mode, Context) ->
    case quod_dtx:control_kind(Control) of
        'begin' -> validate_dtx_begin_request(
                     Control, BlockTimestamp, Mode, Context);
        _ -> {ok, valid, Context}
    end.

validate_dtx_begin_request(Control, BlockTimestamp, Mode,
                           Context0 = #context{target = Target}) ->
    case quod_ontology:network_identity(
           quod_dtx:requires_network_identity(Control), Target) of
        {ok, Network} ->
            case quod_dtx:validate_request(
                   Network, Target, BlockTimestamp, Control) of
                {ok, none} ->
                    {ok, valid, Context0};
                {ok, RequestEvidence} ->
                    case quod_dtx:begin_group_ref(
                           quod_dtx:control_body(Control)) of
                        {ok, GroupRef} ->
                            case validate_signed_begin_request(
                                   RequestEvidence, GroupRef,
                                   Mode, #{}, Context0) of
                                {ok, _Seen, Context1} ->
                                    {ok, valid, Context1};
                                {invalid, Reason, Context1} ->
                                    {ok, {invalid, Reason}, Context1};
                                {outcome_error, _} = Error ->
                                    Error
                            end;
                        error ->
                            {ok, {invalid, malformed_control}, Context0}
                    end;
                {error, _} ->
                    {ok, {invalid, invalid_request_auth}, Context0}
            end;
        {error, Reason} ->
            dependency_verdict(Mode, Reason, Context0)
    end.

safe_dtx_group_id(Control) ->
    try quod_dtx:group_id(Control) of
        <<_:256>> = GroupId -> {ok, GroupId};
        _ -> error
    catch
        error:function_clause -> error;
        error:{badmatch, _} -> error
    end.

dtx_policy_verdict(Control, History, Context) ->
    case quod_dtx:control_kind(Control) of
        prepare ->
            case quod_dtx:prepare_payload(Control) of
                {ok, Manifest, PlanDigest, PlanBlob} ->
                    case prepared_plan(
                           Manifest, PlanDigest, PlanBlob, Context) of
                        ok -> {valid, History};
                        %% Preserve deterministic Prepare failures as a real
                        %% reason stack. Simplex adds the target marker before
                        %% the bounded wire encoding.
                        {error, Reason} -> {invalid, [Reason]}
                    end;
                error ->
                    {invalid, malformed_control}
            end;
        'begin' ->
            case quod_dtx:begin_participant_payload(
                   Control, Context#context.target) of
                not_found ->
                    {valid, History};
                {ok, Manifest, PlanDigest, PlanBlob} ->
                    case prepared_plan(
                           Manifest, PlanDigest, PlanBlob, Context) of
                        ok -> {valid, History};
                        {error, Reason} -> {invalid, [Reason]}
                    end;
                error ->
                    {invalid, malformed_control}
            end;
        decision -> {valid, History};
        finalize -> {valid, History};
        complete -> {valid, History}
    end.

decode_prepared_plan(
  Manifest, PlanDigest, PlanBlob, #context{target = Target}) ->
    case quod_dtx:decode(PlanBlob) of
        {ok, Plan} ->
            case quod_dtx:target(Plan) =:= Target of
                false ->
                    {error, bad_plan_binding};
                true ->
                    %% event_context/2 is the one successful-path signature,
                    %% digest, and manifest-binding owner.  The fallback
                    %% verify is reached only on rejection, solely to preserve
                    %% the existing bad-plan versus bad-manifest reason.
                    case quod_dtx:event_context(Manifest, Plan) of
                        {ok, #{plan_digest := PlanDigest} = EventContext} ->
                            {ok, Plan, EventContext};
                        {ok, _OtherDigest} ->
                            {error, bad_manifest_binding};
                        error ->
                            case quod_dtx:verify(Plan) of
                                true -> {error, bad_manifest_binding};
                                false -> {error, bad_plan_binding}
                            end
                    end
            end;
        {error, _} = Error ->
            Error
    end.

validate_prepared_plan_header(
  Plan, Context = #context{applied = Parent, est = Est}) ->
    case prepared_signer_admitted(quod_dtx:signer(Plan), Context) of
        false ->
            {error, signer_not_admitted};
        true ->
            case {quod_dtx:participates(Plan),
                  quod_dtx:base_height(Plan) =< Parent} of
                {false, _} -> {error, not_material};
                {_, false} -> {error, future_base_height};
                {true, true} ->
                    validate_prepared_plan_material(Plan, Est, Context)
            end
    end.

validate_prepared_plan_material(Plan, Est, Context) ->
    case materialize_prepared_plan(Plan) of
        {ok, #{diff := Diff, read_check := ReadCheck,
               transcript := Transcript} = Material} ->
            case validate_prepared_material(
                   Plan, Diff, ReadCheck, Transcript, Est, Context) of
                ok -> {ok, Material};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

materialize_prepared_plan(Plan) ->
    case quod_dtx:material(Plan) of
        {ok, Material} ->
            case quod_effect:validate_plan(Plan, Material) of
                true -> {ok, Material};
                false -> {error, invalid_direct_effect}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

validate_prepared_material(
  Plan, Diff, ReadCheck, Transcript, Est, Context) ->
    case quod_diff:valid_ops(Diff) andalso
         quod_diff:valid_read_check(ReadCheck) of
        false ->
            {error, malformed_plan_material};
        true ->
            case quod_diff:touches_functor(
                   Diff, {external_predicate_modules, 1}) of
                true -> {error, immutable_external_predicate_manifest};
                false ->
                    validate_prepared_occ(
                      Plan, Diff, ReadCheck, Transcript, Est, Context)
            end
    end.

validate_prepared_occ(
  Plan, Diff, ReadCheck, Transcript, Est, Context) ->
    case quod_diff:validate(ReadCheck, mvcc_ref(Est)) of
        {conflict, _Functor} ->
            {error, conflict_retry};
        ok ->
            case validate_prepared_membership(Diff, Context) of
                {error, _} = Error -> Error;
                ok ->
                    validate_prepared_candidate(
                      Plan, Diff, Transcript, Est, Context)
            end
    end.

validate_prepared_candidate(Plan, Diff, Transcript, Est, Context) ->
    case quod_diff:apply_ops_preserving_policy(Est, Diff) of
        {error, _} = Error ->
            Error;
        {ok, _DiscardedCandidate} ->
            validate_plan_transcript(Plan, Transcript, Context)
    end.

mvcc_ref(#est{db = #db{mod = quod_erlog_db_mvcc, ref = Ref}}) -> Ref.

prepared_signer_admitted(
  none, #context{signer = none, target = {_Ns, Anchor}}) ->
    Anchor =:= <<0:256>>;
prepared_signer_admitted(
  <<_:256>> = Signer, #context{est = Est}) ->
    lists:member(Signer, quod_committee_predicates:admitted_pubkeys(Est));
prepared_signer_admitted(_Signer, _Context) ->
    false.

validate_plan_transcript(
  Plan, Transcript,
  #context{applied = ParentHeight, est = ParentEst}) ->
    quod_ask:validate_authorization_transcript(
      quod_dtx:target(Plan), quod_dtx:origin(Plan),
      quod_dtx:principal(Plan), ParentHeight, Transcript, ParentEst).

validate_prepared_membership(Diff, #context{est = Est}) ->
    case diff_touches_membership(Diff) of
        false ->
            ok;
        true ->
            Validators = quod_committee_predicates:admitted_pubkeys(Est),
            case quod_simplex:membership_diff_acceptable(Diff, Validators)
                 andalso exact_membership_parent(Diff, Est) of
                true -> ok;
                false -> {error, invalid_membership}
            end
    end.

exact_membership_parent(
  [{assert, {{peer_admitted, _Id, _Host, _Port, Pubkey}, _Body}}], Est) ->
    not lists:member(
          Pubkey, quod_committee_predicates:admitted_pubkeys(Est));
exact_membership_parent(
  [{retract, {Head, Body}}],
  #est{db = #db{mod = Mod, ref = Ref}}) ->
    quod_diff:has_clause(Mod, Ref, Head, Body);
exact_membership_parent(_Diff, _Est) ->
    false.

diff_touches_membership(Diff) ->
    lists:any(
      fun({Kind, {{peer_admitted, _, _, _, _}, _Body}})
            when Kind =:= assert; Kind =:= retract -> true;
         (_) -> false
      end, Diff).

is_membership_change(Change) ->
    quod_simplex:committee_delta(Change) =/= {[], []}.

membership_verdict(check, #transaction{diff = Diff}, Context) ->
    membership_diff_verdict(Diff, Context);
membership_verdict({claim, _Slot}, #transaction{}, _Context) ->
    %% A certified membership record already passed the pure shape/cap gate
    %% and every supporter's parent-state can_join verdict. Replaying that
    %% live policy would make projection depend on this node's current feed
    %% observations, so committed apply only records the durable result.
    valid.

membership_diff_verdict(
  [{assert, {{peer_admitted, Pk, H, P, Pk}, _B}}],
  #context{target = {Ns, _Anchor}, applied = Applied, est = Est}) ->
    case lists:member(Pk, quod_committee_predicates:admitted_pubkeys(Est)) of
        true ->
            {invalid, already_admitted};
        false ->
            %% Re-prove the same can_join goal used by admit/3, against the
            %% frozen parent and the existing verdict execution context.
            VerdictEst = quod_predicates:set_context(
                           Est,
                           quod_predicates:verdict_context(Ns, Applied)),
            case quod_proof_session:run_first(
                   {can_join, Ns, [H, P], Pk}, VerdictEst,
                   #{read_set => true}) of
                {ok, _, [], _} -> valid;
                {ok, _, _Diff, _} -> {invalid, can_join_side_effects};
                {fail, _Reasons} -> {invalid, can_join};
                {error, _} -> {invalid, can_join}
            end
    end;
membership_diff_verdict(
  [{retract, {{peer_admitted, _Id, _H, _P, _Pk}, _B} = Clause}],
  #context{est = #est{db = #db{mod = M, ref = R}}}) ->
    {ClauseHead, ClauseBody} = Clause,
    case quod_diff:has_clause(M, R, ClauseHead, ClauseBody) of
        true -> valid;
        false -> {invalid, no_such_member}
    end;
membership_diff_verdict(_Diff, _Context) ->
    {invalid, invalid_membership}.

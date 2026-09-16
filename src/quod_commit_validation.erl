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
         prepared_material/1, vote_choice/3, prepare_vote/3,
         remote_application/2, validate_evidence/2]).
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

-doc "Verify carried certificates against the already-verified exact entries.".
-spec validate_evidence(#transaction{}, map()) -> ok | abstain | {error, term()}.
validate_evidence(#transaction{role = {remote_complete, _, _, Receipt},
                    evidence = {applications, Pairs}, foreign_reads = []}, Evidence) ->
    case quod_operation_vector:receipt_references(Receipt) of
        {ok, _} -> validate_receipt_evidence(Receipt, Pairs, Evidence);
        error -> {error, invalid_operation_receipt}
    end;
validate_evidence(#transaction{role = {remote_complete, _, _, _}},
                       _Evidence) ->
    {error, invalid_operation_receipt};
validate_evidence(#transaction{role = {remote_application, _, _, _},
                               evidence = {Ref, Referenced},
                               foreign_reads = Certificates, proof_id = ProofId}, Evidence) ->
    case matching_evidence(Ref, Referenced, Evidence) of
        {ok, _} -> validate_foreign_reads(Certificates, ProofId, Evidence);
        error -> {error, foreign_reference_binding}
    end;
validate_evidence(#transaction{foreign_reads = Certificates,
                              evidence = none, proof_id = ProofId}, Evidence)
  when is_list(Certificates), is_map(Evidence) ->
    validate_foreign_reads(Certificates, ProofId, Evidence);
validate_evidence(#transaction{}, _Evidence) ->
    {error, malformed_foreign_reads}.

validate_receipt_evidence([], [], _Evidence) -> ok;
validate_receipt_evidence([{Target, {certified, Ref, Certificate}} | Rest],
                          [{CertifiedRef, Transaction} | Pairs], Evidence) ->
    case {quod_transaction:stable_ref(CertifiedRef),
          matching_evidence(CertifiedRef, Transaction, Evidence)} of
        {Ref, {ok, #{identity := Target} = Exact}} ->
            case quod_ontology:network_identity() of
                {ok, Network} ->
                    case quod_applied_certificate:verify_operation_certificate(
                           Certificate, Network, Exact) of
                        true -> validate_receipt_evidence(Rest, Pairs, Evidence);
                        false -> {error, invalid_operation_result_certificate}
                    end;
                {error, _} -> abstain
            end;
        _ -> {error, operation_receipt_reference_binding}
    end;
validate_receipt_evidence(_, _, _) -> {error, invalid_operation_receipt}.

%% Both inputs have already crossed their signed decode boundary. Identical
%% values need no re-encoding or crypto. Independently decoded owner/foreign
%% representations may differ; only their complete canonical envelopes can
%% establish equality, never the semantic ID or an unchecked signed_bytes field.
matching_evidence(Ref, Transaction = #transaction{}, Evidence) ->
    case maps:get(Ref, Evidence, none) of
        #{transaction := Transaction} = Exact -> {ok, Exact};
        #{transaction := Other} = Exact ->
            case quod_transaction:same_ledger_transaction(Transaction, Other) of
                true -> {ok, Exact};
                false -> error
            end;
        _ -> error
    end;
matching_evidence(_, _, _) -> error.

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

-doc "Validate one authenticated atomic control against this exact committed parent.".
-spec dtx(term(), term(), mode(), context()) -> result(term()).
dtx(Control, BlockTimestamp, Mode, Context0 = #context{target = Target, outcomes = Outcomes0}) ->
    case safe_dtx_group_id(Control) of
        {ok, GroupId} ->
            case quod_atomic:control_target(Control) =:= Target andalso
                 quod_outcome:group_history(Outcomes0, GroupId) of
                {History, Outcomes1} when is_map(History) ->
                    Context = Context0#context{outcomes = Outcomes1},
                    case quod_atomic:control_kind(Control) of
                        vote -> validate_vote(Control, BlockTimestamp, Mode, History, Context);
                        _ -> {ok, {valid, History}, Context}
                    end;
                {error, Reason} -> {outcome_error, Reason};
                false -> {ok, {invalid, wrong_atomic_target}, Context0}
            end;
        error -> {ok, {invalid, malformed_control}, Context0}
    end.

-doc "Validate one sealed read-only plan through the shared own-plan checks.".
-spec read_only_plan(quod_dtx:plan(), context()) -> ok | {error, term()}.
read_only_plan(Plan, Context = #context{target = Target}) ->
    case quod_dtx:verify(Plan) andalso quod_dtx:target(Plan) =:= Target andalso
         quod_dtx:diff_ops(Plan) =:= 0 andalso
         quod_dtx:effects_count(Plan) =:= 0 andalso
         maps:get(read_functors, quod_dtx:core(Plan), 0) > 0 of
        true ->
            case validate_prepared_plan(Plan, Context) of
                {ok, _Material} -> ok;
                {error, _} = Error -> Error
            end;
        false ->
            {error, invalid_read_plan}
    end.

-doc "Materialize a reducer-owned positive vote without another plan decode or signature walk.".
-spec prepared_material(quod_atomic:admission_material()) ->
          {ok, map(), map()} | {error, term()}.
prepared_material({{quod_dtx_vote, 4, _, Target, _, prepared}, _,
                   #{plans := Plans, context := EventContext}}) ->
    case materialize_prepared_plan(maps:get(Target, Plans)) of
        {ok, Material} -> {ok, EventContext, Material};
        {error, _} = Error -> Error
    end.

dependency_verdict(check, _Reason, Context) ->
    {ok, abstain, Context};
dependency_verdict({claim, _Slot}, Reason, Context) ->
    {ok, {unavailable, network_identity, Reason}, Context}.

validate_content_transactions(
  [], _Network, _BlockTimestamp, _Mode, _Seen, Context) ->
    {ok, valid, Context};
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
    case content_request(Network, Target, BlockTimestamp, Change) of
        {ok, none} ->
            continue_content_validation(
              Change, Rest, Network, BlockTimestamp,
              Mode, Seen, Context0);
        {ok, RequestEvidence} ->
            Validator = case Change#transaction.role of
                            {remote_claim, _, _, _} ->
                                fun validate_signed_origin_request/5;
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
        {error, independent_scope_required} ->
            {ok, {invalid, independent_scope_required}, Context0};
        {error, _} ->
            {ok, {invalid, invalid_request_auth}, Context0}
    end;
validate_content_transactions(
  _Malformed, _Network, _BlockTimestamp, _Mode, _Seen, Context) ->
    {ok, {invalid, malformed_content}, Context}.

content_request(Network, Target, Timestamp, Change) ->
    case quod_transaction:validate_request(Network, Target, Timestamp, Change) of
        {ok, _} = Valid ->
            case Change#transaction.role of
                {remote_claim, _, _, _} ->
                    case quod_transaction:validate_independent_claim(Change) of
                        ok -> Valid;
                        {error, _} = Error -> Error
                    end;
                _ -> Valid
            end;
        {error, _} = Error -> Error
    end.

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

validate_signed_origin_request(
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
                           role = {remote_claim, _, _, _}} = Claim}},
  Context = #context{target = Target}) ->
    case quod_transaction:validate_independent_claim(Claim) of
        ok -> remote_application_checked(Change, CertifiedRef, ClaimRef, Claim,
                                         Target, Context);
        {error, Reason} -> {invalid, Reason}
    end;
remote_application(_Change, _Context) ->
    {invalid, malformed_remote_application}.

remote_application_checked(Change, CertifiedRef, ClaimRef, Claim,
                           Target, Context) ->
    Expected = try quod_transaction:remote_application_material(ClaimRef, Claim, Target)
               catch _:_ -> invalid
               end,
    case Expected of
        {#transaction{tx_id = TxId}, Plan, EventContext, Material}
          when TxId =:= Change#transaction.tx_id ->
            case quod_dtx:certified_ref_binding(CertifiedRef) of
                {ok, _ClaimIdentity, _Slot, ClaimTxId}
                  when ClaimTxId =:= Claim#transaction.tx_id ->
                    case quod_transaction:valid_id(
                           Context#context.target, Change) of
                        true ->
                            classify_remote_prepared(
                              prepared_application_material(
                                Plan, EventContext, Material, Context));
                        false ->
                            {invalid, remote_application_target}
                    end;
                _ -> {invalid, foreign_claim_binding}
            end;
        _ ->
            {invalid, remote_application_binding}
    end.

prepared_application_material(Plan, EventContext, Material, Context) ->
    case validate_prepared_plan_header(Plan, quod_dtx:participates(Plan), Context) of
        ok ->
            case quod_effect:validate_plan(Plan, Material) of
                true ->
                    case validate_prepared_plan_material(Plan, Material, Context) of
                        {ok, Material} -> {ok, EventContext, Material};
                        {error, _} = Error -> Error
                    end;
                false -> {error, invalid_direct_effect}
            end;
        {error, _} = Error -> Error
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

validate_vote(Control, Timestamp, Mode, History, Context) ->
    Material = quod_atomic:control_material(Control),
    case vote_request(Material, Timestamp, Mode, Context) of
        ok ->
            case quod_atomic:history_phase(vote, History) of
                {ok, Ref} ->
                    %% An exact committed vote keeps its first policy verdict.
                    {ok, _, _, Digest} = quod_dtx:certified_ref_binding(Ref),
                    case Digest =:= quod_atomic:record_digest(Control) of
                        true -> {ok, {valid, History}, Context};
                        false -> {ok, {invalid, atomic_vote_conflict}, Context}
                    end;
                not_found -> validate_vote_choice(Control, Timestamp, Mode, History, Context)
            end;
        Other -> Other
    end.

vote_request(Material, Timestamp, Mode, Context = #context{target = Target}) ->
    case quod_ontology:network_identity(quod_atomic:requires_network_identity(Material), Target) of
        {ok, Network} ->
            case quod_atomic:validate_request(Network, Target, Timestamp, Material) of
                {ok, _} -> ok;
                {error, Reason} -> {ok, {invalid, Reason}, Context}
            end;
        {error, Reason} ->
            ok = quod_selection_basis:note(parent, Context#context.est),
            dependency_verdict(Mode, Reason, Context)
    end.

validate_vote_choice(Control, Timestamp, Mode, History, Context0) ->
    Material = {{quod_dtx_vote, 4, _, _, _, Supplied}, _, _} =
        quod_atomic:control_material(Control),
    case vote_choice(Material, Timestamp, Context0) of
        {ok, wait, Context} -> {ok, abstain, Context};
        {ok, Expected, Context} ->
            Choice = case Supplied of
                prepared -> prepared;
                {refused, Blob} ->
                    {ok, Reasons} = quod_wire_term:decode_failure_reasons(Blob),
                    {refused, Reasons}
            end,
            case Choice =:= Expected of
                true -> claim_atomic_vote(Material, Choice, Mode, History, Context);
                false -> {ok, {invalid, {atomic_vote_choice, Expected}}, Context}
            end;
        {outcome_error, _} = Error -> Error
    end.

-doc "Choose and bind an own vote before signing, using the same parent policy as block verification.".
-spec prepare_vote(quod_atomic:admission_material(), non_neg_integer(), context()) ->
          result({selection, {vote, quod_atomic:admission_material()} | {invalid, term()} | abstain,
                  quod_selection_basis:basis()} | {invalid, invalid_vote_target}).
prepare_vote({{quod_dtx_vote, 4, _, Target, _, _}, _, _} = Material,
             Timestamp, Context = #context{target = Target, est = Est}) ->
    {Result, Basis} = quod_selection_basis:capture(Est, fun(Observed) ->
        prepare_observed_vote(Material, Timestamp, Context#context{est = Observed})
    end),
    case Result of
        {ok, Verdict, Next} -> {ok, {selection, Verdict, Basis}, Next#context{est = Est}};
        {outcome_error, _} = Error -> Error
    end;
prepare_vote(_, _, Context) -> {ok, {invalid, invalid_vote_target}, Context}.

prepare_observed_vote(Material, Timestamp, Context) ->
    case vote_choice(Material, Timestamp, Context) of
        {ok, wait, Next} -> {ok, abstain, Next};
        {ok, Choice, Next} ->
            case quod_atomic:select_vote(Material, Choice) of
                {ok, Selected} ->
                    case vote_request(Selected, Timestamp, check, Next) of
                        ok -> {ok, {vote, Selected}, Next};
                        Other -> Other
                    end;
                error -> {ok, {invalid, malformed_control}, Next}
            end;
        {outcome_error, _} = Error -> Error
    end.

-doc """
Choose the role's vote from authenticated own material and a committed parent.

Both local admission and consensus verification use this classification.
A refused vote must have a deterministic cause; network observations cannot
authorize it. Missing material and same-request reservation conflicts wait.
After the manifest deadline, refusal is possible without any own plan.
Only the source checks/claims the permanent request key. This read-only
classification stages no claim; dtx/4 does so only for a valid certified
positive source vote. The timestamp is the candidate/certified block time.
""".
-spec vote_choice(quod_atomic:admission_material(), non_neg_integer(), context()) ->
          result(prepared | {refused, nonempty_list()} | wait).
vote_choice({{quod_dtx_vote, 4, _, Target, _, _}, _,
              #{group := Binding, plans := Plans}} = Material,
             Timestamp, Context = #context{target = Target})
  when is_integer(Timestamp), Timestamp >= 0 ->
    case source_claim_status(Binding, Context) of
        {ok, clear, Context1} ->
            case Timestamp > maps:get(vote_deadline_ms, Binding) of
                true -> {ok, {refused, [vote_deadline]}, Context1};
                false ->
                    case source_key_status(Binding, Context1) of
                        ok ->
                            case maps:find(Target, Plans) of
                                error -> {ok, wait, Context1};
                                {ok, Plan} -> own_vote_choice(Plan, Binding, Material, Context1)
                            end;
                        {error, Reason} -> {ok, {refused, [Reason]}, Context1}
                    end
            end;
        Other -> Other
    end.

source_claim_status(#{origin := Target, request := #{claim := Claim}} = Binding,
                    Context = #context{target = Target, applied = Parent, outcomes = Outcomes, est = Est}) ->
    ok = quod_selection_basis:note({request, maps:get(key, Claim)}, Est),
    Ref = atomic_group_ref(Binding),
    #{digest := Digest} = Claim,
    case quod_outcome:check_operation(Outcomes, Claim, Ref) of
        {new, Next} -> {ok, clear, Context#context{outcomes = Next}};
        {{claimed, #{first_slot := Slot}}, Next} when Slot > Parent ->
            ok = quod_selection_basis:note(parent, Est),
            %% Reopen preserves permanent request claims while the KB and
            %% atomic projection replay from zero. A later positive claim
            %% cannot change an earlier certified negative vote's reason.
            {ok, clear, Context#context{outcomes = Next}};
        {{claimed, #{request_digest := Digest, outcome_ref := Ref}}, Next} ->
            {ok, clear, Context#context{outcomes = Next}};
        {{claimed, #{request_digest := Digest}}, Next} ->
            {ok, {refused, [duplicate_operation]}, Context#context{outcomes = Next}};
        {{claimed, _}, Next} ->
            {ok, {refused, [operation_conflict]}, Context#context{outcomes = Next}};
        {error, Reason} -> {outcome_error, Reason}
    end;
source_claim_status(_Binding, Context) -> {ok, clear, Context}.

source_key_status(#{origin := Target,
                    request := #{principal := Principal,
                      evidence := #{request := #{signing_public_key := SigningKey}}}},
                  #context{target = Target, applied = Parent, est = Est}) ->
    case quod_ask:validate_agent_key(Target, Principal, SigningKey, Parent, Est) of
        ok -> ok;
        {error, _} -> {error, invalid_agent_key}
    end;
source_key_status(_Binding, _Context) -> ok.

own_vote_choice(Plan, #{origin := Origin}, Material,
                 Context = #context{target = Target, outcomes = Outcomes, est = Est}) ->
    EligibleRole = Target =:= Origin orelse quod_dtx:participates(Plan),
    case validate_prepared_plan_header(Plan, EligibleRole, Context) of
        ok ->
            case materialize_prepared_plan(Plan) of
                {ok, Decoded} ->
                    case validate_prepared_plan_material(Plan, Decoded, Context) of
                        {ok, _} ->
                            ok = quod_selection_basis:note({reservations, Material}, Est),
                            Projection = maps:get(projection, quod_outcome:dtx_state(Outcomes)),
                            Choice = case quod_atomic:reservation_readiness(Material, Projection) of
                                ready -> prepared;
                                {blocked, active_group} -> wait;
                                {refused, Reason} -> {refused, [Reason]}
                            end,
                            {ok, Choice, Context};
                        {error, Reason} -> {ok, {refused, [Reason]}, Context}
                    end;
                {error, Reason} -> {ok, {refused, [Reason]}, Context}
            end;
        {error, future_base_height} ->
            ok = quod_selection_basis:note(parent, Est),
            {ok, wait, Context};
        {error, Reason} -> {ok, {refused, [Reason]}, Context}
    end.

claim_atomic_vote({_, _, #{group := #{origin := Target,
                              request := #{claim := Claim}} = Binding}},
                  prepared, {claim, Slot}, History,
                  Context = #context{target = Target, outcomes = Outcomes}) ->
    case quod_outcome:claim_operation(Outcomes, Slot, Claim, atomic_group_ref(Binding)) of
        {Kind, Next} when Kind =:= new; Kind =:= replay ->
            {ok, {valid, History}, Context#context{outcomes = Next}};
        {error, Reason} -> {outcome_error, Reason}
    end;
claim_atomic_vote(_Material, _Choice, _Mode, History, Context) ->
    {ok, {valid, History}, Context}.

atomic_group_ref(#{manifest := Manifest, group_id := Id}) ->
    {ok, Ref} = quod_dtx:manifest_group_ref(Manifest, Id), Ref.

safe_dtx_group_id(Control) ->
    try quod_atomic:group_id(Control) of
        <<_:256>> = GroupId -> {ok, GroupId}
    catch
        error:function_clause -> error;
        error:{badmatch, _} -> error
    end.

validate_prepared_plan_header(
  Plan, EligibleRole, Context = #context{applied = Parent}) ->
    case prepared_signer_admitted(quod_dtx:signer(Plan), Context) of
        false ->
            {error, signer_not_admitted};
        true ->
            case {EligibleRole, quod_dtx:base_height(Plan) =< Parent} of
                {false, _} -> {error, not_material};
                {_, false} -> {error, future_base_height};
                {true, true} -> ok
            end
    end.

validate_prepared_plan(Plan, Context) ->
    case validate_prepared_plan_header(Plan, quod_dtx:participates(Plan), Context) of
        ok ->
            case materialize_prepared_plan(Plan) of
                {ok, Material} -> validate_prepared_plan_material(Plan, Material, Context);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

validate_prepared_plan_material(Plan,
  #{diff := Diff, read_check := ReadCheck, transcript := Transcript} = Material,
  Context = #context{est = Est}) ->
    case validate_prepared_material(Plan, Diff, ReadCheck, Transcript, Est, Context) of
        ok -> {ok, Material};
        {error, _} = Error -> Error
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
    case quod_diff:touches_functor(Diff, {external_predicate_modules, 1}) of
        true -> {error, immutable_external_predicate_manifest};
        false -> validate_prepared_occ(Plan, Diff, ReadCheck, Transcript, Est, Context)
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

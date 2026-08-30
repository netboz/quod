-module(quod_transaction).
-moduledoc """
Canonical transaction identity and author signatures.

The signature format is a protocol contract with one fixed domain/schema tag,
bound to the target's `{Ns, GenesisAnchor, AuthorAdmission}` supplied by the
validating committee from its own state — never by the author. The anchor
is the slot-1 block hash and cryptographically covers the per-founding random
`consensus_incarnation` fact committed inside that block, so a transaction
signed under any earlier founding of the same namespace is unverifiable after
a re-found: exact mutation-version read tokens (unlike the old content hashes)
could validate by coincidence across a wipe, and this binding is what closes
that. Every committed field except `sig` is covered; no alternate tag is
accepted.
""".

-include("quod_ledger.hrl").
-include("quod_proof_limits.hrl").

-export([from_plan/5, remote_claim/5, remote_application/2,
         remote_complete/4, attach_evidence/3,
         encode_foreign_reads/1, decode_foreign_reads/1,
         encode_evidence/2, decode_evidence/1,
         stable_ref/1,
         role/1, evidence/1, required_references/1,
         bind_id/2, valid_id/2,
         plan_outcome_ref/4, encode_durable_submission/2,
         bytes/2, sign/3, sign_submission/3, verify/2,
         submission/2, submission_id/1, verify_submission/1,
         relay_attempt_id/5, decode_verified_submission/2,
         decode_submission_metadata/1,
         encode_operation_submission/1, decode_operation_submission/1,
         validate_request/4, request_claim/1, remote_claim_route/1,
         requires_network_identity/1]).

-export_type([target_binding/0]).

-define(DOMAIN, quod_transaction).
-define(ID_DOMAIN, quod_semantic_transaction).
-define(ID_VERSION, 7).
%% V12 binds an author's continuous admission generation, transaction role,
%% role evidence, certified foreign reads, signed-agent request, authorization
%% transcript, and the
%% atom-bearing diff/read set through the bounded Prolog wire alphabet,
%% including explicit event occurrences. The fixed envelope can therefore be
%% decoded safely before a small, explicit vocabulary allocation is permitted
%% for an authenticated committee author.
%% Unrelated committee changes do not invalidate retained custody, while
%% remove/re-admit makes every signature from the earlier admission
%% unverifiable. DTX controls use their own admission-scoped sequence lane, and
%% each committed control's certified reference binds the exact committee that
%% finalized its ledger position.
-define(VERSION, 12).
-define(RELAY_ATTEMPT_DOMAIN, quod_relay_attempt).
-define(RELAY_ATTEMPT_VERSION, 1).
-define(PUBKEY_BYTES, 32).
-define(SIGNATURE_BYTES, 64).
-define(SUBMISSION_ID_BYTES, 16).
-define(COMMITTEE_ID_BYTES, 32).
-define(MAX_SLOT, 16#FFFFFFFFFFFFFFFF).
-define(OPERATION_CANCEL_DOMAIN, <<"quod.operation.cancel.v1">>).

-type target_binding() :: {binary(), binary(), binary()}.

-doc """
Build the unsigned semantic transaction carried by one sealed plan.

`Material` is the canonical result returned by `quod_dtx:material/1`, optionally
augmented with the already-certified `foreign_reads` list. This keeps the
origin's opaque-byte id and validators' decoded-term id identical while the
replaceable certificates remain outside that semantic id.
""".
-spec from_plan(quod_dtx:plan(), map(), binary(), binary(),
                none | quod_client_goal:request_auth()) -> #transaction{}.
from_plan(Plan, #{diff := Diff, read_check := ReadCheck,
                  effects := Effects} = Material,
          GoalBlob, ResultBlob, RequestAuth)
  when is_list(Diff), is_map(ReadCheck),
       is_binary(GoalBlob), is_binary(ResultBlob) ->
    Target = quod_dtx:target(Plan),
    {StoredAuth, AuthTranscript} =
        request_fields(Plan, Material, GoalBlob, RequestAuth),
    ForeignReads = foreign_reads_from_material(Material),
    Transaction =
        #transaction{tx_id = <<>>,
                     role = application,
                     evidence = none,
                     foreign_reads = ForeignReads,
                     origin = quod_dtx:origin(Plan),
                     proof_id = quod_dtx:proof_id(Plan),
                     plan_digest = quod_dtx:digest(Plan),
                     goal = GoalBlob,
                     result = ResultBlob,
                     diff = Diff,
                     read_check = ReadCheck,
                     effects = Effects,
                     request_auth = StoredAuth,
                     auth_transcript = AuthTranscript,
                     author = none,
                     sig = none},
    Transaction#transaction{
      tx_id = semantic_plan_id(
                Target, Plan, GoalBlob, ResultBlob,
                StoredAuth, AuthTranscript, application)}.

-doc "Build the source operation claim for one signed foreign sealed plan.".
-spec remote_claim({binary(), <<_:256>>}, quod_dtx:manifest(), tuple(),
                   quod_client_goal:request_auth(), [term()]) ->
          #transaction{}.
remote_claim({OriginNs, <<_:256>> = OriginAnchor} = Origin, Manifest,
             {Target, PlanDigest, PlanBlob, Attestation} = Bundle,
             {agent_goal_v1, <<_:256>>, _Bytes, _Signature} = RequestAuth,
             ForeignReads0)
  when is_binary(OriginNs), is_binary(PlanBlob) ->
    ForeignReads = canonical_foreign_reads_or_error(ForeignReads0),
    {ok, Plan} = quod_dtx:decode(PlanBlob),
    Origin = quod_dtx:origin(Plan),
    false = quod_dtx:target(Plan) =:= Origin,
    Target = quod_dtx:target(Plan),
    PlanDigest = quod_dtx:digest(Plan),
    true = quod_dtx:verify_plan_attestation(
             Target, Plan, Manifest, Attestation),
    {ok, #{goal := GoalBlob, result := ResultBlob}} =
        quod_dtx:event_context(Manifest, Plan),
    Claim0 =
        #transaction{tx_id = <<>>,
                     role = {remote_claim, Manifest, Bundle, <<0:256>>},
                     evidence = none,
                     foreign_reads = ForeignReads,
                     origin = Origin,
                     proof_id = quod_dtx:proof_id(Plan),
                     plan_digest = quod_dtx:digest(Plan),
                     goal = GoalBlob,
                     result = ResultBlob,
                     diff = [], read_check = #{}, effects = [],
                     request_auth = RequestAuth,
                     auth_transcript = none,
                     author = none, sig = none},
    ClaimId = semantic_id_or_error(Origin, Claim0),
    ClaimRef = {transaction, OriginNs, OriginAnchor, ClaimId},
    Application0 = remote_application(ClaimRef, Claim0),
    {TargetNs, TargetAnchor} = Target,
    TargetRef = {transaction, TargetNs, TargetAnchor,
                 Application0#transaction.tx_id},
    Claim0#transaction{
      tx_id = ClaimId,
      role = {remote_claim, Manifest, Bundle, element(4, TargetRef)}}.

-doc "Build the ordinary target application bound to one durable source claim.".
-spec remote_application(term(), #transaction{}) -> #transaction{}.
remote_application(
  {transaction, OriginNs, <<_:256>> = OriginAnchor, <<_:256>>} = ClaimRef,
  #transaction{origin = {OriginNs, OriginAnchor} = Origin,
               role = {remote_claim, Manifest,
                       {Target, PlanDigest, PlanBlob, Attestation}, _Predicted},
               foreign_reads = ForeignReads,
               request_auth = RequestAuth, goal = GoalBlob,
               result = ResultBlob})
  when is_binary(OriginNs), is_binary(PlanBlob),
       is_binary(GoalBlob), is_binary(ResultBlob) ->
    {ok, Plan} = quod_dtx:decode(PlanBlob),
    Target = quod_dtx:target(Plan),
    Origin = quod_dtx:origin(Plan),
    PlanDigest = quod_dtx:digest(Plan),
    true = quod_dtx:verify_plan_attestation(
             Target, Plan, Manifest, Attestation),
    {ok, Material} = quod_dtx:material(Plan),
    {agent_goal_v1, RequestDigest} =
        quod_client_goal:request_binding(RequestAuth),
    {ok, #{claim := #{operation_ref := OperationRef}}} =
        quod_client_goal:verify_durable_request(RequestAuth, GoalBlob),
    Application0 =
        #transaction{tx_id = <<>>,
                     role = {remote_application, ClaimRef,
                             OperationRef, RequestDigest},
                     evidence = none,
                     foreign_reads = ForeignReads,
                     origin = Origin,
                     proof_id = quod_dtx:proof_id(Plan),
                     plan_digest = quod_dtx:digest(Plan),
                     goal = GoalBlob, result = ResultBlob,
                     diff = maps:get(diff, Material),
                     read_check = maps:get(read_check, Material),
                     effects = maps:get(effects, Material),
                     request_auth = none, auth_transcript = none,
                     author = none, sig = none},
    Application0#transaction{tx_id = semantic_id_or_error(Target, Application0)};
remote_application(_ClaimRef, _Claim) ->
    error(bad_remote_claim).

-doc "Build the source receipt for one certified target transaction.".
-spec remote_complete({binary(), <<_:256>>}, term(), binary(), term()) ->
          #transaction{}.
remote_complete({Ns, <<_:256>> = Anchor} = Origin, OperationRef,
                <<_:256>> = RequestDigest,
                {transaction, _TargetNs, <<_:256>>, <<_:256>>} = TargetRef)
  when is_binary(Ns) ->
    {ok, GoalBlob} = quod_durable_term:encode_goal(true),
    {ok, ResultBlob} = quod_durable_term:encode_result(#{}),
    Complete0 =
        #transaction{tx_id = <<>>,
                     role = {remote_complete, OperationRef,
                             RequestDigest, TargetRef},
                     evidence = none,
                     foreign_reads = [],
                     origin = Origin, proof_id = RequestDigest,
                     plan_digest = RequestDigest,
                     goal = GoalBlob, result = ResultBlob,
                     diff = [], read_check = #{}, effects = [],
                     request_auth = none, auth_transcript = none,
                     author = none, sig = none},
    Complete0#transaction{tx_id = semantic_id_or_error(
                                    {Ns, Anchor}, Complete0)};
remote_complete(_Origin, _OperationRef, _RequestDigest, _TargetRef) ->
    error(bad_remote_completion).

-doc "Attach independently verified acceleration evidence without changing tx_id.".
-spec attach_evidence(#transaction{}, term(), #transaction{}) -> #transaction{}.
attach_evidence(
  Transaction = #transaction{role = {remote_application, ClaimRef, _, _},
                             evidence = none},
  CertifiedRef, Claim = #transaction{}) ->
    case stable_ref(CertifiedRef) =:= ClaimRef andalso
         certified_transaction_matches(CertifiedRef, Claim) of
        true -> Transaction#transaction{evidence = {CertifiedRef, Claim}};
        false -> error(bad_remote_evidence)
    end;
attach_evidence(
  Transaction = #transaction{role = {remote_complete, _, _, TargetRef},
                             evidence = none},
  CertifiedRef, TargetTx = #transaction{}) ->
    case stable_ref(CertifiedRef) =:= TargetRef andalso
         certified_transaction_matches(CertifiedRef, TargetTx) of
        true -> Transaction#transaction{evidence = {CertifiedRef, TargetTx}};
        false -> error(bad_remote_evidence)
    end;
attach_evidence(_Transaction, _CertifiedRef, _Referenced) ->
    error(bad_remote_evidence).

-doc "Encode one exact certified transaction evidence pair.".
-spec encode_evidence(term(), #transaction{}) ->
          {ok, binary()} | {error, bad_remote_evidence | too_large}.
encode_evidence(CertifiedRef, #transaction{} = Transaction) ->
    case certified_transaction_matches(CertifiedRef, Transaction) of
        true ->
            Blob = term_to_binary(
                     {quod_transaction_evidence, 1,
                      CertifiedRef, Transaction}, [deterministic]),
            %% Evidence is one transport frame, not a new semantic quota.
            %% Reuse the existing durable-operation envelope bound so this
            %% codec and its only carrier cannot disagree.
            case byte_size(Blob) =< ?QUOD_DTX_ENDPOINT_MAX_ENVELOPE_BYTES of
                true -> {ok, Blob};
                false -> {error, too_large}
            end;
        false -> {error, bad_remote_evidence}
    end.

-doc "Decode one bounded canonical certified transaction evidence pair.".
-spec decode_evidence(binary()) ->
          {ok, term(), #transaction{}} | {error, bad_remote_evidence}.
decode_evidence(Blob)
  when is_binary(Blob),
       byte_size(Blob) =< ?QUOD_DTX_ENDPOINT_MAX_ENVELOPE_BYTES ->
    case quod_safe_term:decode(
           Blob, ?QUOD_DTX_ENDPOINT_MAX_ENVELOPE_BYTES) of
        {ok, {quod_transaction_evidence, 1, CertifiedRef,
              #transaction{} = Transaction} = Decoded} ->
            case term_to_binary(Decoded, [deterministic]) =:= Blob andalso
                 certified_transaction_matches(CertifiedRef, Transaction) of
                true -> {ok, CertifiedRef, Transaction};
                false -> {error, bad_remote_evidence}
            end;
        _ -> {error, bad_remote_evidence}
    end;
decode_evidence(_) -> {error, bad_remote_evidence}.

-spec role(#transaction{}) -> term().
role(#transaction{role = Role}) -> Role.

-spec evidence(#transaction{}) -> term().
evidence(#transaction{evidence = Evidence}) -> Evidence.

-doc "Return typed exact ledger references required to validate content.".
-spec required_references(#transaction{}) -> [{transaction | entry, term()}] | error.
required_references(
  #transaction{role = {remote_application, ClaimRef, _, _},
               evidence = {CertifiedRef, _},
               foreign_reads = ForeignReads}) ->
    case {stable_ref(CertifiedRef), read_reference_requirements(ForeignReads)} of
        {ClaimRef, {ok, ReadRefs}} -> [{transaction, CertifiedRef} | ReadRefs];
        _ -> error
    end;
required_references(
  #transaction{role = {remote_complete, _, _, TargetRef},
               evidence = {CertifiedRef, _}, foreign_reads = []}) ->
    case stable_ref(CertifiedRef) of
        TargetRef -> [{transaction, CertifiedRef}];
        _ -> error
    end;
required_references(#transaction{role = application, evidence = none,
                                 foreign_reads = ForeignReads}) ->
    read_reference_requirements_or_error(ForeignReads);
required_references(#transaction{role = {remote_claim, _, _, _},
                                 evidence = none,
                                 foreign_reads = ForeignReads}) ->
    read_reference_requirements_or_error(ForeignReads);
required_references(#transaction{}) -> error.

read_reference_requirements_or_error(ForeignReads) ->
    case read_reference_requirements(ForeignReads) of
        {ok, Requirements} -> Requirements;
        error -> error
    end.

read_reference_requirements(ForeignReads) ->
    case canonical_foreign_reads(ForeignReads) of
        {ok, Certificates} ->
            read_reference_requirements(Certificates, []);
        error -> error
    end.

read_reference_requirements([], Acc) ->
    {ok, lists:reverse(Acc)};
read_reference_requirements([Certificate | Rest], Acc) ->
    case quod_read_certificate:binding(Certificate) of
        {ok, #{anchor_ref := AnchorRef}} ->
            read_reference_requirements(Rest, [{entry, AnchorRef} | Acc]);
        error -> error
    end.

-doc "Project one certified ledger reference to its stable transaction identity.".
-spec stable_ref(term()) ->
          {transaction, binary(), <<_:256>>, <<_:256>>} | invalid.
stable_ref(Ref) ->
    case quod_dtx:certified_ref_binding(Ref) of
        {ok, {Ns, Anchor}, _Slot, TxId} ->
            {transaction, Ns, Anchor, TxId};
        error -> invalid
    end.

certified_transaction_matches(CertifiedRef,
                              #transaction{tx_id = TxId}) ->
    case quod_dtx:certified_ref_binding(CertifiedRef) of
        {ok, _Identity, _Slot, TxId} -> true;
        _ -> false
    end.

semantic_id_or_error(Target, Transaction) ->
    case semantic_id(Target, Transaction) of
        {ok, Id} -> Id;
        error -> error(bad_transaction_material)
    end.

-doc "Bind a transaction's stable id to its target and complete semantic write.".
-spec bind_id({binary(), binary()}, #transaction{}) -> #transaction{}.
bind_id(Target, Transaction = #transaction{}) ->
    case semantic_id(Target, Transaction) of
        {ok, TxId} -> Transaction#transaction{tx_id = TxId};
        error -> error(bad_transaction_material)
    end.

-doc "Whether `tx_id` is the canonical id of this target-bound semantic write.".
-spec valid_id({binary(), binary()}, #transaction{}) -> boolean().
valid_id({Ns, <<_:256>>} = Target,
         #transaction{tx_id = <<_:256>> = TxId} = Transaction)
  when is_binary(Ns) ->
    semantic_id(Target, Transaction) =:= {ok, TxId};
valid_id(_Target, _Transaction) ->
    false.

-doc "Build the expected anchored outcome without decoding a foreign plan's payloads.".
-spec plan_outcome_ref(quod_dtx:plan(), binary(), binary(),
                       none | quod_client_goal:request_auth()) ->
          {transaction, binary(), binary(), binary()}.
plan_outcome_ref(Plan, GoalBlob, ResultBlob, RequestAuth)
  when is_binary(GoalBlob), is_binary(ResultBlob) ->
    {Ns, <<_:256>> = Anchor} = Target = quod_dtx:target(Plan),
    {StoredAuth, AuthTranscript} =
        request_outcome_fields(Plan, GoalBlob, RequestAuth),
    {transaction, Ns, Anchor,
     semantic_plan_id(
       Target, Plan, GoalBlob, ResultBlob, StoredAuth, AuthTranscript,
       application)}.

request_outcome_fields(Plan, _GoalBlob, none) ->
    case quod_dtx:request_binding(Plan) of
        none -> {none, none};
        _ -> error(bad_request_binding)
    end;
request_outcome_fields(Plan, GoalBlob, RequestAuth) ->
    case quod_dtx:material(Plan) of
        {ok, Material} -> request_fields(Plan, Material, GoalBlob, RequestAuth);
        {error, _} -> error(bad_plan)
    end.

-doc "Encode one durable goal/result pair through the shared persistence codec.".
-spec encode_durable_submission(term(), map()) ->
          {ok, binary(), binary()} | {error, term()}.
encode_durable_submission(Goal, Bindings) when is_map(Bindings) ->
    case quod_durable_term:encode_goal(Goal) of
        {ok, GoalBlob} ->
            case quod_durable_term:encode_result(Bindings) of
                {ok, ResultBlob} -> {ok, GoalBlob, ResultBlob};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end;
encode_durable_submission(_Goal, _Bindings) ->
    {error, invalid_result}.

request_fields(Plan, _Material, _GoalBlob, none) ->
    case quod_dtx:request_binding(Plan) of
        none -> {none, none};
        _ -> error(bad_request_binding)
    end;
request_fields(Plan, #{transcript := Transcript}, GoalBlob,
               {agent_goal_v1, <<_:256>> = Digest, _Bytes, _Signature} = Auth) ->
    case quod_dtx:request_binding(Plan) of
        {agent_goal_v1, Digest} ->
            Target = quod_dtx:target(Plan),
            case quod_client_goal:authorization_transcript(
                   Transcript, Target, GoalBlob) of
                {ok, Authorization} ->
                    case request_evidence(
                           Target, GoalBlob, Auth, Authorization, verify) of
                        {ok, _Evidence} -> {Auth, Authorization};
                        {error, _} -> error(bad_request_binding)
                    end;
                _ -> error(bad_request_binding)
            end;
        _ ->
            error(bad_request_binding)
    end;
request_fields(_Plan, _Material, _GoalBlob, _RequestAuth) ->
    error(bad_request_binding).

-doc "Validate and expose one transaction's durable signed-agent claim.".
-spec validate_request(binary(), {binary(), <<_:256>>}, non_neg_integer(),
                       #transaction{}) ->
          {ok, none | map()} | {error, term()}.
validate_request(_Network, _Target, _AdmissionMs,
                 #transaction{role = Role, request_auth = none,
                              auth_transcript = none}) ->
    case Role of
        application -> {ok, none};
        {remote_application, _, _, _} -> {ok, none};
        {remote_complete, _, _, _} -> {ok, none};
        _ -> {error, invalid_request_binding}
    end;
validate_request(
  <<_:256>> = Network, {Ns, <<_:256>>} = Target, AdmissionMs,
  #transaction{role = application, origin = Target, goal = GoalBlob,
               request_auth = Auth,
               auth_transcript = {agent_goal_v1, TranscriptBlob}})
  when is_binary(Ns), is_integer(AdmissionMs), AdmissionMs >= 0,
       is_binary(GoalBlob), is_binary(TranscriptBlob) ->
    request_evidence(
      Target, GoalBlob, Auth, {agent_goal_v1, TranscriptBlob},
      {admission, Network, AdmissionMs});
validate_request(
  <<_:256>> = Network, {Ns, <<_:256>>} = Target, AdmissionMs,
  #transaction{role = {remote_claim, _, _, _}, origin = Target,
               goal = GoalBlob, request_auth = Auth,
               auth_transcript = none})
  when is_binary(Ns), is_integer(AdmissionMs), AdmissionMs >= 0,
       is_binary(GoalBlob) ->
    case quod_client_goal:validate_durable_request(
           Auth, Network, Target, AdmissionMs, GoalBlob) of
        {ok, Evidence} -> {ok, Evidence};
        {error, _} = Error -> Error
    end;
validate_request(_Network, _Target, _AdmissionMs, #transaction{}) ->
    {error, invalid_request_binding}.

-doc "Return the bounded operation claim without consulting runtime state.".
-spec request_claim(#transaction{}) -> none | {ok, map()} | error.
request_claim(#transaction{role = application,
                           request_auth = none, auth_transcript = none}) ->
    none;
request_claim(#transaction{role = application, origin = Target,
                           goal = GoalBlob, request_auth = Auth,
                           auth_transcript = {agent_goal_v1, TranscriptBlob}})
  when is_binary(GoalBlob), is_binary(TranscriptBlob) ->
    case request_evidence(
           Target, GoalBlob, Auth, {agent_goal_v1, TranscriptBlob}, verify) of
        {ok, #{claim := Claim}} -> {ok, Claim};
        {error, _} -> error
    end;
request_claim(#transaction{role = {remote_claim, _, _, _},
                           goal = GoalBlob, request_auth = Auth,
                           auth_transcript = none}) ->
    case quod_client_goal:verify_durable_request(Auth, GoalBlob) of
        {ok, #{claim := Claim}} -> {ok, Claim};
        {error, _} -> error
    end;
request_claim(#transaction{role = {remote_application, _, _, _},
                           request_auth = none, auth_transcript = none}) -> none;
request_claim(#transaction{role = {remote_complete, _, _, _},
                           request_auth = none, auth_transcript = none}) -> none;
request_claim(#transaction{}) ->
    error.

-doc "Classify whether a remote claim may use any host or its private effect owner.".
-spec remote_claim_route(#transaction{}) ->
          shared | {private, <<_:256>>} | error.
remote_claim_route(
  #transaction{role = {remote_claim, _Manifest,
                       {Target, PlanDigest, PlanBlob, _Attestation},
                       _TargetTxId}}) ->
    case quod_dtx:decode(PlanBlob) of
        {ok, Plan} ->
            case {quod_dtx:target(Plan), quod_dtx:digest(Plan),
                  quod_dtx:signer(Plan), quod_dtx:effects_count(Plan)} of
                {Target, PlanDigest, _Signer, 0} -> shared;
                {Target, PlanDigest, <<_:256>> = Signer, 1} ->
                    {private, Signer};
                _ -> error
            end;
        {error, _} -> error
    end;
remote_claim_route(#transaction{}) -> error.

-doc "Whether a content value must be checked against the network identity.".
-spec requires_network_identity(term()) -> boolean().
requires_network_identity([]) -> false;
requires_network_identity(
  [#transaction{request_auth = none, auth_transcript = none} | Rest]) ->
    requires_network_identity(Rest);
requires_network_identity([#transaction{} | _Rest]) -> true;
requires_network_identity([_Malformed | _Rest]) -> true;
requires_network_identity(_ImproperOrMalformed) -> true.

valid_request_fields(_Target, _GoalBlob, none, none) ->
    true;
valid_request_fields(Target, GoalBlob, Auth, Authorization) ->
    case request_evidence(
           Target, GoalBlob, Auth, Authorization, verify) of
        {ok, _Evidence} -> true;
        {error, _} -> false
    end.

%% One structural verifier feeds transaction construction, signed bytes,
%% claim extraction, and admission-time validation. Callers project the shape
%% they need; none of them reimplements request or transcript checks.
request_evidence(Target, GoalBlob, Auth, Authorization, verify) ->
    checked_request_target(
      Target,
      quod_client_goal:verify_durable_authorization(
        Auth, Authorization, GoalBlob));
request_evidence(Target, GoalBlob, Auth, Authorization,
                 {admission, Network, AdmissionMs}) ->
    checked_request_target(
      Target,
      quod_client_goal:validate_durable_authorization(
        Auth, Authorization, Network, Target, AdmissionMs, GoalBlob)).

checked_request_target(
  {Ns, Anchor},
  {ok, #{evidence :=
             #{request := #{agent_namespace := Ns,
                            agent_genesis_anchor := Anchor}}}} = Result)
  when is_binary(Ns), is_binary(Anchor) ->
    Result;
checked_request_target(_Target, {ok, _OtherEvidence}) ->
    {error, invalid_request_binding};
checked_request_target(_Target, {error, _} = Error) ->
    Error.

semantic_id({Ns, <<_:256>> = Anchor},
            #transaction{role = Role, origin = Origin, proof_id = ProofId,
                         plan_digest = PlanDigest, goal = Goal,
                         result = Result, diff = Diff,
                         read_check = ReadCheck, effects = Effects,
                         request_auth = RequestAuth,
                         auth_transcript = AuthTranscript})
  when is_binary(Ns) ->
    case semantic_material_bytes(Diff, ReadCheck, Effects) of
        {ok, DiffBytes, ReadCheckBytes, EffectsBytes} ->
            {ok,
             semantic_id_parts(
               Ns, Anchor, Origin, ProofId, PlanDigest, Goal, Result,
               DiffBytes, ReadCheckBytes, EffectsBytes,
               RequestAuth, AuthTranscript, semantic_role(Role))};
        error ->
            error
    end.

semantic_material_bytes(Diff, ReadCheck, Effects)
  when is_list(Diff), is_map(ReadCheck), is_list(Effects) ->
    case {quod_wire_term:encode_canonical(Diff),
          quod_wire_term:encode_canonical(maps:to_list(ReadCheck)),
          quod_wire_term:encode_canonical(Effects)} of
        {{ok, DiffBytes}, {ok, ReadCheckBytes}, {ok, EffectsBytes}} ->
            {ok, DiffBytes, ReadCheckBytes, EffectsBytes};
        _ ->
            error
    end;
semantic_material_bytes(_Diff, _ReadCheck, _Effects) ->
    error.

semantic_plan_id(
  {Ns, <<_:256>> = Anchor}, Plan, GoalBlob, ResultBlob,
  RequestAuth, AuthTranscript, Role) ->
    semantic_id_parts(
      Ns, Anchor, quod_dtx:origin(Plan), quod_dtx:proof_id(Plan),
      quod_dtx:digest(Plan), GoalBlob, ResultBlob,
      quod_dtx:diff_bytes(Plan), quod_dtx:read_check_bytes(Plan),
      quod_dtx:effects_bytes(Plan), RequestAuth, AuthTranscript, Role).

semantic_id_parts(Ns, Anchor, Origin, ProofId, PlanDigest, Goal, Result,
                  DiffBytes, ReadCheckBytes, EffectsBytes,
                  RequestAuth, AuthTranscript, Role) ->
    crypto:hash(
      sha256,
      term_to_binary(
        {?ID_DOMAIN, ?ID_VERSION, Ns, Anchor, Origin, ProofId,
         PlanDigest, Goal, Result, DiffBytes, ReadCheckBytes, EffectsBytes,
         RequestAuth, AuthTranscript, Role},
        [deterministic])).

%% The predicted target id is checked but excluded from C, breaking the C/T
%% construction cycle. Every other role field participates in its semantic id.
semantic_role({remote_claim, Target, PlanBlob, <<_:256>>}) ->
    {remote_claim, Target, PlanBlob};
semantic_role(Role) -> Role.

-doc "Canonical bytes signed by a transaction author, bound to the target identity.".
-spec bytes(target_binding(), #transaction{}) ->
          {ok, binary()} | {error, bad_term}.
bytes({TargetNs, TargetAnchor, AuthorAdmission},
      Transaction = #transaction{tx_id = TxId, role = Role,
                   evidence = Evidence,
                   foreign_reads = ForeignReads,
                   origin = Origin, proof_id = ProofId,
                   plan_digest = PlanDigest, goal = Goal,
                   result = Result, diff = Diff, read_check = ReadCheck,
                   effects = Effects,
                   request_auth = RequestAuth,
                   auth_transcript = AuthTranscript,
                   author = Author, author_seq = AuthorSeq,
                   submitted_at = SubmittedAt})
  when is_binary(TargetNs), is_binary(TargetAnchor),
       is_binary(AuthorAdmission), byte_size(TargetAnchor) =:= 32,
       byte_size(AuthorAdmission) =:= 32 ->
    case {encode_material(Diff, ReadCheck, Effects),
          canonical_foreign_reads(ForeignReads),
          valid_role_fields({TargetNs, TargetAnchor}, Transaction)} of
        {{ok, MaterialWire, EffectsWire}, {ok, ForeignReads}, true}
          when byte_size(EffectsWire) =< ?QUOD_MAX_DIRECT_EFFECT_BYTES ->
            case quod_effect:validate_transaction(
                   TargetNs, TargetAnchor, Author, Effects) of
                true ->
                    {ok,
                     canonical_bytes(
                       TargetNs, TargetAnchor, AuthorAdmission, TxId, Origin,
                       ProofId, PlanDigest, Goal, Result, MaterialWire,
                       EffectsWire, Role, Evidence, ForeignReads,
                       RequestAuth, AuthTranscript,
                       Author, AuthorSeq, SubmittedAt)};
                false ->
                    {error, bad_term}
            end;
        {{ok, _MaterialWire, _EffectsWire}, _ForeignReads, _} ->
            {error, bad_term};
        {{error, bad_term} = Error, _ForeignReads, _} ->
            Error
    end;
bytes(_Binding, _Transaction) ->
    {error, bad_term}.

canonical_bytes(TargetNs, TargetAnchor, AuthorAdmission, TxId, Origin,
                ProofId, PlanDigest, Goal, Result, MaterialWire, EffectsWire,
                Role, Evidence, ForeignReads, RequestAuth, AuthTranscript, Author,
                AuthorSeq, SubmittedAt) ->
    term_to_binary(
      {?DOMAIN, ?VERSION, TargetNs, TargetAnchor, AuthorAdmission,
       TxId, Origin, ProofId, PlanDigest, Goal, Result, MaterialWire,
       EffectsWire, Role, Evidence, ForeignReads, RequestAuth, AuthTranscript,
       Author, AuthorSeq, SubmittedAt},
      [deterministic]).

encode_material(Diff, ReadCheck, Effects)
  when is_list(Diff), is_map(ReadCheck), is_list(Effects) ->
    case {quod_wire_term:encode({Diff, maps:to_list(ReadCheck)}),
          quod_wire_term:encode_canonical(Effects)} of
        {{ok, MaterialWire}, {ok, EffectsWire}} ->
            {ok, MaterialWire, EffectsWire};
        _ ->
            {error, bad_term}
    end;
encode_material(_Diff, _ReadCheck, _Effects) ->
    {error, bad_term}.

-doc """
Sign an unsigned transaction for the target identity. The supplied identity
must own the same public key named by `author`; callers cannot use a node key
to sign for a different author.
""".
-spec sign(target_binding(), #transaction{}, quod_identity:signer()) ->
        {ok, #transaction{}} | {error, term()}.
sign(Binding, Transaction, Identity) ->
    case signing_material(Binding, Transaction, Identity) of
        {ok, Signed, _Author, _Signature, _Canonical} -> {ok, Signed};
        {error, _} = Error -> Error
    end.

-doc "Sign and build a relay submission without encoding the transaction twice.".
-spec sign_submission(target_binding(), #transaction{}, quod_identity:signer()) ->
          {ok, #transaction{}, {submit, binary(), binary(), binary()}} |
          {error, term()}.
sign_submission(Binding, Transaction, Identity) ->
    case signing_material(Binding, Transaction, Identity) of
        {ok, Signed, Author, Signature, Canonical}
          when byte_size(Canonical) =< ?QUOD_MAX_CANONICAL_TRANSACTION_BYTES ->
            {ok, Signed, {submit, Author, Signature, Canonical}};
        {ok, _Signed, _Author, _Signature, _Canonical} ->
            {error, too_large};
        {error, _} = Error ->
            Error
    end.

signing_material(
  {TargetNs, TargetAnchor, AuthorAdmission} = Binding,
  #transaction{author = Author, sig = none} = Transaction,
  #{pubkey := Author} = Identity)
  when is_binary(TargetNs), is_binary(TargetAnchor), is_binary(AuthorAdmission),
       byte_size(TargetAnchor) =:= 32, byte_size(AuthorAdmission) =:= 32,
       byte_size(Author) =:= ?PUBKEY_BYTES ->
    case bytes(Binding, Transaction) of
        {ok, Canonical} ->
            Signature = quod_identity:sign(Canonical, Identity),
            {ok, Transaction#transaction{sig = Signature},
             Author, Signature, Canonical};
        {error, _} = Error ->
            Error
    end;
signing_material(_Binding, #transaction{sig = Sig}, _Identity)
  when Sig =/= none ->
    {error, already_signed};
signing_material(_Binding, #transaction{}, _Identity) ->
    {error, author_mismatch};
signing_material(_Binding, _Transaction, _Identity) ->
    {error, malformed_transaction}.

-doc "Verify a transaction signature against the validator's own target identity.".
-spec verify(target_binding(), #transaction{}) -> boolean().
verify({TargetNs, TargetAnchor, AuthorAdmission} = Binding,
       #transaction{author = Author, sig = Signature} = Transaction)
  when is_binary(TargetNs), is_binary(TargetAnchor), is_binary(AuthorAdmission),
       byte_size(TargetAnchor) =:= 32, byte_size(AuthorAdmission) =:= 32,
       is_binary(Author), byte_size(Author) =:= ?PUBKEY_BYTES,
       is_binary(Signature), byte_size(Signature) =:= ?SIGNATURE_BYTES ->
    case bytes(Binding, Transaction) of
        {ok, Canonical} ->
            quod_identity:verify(Signature, Canonical, Author);
        {error, bad_term} ->
            false
    end;
verify(_Binding, _Transaction) ->
    false.

-doc """
Build the relay payload whose canonical transaction bytes remain opaque until
the receiving validator has verified their signature.
""".
-spec submission(target_binding(), #transaction{}) ->
        {ok, {submit, binary(), binary(), binary()}} | {error, term()}.
submission(Binding, #transaction{author = Author, sig = Signature} = Transaction)
  when is_binary(Author), byte_size(Author) =:= ?PUBKEY_BYTES,
       is_binary(Signature), byte_size(Signature) =:= ?SIGNATURE_BYTES ->
    case bytes(Binding, Transaction) of
        {ok, Canonical}
          when byte_size(Canonical) =< ?QUOD_MAX_CANONICAL_TRANSACTION_BYTES ->
            {ok, {submit, Author, Signature, Canonical}};
        {ok, _Canonical} ->
            {error, too_large};
        {error, _} = Error ->
            Error
    end;
submission(_Binding, _Transaction) ->
    {error, unsigned_or_malformed}.

-doc "Stable 16-byte correlation id for one authenticated author/signature pair.".
-spec submission_id({submit, binary(), binary(), binary()}) -> binary().
submission_id({submit, Author, Signature, _Canonical}) ->
    <<Id:16/binary, _/binary>> =
        crypto:hash(
          sha256,
          term_to_binary(
            {quod_submission, 2, Author, Signature}, [deterministic])),
    Id.

-doc """
Return the stable 16-byte identity of one exact relay placement.

The domain-separated digest binds an exact signed submission to its namespace,
committee view, target slot, and target validator. Retargeting the unchanged
submission therefore keeps its `submission_id/1` but receives a distinct attempt
id. Malformed inputs return `error`; this helper is total at the relay boundary.
""".
-spec relay_attempt_id(binary(), binary(), binary(), pos_integer(), binary()) ->
        binary() | error.
relay_attempt_id(Ns, SubmissionId, CommitteeId, TargetSlot, Target)
  when is_binary(Ns),
       is_binary(SubmissionId),
       byte_size(SubmissionId) =:= ?SUBMISSION_ID_BYTES,
       is_binary(CommitteeId),
       byte_size(CommitteeId) =:= ?COMMITTEE_ID_BYTES,
       is_integer(TargetSlot),
       TargetSlot >= 1,
       TargetSlot =< ?MAX_SLOT,
       is_binary(Target),
       byte_size(Target) =:= ?PUBKEY_BYTES ->
    Canonical =
        term_to_binary(
          {?RELAY_ATTEMPT_DOMAIN, ?RELAY_ATTEMPT_VERSION,
           Ns, SubmissionId, CommitteeId, TargetSlot, Target},
          [deterministic]),
    <<Id:?SUBMISSION_ID_BYTES/binary, _/binary>> =
        crypto:hash(sha256, Canonical),
    Id;
relay_attempt_id(_Ns, _SubmissionId, _CommitteeId, _TargetSlot, _Target) ->
    error.

-doc """
Verify the author signature over the still-opaque canonical bytes. This is the
only operation permitted before the inner transaction is decoded.
""".
-spec verify_submission(term()) -> boolean().
verify_submission({submit, Author, Signature, Canonical})
  when is_binary(Author), byte_size(Author) =:= ?PUBKEY_BYTES,
       is_binary(Signature), byte_size(Signature) =:= ?SIGNATURE_BYTES,
       is_binary(Canonical),
       byte_size(Canonical) =< ?QUOD_MAX_CANONICAL_TRANSACTION_BYTES ->
    quod_identity:verify(Signature, Canonical, Author);
verify_submission(_Submission) ->
    false.

-doc """
Decode a submission after `verify_submission/1` succeeded. The re-encode check
rejects non-canonical ETF and binds the opaque bytes to the target identity
and `Author`.
""".
-spec decode_verified_submission(target_binding(), term()) ->
        {ok, #transaction{}} | {error, term()}.
decode_verified_submission(
  {TargetNs, TargetAnchor, AuthorAdmission} = Binding,
  {submit, Author, Signature, Canonical})
  when is_binary(TargetNs), is_binary(TargetAnchor),
       is_binary(AuthorAdmission),
       is_binary(Author), is_binary(Signature),
       is_binary(Canonical),
       byte_size(Canonical) =< ?QUOD_MAX_CANONICAL_TRANSACTION_BYTES ->
    case quod_safe_term:decode(
           Canonical, ?QUOD_MAX_CANONICAL_TRANSACTION_BYTES) of
        {ok,
         {?DOMAIN, ?VERSION, TargetNs, TargetAnchor, AuthorAdmission,
          TxId, Origin, ProofId,
          PlanDigest, Goal, Result, MaterialWire, EffectsWire, Role, Evidence,
          ForeignReads,
          RequestAuth, AuthTranscript,
          Author, AuthorSeq,
          SubmittedAt}} ->
            case decode_material(MaterialWire, EffectsWire) of
                {ok, Diff, ReadCheck, Effects} ->
                    Transaction =
                        #transaction{tx_id = TxId, role = Role,
                                     evidence = Evidence, origin = Origin,
                                     foreign_reads = ForeignReads,
                                     proof_id = ProofId,
                                     plan_digest = PlanDigest,
                                     goal = Goal, result = Result,
                                     diff = Diff, read_check = ReadCheck,
                                     effects = Effects,
                                     request_auth = RequestAuth,
                                     auth_transcript = AuthTranscript,
                                     author = Author,
                                     author_seq = AuthorSeq,
                                     submitted_at = SubmittedAt,
                                     sig = Signature},
                    case bytes(Binding, Transaction) of
                        {ok, Reencoded} when Reencoded =:= Canonical ->
                            {ok, Transaction};
                        {ok, _OtherCanonical} ->
                            {error, noncanonical};
                        {error, _} -> {error, malformed_material}
                    end;
                {error, _} = Error ->
                    Error
            end;
        {ok, Other}
          when is_tuple(Other), tuple_size(Other) >= 2,
               element(1, Other) =:= ?DOMAIN,
               element(2, Other) =/= ?VERSION ->
            {error, unsupported_version};
        {ok, _Other} ->
            {error, namespace_or_author_mismatch};
        {error, _Reason} ->
            {error, malformed_canonical_bytes}
    end;
decode_verified_submission(_Binding, _Submission) ->
    {error, malformed_submission}.

-doc "Decode bounded metadata from the one current V12 transaction envelope.".
-spec decode_submission_metadata(term()) ->
          {ok, #{target := {binary(), binary()},
                 admission := binary(), tx_id := binary(),
                 effects := [quod_effect:effect()], author := binary(),
                 sequence := non_neg_integer()}} |
          {error, malformed_submission}.
decode_submission_metadata(Canonical)
  when is_binary(Canonical),
       byte_size(Canonical) =< ?QUOD_MAX_CANONICAL_TRANSACTION_BYTES ->
    case quod_safe_term:decode(
           Canonical, ?QUOD_MAX_CANONICAL_TRANSACTION_BYTES) of
        {ok,
         {?DOMAIN, ?VERSION, Ns, <<_:256>> = Anchor,
          <<_:256>> = Admission, <<_:256>> = TxId,
          _Origin, _ProofId, _PlanDigest, _Goal, _Result,
          _MaterialWire, EffectsWire, _Role, _Evidence,
          _ForeignReads,
          _RequestAuth, _AuthTranscript,
          <<_:256>> = Author, Sequence, _SubmittedAt} = Decoded}
          when is_binary(Ns), is_integer(Sequence), Sequence >= 0 ->
            case {term_to_binary(Decoded, [deterministic]) =:= Canonical,
                  quod_wire_term:decode_canonical(
                    EffectsWire, ?QUOD_MAX_DIRECT_EFFECT_BYTES)} of
                {true, {ok, Effects}} when is_list(Effects) ->
                    {ok, #{target => {Ns, Anchor}, admission => Admission,
                           tx_id => TxId, effects => Effects,
                           author => Author, sequence => Sequence}};
                _ ->
                    {error, malformed_submission}
            end;
        _ ->
            {error, malformed_submission}
    end;
decode_submission_metadata(_Canonical) ->
    {error, malformed_submission}.

-doc "Encode one exact signed source claim for target operation custody.".
-spec encode_operation_submission(term()) ->
          {ok, binary()} | {error, invalid_operation_submission}.
encode_operation_submission(Submission) ->
    case operation_submission(Submission) of
        {ok, _Binding} ->
            Blob = term_to_binary(Submission, [deterministic]),
            case byte_size(Blob) =< ?QUOD_MAX_OPERATION_SUBMISSION_BYTES of
                true -> {ok, Blob};
                false -> {error, invalid_operation_submission}
            end;
        {error, invalid_operation_submission} = Error ->
            Error
    end.

-doc "Verify and decode one exact signed source claim used for operation custody.".
-spec decode_operation_submission(binary()) ->
          {ok,
           #{submission := term(), claim := #transaction{},
             claim_ref := term(), target := {binary(), <<_:256>>},
             target_ref := term(), plan := quod_dtx:plan(),
             plan_digest := <<_:256>>, manifest_digest := <<_:256>>,
             effect := quod_effect:effect(),
             author := <<_:256>>, admission := <<_:256>>,
             cancel_digest := <<_:256>>}} |
          {error, invalid_operation_submission}.
decode_operation_submission(Blob)
  when is_binary(Blob),
       byte_size(Blob) =< ?QUOD_MAX_OPERATION_SUBMISSION_BYTES ->
    case quod_safe_term:decode(
           Blob, ?QUOD_MAX_OPERATION_SUBMISSION_BYTES) of
        {ok, Submission = {submit, _, _, _}} ->
            case term_to_binary(Submission, [deterministic]) =:= Blob of
                true -> operation_submission(Submission);
                false -> {error, invalid_operation_submission}
            end;
        _ ->
            {error, invalid_operation_submission}
    end;
decode_operation_submission(_Blob) ->
    {error, invalid_operation_submission}.

%% The outer signature is checked while the transaction bytes are still
%% opaque. Only then may the fixed metadata reveal the exact source binding
%% needed by the existing canonical transaction decoder.
operation_submission(
  Submission = {submit, Author, Signature, Canonical}) ->
    case verify_submission(Submission) of
        true ->
            operation_submission_metadata(
              Submission, Author, Signature,
              decode_submission_metadata(Canonical));
        false ->
            {error, invalid_operation_submission}
    end;
operation_submission(_Submission) ->
    {error, invalid_operation_submission}.

operation_submission_metadata(
  Submission, Author, Signature,
  {ok, #{target := {OriginNs, OriginAnchor} = Origin,
         admission := Admission, author := Author}})
  when is_binary(OriginNs), byte_size(OriginNs) > 0 ->
    case decode_verified_submission(
           {OriginNs, OriginAnchor, Admission}, Submission) of
        {ok,
         Claim = #transaction{
                   tx_id = <<_:256>> = ClaimTxId,
                   origin = Origin,
                   role = {remote_claim, Manifest,
                           {Target, PlanDigest, PlanBlob, _Attestation},
                           _PredictedTargetTxId}}} ->
            operation_submission_claim(
              Submission, Author, Signature, Admission, Claim, ClaimTxId,
              Manifest, Target, PlanDigest, PlanBlob);
        _ ->
            {error, invalid_operation_submission}
    end;
operation_submission_metadata(
  _Submission, _Author, _Signature, _Metadata) ->
    {error, invalid_operation_submission}.

operation_submission_claim(
  Submission, Author, Signature, Admission,
  Claim = #transaction{origin = {OriginNs, OriginAnchor}},
  ClaimTxId, Manifest, Target, PlanDigest, PlanBlob) ->
    case {quod_dtx:manifest_coordinator(Manifest),
          quod_dtx:decode(PlanBlob)} of
        {{OriginNs, OriginAnchor, Author, Admission}, {ok, Plan}} ->
            operation_submission_plan(
              Submission, Author, Signature, Admission, Claim,
              {transaction, OriginNs, OriginAnchor, ClaimTxId},
              Target, PlanDigest, quod_dtx:manifest_digest(Manifest), Plan);
        _ ->
            {error, invalid_operation_submission}
    end.

operation_submission_plan(
  Submission, Author, Signature, Admission, Claim, ClaimRef,
  Target, PlanDigest, ManifestDigest, Plan) ->
    case {quod_dtx:target(Plan) =:= Target,
          quod_dtx:digest(Plan) =:= PlanDigest,
          quod_dtx:material(Plan)} of
        {true, true, {ok, #{effects := [Effect]} = Material}} ->
            case quod_effect:validate_plan(Plan, Material) of
                true ->
                    operation_submission_application(
                      Submission, Author, Signature, Admission, Claim,
                      ClaimRef, Target, PlanDigest, ManifestDigest,
                      Plan, Effect);
                false ->
                    {error, invalid_operation_submission}
            end;
        _ ->
            {error, invalid_operation_submission}
    end.

operation_submission_application(
  Submission, Author, Signature, Admission, Claim, ClaimRef,
  {TargetNs, TargetAnchor} = Target, PlanDigest, ManifestDigest,
  Plan, Effect) ->
    try remote_application(ClaimRef, Claim) of
        #transaction{tx_id = <<_:256>> = TargetTxId} ->
            {ok,
             #{submission => Submission, claim => Claim,
               claim_ref => ClaimRef, target => Target,
               target_ref =>
                   {transaction, TargetNs, TargetAnchor, TargetTxId},
               plan => Plan, plan_digest => PlanDigest,
               manifest_digest => ManifestDigest, effect => Effect,
               author => Author, admission => Admission,
               cancel_digest =>
                   crypto:hash(
                     sha256,
                     <<?OPERATION_CANCEL_DOMAIN/binary, Signature/binary>>) }};
        _ ->
            {error, invalid_operation_submission}
    catch
        _:_ -> {error, invalid_operation_submission}
    end.

valid_role_fields(
  Target, #transaction{role = application, evidence = none,
                       goal = Goal, request_auth = RequestAuth,
                       auth_transcript = AuthTranscript}) ->
    valid_request_fields(Target, Goal, RequestAuth, AuthTranscript);
valid_role_fields(
  Target,
  Claim = #transaction{
            role = {remote_claim,
                    Manifest,
                    {{TargetNs, <<_:256>>} = RemoteTarget,
                     PlanDigest, PlanBlob, Attestation},
                    <<_:256>> = PredictedTxId},
            evidence = none, goal = Goal,
            diff = [], read_check = #{}, effects = [],
            request_auth =
              {agent_goal_v1, <<_:256>>, _Bytes, <<_:512>>} = Auth,
            auth_transcript = none})
  when is_binary(TargetNs), is_binary(PlanBlob), is_binary(Goal) ->
    case {quod_client_goal:verify_durable_request(Auth, Goal),
          quod_dtx:decode(PlanBlob)} of
        {{ok, _}, {ok, Plan}} ->
            quod_dtx:origin(Plan) =:= Target andalso
                quod_dtx:target(Plan) =:= RemoteTarget andalso
                quod_dtx:digest(Plan) =:= PlanDigest andalso
                PlanDigest =:= Claim#transaction.plan_digest andalso
                quod_dtx:verify_plan_attestation(
                  RemoteTarget, Plan, Manifest, Attestation) andalso
                quod_dtx:event_context(Manifest, Plan) =:=
                    {ok, #{proof_id => Claim#transaction.proof_id,
                           origin => Target,
                           principal => quod_dtx:principal(Plan),
                           goal => Claim#transaction.goal,
                           result => Claim#transaction.result,
                           plan_digest => PlanDigest}} andalso
                predicted_remote_tx_id(Target, Claim, PredictedTxId);
        _ -> false
    end;
valid_role_fields(
  _Target,
  #transaction{role = {remote_application, ClaimRef, OperationRef,
                       <<_:256>> = RequestDigest},
               evidence = {CertifiedRef, #transaction{} = Claim},
               foreign_reads = ForeignReads,
               request_auth = none, auth_transcript = none}) ->
    ForeignReads =:= Claim#transaction.foreign_reads andalso
        stable_ref(CertifiedRef) =:= ClaimRef andalso
        certified_transaction_matches(CertifiedRef, Claim) andalso
        remote_claim_binding(Claim, OperationRef, RequestDigest);
valid_role_fields(
  Target,
  #transaction{role = {remote_complete, OperationRef,
                       <<_:256>> = RequestDigest, TargetRef},
               evidence = {CertifiedRef, #transaction{} = TargetTx},
               foreign_reads = [],
               diff = [], read_check = #{}, effects = [],
               request_auth = none, auth_transcript = none}) ->
    operation_origin(OperationRef) =:= Target andalso
        stable_ref(CertifiedRef) =:= TargetRef andalso
        certified_transaction_matches(CertifiedRef, TargetTx) andalso
        remote_application_binding(TargetTx, OperationRef, RequestDigest);
valid_role_fields(_Target, _Transaction) ->
    false.

foreign_reads_from_material(Material) ->
    canonical_foreign_reads_or_error(maps:get(foreign_reads, Material, [])).

-doc "Encode the canonical certificate list carried by a scope submission.".
-spec encode_foreign_reads([term()]) ->
          {ok, binary()} | {error, bad_foreign_reads | too_large}.
encode_foreign_reads(ForeignReads) ->
    case canonical_foreign_reads(ForeignReads) of
        {ok, Canonical} ->
            case encode_read_certificates(Canonical, []) of
                {ok, RevBlobs} ->
                    Blob = term_to_binary(
                             {quod_foreign_reads, 1,
                              lists:reverse(RevBlobs)}, [deterministic]),
                    case byte_size(Blob) =< ?QUOD_MAX_DTX_BODY_BYTES of
                        true -> {ok, Blob};
                        false -> {error, too_large}
                    end;
                error ->
                    {error, bad_foreign_reads}
            end;
        error ->
            {error, bad_foreign_reads}
    end.

-doc "Decode the canonical certificate list carried by a scope submission.".
-spec decode_foreign_reads(binary()) ->
          {ok, [term()]} | {error, bad_foreign_reads | too_large}.
decode_foreign_reads(Blob)
  when is_binary(Blob), byte_size(Blob) =< ?QUOD_MAX_DTX_BODY_BYTES ->
    case quod_safe_term:decode(Blob, ?QUOD_MAX_DTX_BODY_BYTES) of
        {ok, {quod_foreign_reads, 1, CertificateBlobs}}
          when is_list(CertificateBlobs) ->
            case decode_read_certificates(CertificateBlobs, []) of
                {ok, RevCertificates} ->
                    Certificates = lists:reverse(RevCertificates),
                    case canonical_foreign_reads(Certificates) of
                        {ok, Certificates} ->
                            case encode_foreign_reads(Certificates) of
                                {ok, Blob} -> {ok, Certificates};
                                _ -> {error, bad_foreign_reads}
                            end;
                        error -> {error, bad_foreign_reads}
                    end;
                error -> {error, bad_foreign_reads}
            end;
        _ -> {error, bad_foreign_reads}
    end;
decode_foreign_reads(Blob) when is_binary(Blob) ->
    {error, too_large};
decode_foreign_reads(_) ->
    {error, bad_foreign_reads}.

encode_read_certificates([], RevBlobs) ->
    {ok, RevBlobs};
encode_read_certificates([Certificate | Rest], RevBlobs) ->
    case quod_read_certificate:encode(Certificate) of
        {ok, Blob} -> encode_read_certificates(Rest, [Blob | RevBlobs]);
        {error, _} -> error
    end.

decode_read_certificates([], RevCertificates) ->
    {ok, RevCertificates};
decode_read_certificates([Blob | Rest], RevCertificates) when is_binary(Blob) ->
    case quod_read_certificate:decode(Blob) of
        {ok, Certificate} ->
            decode_read_certificates(Rest, [Certificate | RevCertificates]);
        {error, _} -> error
    end;
decode_read_certificates(_Malformed, _RevCertificates) ->
    error.

canonical_foreign_reads_or_error(ForeignReads) ->
    case canonical_foreign_reads(ForeignReads) of
        {ok, Canonical} -> Canonical;
        error -> error(bad_foreign_reads)
    end.

canonical_foreign_reads(ForeignReads) when is_list(ForeignReads) ->
    case lists:all(fun quod_read_certificate:valid_shape/1, ForeignReads) of
        true ->
            Canonical = lists:usort(ForeignReads),
            case Canonical =:= ForeignReads of
                true -> {ok, Canonical};
                false -> error
            end;
        false -> error
    end;
canonical_foreign_reads(_ForeignReads) ->
    error.

predicted_remote_tx_id(Origin, Claim, PredictedTxId) ->
    {OriginNs, OriginAnchor} = Origin,
    ClaimId = semantic_id_or_error(Origin, Claim),
    ClaimRef = {transaction, OriginNs, OriginAnchor, ClaimId},
    try remote_application(ClaimRef, Claim) of
        #transaction{tx_id = PredictedTxId} -> true;
        _ -> false
    catch _:_ -> false
    end.

remote_claim_binding(
  #transaction{role = {remote_claim, _Manifest, _Bundle, _Predicted},
               request_auth = Auth, goal = Goal},
  OperationRef, RequestDigest) ->
    case quod_client_goal:verify_durable_request(Auth, Goal) of
        {ok, #{claim := #{operation_ref := OperationRef,
                         digest := RequestDigest}}} -> true;
        _ -> false
    end;
remote_claim_binding(_, _, _) -> false.

remote_application_binding(
  #transaction{role = {remote_application, _ClaimRef,
                       OperationRef, RequestDigest}},
  OperationRef, RequestDigest) -> true;
remote_application_binding(_, _, _) -> false.

operation_origin({operation, Ns, <<_:256>> = Anchor, _Agent, <<_:256>>})
  when is_binary(Ns) -> {Ns, Anchor};
operation_origin(_) -> invalid.

decode_material(MaterialWire, EffectsWire) ->
    case {quod_wire_term:decode(MaterialWire),
          quod_wire_term:decode_canonical(
            EffectsWire, ?QUOD_MAX_DIRECT_EFFECT_BYTES)} of
        {{ok, {Diff0, ReadPairs0}}, {ok, Effects0}}
          when is_list(Diff0), is_list(ReadPairs0), is_list(Effects0) ->
            case quod_wire_term:materialize_symbols(
                   {Diff0, ReadPairs0, Effects0}) of
                {ok, {Diff, ReadPairs, Effects}} ->
                    ReadCheck = maps:from_list(ReadPairs),
                    case map_size(ReadCheck) =:= length(ReadPairs) andalso
                         quod_effect:validate_list(Effects) of
                        true -> {ok, Diff, ReadCheck, Effects};
                        false -> {error, malformed_material}
                    end;
                {error, _} = Error ->
                    Error
            end;
        _ ->
            {error, malformed_material}
    end.

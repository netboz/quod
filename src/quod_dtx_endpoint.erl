-module(quod_dtx_endpoint).
-moduledoc """
Pure v10 wire boundary for durable operation and read-attestation traffic.

The endpoint owns only deterministic framing, bounded atom-safe decoding,
fixed request/response admission, and exact correlation checks. Its view-bound
outcome requests carry a committee id and minimum certified slot; replies carry
the responder's anchored identity and applied floor. The separate group-only
`outcome_barrier` is accepted from the reference's exact coordinator only after
certified-current quorum absence. Applied requests bind one exact Finalize,
generation, and verdict; each validator response carries its signed vote for
the caller to combine into the portable certificate owned by
`quod_dtx_current_view`. Entry hints travel as the canonical ledger entry
bytes; checked entry artifacts carry their local views at this boundary.
Operation-effect cancellation carries the exact
signed source submission; `quod_transaction` remains its sole semantic decoder.
The namespace engine remains responsible for
authenticated-link identity checks, readiness, rate/capacity accounting,
worker monitors, DTX semantics, signing, consensus, and durable state.

One bidirectional channel is derived from the target namespace. Frames carry a
second copy of that namespace in a hard-break envelope. The direction-aware
`decode_request/2` and `decode_response/2` functions bind that copy to the
channel the caller subscribed to. Semantic DTX record bytes stay opaque to
this module. A validation sidecar may carry exact committed entries or applied
certificates beside the semantic term. This module only bounds and shape-checks
them: `quod_foreign_log` verifies entries and `quod_dtx_current_view` verifies
certificates. A one-target remote application carries one canonical certified claim
owned by `quod_transaction`; the target reconstructs its deterministic
application. Both enter the existing target signing and consensus machinery.
The outer request also carries W3C trace context. It is transient metadata,
outside the semantic request, evidence, signatures and correlation checks.
""".

-include("quod_ledger.hrl").
-include("quod_proof_limits.hrl").
-include("quod_transport_limits.hrl").

-export([channel/1,
         encode_request/3, encode_request/4, encode_response/3,
         decode_request/2, decode_response/2,
         encode_validation_sidecar/1, decode_validation_sidecar/1,
         normalize_sidecar/1,
         request_id/1, response_id/1, correlates/2]).
-export_type([request/0, response/0, entry_hint/0, validation_item/0,
              public_outcome_status/0]).

-define(DOMAIN, quod_dtx_endpoint).
-define(VERSION, 10).
-define(CHANNEL_TAG, quod_dtx).
-define(MAX_UINT64, 16#FFFFFFFFFFFFFFFF).

-if(?QUOD_DTX_ENDPOINT_MAX_ENVELOPE_BYTES >= ?QUOD_TRANSPORT_MAX_FRAME_BYTES).
-error("DTX endpoint envelope must stay below the transport frame bound").
-endif.

-type request_id() :: <<_:?QUOD_DTX_ENDPOINT_REQUEST_ID_BITS>>.
-type identity() :: {binary(), <<_:256>>}.
-type group_ref() ::
        {group, binary(), <<_:256>>, <<_:256>>, <<_:256>>, <<_:256>>}.
-type transaction_ref() ::
        {transaction, binary(), <<_:256>>, <<_:256>>}.
-type operation_ref() ::
        {operation, binary(), <<_:256>>, binary(), <<_:256>>}.
-type outcome_ref() :: transaction_ref() | group_ref() | operation_ref().
-type phase_kind() :: 'begin' | prepare | decision | finalize | complete.
-type verdict() :: commit | abort.
-type entry_hint() :: {quod_dtx:certified_ref(), quod_ledger:entry_artifact()}.
-type validation_item() ::
        entry_hint() |
        {{applied, identity(), quod_dtx:certified_ref()},
         quod_dtx_current_view:applied_certificate()}.
-type request() ::
        {submit, request_id(), binary()} |
        {apply_claim, request_id(), binary()} |
        {cancel_operation_effect, request_id(), binary()} |
        {phase, request_id(), <<_:256>>, phase_kind()} |
        {outcome, request_id(), outcome_ref(), <<_:256>>, pos_integer()} |
        {outcome_barrier, request_id(), group_ref(), <<_:256>>,
         pos_integer()} |
        {read_attest, request_id(), binary()} |
        {applied, request_id(), <<_:256>>, quod_dtx:certified_ref(),
         non_neg_integer(), verdict()}.
-type public_outcome_status() :: map().
-type outcome_snapshot() :: not_found | public_outcome_status().
-type barrier_status() :: not_found | pending_begin | coordinator_retired.
-type response() ::
        {accepted, request_id(), <<_:256>>, quod_dtx:certified_ref()} |
        {application, request_id(), committed | {rejected, atom()}, binary()} |
        {operation_effect_cancelled, request_id(), cancelled | not_found} |
        {refused, request_id(), identity(), <<_:256>>, non_neg_integer(),
         binary()} |
        {phase, request_id(), non_neg_integer(),
         not_found | pending | {committed, quod_dtx:certified_ref()}} |
        {outcome, request_id(), identity(), <<_:256>>, non_neg_integer(),
         outcome_snapshot()} |
        {outcome_barrier, request_id(), identity(), <<_:256>>,
         non_neg_integer(), barrier_status()} |
        {read_attest, request_id(), identity(), <<_:256>>, <<_:256>>,
         quod_dtx:certified_ref(), <<_:256>>, <<_:256>>, <<_:512>>} |
        {applied, request_id(), identity(), <<_:256>>, <<_:256>>,
         quod_dtx:certified_ref(), non_neg_integer(), verdict(),
         <<_:256>>, <<_:512>>} |
        {error, request_id(), busy | not_ready | not_found | invalid_request |
         conflict_retry | read_certificate_unavailable}.
-type wire_error() ::
        {error, {too_large, dtx_endpoint | record}} |
        {error, {protocol_error, atom()}}.

%% ------------------------------------------------------------------
%% Channel
%% ------------------------------------------------------------------

-doc "The one bidirectional DTX channel for a target namespace.".
-spec channel(binary()) -> binary().
channel(Namespace) when is_binary(Namespace), byte_size(Namespace) > 0 ->
    term_to_binary({?CHANNEL_TAG, Namespace}, [deterministic]).

%% ------------------------------------------------------------------
%% Deterministic frame API
%% ------------------------------------------------------------------

-spec encode_request(binary(), request(), [validation_item()]) ->
          {ok, binary()} | wire_error().
encode_request(Namespace, Request, Hints) ->
    encode_request(Namespace, Request, Hints, []).

-spec encode_request(binary(), request(), [validation_item()],
                     [{binary(), binary()}]) -> {ok, binary()} | wire_error().
encode_request(Namespace, Request, Hints, TraceCarrier) ->
    encode_direction(Namespace, Request, Hints, TraceCarrier, request).

-spec encode_response(binary(), response(), [validation_item()]) ->
          {ok, binary()} | wire_error().
encode_response(Namespace, Response, Hints) ->
    encode_direction(Namespace, Response, Hints, [], response).

encode_direction(Namespace, Inner, Hints, TraceCarrier, Direction) ->
    case quod_trace:valid_carrier(TraceCarrier) of
        true -> encode_traced_direction(Namespace, Inner, Hints, TraceCarrier, Direction);
        false -> protocol_error(bad_trace_context)
    end.

encode_traced_direction(Namespace, Inner, Hints, TraceCarrier, Direction) ->
    case {valid_namespace(Namespace), validate_direction(Inner, Direction),
          valid_validation_sidecar(Hints)} of
        {true, ok, true} ->
            case encode_validation_sidecar(Hints) of
                {ok, WireHints} ->
                    InnerBinary =
                        term_to_binary({Inner, WireHints}, [deterministic]),
                    Envelope = term_to_binary(
                                 {?DOMAIN, ?VERSION, Namespace, InnerBinary, TraceCarrier},
                                 [deterministic]),
                    case byte_size(Envelope) =<
                         ?QUOD_DTX_ENDPOINT_MAX_ENVELOPE_BYTES of
                        true -> {ok, Envelope};
                        false -> too_large(dtx_endpoint)
                    end;
                error ->
                    protocol_error(bad_hints)
            end;
        {false, _, _} -> protocol_error(bad_namespace);
        {_, {error, _} = Error, _} -> Error;
        {_, _, false} -> protocol_error(bad_hints)
    end.

-doc "Decode a request only for the exact subscribed namespace.".
-spec decode_request(binary(), binary()) ->
          {ok, request(), [validation_item()], [{binary(), binary()}]} | wire_error().
decode_request(Namespace, Envelope) ->
    decode_expected(Namespace, Envelope, request).

-doc "Decode a response only for the exact subscribed namespace.".
-spec decode_response(binary(), binary()) ->
          {ok, response(), [validation_item()]} | wire_error().
decode_response(Namespace, Envelope) ->
    decode_expected(Namespace, Envelope, response).

decode_expected(Namespace, Envelope, Direction) ->
    case valid_namespace(Namespace) of
        true ->
            case decode_direction({expected, Namespace}, Envelope, Direction) of
                {ok, Namespace, Inner, Hints, Carrier} when Direction =:= request ->
                    {ok, Inner, Hints, Carrier};
                {ok, Namespace, Inner, Hints, []} when Direction =:= response ->
                    {ok, Inner, Hints};
                {ok, _, _, _, _} -> protocol_error(bad_trace_context);
                {error, _} = Error -> Error
            end;
        false ->
            protocol_error(bad_namespace)
    end.

decode_direction(Expected, Envelope, Direction)
  when is_binary(Envelope),
       byte_size(Envelope) =< ?QUOD_DTX_ENDPOINT_MAX_ENVELOPE_BYTES ->
    case quod_safe_term:decode(
           Envelope, ?QUOD_DTX_ENDPOINT_MAX_ENVELOPE_BYTES) of
        {ok, {?DOMAIN, ?VERSION, Namespace, InnerBinary, Carrier} = Outer} ->
            case term_to_binary(Outer, [deterministic]) =:= Envelope of
                true ->
                    case quod_trace:valid_carrier(Carrier) of
                        true ->
                            case decode_inner(Expected, Namespace, InnerBinary, Direction) of
                                {ok, Namespace, Inner, Hints} ->
                                    {ok, Namespace, Inner, Hints, Carrier};
                                {error, _} = Error -> Error
                            end;
                        false -> protocol_error(bad_trace_context)
                    end;
                false -> protocol_error(non_canonical)
            end;
        {ok, {?DOMAIN, Version, _Namespace, _InnerBinary, _Carrier}}
          when Version =/= ?VERSION ->
            protocol_error(wrong_version);
        {ok, {Domain, _Version, _Namespace, _InnerBinary, _Carrier}}
          when Domain =/= ?DOMAIN ->
            protocol_error(bad_domain);
        {ok, _Other} ->
            protocol_error(bad_shape);
        {error, _} ->
            protocol_error(bad_etf)
    end;
decode_direction(_Expected, Envelope, _Direction) when is_binary(Envelope) ->
    too_large(dtx_endpoint);
decode_direction(_Expected, _Envelope, _Direction) ->
    protocol_error(bad_etf).

decode_inner(Expected, Namespace, InnerBinary, Direction) ->
    case {valid_namespace(Namespace), namespace_matches(Expected, Namespace),
          is_binary(InnerBinary)} of
        {false, _, _} -> protocol_error(bad_namespace);
        {_, false, _} -> protocol_error(bad_namespace);
        {_, _, false} -> protocol_error(bad_shape);
        {true, true, true} ->
            case quod_safe_term:decode(
                   InnerBinary, ?QUOD_DTX_ENDPOINT_MAX_ENVELOPE_BYTES) of
                {ok, {Inner, RawHints} = Wrapped} ->
                    case term_to_binary(Wrapped, [deterministic]) =:= InnerBinary of
                        false -> protocol_error(non_canonical);
                        true ->
                            case validate_direction(Inner, Direction) of
                                ok ->
                                    {ok, Namespace, Inner,
                                     decode_validation_sidecar(RawHints)};
                                {error, _} = Error -> Error
                            end
                    end;
                {ok, _Other} -> protocol_error(bad_shape);
                {error, _} -> protocol_error(bad_etf)
            end
    end.

namespace_matches({expected, Namespace}, Namespace) -> true;
namespace_matches({expected, _Other}, _Namespace) -> false.

validate_direction(Term, request) -> validate_request(Term);
validate_direction(Term, response) -> validate_response(Term).

%% Hints are deliberately only shape-checked here. Exact-entry authority stays
%% in quod_foreign_log; applied-certificate authority stays in
%% quod_dtx_current_view. A malformed received sidecar becomes no hint and can
%% never change the semantic request or response.
valid_validation_sidecar(Hints) when is_list(Hints) ->
    normalize_sidecar(Hints) =:= Hints;
valid_validation_sidecar(_Hints) ->
    false.

%% The public API uses local decoded views. The wire has one representation
%% for a committed entry: the exact canonical bytes owned by quod_ledger.
-doc "Encode local validation views into the one canonical sidecar wire shape.".
-spec encode_validation_sidecar([validation_item()]) ->
          {ok, [term()]} | error.
encode_validation_sidecar(Hints) ->
    case valid_validation_sidecar(Hints) of
        true -> encode_sidecar(Hints, []);
        false -> error
    end.

encode_sidecar([], Acc) ->
    {ok, lists:reverse(Acc)};
encode_sidecar([{{applied, _, _}, _} = AppliedCertificate | Rest], Acc) ->
    encode_sidecar(Rest, [AppliedCertificate | Acc]);
encode_sidecar([{Ref, Entry} | Rest], Acc) ->
    case quod_ledger:encode_entry(Entry) of
        {ok, EntryBytes} ->
            encode_sidecar(
              Rest, [{entry_bytes, Ref, EntryBytes} | Acc]);
        {error, _} ->
            error
    end;
encode_sidecar(_Improper, _Acc) ->
    error.

-doc "Decode an untrusted canonical sidecar wire shape into local views.".
-spec decode_validation_sidecar(term()) -> [validation_item()].
decode_validation_sidecar(RawHints) when is_list(RawHints) ->
    decode_sidecar(RawHints, []);
decode_validation_sidecar(_Malformed) ->
    [].

decode_sidecar([], Acc) ->
    normalize_sidecar(lists:reverse(Acc));
decode_sidecar([{entry_bytes, Ref, EntryBytes} | Rest], Acc)
  when is_binary(EntryBytes) ->
    %% These are acceleration hints for foreign-reference verification, not
    %% target-owned execution. Local references use the owner's ledger view;
    %% no sidecar may allocate a foreign ontology's callable vocabulary.
    case quod_ledger:decode_entry(EntryBytes, wrapped) of
        {ok, Entry} -> decode_sidecar(Rest, [{Ref, Entry} | Acc]);
        {error, _} -> decode_sidecar(Rest, Acc)
    end;
decode_sidecar([{{applied, _, _}, _} = AppliedCertificate | Rest], Acc) ->
    case valid_validation_item(AppliedCertificate) of
        true -> decode_sidecar(Rest, [AppliedCertificate | Acc]);
        false -> decode_sidecar(Rest, Acc)
    end;
decode_sidecar([_Invalid | Rest], Acc) ->
    %% Entry artifacts are local data, never another accepted wire shape.
    %% Only entry_bytes above may mint one from an untrusted sidecar.
    decode_sidecar(Rest, Acc);
decode_sidecar(_Improper, _Acc) ->
    [].

-doc "Normalize one untrusted bounded validation sidecar; malformed rows disappear.".
-spec normalize_sidecar(term()) -> [validation_item()].
normalize_sidecar(Hints) when is_list(Hints) ->
    normalize_sidecar(Hints, #{}, []);
normalize_sidecar(_Malformed) ->
    [].

normalize_sidecar([], _Seen, Acc) ->
    lists:reverse(Acc);
normalize_sidecar([Hint = {Key, _Value} | Rest], Seen, Acc) ->
    case valid_validation_item(Hint) andalso not maps:is_key(Key, Seen) of
        true -> normalize_sidecar(Rest, Seen#{Key => true}, [Hint | Acc]);
        false -> normalize_sidecar(Rest, Seen, Acc)
    end;
normalize_sidecar(_Improper, _Seen, _Acc) ->
    [].

valid_entry_hint({Ref, Entry}) ->
    View = try quod_ledger:entry_view(Entry)
           catch error:_ -> invalid
           end,
    valid_entry_hint_view(Ref, Entry, View).

valid_entry_hint_view(Ref, Entry, #entry{index = Slot}) ->
    quod_dtx:validate_certified_ref(Ref) andalso
        case quod_dtx:certified_ref_binding(Ref) of
            {ok, _Identity, Slot, _Digest} ->
                case quod_catchup:page_stats([Entry]) of
                    {ok, 1, _Bytes} -> true;
                    {error, _} -> false
                end;
            _ ->
                false
        end;
valid_entry_hint_view(_Ref, _Entry, _View) -> false.

valid_validation_item(
  {{applied, Target, FinalizeRef}, Certificate}) ->
    case quod_dtx_current_view:applied_certificate_binding(Certificate) of
        {ok, #{target := Target, finalize_ref := FinalizeRef}} -> true;
        _ -> false
    end;
valid_validation_item({Ref, _Entry} = Hint) ->
    quod_dtx:validate_certified_ref(Ref) andalso valid_entry_hint(Hint).

%% ------------------------------------------------------------------
%% Fixed v9 operation algebra
%% ------------------------------------------------------------------

validate_request({submit, RequestId, RecordBlob}) ->
    case valid_request_id(RequestId) of
        false -> protocol_error(bad_request_id);
        true -> validate_record_blob(RecordBlob)
    end;
validate_request({apply_claim, RequestId, EvidenceBlob}) ->
    validate_request_fields(
      RequestId, valid_claim_evidence(EvidenceBlob));
validate_request({phase, RequestId, GroupId, Kind}) ->
    validate_request_fields(
      RequestId, valid_digest(GroupId) andalso valid_phase_kind(Kind));
validate_request(
  {cancel_operation_effect, RequestId, SubmissionBlob}) ->
    validate_request_fields(
      RequestId, valid_operation_submission(SubmissionBlob));
validate_request(
  {outcome, RequestId, OutcomeRef, CommitteeId, MinimumSlot}) ->
    validate_request_fields(
      RequestId,
      valid_outcome_ref(OutcomeRef) andalso valid_digest(CommitteeId) andalso
          valid_slot(MinimumSlot));
validate_request(
  {outcome_barrier, RequestId, GroupRef, CommitteeId, MinimumSlot}) ->
    validate_request_fields(
      RequestId,
      valid_group_ref(GroupRef) andalso valid_digest(CommitteeId) andalso
          valid_slot(MinimumSlot));
validate_request({read_attest, RequestId, PlanBlob}) ->
    validate_request_fields(RequestId, valid_read_plan(PlanBlob));
validate_request(
  {applied, RequestId, GroupId, FinalizeRef, Generation, Verdict}) ->
    validate_request_fields(
      RequestId,
      valid_digest(GroupId) andalso valid_certified_ref(FinalizeRef) andalso
          valid_uint64(Generation) andalso valid_verdict(Verdict));
validate_request(_) ->
    protocol_error(bad_shape).

validate_request_fields(RequestId, FieldsValid) ->
    case {valid_request_id(RequestId), FieldsValid} of
        {true, true} -> ok;
        {false, _} -> protocol_error(bad_request_id);
        {_, false} -> protocol_error(bad_shape)
    end.

validate_record_blob(RecordBlob) ->
    case quod_dtx:decode_record(RecordBlob) of
        {ok, _Record} -> ok;
        {error, {too_large, dtx_body}} -> too_large(record);
        {error, _} -> protocol_error(bad_record)
    end.

%% The endpoint owns only the fixed request shape and outer envelope bound.
%% The target engine invokes the transaction codec exactly once after its
%% authenticated peer/readiness checks; this framing layer never parses or
%% verifies the signed submission a second time.
valid_operation_submission(SubmissionBlob) when is_binary(SubmissionBlob) ->
    byte_size(SubmissionBlob) > 0 andalso
        byte_size(SubmissionBlob) < ?QUOD_DTX_ENDPOINT_MAX_ENVELOPE_BYTES;
valid_operation_submission(_SubmissionBlob) ->
    false.

validate_response({accepted, RequestId, SemanticDigest, CertifiedRef}) ->
    validate_response_fields(
      RequestId,
      valid_digest(SemanticDigest) andalso
          certified_ref_digest(CertifiedRef) =:= SemanticDigest);
validate_response({application, RequestId, Result, EvidenceBlob}) ->
    validate_response_fields(
      RequestId,
      valid_application_result(Result) andalso
          valid_application_evidence(EvidenceBlob));
validate_response(
  {operation_effect_cancelled, RequestId, Status}) ->
    validate_response_fields(
      RequestId, Status =:= cancelled orelse Status =:= not_found);
validate_response(
  {refused, RequestId, TargetIdentity, SemanticDigest, Generation,
   ReasonsBlob}) ->
    validate_response_fields(
      RequestId,
      valid_identity(TargetIdentity) andalso valid_digest(SemanticDigest) andalso
          valid_uint64(Generation) andalso
          valid_refusal_reasons(TargetIdentity, ReasonsBlob));
validate_response({phase, RequestId, Generation, Phase}) ->
    validate_response_fields(
      RequestId, valid_uint64(Generation) andalso valid_phase_response(Phase));
validate_response(
  {outcome, RequestId, TargetIdentity, CommitteeId, AppliedFloor,
   Outcome}) ->
    validate_response_fields(
      RequestId,
      valid_identity(TargetIdentity) andalso valid_digest(CommitteeId) andalso
          valid_uint64(AppliedFloor) andalso valid_outcome_snapshot(Outcome));
validate_response(
  {outcome_barrier, RequestId, TargetIdentity, CommitteeId, AppliedFloor,
   Status}) ->
    validate_response_fields(
      RequestId,
      valid_identity(TargetIdentity) andalso valid_digest(CommitteeId) andalso
          valid_uint64(AppliedFloor) andalso valid_barrier_status(Status));
validate_response(
  {read_attest, RequestId, TargetIdentity, ProofId, PlanDigest, AnchorRef,
   CommitteeId, Signer, Signature}) ->
    validate_response_fields(
      RequestId,
      valid_identity(TargetIdentity) andalso valid_digest(ProofId) andalso
          valid_digest(PlanDigest) andalso valid_certified_ref(AnchorRef) andalso
          certified_ref_identity(AnchorRef) =:= TargetIdentity andalso
          valid_digest(CommitteeId) andalso
          valid_digest(Signer) andalso is_binary(Signature) andalso
          byte_size(Signature) =:= 64);
validate_response(
  {applied, RequestId, TargetIdentity, CommitteeId, GroupId, FinalizeRef,
   Generation, Verdict, Signer, Signature}) ->
    validate_response_fields(
      RequestId,
      valid_identity(TargetIdentity) andalso valid_digest(CommitteeId) andalso
          valid_digest(GroupId) andalso valid_certified_ref(FinalizeRef) andalso
          valid_uint64(Generation) andalso valid_verdict(Verdict) andalso
          valid_digest(Signer) andalso is_binary(Signature) andalso
          byte_size(Signature) =:= 64);
validate_response({error, RequestId, Reason}) ->
    validate_response_fields(RequestId, valid_error_reason(Reason));
validate_response(_) ->
    protocol_error(bad_shape).

validate_response_fields(RequestId, FieldsValid) ->
    case {valid_request_id(RequestId), FieldsValid} of
        {true, true} -> ok;
        {false, _} -> protocol_error(bad_request_id);
        {_, false} -> protocol_error(bad_shape)
    end.

valid_phase_response(not_found) -> true;
valid_phase_response(pending) -> true;
valid_phase_response({committed, Ref}) -> valid_certified_ref(Ref);
valid_phase_response(_) -> false.

valid_outcome_snapshot(not_found) -> true;
valid_outcome_snapshot(Status) -> valid_public_outcome_status(Status).

valid_barrier_status(not_found) -> true;
valid_barrier_status(pending_begin) -> true;
valid_barrier_status(coordinator_retired) -> true;
valid_barrier_status(_) -> false.

%% These are the exact bounded maps exposed by quod_outcome:public/1. The
%% derived pre-Begin retirement classification has no ledger height.
valid_public_outcome_status(
  #{status := pending, ref := TransactionRef} = Status)
  when map_size(Status) =:= 2 ->
    valid_transaction_ref(TransactionRef);
valid_public_outcome_status(
  #{status := committed, height := Height, ref := TransactionRef} = Status)
  when map_size(Status) =:= 3 ->
    valid_slot(Height) andalso valid_transaction_ref(TransactionRef);
valid_public_outcome_status(
  #{status := rejected, reason := Reason, height := Height,
    ref := TransactionRef} = Status)
  when map_size(Status) =:= 4 ->
    is_atom(Reason) andalso valid_slot(Height) andalso
        valid_transaction_ref(TransactionRef);
valid_public_outcome_status(
  #{status := pending, phase := Phase, ref := GroupRef} = Status)
  when map_size(Status) =:= 3 ->
    valid_pending_phase(Phase) andalso valid_group_ref(GroupRef);
valid_public_outcome_status(
  #{status := committed, height := Height, ref := GroupRef,
    bindings := Bindings, participant_slots := Slots} = Status)
  when map_size(Status) =:= 5 ->
    valid_slot(Height) andalso valid_group_ref(GroupRef) andalso
        valid_bindings(Bindings) andalso valid_participant_slots(Slots);
valid_public_outcome_status(
  #{status := aborted, height := Height, ref := GroupRef,
    reasons := Reasons, participant_slots := Slots} = Status)
  when map_size(Status) =:= 5 ->
    valid_slot(Height) andalso valid_group_ref(GroupRef) andalso
        quod_wire_term:valid_failure_reason_stack(Reasons) andalso
        valid_participant_slots(Slots);
valid_public_outcome_status(
  #{status := rejected, reason := coordinator_retired,
    ref := GroupRef} = Status)
  when map_size(Status) =:= 3 ->
    valid_group_ref(GroupRef);
valid_public_outcome_status(
  #{status := claimed, height := Height, ref := OperationRef,
    request_digest := RequestDigest, outcome_ref := OutcomeRef,
    operation_state := OperationState} = Status)
  when map_size(Status) =:= 6 ->
    valid_slot(Height) andalso valid_operation_ref(OperationRef) andalso
        is_binary(RequestDigest) andalso byte_size(RequestDigest) =:= 32 andalso
        valid_operation_state(OperationState) andalso
        valid_outcome_ref(OutcomeRef);
valid_public_outcome_status(_) ->
    false.

valid_operation_state(unresolved) -> true;
valid_operation_state(terminal) -> true;
valid_operation_state(_) -> false.

valid_pending_phase(pending_begin) -> true;
valid_pending_phase(begun) -> true;
valid_pending_phase(finalizing_commit) -> true;
valid_pending_phase(finalizing_abort) -> true;
valid_pending_phase(publication) -> true;
valid_pending_phase(_) -> false.

valid_bindings(Bindings) when is_list(Bindings) ->
    valid_binding_names(Bindings, none) andalso
        quod_wire_term:encode(Bindings) =/= {error, bad_term};
valid_bindings(_) -> false.

valid_binding_names([], _Previous) -> true;
valid_binding_names([{Name, _Value} | Rest], Previous)
  when is_binary(Name), byte_size(Name) > 0,
       (Previous =:= none orelse Previous < Name) ->
    valid_binding_names(Rest, Name);
valid_binding_names(_, _) -> false.

valid_participant_slots(Slots) ->
    valid_participant_slots(Slots, none, 0).

valid_participant_slots([], _Previous, Count) -> Count >= 2;
valid_participant_slots([{Identity, Slot, Generation} | Rest], Previous, Count)
  when Count < ?QUOD_MAX_DTX_PARTICIPANTS,
       (Previous =:= none orelse Previous < Identity),
       is_integer(Slot), Slot > 0, Slot =< ?MAX_UINT64,
       is_integer(Generation), Generation >= 0,
       Generation =< ?MAX_UINT64 ->
    valid_identity(Identity) andalso
        valid_participant_slots(Rest, Identity, Count + 1);
valid_participant_slots(_, _, _) -> false.

%% ------------------------------------------------------------------
%% Correlation helpers
%% ------------------------------------------------------------------

-spec request_id(term()) -> request_id() | error.
request_id({submit, RequestId, _}) -> valid_id_or_error(RequestId);
request_id({apply_claim, RequestId, _}) -> valid_id_or_error(RequestId);
request_id({cancel_operation_effect, RequestId, _}) ->
    valid_id_or_error(RequestId);
request_id({phase, RequestId, _, _}) -> valid_id_or_error(RequestId);
request_id({outcome, RequestId, _, _, _}) -> valid_id_or_error(RequestId);
request_id({outcome_barrier, RequestId, _, _, _}) ->
    valid_id_or_error(RequestId);
request_id({read_attest, RequestId, _}) -> valid_id_or_error(RequestId);
request_id({applied, RequestId, _, _, _, _}) -> valid_id_or_error(RequestId);
request_id(_) -> error.

-spec response_id(term()) -> request_id() | error.
response_id({accepted, RequestId, _, _}) -> valid_id_or_error(RequestId);
response_id({application, RequestId, _, _}) -> valid_id_or_error(RequestId);
response_id({operation_effect_cancelled, RequestId, _}) ->
    valid_id_or_error(RequestId);
response_id({refused, RequestId, _, _, _, _}) ->
    valid_id_or_error(RequestId);
response_id({phase, RequestId, _, _}) -> valid_id_or_error(RequestId);
response_id({outcome, RequestId, _, _, _, _}) -> valid_id_or_error(RequestId);
response_id({outcome_barrier, RequestId, _, _, _, _}) ->
    valid_id_or_error(RequestId);
response_id({read_attest, RequestId, _, _, _, _, _, _, _}) ->
    valid_id_or_error(RequestId);
response_id({applied, RequestId, _, _, _, _, _, _, _, _}) ->
    valid_id_or_error(RequestId);
response_id({error, RequestId, _}) -> valid_id_or_error(RequestId);
response_id(_) -> error.

valid_id_or_error(RequestId) ->
    case valid_request_id(RequestId) of
        true -> RequestId;
        false -> error
    end.

-doc "Match a decoded response to the exact decoded request it can answer.".
-spec correlates(term(), term()) -> boolean().
correlates(Request, {error, RequestId, _} = Response) ->
    valid_pair(Request, Response) andalso request_id(Request) =:= RequestId;
correlates({submit, RequestId, RecordBlob} = Request,
           {accepted, RequestId, SemanticDigest, CertifiedRef} = Response) ->
    valid_pair(Request, Response) andalso
        record_blob_digest(RecordBlob) =:= SemanticDigest andalso
        certified_ref_digest(CertifiedRef) =:= SemanticDigest;
correlates({submit, RequestId, RecordBlob} = Request,
           {refused, RequestId, _, SemanticDigest, _, _} = Response) ->
    valid_pair(Request, Response) andalso
        prepare_blob_digest(RecordBlob) =:= SemanticDigest;
correlates(
  {apply_claim, RequestId, ClaimEvidence} = Request,
  {application, RequestId, _Result, TargetEvidence} = Response) ->
    valid_pair(Request, Response) andalso
        application_response_matches(ClaimEvidence, TargetEvidence);
correlates(
  {cancel_operation_effect, RequestId, _} = Request,
  {operation_effect_cancelled, RequestId, _} = Response) ->
    valid_pair(Request, Response);
correlates({phase, RequestId, _, _} = Request,
           {phase, RequestId, _, _} = Response) ->
    valid_pair(Request, Response);
correlates(
  {outcome, RequestId, OutcomeRef, CommitteeId, MinimumSlot} = Request,
  {outcome, RequestId, TargetIdentity, CommitteeId, AppliedFloor,
   Outcome} = Response) ->
    valid_pair(Request, Response) andalso AppliedFloor >= MinimumSlot andalso
        quod_outcome:ref_identity(OutcomeRef) =:= {ok, TargetIdentity} andalso
        outcome_matches_ref(Outcome, OutcomeRef);
correlates(
  {outcome_barrier, RequestId, GroupRef, CommitteeId,
   MinimumSlot} = Request,
  {outcome_barrier, RequestId, TargetIdentity, CommitteeId, AppliedFloor,
   _Status} = Response) ->
    valid_pair(Request, Response) andalso AppliedFloor >= MinimumSlot andalso
        quod_outcome:ref_identity(GroupRef) =:= {ok, TargetIdentity};
correlates(
  {read_attest, RequestId, PlanBlob} = Request,
  {read_attest, RequestId, TargetIdentity, ProofId, PlanDigest, AnchorRef,
   _CommitteeId, _Signer, _Signature} = Response) ->
    valid_pair(Request, Response) andalso
        case quod_dtx:decode(PlanBlob) of
            {ok, Plan} ->
                quod_dtx:target(Plan) =:= TargetIdentity andalso
                    quod_dtx:proof_id(Plan) =:= ProofId andalso
                    quod_dtx:digest(Plan) =:= PlanDigest andalso
                    certified_ref_identity(AnchorRef) =:= TargetIdentity;
            {error, _} -> false
        end;
correlates(
  {applied, RequestId, GroupId, FinalizeRef, Generation, Verdict} = Request,
  {applied, RequestId, _TargetIdentity, _CommitteeId, GroupId, FinalizeRef,
   Generation, Verdict, _Signer, _Signature} = Response) ->
    valid_pair(Request, Response);
correlates(_Request, _Response) ->
    false.

valid_pair(Request, Response) ->
    validate_request(Request) =:= ok andalso validate_response(Response) =:= ok.

outcome_matches_ref(not_found, _OutcomeRef) -> true;
outcome_matches_ref(#{ref := OutcomeRef}, OutcomeRef) -> true;
outcome_matches_ref(_Outcome, _OutcomeRef) -> false.

record_blob_digest(RecordBlob) ->
    case quod_dtx:decode_record(RecordBlob) of
        {ok, Record} -> quod_dtx:record_digest(Record);
        {error, _} -> error
    end.

prepare_blob_digest(RecordBlob) ->
    case quod_dtx:decode_record(RecordBlob) of
        {ok, {quod_dtx_prepare, 3, _, _, _, _, _} = Record} ->
            quod_dtx:record_digest(Record);
        _ ->
            error
    end.

valid_claim_evidence(Blob) ->
    case quod_transaction:decode_evidence(Blob) of
        {ok, ClaimRef,
         #transaction{role = {remote_claim, _, _, _}} = Claim} ->
            case quod_transaction:stable_ref(ClaimRef) of
                {transaction, _, _, _} = StableRef ->
                    try quod_transaction:remote_application(
                          StableRef, Claim) of
                        #transaction{} -> true
                    catch _:_ -> false
                    end;
                invalid -> false
            end;
        _ -> false
    end.

valid_read_plan(PlanBlob) when is_binary(PlanBlob) ->
    case quod_dtx:decode(PlanBlob) of
        {ok, Plan} -> quod_dtx:verify(Plan);
        {error, _} -> false
    end;
valid_read_plan(_PlanBlob) ->
    false.

certified_ref_identity(Ref) ->
    case quod_dtx:certified_ref_binding(Ref) of
        {ok, Identity, _Slot, _Digest} -> Identity;
        _ -> error
    end.

valid_application_evidence(Blob) ->
    case quod_transaction:decode_evidence(Blob) of
        {ok, _Ref, #transaction{role = {remote_application, _, _, _}}} ->
            true;
        _ -> false
    end.

valid_application_result(committed) -> true;
valid_application_result({rejected, Reason}) when is_atom(Reason) -> true;
valid_application_result(_) -> false.

application_response_matches(ClaimBlob, TargetBlob) ->
    case {quod_transaction:decode_evidence(ClaimBlob),
          quod_transaction:decode_evidence(TargetBlob)} of
        {{ok, ClaimRef, #transaction{} = Claim},
         {ok, _TargetRef, #transaction{} = TargetTx}} ->
            case quod_transaction:stable_ref(ClaimRef) of
                {transaction, _, _, _} = StableRef ->
                    try quod_transaction:remote_application(
                          StableRef, Claim) of
                        Expected ->
                            Expected#transaction.tx_id =:=
                                TargetTx#transaction.tx_id
                    catch _:_ -> false
                    end;
                invalid -> false
            end;
        _ -> false
    end.

%% ------------------------------------------------------------------
%% Scalar validation
%% ------------------------------------------------------------------

valid_namespace(Namespace) ->
    is_binary(Namespace) andalso byte_size(Namespace) > 0.

valid_request_id(RequestId) ->
    is_binary(RequestId) andalso
        bit_size(RequestId) =:= ?QUOD_DTX_ENDPOINT_REQUEST_ID_BITS.

valid_digest(<<_:256>>) -> true;
valid_digest(_) -> false.

valid_identity({Namespace, Anchor}) ->
    valid_namespace(Namespace) andalso valid_digest(Anchor);
valid_identity(_) -> false.

valid_group_ref(
  {group, Namespace, Anchor, Coordinator, Admission, GroupId}) ->
    valid_namespace(Namespace) andalso valid_digest(Anchor) andalso
        valid_digest(Coordinator) andalso valid_digest(Admission) andalso
        valid_digest(GroupId);
valid_group_ref(_) -> false.

valid_transaction_ref(
  {transaction, Ns, <<_:256>>, <<_:256>>}) ->
    valid_namespace(Ns);
valid_transaction_ref(_) -> false.

valid_operation_ref(
  {operation, Ns, <<_:256>>, AgentRef, <<_:256>>}) ->
    valid_namespace(Ns) andalso
        quod_agent_ref:valid_principal({agent, AgentRef});
valid_operation_ref(_) -> false.

valid_outcome_ref(Ref) ->
    valid_transaction_ref(Ref) orelse valid_group_ref(Ref) orelse
        valid_operation_ref(Ref).

valid_certified_ref(Ref) -> quod_dtx:validate_certified_ref(Ref).

certified_ref_digest(Ref) ->
    case quod_dtx:certified_ref_binding(Ref) of
        {ok, _Identity, _Slot, Digest} -> Digest;
        error -> error
    end.

valid_phase_kind('begin') -> true;
valid_phase_kind(prepare) -> true;
valid_phase_kind(decision) -> true;
valid_phase_kind(finalize) -> true;
valid_phase_kind(complete) -> true;
valid_phase_kind(_) -> false.

valid_verdict(commit) -> true;
valid_verdict(abort) -> true;
valid_verdict(_) -> false.

valid_slot(Slot) ->
    is_integer(Slot) andalso Slot > 0 andalso Slot =< ?MAX_UINT64.

valid_uint64(Integer) ->
    is_integer(Integer) andalso Integer >= 0 andalso Integer =< ?MAX_UINT64.

%% Keep ontology-local atoms inside the established wire alphabet.  The blob
%% must be the canonical encoding of the target marker followed by at least one
%% actual reason; a transient endpoint error is represented by `{error, ...}`.
valid_refusal_reasons({Ns, Anchor}, ReasonsBlob) ->
    case quod_wire_term:decode_failure_reasons(ReasonsBlob) of
        {ok, [{prepare_refused, {ontology, Ns, Anchor}}, _Actual | _]} -> true;
        _ -> false
    end.

valid_error_reason(busy) -> true;
valid_error_reason(not_ready) -> true;
valid_error_reason(not_found) -> true;
valid_error_reason(invalid_request) -> true;
valid_error_reason(conflict_retry) -> true;
valid_error_reason(read_certificate_unavailable) -> true;
valid_error_reason(_) -> false.

too_large(Kind) -> {error, {too_large, Kind}}.
protocol_error(Reason) -> {error, {protocol_error, Reason}}.

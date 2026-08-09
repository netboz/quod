-module(quod_scope_wire).
-moduledoc """
Pure hard-break codec for one distributed proof-scope session.

The deterministic ETF envelope contains exact fixed metadata plus opaque
payload binaries.  In particular, decoding an invocation command does not
decode its goal: callers authenticate the link and validate identities,
sequences, quotas, and readiness before calling `decode_payload(goal, Blob)`.

`OverlayGeneration` is a monotonic wire integer, never the local
`quod_erlog_db_local_prove:revision()` containing overlay/ETS state.  Every
target event carries both the exact generation and the exact current dirty
boolean.  This module owns no process, connection, timer, or proof state.

Commands carry remaining milliseconds, not a sender-local monotonic timestamp.
The target later derives and clamps its own deadline; another command must not
renew the scope lifetime.
""".

-include("quod_proof_limits.hrl").
-include("quod_transport_limits.hrl").
-include_lib("erlog/src/erlog_int.hrl").

-export([request_channel/1, return_channel/1,
         encode_identity_probe/1, encode_identity_response/1,
         encode_command/1, encode_event/1,
         decode_request/1, decode_response/1,
         encode_payload/2, decode_payload/2,
         valid_public_error/1, scope_error_matches_target/2,
         normalize_public_error/2]).
-export_type([binding/0, command/0, event/0, payload_kind/0]).

-define(DOMAIN, <<"quod.scope">>).
-define(VERSION, 2).
-define(REQUEST_CHANNEL_TAG, quod_scope).
-define(RETURN_CHANNEL_TAG, quod_scope_return).
-define(IDENTITY_DOMAIN, <<"quod.scope.identity">>).

-if(?QUOD_SCOPE_WIRE_MAX_ENVELOPE_BYTES >= ?QUOD_TRANSPORT_MAX_FRAME_BYTES).
-error("scope envelope must stay below the transport frame bound").
-endif.

-type key() :: <<_:?QUOD_SCOPE_WIRE_KEY_BITS>>.
-type opaque_id() :: <<_:?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS>>.
-type lineage() :: none | opaque_id().
-type selection() :: {tx_selection, lineage(), [opaque_id()]}.
-type identity() :: {binary(), key()}.
-type binding() ::
        {scope_binding, key(), key(),
         <<_:?QUOD_SCOPE_WIRE_PROOF_ID_BITS>>, opaque_id(),
         identity(), identity(), read_write | read_only}.
-type command_operation() ::
        scope_open | scope_close | scope_seal |
        {submit_plan, binary(), binary(), binary(), [{binary(), binary()}]} |
        {invoke_open, opaque_id(), selection(), [identity()], binary()} |
        {invoke_next, opaque_id(), pos_integer()} |
        {invoke_cancel, opaque_id()} |
        {nested_opened, opaque_id(), opaque_id()} |
        {nested_solution | nested_complete | nested_erlog_error,
         opaque_id(), opaque_id(), pos_integer(), binary()} |
        {nested_error, opaque_id(), term()} |
        {tx_activated, opaque_id(), opaque_id(),
         [{opaque_id(), opaque_id(), opaque_id(), opaque_id()}]} |
        {tx_finished, opaque_id(), lineage()} |
        {savepoint_allocated, opaque_id(), opaque_id()} |
        {savepoint_restored, opaque_id(), [opaque_id()]} |
        {materialize, opaque_id(), opaque_id(), opaque_id(), [opaque_id()]} |
        {batch_restore | batch_release, [opaque_id()]} |
        {controller_error, opaque_id(), term()}.
-type event_operation() ::
        {scope_opened, non_neg_integer()} | scope_closed |
        {plan_sealed, binary()} | plan_not_material |
        {plan_submitted, {committed, pos_integer(), binary()} |
                         {rejected, atom()} |
                         {outcome_unknown,
                          {transaction, binary(), binary(), binary()}}} |
        {invocation_opened, opaque_id()} |
        {solution | complete | erlog_error,
         opaque_id(), pos_integer(), binary()} |
        {invocation_error, opaque_id(), pos_integer(), term()} |
        {scope_error, term()} |
        {nested_open, opaque_id(), binary(), [identity()], binary()} |
        {nested_next, opaque_id(), opaque_id(), pos_integer()} |
        {nested_cancel, opaque_id(), opaque_id()} |
        {tx_activate, opaque_id(), opaque_id(), lineage(), [opaque_id()]} |
        {tx_finish, opaque_id(), opaque_id(), opaque_id(), opaque_id(),
         finish | discard} |
        {savepoint_allocate, opaque_id(), opaque_id(), opaque_id()} |
        {savepoint_restore, opaque_id(), opaque_id(), opaque_id(),
         [opaque_id()]} |
        {materialized, opaque_id(), [opaque_id()]} |
        {batch_restored | batch_released, [opaque_id()]}.
-type command() ::
        {scope_command, binding(), pos_integer(), opaque_id(),
         non_neg_integer(), command_operation()}.
-type event() ::
        {scope_event, binding(), pos_integer(), opaque_id(), pos_integer(),
         non_neg_integer(), boolean(), event_operation()}.
-type payload_kind() ::
        goal | answer | failure_reasons | erlog_error | plan | result.
-type wire_error() ::
        {error, {too_large, scope_envelope | payload_kind()}} |
        {error, {protocol_error, atom()}}.

-type identity_probe() ::
        {scope_identity_probe, opaque_id(), key(), binary()}.
-type identity_response() ::
        {scope_identity_response, opaque_id(), key(), identity(),
         validator | observer}.

%% ------------------------------------------------------------------
%% One hard-break transport namespace
%% ------------------------------------------------------------------

-spec request_channel(binary()) -> binary().
request_channel(Namespace) when is_binary(Namespace) ->
    term_to_binary({?REQUEST_CHANNEL_TAG, Namespace}, [deterministic]).

-spec return_channel(key()) -> binary().
return_channel(<<_:?QUOD_SCOPE_WIRE_KEY_BITS>> = OriginKey) ->
    term_to_binary({?RETURN_CHANNEL_TAG, OriginKey}, [deterministic]).

-spec encode_identity_probe(identity_probe()) ->
          {ok, binary()} | wire_error().
encode_identity_probe(Probe) ->
    encode_identity_frame(Probe, validate_identity_probe(Probe)).

-spec encode_identity_response(identity_response()) ->
          {ok, binary()} | wire_error().
encode_identity_response(Response) ->
    encode_identity_frame(Response, validate_identity_response(Response)).

encode_identity_frame(Frame, ok) ->
    Encoded = term_to_binary(
                {?IDENTITY_DOMAIN, ?VERSION, Frame}, [deterministic]),
    case byte_size(Encoded) =< ?QUOD_SCOPE_WIRE_MAX_ENVELOPE_BYTES of
        true -> {ok, Encoded};
        false -> too_large(scope_envelope)
    end;
encode_identity_frame(_Frame, {error, _} = Error) ->
    Error.

validate_identity_probe(
  {scope_identity_probe, RequestId, OriginKey, Namespace}) ->
    case {valid_id(RequestId), valid_key(OriginKey),
          valid_namespace(Namespace)} of
        {true, true, true} -> ok;
        {false, _, _} -> protocol_error(bad_id);
        {_, false, _} -> protocol_error(bad_binding);
        {_, _, false} -> protocol_error(bad_identity)
    end;
validate_identity_probe(_) ->
    protocol_error(bad_shape).

validate_identity_response(
  {scope_identity_response, RequestId, TargetKey, TargetIdentity, Role}) ->
    case {valid_id(RequestId), valid_key(TargetKey),
          valid_identity(TargetIdentity), valid_role(Role)} of
        {true, true, true, true} -> ok;
        {false, _, _, _} -> protocol_error(bad_id);
        {_, false, _, _} -> protocol_error(bad_binding);
        {_, _, false, _} -> protocol_error(bad_identity);
        {_, _, _, false} -> protocol_error(bad_role)
    end;
validate_identity_response(_) ->
    protocol_error(bad_shape).

%% ------------------------------------------------------------------
%% Exact envelope API
%% ------------------------------------------------------------------

-spec encode_command(command()) -> {ok, binary()} | wire_error().
encode_command(Command) ->
    case validate_command(Command) of
        ok -> encode_envelope(Command);
        {error, _} = Error -> Error
    end.

-spec encode_event(event()) -> {ok, binary()} | wire_error().
encode_event(Event) ->
    case validate_event(Event) of
        ok -> encode_envelope(Event);
        {error, _} = Error -> Error
    end.

-spec decode_request(binary()) ->
          {ok, identity_probe() | command()} | wire_error().
decode_request(Encoded) ->
    decode_frame(Encoded, request).

-spec decode_response(binary()) ->
          {ok, identity_response() | event()} | wire_error().
decode_response(Encoded) ->
    decode_frame(Encoded, response).

validate_command(
  {scope_command, Binding, CommandSeq, RequestId, RemainingMs, Operation}) ->
    case {validate_binding(Binding), valid_sequence(CommandSeq),
          valid_id(RequestId), valid_uint64(RemainingMs),
          validate_command_operation(Operation)} of
        {ok, true, true, true, ok} -> ok;
        {{error, _} = Error, _, _, _, _} -> Error;
        {_, false, _, _, _} -> protocol_error(bad_sequence);
        {_, _, false, _, _} -> protocol_error(bad_id);
        {_, _, _, false, _} -> protocol_error(bad_budget);
        {_, _, _, _, {error, _} = Error} -> Error
    end;
validate_command(_) -> protocol_error(bad_shape).

validate_event(
  {scope_event, Binding, EventSeq, RequestId, AcceptedCommandSeq,
   OverlayGeneration, Dirty, Operation}) ->
    case {validate_binding(Binding), valid_sequence(EventSeq),
          valid_id(RequestId), valid_sequence(AcceptedCommandSeq),
          valid_uint64(OverlayGeneration), is_boolean(Dirty),
          validate_event_operation(Operation)} of
        {ok, true, true, true, true, true, ok} -> ok;
        {{error, _} = Error, _, _, _, _, _, _} -> Error;
        {_, false, _, _, _, _, _} -> protocol_error(bad_sequence);
        {_, _, false, _, _, _, _} -> protocol_error(bad_id);
        {_, _, _, false, _, _, _} -> protocol_error(bad_sequence);
        {_, _, _, _, false, _, _} -> protocol_error(bad_generation);
        {_, _, _, _, _, false, _} -> protocol_error(bad_dirty);
        {_, _, _, _, _, _, {error, _} = Error} -> Error
    end;
validate_event(_) -> protocol_error(bad_shape).

encode_envelope(Frame) ->
    Encoded = term_to_binary({?DOMAIN, ?VERSION, Frame}, [deterministic]),
    case byte_size(Encoded) =< ?QUOD_SCOPE_WIRE_MAX_ENVELOPE_BYTES of
        true -> {ok, Encoded};
        false -> too_large(scope_envelope)
    end.

decode_frame(Encoded, Direction)
  when is_binary(Encoded),
       byte_size(Encoded) =< ?QUOD_SCOPE_WIRE_MAX_ENVELOPE_BYTES ->
    case quod_safe_term:decode(
           Encoded, ?QUOD_SCOPE_WIRE_MAX_ENVELOPE_BYTES) of
        {ok, {Domain, Version, Frame}} ->
            decode_frame_term(Domain, Version, Frame, Direction);
        {ok, _} -> protocol_error(bad_shape);
        {error, _} -> protocol_error(bad_etf)
    end;
decode_frame(Encoded, _Direction) when is_binary(Encoded) ->
    too_large(scope_envelope);
decode_frame(_, _) -> protocol_error(bad_etf).

decode_frame_term(Domain, Version, _Frame, _Direction)
  when (Domain =:= ?DOMAIN orelse Domain =:= ?IDENTITY_DOMAIN),
       Version =/= ?VERSION ->
    protocol_error(wrong_version);
decode_frame_term(?IDENTITY_DOMAIN, ?VERSION, Frame, Direction) ->
    validate_identity_frame(Frame, Direction);
decode_frame_term(?DOMAIN, ?VERSION, Frame, Direction) ->
    validate_scope_frame(Frame, Direction);
decode_frame_term(_Domain, _Version, _Frame, _Direction) ->
    protocol_error(bad_domain).

validate_identity_frame(Frame, request) ->
    case frame_tag(Frame) of
        scope_identity_probe -> checked(Frame, validate_identity_probe(Frame));
        scope_identity_response -> protocol_error(bad_frame_type);
        _ -> protocol_error(bad_shape)
    end;
validate_identity_frame(Frame, response) ->
    case frame_tag(Frame) of
        scope_identity_response ->
            checked(Frame, validate_identity_response(Frame));
        scope_identity_probe -> protocol_error(bad_frame_type);
        _ -> protocol_error(bad_shape)
    end.

validate_scope_frame(Frame, request) ->
    case frame_tag(Frame) of
        scope_command -> checked(Frame, validate_command(Frame));
        scope_event -> protocol_error(bad_frame_type);
        _ -> protocol_error(bad_shape)
    end;
validate_scope_frame(Frame, response) ->
    case frame_tag(Frame) of
        scope_event -> checked(Frame, validate_event(Frame));
        scope_command -> protocol_error(bad_frame_type);
        _ -> protocol_error(bad_shape)
    end.

frame_tag(Frame) when is_tuple(Frame), tuple_size(Frame) > 0 -> element(1, Frame);
frame_tag(_) -> undefined.

checked(Frame, ok) -> {ok, Frame};
checked(_Frame, {error, _} = Error) -> Error.

%% ------------------------------------------------------------------
%% Opaque Prolog payload API
%% ------------------------------------------------------------------

-spec encode_payload(payload_kind(), term()) -> {ok, binary()} | wire_error().
%% A plan is a sealed `m:quod_dtx` artifact, not a Prolog term: its codec owns
%% canonicalization, bounds, and shape validation; only the byte bound is
%% shared here through `payload_limit/1`.
encode_payload(plan, Plan) ->
    quod_dtx:encode(Plan);
encode_payload(Kind, Term) ->
    case payload_limit(Kind) of
        {ok, MaxBytes} ->
            case quod_wire_term:encode(Term) of
                {ok, WireTerm} ->
                    bounded_encoded_payload(
                      Kind, MaxBytes,
                      term_to_binary(WireTerm, [deterministic]));
                {error, bad_term} -> protocol_error(bad_payload)
            end;
        error -> protocol_error(bad_payload_kind)
    end.

-spec decode_payload(payload_kind(), binary()) -> {ok, term()} | wire_error().
decode_payload(plan, Encoded) when is_binary(Encoded) ->
    quod_dtx:decode(Encoded);
decode_payload(Kind, Encoded) when is_binary(Encoded) ->
    case payload_limit(Kind) of
        {ok, MaxBytes} when byte_size(Encoded) =< MaxBytes ->
            case quod_safe_term:decode(Encoded, MaxBytes) of
                {ok, WireTerm} -> decode_wire_payload(Kind, WireTerm);
                {error, _} -> protocol_error(bad_payload)
            end;
        {ok, _} -> too_large(Kind);
        error -> protocol_error(bad_payload_kind)
    end;
decode_payload(Kind, _) ->
    case payload_limit(Kind) of
        {ok, _} -> protocol_error(bad_payload);
        error -> protocol_error(bad_payload_kind)
    end.

bounded_encoded_payload(_Kind, MaxBytes, Encoded)
  when byte_size(Encoded) =< MaxBytes -> {ok, Encoded};
bounded_encoded_payload(Kind, _MaxBytes, _Encoded) -> too_large(Kind).

decode_wire_payload(goal, WireTerm) ->
    normalize_payload(quod_wire_term:decode_goal(WireTerm));
decode_wire_payload(_Kind, WireTerm) ->
    normalize_payload(quod_wire_term:decode(WireTerm)).

normalize_payload({ok, _} = Result) -> Result;
normalize_payload({error, bad_term}) -> protocol_error(bad_payload).

payload_limit(goal) -> {ok, ?QUOD_MAX_NESTED_GOAL_BYTES};
payload_limit(answer) -> {ok, ?QUOD_MAX_PROOF_ANSWER_BYTES};
payload_limit(failure_reasons) -> {ok, ?ERLOG_MAX_FAILURE_REASONS_BYTES};
payload_limit(erlog_error) -> {ok, ?ERLOG_MAX_FAILURE_REASON_BYTES};
payload_limit(plan) -> {ok, ?QUOD_MAX_PLAN_ENVELOPE_BYTES};
payload_limit(result) -> {ok, ?QUOD_MAX_DURABLE_RESULT_BYTES};
payload_limit(_) -> error.

%% ------------------------------------------------------------------
%% Fixed operation shapes
%% ------------------------------------------------------------------

validate_command_operation(scope_open) -> ok;
validate_command_operation(scope_close) -> ok;
validate_command_operation(scope_seal) -> ok;
validate_command_operation(
  {submit_plan, PlanBlob, GoalBlob, ResultBlob, TraceCarrier}) ->
    %% These three payloads remain opaque until the authenticated command has
    %% passed its exact scope binding, sequence, deadline, readiness and quota
    %% gates. Deep canonical decoding belongs to the shared target admission
    %% boundary; unauthorised peers pay only bounded envelope decoding here.
    case quod_trace:valid_carrier(TraceCarrier) of
        true -> validate_submit_blobs(PlanBlob, GoalBlob, ResultBlob);
        false -> protocol_error(bad_payload)
    end;
validate_command_operation(
  {invoke_open, InvocationId, Selection, Chain, GoalBlob}) ->
    case {valid_id(InvocationId), validate_selection(Selection)} of
        {true, ok} -> validate_chain_blob(Chain, GoalBlob, goal);
        {false, _} -> protocol_error(bad_id);
        {_, {error, _} = Error} -> Error
    end;
validate_command_operation({invoke_next, InvocationId, AnswerSeq}) ->
    validate_id_sequence(InvocationId, AnswerSeq);
validate_command_operation({invoke_cancel, InvocationId}) ->
    validate_one_id(InvocationId);
validate_command_operation({nested_opened, ControllerId, ProxyId}) ->
    validate_two_ids(ControllerId, ProxyId);
validate_command_operation(
  {nested_solution, ControllerId, ProxyId, AnswerSeq, Blob}) ->
    validate_two_ids_sequence_blob(
      ControllerId, ProxyId, AnswerSeq, Blob, answer);
validate_command_operation(
  {nested_complete, ControllerId, ProxyId, AnswerSeq, Blob}) ->
    validate_two_ids_sequence_blob(
      ControllerId, ProxyId, AnswerSeq, Blob, failure_reasons);
validate_command_operation(
  {nested_erlog_error, ControllerId, ProxyId, AnswerSeq, Blob}) ->
    validate_two_ids_sequence_blob(
      ControllerId, ProxyId, AnswerSeq, Blob, erlog_error);
validate_command_operation({nested_error, ControllerId, Reason}) ->
    validate_id_error(ControllerId, Reason);
validate_command_operation(
  {tx_activated, ControllerId, FinalLineage, Activated}) ->
    validate_activated(ControllerId, FinalLineage, Activated);
validate_command_operation({tx_finished, ControllerId, ParentLineage}) ->
    validate_id_lineage(ControllerId, ParentLineage);
validate_command_operation({savepoint_allocated, ControllerId, BatchId}) ->
    validate_two_ids(ControllerId, BatchId);
validate_command_operation(
  {savepoint_restored, ControllerId, BatchIds}) ->
    validate_id_id_list(ControllerId, BatchIds);
validate_command_operation(
  {materialize, ControllerId, ActorInvocationId, Lineage, BatchIds}) ->
    validate_controller_actor_lineage_ids(
      ControllerId, ActorInvocationId, Lineage, BatchIds);
validate_command_operation({batch_restore, BatchIds}) ->
    validate_sorted_id_list(BatchIds);
validate_command_operation({batch_release, BatchIds}) ->
    validate_sorted_id_list(BatchIds);
validate_command_operation({controller_error, ControllerId, Reason}) ->
    validate_id_error(ControllerId, Reason);
validate_command_operation(_) -> protocol_error(bad_shape).

validate_submit_blobs(PlanBlob, GoalBlob, ResultBlob) ->
    case validate_blob(plan, PlanBlob) of
        ok ->
            case validate_blob(goal, GoalBlob) of
                ok -> validate_blob(result, ResultBlob);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

validate_event_operation({scope_opened, BaseHeight}) ->
    case valid_uint64(BaseHeight) of
        true -> ok;
        false -> protocol_error(bad_height)
    end;
validate_event_operation(scope_closed) -> ok;
validate_event_operation({plan_sealed, Blob}) ->
    validate_blob(plan, Blob);
validate_event_operation(plan_not_material) -> ok;
validate_event_operation({plan_submitted, {committed, Slot, TxId}}) ->
    case valid_sequence(Slot) andalso is_binary(TxId)
         andalso byte_size(TxId) =:= 32 of
        true -> ok;
        false -> protocol_error(bad_shape)
    end;
validate_event_operation({plan_submitted, {rejected, Reason}}) ->
    case lists:member(
           Reason,
           [conflict_retry, retry,
            consensus_unavailable, bad_plan]) of
        true -> ok;
        false -> protocol_error(bad_error_code)
    end;
validate_event_operation(
  {plan_submitted,
   {outcome_unknown, {transaction, Ns, Anchor, TxId}}}) ->
    case valid_namespace(Ns) andalso is_binary(Anchor)
         andalso byte_size(Anchor) =:= 32 andalso is_binary(TxId)
         andalso byte_size(TxId) =:= 32 of
        true -> ok;
        false -> protocol_error(bad_shape)
    end;
validate_event_operation({invocation_opened, InvocationId}) ->
    validate_one_id(InvocationId);
validate_event_operation({solution, InvocationId, AnswerSeq, Blob}) ->
    validate_id_sequence_blob(InvocationId, AnswerSeq, Blob, answer);
validate_event_operation({complete, InvocationId, AnswerSeq, Blob}) ->
    validate_id_sequence_blob(
      InvocationId, AnswerSeq, Blob, failure_reasons);
validate_event_operation({erlog_error, InvocationId, AnswerSeq, Blob}) ->
    validate_id_sequence_blob(InvocationId, AnswerSeq, Blob, erlog_error);
validate_event_operation({invocation_error, InvocationId, AnswerSeq, Reason}) ->
    case validate_id_sequence(InvocationId, AnswerSeq) of
        ok -> validate_public_error(Reason);
        {error, _} = Error -> Error
    end;
validate_event_operation({scope_error, Reason}) ->
    validate_public_error(Reason);
validate_event_operation(
  {nested_open, ControllerId, TargetNs, Chain, GoalBlob}) ->
    case valid_namespace(TargetNs) of
        true -> validate_id_chain_blob(ControllerId, Chain, GoalBlob, goal);
        false -> protocol_error(bad_identity)
    end;
validate_event_operation({nested_next, ControllerId, ProxyId, AnswerSeq}) ->
    case validate_two_ids(ControllerId, ProxyId) of
        ok -> validate_sequence(AnswerSeq);
        {error, _} = Error -> Error
    end;
validate_event_operation({nested_cancel, ControllerId, ProxyId}) ->
    validate_two_ids(ControllerId, ProxyId);
validate_event_operation(
  {tx_activate, ControllerId, ActorInvocationId, ParentLineage, FrameIds}) ->
    case validate_controller_actor_parent(
           ControllerId, ActorInvocationId, ParentLineage) of
        ok -> validate_id_list(FrameIds);
        {error, _} = Error -> Error
    end;
validate_event_operation(
  {tx_finish, ControllerId, ActorInvocationId, Lineage, TxId, Mode}) ->
    case {validate_controller_actor_lineage(
            ControllerId, ActorInvocationId, Lineage),
          valid_id(TxId), valid_finish_mode(Mode)} of
        {ok, true, true} -> ok;
        {{error, _} = Error, _, _} -> Error;
        {_, false, _} -> protocol_error(bad_id);
        {_, _, false} -> protocol_error(bad_transaction_mode)
    end;
validate_event_operation(
  {savepoint_allocate, ControllerId, ActorInvocationId, Lineage}) ->
    validate_controller_actor_lineage(
      ControllerId, ActorInvocationId, Lineage);
validate_event_operation(
  {savepoint_restore, ControllerId, ActorInvocationId, Lineage, BatchIds}) ->
    validate_controller_actor_lineage_ids(
      ControllerId, ActorInvocationId, Lineage, BatchIds);
validate_event_operation({materialized, ControllerId, BatchIds}) ->
    validate_id_id_list(ControllerId, BatchIds);
validate_event_operation({batch_restored, BatchIds}) ->
    validate_sorted_id_list(BatchIds);
validate_event_operation({batch_released, BatchIds}) ->
    validate_sorted_id_list(BatchIds);
validate_event_operation(_) -> protocol_error(bad_shape).

%% ------------------------------------------------------------------
%% Field validation
%% ------------------------------------------------------------------

validate_binding(
  {scope_binding, OriginKey, TargetKey, ProofId, SessionId,
   OriginIdentity, TargetIdentity, Mode}) ->
    case {valid_key(OriginKey), valid_key(TargetKey), valid_proof_id(ProofId),
          valid_id(SessionId), valid_identity(OriginIdentity),
          valid_identity(TargetIdentity), valid_mode(Mode)} of
        {true, true, true, true, true, true, true} -> ok;
        {false, _, _, _, _, _, _} -> protocol_error(bad_binding);
        {_, false, _, _, _, _, _} -> protocol_error(bad_binding);
        {_, _, false, _, _, _, _} -> protocol_error(bad_binding);
        {_, _, _, false, _, _, _} -> protocol_error(bad_binding);
        {_, _, _, _, false, _, _} -> protocol_error(bad_identity);
        {_, _, _, _, _, false, _} -> protocol_error(bad_identity);
        {_, _, _, _, _, _, false} -> protocol_error(bad_mode)
    end;
validate_binding(_) -> protocol_error(bad_binding).

validate_id_chain_blob(Id, Chain, Blob, Kind) ->
    case {valid_id(Id), validate_chain(Chain), validate_blob(Kind, Blob)} of
        {true, ok, ok} -> ok;
        {false, _, _} -> protocol_error(bad_id);
        {_, {error, _} = Error, _} -> Error;
        {_, _, {error, _} = Error} -> Error
    end.

validate_chain_blob(Chain, Blob, Kind) ->
    case validate_chain(Chain) of
        ok -> validate_blob(Kind, Blob);
        {error, _} = Error -> Error
    end.

validate_one_id(Id) ->
    case valid_id(Id) of true -> ok; false -> protocol_error(bad_id) end.

validate_two_ids(First, Second) ->
    case valid_id(First) andalso valid_id(Second) of
        true -> ok;
        false -> protocol_error(bad_id)
    end.

validate_id_lineage(Id, Lineage) ->
    case {valid_id(Id), valid_lineage(Lineage)} of
        {true, true} -> ok;
        {false, _} -> protocol_error(bad_id);
        {_, false} -> protocol_error(bad_lineage)
    end.

validate_controller_actor_parent(
  ControllerId, ActorInvocationId, ParentLineage) ->
    case {valid_id(ControllerId), valid_id(ActorInvocationId),
          valid_lineage(ParentLineage)} of
        {true, true, true} -> ok;
        {false, _, _} -> protocol_error(bad_id);
        {_, false, _} -> protocol_error(bad_id);
        {_, _, false} -> protocol_error(bad_lineage)
    end.

validate_controller_actor_lineage(
  ControllerId, ActorInvocationId, Lineage) ->
    case {valid_id(ControllerId), valid_id(ActorInvocationId),
          valid_id(Lineage)} of
        {true, true, true} -> ok;
        _ -> protocol_error(bad_id)
    end.

validate_controller_actor_lineage_ids(
  ControllerId, ActorInvocationId, Lineage, Ids) ->
    case validate_controller_actor_lineage(
           ControllerId, ActorInvocationId, Lineage) of
        ok -> validate_sorted_id_list(Ids);
        {error, _} = Error -> Error
    end.

validate_id_id_list(Id, Ids) ->
    case validate_one_id(Id) of
        ok -> validate_sorted_id_list(Ids);
        {error, _} = Error -> Error
    end.

validate_id_list(Ids) ->
    case validate_unique_ids(
           Ids, ?QUOD_MAX_DISTRIBUTED_SAVEPOINTS_PER_PROOF, false) of
        ok -> ok;
        error -> protocol_error(bad_id_list)
    end.

validate_sorted_id_list(Ids) ->
    case validate_id_list(Ids) of
        ok ->
            case Ids =:= lists:sort(Ids) of
                true -> ok;
                false -> protocol_error(bad_id_list)
            end;
        {error, _} = Error -> Error
    end.

validate_selection({tx_selection, Lineage, BatchIds}) ->
    Limit = ?QUOD_MAX_DISTRIBUTED_SAVEPOINTS_PER_PROOF,
    case valid_lineage(Lineage) andalso
         validate_unique_ids(BatchIds, Limit, true) =:= ok andalso
         BatchIds =:= lists:sort(BatchIds) andalso
         (Lineage =/= none orelse BatchIds =:= []) of
        true -> ok;
        false -> protocol_error(bad_selection)
    end;
validate_selection(_Selection) -> protocol_error(bad_selection).

validate_activated(ControllerId, FinalLineage, Activated) ->
    case {valid_id(ControllerId), valid_id(FinalLineage),
          valid_activated_list(Activated)} of
        {true, true, {ok, FinalLineage}} -> ok;
        {false, _, _} -> protocol_error(bad_id);
        {_, false, _} -> protocol_error(bad_id);
        {_, _, _} -> protocol_error(bad_activation)
    end.

valid_activated_list(Activated) ->
    Limit = ?QUOD_MAX_DISTRIBUTED_SAVEPOINTS_PER_PROOF,
    case bounded_nonempty_list(Activated, Limit) andalso
         lists:all(fun valid_activation_entry/1, Activated) andalso
         unique_activation_fields(Activated) of
        true -> {ok, element(3, lists:last(Activated))};
        false -> error
    end.

valid_activation_entry({FrameId, TxId, LineageId, BaselineBatchId}) ->
    valid_id(FrameId) andalso valid_id(TxId) andalso
        valid_id(LineageId) andalso valid_id(BaselineBatchId);
valid_activation_entry(_) -> false.

unique_activation_fields(Activated) ->
    unique_ids(1, Activated) andalso unique_ids(2, Activated) andalso
        unique_ids(3, Activated).

unique_ids(Position, Activated) ->
    Ids = [element(Position, Entry) || Entry <- Activated],
    map_size(maps:from_keys(Ids, true)) =:= length(Ids).

validate_unique_ids(Ids, Limit, AllowEmpty) ->
    validate_unique_ids(Ids, Limit, AllowEmpty, 0, #{}).

validate_unique_ids([], _Limit, true, _Count, _Seen) -> ok;
validate_unique_ids([], _Limit, false, Count, _Seen) when Count > 0 -> ok;
validate_unique_ids([], _Limit, false, 0, _Seen) -> error;
validate_unique_ids([Id | Rest], Limit, AllowEmpty, Count, Seen)
  when Count < Limit ->
    case valid_id(Id) andalso not maps:is_key(Id, Seen) of
        true -> validate_unique_ids(
                  Rest, Limit, AllowEmpty, Count + 1, Seen#{Id => true});
        false -> error
    end;
validate_unique_ids(_Ids, _Limit, _AllowEmpty, _Count, _Seen) -> error.

bounded_nonempty_list([_ | _] = List, Limit) ->
    bounded_list(List, Limit, 0);
bounded_nonempty_list(_List, _Limit) -> false.

bounded_list([], _Limit, _Count) -> true;
bounded_list([_ | Rest], Limit, Count) when Count < Limit ->
    bounded_list(Rest, Limit, Count + 1);
bounded_list(_List, _Limit, _Count) -> false.

validate_id_sequence(Id, Sequence) ->
    case {valid_id(Id), valid_sequence(Sequence)} of
        {true, true} -> ok;
        {false, _} -> protocol_error(bad_id);
        {_, false} -> protocol_error(bad_sequence)
    end.

validate_sequence(Sequence) ->
    case valid_sequence(Sequence) of
        true -> ok;
        false -> protocol_error(bad_sequence)
    end.

validate_id_sequence_blob(Id, Sequence, Blob, Kind) ->
    case validate_id_sequence(Id, Sequence) of
        ok -> validate_blob(Kind, Blob);
        {error, _} = Error -> Error
    end.

validate_two_ids_sequence_blob(First, Second, Sequence, Blob, Kind) ->
    case validate_two_ids(First, Second) of
        ok -> validate_id_sequence_blob(First, Sequence, Blob, Kind);
        {error, _} = Error -> Error
    end.

validate_id_error(Id, Reason) ->
    case validate_one_id(Id) of
        ok -> validate_public_error(Reason);
        {error, _} = Error -> Error
    end.

validate_chain(Chain) ->
    case bounded_nonempty_list(Chain, ?QUOD_MAX_ACTIVE_PROOF_DEPTH) andalso
         lists:all(fun valid_identity/1, Chain) of
        true -> ok;
        false -> protocol_error(bad_chain)
    end.

validate_blob(Kind, Blob) when is_binary(Blob) ->
    {ok, MaxBytes} = payload_limit(Kind),
    case byte_size(Blob) =< MaxBytes of
        true -> ok;
        false -> too_large(Kind)
    end;
validate_blob(_Kind, _Blob) -> protocol_error(bad_payload).

valid_identity({Namespace, Anchor}) ->
    valid_namespace(Namespace) andalso valid_key(Anchor);
valid_identity(_) -> false.

valid_namespace(Namespace) ->
    is_binary(Namespace) andalso byte_size(Namespace) > 0.

valid_key(Binary) ->
    is_binary(Binary) andalso
        bit_size(Binary) =:= ?QUOD_SCOPE_WIRE_KEY_BITS.

valid_proof_id(Binary) ->
    is_binary(Binary) andalso
        bit_size(Binary) =:= ?QUOD_SCOPE_WIRE_PROOF_ID_BITS.

valid_id(Binary) ->
    is_binary(Binary) andalso
        bit_size(Binary) =:= ?QUOD_SCOPE_WIRE_OPAQUE_ID_BITS.

valid_lineage(none) -> true;
valid_lineage(Lineage) -> valid_id(Lineage).

valid_mode(read_write) -> true;
valid_mode(read_only) -> true;
valid_mode(_) -> false.

valid_role(validator) -> true;
valid_role(observer) -> true;
valid_role(_) -> false.

valid_finish_mode(finish) -> true;
valid_finish_mode(discard) -> true;
valid_finish_mode(_) -> false.

valid_sequence(Integer) ->
    is_integer(Integer) andalso Integer >= 1 andalso valid_uint64(Integer).

valid_uint64(Integer) ->
    is_integer(Integer) andalso Integer >= 0 andalso
        Integer =< ?QUOD_SCOPE_WIRE_MAX_UINT64.

%% Typed failures are a closed vocabulary.  Prolog failures and Erlog errors
%% remain opaque bounded quod_wire_term blobs in their dedicated operations.
validate_public_error(read_only) -> ok;
validate_public_error({Tag, Value} = Reason) ->
    case namespaced_error_tag(Tag) of
        true ->
            case valid_namespace(Value) of
                true -> ok;
                false -> protocol_error(bad_error_code)
            end;
        false -> validate_public_error_pair(Reason)
    end;
validate_public_error(_) -> protocol_error(bad_error_code).

validate_public_error_pair({Tag, Max})
  when Tag =:= proof_depth_exceeded; Tag =:= scope_limit_exceeded;
       Tag =:= savepoint_limit_exceeded ->
    case valid_sequence(Max) of
        true -> ok;
        false -> protocol_error(bad_error_code)
    end;
validate_public_error_pair({too_large, Kind}) ->
    case payload_limit(Kind) of
        {ok, _} -> ok;
        error when Kind =:= scope_envelope; Kind =:= transcript;
                   Kind =:= result -> ok;
        error -> protocol_error(bad_error_code)
    end;
validate_public_error_pair({non_transactional_dependency, {Name, Arity}})
  when is_atom(Name), is_integer(Arity), Arity >= 0, Arity =< 255 ->
    ok;
validate_public_error_pair({protocol_error, Kind}) ->
    case valid_protocol_kind(Kind) of
        true -> ok;
        false -> protocol_error(bad_error_code)
    end;
validate_public_error_pair(_) -> protocol_error(bad_error_code).

-doc "Whether a term belongs to the one closed public scope-error catalog.".
-spec valid_public_error(term()) -> boolean().
valid_public_error(Reason) ->
    validate_public_error(Reason) =:= ok.

-spec scope_error_matches_target(term(), binary()) -> boolean().
scope_error_matches_target(Reason, TargetNamespace)
  when is_binary(TargetNamespace) ->
    case valid_public_error(Reason) of
        true ->
            case public_error_namespace(Reason) of
                none -> true;
                {ok, TargetNamespace} -> true;
                {ok, _OtherNamespace} -> false
            end;
        false -> false
    end;
scope_error_matches_target(_Reason, _TargetNamespace) ->
    false.

-doc "Return one target-bound public error, or the closed proof-engine error.".
-spec normalize_public_error(term(), binary()) -> term().
normalize_public_error(Reason, TargetNamespace) ->
    case scope_error_matches_target(Reason, TargetNamespace) of
        true -> Reason;
        false -> {protocol_error, proof_engine}
    end.

public_error_namespace({Tag, Namespace}) ->
    case namespaced_error_tag(Tag) of
        true -> {ok, Namespace};
        false -> none
    end;
public_error_namespace(_Reason) ->
    none.

namespaced_error_tag(Tag) ->
    Tag =:= unknown_ontology orelse Tag =:= anchor_conflict orelse
        Tag =:= not_allowed orelse Tag =:= ontology_unreachable orelse
        Tag =:= ontology_busy orelse Tag =:= ontology_rate_limited orelse
        Tag =:= ontology_rebuilding orelse Tag =:= proof_limit_exceeded orelse
        Tag =:= scope_expired orelse Tag =:= too_many_answers.

valid_protocol_kind(Kind) ->
    lists:member(
      Kind,
      [bad_etf, bad_domain, wrong_version, bad_frame_type, bad_shape,
       bad_binding, bad_identity, bad_mode, bad_id, bad_sequence,
       bad_role,
       bad_budget, bad_height, bad_chain, bad_dirty, bad_generation,
       bad_lineage, bad_selection, bad_id_list, bad_activation,
       bad_transaction_mode,
       bad_payload, bad_payload_kind, bad_error_code,
       command_sequence, event_sequence, answer_sequence,
       request_binding, session_binding, identity_binding,
       unexpected_scope_command, proof_engine]).

too_large(Kind) -> {error, {too_large, Kind}}.
protocol_error(Kind) -> {error, {protocol_error, Kind}}.

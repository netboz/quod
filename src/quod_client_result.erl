-module(quod_client_result).
-moduledoc """
One closed, bounded signed-client proof result shared by local HTTP execution
and the node-to-node signed-goal endpoint.

Engine bindings are converted once to the signed request's binary variable
names and encoded with `quod_durable_term`. Failure stacks reuse the existing
bounded failure-reason codec. The transport therefore never carries arbitrary
Erlang result terms, and the HTTP layer has only one renderer regardless of
where the proof ran.
""".

-include("quod_client_goal_limits.hrl").
-include("quod_proof_limits.hrl").

-export([normalize/2, encode/1, decode/1, http_normalized/2]).
-export_type([result/0]).

-define(MAX_UINT64, 16#FFFFFFFFFFFFFFFF).

-type transaction_ref() ::
        {transaction, binary(), <<_:256>>, <<_:256>>}.
-type group_ref() ::
        {group, binary(), <<_:256>>, <<_:256>>, <<_:256>>, <<_:256>>}.
-type operation_ref() ::
        {operation, binary(), <<_:256>>, binary(), <<_:256>>}.
-type participant_slot() ::
        {{binary(), <<_:256>>}, pos_integer(), non_neg_integer()}.
-type outcome() :: transaction_ref() |
        {group_outcome, group_ref(), pos_integer(), [participant_slot()]}.
-type public_error() ::
        read_only | target_unavailable | ontology_rebuilding | ontology_busy |
        cursor_not_found | cursor_not_ready | invalid_action |
        non_backtrackable_action | proof_unavailable | result_too_large.
-type result() ::
        {answers, non_neg_integer(), [binary()]} |
        {solution, <<_:256>>, non_neg_integer(), binary()} |
        stopped | fail | {failed, binary()} |
        {committed, [binary()], outcome()} |
        {pending, transaction_ref() | group_ref() | operation_ref()} |
        {error, public_error()}.

-doc "Normalize one target-engine result and enforce the aggregate reply cap.".
-spec normalize(quod_client_goal:evidence(), term()) -> result().
normalize(Evidence, Raw) ->
    case normalize_unbounded(Evidence, Raw) of
        {ok, Result} -> bounded(Result);
        error -> {error, proof_unavailable}
    end.

normalize_unbounded(Evidence, {ok, Bindings, Height})
  when is_list(Bindings), is_integer(Height), Height >= 0,
       Height =< ?MAX_UINT64 ->
    case encode_bindings(Evidence, Bindings) of
        {ok, Blobs} -> {ok, {answers, Height, Blobs}};
        error -> error
    end;
normalize_unbounded(Evidence,
                    {solution, <<_:256>> = CursorId, Bindings, Height})
  when is_map(Bindings), is_integer(Height), Height >= 0,
       Height =< ?MAX_UINT64 ->
    case encode_binding(Evidence, Bindings) of
        {ok, Blob} -> {ok, {solution, CursorId, Height, Blob}};
        error -> error
    end;
normalize_unbounded(_Evidence, {ok, stopped}) ->
    {ok, stopped};
normalize_unbounded(_Evidence, fail) ->
    {ok, fail};
normalize_unbounded(_Evidence, {fail, Reasons}) when is_list(Reasons) ->
    case quod_wire_term:encode_failure_reasons(Reasons) of
        {ok, Blob} -> {ok, {failed, Blob}};
        {error, _} -> error
    end;
normalize_unbounded(Evidence, {ok, Bindings, Outcome})
  when is_list(Bindings) ->
    case {encode_bindings(Evidence, Bindings), normalize_outcome(Outcome)} of
        {{ok, Blobs}, {ok, PublicOutcome}} ->
            {ok, {committed, Blobs, PublicOutcome}};
        _ ->
            error
    end;
normalize_unbounded(_Evidence, {error, {outcome_unknown, Ref}}) ->
    case valid_outcome_ref(Ref) of
        true -> {ok, {pending, Ref}};
        false -> error
    end;
normalize_unbounded(_Evidence, {error, Reason}) ->
    {ok, {error, public_error(Reason)}};
normalize_unbounded(_Evidence, _Raw) ->
    error.

bounded(Result) ->
    case encode(Result) of
        {ok, _Blob} -> Result;
        {error, result_too_large} -> {error, result_too_large};
        {error, _} -> {error, proof_unavailable}
    end.

encode_bindings(Evidence, Bindings) ->
    encode_bindings(Evidence, Bindings, 0, []).

encode_bindings(_Evidence, [], _Count, Acc) ->
    {ok, lists:reverse(Acc)};
encode_bindings(_Evidence, [_ | _], Count, _Acc)
  when Count >= ?QUOD_MAX_ANSWERS_PER_INVOCATION ->
    error;
encode_bindings(Evidence, [Bindings | Rest], Count, Acc) ->
    case encode_binding(Evidence, Bindings) of
        {ok, Blob} ->
            encode_bindings(Evidence, Rest, Count + 1, [Blob | Acc]);
        error ->
            error
    end;
encode_bindings(_Evidence, _Bindings, _Count, _Acc) ->
    error.

encode_binding(Evidence, Bindings) when is_map(Bindings) ->
    case quod_client_goal:named_bindings(Evidence, Bindings) of
        {ok, Named} ->
            case quod_durable_term:encode_result(Named) of
                {ok, Blob} -> {ok, Blob};
                {error, _} -> error
            end;
        {error, _} ->
            error
    end;
encode_binding(_Evidence, _Bindings) ->
    error.

normalize_outcome({transaction, Ns, <<_:256>>, <<_:256>>} = Ref)
  when is_binary(Ns), byte_size(Ns) > 0 ->
    {ok, Ref};
normalize_outcome(
  #{ref := {group, Ns, <<_:256>> = Anchor, <<_:256>> = Coordinator,
           <<_:256>> = Admission, <<_:256>> = GroupId} = Ref,
    height := Height, participant_slots := Slots})
  when is_binary(Ns), byte_size(Ns) > 0,
       is_integer(Height), Height > 0, Height =< ?MAX_UINT64 ->
    case valid_participant_slots(Slots) of
        true ->
            _ = {Anchor, Coordinator, Admission, GroupId},
            {ok, {group_outcome, Ref, Height, Slots}};
        false ->
            error
    end;
normalize_outcome(_Outcome) ->
    error.

public_error(read_only) -> read_only;
public_error(no_such_namespace) -> target_unavailable;
public_error(wrong_genesis_anchor) -> target_unavailable;
public_error(rebuilding) -> ontology_rebuilding;
public_error(busy) -> ontology_busy;
public_error(not_found) -> cursor_not_found;
public_error(not_ready) -> cursor_not_ready;
public_error(invalid_action) -> invalid_action;
public_error(non_backtrackable_action) -> non_backtrackable_action;
public_error(result_too_large) -> result_too_large;
public_error(_Reason) -> proof_unavailable.

-doc "Encode one canonical normalized result.".
-spec encode(result()) ->
          {ok, binary()} |
          {error, result_too_large | invalid_result}.
encode(Result) ->
    case valid_result(Result) of
        true ->
            Blob = term_to_binary(Result, [deterministic]),
            case byte_size(Blob) =< ?QUOD_CLIENT_GOAL_MAX_REPLY_BYTES of
                true -> {ok, Blob};
                false -> {error, result_too_large}
            end;
        false ->
            {error, invalid_result}
    end.

-doc "Decode, revalidate, and require canonical normalized-result bytes.".
-spec decode(term()) ->
          {ok, result()} |
          {error, result_too_large | invalid_result}.
decode(Blob)
  when is_binary(Blob),
       byte_size(Blob) =< ?QUOD_CLIENT_GOAL_MAX_REPLY_BYTES ->
    case quod_safe_term:decode(Blob, ?QUOD_CLIENT_GOAL_MAX_REPLY_BYTES) of
        {ok, Result} ->
            case valid_result(Result) andalso
                 term_to_binary(Result, [deterministic]) =:= Blob of
                true -> {ok, Result};
                false -> {error, invalid_result}
            end;
        {error, _} ->
            {error, invalid_result}
    end;
decode(Blob) when is_binary(Blob) ->
    {error, result_too_large};
decode(_Blob) ->
    {error, invalid_result}.

valid_result({answers, Height, Blobs}) ->
    valid_uint64(Height) andalso valid_binding_blobs(Blobs);
valid_result({solution, <<_:256>>, Height, Blob}) ->
    valid_uint64(Height) andalso valid_binding_blob(Blob);
valid_result(stopped) -> true;
valid_result(fail) -> true;
valid_result({failed, ReasonsBlob}) ->
    case quod_wire_term:decode_failure_reasons(ReasonsBlob) of
        {ok, _Reasons} -> true;
        {error, _} -> false
    end;
valid_result({committed, Blobs, Outcome}) ->
    valid_binding_blobs(Blobs) andalso valid_normalized_outcome(Outcome);
valid_result({pending, Ref}) -> valid_outcome_ref(Ref);
valid_result({error, Reason}) -> valid_public_error(Reason);
valid_result(_) -> false.

valid_binding_blobs(Blobs) ->
    valid_binding_blobs(Blobs, 0).

valid_binding_blobs([], _Count) -> true;
valid_binding_blobs([Blob | Rest], Count)
  when Count < ?QUOD_MAX_ANSWERS_PER_INVOCATION ->
    valid_binding_blob(Blob) andalso valid_binding_blobs(Rest, Count + 1);
valid_binding_blobs(_, _Count) -> false.

valid_binding_blob(Blob) ->
    case quod_durable_term:decode_result(Blob) of
        {ok, _Pairs} -> true;
        {error, _} -> false
    end.

valid_normalized_outcome(Ref = {transaction, _, _, _}) ->
    valid_transaction_ref(Ref);
valid_normalized_outcome({group_outcome, Ref, Height, Slots}) ->
    valid_group_ref(Ref) andalso valid_positive_slot(Height) andalso
        valid_participant_slots(Slots);
valid_normalized_outcome(_) -> false.

valid_outcome_ref(Ref = {transaction, _, _, _}) -> valid_transaction_ref(Ref);
valid_outcome_ref(Ref = {group, _, _, _, _, _}) -> valid_group_ref(Ref);
valid_outcome_ref(Ref = {operation, _, _, _, _}) -> valid_operation_ref(Ref);
valid_outcome_ref(_) -> false.

valid_transaction_ref(
  {transaction, Ns, <<_:256>>, <<_:256>>}) ->
    is_binary(Ns) andalso byte_size(Ns) > 0;
valid_transaction_ref(_) -> false.

valid_group_ref(
  {group, Ns, <<_:256>>, <<_:256>>, <<_:256>>, <<_:256>>}) ->
    is_binary(Ns) andalso byte_size(Ns) > 0;
valid_group_ref(_) -> false.

valid_operation_ref(
  {operation, Ns, <<_:256>>, AgentRef, <<_:256>>}) ->
    is_binary(Ns) andalso byte_size(Ns) > 0 andalso
        quod_agent_ref:valid_principal({agent, AgentRef});
valid_operation_ref(_) -> false.

valid_participant_slots(Slots) ->
    valid_participant_slots(Slots, none, 0).

valid_participant_slots([], _Previous, Count) -> Count >= 2;
valid_participant_slots(
  [{{Ns, <<_:256>>} = Identity, Slot, Generation} | Rest], Previous, Count)
  when is_binary(Ns), byte_size(Ns) > 0,
       Count < ?QUOD_MAX_DTX_PARTICIPANTS,
       (Previous =:= none orelse Previous < Identity),
       is_integer(Slot), Slot > 0, Slot =< ?MAX_UINT64,
       is_integer(Generation), Generation >= 0, Generation =< ?MAX_UINT64 ->
    valid_participant_slots(Rest, Identity, Count + 1);
valid_participant_slots(_, _Previous, _Count) -> false.

valid_uint64(Value) ->
    is_integer(Value) andalso Value >= 0 andalso Value =< ?MAX_UINT64.

valid_positive_slot(Value) -> valid_uint64(Value) andalso Value > 0.

valid_public_error(Reason) ->
    Reason =:= read_only orelse Reason =:= target_unavailable orelse
        Reason =:= ontology_rebuilding orelse Reason =:= ontology_busy orelse
        Reason =:= cursor_not_found orelse Reason =:= cursor_not_ready orelse
        Reason =:= invalid_action orelse
        Reason =:= non_backtrackable_action orelse
        Reason =:= proof_unavailable orelse Reason =:= result_too_large.

-doc "Render one already-normalized local or forwarded result.".
-spec http_normalized(quod_client_goal:evidence(), result()) ->
          {pos_integer(), map()}.
http_normalized(Evidence, {answers, Height, Blobs}) ->
    {200, evidence_json(
            Evidence,
            #{result => ok, height => Height,
              bindings => render_bindings(Blobs)})};
http_normalized(Evidence, {solution, CursorId, Height, Blob}) ->
    {200, evidence_json(
            Evidence,
            #{result => solution, cursor => b64url(CursorId),
              height => Height, bindings => render_bindings([Blob])})};
http_normalized(Evidence, stopped) ->
    {200, evidence_json(Evidence, #{result => stopped})};
http_normalized(Evidence, fail) ->
    {200, evidence_json(Evidence, #{result => fail})};
http_normalized(Evidence, {failed, ReasonsBlob}) ->
    {ok, Reasons} = quod_wire_term:decode_failure_reasons(ReasonsBlob),
    {200, evidence_json(
            Evidence,
            #{result => fail,
              reasons => [quod_explorer_http:prolog_text(R) || R <- Reasons]})};
http_normalized(Evidence, {committed, Blobs, Outcome}) ->
    {200, evidence_json(
            Evidence,
            (committed_json(Outcome))#{result => ok,
                                       bindings => render_bindings(Blobs)})};
http_normalized(Evidence, {pending, Ref}) ->
    {202, evidence_json(Evidence,
                        (outcome_ref_json(Ref))#{result => pending})};
http_normalized(_Evidence, {error, read_only}) ->
    {409, #{error => read_only}};
http_normalized(_Evidence, {error, target_unavailable}) ->
    {503, #{error => signed_target_unavailable}};
http_normalized(_Evidence, {error, ontology_rebuilding}) ->
    {503, #{error => ontology_rebuilding}};
http_normalized(_Evidence, {error, ontology_busy}) ->
    {503, #{error => ontology_busy}};
http_normalized(_Evidence, {error, cursor_not_found}) ->
    {404, #{error => cursor_not_found}};
http_normalized(_Evidence, {error, cursor_not_ready}) ->
    {409, #{error => cursor_not_ready}};
http_normalized(_Evidence, {error, invalid_action}) ->
    {400, #{error => invalid_action}};
http_normalized(_Evidence, {error, non_backtrackable_action}) ->
    {400, #{error => non_backtrackable_action}};
http_normalized(_Evidence, {error, result_too_large}) ->
    {413, #{error => result_too_large}};
http_normalized(_Evidence, {error, proof_unavailable}) ->
    {503, #{error => proof_unavailable}}.

render_bindings(Blobs) ->
    [maps:from_list(
       [{Name, quod_explorer_http:prolog_text(Value)}
        || {Name, Value} <- decoded_binding(Blob)])
     || Blob <- Blobs].

decoded_binding(Blob) ->
    {ok, Pairs} = quod_durable_term:decode_result(Blob),
    Pairs.

committed_json(Ref = {transaction, _, _, _}) -> outcome_ref_json(Ref);
committed_json({group_outcome, Ref, Height, Slots}) ->
    (outcome_ref_json(Ref))#{height => Height,
                             participant_slots =>
                                 [participant_slot_json(S) || S <- Slots]}.

outcome_ref_json({transaction, Ns, Anchor, TxId}) ->
    #{ns => Ns, anchor => hex(Anchor), tx_id => hex(TxId)};
outcome_ref_json(
  {group, Ns, Anchor, Coordinator, Admission, GroupId}) ->
    #{ns => Ns, anchor => hex(Anchor), coordinator => hex(Coordinator),
      coordinator_admission => hex(Admission), group_id => hex(GroupId)};
outcome_ref_json(
  {operation, Ns, Anchor, AgentRef, OperationId}) ->
    #{ns => Ns, anchor => hex(Anchor), agent => agent_json(AgentRef),
      operation_id => b64url(OperationId)}.

agent_json(AgentRef) ->
    {ok, #{identity := {AgentNs, AgentAnchor}, reference := Reference}} =
        quod_agent_ref:decode(AgentRef),
    #{kind => agent,
      identity => #{ns => AgentNs, anchor => hex(AgentAnchor)},
      reference => quod_explorer_http:prolog_text(Reference),
      reference_wire => b64url(AgentRef)}.

participant_slot_json({{Ns, Anchor}, Slot, Generation}) ->
    #{ns => Ns, anchor => hex(Anchor), height => Slot,
      generation => Generation}.

evidence_json(#{request_digest := Digest,
                request := #{operation_id := OperationId}}, Result) ->
    Result#{request_digest => b64url(Digest),
            operation_id => b64url(OperationId)}.

hex(Bytes) -> binary:encode_hex(Bytes, lowercase).
b64url(Bytes) -> base64:encode(Bytes, #{mode => urlsafe, padding => false}).

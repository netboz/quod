-module(quod_client_goal).
-moduledoc """
Pure cross-language contract for one user-signed Prolog goal.

The signed bytes are a fixed binary layout, never JSON, ETF, or JavaScript
object order. Decoding allocates no request-controlled atoms. Signature
verification happens before the atom-safe parser is entered; parsing then
derives the canonical durable goal bytes every validator compares.

This module owns no session, process, clock, rate limiter, proof, or ledger
state. Callers supply the expected network, target, and admission timestamp
when they need the complete validator check.
""".

-include("quod_client_goal_limits.hrl").

-export([encode/1, decode/1, verify/2, verify_for/5,
         digest/1, operation_ref/1]).
-export_type([request/0, evidence/0, mode/0]).

-define(DOMAIN, <<"quod.user.goal.v1", 0>>).
-define(PARSER_VERSION, 1).
-define(MAX_UINT64, 16#FFFFFFFFFFFFFFFF).

-type mode() :: read | execute | cursor.
-type request() ::
        #{network_identity := <<_:256>>,
          user_public_key := <<_:256>>,
          operation_id := <<_:256>>,
          target_namespace := binary(),
          target_genesis_anchor := <<_:256>>,
          mode := mode(),
          parser_version := 1,
          not_after_ms := pos_integer(),
          goal_text := binary()}.
-type evidence() ::
        #{request := request(), request_bytes := binary(),
          request_digest := <<_:256>>, signature := <<_:512>>,
          goal := term(), goal_blob := binary(),
          variables := [{binary(), non_neg_integer()}],
          operation_ref := tuple()}.

-type error_reason() ::
        invalid_request | invalid_signature | invalid_goal |
        wrong_network | wrong_target | invalid_admission_time | expired |
        {too_large, request | namespace | goal_text | goal}.

-doc "Encode one exact v1 request into the bytes the browser signs.".
-spec encode(term()) -> {ok, binary()} | {error, error_reason()}.
encode(Request) ->
    case validate_request(Request) of
        ok -> {ok, encode_valid(Request)};
        {error, _} = Error -> Error
    end.

-doc "Decode one exact v1 request without parsing or allocating goal symbols.".
-spec decode(term()) -> {ok, request()} | {error, error_reason()}.
decode(Bytes)
  when is_binary(Bytes), byte_size(Bytes) =< ?QUOD_CLIENT_GOAL_REQUEST_BYTES ->
    decode_bounded(Bytes);
decode(Bytes) when is_binary(Bytes) ->
    {error, {too_large, request}};
decode(_) ->
    {error, invalid_request}.

-doc "Verify the user signature and derive the canonical atom-safe goal.".
-spec verify(term(), term()) -> {ok, evidence()} | {error, error_reason()}.
verify(Bytes, <<_:512>> = Signature) ->
    case decode(Bytes) of
        {ok, #{user_public_key := PublicKey} = Request} ->
            case quod_identity:verify(Signature, Bytes, PublicKey) of
                true -> parsed_evidence(Request, Bytes, Signature);
                false -> {error, invalid_signature}
            end;
        {error, _} = Error ->
            Error
    end;
verify(_Bytes, _Signature) ->
    {error, invalid_signature}.

-doc """
Perform the complete deterministic validator check.

`AdmissionMs` is the proposed or committed block timestamp, not the validator's
current wall clock. Session validity and ingress rate limits remain caller
responsibilities.
""".
-spec verify_for(term(), term(), term(), term(), term()) ->
          {ok, evidence()} | {error, error_reason()}.
verify_for(Bytes, Signature, ExpectedNetwork, ExpectedTarget, AdmissionMs) ->
    case verify(Bytes, Signature) of
        {ok, #{request := Request} = Evidence} ->
            validate_context(
              Request, ExpectedNetwork, ExpectedTarget, AdmissionMs, Evidence);
        {error, _} = Error ->
            Error
    end.

-doc "Return the SHA-256 identity of exact canonical request bytes.".
-spec digest(request() | binary()) -> {ok, <<_:256>>} | {error, error_reason()}.
digest(Bytes) when is_binary(Bytes) ->
    case decode(Bytes) of
        {ok, _} -> {ok, crypto:hash(sha256, Bytes)};
        {error, _} = Error -> Error
    end;
digest(Request) ->
    case encode(Request) of
        {ok, Bytes} -> {ok, crypto:hash(sha256, Bytes)};
        {error, _} = Error -> Error
    end.

-doc "Return the stable anchored reference used to resolve a signed operation.".
-spec operation_ref(request() | evidence()) -> tuple().
operation_ref(#{request := Request}) -> operation_ref(Request);
operation_ref(#{target_namespace := Namespace,
                target_genesis_anchor := Anchor,
                user_public_key := PublicKey,
                operation_id := OperationId}) ->
    {operation, Namespace, Anchor, PublicKey, OperationId}.

%% ------------------------------------------------------------------
%% Fixed wire
%% ------------------------------------------------------------------

encode_valid(#{network_identity := Network,
               user_public_key := PublicKey,
               operation_id := OperationId,
               target_namespace := Namespace,
               target_genesis_anchor := Anchor,
               mode := Mode,
               parser_version := ParserVersion,
               not_after_ms := NotAfter,
               goal_text := GoalText}) ->
    NamespaceBytes = byte_size(Namespace),
    GoalBytes = byte_size(GoalText),
    ModeTag = mode_tag(Mode),
    <<?DOMAIN/binary, Network/binary, PublicKey/binary, OperationId/binary,
      NamespaceBytes:16/unsigned-big, Namespace/binary, Anchor/binary,
      ModeTag:8, ParserVersion:8, NotAfter:64/unsigned-big,
      GoalBytes:32/unsigned-big, GoalText/binary>>.

decode_bounded(<<"quod.user.goal.v1", 0,
                 Network:32/binary, PublicKey:32/binary,
                 OperationId:32/binary, NamespaceBytes:16/unsigned-big,
                 Rest/binary>>) ->
    case Rest of
        <<Namespace:NamespaceBytes/binary, Anchor:32/binary, ModeTag:8,
          ParserVersion:8, NotAfter:64/unsigned-big,
          GoalBytes:32/unsigned-big, GoalText:GoalBytes/binary>> ->
            case decode_mode(ModeTag) of
                {ok, Mode} ->
                    Request = #{network_identity => Network,
                                user_public_key => PublicKey,
                                operation_id => OperationId,
                                target_namespace => Namespace,
                                target_genesis_anchor => Anchor,
                                mode => Mode,
                                parser_version => ParserVersion,
                                not_after_ms => NotAfter,
                                goal_text => GoalText},
                    case validate_request(Request) of
                        ok -> {ok, Request};
                        {error, _} = Error -> Error
                    end;
                error ->
                    {error, invalid_request}
            end;
        _ ->
            {error, invalid_request}
    end;
decode_bounded(_) ->
    {error, invalid_request}.

validate_request(Request) when is_map(Request), map_size(Request) =:= 9 ->
    case Request of
        #{network_identity := <<_:256>>,
          user_public_key := <<_:256>>,
          operation_id := <<_:256>>,
          target_namespace := Namespace,
          target_genesis_anchor := <<_:256>>,
          mode := Mode,
          parser_version := ?PARSER_VERSION,
          not_after_ms := NotAfter,
          goal_text := GoalText} ->
            validate_scalars(Namespace, Mode, NotAfter, GoalText);
        _ ->
            {error, invalid_request}
    end;
validate_request(_) ->
    {error, invalid_request}.

validate_scalars(Namespace, Mode, NotAfter, GoalText) ->
    case {valid_namespace(Namespace), valid_mode(Mode),
          is_integer(NotAfter) andalso NotAfter > 0 andalso
              NotAfter =< ?MAX_UINT64,
          valid_utf8(GoalText)} of
        {false, _, _, _} when is_binary(Namespace),
                             byte_size(Namespace) >
                                 ?DIRECTORY_MAX_NAMESPACE_BYTES ->
            {error, {too_large, namespace}};
        {false, _, _, _} ->
            {error, invalid_request};
        {_, false, _, _} ->
            {error, invalid_request};
        {_, _, false, _} ->
            {error, invalid_request};
        {_, _, _, false} when is_binary(GoalText),
                              byte_size(GoalText) >
                                  ?QUOD_CLIENT_GOAL_TEXT_BYTES ->
            {error, {too_large, goal_text}};
        {_, _, _, false} ->
            {error, invalid_request};
        {true, true, true, true} ->
            ok
    end.

valid_namespace(Namespace) ->
    is_binary(Namespace) andalso byte_size(Namespace) > 0 andalso
        byte_size(Namespace) =< ?DIRECTORY_MAX_NAMESPACE_BYTES andalso
        valid_utf8_bytes(Namespace).

valid_utf8(GoalText) ->
    is_binary(GoalText) andalso byte_size(GoalText) > 0 andalso
        byte_size(GoalText) =< ?QUOD_CLIENT_GOAL_TEXT_BYTES andalso
        valid_utf8_bytes(GoalText).

valid_utf8_bytes(Bytes) ->
    case unicode:characters_to_binary(Bytes, utf8, utf8) of
        Bytes -> true;
        _ -> false
    end.

valid_mode(read) -> true;
valid_mode(execute) -> true;
valid_mode(cursor) -> true;
valid_mode(_) -> false.

mode_tag(read) -> 0;
mode_tag(execute) -> 1;
mode_tag(cursor) -> 2.

decode_mode(0) -> {ok, read};
decode_mode(1) -> {ok, execute};
decode_mode(2) -> {ok, cursor};
decode_mode(_) -> error.

%% ------------------------------------------------------------------
%% Verified evidence
%% ------------------------------------------------------------------

parsed_evidence(#{goal_text := GoalText,
                  parser_version := ParserVersion} = Request,
                Bytes, Signature) ->
    case quod_client_goal_parser:parse(GoalText, ParserVersion) of
        {ok, #{goal := Goal, variables := Variables}} ->
            case quod_durable_term:encode_goal(Goal) of
                {ok, GoalBlob} ->
                    Digest = crypto:hash(sha256, Bytes),
                    Evidence0 = #{request => Request,
                                  request_bytes => Bytes,
                                  request_digest => Digest,
                                  signature => Signature,
                                  goal => Goal,
                                  goal_blob => GoalBlob,
                                  variables => Variables},
                    {ok, Evidence0#{operation_ref =>
                                       operation_ref(Evidence0)}};
                {error, {too_large, goal}} ->
                    {error, {too_large, goal}};
                {error, _} ->
                    {error, invalid_goal}
            end;
        {error, {too_large, _}} = Error ->
            Error;
        {error, _} ->
            {error, invalid_goal}
    end.

validate_context(_Request, _ExpectedNetwork, _ExpectedTarget,
                 AdmissionMs, _Evidence)
  when not is_integer(AdmissionMs); AdmissionMs < 0 ->
    {error, invalid_admission_time};
validate_context(#{network_identity := Network,
                   target_namespace := Namespace,
                   target_genesis_anchor := Anchor,
                   not_after_ms := NotAfter},
                 ExpectedNetwork, ExpectedTarget, AdmissionMs, Evidence) ->
    case {ExpectedNetwork, ExpectedTarget, AdmissionMs} of
        {Network, {Namespace, Anchor}, Timestamp}
          when is_integer(Timestamp), Timestamp >= 0,
               Timestamp =< NotAfter ->
            {ok, Evidence};
        {Network, {Namespace, Anchor}, Timestamp}
          when is_integer(Timestamp), Timestamp > NotAfter ->
            {error, expired};
        {Network, {_OtherNamespace, _OtherAnchor}, _} ->
            {error, wrong_target};
        {Network, _MalformedTarget, _} ->
            {error, wrong_target};
        {_OtherNetwork, _, _} ->
            {error, wrong_network}
    end.

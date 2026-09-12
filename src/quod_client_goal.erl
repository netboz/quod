-module(quod_client_goal).
-moduledoc """
Pure cross-language contract for one agent-signed Prolog goal.

The signed bytes are a fixed binary layout, never JSON, ETF, or JavaScript
object order. Decoding allocates no request-controlled atoms. Signature
verification happens before the atom-safe parser is entered; parsing then
derives the canonical durable goal bytes every validator compares.

This module owns no session, process, clock, rate limiter, proof, or ledger
state. Callers supply the expected network, target, and admission timestamp
when they need the complete validator check.
""".

-include("quod_client_goal_limits.hrl").
-include("quod_proof_limits.hrl").

-export([encode/1, decode/1, verify/2, verify_for/5,
         operation_ref/1,
         request_auth/1, request_binding/1,
         named_bindings/2, durable_bindings/2,
         valid_request_binding/1, authorization_transcript/3,
         verify_durable_request/2, validate_durable_request/5,
         verify_durable_authorization/3,
         validate_durable_authorization/6]).
-export_type([request/0, evidence/0, mode/0,
              request_auth/0, request_binding/0]).

-define(DOMAIN, <<"quod.agent.goal.v1", 0>>).
-define(MAX_UINT64, 16#FFFFFFFFFFFFFFFF).

-type mode() :: read | execute | cursor.
-type request() ::
        #{network_identity := <<_:256>>,
          signing_public_key := <<_:256>>,
          operation_id := <<_:256>>,
          agent_namespace := binary(),
          agent_genesis_anchor := <<_:256>>,
          agent_instance_text := binary(),
          mode := mode(),
          parser_version := 1 | 2,
          not_after_ms := pos_integer(),
          goal_text := binary()}.
-type evidence() ::
        #{request := request(), request_bytes := binary(),
          request_digest := <<_:256>>, signature := <<_:512>>,
          agent_ref_blob := quod_agent_ref:blob(),
          goal := term(), goal_blob := binary(),
          variables := [{binary(), non_neg_integer()}],
          operation_ref := {operation, binary(), <<_:256>>,
                            quod_agent_ref:blob(), <<_:256>>}}.
-type request_auth() ::
        {agent_goal_v1, <<_:256>>, binary(), <<_:512>>}.
-type request_binding() :: none | {agent_goal_v1, <<_:256>>}.

-type error_reason() ::
        invalid_request | invalid_signature | invalid_goal |
        wrong_network | wrong_target | invalid_admission_time | expired |
        invalid_authorization_transcript |
        {too_large, request | namespace | agent_instance_text |
                    goal_text | goal}.

-doc "Encode one exact signed-goal request into the bytes the browser signs.".
-spec encode(term()) -> {ok, binary()} | {error, error_reason()}.
encode(Request) ->
    case validate_request(Request) of
        ok -> {ok, encode_valid(Request)};
        {error, _} = Error -> Error
    end.

-doc "Decode one exact signed-goal request without parsing or allocating goal symbols.".
-spec decode(term()) -> {ok, request()} | {error, error_reason()}.
decode(Bytes)
  when is_binary(Bytes), byte_size(Bytes) =< ?QUOD_CLIENT_GOAL_REQUEST_BYTES ->
    decode_bounded(Bytes);
decode(Bytes) when is_binary(Bytes) ->
    {error, {too_large, request}};
decode(_) ->
    {error, invalid_request}.

-doc "Verify the agent signature and derive its canonical reference and goal.".
-spec verify(term(), term()) -> {ok, evidence()} | {error, error_reason()}.
verify(Bytes, <<_:512>> = Signature) ->
    case decode(Bytes) of
        {ok, #{signing_public_key := PublicKey} = Request} ->
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

-doc "Return the stable anchored reference used to resolve a signed operation.".
-spec operation_ref(evidence()) -> tuple().
operation_ref(#{request := #{agent_namespace := Namespace,
                             agent_genesis_anchor := Anchor,
                             operation_id := OperationId},
                agent_ref_blob := AgentRef}) ->
    make_operation_ref(Namespace, Anchor, AgentRef, OperationId).

make_operation_ref(Namespace, Anchor, AgentRef, OperationId) ->
    {operation, Namespace, Anchor, AgentRef, OperationId}.

-doc "Build the one canonical durable evidence object from verified ingress evidence.".
-spec request_auth(evidence()) -> request_auth().
request_auth(#{request_bytes := Bytes, request_digest := <<_:256>> = Digest,
               signature := <<_:512>> = Signature}) ->
    {agent_goal_v1, Digest, Bytes, Signature}.

-doc "Return the digest-only binding copied into sealed plans and manifests.".
-spec request_binding(evidence() | request_auth()) -> request_binding().
request_binding(#{request_digest := <<_:256>> = Digest}) ->
    {agent_goal_v1, Digest};
request_binding({agent_goal_v1, <<_:256>> = Digest, _Bytes, _Signature}) ->
    {agent_goal_v1, Digest}.

-doc "Validate the one durable request-binding alphabet owned by this protocol.".
-spec valid_request_binding(term()) -> boolean().
valid_request_binding(none) -> true;
valid_request_binding({agent_goal_v1, <<_:256>>}) -> true;
valid_request_binding(_) -> false.

-doc "Build the one durable operation claim from verified request evidence.".
-spec operation_claim(evidence()) -> map().
operation_claim(
  #{request := #{agent_namespace := Ns,
                 agent_genesis_anchor := Anchor,
                 operation_id := OperationId,
                 not_after_ms := Deadline},
    agent_ref_blob := AgentRef,
    request_digest := Digest, operation_ref := OperationRef}) ->
    #{key => {AgentRef, OperationId}, digest => Digest,
      target => {Ns, Anchor}, deadline => Deadline,
      principal => {agent, AgentRef}, operation_ref => OperationRef}.

-doc "Encode the one top-level allowed authorization entry bound to a signed goal.".
-spec authorization_transcript(list(), term(), term()) ->
          {ok, {agent_goal_v1, binary()}} | error.
authorization_transcript(Transcript, Target, GoalBlob)
  when is_list(Transcript), is_binary(GoalBlob) ->
    Matches =
        [Entry || {_, Chain, EntryGoal, allowed, _, _, _} = Entry <- Transcript,
                  Chain =:= [Target], EntryGoal =:= GoalBlob],
    case Matches of
        [Entry] ->
            case quod_wire_term:encode_canonical([Entry]) of
                {ok, Blob}
                  when byte_size(Blob) =< ?QUOD_MAX_SCOPE_TRANSCRIPT_BYTES ->
                    {ok, {agent_goal_v1, Blob}};
                _ -> error
            end;
        _ -> error
    end;
authorization_transcript(_Transcript, _Target, _GoalBlob) ->
    error.

-doc "Decode and bind the one recorded top-level authorization entry to verified intent.".
-spec verify_authorization(evidence(), term()) -> {ok, list()} | error.
verify_authorization(
  #{request := #{agent_namespace := Ns,
                 agent_genesis_anchor := Anchor},
    goal_blob := GoalBlob},
  {agent_goal_v1, Blob})
  when is_binary(Ns), is_binary(GoalBlob), is_binary(Blob),
       byte_size(Blob) =< ?QUOD_MAX_SCOPE_TRANSCRIPT_BYTES ->
    Target = {Ns, Anchor},
    case quod_wire_term:decode_canonical(
           Blob, ?QUOD_MAX_SCOPE_TRANSCRIPT_BYTES) of
        {ok, [Entry0]} ->
            case quod_wire_term:materialize_symbols([Entry0]) of
                {ok, [Entry]} ->
                    verify_authorization_entry(Entry, Target, GoalBlob);
                _ -> error
            end;
        _ -> error
    end;
verify_authorization(_Evidence, _Authorization) ->
    error.

verify_authorization_entry(
  {<<_:128>>, [Target], GoalBlob, allowed, AnswerCount, <<_:256>>, Tag} = Entry,
  Target, GoalBlob)
  when is_integer(AnswerCount), AnswerCount >= 0,
       AnswerCount =< ?QUOD_MAX_ANSWERS_PER_INVOCATION,
       (Tag =:= active orelse Tag =:= complete orelse
        Tag =:= error orelse Tag =:= cancelled) ->
    {ok, [Entry]};
verify_authorization_entry(_Entry, _Target, _GoalBlob) ->
    error.

-doc """
Validate durable agent intent against the exact ledger admission context.

This is the sole transaction/DTX validation seam: it re-verifies the original
signature and parser result, checks the stored digest, target and block time,
and binds the resulting goal and principal.  Callers do not reinterpret any of
those fields themselves.
""".
-spec validate_durable_auth(term(), term(), term(), term(), term()) ->
          {ok, evidence()} | {error, error_reason() | invalid_binding}.
validate_durable_auth(
  Auth, ExpectedNetwork, {Ns, <<_:256>>} = ExpectedTarget, AdmissionMs,
  ExpectedGoalBlob)
  when is_binary(Ns), is_binary(ExpectedGoalBlob) ->
    case verify_durable_auth(Auth, ExpectedGoalBlob) of
        {ok, #{request := Request} = Evidence} ->
            validate_context(
              Request, ExpectedNetwork, ExpectedTarget, AdmissionMs,
              Evidence);
        {error, _} = Error ->
            Error
    end;
validate_durable_auth(_Auth, _Network, _Target, _AdmissionMs,
                      _GoalBlob) ->
    {error, invalid_binding}.

-doc "Verify durable request evidence and its exact parsed goal without runtime context.".
-spec verify_durable_auth(term(), term()) ->
          {ok, evidence()} | {error, error_reason() | invalid_binding}.
verify_durable_auth(
  {agent_goal_v1, <<_:256>> = Digest, Bytes, <<_:512>> = Signature},
  ExpectedGoalBlob)
  when is_binary(Bytes), is_binary(ExpectedGoalBlob) ->
    case verify(Bytes, Signature) of
        {ok, #{request := #{mode := Mode},
               request_digest := Digest,
               goal_blob := ExpectedGoalBlob} = Evidence}
          when Mode =:= execute; Mode =:= cursor ->
            {ok, Evidence};
        {ok, _OtherEvidence} ->
            {error, invalid_binding};
        {error, _} = Error ->
            Error
    end;
verify_durable_auth(_Auth, _ExpectedGoalBlob) ->
    {error, invalid_binding}.

-doc "Verify one signed durable request and expose its principal and operation claim.".
-spec verify_durable_request(term(), term()) ->
          {ok, map()} | {error, error_reason() | invalid_binding}.
verify_durable_request(Auth, GoalBlob) ->
    case verify_durable_auth(Auth, GoalBlob) of
        {ok, Evidence} -> {ok, durable_request_evidence(Evidence)};
        {error, _} = Error -> Error
    end.

-doc "Validate one signed durable request at its exact ledger admission context.".
-spec validate_durable_request(term(), term(), term(), term(), term()) ->
          {ok, map()} | {error, error_reason() | invalid_binding}.
validate_durable_request(Auth, Network, Target, AdmissionMs, GoalBlob) ->
    case validate_durable_auth(
           Auth, Network, Target, AdmissionMs, GoalBlob) of
        {ok, Evidence} -> {ok, durable_request_evidence(Evidence)};
        {error, _} = Error -> Error
    end.

-doc "Verify the one signed request and its recorded authorization without runtime context.".
-spec verify_durable_authorization(term(), term(), term()) ->
          {ok, map()} | {error, error_reason() | invalid_binding}.
verify_durable_authorization(Auth, Authorization, GoalBlob) ->
    case verify_durable_auth(Auth, GoalBlob) of
        {ok, Evidence} ->
            authorized_evidence(Evidence, Authorization);
        {error, _} = Error ->
            Error
    end.

-doc "Validate the one signed request and its authorization at ledger admission.".
-spec validate_durable_authorization(
        term(), term(), term(), term(), term(), term()) ->
          {ok, map()} | {error, error_reason() | invalid_binding}.
validate_durable_authorization(
  Auth, Authorization, Network, Target, AdmissionMs, GoalBlob) ->
    case validate_durable_auth(
           Auth, Network, Target, AdmissionMs, GoalBlob) of
        {ok, Evidence} ->
            authorized_evidence(Evidence, Authorization);
        {error, _} = Error ->
            Error
    end.

authorized_evidence(Evidence, Authorization) ->
    case verify_authorization(Evidence, Authorization) of
        {ok, Transcript} ->
            Claim = operation_claim(Evidence),
            {ok, #{evidence => Evidence,
                   principal => maps:get(principal, Claim),
                   transcript => Transcript,
                   claim => Claim}};
        error ->
            {error, invalid_authorization_transcript}
    end.

durable_request_evidence(Evidence) ->
    Claim = operation_claim(Evidence),
    #{evidence => Evidence,
      principal => maps:get(principal, Claim),
      claim => Claim}.

%% ------------------------------------------------------------------
%% Fixed wire
%% ------------------------------------------------------------------

encode_valid(#{network_identity := Network,
               signing_public_key := PublicKey,
               operation_id := OperationId,
               agent_namespace := Namespace,
               agent_genesis_anchor := Anchor,
               agent_instance_text := InstanceText,
               mode := Mode,
               parser_version := ParserVersion,
               not_after_ms := NotAfter,
               goal_text := GoalText}) ->
    NamespaceBytes = byte_size(Namespace),
    InstanceBytes = byte_size(InstanceText),
    GoalBytes = byte_size(GoalText),
    ModeTag = mode_tag(Mode),
    <<?DOMAIN/binary, Network/binary, PublicKey/binary, OperationId/binary,
      NamespaceBytes:16/unsigned-big, Namespace/binary, Anchor/binary,
      InstanceBytes:32/unsigned-big, InstanceText/binary,
      ModeTag:8, ParserVersion:8, NotAfter:64/unsigned-big,
      GoalBytes:32/unsigned-big, GoalText/binary>>.

decode_bounded(<<"quod.agent.goal.v1", 0,
                 Network:32/binary, PublicKey:32/binary,
                 OperationId:32/binary, NamespaceBytes:16/unsigned-big,
                 Rest/binary>>) ->
    case Rest of
        <<Namespace:NamespaceBytes/binary, Anchor:32/binary,
          InstanceBytes:32/unsigned-big,
          InstanceText:InstanceBytes/binary, ModeTag:8,
          ParserVersion:8, NotAfter:64/unsigned-big,
          GoalBytes:32/unsigned-big, GoalText:GoalBytes/binary>> ->
            case decode_mode(ModeTag) of
                {ok, Mode} ->
                    Request = #{network_identity => Network,
                                signing_public_key => PublicKey,
                                operation_id => OperationId,
                                agent_namespace => Namespace,
                                agent_genesis_anchor => Anchor,
                                agent_instance_text => InstanceText,
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

validate_request(Request) when is_map(Request), map_size(Request) =:= 10 ->
    case Request of
        #{network_identity := <<_:256>>,
          signing_public_key := <<_:256>>,
          operation_id := <<_:256>>,
          agent_namespace := Namespace,
          agent_genesis_anchor := <<_:256>>,
          agent_instance_text := InstanceText,
          mode := Mode,
          parser_version := ParserVersion,
          not_after_ms := NotAfter,
          goal_text := GoalText} ->
            case quod_client_goal_parser:supported_version(ParserVersion) of
                true -> validate_scalars(
                          Namespace, InstanceText, Mode, NotAfter, GoalText);
                false -> {error, invalid_request}
            end;
        _ ->
            {error, invalid_request}
    end;
validate_request(_) ->
    {error, invalid_request}.

validate_scalars(Namespace, InstanceText, Mode, NotAfter, GoalText) ->
    case {valid_namespace(Namespace), valid_mode(Mode),
          is_integer(NotAfter) andalso NotAfter > 0 andalso
              NotAfter =< ?MAX_UINT64,
          valid_instance_text(InstanceText), valid_utf8(GoalText)} of
        {false, _, _, _, _} when is_binary(Namespace),
                             byte_size(Namespace) >
                                 ?DIRECTORY_MAX_NAMESPACE_BYTES ->
            {error, {too_large, namespace}};
        {false, _, _, _, _} ->
            {error, invalid_request};
        {_, false, _, _, _} ->
            {error, invalid_request};
        {_, _, _, false, _} when is_binary(InstanceText),
                                  byte_size(InstanceText) >
                                      ?QUOD_CLIENT_AGENT_INSTANCE_TEXT_BYTES ->
            {error, {too_large, agent_instance_text}};
        {_, _, _, false, _} ->
            {error, invalid_request};
        {_, _, false, _, _} ->
            {error, invalid_request};
        {_, _, _, _, false} when is_binary(GoalText),
                              byte_size(GoalText) >
                                  ?QUOD_CLIENT_GOAL_TEXT_BYTES ->
            {error, {too_large, goal_text}};
        {_, _, _, _, false} ->
            {error, invalid_request};
        {true, true, true, true, true} ->
            ok
    end.

valid_instance_text(Text) ->
    is_binary(Text) andalso byte_size(Text) > 0 andalso
        byte_size(Text) =< ?QUOD_CLIENT_AGENT_INSTANCE_TEXT_BYTES andalso
        valid_utf8_bytes(Text).

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
                  parser_version := ParserVersion,
                  agent_namespace := AgentNs,
                  agent_genesis_anchor := AgentAnchor,
                  agent_instance_text := InstanceText} = Request0,
                Bytes, Signature) ->
    case {quod_agent_ref:from_text(
            AgentNs, AgentAnchor, InstanceText, ParserVersion),
          quod_client_goal_parser:parse(GoalText, ParserVersion)} of
        {{ok, #{blob := AgentRef}},
         {ok, #{goal := Goal, variables := Variables}}} ->
            case quod_durable_term:encode_goal(Goal) of
                {ok, GoalBlob} ->
                    Digest = crypto:hash(sha256, Bytes),
                    Evidence0 = #{request => Request0,
                                  request_bytes => Bytes,
                                  request_digest => Digest,
                                  signature => Signature,
                                  agent_ref_blob => AgentRef,
                                  goal => Goal,
                                  goal_blob => GoalBlob,
                                  variables => Variables},
                    OperationRef = make_operation_ref(
                                     AgentNs, AgentAnchor, AgentRef,
                                     maps:get(operation_id, Request0)),
                    {ok, Evidence0#{operation_ref => OperationRef}};
                {error, {too_large, goal}} ->
                    {error, {too_large, goal}};
                {error, _} ->
                    {error, invalid_goal}
            end;
        {{error, {too_large, _}} = Error, _} ->
            Error;
        {_, {error, {too_large, _}} = Error} ->
            Error;
        _ ->
            {error, invalid_goal}
    end.

-doc "Project proof bindings onto the variables named by the signed request.".
-spec named_bindings(evidence(), map()) ->
          {ok, map()} | {error, invalid_result}.
named_bindings(#{variables := Variables}, Bindings)
  when is_list(Variables), is_map(Bindings) ->
    named_bindings(Variables, Bindings, []);
named_bindings(_Evidence, _Bindings) ->
    {error, invalid_result}.

named_bindings([], _Bindings, Named) ->
    {ok, maps:from_list(lists:reverse(Named))};
named_bindings([{Name, Index} | Rest], Bindings, Named)
  when is_binary(Name), is_integer(Index), Index >= 0 ->
    case maps:find(Index, Bindings) of
        {ok, Value} ->
            named_bindings(Rest, Bindings, [{Name, Value} | Named]);
        error ->
            named_bindings(Rest, Bindings, Named)
    end;
named_bindings(_MalformedVariables, _Bindings, _Named) ->
    {error, invalid_result}.

-doc "Replace parser-local named variable ids with their signed binary names.".
-spec durable_bindings(evidence(), map()) ->
          {ok, map()} | {error, invalid_result}.
durable_bindings(Evidence, Bindings) ->
    named_bindings(Evidence, Bindings).

validate_context(_Request, _ExpectedNetwork, _ExpectedTarget,
                 AdmissionMs, _Evidence)
  when not is_integer(AdmissionMs); AdmissionMs < 0 ->
    {error, invalid_admission_time};
validate_context(#{network_identity := Network,
                   agent_namespace := Namespace,
                   agent_genesis_anchor := Anchor,
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

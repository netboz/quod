-module(quod_client_goal_ingress).
-moduledoc """
Authenticated gateway ingress for every agent-signed goal mode.

This module performs one shared session and signature admission, then invokes
the exact target locally or forwards the unchanged signed request through the
bounded node router. The target performs the shared target and materialization
sequence before handing the verified goal to the existing proof engine. It
does not classify predicates or authorize them: the ontology's normal
`can_invoke/4` proof remains the only ACL.  Read, execute and cursor differ
only at the final proof-mode selection.

Foreign scopes carry the same verified request evidence and agent principal;
each target applies its ordinary `can_invoke/4` policy to that principal.
""".

-export([submit/5, resolve_operation/4, cursor_command/4]).
-ifdef(TEST).
-export([test_forward_routes/3]).
-endif.

-include("quod_client_goal_limits.hrl").

-type mode() :: read | execute | cursor.
-type result() ::
        {ok, quod_client_goal:evidence(), term()} | {error, term()}.

-doc "Admit and run or route one signed goal request.".
-spec submit(mode(), binary(), binary(), binary(), term()) -> result().
submit(ExpectedMode, SessionId, RequestBytes, Signature, Peer)
  when ExpectedMode =:= read; ExpectedMode =:= execute;
       ExpectedMode =:= cursor ->
    case quod_client_auth:admit_goal(SessionId, Peer) of
        {ok, Session} ->
            admitted(ExpectedMode, SessionId, Session, RequestBytes,
                     Signature, Peer);
        {error, _} = Error ->
            Error
    end;
submit(_ExpectedMode, _SessionId, _RequestBytes, _Signature, _Peer) ->
    {error, unsupported_goal_mode}.

-doc "Resolve the existing operation named by one exact signed request.".
-spec resolve_operation(binary(), binary(), binary(), term()) -> result().
resolve_operation(SessionId, RequestBytes, Signature, Peer) ->
    case quod_client_auth:admit_goal(SessionId, Peer) of
        {ok, #{public_key := PublicKey}} ->
            resolve_verified_operation(
              PublicKey, RequestBytes, Signature);
        {error, _} = Error ->
            Error
    end.

-doc "Run one authenticated operation on an already-open signed cursor.".
-spec cursor_command(binary(), binary(), next | accept | stop, term()) ->
          result().
cursor_command(SessionId, CursorId, Command, Peer)
  when Command =:= next; Command =:= accept; Command =:= stop ->
    case quod_client_auth:admit_goal(SessionId, Peer) of
        {ok, #{public_key := SigningKey}} ->
            Owner = local_owner(SessionId, SigningKey),
            cursor_owner_command(Owner, CursorId, Command);
        {error, _} = Error ->
            Error
    end;
cursor_command(_SessionId, _CursorId, _Command, _Peer) ->
    {error, bad_request}.

admitted(ExpectedMode, SessionId,
         #{public_key := PublicKey,
           expires_ms := SessionExpires},
         RequestBytes, Signature, Peer) ->
    case quod_client_goal:decode(RequestBytes) of
        {ok, Request} ->
            case request_session_binding(
                   Request, ExpectedMode, PublicKey, SessionExpires) of
                ok ->
                    verified_gateway(
                      SessionId, RequestBytes, Signature,
                      PublicKey, Peer);
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

request_session_binding(
  #{signing_public_key := PublicKey, mode := ExpectedMode,
    not_after_ms := NotAfter}, ExpectedMode, PublicKey, SessionExpires)
  when NotAfter =< SessionExpires ->
    ok;
request_session_binding(
  #{signing_public_key := PublicKey, mode := ExpectedMode},
  ExpectedMode, PublicKey, _SessionExpires) ->
    {error, deadline_exceeds_session};
request_session_binding(#{signing_public_key := PublicKey},
                        _ExpectedMode, PublicKey, _SessionExpires) ->
    {error, unsupported_goal_mode};
request_session_binding(_Request, _ExpectedMode, _PublicKey, _SessionExpires) ->
    {error, session_principal_mismatch}.

resolve_verified_operation(PublicKey, RequestBytes, Signature) ->
    case quod_client_goal:verify(RequestBytes, Signature) of
        {ok, #{request := #{signing_public_key := PublicKey,
                            network_identity := RequestNetwork},
               request_digest := Digest,
               operation_ref := OperationRef} = Evidence} ->
            case network_identity() of
                {ok, RequestNetwork} ->
                    resolved_operation(
                      Evidence, Digest, OperationRef,
                      quod_prolog:outcome(OperationRef));
                {ok, _OtherNetwork} ->
                    {error, wrong_network};
                {error, _} = Error ->
                    Error
            end;
        {ok, _OtherPrincipal} ->
            {error, session_principal_mismatch};
        {error, _} = Error ->
            Error
    end.

resolved_operation(
  Evidence, Digest, OperationRef,
  {ok, #{status := claimed, request_digest := Digest,
         outcome_ref := OutcomeRef} = Claim}) ->
    case quod_prolog:outcome(OutcomeRef) of
        {ok, Outcome} ->
            {ok, Evidence, {operation_outcome, Claim, Outcome}};
        {error, _} ->
            {ok, Evidence, {operation_pending, OperationRef}}
    end;
resolved_operation(Evidence, _Digest, OperationRef, {error, _}) ->
    %% Absence is never permission to create a fresh operation: the request
    %% could be between durable custody and publication on the queried node.
    {ok, Evidence, {operation_pending, OperationRef}};
resolved_operation(
  _Evidence, Digest, _OperationRef,
  {ok, #{status := claimed, request_digest := OtherDigest}})
  when is_binary(OtherDigest), OtherDigest =/= Digest ->
    {error, operation_conflict};
resolved_operation(_Evidence, _Digest, _OperationRef, {ok, _BadClaim}) ->
    {error, outcome_index_corrupt}.

verified_gateway(SessionId, RequestBytes, Signature, PublicKey, Peer) ->
    case quod_client_goal_target:verify_request(RequestBytes, Signature) of
        {ok, #{request := #{signing_public_key := PublicKey},
               agent_ref_blob := AgentRef} = Evidence} ->
            Principal = {agent, AgentRef},
            Owner = local_owner(SessionId, PublicKey),
            execute_gateway(
              Evidence, RequestBytes, Signature, Principal, PublicKey, Peer,
              Owner);
        {ok, _OtherAgent} ->
            {error, session_principal_mismatch};
        {error, _} = Error ->
            Error
    end.

execute_gateway(
  #{request := #{mode := Mode, agent_namespace := Ns,
                 agent_genesis_anchor := Anchor}} = Evidence,
  RequestBytes, Signature, Principal, _PublicKey, Peer, Owner) ->
    CursorBinding = cursor_binding(Mode),
    case quod_client_goal_target:available({Ns, Anchor}) of
        ok ->
            case quod_client_goal_target:prepare_local(
                   Evidence, Peer, Owner, CursorBinding) of
                {ok, {Evidence, Goal, Principal, Owner}} ->
                    quod_client_goal_target:execute(
                      Evidence, Goal, Principal, Owner, CursorBinding);
                {error, _} = Error -> Error
            end;
        {error, wrong_target} ->
            {error, wrong_target};
        {error, _NotLocal} ->
            forward_gateway(
              Evidence, RequestBytes, Signature, Owner, CursorBinding)
    end.

cursor_binding(cursor) -> crypto:strong_rand_bytes(32);
cursor_binding(read) -> none;
cursor_binding(execute) -> none.

forward_gateway(
  #{request := #{agent_namespace := Ns,
                 agent_genesis_anchor := Anchor}} = Evidence,
  RequestBytes, Signature, Owner, CursorBinding) ->
    case quod_directory:validator_routes(Ns, Anchor) of
        {ok, Routes} when Routes =/= [] ->
            TraceCarrier = quod_trace:inject(quod_trace:context()),
            ExpiresMs = maps:get(not_after_ms, maps:get(request, Evidence)),
            forward_routes(
              Routes, Evidence, RequestBytes, Signature, Owner,
              CursorBinding, TraceCarrier, ExpiresMs);
        {ok, []} -> {error, signed_target_unavailable};
        {error, anchor_conflict} -> {error, {anchor_conflict, Ns}};
        {error, _} -> {error, signed_target_unavailable}
    end.

forward_routes([], _Evidence, _RequestBytes, _Signature, _Owner,
               _CursorBinding, _TraceCarrier, _ExpiresMs) ->
    {error, signed_target_unavailable};
forward_routes([Route | Rest], Evidence, RequestBytes, Signature, Owner,
               CursorBinding, TraceCarrier, ExpiresMs) ->
    Submit = fun quod_client_goal_router:submit/9,
    forward_routes(
      [Route | Rest], Evidence, RequestBytes, Signature, Owner,
      CursorBinding, TraceCarrier, ExpiresMs, Submit).

forward_routes([], _Evidence, _RequestBytes, _Signature, _Owner,
               _CursorBinding, _TraceCarrier, _ExpiresMs, _Submit) ->
    {error, signed_target_unavailable};
forward_routes([Route | Rest], Evidence, RequestBytes, Signature, Owner,
               CursorBinding, TraceCarrier, ExpiresMs, Submit) ->
    TimeoutMs = request_timeout(ExpiresMs),
    case Submit(Route, Owner, Evidence, RequestBytes, Signature, CursorBinding,
                TraceCarrier, ExpiresMs, TimeoutMs) of
        {ok, Evidence, {normalized, _} = Normalized} ->
            {ok, Evidence, Normalized};
        {error, pre_send} ->
            forward_routes(
              Rest, Evidence, RequestBytes, Signature, Owner,
              CursorBinding, TraceCarrier, ExpiresMs, Submit);
        {error, {refused, Reason}}
          when Reason =:= not_ready; Reason =:= busy;
               Reason =:= rate_limited ->
            forward_routes(
              Rest, Evidence, RequestBytes, Signature, Owner,
              CursorBinding, TraceCarrier, ExpiresMs, Submit);
        {error, {uncertain, Evidence}} ->
            uncertain_submit(Evidence);
        {error, unavailable} ->
            uncertain_submit(Evidence, router_unavailable);
        {error, Reason} ->
            {error, Reason}
    end.

-ifdef(TEST).
test_forward_routes(Routes,
                    #{request := #{signing_public_key := SigningKey,
                                   mode := Mode,
                                   not_after_ms := ExpiresMs},
                      request_bytes := RequestBytes,
                      signature := Signature} = Evidence,
                    Submit) when is_function(Submit, 9) ->
    Owner = {session, <<0:256>>, SigningKey},
    forward_routes(Routes, Evidence, RequestBytes, Signature, Owner,
                   cursor_binding(Mode), [], ExpiresMs, Submit).
-endif.

uncertain_submit(Evidence) ->
    uncertain_submit(Evidence, reported).

uncertain_submit(
  #{request := #{mode := execute}} = Evidence, Cause) ->
    Ref = maps:get(operation_ref, Evidence),
    ok = report_gateway_uncertainty(Cause, Ref),
    {ok, Evidence, {normalized, {pending, Ref}}};
uncertain_submit(_Evidence, _Cause) ->
    {error, signed_target_unavailable}.

report_gateway_uncertainty(reported, _Ref) ->
    ok;
report_gateway_uncertainty(Cause, Ref) ->
    quod_client_result:report_outcome_unknown(
      gateway_execute_transport, Cause, Ref).

request_timeout(ExpiresMs) ->
    Remaining = erlang:max(1, ExpiresMs - quod_time:now_ms()),
    erlang:min(Remaining, ?QUOD_CLIENT_GOAL_ROUTER_TIMEOUT_MS).

cursor_owner_command(Owner, CursorId, Command) ->
    case quod_client_cursor:command(Owner, CursorId, Command) of
        {ok, Evidence, Raw} ->
            observe_cursor_outcome(Raw),
            {ok, Evidence,
             {normalized, quod_client_result:normalize(Evidence, Raw)}};
        {error, not_found} ->
            forwarded_cursor_command(Owner, CursorId, Command);
        {error, not_ready} ->
            {error, cursor_not_ready};
        {error, busy} ->
            {error, cursor_busy};
        {error, _} = Error -> Error
    end.

observe_cursor_outcome(Raw) ->
    quod_client_result:observe_outcome_unknown(
      target_cursor, cursor_coordinator, Raw).

forwarded_cursor_command(Owner, CursorId, Command) ->
    case quod_client_goal_router:cursor(
           Owner, CursorId, Command,
           ?QUOD_CLIENT_GOAL_ROUTER_TIMEOUT_MS) of
        {ok, Evidence, {normalized, _} = Normalized} ->
            {ok, Evidence, Normalized};
        {error, {uncertain, Evidence}} when Command =:= accept ->
            {ok, Evidence,
             {normalized, {pending, maps:get(operation_ref, Evidence)}}};
        {error, {uncertain, _Evidence}} ->
            {error, client_cursor_unavailable};
        {error, {refused, _}} ->
            {error, client_cursor_unavailable};
        {error, unavailable} ->
            {error, client_cursor_unavailable};
        {error, not_found} ->
            {error, cursor_not_found};
        {error, busy} ->
            {error, cursor_busy};
        {error, Reason} -> {error, Reason}
    end.

local_owner(SessionId, <<_:256>> = SigningKey) ->
    {session, SessionId, SigningKey}.

network_identity() ->
    case quod_ontology:network_identity() of
        {ok, <<_:256>> = Network} -> {ok, Network};
        _ -> {error, signed_goal_unavailable}
    end.

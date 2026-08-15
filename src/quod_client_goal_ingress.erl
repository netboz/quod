-module(quod_client_goal_ingress).
-moduledoc """
Authenticated local ingress for every user-signed goal mode.

This module performs one shared session, signature, target and materialization
sequence, then hands the verified goal to the existing proof engine.  It does
not classify predicates or authorize them: the ontology's normal
`can_invoke/4` proof remains the only ACL.  Read, execute and cursor differ
only at the final proof-mode selection.

Foreign scopes carry the same verified request evidence and user principal;
each target applies its ordinary `can_invoke/4` policy to that principal.
""".

-export([submit/5, resolve_operation/4, cursor_command/4]).

-type mode() :: read | execute | cursor.
-type result() ::
        {ok, quod_client_goal:evidence(), term()} | {error, term()}.

-doc "Verify, materialize, and run one signed local goal request.".
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
        {ok, #{principal := Principal}} ->
            quod_client_cursor:command(
              SessionId, Principal, CursorId, Command);
        {error, _} = Error ->
            Error
    end;
cursor_command(_SessionId, _CursorId, _Command, _Peer) ->
    {error, bad_request}.

admitted(ExpectedMode, SessionId,
         #{public_key := PublicKey, principal := Principal,
           expires_ms := SessionExpires},
         RequestBytes, Signature, Peer) ->
    case quod_client_goal:decode(RequestBytes) of
        {ok, Request} ->
            case request_session_binding(
                   Request, ExpectedMode, PublicKey, SessionExpires) of
                ok ->
                    verified_context(
                      SessionId, Request, RequestBytes, Signature,
                      Principal, PublicKey, Peer);
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

request_session_binding(
  #{user_public_key := PublicKey, mode := ExpectedMode,
    not_after_ms := NotAfter}, ExpectedMode, PublicKey, SessionExpires)
  when NotAfter =< SessionExpires ->
    ok;
request_session_binding(
  #{user_public_key := PublicKey, mode := ExpectedMode},
  ExpectedMode, PublicKey, _SessionExpires) ->
    {error, deadline_exceeds_session};
request_session_binding(#{user_public_key := PublicKey},
                        _ExpectedMode, PublicKey, _SessionExpires) ->
    {error, unsupported_goal_mode};
request_session_binding(_Request, _ExpectedMode, _PublicKey, _SessionExpires) ->
    {error, session_principal_mismatch}.

resolve_verified_operation(PublicKey, RequestBytes, Signature) ->
    case quod_client_goal:verify(RequestBytes, Signature) of
        {ok, #{request := #{user_public_key := PublicKey,
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
resolved_operation(_Evidence, _Digest, _OperationRef, {ok, _BadClaim}) ->
    {error, outcome_index_corrupt}.

verified_context(SessionId, #{target_namespace := Namespace},
                 RequestBytes, Signature, Principal, PublicKey, Peer) ->
    case {network_identity(), local_target(Namespace)} of
        {{ok, Network}, {ok, Target}} ->
            AdmissionMs = quod_time:now_ms(),
            case quod_client_goal:verify_for(
                   RequestBytes, Signature, Network, Target, AdmissionMs) of
                {ok, Evidence} ->
                    materialized(
                      SessionId, Evidence, Principal, PublicKey, Peer);
                {error, _} = Error ->
                    Error
            end;
        {{error, _} = Error, _} ->
            Error;
        {_, {error, _} = Error} ->
            Error
    end.

materialized(SessionId,
             #{goal_blob := GoalBlob,
               request := #{mode := Mode}} = Evidence,
             Principal, PublicKey, Peer) ->
    %% Re-decode at the owning ontology before callable materialization.  The
    %% canonical parser kept every non-operator symbol opaque; this decode
    %% safely reuses only atoms already owned by the ontology.
    case quod_durable_term:decode_goal(GoalBlob) of
        {ok, OwnerGoal} ->
            case quod_client_auth:materialize_goal(
                   PublicKey, Peer, OwnerGoal) of
                {ok, Goal} ->
                    run(Mode, SessionId, Evidence, Goal, Principal);
                {error, _} = Error ->
                    Error
            end;
        {error, _} ->
            {error, invalid_goal}
    end.

run(cursor, SessionId, Evidence, Goal, Principal) ->
    quod_client_cursor:open(SessionId, Evidence, Goal, Principal);
run(Mode, _SessionId, Evidence, Goal, Principal)
  when Mode =:= read; Mode =:= execute ->
    {ok, Evidence, quod_prolog:execute_signed(Evidence, Goal, Principal)}.

network_identity() ->
    case quod_ontology:network_identity() of
        {ok, <<_:256>> = Network} -> {ok, Network};
        _ -> {error, signed_goal_unavailable}
    end.

local_target(Namespace) ->
    case quod_reg:where({quod_prolog, Namespace}) of
        undefined ->
            {error, signed_target_unavailable};
        _Pid ->
            case quod_simplex:genesis_hash(Namespace) of
                <<_:256>> = Anchor -> {ok, {Namespace, Anchor}};
                undefined -> {error, signed_target_unavailable}
            end
    end.

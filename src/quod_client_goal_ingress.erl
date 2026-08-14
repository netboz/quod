-module(quod_client_goal_ingress).
-moduledoc """
Authenticated local ingress for one user-signed read goal.

This module is the bridge between the browser contract and the existing proof
engine.  It does not dispatch predicates and it does not make authorization
decisions: after binding the live session, signature, network, exact target and
deadline, it materializes the bounded callable vocabulary and calls the normal
read-only proof path with `{user, PublicKey}`.  The ontology's `can_invoke/4`
proof remains the only ACL.

Slice 2 is deliberately local and read-only.  Routing and signed remote-scope
evidence arrive in later reviewed slices; until then the proof layer refuses a
foreign scope rather than substituting the forwarding node's identity.
""".

-export([read/4]).

-type result() ::
        {ok, quod_client_goal:evidence(), term()} | {error, term()}.

-doc "Verify, materialize, and run one signed local read request.".
-spec read(binary(), binary(), binary(), term()) -> result().
read(SessionId, RequestBytes, Signature, Peer) ->
    case quod_client_auth:admit_goal(SessionId, Peer) of
        {ok, Session} ->
            admitted(Session, RequestBytes, Signature, Peer);
        {error, _} = Error ->
            Error
    end.

admitted(#{public_key := PublicKey, principal := Principal,
           expires_ms := SessionExpires},
         RequestBytes, Signature, Peer) ->
    case quod_client_goal:decode(RequestBytes) of
        {ok, Request} ->
            case request_session_binding(Request, PublicKey, SessionExpires) of
                ok -> verified_context(Request, RequestBytes, Signature,
                                       Principal, PublicKey, Peer);
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

request_session_binding(
  #{user_public_key := PublicKey, mode := read,
    not_after_ms := NotAfter}, PublicKey, SessionExpires)
  when NotAfter =< SessionExpires ->
    ok;
request_session_binding(#{user_public_key := PublicKey, mode := read},
                        PublicKey, _SessionExpires) ->
    {error, deadline_exceeds_session};
request_session_binding(#{user_public_key := PublicKey}, PublicKey,
                        _SessionExpires) ->
    {error, unsupported_goal_mode};
request_session_binding(_Request, _PublicKey, _SessionExpires) ->
    {error, session_principal_mismatch}.

verified_context(#{target_namespace := Namespace},
                 RequestBytes, Signature, Principal, PublicKey, Peer) ->
    case {network_identity(), local_target(Namespace)} of
        {{ok, Network}, {ok, Target}} ->
            AdmissionMs = quod_time:now_ms(),
            case quod_client_goal:verify_for(
                   RequestBytes, Signature, Network, Target, AdmissionMs) of
                {ok, Evidence} ->
                    materialized(Evidence, Principal, PublicKey, Peer);
                {error, _} = Error ->
                    Error
            end;
        {{error, _} = Error, _} ->
            Error;
        {_, {error, _} = Error} ->
            Error
    end.

materialized(#{goal_blob := GoalBlob, request :=
                 #{target_namespace := Namespace,
                   target_genesis_anchor := Anchor}} = Evidence,
             Principal, PublicKey, Peer) ->
    %% Re-decode at the owning ontology before callable materialization.  The
    %% canonical parser intentionally kept every non-operator symbol opaque;
    %% this decode safely reuses atoms already owned by the ontology (including
    %% ordinary data constants) while leaving genuinely unknown values opaque.
    case quod_durable_term:decode_goal(GoalBlob) of
        {ok, OwnerGoal} ->
            case quod_client_auth:materialize_goal(
                   PublicKey, Peer, OwnerGoal) of
                {ok, MaterializedGoal} ->
                    {ok, Evidence,
                     quod_prolog:prove_ro_as(
                       {Namespace, Anchor}, MaterializedGoal, Principal)};
                {error, _} = Error ->
                    Error
            end;
        {error, _} ->
            {error, invalid_goal}
    end.

network_identity() ->
    case quod_ontology:genesis_anchor(quod_ontology:root_ns()) of
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

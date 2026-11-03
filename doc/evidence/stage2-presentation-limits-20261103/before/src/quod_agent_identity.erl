-module(quod_agent_identity).
-moduledoc """
Canonical proof-scoped agent-identity statement and quorum certificate.

The statement is constructed from a verified signed goal and a certified
current committee view.  Callers can request this one statement; they cannot
ask a validator to sign arbitrary bytes.

The runtime exchange has one terminal response grammar: a signed attestation
or a request-correlated refusal.  Wire V2 introduced the refusal so an
available peer that cannot attest wakes the collector instead of leaving it
parked until the proof deadline.
""".

-include("quod_client_goal_limits.hrl").
-include("quod_proof_limits.hrl").
-include("quod_ingress_limits.hrl").

-export([statement/4, statement_bytes/1, sign/2,
         certificate/3, validate_certificate/1,
         verify/5, route_hints/1, committee_id/1, not_after_ms/1,
         channel/0, encode_request/1, decode_request/1,
         encode_response/1, decode_response/1]).

-define(STATEMENT_DOMAIN, <<"quod.agent.identity.v1", 0>>).
-define(WIRE_DOMAIN, <<"quod.agent.identity.wire", 0>>).
-define(WIRE_VERSION, 2).
-define(CHANNEL, <<"quod.agent.identity">>).
-define(MAX_WIRE_BYTES, (?QUOD_CLIENT_GOAL_REQUEST_BYTES + 32768)).

-type statement() ::
        {agent_identity_v1, <<_:256>>, {binary(), <<_:256>>},
         <<_:256>>, <<_:256>>, binary(), <<_:256>>, <<_:256>>,
         non_neg_integer(), active}.
-type certificate() ::
        {agent_identity_certificate_v1, statement(),
         [{<<_:256>>, <<_:512>>}], [{<<_:256>>, [term()]}]}.
-export_type([statement/0, certificate/0]).

-spec channel() -> binary().
channel() -> ?CHANNEL.

-spec statement(quod_client_goal:evidence(), <<_:256>>, <<_:256>>,
                non_neg_integer()) -> {ok, statement()} | {error, invalid_request}.
statement(
  #{request_digest := <<_:256>> = RequestDigest,
    agent_ref_blob := AgentRef,
    request := #{network_identity := <<_:256>> = Network,
                 agent_namespace := AgentNs,
                 agent_genesis_anchor := <<_:256>> = AgentAnchor,
                 signing_public_key := <<_:256>> = SigningKey,
                 not_after_ms := RequestNotAfter}},
  <<_:256>> = ProofId, <<_:256>> = CommitteeId, NotAfter)
  when is_binary(AgentNs), byte_size(AgentNs) > 0,
       is_binary(AgentRef),
       is_integer(NotAfter), NotAfter >= 0,
       is_integer(RequestNotAfter), NotAfter =< RequestNotAfter ->
    case quod_agent_ref:decode(AgentRef) of
        {ok, #{identity := {AgentNs, AgentAnchor}}} ->
            {ok, {agent_identity_v1, Network,
                  {AgentNs, AgentAnchor}, ProofId, RequestDigest,
                  AgentRef, SigningKey, CommitteeId, NotAfter, active}};
        _ -> {error, invalid_request}
    end;
statement(_Evidence, _ProofId, _CommitteeId, _NotAfter) ->
    {error, invalid_request}.

-spec statement_bytes(statement()) -> {ok, binary()} | {error, invalid_request}.
statement_bytes(Statement) ->
    case valid_statement(Statement) of
        true ->
            Body = term_to_binary(Statement, [deterministic]),
            {ok, <<?STATEMENT_DOMAIN/binary,
                   (byte_size(Body)):32/unsigned-big, Body/binary>>};
        false -> {error, invalid_request}
    end.

-spec sign(statement(), quod_identity:signer()) ->
          {ok, {<<_:256>>, <<_:512>>}} | {error, invalid_request}.
sign(Statement, #{pubkey := <<_:256>> = Signer, key := Key}) ->
    case statement_bytes(Statement) of
        {ok, Bytes} -> {ok, {Signer, quod_identity:sign(Bytes, Key)}};
        {error, _} = Error -> Error
    end;
sign(_Statement, _Signer) ->
    {error, invalid_request}.

-spec certificate(statement(), list(), list()) ->
          {ok, certificate()} | {error, invalid_request}.
certificate(Statement, Signatures, RouteHints) ->
    Candidate = {agent_identity_certificate_v1,
                 Statement, Signatures, RouteHints},
    case validate_certificate(Candidate) of
        true -> {ok, Candidate};
        false -> {error, invalid_request}
    end.

-spec validate_certificate(term()) -> boolean().
validate_certificate(
  {agent_identity_certificate_v1, Statement, Signatures, RouteHints}) ->
    valid_statement(Statement) andalso
        quod_quorum:valid_signature_list(Signatures, ?MAX_VALIDATORS) andalso
        quod_foreign_log:valid_route_candidates(RouteHints);
validate_certificate(_Certificate) -> false.

-spec verify(certificate(), quod_client_goal:evidence(), <<_:256>>, map(),
             non_neg_integer()) -> ok | {error, retry | invalid_request}.
verify(
  Certificate = {agent_identity_certificate_v1, Statement,
                 Signatures, _RouteHints},
  Evidence, ProofId,
  #{identity := Identity, committee := Committee,
    committee_id := CommitteeId}, NowMs)
  when is_integer(NowMs), NowMs >= 0 ->
    case {validate_certificate(Certificate),
          statement(Evidence, ProofId, CommitteeId,
                    statement_not_after(Statement))} of
        {true, {ok, Statement}} ->
            case {statement_identity(Statement) =:= Identity,
                  statement_not_after(Statement) >= NowMs,
                  statement_bytes(Statement)} of
                {true, true, {ok, Bytes}} ->
                    case quod_quorum:verify(Committee, Bytes, Signatures) of
                        true -> ok;
                        false -> {error, invalid_request}
                    end;
                {_, false, _} -> {error, retry};
                _ -> {error, invalid_request}
            end;
        {true, {ok, _OtherStatement}} -> {error, invalid_request};
        _ -> {error, invalid_request}
    end;
verify(_Certificate, _Evidence, _ProofId, _View, _NowMs) ->
    {error, invalid_request}.

-spec route_hints(certificate()) -> [{<<_:256>>, [term()]}].
route_hints({agent_identity_certificate_v1, _Statement, _Sigs, Routes}) ->
    Routes.

-spec committee_id(certificate()) -> <<_:256>>.
committee_id({agent_identity_certificate_v1, Statement, _Sigs, _Routes}) ->
    statement_committee_id(Statement).

-spec not_after_ms(certificate()) -> non_neg_integer().
not_after_ms({agent_identity_certificate_v1, Statement, _Sigs, _Routes}) ->
    statement_not_after(Statement).

-spec encode_request(term()) -> {ok, binary()} | {error, invalid_request}.
encode_request(
  {agent_identity_request, <<_:128>>, <<_:256>>,
   RequestBytes, <<_:512>>, NotAfter} = Request)
  when is_binary(RequestBytes),
       byte_size(RequestBytes) =< ?QUOD_CLIENT_GOAL_REQUEST_BYTES,
       is_integer(NotAfter), NotAfter >= 0 ->
    encode_wire(request, Request);
encode_request(_Request) -> {error, invalid_request}.

-spec decode_request(binary()) -> {ok, term()} | {error, invalid_request}.
decode_request(Bytes) -> decode_wire(request, Bytes).

-spec encode_response(term()) -> {ok, binary()} | {error, invalid_request}.
encode_response(
  {agent_identity_response, <<_:128>>, <<_:256>>, <<_:256>>,
   NotAfter, <<_:512>>} = Response)
  when is_integer(NotAfter), NotAfter >= 0 ->
    encode_wire(response, Response);
encode_response(
  {agent_identity_refusal, <<_:128>>} = Response) ->
    encode_wire(response, Response);
encode_response(_Response) -> {error, invalid_request}.

-spec decode_response(binary()) -> {ok, term()} | {error, invalid_request}.
decode_response(Bytes) -> decode_wire(response, Bytes).

encode_wire(Kind, Value) ->
    Encoded = term_to_binary(
                {?WIRE_DOMAIN, ?WIRE_VERSION, Kind, Value}, [deterministic]),
    case byte_size(Encoded) =< ?MAX_WIRE_BYTES of
        true -> {ok, Encoded};
        false -> {error, invalid_request}
    end.

decode_wire(Kind, Bytes) when is_binary(Bytes), byte_size(Bytes) =< ?MAX_WIRE_BYTES ->
    try binary_to_term(Bytes, [safe]) of
        {?WIRE_DOMAIN, ?WIRE_VERSION, Kind, Value} ->
            validate_decoded(Kind, Value);
        _ -> {error, invalid_request}
    catch error:badarg -> {error, invalid_request}
    end;
decode_wire(_Kind, _Bytes) -> {error, invalid_request}.

validate_decoded(request, Value) ->
    case encode_request(Value) of {ok, _} -> {ok, Value}; _ -> {error, invalid_request} end;
validate_decoded(response, Value) ->
    case encode_response(Value) of {ok, _} -> {ok, Value}; _ -> {error, invalid_request} end.

valid_statement(
  {agent_identity_v1, <<_:256>>, {Ns, <<_:256>>}, <<_:256>>,
   <<_:256>>, AgentRef, <<_:256>>, <<_:256>>, NotAfter, active}) ->
    is_binary(Ns) andalso byte_size(Ns) > 0 andalso
        is_binary(AgentRef) andalso is_integer(NotAfter) andalso NotAfter >= 0 andalso
        quod_agent_ref:valid_principal({agent, AgentRef});
valid_statement(_Statement) -> false.

statement_identity(
  {agent_identity_v1, _Network, Identity, _ProofId, _RequestDigest,
   _AgentRef, _SigningKey, _CommitteeId, _NotAfter, active}) -> Identity.
statement_committee_id(
  {agent_identity_v1, _Network, _Identity, _ProofId, _RequestDigest,
   _AgentRef, _SigningKey, CommitteeId, _NotAfter, active}) -> CommitteeId.
statement_not_after(
  {agent_identity_v1, _Network, _Identity, _ProofId, _RequestDigest,
   _AgentRef, _SigningKey, _CommitteeId, NotAfter, active}) -> NotAfter.

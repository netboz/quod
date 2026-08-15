-module(quod_client_goal_endpoint).
-moduledoc """
Process-free wire boundary for signed client goals forwarded between nodes.

The codec owns only one fixed channel, deterministic framing, bounded
atom-safe decoding, a closed request/reply algebra, and exact correlation.
Authenticated peer identity is deliberately absent from the payload and comes
only from `quod_link:peer_key/1`. Goal execution, rate admission, cursor state,
ACL, transactions, and outcomes remain with their existing owners.
""".

-include("quod_client_goal_limits.hrl").
-include("quod_transport_limits.hrl").

-export([channel/0, encode_request/1, encode_response/1,
         decode_response/1,
         route_request/1, route_response/1,
         request_id/1, response_id/1, correlates/2]).
-export_type([request/0, response/0]).

-define(DOMAIN, quod_client_goal_endpoint).
-define(VERSION, 1).
-define(CHANNEL, quod_client_goal_v1).

-if(?QUOD_CLIENT_GOAL_MAX_ENVELOPE_BYTES >=
    ?QUOD_TRANSPORT_MAX_FRAME_BYTES).
-error("client-goal endpoint envelope must stay below the transport frame bound").
-endif.

-type request_id() :: <<_:?QUOD_CLIENT_GOAL_REQUEST_ID_BITS>>.
-type cursor_id() :: <<_:256>>.
-type cursor_binding() :: none | cursor_id().
-type request() ::
        {submit, request_id(), binary(), <<_:512>>, cursor_binding(), list()} |
        {cursor, request_id(), cursor_id(), next | accept | stop}.
-type refusal() :: not_ready | busy | rate_limited.
-type terminal_error() ::
        invalid_request | invalid_signature | wrong_network | wrong_target |
        expired | operation_conflict.
-type response() ::
        {refused, request_id(), refusal()} |
        {result, request_id(), binary()} |
        {cursor_result, request_id(), cursor_id(), binary()} |
        {error, request_id(), terminal_error()}.
-type wire_error() ::
        {error, result_too_large |
                {too_large, client_goal_endpoint} |
                {protocol_error, atom()}}.

-doc "The one bidirectional signed-goal channel shared by all namespaces.".
-spec channel() -> binary().
channel() -> term_to_binary(?CHANNEL, [deterministic]).

-spec encode_request(request()) -> {ok, binary()} | wire_error().
encode_request(Request) -> encode(Request, request).

-spec encode_response(response()) -> {ok, binary()} | wire_error().
encode_response(Response) -> encode(Response, response).

encode(Inner, Direction) ->
    case validate_direction(Inner, Direction) of
        ok ->
            InnerBlob = term_to_binary(Inner, [deterministic]),
            Envelope = term_to_binary(
                         {?DOMAIN, ?VERSION, InnerBlob}, [deterministic]),
            case byte_size(Envelope) =<
                 ?QUOD_CLIENT_GOAL_MAX_ENVELOPE_BYTES of
                true -> {ok, Envelope};
                false -> too_large()
            end;
        {error, _} = Error ->
            Error
    end.

-spec decode_response(term()) -> {ok, response()} | wire_error().
decode_response(Envelope) -> decode(Envelope, response).

-doc "Admit and correlate a request frame while keeping signed bytes opaque.".
-spec route_request(term()) -> {ok, request()} | wire_error().
route_request(Envelope) -> decode(Envelope, routed_request).

-doc "Admit and correlate a response frame while keeping result bytes opaque.".
-spec route_response(term()) -> {ok, response()} | wire_error().
route_response(Envelope) -> decode(Envelope, routed_response).

decode(Envelope, Direction)
  when is_binary(Envelope),
       byte_size(Envelope) =< ?QUOD_CLIENT_GOAL_MAX_ENVELOPE_BYTES ->
    case quod_safe_term:decode(
           Envelope, ?QUOD_CLIENT_GOAL_MAX_ENVELOPE_BYTES) of
        {ok, {?DOMAIN, ?VERSION, InnerBlob} = Outer}
          when is_binary(InnerBlob) ->
            case term_to_binary(Outer, [deterministic]) =:= Envelope of
                true -> decode_inner(InnerBlob, Direction);
                false -> protocol_error(non_canonical)
            end;
        {ok, {?DOMAIN, OtherVersion, _}}
          when OtherVersion =/= ?VERSION ->
            protocol_error(wrong_version);
        {ok, {OtherDomain, _, _}} when OtherDomain =/= ?DOMAIN ->
            protocol_error(bad_domain);
        {ok, _} ->
            protocol_error(bad_shape);
        {error, _} ->
            protocol_error(bad_etf)
    end;
decode(Envelope, _Direction) when is_binary(Envelope) ->
    too_large();
decode(_Envelope, _Direction) ->
    protocol_error(bad_etf).

decode_inner(InnerBlob, Direction) ->
    case quod_safe_term:decode(
           InnerBlob, ?QUOD_CLIENT_GOAL_MAX_ENVELOPE_BYTES) of
        {ok, Inner} ->
            case term_to_binary(Inner, [deterministic]) =:= InnerBlob of
                false -> protocol_error(non_canonical);
                true ->
                    case validate_direction(Inner, Direction) of
                        ok -> {ok, Inner};
                        {error, _} = Error -> Error
                    end
            end;
        {error, _} ->
            protocol_error(bad_etf)
    end.

validate_direction(Term, request) -> validate_request(Term);
validate_direction(Term, response) -> validate_response(Term);
validate_direction(Term, routed_request) -> validate_routed_request(Term);
validate_direction(Term, routed_response) -> validate_routed_response(Term).

validate_routed_request(
  {submit, RequestId, RequestBytes, Signature, CursorId, TraceCarrier}) ->
    case {valid_request_id(RequestId), valid_signed_request_blob(RequestBytes),
          valid_signature(Signature), valid_cursor_binding(CursorId),
          quod_trace:valid_carrier(TraceCarrier)} of
        {true, true, true, true, true} -> ok;
        {false, _, _, _, _} -> protocol_error(bad_request_id);
        {_, false, _, _, _} -> protocol_error(bad_request);
        {_, _, false, _, _} -> protocol_error(bad_signature);
        {_, _, _, false, _} -> protocol_error(bad_cursor_id);
        {_, _, _, _, false} -> protocol_error(bad_trace)
    end;
validate_routed_request(Request = {cursor, _, _, _}) ->
    validate_request(Request);
validate_routed_request(_) -> protocol_error(bad_shape).

validate_routed_response({result, RequestId, ResultBlob}) ->
    validate_opaque_result(RequestId, ResultBlob);
validate_routed_response(
  {cursor_result, RequestId, CursorId, ResultBlob}) ->
    case {valid_request_id(RequestId), valid_cursor_id(CursorId),
          valid_result_blob(ResultBlob)} of
        {true, true, true} -> ok;
        {false, _, _} -> protocol_error(bad_request_id);
        {_, false, _} -> protocol_error(bad_cursor_id);
        {_, _, false} -> protocol_error(bad_result)
    end;
validate_routed_response(Response) -> validate_response(Response).

validate_opaque_result(RequestId, ResultBlob) ->
    case {valid_request_id(RequestId), valid_result_blob(ResultBlob)} of
        {true, true} -> ok;
        {false, _} -> protocol_error(bad_request_id);
        {_, false} -> protocol_error(bad_result)
    end.

valid_result_blob(Blob) ->
    is_binary(Blob) andalso
        byte_size(Blob) =< ?QUOD_CLIENT_GOAL_MAX_REPLY_BYTES.

validate_request(
  {submit, RequestId, RequestBytes, Signature, CursorId, TraceCarrier}) ->
    case {valid_request_id(RequestId), valid_signed_request(RequestBytes),
          valid_signature(Signature), valid_cursor_binding(CursorId),
          quod_trace:valid_carrier(TraceCarrier)} of
        {true, true, true, true, true} -> ok;
        {false, _, _, _, _} -> protocol_error(bad_request_id);
        {_, false, _, _, _} -> protocol_error(bad_request);
        {_, _, false, _, _} -> protocol_error(bad_signature);
        {_, _, _, false, _} -> protocol_error(bad_cursor_id);
        {_, _, _, _, false} -> protocol_error(bad_trace)
    end;
validate_request({cursor, RequestId, CursorId, Command}) ->
    case {valid_request_id(RequestId), valid_cursor_id(CursorId),
          valid_cursor_command(Command)} of
        {true, true, true} -> ok;
        {false, _, _} -> protocol_error(bad_request_id);
        {_, false, _} -> protocol_error(bad_cursor_id);
        {_, _, false} -> protocol_error(bad_command)
    end;
validate_request(_) ->
    protocol_error(bad_shape).

validate_response({refused, RequestId, Reason}) ->
    validate_response_fields(RequestId, valid_refusal(Reason));
validate_response({result, RequestId, ResultBlob}) ->
    validate_result_response(RequestId, ResultBlob);
validate_response({cursor_result, RequestId, CursorId, ResultBlob}) ->
    case {valid_request_id(RequestId), valid_cursor_id(CursorId),
          quod_client_result:decode(ResultBlob)} of
        {true, true, {ok, _}} -> ok;
        {false, _, _} -> protocol_error(bad_request_id);
        {_, false, _} -> protocol_error(bad_cursor_id);
        {_, _, {error, result_too_large}} -> {error, result_too_large};
        _ -> protocol_error(bad_result)
    end;
validate_response({error, RequestId, Reason}) ->
    validate_response_fields(RequestId, valid_terminal_error(Reason));
validate_response(_) ->
    protocol_error(bad_shape).

validate_response_fields(RequestId, ValidFields) ->
    case {valid_request_id(RequestId), ValidFields} of
        {true, true} -> ok;
        {false, _} -> protocol_error(bad_request_id);
        {_, false} -> protocol_error(bad_shape)
    end.

validate_result_response(RequestId, ResultBlob) ->
    case {valid_request_id(RequestId), quod_client_result:decode(ResultBlob)} of
        {true, {ok, _}} -> ok;
        {false, _} -> protocol_error(bad_request_id);
        {_, {error, result_too_large}} -> {error, result_too_large};
        _ -> protocol_error(bad_result)
    end.

valid_signed_request(RequestBytes)
  when is_binary(RequestBytes),
       byte_size(RequestBytes) =< ?QUOD_CLIENT_GOAL_REQUEST_BYTES ->
    case quod_client_goal:decode(RequestBytes) of
        {ok, _Request} -> true;
        {error, _} -> false
    end;
valid_signed_request(_) -> false.

valid_signed_request_blob(RequestBytes) ->
    is_binary(RequestBytes) andalso
        byte_size(RequestBytes) =< ?QUOD_CLIENT_GOAL_REQUEST_BYTES.

valid_signature(<<_:512>>) -> true;
valid_signature(_) -> false.

valid_request_id(<<_:?QUOD_CLIENT_GOAL_REQUEST_ID_BITS>>) -> true;
valid_request_id(_) -> false.

valid_cursor_binding(none) -> true;
valid_cursor_binding(CursorId) -> valid_cursor_id(CursorId).

valid_cursor_id(<<_:256>>) -> true;
valid_cursor_id(_) -> false.

valid_cursor_command(next) -> true;
valid_cursor_command(accept) -> true;
valid_cursor_command(stop) -> true;
valid_cursor_command(_) -> false.

valid_refusal(not_ready) -> true;
valid_refusal(busy) -> true;
valid_refusal(rate_limited) -> true;
valid_refusal(_) -> false.

valid_terminal_error(invalid_request) -> true;
valid_terminal_error(invalid_signature) -> true;
valid_terminal_error(wrong_network) -> true;
valid_terminal_error(wrong_target) -> true;
valid_terminal_error(expired) -> true;
valid_terminal_error(operation_conflict) -> true;
valid_terminal_error(_) -> false.

-spec request_id(term()) -> request_id() | error.
request_id({submit, RequestId, _, _, _, _}) -> valid_id(RequestId);
request_id({cursor, RequestId, _, _}) -> valid_id(RequestId);
request_id(_) -> error.

-spec response_id(term()) -> request_id() | error.
response_id({refused, RequestId, _}) -> valid_id(RequestId);
response_id({result, RequestId, _}) -> valid_id(RequestId);
response_id({cursor_result, RequestId, _, _}) -> valid_id(RequestId);
response_id({error, RequestId, _}) -> valid_id(RequestId);
response_id(_) -> error.

valid_id(RequestId) ->
    case valid_request_id(RequestId) of true -> RequestId; false -> error end.

-doc "Require exact request id and cursor id correlation.".
-spec correlates(request(), response()) -> boolean().
correlates(Request, Response) ->
    case request_id(Request) =/= error andalso
         request_id(Request) =:= response_id(Response) of
        false -> false;
        true -> cursor_correlates(Request, Response)
    end.

cursor_correlates({submit, _, _, _, none, _},
                  {result, _, _}) -> true;
cursor_correlates({submit, _, _, _, CursorId, _},
                  {cursor_result, _, CursorId, _}) when CursorId =/= none -> true;
cursor_correlates({cursor, _, CursorId, _},
                  {cursor_result, _, CursorId, _}) -> true;
cursor_correlates(_Request, {refused, _, _}) -> true;
cursor_correlates(_Request, {error, _, _}) -> true;
cursor_correlates(_Request, _Response) -> false.

too_large() -> {error, {too_large, client_goal_endpoint}}.
protocol_error(Kind) -> {error, {protocol_error, Kind}}.

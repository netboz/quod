-module(quod_trace).
-moduledoc """
Small OpenTelemetry boundary for Quod.

Tracing is disabled by default in `config/sys.config`. A deployment enables the
OTLP exporter and sampler through standard `OTEL_*` environment variables. All
exporting uses the SDK batch processor, so a collector is never contacted from
the consensus or proof hot path.

Contexts are transient process/wire metadata. They must never be added to a
`#transaction{}`, canonical signature bytes, a block, or the durable ledger.
Only W3C Trace Context is propagated between validators; baggage is deliberately
excluded from the authenticated relay surface.
""".

-export([context/0, with_span/5, with_optional_span/5,
         start_span/4, finish_span/2,
         set_attributes/2, add_event/3, inject/1, extract/1,
         valid_carrier/1, tx_id/1, result/2]).

-define(MAX_CARRIER_FIELDS, 2).
-define(MAX_CARRIER_VALUE_BYTES, 512).

-type context() :: otel_ctx:t().
-type span_ctx() :: opentelemetry:span_ctx().
-export_type([context/0, span_ctx/0]).

-spec context() -> context().
context() -> otel_ctx:get_current().

-spec with_span(context(), binary(), atom(), map(), fun((span_ctx()) -> T)) -> T.
with_span(Ctx, Name, Kind, Attributes, Fun) ->
    otel_tracer:with_span(
      Ctx, tracer(), Name, #{kind => Kind, attributes => Attributes}, Fun).

-spec with_optional_span(context() | undefined, binary(), atom(), map(),
                         fun(() -> T)) -> T.
with_optional_span(undefined, _Name, _Kind, _Attributes, Fun) ->
    Fun();
with_optional_span(Ctx, Name, Kind, Attributes, Fun) ->
    with_span(Ctx, Name, Kind, Attributes, fun(_SpanCtx) -> Fun() end).

-doc "Start a span that another callback will finish; returns its child context.".
-spec start_span(context(), binary(), atom(), map()) -> {context(), span_ctx()}.
start_span(Ctx, Name, Kind, Attributes) ->
    SpanCtx = otel_tracer:start_span(
                Ctx, tracer(), Name,
                #{kind => Kind, attributes => Attributes}),
    {otel_tracer:set_current_span(Ctx, SpanCtx), SpanCtx}.

-spec finish_span(span_ctx(), term()) -> ok.
finish_span(SpanCtx, Result) ->
    _ = result(SpanCtx, Result),
    _ = otel_span:end_span(SpanCtx),
    ok.

-spec result(span_ctx(), term()) -> boolean().
result(SpanCtx, Result) ->
    case outcome(Result) of
        {ok, Value} ->
            _ = otel_span:set_attribute(SpanCtx, 'quod.outcome', Value),
            otel_span:set_status(SpanCtx, ok);
        {error, Value} ->
            _ = otel_span:set_attribute(SpanCtx, 'quod.outcome', Value),
            otel_span:set_status(SpanCtx, error)
    end.

-spec set_attributes(span_ctx(), map()) -> boolean().
set_attributes(SpanCtx, Attributes) ->
    otel_span:set_attributes(SpanCtx, Attributes).

-spec add_event(context(), binary(), map()) -> boolean().
add_event(Ctx, Name, Attributes) ->
    otel_span:add_event(otel_tracer:current_span_ctx(Ctx), Name, Attributes).

-doc "Encode only W3C traceparent/tracestate for a relay envelope.".
-spec inject(context()) -> [{binary(), binary()}].
inject(Ctx) ->
    otel_propagator_text_map:inject_from(
      Ctx, otel_propagator_trace_context, []).

-doc "Decode a validated relay carrier into an otherwise-empty context.".
-spec extract(term()) -> context().
extract(Carrier) ->
    case valid_carrier(Carrier) of
        true ->
            otel_propagator_text_map:extract_to(
              otel_ctx:new(), otel_propagator_trace_context, Carrier);
        false ->
            otel_ctx:new()
    end.

-spec valid_carrier(term()) -> boolean().
valid_carrier(Carrier) when is_list(Carrier),
                            length(Carrier) =< ?MAX_CARRIER_FIELDS ->
    lists:all(fun valid_carrier_field/1, Carrier);
valid_carrier(_Carrier) ->
    false.

-spec tx_id(binary()) -> binary().
tx_id(Id) when is_binary(Id) -> binary:encode_hex(Id, lowercase).

tracer() -> opentelemetry:get_application_tracer(?MODULE).

valid_carrier_field({Key, Value})
  when is_binary(Key), is_binary(Value),
       byte_size(Value) =< ?MAX_CARRIER_VALUE_BYTES ->
    Key =:= <<"traceparent">> orelse Key =:= <<"tracestate">>;
valid_carrier_field(_) ->
    false.

outcome({ok, _, _}) -> {ok, <<"ok">>};
outcome({ok, _}) -> {ok, <<"ok">>};
outcome(ok) -> {ok, <<"ok">>};
outcome(fail) -> {error, <<"fail">>};
outcome({error, Reason}) -> {error, reason(Reason)};
outcome({error, Reason, _Detail}) -> {error, reason(Reason)};
outcome(_) -> {ok, <<"ok">>}.

reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
reason({Reason, _}) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
reason({Reason, _, _}) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
reason(_) -> <<"error">>.

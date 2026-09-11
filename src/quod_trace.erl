-module(quod_trace).
-include("quod_c4_attempt.hrl").
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

-export([context/0, shared_context/1,
         with_context/2, with_span/5, with_span/6, with_optional_span/5,
         with_owner_turn/2, with_owner_step/2,
         start_span/4, finish_span/2,
         set_attributes/2, add_event/3, inject/1, extract/1,
         valid_carrier/1, tx_id/1, result/2]).

-define(MAX_CARRIER_FIELDS, 2).
-define(MAX_CARRIER_VALUE_BYTES, 512).
-define(OWNER_SEQUENCE, {?MODULE, owner_sequence}).
-define(OWNER_CONTEXT, {?MODULE, owner_context}).

-type context() :: otel_ctx:t().
-type span_ctx() :: opentelemetry:span_ctx().
-export_type([context/0, span_ctx/0]).

-spec context() -> context().
context() -> otel_ctx:get_current().

-doc """
Choose one parent for shared work and link its other participating spans.

Prefer the first recording span so an earlier unsampled request cannot hide
shared work. Otherwise preserve the first valid parent's sampling decision;
never manufacture a root. The returned context carries only the SDK span,
not process-local values or baggage from any participating request.
""".
-spec shared_context([term()]) -> none | {context(), [opentelemetry:link()]}.
shared_context(SpanContexts) ->
    Spans = lists:uniq([Span || Span <- SpanContexts, otel_span:is_valid(Span)]),
    {Recording, Unrecorded} = lists:partition(fun otel_span:is_recording/1, Spans),
    case Recording ++ Unrecorded of
        [] -> none;
        [Parent | Others] ->
            {otel_tracer:set_current_span(otel_ctx:new(), Parent),
             opentelemetry:links(Others)}
    end.

-doc "Attach transient request context for one callback without creating a span.".
-spec with_context(context(), fun(() -> T)) -> T.
with_context(Ctx, Fun) ->
    Token = otel_ctx:attach(Ctx),
    try Fun()
    after otel_ctx:detach(Token)
    end.

-spec with_span(context(), binary(), atom(), map(), fun((span_ctx()) -> T)) -> T.
with_span(Ctx, Name, Kind, Attributes, Fun) ->
    with_span(Ctx, Name, Kind, Attributes, [], Fun).

-doc "Trace shared work once, with SDK links to the other participating spans.".
-spec with_span(context(), binary(), atom(), map(), [opentelemetry:link()],
                fun((span_ctx()) -> T)) -> T.
with_span(Ctx, Name, Kind, Attributes, Links, Fun) ->
    otel_tracer:with_span(
      Ctx, tracer(), Name,
      #{kind => Kind, attributes => trace_attributes(Attributes), links => Links},
      Fun).

-spec with_optional_span(context() | undefined, binary(), atom(), map(),
                         fun(() -> T)) -> T.
with_optional_span(undefined, _Name, _Kind, _Attributes, Fun) ->
    Fun();
with_optional_span(Ctx, Name, Kind, Attributes, Fun) ->
    with_span(Ctx, Name, Kind, Attributes, fun(_SpanCtx) -> Fun() end).

-doc """
Opt-in synchronous owner occupancy, independent of request sampling/parenting.

The caller gates this diagnostic. One root per callback also covers autonomous
work. Its incarnation and sequence are process-local, constant-space diagnostics,
not consensus state; sequence gaps expose sampled/dropped turns. The active
diagnostic context is scoped with try/after and NEVER attached to the SDK ambient
context: existing request parenting and asynchronous propagation stay unchanged.
Wall duration includes descheduling; reductions are not CPU time. OTP actions
returned by the callback, internal event queues and time outside it are excluded.
""".
-spec with_owner_turn(map(), fun(() -> T)) -> T.
with_owner_turn(Attributes, Fun) ->
    {Incarnation, Sequence} = case get(?OWNER_SEQUENCE) of
        undefined -> {binary:encode_hex(crypto:strong_rand_bytes(16), lowercase), 1};
        {Id, Previous} -> {Id, Previous + 1}
    end,
    put(?OWNER_SEQUENCE, {Incarnation, Sequence}),
    Before = owner_observation(),
    {Ctx, Span} = start_span(otel_ctx:new(), <<"quod.consensus.owner_turn">>, internal,
        Attributes#{'quod.owner.incarnation' => Incarnation,
                    'quod.owner.sequence' => Sequence,
                    'quod.owner.pid' => list_to_binary(pid_to_list(self()))}),
    PreviousContext = put(?OWNER_CONTEXT, Ctx),
    try Fun()
    after
        After = owner_observation(),
        restore_owner_context(PreviousContext),
        _ = set_attributes(Span, owner_observation_attributes(Before, After)),
        %% No result/error payload is inspected or serialized, even on an exit.
        _ = otel_span:end_span(Span)
    end.

-doc "A synchronous substep of the current diagnostic turn, not a request span.".
-spec with_owner_step(atom(), fun(() -> T)) -> T.
with_owner_step(Step, Fun) ->
    case get(?OWNER_CONTEXT) of
        undefined -> Fun();
        Parent ->
            {Ctx, Span} = start_span(Parent, <<"quod.consensus.owner_step">>, internal,
                                    #{'quod.owner.step' => atom_to_binary(Step)}),
            put(?OWNER_CONTEXT, Ctx),
            try Fun()
            after
                restore_owner_context(Parent),
                _ = otel_span:end_span(Span)
            end
    end.

restore_owner_context(undefined) -> erase(?OWNER_CONTEXT);
restore_owner_context(Ctx) -> put(?OWNER_CONTEXT, Ctx).

owner_observation() ->
    Time = erlang:monotonic_time(nanosecond),
    [{message_queue_len, Queue}, {reductions, Reductions}] =
        process_info(self(), [message_queue_len, reductions]),
    {Time, Queue, Reductions}.

owner_observation_attributes({Start, QueueBefore, ReductionsBefore},
                             {End, QueueAfter, ReductionsAfter}) ->
    #{'quod.owner.start_monotonic_ns' => Start,
      'quod.owner.end_monotonic_ns' => End,
      'quod.owner.wall_ns' => End - Start,
      'quod.owner.queue_before' => QueueBefore,
      'quod.owner.queue_after' => QueueAfter,
      'quod.owner.reductions' => ReductionsAfter - ReductionsBefore}.

-doc "Start a span that another callback will finish; returns its child context.".
-spec start_span(context(), binary(), atom(), map()) -> {context(), span_ctx()}.
start_span(Ctx, Name, Kind, Attributes) ->
    Tracer = tracer(),
    SpanCtx = ?C4_ATTEMPT(Ctx, Tracer, Name, Attributes,
                fun() -> otel_tracer:start_span(
                  Ctx, Tracer, Name,
                  #{kind => Kind, attributes => trace_attributes(Attributes)}) end),
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
    otel_span:set_attributes(SpanCtx, trace_attributes(Attributes)).

-spec add_event(context(), binary(), map()) -> boolean().
add_event(Ctx, Name, Attributes) ->
    otel_span:add_event(
      otel_tracer:current_span_ctx(Ctx), Name, trace_attributes(Attributes)).

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

%% OpenTelemetry binary attributes are UTF-8 strings, while Quod identifiers
%% are arbitrary bytes. Keep that representation rule at the tracing boundary
%% so instrumentation can never turn a valid ledger/cache operation into a
%% failure. Human-readable UTF-8 values remain unchanged; opaque bytes have
%% one deterministic lowercase hexadecimal representation.
trace_attributes(Attributes) when is_map(Attributes) ->
    maps:map(fun(_Key, Value) -> trace_attribute(Value) end, Attributes).

trace_attribute(Value) when is_binary(Value) ->
    case unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> Value;
        _ -> <<"hex:", (binary:encode_hex(Value, lowercase))/binary>>
    end;
trace_attribute(Value) ->
    Value.

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
outcome({fail, _Reasons}) -> {error, <<"fail">>};
outcome({error, Reason}) -> {error, reason(Reason)};
outcome({error, Reason, _Detail}) -> {error, reason(Reason)};
outcome(_) -> {ok, <<"ok">>}.

reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
reason({Reason, _}) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
reason({Reason, _, _}) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
reason(_) -> <<"error">>.

-module(quod_attempt_span).
-moduledoc """
Process-free span-handle mechanics shared by installed coordination owners.

The owner's existing row is the sole token. Callers build their released state
before invoking close/2 and return that state on every survivable path. SDK
loss cannot interrupt operational cleanup. Fatal callback unwind may expose
an old token or discard a tentative one, under the pinned B SDK assumptions.
This module has no registry, process dictionary, process, timer or retry.
""".
-export([owned/3, close/2, event/2, ancestry/1, exit_class/1]).
-export_type([handle/0]).
-type handle() :: none | {quod_trace:context(), quod_trace:span_ctx()}.

-doc "Distinguish a newly allocated handle from a disabled tracer's borrowed parent.".
-spec owned(quod_trace:context(), quod_trace:context(), quod_trace:span_ctx()) -> handle().
owned(ParentCtx, ChildCtx, Span) ->
    Parent = otel_tracer:current_span_ctx(ParentCtx),
    case otel_span:is_valid(Span) andalso
         (not otel_span:is_valid(Parent) orelse
          {otel_span:trace_id(Span), otel_span:span_id(Span)} =/=
          {otel_span:trace_id(Parent), otel_span:span_id(Parent)}) of
        true -> {ChildCtx, Span};
        false -> none
    end.

-doc "End one released token best-effort; ownership is not inferred from is_recording.".
-spec close(handle(), map()) -> ok.
close(none, _Attributes) -> ok;
close({_Ctx, Span}, Attributes) ->
    _ = catch quod_trace:set_attributes(Span, Attributes),
    _ = catch otel_span:end_span(Span),
    ok.

-doc "Add an observation without making it an execution dependency.".
-spec event(handle(), binary()) -> ok.
event(none, _Name) -> ok;
event({Ctx, _Span}, Name) ->
    _ = catch quod_trace:add_event(Ctx, Name, #{}),
    ok.

-doc "Describe only the original caller context actually carried by the owner row.".
-spec ancestry(quod_trace:context()) -> binary().
ancestry(Ctx) ->
    case otel_span:is_valid(otel_tracer:current_span_ctx(Ctx)) of
        true -> <<"retained_parent">>;
        false -> <<"no_retained_parent">>
    end.

-doc "Bounded exit classification; never export an arbitrary exception payload.".
-spec exit_class(term()) -> binary().
exit_class(normal) -> <<"normal">>;
exit_class(shutdown) -> <<"shutdown">>;
exit_class({shutdown, _}) -> <<"shutdown">>;
exit_class(killed) -> <<"killed">>;
exit_class(_) -> <<"abnormal">>.

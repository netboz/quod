-module(quod_c4_attempt).
-moduledoc """
Removable Phase-1 observation at rare coordinator span allocation only.
No callback hooks, execution state, counters, parent replacement, exporter
decoration, messages or new production owner. The independent start denominator
is the existing VM call counter on Simplex's start function, not this record.
Default builds erase the one call site. Metadata failure never changes the SDK
call's result or original exception; missing metadata stays an unknown start.
""".
-export([enable/2, disable/1, allocate_span/5, record/1]).
-define(CONFIG, {?MODULE, window}).

enable(Window, Namespaces)
  when is_binary(Window), byte_size(Window) > 0, byte_size(Window) =< 128,
       is_list(Namespaces), length(Namespaces) > 0, length(Namespaces) =< 64 ->
    true = lists:all(fun(Ns) -> is_binary(Ns) andalso byte_size(Ns) > 0 andalso
                                 byte_size(Ns) =< 256 end, Namespaces),
    %% Serialized by the external observer, not an execution lock API.
    case persistent_term:get(?CONFIG, off) of
        off -> persistent_term:put(?CONFIG,
                 #{window => Window, namespaces => maps:from_keys(Namespaces, true)}), ok;
        _ -> {error, observation_already_enabled}
    end.

disable(Window) ->
    case persistent_term:get(?CONFIG, off) of
        #{window := Window} -> persistent_term:erase(?CONFIG), ok;
        off -> ok;
        _ -> {error, different_observation_window}
    end.

allocate_span(Ctx, Tracer, <<"quod.dtx.coordinate">>,
              #{'quod.namespace' := Ns, 'quod.dtx.group_id' := Group}, Operation)
  when is_binary(Ns), is_binary(Group), byte_size(Group) =:= 64 ->
    case selected(Ns) of
        off -> Operation();
        Window ->
            try Operation() of
                Span -> safe_record(Window, Ns, Group, Ctx, Span, Tracer, returned), Span
            catch Class:Reason:Stack ->
                safe_record(Window, Ns, Group, Ctx, unknown, Tracer, unwind),
                erlang:raise(Class, Reason, Stack)
            end
    end;
allocate_span(_Ctx, _Tracer, _Name, _Attributes, Operation) -> Operation().

selected(Ns) ->
    try persistent_term:get(?CONFIG, off) of
        #{window := W, namespaces := N} when is_map_key(Ns, N) -> W;
        _ -> off
    catch _:_ -> off
    end.

safe_record(Window, Ns, Group, Ctx, Span, Tracer, Edge) ->
    try
        <<_:256>> = binary:decode_hex(Group),
        Metadata = quod_c4_sampler_observation:allocation(
                     otel_tracer:current_span_ctx(Ctx), Span, Tracer),
        ?MODULE:record(#{window => Window, group => Group,
          namespace_digest => binary:encode_hex(crypto:hash(sha256, Ns), lowercase),
          owner => list_to_binary(pid_to_list(self())), edge => Edge,
          monotonic_ns => integer_to_binary(erlang:monotonic_time(nanosecond)),
          metadata => Metadata})
    catch _:_ -> ok
    end.

%% Only closed projected metadata reaches this no-op trace boundary. The
%% external collector traces arity, never original SDK arguments or results.
record(_ClosedMetadata) -> ok.

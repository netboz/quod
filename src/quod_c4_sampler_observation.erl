-module(quod_c4_sampler_observation).
-moduledoc """
Closed metadata for the removable C4 diagnostic. This module does not allocate,
end, sample, attach, export, or look up a span. Callers supply the exact tracer
and the allocation result they already used. No production hook is installed
by this module. Unknown SDK shapes remain unknown, never arbitrary rendering.
""".
-export([describe/1, allocation/3]).
-include_lib("opentelemetry_api/include/opentelemetry.hrl").
-include_lib("opentelemetry/src/otel_tracer.hrl").

describe({otel_tracer_default, #tracer{sampler = Sampler}}) -> sampler(Sampler, 1);
describe(_) -> #{kind => unknown}.

allocation(Parent, Child, Tracer) ->
    %% These are snapshots at allocation return, not a later ETS recording
    %% lookup. Sampled, recording, and newly allocated are different facts.
    P = span(Parent), C = span(Child),
    #{sampler => describe(Tracer), parent => P, span => C,
      parent_class => parent_class(P), allocation_kind => allocated(P, C)}.

span(#span_ctx{trace_id = Trace, span_id = Span, trace_flags = Flags,
               is_recording = Recording, is_remote = Remote})
  when is_integer(Trace), Trace > 0, Trace < (1 bsl 128),
       is_integer(Span), Span > 0, Span < (1 bsl 64),
       is_integer(Flags), Flags >= 0, Flags =< 255,
       is_boolean(Recording), is_boolean(Remote) ->
    #{identity => [binary:encode_hex(<<Trace:128>>, lowercase),
                    binary:encode_hex(<<Span:64>>, lowercase)],
      sampled => (Flags band 1) =/= 0, recording => Recording,
      remote => Remote};
span(undefined) -> #{identity => none};
span(#span_ctx{trace_id = Trace, span_id = Span}) when Trace =:= 0; Span =:= 0 ->
    #{identity => none};
span(_) -> #{identity => unknown}.

allocated(#{identity := Same}, #{identity := Same})
  when is_list(Same) -> borrowed_parent;
allocated(_, #{identity := Identity}) when is_list(Identity) -> new_identity;
allocated(_, #{identity := none}) -> invalid_or_noop;
allocated(_, _) -> unknown.

parent_class(#{identity := none}) -> parentless;
parent_class(#{remote := true, sampled := true}) -> remote_sampled;
parent_class(#{remote := true, sampled := false}) -> remote_unsampled;
parent_class(#{remote := false, sampled := true}) -> local_sampled;
parent_class(#{remote := false, sampled := false}) -> local_unsampled;
parent_class(_) -> unknown.

sampler({otel_sampler_always_on, _, _}, _) -> #{kind => always_on};
sampler({otel_sampler_always_off, _, _}, _) -> #{kind => always_off};
sampler({otel_sampler_trace_id_ratio_based, _,
         #{probability := P, id_upper_bound := Bound}}, _)
  when is_number(P), P >= 0, P =< 1, is_number(Bound),
       Bound >= 0, Bound =< (1 bsl 63) ->
    #{kind => trace_id_ratio, probability => P,
      id_upper_bound => threshold(Bound)};
sampler({otel_sampler_parent_based, _, Config}, Depth)
  when is_map(Config), Depth > 0 ->
    Keys = [root, remote_parent_sampled, remote_parent_not_sampled,
            local_parent_sampled, local_parent_not_sampled],
    #{kind => parent_based, branches => maps:from_list(
      [{K, sampler(maps:get(K, Config, unknown), Depth - 1)} || K <- Keys])};
sampler(_, _) -> #{kind => unknown}.

%% SDK 1.7.0 uses a float for intermediate probabilities despite its integer
%% type annotation. Preserve the exact stored threshold, not a rounded JSON
%% integer or a threshold recomputed from the advertised probability.
threshold(Bound) when is_integer(Bound) ->
    #{encoding => decimal_integer, value => integer_to_binary(Bound)};
threshold(Bound) when is_float(Bound) ->
    #{encoding => ieee754_binary64,
      value => binary:encode_hex(<<Bound:64/float>>, lowercase)}.

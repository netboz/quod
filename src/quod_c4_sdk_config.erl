-module(quod_c4_sdk_config).
-moduledoc """
Read-only, closed SDK configuration snapshot for the Phase-1 diagnostic.
No provider reconfiguration or processor/exporter decoration. Only exact keys
are read; arbitrary application configuration, endpoints and secrets are absent.
The per-attempt record uses the exact tracer actually passed to the SDK.
""".
-export([snapshot/0]).

snapshot() ->
    Application = opentelemetry:get_application(quod_trace),
    Key = case Application of
        '$__default_tracer' -> '$__default_tracer';
        {_, _, _} -> Application;
        Name when is_atom(Name) -> {Name, undefined, undefined}
    end,
    #{schema => <<"quod.c4.sdk-config/v1">>,
      node => atom_to_binary(node()),
      observed_system_ms => integer_to_binary(erlang:system_time(millisecond)),
      cached_application_sampler => sampler(Key),
      cached_default_sampler => sampler('$__default_tracer'),
      requested_sampler => sampler_name(os:getenv("OTEL_TRACES_SAMPLER")),
      requested_ratio => ratio(os:getenv("OTEL_TRACES_SAMPLER_ARG"))}.

sampler(Key) -> quod_c4_sampler_observation:describe(
    persistent_term:get({opentelemetry, global, tracer, Key}, unknown)).
sampler_name(false) -> unset;
sampler_name("parentbased_traceidratio") -> parentbased_traceidratio;
sampler_name("always_on") -> always_on;
sampler_name("always_off") -> always_off;
sampler_name("traceidratio") -> traceidratio;
sampler_name(_) -> unknown.
ratio(false) -> unset;
ratio("0.05") -> <<"0.05">>;
ratio("1") -> <<"1">>;
ratio("1.0") -> <<"1.0">>;
ratio(_) -> unknown.

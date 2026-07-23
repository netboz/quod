-module(quod_metrics_tests).
-include_lib("eunit/include/eunit.hrl").

%% Regression guard for the documented deploy-killer (doc/deferred / memory): a metric
%% HELP string with a codepoint > 255 passes `declare` but throws `badarg` in
%% `prometheus_text_format:escape_string`'s `iolist_to_binary` at SCRAPE time — so
%% `/metrics` returns 500, the Nomad health check (type=http path=/metrics) never passes,
%% and a rolling deploy stalls at its progress deadline. Declaring is not enough; this
%% RENDERS the whole registry and asserts it neither crashes nor emits a non-ASCII byte.
renders_without_non_ascii_help_test() ->
    {ok, _} = application:ensure_all_started(prometheus),
    ok = quod_metrics:declare(<<"kp_testnode">>),
    Rendered = prometheus_text_format:format(),   %% would throw badarg on a bad HELP string
    Bin = iolist_to_binary(Rendered),
    ?assert(byte_size(Bin) > 0),
    NonAscii = [B || <<B>> <= Bin, B > 127],
    ?assertEqual([], NonAscii).

%% Commit latency is a SUBMITTER-side, single-clock observation (quod_prolog calls this
%% when a parked write resolves as applied). Absent metrics process => silent no-op
%% (metrics are never a dependency of write resolution); negative input — impossible on
%% one monotonic clock, but the guard is the contract — is dropped, not recorded.
observe_tx_latency_test() ->
    {ok, _} = application:ensure_all_started(prometheus),
    Ns = <<"lat:test">>,
    ?assertEqual(undefined, whereis(quod_metrics)),
    ok = quod_metrics:observe_tx_latency(Ns, 7),    %% no metrics process: no-op, no crash
    %% the guard checks name PRESENCE only (never a dependency of write resolution), so a
    %% placeholder registration stands in for the server; declare/1 seeds the registry
    Placeholder = spawn(fun() -> receive stop -> ok end end),
    true = register(quod_metrics, Placeholder),
    try
        ok = quod_metrics:declare(<<"kp_testnode">>),
        ok = quod_metrics:observe_tx_latency(Ns, 42),
        ok = quod_metrics:observe_tx_latency(Ns, -1),   %% dropped by the guard
        {_Buckets, Sum} = prometheus_histogram:value(quod_tx_commit_latency_ms, [Ns]),
        ?assertEqual(42, Sum)
    after
        Placeholder ! stop
    end.

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

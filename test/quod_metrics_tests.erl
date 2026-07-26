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

%% The link-send drop counter makes quod_link's deliberately ignored backpressure
%% returns visible, classified by reason, labelled by the receiving peer.
count_link_send_drop_test() ->
    {ok, _} = application:ensure_all_started(prometheus),
    Peer = binary:copy(<<16#ab>>, 32),
    ok = quod_metrics:count_link_send_drop(Peer, send_queue_full),   %% no process: no-op
    Placeholder = spawn(fun() -> receive stop -> ok end end),
    true = register(quod_metrics, Placeholder),
    try
        ok = quod_metrics:declare(<<"kp_testnode">>),
        ok = quod_metrics:count_link_send_drop(Peer, {flow_control_blocked, connection}),
        ok = quod_metrics:count_link_send_drop(Peer, {flow_control_blocked, {stream, 4}}),
        ok = quod_metrics:count_link_send_drop(Peer, send_queue_full),
        ok = quod_metrics:count_link_send_drop(Peer, {shutdown, whatever}),
        Short = quod_identity:short(Peer),
        ?assertEqual(1, prometheus_counter:value(quod_link_send_drops_total,
                                                 [Short, <<"flow_control_conn">>])),
        ?assertEqual(1, prometheus_counter:value(quod_link_send_drops_total,
                                                 [Short, <<"flow_control_stream">>])),
        ?assertEqual(1, prometheus_counter:value(quod_link_send_drops_total,
                                                 [Short, <<"queue_full">>])),
        ?assertEqual(1, prometheus_counter:value(quod_link_send_drops_total,
                                                 [Short, <<"other">>]))
    after
        Placeholder ! stop
    end.

%% Round-phase samples land in the right histogram; a negative duration (impossible on
%% one monotonic clock — the guard is the contract) is dropped.
observe_round_phase_test() ->
    {ok, _} = application:ensure_all_started(prometheus),
    Ns = <<"round:test">>,
    ok = quod_metrics:observe_round_phase(Ns, approve, 5),   %% no process: no-op
    Placeholder = spawn(fun() -> receive stop -> ok end end),
    true = register(quod_metrics, Placeholder),
    try
        ok = quod_metrics:declare(<<"kp_testnode">>),
        ok = quod_metrics:observe_round_phase(Ns, approve, 12),
        ok = quod_metrics:observe_round_phase(Ns, commit, 30),
        ok = quod_metrics:observe_round_phase(Ns, commit, -1),
        {_, ASum} = prometheus_histogram:value(quod_consensus_round_approve_ms, [Ns]),
        {_, CSum} = prometheus_histogram:value(quod_consensus_round_commit_ms, [Ns]),
        ?assertEqual(12, ASum),
        ?assertEqual(30, CSum)
    after
        Placeholder ! stop
    end.

%% Per-event timing: microseconds land (divided by 1000) in the ms histogram, the
%% mailbox depth lands in its own histogram, both labelled by event class. A negative
%% duration (impossible on one monotonic clock) is dropped by the guard.
observe_consensus_event_test() ->
    {ok, _} = application:ensure_all_started(prometheus),
    Ns = <<"ev:test">>,
    ok = quod_metrics:observe_consensus_event(Ns, frame, 5000, 3),   %% no process yet: no-op, no crash
    Placeholder = spawn(fun() -> receive stop -> ok end end),
    true = register(quod_metrics, Placeholder),
    try
        ok = quod_metrics:declare(<<"kp_testnode">>),
        ok = quod_metrics:observe_consensus_event(Ns, frame, 12000, 7),  %% 12000us -> 12ms, mailbox 7
        ok = quod_metrics:observe_consensus_event(Ns, append, 3000, 0),  %% a different event class
        ok = quod_metrics:observe_consensus_event(Ns, frame, -1, 0),     %% negative us: dropped by guard
        {_, MsSum} = prometheus_histogram:value(quod_consensus_event_ms, [Ns, <<"frame">>]),
        {_, QlSum} = prometheus_histogram:value(quod_consensus_event_qlen, [Ns, <<"frame">>]),
        {_, MsAppend} = prometheus_histogram:value(quod_consensus_event_ms, [Ns, <<"append">>]),
        ?assert(MsSum == 12.0),   %% only the one valid frame sample survived
        ?assert(QlSum == 7),
        ?assert(MsAppend == 3.0)
    after
        Placeholder ! stop
    end.

%% Per named sub-step timing: microseconds land (divided by 1000) in the ms histogram,
%% labelled by step name. Negative durations are dropped by the guard.
observe_consensus_step_test() ->
    {ok, _} = application:ensure_all_started(prometheus),
    Ns = <<"step:test">>,
    ok = quod_metrics:observe_consensus_step(Ns, persist, 4000),   %% no process: no-op
    Placeholder = spawn(fun() -> receive stop -> ok end end),
    true = register(quod_metrics, Placeholder),
    try
        ok = quod_metrics:declare(<<"kp_testnode">>),
        ok = quod_metrics:observe_consensus_step(Ns, persist, 2000),    %% 2000us -> 2ms
        ok = quod_metrics:observe_consensus_step(Ns, support, 150000),  %% 150000us -> 150ms
        ok = quod_metrics:observe_consensus_step(Ns, persist, -5),      %% negative: dropped
        {_, PSum} = prometheus_histogram:value(quod_consensus_step_ms, [Ns, <<"persist">>]),
        {_, SSum} = prometheus_histogram:value(quod_consensus_step_ms, [Ns, <<"support">>]),
        ?assert(PSum == 2.0),
        ?assert(SSum == 150.0)
    after
        Placeholder ! stop
    end.

%% Vote-share arrival lag lands in the histogram in milliseconds, labelled by vote
%% kind (support/commit/complaint). Negative durations are dropped by the guard.
observe_share_lag_test() ->
    {ok, _} = application:ensure_all_started(prometheus),
    Ns = <<"lag:test">>,
    ok = quod_metrics:observe_share_lag(Ns, support, 40),   %% no process: no-op
    Placeholder = spawn(fun() -> receive stop -> ok end end),
    true = register(quod_metrics, Placeholder),
    try
        ok = quod_metrics:declare(<<"kp_testnode">>),
        ok = quod_metrics:observe_share_lag(Ns, support, 25),
        ok = quod_metrics:observe_share_lag(Ns, commit, 60),
        ok = quod_metrics:observe_share_lag(Ns, support, -1),   %% negative: dropped
        {_, SupSum} = prometheus_histogram:value(quod_consensus_share_lag_ms, [Ns, <<"support">>]),
        {_, ComSum} = prometheus_histogram:value(quod_consensus_share_lag_ms, [Ns, <<"commit">>]),
        ?assert(SupSum == 25),
        ?assert(ComSum == 60)
    after
        Placeholder ! stop
    end.

%% Batching is sampled once per proposed block, while retry outcomes are counted
%% at the caller-facing Prolog boundary. Invalid samples/reasons are ignored.
batch_and_retry_metrics_test() ->
    {ok, _} = application:ensure_all_started(prometheus),
    Ns = <<"batch:test">>,
    ok = quod_metrics:observe_batch(Ns, 4, 25),
    ok = quod_metrics:count_tx_retry(Ns, slot_closed),
    Placeholder = spawn(fun() -> receive stop -> ok end end),
    true = register(quod_metrics, Placeholder),
    try
        ok = quod_metrics:declare(<<"kp_testnode">>),
        ok = quod_metrics:observe_batch(Ns, 4, 25),
        ok = quod_metrics:observe_batch(Ns, 0, -1),
        ok = quod_metrics:count_tx_retry(Ns, slot_closed),
        ok = quod_metrics:count_tx_retry(Ns, stale_sequence),
        ok = quod_metrics:count_tx_retry(Ns, unknown),
        {_, SizeSum} = prometheus_histogram:value(
                         quod_consensus_batch_size, [Ns]),
        {_, WaitSum} = prometheus_histogram:value(
                         quod_consensus_batch_wait_ms, [Ns]),
        ?assertEqual(4, SizeSum),
        ?assertEqual(25, WaitSum),
        ?assertEqual(1, prometheus_counter:value(
                          quod_tx_retries_total, [Ns, <<"slot_closed">>])),
        ?assertEqual(1, prometheus_counter:value(
                          quod_tx_retries_total, [Ns, <<"stale_sequence">>]))
    after
        Placeholder ! stop
    end.

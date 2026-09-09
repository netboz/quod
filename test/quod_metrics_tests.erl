-module(quod_metrics_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

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
    ?assertNotEqual(
       nomatch,
       binary:match(
         Bin, <<"# HELP quod_foreign_follow_resnapshots ">>)),
    ?assertNotEqual(
       nomatch,
       binary:match(
         Bin, <<"# HELP quod_effect_custody_group_active ">>)),
    ?assertNotEqual(
       nomatch,
       binary:match(
         Bin, <<"# HELP quod_dtx_admission_wait_ms ">>)),
    ?assertNotEqual(
       nomatch,
       binary:match(
         Bin, <<"# HELP quod_foreign_feed_registrations ">>)),
    ?assertNotEqual(
       nomatch,
       binary:match(
         Bin, <<"# HELP quod_feed_recipients ">>)),
    ?assertNotEqual(
       nomatch,
       binary:match(
         Bin, <<"# HELP quod_client_outcome_unknown_total ">>)),
    ?assertNotEqual(
       nomatch,
       binary:match(
         Bin, <<"# HELP quod_directory_rebuild_seconds ">>)),
    NonAscii = [B || <<B>> <= Bin, B > 127],
    ?assertEqual([], NonAscii).

stopped_ontology_consensus_gauges_are_removed_test() ->
    {ok, _} = application:ensure_all_started(prometheus),
    ok = quod_metrics:declare(<<"kp_testnode">>),
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(8)),
    Live = <<"metrics:live:", Suffix/binary>>,
    Stopped = <<"metrics:stopped:", Suffix/binary>>,
    ok = prometheus_gauge:set(quod_consensus_syncing, [Live], 0),
    ok = prometheus_gauge:set(quod_consensus_slot, [Live], 7),
    ok = prometheus_gauge:set(quod_consensus_syncing, [Stopped], 1),
    ok = prometheus_gauge:set(quod_consensus_slot, [Stopped], 9),

    ok = quod_metrics:test_remove_stale_consensus_metrics([Live]),

    ?assertEqual(0, prometheus_gauge:value(quod_consensus_syncing, [Live])),
    ?assertEqual(7, prometheus_gauge:value(quod_consensus_slot, [Live])),
    ?assertEqual(undefined,
                 prometheus_gauge:value(quod_consensus_syncing, [Stopped])),
    ?assertEqual(undefined,
                 prometheus_gauge:value(quod_consensus_slot, [Stopped])).

client_outcome_unknown_uses_only_fixed_producer_labels_test() ->
    {ok, _} = application:ensure_all_started(prometheus),
    ok = quod_metrics:count_client_outcome_unknown(target_execute),
    Placeholder = spawn(fun() -> receive stop -> ok end end),
    true = register(quod_metrics, Placeholder),
    try
        ok = quod_metrics:declare(<<"kp_testnode">>),
        Producers =
            [target_execute, target_cursor,
             gateway_execute_transport, gateway_cursor_transport],
        lists:foreach(
          fun(Producer) ->
                  Label = atom_to_binary(Producer, utf8),
                  Before = counter_value_or_zero(
                             quod_client_outcome_unknown_total, [Label]),
                  ok = quod_metrics:count_client_outcome_unknown(Producer),
                  ?assertEqual(
                     Before + 1,
                     prometheus_counter:value(
                      quod_client_outcome_unknown_total, [Label]))
          end, Producers),
        TxRef = {transaction, <<"quod:metrics">>, <<1:256>>, <<2:256>>},
        TargetBefore = counter_value_or_zero(
                         quod_client_outcome_unknown_total,
                         [<<"target_execute">>]),
        ok = quod_client_result:observe_outcome_unknown(
               target_execute, test_producer,
               {error, {outcome_unknown, TxRef}}),
        ok = quod_client_result:observe_outcome_unknown(
               target_execute, test_producer, {error, conflict_retry}),
        ok = quod_client_result:observe_outcome_unknown(
               target_execute, test_producer,
               {error, {outcome_unknown, malformed}}),
        ?assertEqual(
           TargetBefore + 1,
           prometheus_counter:value(
             quod_client_outcome_unknown_total,
             [<<"target_execute">>])),
        ok = quod_metrics:count_client_outcome_unknown(
               attacker_controlled_producer),
        ?assertEqual(
           undefined,
           prometheus_counter:value(
             quod_client_outcome_unknown_total,
             [<<"attacker_controlled_producer">>]))
    after
        true = unregister(quod_metrics),
        Placeholder ! stop
    end.

counter_value_or_zero(Name, Labels) ->
    case prometheus_counter:value(Name, Labels) of
        undefined -> 0;
        Value -> Value
    end.

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

dtx_admission_wait_uses_only_the_hosted_namespace_label_test() ->
    {ok, _} = application:ensure_all_started(prometheus),
    Ns = <<"dtx:admission:metrics">>,
    ok = quod_metrics:observe_dtx_admission_wait(Ns, 7),
    Placeholder = spawn(fun() -> receive stop -> ok end end),
    true = register(quod_metrics, Placeholder),
    try
        ok = quod_metrics:declare(<<"kp_testnode">>),
        ok = quod_metrics:observe_dtx_admission_wait(Ns, 42),
        ok = quod_metrics:observe_dtx_admission_wait(Ns, -1),
        {_, Sum} = prometheus_histogram:value(
                     quod_dtx_admission_wait_ms, [Ns]),
        ?assertEqual(42, Sum)
    after
        Placeholder ! stop
    end.

reaction_latency_uses_only_bounded_result_labels_test() ->
    {ok, _} = application:ensure_all_started(prometheus),
    Ns = <<"reaction:metrics">>,
    ok = quod_metrics:observe_runtime_reaction(Ns, executed, 7),
    Placeholder = spawn(fun() -> receive stop -> ok end end),
    true = register(quod_metrics, Placeholder),
    try
        ok = quod_metrics:declare(<<"kp_testnode">>),
        ok = quod_metrics:observe_runtime_reaction(Ns, executed, 1000000),
        ok = quod_metrics:observe_runtime_reaction(
               Ns, {inert, attacker_controlled_reason}, 2000000),
        ok = quod_metrics:observe_runtime_reaction(
               Ns, {failed, {arbitrary, payload}}, 3000000),
        {_, Executed} = prometheus_histogram:value(
                          quod_runtime_reaction_seconds,
                          [Ns, <<"executed">>]),
        {_, Inert} = prometheus_histogram:value(
                       quod_runtime_reaction_seconds,
                       [Ns, <<"inert">>]),
        {_, Failed} = prometheus_histogram:value(
                        quod_runtime_reaction_seconds,
                        [Ns, <<"failed">>]),
        ?assertEqual(1.0, Executed),
        ?assertEqual(2.0, Inert),
        ?assertEqual(3.0, Failed),
        ?assertEqual(
           undefined,
           prometheus_histogram:value(
             quod_runtime_reaction_seconds,
             [Ns, <<"attacker_controlled_reason">>]))
    after
        Placeholder ! stop
    end.

remote_operation_latency_uses_only_fixed_stage_and_result_labels_test() ->
    {ok, _} = application:ensure_all_started(prometheus),
    Ns = <<"operation:metrics:",
           (integer_to_binary(
              erlang:unique_integer([positive])))/binary>>,
    ok = quod_metrics:observe_remote_operation_stage(
           Ns, source_claim, ok, 7),
    Placeholder = spawn(fun() -> receive stop -> ok end end),
    true = register(quod_metrics, Placeholder),
    try
        ok = quod_metrics:declare(<<"kp_testnode">>),
        OneSecond = erlang:convert_time_unit(1, second, native),
        ok = quod_metrics:observe_remote_operation_stage(
               Ns, source_claim, ok, OneSecond),
        ok = quod_metrics:observe_remote_operation_stage(
               Ns, read_certification, ok, OneSecond),
        ok = quod_metrics:observe_remote_operation_stage(
               Ns, attacker_stage, ok, OneSecond),
        ok = quod_metrics:observe_remote_operation_stage(
               Ns, source_claim, attacker_result, OneSecond),
        {_, Sum} = prometheus_histogram:value(
                     quod_remote_operation_stage_seconds,
                     [Ns, <<"source_claim">>, <<"ok">>]),
        ?assertEqual(1.0, Sum),
        {_, ReadCertificationSum} = prometheus_histogram:value(
                                      quod_remote_operation_stage_seconds,
                                      [Ns, <<"read_certification">>, <<"ok">>]),
        ?assertEqual(1.0, ReadCertificationSum),
        ?assertEqual(
           undefined,
           prometheus_histogram:value(
             quod_remote_operation_stage_seconds,
             [Ns, <<"attacker_stage">>, <<"ok">>]))
    after
        Placeholder ! stop
    end.

dtx_and_foreign_history_latency_use_only_fixed_labels_test() ->
    {ok, _} = application:ensure_all_started(prometheus),
    Ns = <<"dtx:stage:metrics:",
           (integer_to_binary(
              erlang:unique_integer([positive])))/binary>>,
    Placeholder = spawn(fun() -> receive stop -> ok end end),
    true = register(quod_metrics, Placeholder),
    try
        ok = quod_metrics:declare(<<"kp_testnode">>),
        OneSecond = erlang:convert_time_unit(1, second, native),
        ok = quod_metrics:observe_dtx_group_stage(
               Ns, prepare_wave, ok, OneSecond),
        ok = quod_metrics:observe_foreign_history_stage(
               cache_replay, uncertain, OneSecond),
        ForeignStages =
            [queue_wait, request_exact, request_current, request_follow,
             current_total, resident_current_hit, resident_current_miss,
             owner_mailbox,
             cache_open, cache_replay, ledger_resume, ledger_open,
             ledger_suspend, checkpoint_read, projection_validate,
             phase_resume, phase_open, phase_suspend, page_fetch,
             page_verify, ledger_append, phase_commit, checkpoint_write,
             cache_accounting, tip_confirm, result_install, caller_wake,
             serve_read_total, serve_snapshot_lookup, serve_snapshot_resume,
             serve_range_read, serve_encode],
        StageSumsBefore =
            maps:from_list(
              [{Stage,
                histogram_sum_or_zero(
                  quod_foreign_history_stage_seconds,
                  [atom_to_binary(Stage, utf8), <<"ok">>])}
               || Stage <- ForeignStages]),
        lists:foreach(
          fun(Stage) ->
              ok = quod_metrics:observe_foreign_history_stage(
                     Stage, ok, OneSecond)
          end, ForeignStages),
        ok = quod_metrics:observe_dtx_group_stage(
               Ns, attacker_stage, ok, OneSecond),
        ok = quod_metrics:observe_foreign_history_stage(
               page_fetch, attacker_result, OneSecond),
        {_, DtxSum} = prometheus_histogram:value(
                        quod_dtx_group_stage_seconds,
                        [Ns, <<"prepare_wave">>, <<"ok">>]),
        {_, ForeignSum} = prometheus_histogram:value(
                            quod_foreign_history_stage_seconds,
                            [<<"cache_replay">>, <<"uncertain">>]),
        ?assertEqual(1.0, DtxSum),
        ?assertEqual(1.0, ForeignSum),
        lists:foreach(
          fun(Stage) ->
              {_, StageSum} = prometheus_histogram:value(
                                quod_foreign_history_stage_seconds,
                                [atom_to_binary(Stage, utf8), <<"ok">>]),
              ?assert(abs(StageSum - maps:get(Stage, StageSumsBefore) - 1.0)
                      < 1.0e-9)
          end, ForeignStages),
        ?assertEqual(
           undefined,
           prometheus_histogram:value(
             quod_dtx_group_stage_seconds,
             [Ns, <<"attacker_stage">>, <<"ok">>])),
        ?assertEqual(
           undefined,
           prometheus_histogram:value(
             quod_foreign_history_stage_seconds,
             [<<"page_fetch">>, <<"attacker_result">>]))
    after
        Placeholder ! stop
    end.

histogram_sum_or_zero(Name, Labels) ->
    case prometheus_histogram:value(Name, Labels) of
        undefined -> 0.0;
        {_Buckets, Sum} -> Sum
    end.

directory_rebuild_latency_uses_only_fixed_result_labels_test() ->
    {ok, _} = application:ensure_all_started(prometheus),
    ok = quod_metrics:observe_directory_rebuild(ok, 7),
    Placeholder = spawn(fun() -> receive stop -> ok end end),
    true = register(quod_metrics, Placeholder),
    try
        ok = quod_metrics:declare(<<"kp_testnode">>),
        OneSecond = erlang:convert_time_unit(1, second, native),
        ok = quod_metrics:observe_directory_rebuild(ok, OneSecond),
        ok = quod_metrics:observe_directory_rebuild(
               attacker_controlled_result, OneSecond),
        {Buckets, Sum} = prometheus_histogram:value(
                           quod_directory_rebuild_seconds, [<<"ok">>]),
        ?assertEqual(1.0, Sum),
        %% Native time is converted by the Prometheus duration metric: a
        %% one-second sample belongs to a finite bucket, never +Inf only.
        ?assertEqual(1, lists:sum(Buckets)),
        ?assertEqual(0, lists:last(Buckets)),
        ?assertEqual(
           undefined,
           prometheus_histogram:value(
             quod_directory_rebuild_seconds,
             [<<"attacker_controlled_result">>]))
    after
        true = unregister(quod_metrics),
        Placeholder ! stop
    end.

owner_lifetimes_use_only_fixed_component_phase_and_result_labels_test() ->
    {ok, _} = application:ensure_all_started(prometheus),
    Ns = <<"owner:metrics:",
           (integer_to_binary(
              erlang:unique_integer([positive])))/binary>>,
    ok = quod_metrics:observe_ontology_owner_terminal(
           Ns, dtx_control, prepare, completed, 7),
    ok = quod_metrics:observe_node_owner_terminal(
           scope_router, scope, timeout, 7),
    Placeholder = spawn(fun() -> receive stop -> ok end end),
    true = register(quod_metrics, Placeholder),
    try
        ok = quod_metrics:declare(<<"kp_testnode">>),
        ok = quod_metrics:observe_ontology_owner_terminal(
               Ns, dtx_control, prepare, completed, 125),
        ok = quod_metrics:observe_node_owner_terminal(
               scope_router, scope, timeout, 250),
        %% None of these request-controlled values may create a label series.
        ok = quod_metrics:observe_ontology_owner_terminal(
               Ns, attacker_component, prepare, completed, 1000),
        ok = quod_metrics:observe_node_owner_terminal(
               scope_router, attacker_phase, timeout, 1000),
        ok = quod_metrics:observe_node_owner_terminal(
               scope_router, scope, attacker_result, 1000),
        {_, OntologySum} = prometheus_histogram:value(
                             quod_ontology_owner_duration_seconds,
                             [Ns, <<"dtx_control">>, <<"prepare">>,
                              <<"completed">>]),
        {_, NodeSum} = prometheus_histogram:value(
                         quod_node_owner_duration_seconds,
                         [<<"scope_router">>, <<"scope">>, <<"timeout">>]),
        ?assertEqual(0.125, OntologySum),
        ?assertEqual(0.25, NodeSum),
        ?assertEqual(
           1, prometheus_counter:value(
                quod_ontology_owner_terminal_total,
                [Ns, <<"dtx_control">>, <<"prepare">>, <<"completed">>])),
        ?assertEqual(
           1, prometheus_counter:value(
                quod_node_owner_terminal_total,
                [<<"scope_router">>, <<"scope">>, <<"timeout">>])),
        ?assertEqual(
           undefined,
           prometheus_histogram:value(
             quod_node_owner_duration_seconds,
             [<<"scope_router">>, <<"attacker_phase">>, <<"timeout">>]))
    after
        Placeholder ! stop
    end.

foreign_commit_metrics_use_target_namespace_test() ->
    {ok, _} = application:ensure_all_started(prometheus),
    ok = quod_metrics:declare(<<"kp_testnode">>),
    Target = <<"metrics:target:",
               (integer_to_binary(
                  erlang:unique_integer([positive])))/binary>>,
    Origin = <<"metrics:origin:",
               (integer_to_binary(
                  erlang:unique_integer([positive])))/binary>>,
    Author = <<19:256>>,
    Tx = #transaction{tx_id = <<20:256>>,
                      origin = {Origin, <<21:256>>},
                      proof_id = <<22:256>>, plan_digest = <<23:256>>,
                      goal = <<>>, result = <<>>,
                      diff = [{assert, {{metric_fact, true}, true}}],
                      read_check = #{}, author = Author},
    ok = quod_metrics:test_observe_commit(
           Target, #entry{index = 1, data = {batch, [Tx]}}),
    AuthorLabel = quod_identity:short(Author),
    ?assertEqual(1, prometheus_counter:value(
                      quod_tx_committed_total, [Target, AuthorLabel])),
    ?assertEqual(undefined, prometheus_counter:value(
                            quod_tx_committed_total,
                            [Origin, AuthorLabel])).

dtx_commits_are_counted_by_phase_test() ->
    {ok, _} = application:ensure_all_started(prometheus),
    ok = quod_metrics:declare(<<"kp_testnode">>),
    Ns = <<"metrics:non-content:",
           (integer_to_binary(
              erlang:unique_integer([positive])))/binary>>,
    ok = quod_metrics:test_observe_commit(
           Ns, #entry{index = 1, data = noop}),
    ok = quod_metrics:test_observe_commit(
           Ns, #entry{index = 2, data = {batch, []}}),
    ?assertEqual(
       undefined,
       prometheus_counter:value(
         quod_dtx_committed_total, [Ns, <<"decision">>])),
    ok = quod_metrics:test_observe_commit(
           Ns, #entry{index = 3,
                      data = quod_ct:dtx_decision_payload()}),
    ?assertEqual(
       1,
       prometheus_counter:value(
         quod_dtx_committed_total, [Ns, <<"decision">>])).

dtx_route_continuity_metrics_use_only_fixed_event_labels_test() ->
    {ok, _} = application:ensure_all_started(prometheus),
    Ns = <<"metrics:dtx-route:",
           (integer_to_binary(
              erlang:unique_integer([positive])))/binary>>,
    Placeholder = spawn(fun() -> receive stop -> ok end end),
    true = register(quod_metrics, Placeholder),
    try
        ok = quod_metrics:declare(<<"kp_testnode">>),
        ok = quod_metrics:count_dtx_validation(Ns, abstain),
        ok = quod_metrics:count_dtx_submit_fanout(Ns, attempted, 3),
        ok = quod_metrics:count_dtx_submit_fanout(Ns, accepted, 1),
        %% Unknown labels and negative counts cannot create a series.
        ok = quod_metrics:count_dtx_validation(Ns, attacker_label),
        ok = quod_metrics:count_dtx_submit_fanout(
               Ns, attacker_label, 100),
        ok = quod_metrics:count_dtx_submit_fanout(Ns, uncertain, -1),
        ?assertEqual(
           1, prometheus_counter:value(
                quod_dtx_validation_events_total, [Ns, <<"abstain">>])),
        ?assertEqual(
           undefined, prometheus_counter:value(
                        quod_dtx_validation_events_total,
                        [Ns, <<"redrive">>])),
        ?assertEqual(
           3, prometheus_counter:value(
                quod_dtx_submit_fanout_total, [Ns, <<"attempted">>])),
        ?assertEqual(
           1, prometheus_counter:value(
                quod_dtx_submit_fanout_total, [Ns, <<"accepted">>])),
        ?assertEqual(
           undefined, prometheus_counter:value(
                        quod_dtx_submit_fanout_total,
                        [Ns, <<"attacker_label">>]))
    after
        Placeholder ! stop
    end.

%% The link-send drop counter makes quod_link's deliberately ignored backpressure
%% returns visible, classified by reason, receiving peer, and a bounded channel
%% class. Only exact deterministic Simplex channel identities get `log`/`ingress`;
%% unrelated, malformed, and non-canonical identities all collapse to `other`.
count_link_send_drop_test() ->
    {ok, _} = application:ensure_all_started(prometheus),
    Peer = binary:copy(<<16#ab>>, 32),
    Ns = <<"drop:test">>,
    LogChannel = term_to_binary({log, Ns}, [deterministic]),
    IngressChannel = term_to_binary({ingress, Ns}, [deterministic]),
    FeedChannel = term_to_binary({feed, Ns}, [deterministic]),
    %% This decodes to {log, Ns}, but ATOM_EXT is not quod's deterministic
    %% SMALL_ATOM_UTF8_EXT encoding and therefore must not acquire the log label.
    NonCanonicalLog =
        <<131, 104, 2, 100, 0, 3, "log", 109, (byte_size(Ns)):32, Ns/binary>>,
    ok = quod_metrics:count_link_send_drop(
           Peer, LogChannel, send_queue_full),   %% no process: no-op
    Placeholder = spawn(fun() -> receive stop -> ok end end),
    true = register(quod_metrics, Placeholder),
    try
        ok = quod_metrics:declare(<<"kp_testnode">>),
        ok = quod_metrics:count_link_send_drop(
               Peer, LogChannel, {flow_control_blocked, connection}),
        ok = quod_metrics:count_link_send_drop(
               Peer, IngressChannel, {flow_control_blocked, {stream, 4}}),
        ok = quod_metrics:count_link_send_drop(
               Peer, LogChannel, send_queue_full),
        ok = quod_metrics:count_link_send_drop(
               Peer, IngressChannel, {shutdown, whatever}),
        ok = quod_metrics:count_link_send_drop(
               Peer, FeedChannel, send_queue_full),
        ok = quod_metrics:count_link_send_drop(
               Peer, NonCanonicalLog, send_queue_full),
        ok = quod_metrics:count_link_send_drop(
               Peer, <<"attacker-selected-label">>, send_queue_full),
        Short = quod_identity:short(Peer),
        ?assertEqual(1, prometheus_counter:value(quod_link_send_drops_total,
                                                 [Short, <<"log">>,
                                                  <<"flow_control_conn">>])),
        ?assertEqual(1, prometheus_counter:value(quod_link_send_drops_total,
                                                 [Short, <<"ingress">>,
                                                  <<"flow_control_stream">>])),
        ?assertEqual(1, prometheus_counter:value(quod_link_send_drops_total,
                                                 [Short, <<"log">>,
                                                  <<"queue_full">>])),
        ?assertEqual(1, prometheus_counter:value(quod_link_send_drops_total,
                                                 [Short, <<"ingress">>,
                                                  <<"other">>])),
        ?assertEqual(3, prometheus_counter:value(quod_link_send_drops_total,
                                                 [Short, <<"other">>,
                                                  <<"queue_full">>]))
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
    ok = quod_metrics:count_tx_retry(Ns, membership_skipped),
    Placeholder = spawn(fun() -> receive stop -> ok end end),
    true = register(quod_metrics, Placeholder),
    try
        ok = quod_metrics:declare(<<"kp_testnode">>),
        ok = quod_metrics:observe_batch(Ns, 4, 25),
        ok = quod_metrics:observe_batch(Ns, 0, -1),
        ok = quod_metrics:count_tx_retry(Ns, membership_skipped),
        ok = quod_metrics:count_tx_retry(Ns, stale_sequence),
        ok = quod_metrics:count_tx_retry(Ns, unknown),
        {_, SizeSum} = prometheus_histogram:value(
                         quod_consensus_batch_size, [Ns]),
        {_, WaitSum} = prometheus_histogram:value(
                         quod_consensus_batch_wait_ms, [Ns]),
        ?assertEqual(4, SizeSum),
        ?assertEqual(25, WaitSum),
        ?assertEqual(1, prometheus_counter:value(
                          quod_tx_retries_total,
                          [Ns, <<"membership_skipped">>])),
        ?assertEqual(1, prometheus_counter:value(
                          quod_tx_retries_total, [Ns, <<"stale_sequence">>]))
    after
        Placeholder ! stop
    end.

%% Custody completion records the number of internal placement hops, including
%% zero for a first-placement success. Invalid input and an absent metrics
%% process are silent no-ops because caller completion cannot depend on metrics.
ingress_custody_metrics_test() ->
    {ok, _} = application:ensure_all_started(prometheus),
    Ns = <<"custody:test">>,
    ok = quod_metrics:observe_ingress_retarget_hops(Ns, 2),
    Placeholder = spawn(fun() -> receive stop -> ok end end),
    true = register(quod_metrics, Placeholder),
    try
        ok = quod_metrics:declare(<<"kp_testnode">>),
        ok = quod_metrics:observe_ingress_retarget_hops(Ns, 0),
        ok = quod_metrics:observe_ingress_retarget_hops(Ns, 2),
        ok = quod_metrics:observe_ingress_retarget_hops(Ns, -1),
        {BucketCounts, HopSum} = prometheus_histogram:value(
                                   quod_consensus_ingress_retarget_hops, [Ns]),
        ?assertEqual(2, lists:sum(BucketCounts)),
        ?assertEqual(2, HopSum),
        RequiredStats = [custody_depth, custody_ready, custody_bytes,
                         ingress_retargets, dtx_admission_waiting,
                         dtx_admission_dormant],
        ?assertEqual(
           [], RequiredStats -- quod_metrics:consensus_stat_keys())
    after
        Placeholder ! stop
    end.

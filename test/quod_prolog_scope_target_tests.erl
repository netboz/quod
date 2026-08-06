-module(quod_prolog_scope_target_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_proof_limits.hrl").

%% B's first invocation is suspended while it asks C.  C re-enters B through
%% a second invocation, whose controller traffic must correlate to request 2;
%% once request 2 completes, B resumes request 1 and its later controller
%% traffic must recover request 1's correlation.  A single active-command slot
%% either rejects request 2 or loses request 1 and fails this test.
reentrant_scope_command_correlation_is_lifo_test() ->
    Request1 = {<<1:128>>, 7},
    Request2 = {<<2:128>>, 11},
    ?assertEqual(
       {ok, [Request1, Request2, Request1], []},
       quod_prolog:test_active_command_stack(
         [{push, Request1}, top,
          {push, Request2}, top,
          {pop, Request2}, top,
          {pop, Request1}])).

out_of_order_terminal_reply_is_rejected_test() ->
    Request1 = {<<3:128>>, 3},
    Request2 = {<<4:128>>, 4},
    ?assertEqual(
       error,
       quod_prolog:test_active_command_stack(
         [{push, Request1}, {push, Request2}, {pop, Request1}])).

pending_remote_open_reserves_shared_capacity_test() ->
    %% A return-link handshake has not spawned its worker yet, but it already
    %% owns the last capacity slot.  A co-hosted open must not pass this gate.
    ?assert(quod_prolog:test_scope_capacity_available(2, 1, 0)),
    ?assertNot(quod_prolog:test_scope_capacity_available(2, 1, 1)),
    ?assertNot(quod_prolog:test_scope_capacity_available(2, 0, 2)).

unknown_internal_error_is_not_put_on_the_wire_test() ->
    Ns = <<"quod:target">>,
    ?assertEqual(
       {ontology_busy, Ns},
       quod_prolog:test_public_scope_reason({ontology_busy, Ns}, Ns)),
    ?assertEqual(
       {not_allowed, Ns},
       quod_prolog:test_public_scope_reason(not_allowed, Ns)),
    ?assertEqual(
       {protocol_error, proof_engine},
       quod_prolog:test_public_scope_reason(
         {unexpected_internal_detail, make_ref()}, Ns)),
    ?assertEqual(
       {protocol_error, proof_engine},
       quod_prolog:test_public_scope_reason(
         {protocol_error, not_in_the_wire_catalog}, Ns)).

target_owns_scope_timeout_classification_test() ->
    Ns = <<"quod:target">>,
    ?assertEqual(
       {proof_limit_exceeded, Ns},
       quod_prolog:test_scope_timeout_reason(active, Ns)),
    ?assertEqual(
       {scope_expired, Ns},
       quod_prolog:test_scope_timeout_reason(idle, Ns)).

remote_worker_death_has_one_wire_safe_failure_class_test() ->
    Ns = <<"quod:target">>,
    ?assertEqual(
       {scope_expired, Ns},
       quod_prolog:test_scope_worker_failure(
         {scope_error, {scope_expired, Ns}}, Ns)),
    ?assertEqual(
       {proof_limit_exceeded, Ns},
       quod_prolog:test_scope_worker_failure(killed, Ns)),
    ?assertEqual(
       {protocol_error, proof_engine},
       quod_prolog:test_scope_worker_failure(unexpected_crash, Ns)),
    ?assertMatch(
       {ok, _},
       quod_scope_wire:encode_event(
         {scope_event, test_binding(Ns), 1, <<1:128>>, 1, 0, false,
          {scope_error, {protocol_error, proof_engine}}})).

target_deadline_reserves_terminal_event_delivery_time_test() ->
    ?assertEqual(
       60000 - ?QUOD_SCOPE_TIMEOUT_REPLY_GRACE_MS,
       quod_prolog:test_target_scope_lifetime_ms(60000, 60000)),
    ?assertEqual(
       30000 - ?QUOD_SCOPE_TIMEOUT_REPLY_GRACE_MS,
       quod_prolog:test_target_scope_lifetime_ms(60000, 30000)),
    ?assertEqual(
       ?QUOD_SCOPE_TIMEOUT_REPLY_GRACE_MS div 2,
       quod_prolog:test_target_scope_lifetime_ms(
         ?QUOD_SCOPE_TIMEOUT_REPLY_GRACE_MS, 60000)),
    ?assertEqual(
       250,
       quod_prolog:test_target_scope_lifetime_ms(500, 60000)).

cleanup_remains_valid_after_execution_budget_expires_test() ->
    Past = quod_time:mono_ms() - 1,
    ?assert(
       quod_prolog:test_scope_command_budget_valid(scope_close, 0, Past)),
    ?assertNot(
       quod_prolog:test_scope_command_budget_valid(
         {invoke_next, <<1:128>>, 1}, 0, Past)).

idle_expiry_reuses_exact_last_command_correlation_test() ->
    OpenRequest = <<1:128>>,
    LaterRequest = <<2:128>>,
    ActiveRequest = <<3:128>>,
    ?assertEqual(
       {OpenRequest, 1},
       quod_prolog:test_remote_timeout_correlation(
         OpenRequest, 2, [])),
    ?assertEqual(
       {LaterRequest, 9},
       quod_prolog:test_remote_timeout_correlation(
         LaterRequest, 10, [])),
    ?assertEqual(
       {ActiveRequest, 12},
       quod_prolog:test_remote_timeout_correlation(
         LaterRequest, 10, [{ActiveRequest, 12}])).

top_level_deadline_and_crash_use_current_public_errors_test() ->
    Ns = <<"quod:origin">>,
    ?assertEqual(
       {error, {proof_limit_exceeded, Ns}},
       quod_prolog:test_proof_down_reply(prove, killed, Ns)),
    ?assertEqual(
       {error, {protocol_error, proof_worker_crash}},
       quod_prolog:test_proof_down_reply(prove, unexpected_crash, Ns)),
    ?assertEqual(
       {error, outcome_unknown},
       quod_prolog:test_proof_down_reply(action, unexpected_crash, Ns)),
    ?assertEqual(
       {error, outcome_unknown},
       quod_prolog:test_proof_down_reply(action, killed, Ns)).

test_binding(Ns) ->
    {scope_binding, <<1:256>>, <<2:256>>, <<3:256>>, <<4:128>>,
     {<<"quod:origin">>, <<5:256>>}, {Ns, <<6:256>>}, read_write}.

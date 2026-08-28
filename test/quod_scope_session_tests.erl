-module(quod_scope_session_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_proof_limits.hrl").

committed_submit_reply_is_bound_to_expected_transaction_test() ->
    Expected = key(97),
    Ref = {transaction, <<"quod:target">>, key(98), Expected},
    ?assertEqual(
       {ok, 7, Expected},
       quod_scope_session:test_committed_submit_outcome(
         7, Expected, Ref)),
    ?assertEqual(
       {error, {outcome_unknown, Ref}},
       quod_scope_session:test_committed_submit_outcome(
         7, key(99), Ref)).

divergent_submit_reply_terminates_with_expected_reference_test() ->
    Parent = self(),
    Router = spawn(fun request_link/0),
    RequestLink = spawn(fun request_link/0),
    Binding = node_binding(
                key(7), key(8), key(9), id(2),
                {<<"quod:origin">>, key(10)},
                {<<"quod:target">>, key(4)}, read_write),
    Handle = {remote_scope, Router, id(1), Binding, RequestLink},
    RequestId = id(3),
    ExpectedRef = {transaction, <<"quod:target">>, key(4), key(5)},
    DivergentRef = {transaction, <<"quod:target">>, key(4), key(6)},
    Worker = spawn(
               fun() ->
                   Parent !
                       {submit_result,
                        quod_scope_session:test_await_remote_submit(
                          Handle, RequestId, Router, ExpectedRef, 1000)}
               end),
    Worker ! {quod_scope_event, Handle, RequestId, 1, false,
              {plan_submitted, {outcome_unknown, DivergentRef}}},
    receive
        {submit_result, Result} ->
            ?assertEqual({error, {outcome_unknown, ExpectedRef}}, Result)
    after 250 ->
        ?assert(false)
    end,
    Router ! stop,
    RequestLink ! stop.

startup_failure_is_asynchronous_and_monitored_test() ->
    ProofId = crypto:strong_rand_bytes(32),
    Anchor = crypto:strong_rand_bytes(32),
    ScopeId = crypto:strong_rand_bytes(16),
    {Handle, WorkerMRef} =
        quod_scope_session:start(
          ScopeId, ProofId, self(), <<"quod:broken-scope">>, Anchor, 0,
          {not_an_erlog_state}, self(),
          #{principal => {node, key(1)}, request_binding => none,
            deadline_ms => quod_time:mono_ms() + 5000}),
    Worker = quod_scope_session:pid(Handle),
    receive
        {'DOWN', WorkerMRef, process, Worker, _Reason} -> ok
    after 1000 ->
        ?assert(false)
    end.

worker_heap_cap_and_public_local_errors_test() ->
    ScopeId = id(90),
    ProofId = key(91),
    Anchor = key(92),
    Ns = <<"quod:bounded-scope">>,
    {Handle, WorkerMRef} =
        quod_scope_session:start(
          ScopeId, ProofId, self(), Ns, Anchor, 0,
          committed([]), self(),
          #{principal => {node, key(89)}, request_binding => none,
            deadline_ms => quod_time:mono_ms() + 5000}),
    {quod_scope_session, Worker, ScopeId, ProofId,
     SessionRef, Ns, Anchor} = Handle,
    WordBytes = erlang:system_info(wordsize),
    ExpectedWords =
        (?QUOD_SCOPE_WORKER_MAX_HEAP_BYTES + WordBytes - 1) div WordBytes,
    ?assertMatch(
       {max_heap_size,
        #{size := ExpectedWords, kill := true, error_logger := true}},
       process_info(Worker, max_heap_size)),

    UnknownInvocation = id(93),
    {ok, NextRef} =
        quod_scope_session:invoke_next(Handle, UnknownInvocation, 1),
    ?assertEqual(
       {error, {protocol_error, request_binding}, false},
       receive_scope_reply(Worker, ProofId, SessionRef, NextRef)),

    %% The requested write is denied and never runs. The invocation still
    %% completes through ordinary logical failure with the bounded reason.
    InvocationId = id(94),
    RequestedGoal = {assertz, {must_not_run, true}},
    Origin = {<<"quod:origin">>, key(95)},
    {ok, OpenRef} = quod_scope_session:invoke_open(
                      Handle, InvocationId, RequestedGoal,
                      [Origin],
                      quod_transaction_scope:empty_selection()),
    ?assertEqual(
       {opened, InvocationId},
       receive_scope_reply(Worker, ProofId, SessionRef, OpenRef)),
    {ok, RefusedRef} =
        quod_scope_session:invoke_next(Handle, InvocationId, 1),
    ?assertMatch(
       {complete, 1, [{not_allowed, Ns} | _], false},
       receive_scope_reply(Worker, ProofId, SessionRef, RefusedRef)),
    _Ctx = quod_proof_context:start(
             key(96), false, Origin, quod_time:mono_ms() + 5000,
             anonymous),
    try
        {ok, RefusedPlan} =
            quod_scope_session:seal(Handle, Origin, anonymous, none),
        ?assertEqual([], quod_dtx:diff(RefusedPlan)),
        ?assertMatch(
           [{InvocationId, [{Ns, Anchor}, Origin], _, denied,
             0, <<0:256>>, complete}],
           quod_dtx:transcript(RefusedPlan)),
        [{InvocationId, _Chain, RequestedGoalBin, denied,
          0, <<0:256>>, complete}] = quod_dtx:transcript(RefusedPlan),
        {ok, ExpectedGoalBin} =
            quod_wire_term:encode_canonical(RequestedGoal),
        ?assertEqual(
           ExpectedGoalBin,
           RequestedGoalBin)
    after
        quod_proof_context:stop(fun(_) -> ok end, fun(_) -> ok end)
    end,

    ?assertEqual(ok, quod_scope_session:test_answer_disposition(small)),
    ?assertEqual(
       {error, {too_large, answer}},
       quod_scope_session:test_answer_disposition(
         binary:copy(<<0>>, ?QUOD_MAX_PROOF_ANSWER_BYTES))),
    ok = quod_scope_session:close(Handle),
    receive
        {'DOWN', WorkerMRef, process, Worker, _Reason} -> ok
    after 1000 ->
        ?assert(false)
    end.

worker_preserves_pending_guard_error_without_dirty_recheck_test() ->
    Ns = <<"quod:scope-guard-reply">>,
    Table = 'quod_simplex_genesis_quod:scope-guard-reply',
    Tab = ets:new(Table, [named_table, protected, set]),
    true = ets:insert(Tab, quod_ct:proof_gate_row(true, 7, [])),
    ScopeId = id(96),
    ProofId = key(97),
    Anchor = key(98),
    AccessGuard = {quod_proof_access, Ns, 7},
    Est = committed([{can_invoke, {'G'}, {'P'}, {'C'}, {'N'}}]),
    {Handle, WorkerMRef} =
        quod_scope_session:start(
          ScopeId, ProofId, self(), Ns, Anchor, 0, Est, self(),
          #{principal => {node, key(99)}, request_binding => none,
            access_guard => AccessGuard,
            deadline_ms => quod_time:mono_ms() + 5000}),
    {quod_scope_session, Worker, ScopeId, ProofId,
     SessionRef, Ns, Anchor} = Handle,
    InvocationId = id(100),
    try
        {ok, OpenRef} = quod_scope_session:invoke_open(
                          Handle, InvocationId, true,
                          [{<<"quod:origin">>, key(101)}],
                          quod_transaction_scope:empty_selection()),
        ?assertEqual(
           {opened, InvocationId},
           receive_scope_reply(Worker, ProofId, SessionRef, OpenRef)),
        GroupId = key(102),
        true = ets:insert(
                 Tab,
                 quod_ct:proof_gate_row(
                   true, 7, [{GroupId, 1, 7}])),
        {ok, NextRef} = quod_scope_session:invoke_next(
                          Handle, InvocationId, 1),
        ?assertEqual(
           {error, {transaction_pending, GroupId}, false},
           receive_scope_reply(Worker, ProofId, SessionRef, NextRef)),
        with_proof_context(
          fun() ->
              ?assertEqual(
                 {error, {transaction_pending, GroupId}},
                 quod_scope_session:restore_many(Handle, [id(103)]))
          end)
    after
        ok = quod_scope_session:close(Handle),
        receive
            {'DOWN', WorkerMRef, process, Worker, _Reason} -> ok
        after 1000 -> ?assert(false)
        end,
        ets:delete(Tab)
    end.

local_invocation_facade_preserves_worker_protocol_test() ->
    Parent = self(),
    Worker = spawn(fun() -> fake_worker(Parent) end),
    ScopeId = id(1),
    ProofId = key(2),
    SessionRef = make_ref(),
    Anchor = key(3),
    Ns = <<"quod:scope-facade-test">>,
    Handle = {quod_scope_session, Worker, ScopeId, ProofId,
              SessionRef, Ns, Anchor},
    InvocationId = id(4),
    Chain = [{<<"quod:origin">>, key(5)}],
    Selection = quod_transaction_scope:empty_selection(),

    ?assertEqual(Worker, quod_scope_session:pid(Handle)),
    ?assertEqual(ScopeId, quod_scope_session:scope_id(Handle)),
    ?assertEqual({Ns, Anchor}, quod_scope_session:identity(Handle)),
    {ok, OpenRef} = quod_scope_session:invoke_open(
                      Handle, InvocationId, {knows, tom, bob},
                      Chain, Selection),
    ?assert(is_reference(OpenRef)),
    ?assertEqual(
       {scope_invoke_open, self(), ProofId, SessionRef, OpenRef,
        InvocationId, {knows, tom, bob}, Chain, Selection},
       receive_worker_message()),

    {ok, NextRef} = quod_scope_session:invoke_next(Handle, InvocationId, 2),
    ?assert(is_reference(NextRef)),
    ?assertEqual(
       {scope_invoke_next, self(), ProofId, SessionRef,
        NextRef, InvocationId, 2},
       receive_worker_message()),

    ok = quod_scope_session:invoke_cancel(Handle, InvocationId),
    ?assertEqual(
       {scope_invoke_cancel, self(), ProofId, SessionRef, InvocationId},
       receive_worker_message()),
    ok = quod_scope_session:close(Handle),
    ?assertEqual(
       {scope_close, self(), ProofId, SessionRef},
       receive_worker_message()).

local_materialize_restore_and_release_test() ->
    Session = quod_proof_session:start(committed([]), #{read_set => true}),
    ScopeId = id(10),
    InvocationId = id(11),
    Lineage = id(12),
    BatchIds = [id(13), id(14)],
    Handle = {local_scope, ScopeId, <<"quod:local">>, key(15), 0, Session},
    try
        ?assertMatch(
           {ok, false, _},
           quod_scope_session:materialize(
             Handle, {ScopeId, InvocationId}, Lineage, BatchIds)),
        ?assertMatch(
           {ok, false, _},
           quod_scope_session:restore_many(Handle, BatchIds)),
        ?assertMatch(
           {ok, false, _},
           quod_scope_session:release_many(Handle, BatchIds)),
        ?assertEqual(
           {error, not_allowed},
           quod_scope_session:materialize(
             Handle, {id(99), InvocationId}, Lineage, BatchIds)),
        ?assertEqual(
           {error, {protocol_error, request_binding}},
           quod_scope_session:materialize(
             Handle, {ScopeId, InvocationId}, none, BatchIds)),
        ?assertEqual(
           {error, {protocol_error, request_binding}},
           quod_scope_session:restore_many(Handle, [])),
        ?assertEqual(
           {error, {protocol_error, request_binding}},
           quod_scope_session:release_many(
             Handle, lists:reverse(BatchIds)))
    after
        quod_proof_session:stop(Session)
    end.

local_scope_uses_shared_seal_and_attestation_lifecycle_test() ->
    {TargetKey, Signer} = test_signer(),
    ScopeId = id(150),
    ProofId = key(151),
    Anchor = key(152),
    Target = {<<"quod:local-attest">>, Anchor},
    Origin = {<<"quod:origin">>, key(153)},
    Session = quod_proof_session:start(
                committed([]),
                #{read_set => true,
                  proof_context => {test, local_attestation},
                  signer => Signer}),
    Handle = {local_scope, ScopeId, element(1, Target), Anchor, 3, Session},
    Invocation = id(154),
    _Ctx = quod_proof_context:start(
             ProofId, false, Origin, quod_time:mono_ms() + 5000,
             anonymous),
    try
        ok = quod_proof_session:open(
               Session, Invocation, {assertz, {local_attested, true}},
               allowed, quod_predicates:proof_context(
                          element(1, Target), 3, undefined),
               quod_transaction_scope:empty_selection()),
        ?assertMatch(
           {solution, _}, quod_proof_session:next(Session, Invocation)),
        {ok, Plan} = quod_scope_session:seal(
                       Handle, Origin, anonymous, none),
        Manifest = manifest_for_plan(Plan, key(155), TargetKey),
        {ok, Attestation} =
            quod_scope_session:attest_plan(Handle, Plan, Manifest),
        ?assert(quod_dtx:verify_plan_attestation(
                  Target, Plan, Manifest, Attestation)),
        ?assertEqual(
           {ok, Attestation},
           quod_scope_session:attest_plan(Handle, Plan, Manifest)),
        ?assertEqual(
           {error, {protocol_error, unexpected_scope_command}},
           quod_scope_session:restore_many(Handle, [id(156)]))
    after
        quod_proof_context:stop(fun(_) -> ok end, fun(_) -> ok end),
        quod_proof_session:stop(Session)
    end.

cohosted_materialize_uses_exact_worker_reply_test() ->
    ScopeId = id(16),
    ProofId = key(17),
    SessionRef = make_ref(),
    Parent = self(),
    Worker = spawn(fun() -> fake_batch_worker(Parent) end),
    Handle = {quod_scope_session, Worker, ScopeId, ProofId, SessionRef,
              <<"quod:cohosted">>, key(18)},
    InvocationId = id(19),
    Lineage = id(20),
    BatchIds = [id(21)],
    with_proof_context(
      fun() ->
          ?assertEqual(
             {ok, false, 4},
             quod_scope_session:materialize(
               Handle, {ScopeId, InvocationId}, Lineage, BatchIds))
      end),
    receive
        {worker_batch, checkpoint, BatchIds} -> ok
    after 1000 ->
        ?assert(false)
    end,
    Worker ! stop.

cohosted_group_effect_batch_preserves_owner_and_starts_together_test() ->
    Parent = self(),
    Gate = spawn(fun() -> group_effect_gate(Parent, []) end),
    Worker1 = spawn(fun() -> fake_group_effect_worker(Gate) end),
    Worker2 = spawn(fun() -> fake_group_effect_worker(Gate) end),
    ProofId = key(180),
    SessionRef1 = make_ref(),
    SessionRef2 = make_ref(),
    Handle1 = {quod_scope_session, Worker1, id(181), ProofId, SessionRef1,
               <<"quod:effect-one">>, key(182)},
    Handle2 = {quod_scope_session, Worker2, id(183), ProofId, SessionRef2,
               <<"quod:effect-two">>, key(184)},
    GroupRef = {group, <<"quod:origin">>, key(185), key(186), key(187),
                key(188)},
    try
        ?assertEqual(
           ok,
           quod_scope_session:bind_group_effects(
             [{Handle1, key(189)}, {Handle2, key(190)}],
             GroupRef, 1000)),
        receive
            {group_effect_commands_started, Commands} ->
                ?assertEqual(2, length(Commands)),
                ?assert(
                   lists:all(
                     fun({_Worker, Origin, SeenGroupRef, _PlanDigest}) ->
                             Origin =:= self() andalso
                                 SeenGroupRef =:= GroupRef
                     end, Commands))
        after 1000 ->
            ?assert(false)
        end
    after
        Worker1 ! stop,
        Worker2 ! stop,
        Gate ! stop
    end.

remote_invocation_facade_encodes_goal_and_uses_budget_test() ->
    {Router, Handle, ScopeId, TargetIdentity} = remote_fixture(no_events),
    InvocationId = id(20),
    Goal = {reachable, alice, bob},
    Chain = [{<<"quod:origin">>, key(21)}],
    Selection = quod_transaction_scope:empty_selection(),
    try
        with_proof_context(
          fun() ->
              ?assertEqual(Router, quod_scope_session:pid(Handle)),
              ?assertEqual(ScopeId, quod_scope_session:scope_id(Handle)),
              ?assertEqual(TargetIdentity,
                           quod_scope_session:identity(Handle)),
              {ok, OpenRequestId} = quod_scope_session:invoke_open(
                                      Handle, InvocationId, Goal,
                                      Chain, Selection),
              {OpenRequestId, RemainingMs,
               {invoke_open, InvocationId, Selection, Chain, GoalBlob}} =
                  receive_router_command(),
              ?assert(RemainingMs > 0),
              ?assertEqual({ok, Goal},
                           quod_scope_wire:decode_payload(goal, GoalBlob)),

              {ok, NextRequestId} =
                  quod_scope_session:invoke_next(Handle, InvocationId, 3),
              {NextRequestId, _, {invoke_next, InvocationId, 3}} =
                  receive_router_command(),
              ok = quod_scope_session:invoke_cancel(Handle, InvocationId),
              {_CancelRequestId, _, {invoke_cancel, InvocationId}} =
                  receive_router_command(),

              ok = quod_scope_session:close(Handle),
              {_CloseRequestId, 0, scope_close} = receive_router_command(),
              receive
                  {router_unregister, Handle} -> ok
              after 1000 ->
                  ?assert(false)
              end
          end)
    after
        stop_remote_fixture(Router, Handle)
    end.

remote_materialize_restore_release_are_exact_test() ->
    {Router, Handle, ScopeId, _TargetIdentity} = remote_fixture(ack_controls),
    InvocationId = id(30),
    Lineage = id(31),
    BatchIds = [id(32), id(33)],
    try
        with_proof_context(
          fun() ->
              ?assertEqual(
                 {ok, true, 7},
                 quod_scope_session:materialize(
                   Handle, {ScopeId, InvocationId}, Lineage, BatchIds)),
              {RequestId1, _,
               {materialize, ScopeId, InvocationId, Lineage, BatchIds}} =
                  receive_router_command(),
              assert_unrelated_events_retained(Handle, RequestId1),

              ?assertEqual(
                 {ok, true, 7},
                 quod_scope_session:restore_many(Handle, BatchIds)),
              {RequestId2, _, {batch_restore, BatchIds}} =
                  receive_router_command(),
              assert_unrelated_events_retained(Handle, RequestId2),

              ?assertEqual(
                 {ok, true, 7},
                 quod_scope_session:release_many(Handle, BatchIds)),
              {RequestId3, _, {batch_release, BatchIds}} =
                  receive_router_command(),
              assert_unrelated_events_retained(Handle, RequestId3)
          end)
    after
        stop_remote_fixture(Router, Handle)
    end.

remote_controls_validate_their_explicit_batch_ids_before_send_test() ->
    {Router, Handle, ScopeId, _TargetIdentity} = remote_fixture(no_events),
    try
        with_proof_context(
          fun() ->
              Invalid = {error, {protocol_error, request_binding}},
              ?assertEqual(
                 Invalid,
                 quod_scope_session:materialize(
                   Handle, {ScopeId, id(34)}, id(35), [])),
              ?assertEqual(
                 Invalid, quod_scope_session:restore_many(Handle, [])),
              ?assertEqual(
                 Invalid,
                 quod_scope_session:release_many(
                   Handle, [id(37), id(36)])),
              ?assertEqual(
                 {error, {protocol_error, session_binding}},
                 quod_scope_session:restore_many(
                   {remote_scope, bad_router, bad_generation,
                    bad_binding, bad_link}, [id(38)])),
              receive
                  {router_command, Router, _, _, _} -> ?assert(false)
              after 20 ->
                  ok
              end
          end)
    after
        stop_remote_fixture(Router, Handle)
    end.

failure_reason_is_transport_specific_test() ->
    LocalNs = <<"quod:local-failure">>,
    Local = {quod_scope_session, self(), id(70), key(71), make_ref(),
             LocalNs, key(72)},
    TargetNs = <<"quod:remote-failure">>,
    Binding = node_binding(
                key(73), key(74), key(75), id(76),
                {<<"quod:origin">>, key(77)}, {TargetNs, key(78)},
                read_write),
    Remote = {remote_scope, self(), id(79), Binding, self()},
    ?assertEqual(
       read_only,
       quod_scope_session:failure_reason(Local, {scope_error, read_only})),
    ?assertEqual(
       {proof_limit_exceeded, LocalNs},
       quod_scope_session:failure_reason(Local, killed)),
    ?assertEqual(
       {protocol_error, proof_engine},
       quod_scope_session:failure_reason(Local, unexpected_crash)),
    ?assertEqual(
       {protocol_error, command_sequence},
       quod_scope_session:failure_reason(
         Remote, {protocol_error, command_sequence})),
    ?assertEqual(
       {ontology_unreachable, TargetNs},
       quod_scope_session:failure_reason(Remote, killed)).

remote_control_surfaces_exact_error_and_down_test() ->
    BatchIds = [id(40)],
    {ErrorRouter, ErrorHandle, _ScopeId, _Identity} =
        remote_fixture({scope_error, read_only}),
    try
        with_proof_context(
          fun() ->
              ?assertEqual(
                 {error, read_only},
                 quod_scope_session:restore_many(ErrorHandle, BatchIds)),
              {_RequestId, _, {batch_restore, BatchIds}} =
                  receive_router_command()
          end)
    after
        stop_remote_fixture(ErrorRouter, ErrorHandle)
    end,

    {DownRouter, DownHandle, _ScopeId2, _Identity2} =
        remote_fixture({scope_down, unavailable}),
    try
        with_proof_context(
          fun() ->
              ?assertEqual(
                 {error, {ontology_unreachable, <<"quod:target">>}},
                 quod_scope_session:release_many(DownHandle, BatchIds)),
              {_RequestId, _, {batch_release, BatchIds}} =
                  receive_router_command()
          end)
    after
        stop_remote_fixture(DownRouter, DownHandle)
    end.

remote_control_fails_when_its_exact_router_generation_dies_test() ->
    BatchIds = [id(41)],
    {Router, Handle, _ScopeId, _Identity} = remote_fixture(die_after_command),
    try
        with_proof_context(
          fun() ->
              ?assertEqual(
                 {error, {ontology_unreachable, <<"quod:target">>}},
                 quod_scope_session:restore_many(Handle, BatchIds)),
              {_RequestId, _, {batch_restore, BatchIds}} =
                  receive_router_command()
          end)
    after
        stop_remote_fixture(Router, Handle)
    end.

remote_control_obeys_expired_budget_without_retry_test() ->
    {Router, Handle, _ScopeId, _Identity} = remote_fixture(silent),
    try
        with_proof_context_deadline(
          quod_time:mono_ms(),
          fun() ->
              ?assertEqual(
                 {error,
                  {proof_limit_exceeded, <<"quod:origin">>}},
                 quod_scope_session:restore_many(Handle, [id(50)])),
              receive
                  {router_command, Router, _, _, _} -> ?assert(false)
              after 20 ->
                  ok
              end
          end)
    after
        stop_remote_fixture(Router, Handle)
    end.

remote_seal_and_control_stop_at_the_running_budget_test() ->
    {SealRouter, SealHandle, _SealScopeId, _SealIdentity} =
        remote_fixture(silent),
    try
        with_proof_context_deadline(
          quod_time:mono_ms() + 40,
          fun() ->
              ?assertEqual(
                 {error, {proof_limit_exceeded, <<"quod:origin">>}},
                 quod_scope_session:seal(
                   SealHandle, {<<"quod:origin">>, key(61)}, anonymous,
                   none))
          end)
    after
        stop_remote_fixture(SealRouter, SealHandle)
    end,
    {ControlRouter, ControlHandle, _ControlScopeId, _ControlIdentity} =
        remote_fixture(silent),
    try
        with_proof_context_deadline(
          quod_time:mono_ms() + 40,
          fun() ->
              ?assertEqual(
                 {error, {proof_limit_exceeded, <<"quod:origin">>}},
                 quod_scope_session:restore_many(
                   ControlHandle, [id(51)]))
          end)
    after
        stop_remote_fixture(ControlRouter, ControlHandle)
    end.

remote_scope_seal_and_attestation_are_verified_end_to_end_test() ->
    {Router, Handle, Plan, TargetKey, TargetIdentity} =
        remote_attestation_fixture(),
    try
        with_proof_context(
          fun() ->
              Origin = {<<"quod:origin">>, key(161)},
              ?assertEqual(
                 {ok, Plan},
                 quod_scope_session:seal(Handle, Origin,
                                          {node, key(163)}, none)),
              Manifest1 = manifest_for_plan(Plan, key(164), TargetKey),
              Manifest2 = manifest_for_plan(Plan, key(165), TargetKey),
              {ok, Attestation} =
                  quod_scope_session:attest_plan(
                    Handle, Plan, Manifest1),
              ?assert(quod_dtx:verify_plan_attestation(
                        TargetIdentity, Plan, Manifest1, Attestation)),
              {ok, AttestationBytes} =
                  quod_dtx:encode_attestation(Attestation),
              {ok, Retry} = quod_scope_session:attest_plan(
                              Handle, Plan, Manifest1),
              {ok, RetryBytes} = quod_dtx:encode_attestation(Retry),
              ?assertEqual(AttestationBytes, RetryBytes),
              ?assertEqual(
                 {error, {protocol_error, manifest_binding}},
                 quod_scope_session:attest_plan(
                   Handle, Plan, Manifest2))
          end)
    after
        stop_remote_fixture(Router, Handle)
    end.

fake_worker(Parent) ->
    receive
        Message ->
            Parent ! {worker_message, Message},
            case Message of
                {scope_close, _, _, _} -> ok;
                _ -> fake_worker(Parent)
            end
    end.

fake_batch_worker(Parent) ->
    receive
        {scope_savepoint, Origin, ProofId, SessionRef, RequestRef,
         Operation, BatchIds} ->
            Parent ! {worker_batch, Operation, BatchIds},
            Origin ! {scope_reply, self(), ProofId, SessionRef, RequestRef,
                      {savepoint, Operation, BatchIds, {ok, false, 4}}},
            fake_batch_worker(Parent);
        stop ->
            ok
    end.

fake_group_effect_worker(Gate) ->
    receive
        {scope_bind_group_effects, Origin, ProofId, SessionRef,
         RequestRef, GroupRef, PlanDigest} ->
            Gate ! {group_effect_command, self(), Origin, ProofId, SessionRef,
                    RequestRef, GroupRef, PlanDigest},
            receive
                release_group_effect_reply ->
                    Origin ! {scope_reply, self(), ProofId, SessionRef,
                              RequestRef, {group_effects_bound, ok}}
            end,
            fake_group_effect_worker(Gate);
        stop ->
            ok
    end.

group_effect_gate(Parent, Pending) ->
    receive
        {group_effect_command, _Worker, _Origin, _ProofId, _SessionRef,
         _RequestRef, _GroupRef, _PlanDigest} = Command ->
            Pending1 = [Command | Pending],
            case length(Pending1) of
                2 ->
                    Parent !
                        {group_effect_commands_started,
                         [{Pid, Owner, Ref, Digest}
                          || {group_effect_command, Pid, Owner, _Proof,
                              _Session, _Request, Ref, Digest} <- Pending1]},
                    [Pid ! release_group_effect_reply
                     || {group_effect_command, Pid, _Owner, _Proof,
                         _Session, _Request, _Ref, _Digest} <- Pending1],
                    group_effect_gate(Parent, []);
                _ ->
                    group_effect_gate(Parent, Pending1)
            end;
        stop ->
            ok
    end.

receive_worker_message() ->
    receive
        {worker_message, Message} -> Message
    after 1000 ->
        error(worker_message_timeout)
    end.

%% One co-hosted worker seals its own session over the scope message protocol:
%% the plan binds the scope's pinned identity/height, the requester-supplied
%% origin, and the engine-owned `{node, Principal}` — and carries the exact
%% staged diff.
worker_seals_its_session_on_request_test() ->
    {TargetKey, Signer} = test_signer(),
    ScopeId = id(80),
    ProofId = key(81),
    Anchor = key(82),
    Ns = <<"quod:sealed-scope">>,
    Est = committed([{can_invoke, {'G'}, {'P'}, {'C'}, {'N'}}]),
    {Handle, WorkerMRef} =
        quod_scope_session:start(
          ScopeId, ProofId, self(), Ns, Anchor, 7, Est, self(),
          #{principal => {node, key(83)}, request_binding => none,
            signer => Signer,
            deadline_ms => quod_time:mono_ms() + 5000}),
    {quod_scope_session, Worker, ScopeId, ProofId,
     SessionRef, Ns, Anchor} = Handle,
    Origin = {<<"quod:origin">>, key(85)},
    InvocationId = id(84),
    {ok, OpenRef} = quod_scope_session:invoke_open(
                      Handle, InvocationId, {assertz, {sealed_fact, 1}},
                      [Origin], quod_transaction_scope:empty_selection()),
    ?assertEqual({opened, InvocationId},
                 receive_scope_reply(Worker, ProofId, SessionRef, OpenRef)),
    {ok, NextRef} = quod_scope_session:invoke_next(Handle, InvocationId, 1),
    ?assertMatch({solution, 1, _Solution, true},
                 receive_scope_reply(Worker, ProofId, SessionRef, NextRef)),
    _Ctx = quod_proof_context:start(
             key(86), false, Origin, quod_time:mono_ms() + 5000,
             anonymous),
    try
        {ok, Plan} = quod_scope_session:seal(
                       Handle, Origin, anonymous, none),
        ?assertEqual({Ns, Anchor}, quod_dtx:target(Plan)),
        ?assertEqual(7, quod_dtx:base_height(Plan)),
        ?assertEqual(ProofId, quod_dtx:proof_id(Plan)),
        ?assertEqual(Origin, quod_dtx:origin(Plan)),
        ?assertEqual({node, key(83)}, quod_dtx:principal(Plan)),
        ?assertMatch([{assert, {{sealed_fact, 1}, _Body}}],
                     quod_dtx:diff(Plan)),
        ?assert(quod_dtx:verify(Plan)),
        Manifest1 = manifest_for_plan(Plan, key(87), TargetKey),
        Manifest2 = manifest_for_plan(Plan, key(88), TargetKey),
        ?assertMatch(
           {ok, _},
           quod_dtx:attest_plan(
             quod_dtx:target(Plan), Plan, Manifest2, Signer)),
        {ok, Attestation} =
            quod_scope_session:attest_plan(Handle, Plan, Manifest1),
        ?assert(quod_dtx:verify_plan_attestation(
                  {Ns, Anchor}, Plan, Manifest1, Attestation)),
        {ok, AttestationBytes} =
            quod_dtx:encode_attestation(Attestation),
        {ok, RetryAttestation} =
            quod_scope_session:attest_plan(Handle, Plan, Manifest1),
        {ok, RetryBytes} = quod_dtx:encode_attestation(RetryAttestation),
        ?assertEqual(AttestationBytes, RetryBytes),
        ?assertEqual(
           {error, {protocol_error, manifest_binding}},
           quod_scope_session:attest_plan(Handle, Plan, Manifest2)),

        SealedInvocation = id(89),
        {ok, RejectedOpenRef} = quod_scope_session:invoke_open(
                                  Handle, SealedInvocation, true,
                                  [Origin],
                                  quod_transaction_scope:empty_selection()),
        ?assertEqual(
           {error, {protocol_error, unexpected_scope_command}},
           receive_scope_reply(
             Worker, ProofId, SessionRef, RejectedOpenRef)),
        ?assertEqual(
           {error, {protocol_error, unexpected_scope_command}},
           quod_scope_session:restore_many(Handle, [id(90)]))
    after
        quod_proof_context:stop(fun(_) -> ok end, fun(_) -> ok end)
    end,
    ok = quod_scope_session:close(Handle),
    receive
        {'DOWN', WorkerMRef, process, Worker, _Reason} -> ok
    after 1000 ->
        ?assert(false)
    end.

receive_scope_reply(Worker, ProofId, SessionRef, RequestRef) ->
    receive
        {scope_reply, Worker, ProofId, SessionRef, RequestRef, Reply} -> Reply
    after 1000 ->
        error(scope_reply_timeout)
    end.

remote_fixture(Mode) ->
    Parent = self(),
    Router = spawn(fun() -> fake_router(Parent, Mode, 1) end),
    RequestLink = spawn(fun request_link/0),
    ScopeId = id(60),
    OriginIdentity = {<<"quod:origin">>, key(61)},
    TargetIdentity = {<<"quod:target">>, key(62)},
    Binding = node_binding(
                key(63), key(64), key(65), ScopeId,
                OriginIdentity, TargetIdentity, read_write),
    Handle = {remote_scope, Router, id(66), Binding, RequestLink},
    Router ! {set_handle, Handle},
    {Router, Handle, ScopeId, TargetIdentity}.

remote_attestation_fixture() ->
    Parent = self(),
    {TargetKey, Signer} = test_signer(),
    RequestLink = spawn(fun request_link/0),
    ScopeId = id(160),
    ProofId = key(162),
    OriginIdentity = {<<"quod:origin">>, key(161)},
    TargetIdentity = {<<"quod:target">>, key(166)},
    Principal = {node, key(163)},
    Plan = sealed_test_plan(
             TargetIdentity, OriginIdentity, ProofId, Principal, Signer),
    Mode = {attestation_fixture, Plan, Signer},
    Router = spawn(fun() -> fake_router(Parent, Mode, 1) end),
    Binding = node_binding(
                key(163), TargetKey, ProofId, ScopeId,
                OriginIdentity, TargetIdentity, read_write),
    Handle = {remote_scope, Router, id(167), Binding, RequestLink},
    Router ! {set_handle, Handle},
    {Router, Handle, Plan, TargetKey, TargetIdentity}.

fake_router(Parent, Mode, Counter) ->
    receive
        {set_handle, Handle} ->
            fake_router(Parent, Mode, Counter, Handle)
    end.

fake_router(Parent, Mode, Counter, Handle) ->
    receive
        {'$gen_call', From,
         {command, Owner, Handle, _RouterGeneration, _Binding, _RequestLink,
          RemainingMs, Operation}} ->
            RequestId = id(100 + Counter),
            Reply = router_reply(Operation, RequestId),
            gen_server:reply(From, Reply),
            Parent ! {router_command, self(), RequestId,
                      RemainingMs, Operation},
            send_router_event(Mode, Owner, Handle, RequestId, Operation),
            case Mode of
                die_after_command -> exit(simulated_router_failure);
                _ -> fake_router(Parent, Mode, Counter + 1, Handle)
            end;
        {'$gen_call', From,
         {cancel, _Owner, Handle, _RouterGeneration, _Binding, _RequestLink,
          _RequestId}} ->
            gen_server:reply(From, ok),
            fake_router(Parent, Mode, Counter, Handle);
        {'$gen_cast', {unregister, _Owner, Handle, _RouterGeneration,
                      _Binding, _RequestLink}} ->
            Parent ! {router_unregister, Handle},
            fake_router(Parent, Mode, Counter, Handle);
        stop ->
            ok;
        _Other ->
            fake_router(Parent, Mode, Counter, Handle)
    end.

router_reply({invoke_cancel, _InvocationId}, RequestId) ->
    {sent, RequestId};
router_reply(scope_close, RequestId) ->
    {sent, RequestId};
router_reply(_Operation, RequestId) ->
    {ok, RequestId}.

send_router_event(ack_controls, Owner, Handle, RequestId, Operation) ->
    case control_ack(Operation) of
        none -> ok;
        Ack ->
            Owner ! {quod_scope_event, unrelated_handle, id(250),
                     1, false, unrelated_event},
            Owner ! {quod_scope_event, Handle, id(251),
                     2, false, Ack},
            Owner ! {quod_scope_event, Handle, RequestId,
                     3, false, unrelated_event},
            Owner ! {quod_scope_event, Handle, RequestId, 7, true, Ack}
    end;
send_router_event(
  {attestation_fixture, Plan, _Signer}, Owner, Handle, RequestId,
  scope_seal) ->
    {ok, PlanBlob} = quod_scope_wire:encode_payload(plan, Plan),
    Owner ! {quod_scope_event, Handle, RequestId, 1, true,
             {plan_sealed, PlanBlob}};
send_router_event(
  {attestation_fixture, Plan, Signer}, Owner, Handle, RequestId,
  {scope_attest, ManifestBlob}) ->
    {ok, Manifest} = quod_scope_wire:decode_payload(
                       manifest, ManifestBlob),
    Digest = quod_dtx:manifest_digest(Manifest),
    case get(attestation_manifest_digest) of
        undefined ->
            put(attestation_manifest_digest, Digest),
            send_fixture_attestation(
              Owner, Handle, RequestId, Plan, Manifest, Signer);
        Digest ->
            send_fixture_attestation(
              Owner, Handle, RequestId, Plan, Manifest, Signer);
        _Other ->
            Owner ! {quod_scope_event, Handle, RequestId, 1, true,
                     {scope_error, {protocol_error, manifest_binding}}}
    end;
send_router_event({scope_error, Reason}, Owner, Handle, RequestId, Operation) ->
    case control_ack(Operation) of
        none -> ok;
        _ -> Owner ! {quod_scope_event, Handle, RequestId,
                      7, false, {scope_error, Reason}}
    end;
send_router_event({scope_down, Reason}, Owner, Handle, _RequestId, Operation) ->
    case control_ack(Operation) of
        none -> ok;
        _ -> Owner ! {quod_scope_down, Handle, Reason}
    end;
send_router_event(_Mode, _Owner, _Handle, _RequestId, _Operation) ->
    ok.

send_fixture_attestation(Owner, Handle, RequestId, Plan, Manifest, Signer) ->
    {ok, Attestation} = quod_dtx:attest_plan(
                          quod_dtx:target(Plan), Plan, Manifest, Signer),
    {ok, AttestationBlob} = quod_scope_wire:encode_payload(
                              attestation, Attestation),
    Owner ! {quod_scope_event, Handle, RequestId, 1, true,
             {plan_attested, AttestationBlob}}.

control_ack({materialize, ControllerId, _InvocationId, _Lineage, BatchIds}) ->
    {materialized, ControllerId, BatchIds};
control_ack({batch_restore, BatchIds}) ->
    {batch_restored, BatchIds};
control_ack({batch_release, BatchIds}) ->
    {batch_released, BatchIds};
control_ack(_) ->
    none.

receive_router_command() ->
    receive
        {router_command, _Router, RequestId, RemainingMs, Operation} ->
            {RequestId, RemainingMs, Operation}
    after 1000 ->
        error(router_command_timeout)
    end.

assert_unrelated_events_retained(Handle, RequestId) ->
    receive
        {quod_scope_event, unrelated_handle, _RequestId,
         1, false, unrelated_event} -> ok
    after 0 ->
        ?assert(false)
    end,
    receive
        {quod_scope_event, Handle, OtherRequestId,
         2, false, _Ack} when OtherRequestId =/= RequestId -> ok
    after 0 ->
        ?assert(false)
    end,
    receive
        {quod_scope_event, Handle, RequestId,
         3, false, unrelated_event} -> ok
    after 0 ->
        ?assert(false)
    end.

with_proof_context(Fun) ->
    with_proof_context_deadline(quod_time:mono_ms() + 5000, Fun).

with_proof_context_deadline(Deadline, Fun) ->
    _ = quod_proof_context:start(
          key(70), false, {<<"quod:origin">>, key(71)}, Deadline,
          anonymous),
    try Fun()
    after
        quod_proof_context:stop(fun(_Scope) -> ok end,
                                fun(_Proxy) -> ok end)
    end.

stop_remote_fixture(Router, Handle) ->
    Router ! stop,
    element(5, Handle) ! stop,
    flush_scope_messages().

flush_scope_messages() ->
    receive
        {quod_scope_event, _, _, _, _, _} -> flush_scope_messages();
        {quod_scope_down, _, _} -> flush_scope_messages();
        {router_command, _, _, _, _} -> flush_scope_messages();
        {router_unregister, _} -> flush_scope_messages()
    after 0 ->
        ok
    end.

request_link() ->
    receive stop -> ok end.

committed(Facts) -> quod_ct:committed_kb(Facts).

test_signer() ->
    {Pubkey, Seed} = quod_identity:generate(),
    {Pubkey,
     #{pubkey => Pubkey,
       key => quod_identity:key_term({Pubkey, Seed})}}.

manifest_for_plan(Plan, Nonce, Coordinator) ->
    {ok, GoalBlob} = quod_durable_term:encode_goal({scope, true}),
    {ok, ResultBlob} = quod_durable_term:encode_result(#{}),
    {OriginNs, OriginAnchor} = quod_dtx:origin(Plan),
    Target = quod_dtx:target(Plan),
    {ok, Manifest} = quod_dtx:new_manifest(
                       #{proof_id => quod_dtx:proof_id(Plan),
                         coordinator =>
                             {OriginNs, OriginAnchor,
                              Coordinator, key(240)},
                         nonce => Nonce,
                         principal => quod_dtx:principal(Plan),
                         goal => GoalBlob,
                         result => ResultBlob,
                         request_binding => none,
                         participants =>
                             [{Target, quod_dtx:digest(Plan)},
                              {{<<"quod:other">>, key(241)}, key(242)}]}),
    Manifest.

sealed_test_plan(Target, Origin, ProofId, Principal, Signer) ->
    Session = quod_proof_session:start(
                committed([]),
                #{read_set => true,
                  proof_context => {test, remote_attestation},
                  signer => Signer}),
    Invocation = id(243),
    try
        ok = quod_proof_session:open(
               Session, Invocation, {assertz, {remote_attested, true}},
               allowed,
               quod_predicates:proof_context(
                 element(1, Target), 4, undefined),
               quod_transaction_scope:empty_selection()),
        ?assertMatch(
           {solution, _}, quod_proof_session:next(Session, Invocation)),
        {ok, Plan} = quod_proof_session:seal(
                       Session,
                       #{target => Target, base_height => 4,
                         proof_id => ProofId, origin => Origin,
                         principal => Principal, request_binding => none}),
        Plan
    after
        quod_proof_session:stop(Session)
    end.

node_binding(OriginKey, TargetKey, ProofId, ScopeId,
             OriginIdentity, TargetIdentity, Mode) ->
    {ok, AuthenticationDigest} =
        quod_scope_wire:authentication_digest(node),
    {scope_binding, OriginKey, TargetKey, ProofId, ScopeId,
     OriginIdentity, TargetIdentity, Mode,
     {node, OriginKey}, AuthenticationDigest}.

id(N) -> <<N:128>>.
key(N) -> <<N:256>>.

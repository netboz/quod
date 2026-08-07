-module(quod_scope_session_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_proof_limits.hrl").

startup_failure_is_asynchronous_and_monitored_test() ->
    ProofId = crypto:strong_rand_bytes(32),
    Anchor = crypto:strong_rand_bytes(32),
    ScopeId = crypto:strong_rand_bytes(16),
    {Handle, WorkerMRef} =
        quod_scope_session:start(
          ScopeId, ProofId, self(), <<"quod:broken-scope">>, Anchor, 0,
          {not_an_erlog_state}, self(),
          #{principal => key(1),
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
          #{principal => key(89),
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

    InvocationId = id(94),
    {ok, OpenRef} = quod_scope_session:invoke_open(
                      Handle, InvocationId, true,
                      [{<<"quod:origin">>, key(95)}],
                      quod_transaction_scope:empty_selection()),
    ?assertEqual(
       {error, {not_allowed, Ns}},
       receive_scope_reply(Worker, ProofId, SessionRef, OpenRef)),

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
    Binding = {scope_binding, key(73), key(74), key(75), id(76),
               {<<"quod:origin">>, key(77)}, {TargetNs, key(78)},
               read_write},
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

receive_worker_message() ->
    receive
        {worker_message, Message} -> Message
    after 1000 ->
        error(worker_message_timeout)
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
    Binding = {scope_binding, key(63), key(64), key(65), ScopeId,
               OriginIdentity, TargetIdentity, read_write},
    Handle = {remote_scope, Router, id(66), Binding, RequestLink},
    Router ! {set_handle, Handle},
    {Router, Handle, ScopeId, TargetIdentity}.

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
          key(70), false, {<<"quod:origin">>, key(71)}, Deadline),
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

id(N) -> <<N:128>>.
key(N) -> <<N:256>>.

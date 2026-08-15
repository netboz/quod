-module(quod_client_cursor_tests).
-moduledoc false.

-include_lib("eunit/include/eunit.hrl").

-define(SESSION, <<16#21:256>>).
-define(PRINCIPAL, {user, <<16#22:256>>}).

cursor_command_busy_and_solution_correlation_test() ->
    {CursorId, Engine, Worker, CallRef, State0} = cursor_state(none, none),
    Tag = make_ref(),
    {noreply, State1} = quod_client_cursor:handle_call(
                          {command, ?SESSION, ?PRINCIPAL, CursorId, next},
                          {self(), Tag}, State0),
    CommandRef = receive
        {worker_message, Worker,
         {quod_cursor_command, _Owner, CallRef, CursorId,
          SeenCommandRef, next}} -> SeenCommandRef
    after 1000 -> error(cursor_command_missing)
    end,
    ?assertMatch(
       {reply, {error, busy}, _},
       quod_client_cursor:handle_call(
         {command, ?SESSION, ?PRINCIPAL, CursorId, accept},
         {self(), make_ref()}, State1)),
    {noreply, State2} = quod_client_cursor:handle_info(
                          {quod_cursor_solution, Worker, CallRef, CursorId,
                           CommandRef, #{'X' => second}, 7}, State1),
    receive
        {Tag, {ok, _Evidence,
               {solution, CursorId, #{'X' := second}, 7}}} -> ok
    after 1000 -> error(cursor_solution_reply_missing)
    end,
    #{CursorId := #{pending := none}} = maps:get(cursors, State2),
    {noreply, State3} = quod_client_cursor:handle_info(
                          {quod_proof_reply, Engine, CallRef, cursor_stopped},
                          State2),
    ?assertEqual(#{}, maps:get(cursors, State3)),
    stop_cursor_fixture(Engine, Worker).

cursor_stale_solution_kills_exact_worker_test() ->
    {CursorId, Engine, Worker, CallRef, State0} = cursor_state(none, none),
    WorkerMRef = monitor(process, Worker),
    {noreply, State1} = quod_client_cursor:handle_call(
                          {command, ?SESSION, ?PRINCIPAL, CursorId, next},
                          {self(), make_ref()}, State0),
    receive {worker_message, Worker, _} -> ok
    after 1000 -> error(cursor_command_missing)
    end,
    {noreply, State2} = quod_client_cursor:handle_info(
                          {quod_cursor_solution, Worker, CallRef, CursorId,
                           make_ref(), #{}, 7}, State1),
    ?assertEqual(#{}, maps:get(cursors, State2)),
    receive {'DOWN', WorkerMRef, process, Worker, killed} -> ok
    after 1000 -> error(stale_cursor_worker_survived)
    end,
    stop_cursor_fixture(Engine, undefined).

cursor_owner_is_exact_test() ->
    {CursorId, Engine, Worker, _CallRef, State0} = cursor_state(none, none),
    ?assertMatch(
       {reply, {error, not_found}, _},
       quod_client_cursor:handle_call(
         {command, <<0:256>>, ?PRINCIPAL, CursorId, next},
         {self(), make_ref()}, State0)),
    ?assertMatch(
       {reply, {error, not_found}, _},
       quod_client_cursor:handle_call(
         {command, ?SESSION, {user, <<0:256>>}, CursorId, next},
         {self(), make_ref()}, State0)),
    stop_cursor_fixture(Engine, Worker).

cursor_caller_down_cancels_next_but_detaches_accept_test() ->
    {NextId, NextEngine, NextWorker, _NextCallRef, NextState0} =
        cursor_state(none, none),
    NextWorkerMRef = monitor(process, NextWorker),
    NextCaller = spawn(fun cursor_fixture_loop/0),
    {noreply, NextState1} = quod_client_cursor:handle_call(
                              {command, ?SESSION, ?PRINCIPAL, NextId, next},
                              {NextCaller, make_ref()}, NextState0),
    receive {worker_message, NextWorker, _} -> ok
    after 1000 -> error(next_command_missing)
    end,
    NextCallerMRef = pending_caller_mref(NextId, NextState1),
    exit(NextCaller, kill),
    NextDown = receive
        {'DOWN', NextCallerMRef, process, NextCaller, killed} = NextDownMsg ->
            NextDownMsg
    after 1000 -> error(next_caller_down_missing)
    end,
    {noreply, NextState2} =
        quod_client_cursor:handle_info(NextDown, NextState1),
    ?assertEqual(#{}, maps:get(cursors, NextState2)),
    receive {'DOWN', NextWorkerMRef, process, NextWorker, killed} -> ok
    after 1000 -> error(next_worker_survived_caller)
    end,
    stop_cursor_fixture(NextEngine, undefined),

    {AcceptId, AcceptEngine, AcceptWorker, AcceptCallRef, AcceptState0} =
        cursor_state(none, none),
    AcceptCaller = spawn(fun cursor_fixture_loop/0),
    {noreply, AcceptState1} = quod_client_cursor:handle_call(
                                {command, ?SESSION, ?PRINCIPAL,
                                 AcceptId, accept},
                                {AcceptCaller, make_ref()}, AcceptState0),
    receive {worker_message, AcceptWorker, _} -> ok
    after 1000 -> error(accept_command_missing)
    end,
    AcceptCallerMRef = pending_caller_mref(AcceptId, AcceptState1),
    exit(AcceptCaller, kill),
    AcceptDown = receive
        {'DOWN', AcceptCallerMRef, process, AcceptCaller, killed} = AcceptDownMsg ->
            AcceptDownMsg
    after 1000 -> error(accept_caller_down_missing)
    end,
    {noreply, AcceptState2} =
        quod_client_cursor:handle_info(AcceptDown, AcceptState1),
    #{AcceptId := #{pending := detached_accept}} =
        maps:get(cursors, AcceptState2),
    ?assert(is_process_alive(AcceptWorker)),
    {noreply, AcceptState3} = quod_client_cursor:handle_info(
                               {quod_proof_reply, AcceptEngine,
                                AcceptCallRef, {ok, [#{}], 8}},
                               AcceptState2),
    ?assertEqual(#{}, maps:get(cursors, AcceptState3)),
    stop_cursor_fixture(AcceptEngine, AcceptWorker).

cursor_engine_down_preserves_exact_checkpoint_test() ->
    Ref = {transaction, <<"ont:test">>, <<41:256>>, <<42:256>>},
    lists:foreach(
      fun({Checkpoint, Expected}) ->
          Tag = make_ref(),
          CallerMRef = monitor(process, self()),
          Pending = {{self(), Tag}, CallerMRef, open},
          {CursorId, Engine, Worker, _CallRef, State0} =
              cursor_state(Pending, Checkpoint),
          EngineMRef = cursor_engine_mref(CursorId, State0),
          exit(Engine, kill),
          EngineDown = receive
              {'DOWN', EngineMRef, process, Engine, killed} = Down -> Down
          after 1000 -> error(cursor_engine_down_missing)
          end,
          {noreply, State1} =
              quod_client_cursor:handle_info(EngineDown, State0),
          receive {Tag, {ok, _Evidence, Expected}} -> ok
          after 1000 -> error(cursor_engine_reply_missing)
          end,
          ?assertEqual(#{}, maps:get(cursors, State1)),
          stop_cursor_fixture(undefined, Worker)
      end,
      [{none, {error, ontology_unavailable}},
       {Ref, {error, {outcome_unknown, Ref}}}]).

cursor_terminate_preserves_detached_accept_worker_test() ->
    {ok, _} = application:ensure_all_started(cowboy),
    {CursorId, Engine, Worker, _CallRef, State0} =
        cursor_state(detached_accept, none),
    ?assertEqual(ok, quod_client_cursor:terminate(shutdown, State0)),
    ?assert(is_process_alive(Worker)),
    ?assert(maps:is_key(CursorId, maps:get(cursors, State0))),
    stop_cursor_fixture(Engine, Worker).

cursor_state(Pending, Checkpoint) ->
    Parent = self(),
    Engine = spawn(fun cursor_fixture_loop/0),
    Worker = spawn(fun() -> cursor_worker_loop(Parent) end),
    EngineMRef = monitor(process, Engine),
    CursorId = crypto:strong_rand_bytes(32),
    CallRef = make_ref(),
    Evidence = #{request_digest => <<16#23:256>>,
                 request => #{operation_id => <<16#24:256>>},
                 variables => []},
    Cursor = #{engine => Engine, engine_mref => EngineMRef,
               call_ref => CallRef, worker => Worker,
               checkpoint => Checkpoint, pending => Pending,
               session_id => ?SESSION, principal => ?PRINCIPAL,
               evidence => Evidence},
    {CursorId, Engine, Worker, CallRef,
     #{cursors => #{CursorId => Cursor}}}.

cursor_worker_loop(Parent) ->
    receive
        stop -> ok;
        Message ->
            Parent ! {worker_message, self(), Message},
            cursor_worker_loop(Parent)
    end.

cursor_fixture_loop() ->
    receive stop -> ok end.

pending_caller_mref(CursorId, State) ->
    #{CursorId := #{pending := {_From, MRef, _Command}}} =
        maps:get(cursors, State),
    MRef.

cursor_engine_mref(CursorId, State) ->
    #{CursorId := #{engine_mref := MRef}} = maps:get(cursors, State),
    MRef.

stop_cursor_fixture(Engine, Worker) ->
    lists:foreach(
      fun(Pid) when is_pid(Pid) ->
              case is_process_alive(Pid) of
                  true -> Pid ! stop;
                  false -> ok
              end;
         (_) -> ok
      end, [Engine, Worker]).

-module(quod_client_cursor_tests).
-moduledoc false.

-include_lib("eunit/include/eunit.hrl").

-define(SESSION, <<16#21:256>>).
-define(PRINCIPAL, {agent, agent_ref()}).
-define(OWNER, {session, ?SESSION, agent_ref()}).

cursor_command_busy_and_solution_correlation_test() ->
    {CursorId, Engine, Worker, CallRef, State0} = cursor_state(none, none),
    Tag = make_ref(),
    {noreply, State1} = quod_client_cursor:handle_call(
                          {command, ?OWNER, CursorId, next},
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
         {command, ?OWNER, CursorId, accept},
         {self(), make_ref()}, State1)),
    {noreply, State2} = quod_client_cursor:handle_info(
                          {quod_cursor_solution, Worker, CallRef, CursorId,
                           CommandRef, #{'X' => second}, 7}, State1),
    receive
        {Tag, {ok, _Evidence,
               {solution, CursorId, #{'X' := second}, 7}}} -> ok
    after 1000 -> error(cursor_solution_reply_missing)
    end,
    Owner = ?OWNER,
    #{{Owner, CursorId} := #{pending := none}} = maps:get(cursors, State2),
    {noreply, State3} = quod_client_cursor:handle_info(
                          {quod_proof_reply, Engine, CallRef, cursor_stopped},
                          State2),
    ?assertEqual(#{}, maps:get(cursors, State3)),
    stop_cursor_fixture(Engine, Worker).

cursor_stale_solution_kills_exact_worker_test() ->
    {CursorId, Engine, Worker, CallRef, State0} = cursor_state(none, none),
    WorkerMRef = monitor(process, Worker),
    {noreply, State1} = quod_client_cursor:handle_call(
                          {command, ?OWNER, CursorId, next},
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
         {command, {session, <<0:256>>, <<16#22:256>>}, CursorId, next},
         {self(), make_ref()}, State0)),
    ?assertMatch(
       {reply, {error, not_found}, _},
       quod_client_cursor:handle_call(
         {command, {session, ?SESSION, <<0:256>>}, CursorId, next},
         {self(), make_ref()}, State0)),
    stop_cursor_fixture(Engine, Worker).

cursor_caller_down_cancels_next_but_detaches_accept_test() ->
    {NextId, NextEngine, NextWorker, _NextCallRef, NextState0} =
        cursor_state(none, none),
    NextWorkerMRef = monitor(process, NextWorker),
    NextCaller = spawn(fun cursor_fixture_loop/0),
    {noreply, NextState1} = quod_client_cursor:handle_call(
                              {command, ?OWNER, NextId, next},
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
                                {command, ?OWNER, AcceptId, accept},
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
    AcceptOwner = ?OWNER,
    #{{AcceptOwner, AcceptId} := #{pending := detached_accept}} =
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
    ?assert(maps:is_key({?OWNER, CursorId}, maps:get(cursors, State0))),
    stop_cursor_fixture(Engine, Worker).

forwarded_cursor_requires_the_exact_gateway_and_link_test() ->
    Link = spawn(fun cursor_fixture_loop/0),
    Gateway = <<16#31:256>>,
    Owner = {forwarder, Gateway, Link, agent_ref()},
    {CursorId, Engine, Worker, CallRef, State0} =
        cursor_state(none, none, Owner),
    Tag = make_ref(),
    {noreply, State1} = quod_client_cursor:handle_call(
                          {command_forwarded, Gateway, Link, CursorId, next},
                          {self(), Tag}, State0),
    CommandRef = receive
        {worker_message, Worker,
         {quod_cursor_command, _Coordinator, CallRef, CursorId,
          Ref, next}} -> Ref
    after 1000 -> error(forwarded_cursor_command_missing)
    end,
    ?assertMatch(
       {reply, {error, not_found}, _},
       quod_client_cursor:handle_call(
         {command_forwarded, <<0:256>>, Link, CursorId, next},
         {self(), make_ref()}, State0)),
    OtherLink = spawn(fun cursor_fixture_loop/0),
    ?assertMatch(
       {reply, {error, not_found}, _},
       quod_client_cursor:handle_call(
         {command_forwarded, Gateway, OtherLink, CursorId, next},
         {self(), make_ref()}, State0)),
    {noreply, State2} = quod_client_cursor:handle_info(
                          {quod_cursor_solution, Worker, CallRef, CursorId,
                           CommandRef, #{}, 7}, State1),
    receive {Tag, {ok, _, {solution, CursorId, #{}, 7}}} -> ok
    after 1000 -> error(forwarded_cursor_reply_missing)
    end,
    stop_cursor_fixture(Engine, Worker),
    stop_cursor_fixture(Link, OtherLink),
    _ = State2,
    ok.

second_gateway_cannot_open_an_existing_cursor_id_test() ->
    Link1 = spawn(fun cursor_fixture_loop/0),
    Link2 = spawn(fun cursor_fixture_loop/0),
    Owner1 = {forwarder, <<16#33:256>>, Link1, agent_ref()},
    Owner2 = {forwarder, <<16#34:256>>, Link2, agent_ref()},
    {CursorId, Engine, Worker, _CallRef, State0} =
        cursor_state(none, none, Owner1),
    #{{Owner1, CursorId} := #{evidence := Evidence}} =
        maps:get(cursors, State0),
    ?assertMatch(
       {reply, {error, not_found}, _},
       quod_client_cursor:handle_call(
         {open, Owner2, CursorId, Evidence, true, ?PRINCIPAL},
         {self(), make_ref()}, State0)),
    stop_cursor_fixture(Engine, Worker),
    stop_cursor_fixture(Link1, Link2).

forwarded_link_down_cancels_next_but_detaches_accept_test() ->
    lists:foreach(
      fun({PendingKind, Detached}) ->
          Link = spawn(fun cursor_fixture_loop/0),
          Gateway = <<16#32:256>>,
          Owner = {forwarder, Gateway, Link, agent_ref()},
          {CursorId, Engine, Worker, _CallRef, State0} =
              cursor_state(none, none, Owner),
          Tag = make_ref(),
          {noreply, State1} = quod_client_cursor:handle_call(
                                {command, Owner, CursorId, PendingKind},
                                {self(), Tag}, State0),
          receive {worker_message, Worker, _} -> ok
          after 1000 -> error(forwarded_command_missing)
          end,
          OwnerMRef = cursor_owner_mref(Owner, CursorId, State1),
          exit(Link, kill),
          Down = receive
              {'DOWN', OwnerMRef, process, Link, killed} = Message -> Message
          after 1000 -> error(forwarder_down_missing)
          end,
          WorkerMRef = monitor(process, Worker),
          {noreply, State2} = quod_client_cursor:handle_info(Down, State1),
          case Detached of
              true ->
                  receive
                      {Tag, {ok, _,
                             {error, {outcome_unknown,
                                      {operation, _, _, _, _}}}}} -> ok
                  after 1000 -> error(accept_uncertainty_missing)
                  end,
                  #{{Owner, CursorId} := #{pending := detached_accept}} =
                      maps:get(cursors, State2),
                  ?assert(is_process_alive(Worker));
              false ->
                  receive
                      {Tag, {ok, _, {error, client_cursor_unavailable}}} -> ok
                  after 1000 -> error(next_unavailable_missing)
                  end,
                  ?assertEqual(#{}, maps:get(cursors, State2)),
                  receive {'DOWN', WorkerMRef, process, Worker, killed} -> ok
                  after 1000 -> error(next_worker_survived_link)
                  end
          end,
          stop_cursor_fixture(Engine, Worker)
      end,
      [{next, false}, {accept, true}]).

cursor_state(Pending, Checkpoint) ->
    cursor_state(Pending, Checkpoint, ?OWNER).

cursor_state(Pending, Checkpoint, Owner) ->
    Parent = self(),
    Engine = spawn(fun cursor_fixture_loop/0),
    Worker = spawn(fun() -> cursor_worker_loop(Parent) end),
    EngineMRef = monitor(process, Engine),
    OwnerMRef = case Owner of
                    {forwarder, _, Link, _} -> monitor(process, Link);
                    _ -> undefined
                end,
    CursorId = crypto:strong_rand_bytes(32),
    CallRef = make_ref(),
    Evidence = #{request_digest => <<16#23:256>>,
                 operation_ref =>
                     {operation, <<"test">>, <<16#25:256>>,
                      agent_ref(), <<16#24:256>>},
                 request => #{operation_id => <<16#24:256>>},
                 variables => []},
    Cursor = #{engine => Engine, engine_mref => EngineMRef,
               owner_mref => OwnerMRef,
               call_ref => CallRef, worker => Worker,
               checkpoint => Checkpoint, pending => Pending,
               owner => Owner, principal => ?PRINCIPAL,
               evidence => Evidence},
    {CursorId, Engine, Worker, CallRef,
     #{cursors => #{{Owner, CursorId} => Cursor}}}.

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
    Owner = ?OWNER,
    #{{Owner, CursorId} := #{pending := {_From, MRef, _Command}}} =
        maps:get(cursors, State),
    MRef.

cursor_engine_mref(CursorId, State) ->
    Owner = ?OWNER,
    #{{Owner, CursorId} := #{engine_mref := MRef}} = maps:get(cursors, State),
    MRef.

cursor_owner_mref(Owner, CursorId, State) ->
    #{{Owner, CursorId} := #{owner_mref := MRef}} = maps:get(cursors, State),
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

agent_ref() ->
    {ok, #{blob := Blob}} = quod_agent_ref:from_text(
                              <<"test">>, <<16#25:256>>,
                              <<"test_agent.">>, 1),
    Blob.

-module(quod_client_cursor).
-moduledoc """
One bounded owner for signed client proof cursors.

This is the existing proof-cursor coordinator, independent of any UI.  It
owns only volatile cursor/session correlation.  The ontology engine still
owns proof execution, authorization, staging, sealing and durable handoff.
Every cursor retains the original verified request evidence; `accept` resumes
that exact proof and cannot replace its goal, user, target or operation id.
""".

-behaviour(gen_server).

-export([start_link/0, open/4, command/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link() ->
    case application:get_env(quod, client_enabled, false) of
        true -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []);
        _ -> ignore
    end.

-spec open(<<_:256>>, quod_client_goal:evidence(), term(),
           {user, <<_:256>>}) ->
          {ok, quod_client_goal:evidence(), term()} | {error, term()}.
open(<<_:256>> = SessionId, Evidence, Goal,
     {user, <<_:256>>} = Principal) ->
    call({open, SessionId, Evidence, Goal, Principal});
open(_SessionId, _Evidence, _Goal, _Principal) ->
    {error, invalid_signed_goal}.

-spec command(<<_:256>>, {user, <<_:256>>}, <<_:256>>,
              next | accept | stop) ->
          {ok, quod_client_goal:evidence(), term()} | {error, term()}.
command(<<_:256>> = SessionId, {user, <<_:256>>} = Principal,
        <<_:256>> = CursorId, Command)
  when Command =:= next; Command =:= accept; Command =:= stop ->
    call({command, SessionId, Principal, CursorId, Command});
command(_SessionId, _Principal, _CursorId, _Command) ->
    {error, bad_request}.

call(Request) ->
    try gen_server:call(?MODULE, Request, infinity)
    catch exit:_ -> {error, client_cursor_unavailable}
    end.

init([]) ->
    {ok, #{cursors => #{}}}.

handle_call({open, SessionId, Evidence, Goal, Principal}, From,
            State = #{cursors := Cursors}) ->
    CursorId = new_cursor_id(Cursors),
    case quod_prolog:open_cursor(Evidence, Goal, Principal, self(), CursorId) of
        {ok, Engine, CallRef} ->
            EngineMRef = monitor(process, Engine),
            CallerMRef = monitor(process, element(1, From)),
            Cursor = #{engine => Engine, engine_mref => EngineMRef,
                       call_ref => CallRef, worker => undefined,
                       checkpoint => none,
                       session_id => SessionId, principal => Principal,
                       evidence => Evidence,
                       pending => {From, CallerMRef, open}},
            {noreply, State#{cursors => Cursors#{CursorId => Cursor}}};
        {error, _} = Error ->
            {reply, Error, State}
    end;
handle_call({command, SessionId, Principal, CursorId, Command}, From,
            State = #{cursors := Cursors}) ->
    case maps:find(CursorId, Cursors) of
        {ok, #{session_id := SessionId, principal := Principal,
               pending := none, worker := Worker,
               call_ref := CallRef} = Cursor}
          when is_pid(Worker) ->
            CommandRef = make_ref(),
            CallerMRef = monitor(process, element(1, From)),
            Worker ! {quod_cursor_command, self(), CallRef, CursorId,
                      CommandRef, Command},
            Cursor1 = Cursor#{pending =>
                                {From, CallerMRef,
                                 {CommandRef, Command}}},
            {noreply, State#{cursors => Cursors#{CursorId => Cursor1}}};
        {ok, #{session_id := SessionId, principal := Principal,
               pending := none}} ->
            {reply, {error, not_ready}, State};
        {ok, #{session_id := SessionId, principal := Principal}} ->
            {reply, {error, busy}, State};
        {ok, _WrongOwner} ->
            {reply, {error, not_found}, State};
        error ->
            {reply, {error, not_found}, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, bad_request}, State}.

handle_cast(_Message, State) -> {noreply, State}.

handle_info(
  {quod_cursor_solution, Worker, CallRef, CursorId, CommandRef,
   Bindings, Height}, State = #{cursors := Cursors}) ->
    case maps:find(CursorId, Cursors) of
        {ok, #{call_ref := CallRef, worker := Existing,
               evidence := Evidence, pending := Pending} = Cursor}
          when Existing =:= undefined; Existing =:= Worker ->
            case cursor_solution_pending(CommandRef, Pending) of
                {ok, From, CallerMRef} ->
                    demonitor(CallerMRef, [flush]),
                    gen_server:reply(
                      From,
                      {ok, Evidence,
                       {solution, CursorId, Bindings, Height}}),
                    Cursor1 = Cursor#{worker => Worker, pending => none},
                    {noreply,
                     State#{cursors => Cursors#{CursorId => Cursor1}}};
                error ->
                    stop_unknown_cursor(Cursor),
                    {noreply, drop_cursor(CursorId, State)}
            end;
        _ ->
            {noreply, State}
    end;
handle_info({quod_proof_checkpoint, Engine, CallRef, Ref},
            State = #{cursors := Cursors}) ->
    case find_cursor_by_call(Engine, CallRef, Cursors) of
        {ok, CursorId, Cursor} ->
            {noreply,
             State#{cursors => Cursors#{CursorId =>
                                          Cursor#{checkpoint => Ref}}}};
        error ->
            {noreply, State}
    end;
handle_info({quod_proof_reply, Engine, CallRef, Reply},
            State = #{cursors := Cursors}) ->
    case find_cursor_by_call(Engine, CallRef, Cursors) of
        {ok, CursorId, Cursor} ->
            reply_pending(Cursor, Reply),
            {noreply, drop_cursor(CursorId, State)};
        error ->
            {noreply, State}
    end;
handle_info({'DOWN', MRef, process, _Pid, _Reason},
            State = #{cursors := Cursors}) ->
    case find_cursor_monitor(MRef, Cursors) of
        {engine, CursorId, Cursor} ->
            Reply = case maps:get(checkpoint, Cursor) of
                        none -> {error, ontology_unavailable};
                        Ref -> {error, {outcome_unknown, Ref}}
                    end,
            reply_pending(Cursor, Reply),
            {noreply, drop_cursor(CursorId, State)};
        {caller, CursorId, Cursor} ->
            case detach_accept_observer(MRef, Cursor) of
                {ok, Cursor1} ->
                    %% Accept may have crossed durable handoff.  Losing its
                    %% HTTP observer must not turn uncertainty into a retry.
                    {noreply,
                     State#{cursors => Cursors#{CursorId => Cursor1}}};
                error ->
                    stop_unknown_cursor(Cursor),
                    {noreply, drop_cursor(CursorId, State)}
            end;
        error ->
            {noreply, State}
    end;
handle_info(_Message, State) -> {noreply, State}.

terminate(_Reason, #{cursors := Cursors}) ->
    maps:foreach(fun(_CursorId, Cursor) -> stop_cursor_on_terminate(Cursor) end,
                 Cursors),
    ok.

new_cursor_id(Cursors) ->
    CursorId = crypto:strong_rand_bytes(32),
    case maps:is_key(CursorId, Cursors) of
        true -> new_cursor_id(Cursors);
        false -> CursorId
    end.

cursor_solution_pending(open, {From, MRef, open}) ->
    {ok, From, MRef};
cursor_solution_pending(CommandRef,
                        {From, MRef, {CommandRef, next}}) ->
    {ok, From, MRef};
cursor_solution_pending(_CommandRef, _Pending) ->
    error.

find_cursor_by_call(Engine, CallRef, Cursors) ->
    maps:fold(
      fun(CursorId,
          #{engine := Engine0, call_ref := CallRef0} = Cursor, Acc) ->
              case Acc of
                  error when Engine0 =:= Engine, CallRef0 =:= CallRef ->
                      {ok, CursorId, Cursor};
                  _ -> Acc
              end
      end, error, Cursors).

find_cursor_monitor(MRef, Cursors) ->
    maps:fold(
      fun(CursorId, Cursor, Acc) ->
              case Acc of
                  error ->
                      case Cursor of
                          #{engine_mref := MRef} ->
                              {engine, CursorId, Cursor};
                          #{pending := {_From, MRef, _Command}} ->
                              {caller, CursorId, Cursor};
                          _ -> error
                      end;
                  _ -> Acc
              end
      end, error, Cursors).

reply_pending(
  #{pending := {From, CallerMRef, _Command}, evidence := Evidence}, Reply) ->
    demonitor(CallerMRef, [flush]),
    gen_server:reply(From, {ok, Evidence, Reply});
reply_pending(_Cursor, _Reply) ->
    ok.

detach_accept_observer(
  MRef, Cursor = #{pending := {_From, MRef, {_CommandRef, accept}}}) ->
    {ok, Cursor#{pending => detached_accept}};
detach_accept_observer(_MRef, _Cursor) ->
    error.

stop_cursor_on_terminate(#{pending := detached_accept}) -> ok;
stop_cursor_on_terminate(Cursor) -> stop_unknown_cursor(Cursor).

drop_cursor(CursorId, State = #{cursors := Cursors}) ->
    case maps:take(CursorId, Cursors) of
        {Cursor, Cursors1} ->
            demonitor(maps:get(engine_mref, Cursor), [flush]),
            case maps:get(pending, Cursor) of
                {_From, CallerMRef, _Command} ->
                    demonitor(CallerMRef, [flush]);
                none -> ok;
                detached_accept -> ok
            end,
            State#{cursors => Cursors1};
        error -> State
    end.

stop_unknown_cursor(#{worker := Worker}) when is_pid(Worker) ->
    exit(Worker, kill),
    ok;
stop_unknown_cursor(#{engine := Engine, call_ref := CallRef}) ->
    quod_prolog:cancel_cursor(Engine, self(), CallRef).

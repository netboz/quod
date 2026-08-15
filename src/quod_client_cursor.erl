-module(quod_client_cursor).
-moduledoc """
One bounded owner for signed client proof cursors.

This is the existing proof-cursor coordinator, independent of any UI.  It
owns only volatile cursor/capability correlation.  The ontology engine still
owns proof execution, authorization, staging, sealing and durable handoff.
Every cursor retains the original verified request evidence; `accept` resumes
that exact proof and cannot replace its goal, user, target or operation id.
""".

-behaviour(gen_server).

-export([start_link/0, open/5, command/3, command_forwarded/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-type owner() ::
        {session, <<_:256>>, <<_:256>>} |
        {forwarder, <<_:256>>, pid(), <<_:256>>}.

-spec open(owner(), <<_:256>>, quod_client_goal:evidence(), term(),
           {user, <<_:256>>}) ->
          {ok, quod_client_goal:evidence(), term()} | {error, term()}.
open(Owner, <<_:256>> = CursorId, Evidence, Goal,
     {user, <<_:256>> = User} = Principal) ->
    case valid_owner(Owner, User) of
        true -> call({open, Owner, CursorId, Evidence, Goal, Principal});
        false -> {error, invalid_signed_goal}
    end;
open(_Owner, _CursorId, _Evidence, _Goal, _Principal) ->
    {error, invalid_signed_goal}.

-spec command(owner(), <<_:256>>, next | accept | stop) ->
          {ok, quod_client_goal:evidence(), term()} | {error, term()}.
command(Owner, <<_:256>> = CursorId, Command)
  when Command =:= next; Command =:= accept; Command =:= stop ->
    case valid_owner_shape(Owner) of
        true -> call({command, Owner, CursorId, Command});
        false -> {error, bad_request}
    end;
command(_Owner, _CursorId, _Command) ->
    {error, bad_request}.

-doc "Resume the cursor owned by this exact authenticated gateway link.".
-spec command_forwarded(<<_:256>>, pid(), <<_:256>>,
                        next | accept | stop) ->
          {ok, quod_client_goal:evidence(), term()} | {error, term()}.
command_forwarded(<<_:256>> = GatewayKey, Link, <<_:256>> = CursorId,
                  Command) when is_pid(Link),
                                (Command =:= next orelse
                                 Command =:= accept orelse
                                 Command =:= stop) ->
    call({command_forwarded, GatewayKey, Link, CursorId, Command});
command_forwarded(_GatewayKey, _Link, _CursorId, _Command) ->
    {error, bad_request}.

call(Request) ->
    try gen_server:call(?MODULE, Request, infinity)
    catch exit:_ -> {error, client_cursor_unavailable}
    end.

init([]) ->
    {ok, #{cursors => #{}}}.

handle_call({open, Owner, CursorId, Evidence, Goal, Principal}, From,
            State = #{cursors := Cursors}) ->
    Key = {Owner, CursorId},
    case cursor_open_admission(Key, CursorId, Cursors) of
        ok ->
            case quod_prolog:open_cursor(
                   Evidence, Goal, Principal, self(), CursorId) of
                {ok, Engine, CallRef} ->
                    EngineMRef = monitor(process, Engine),
                    CallerMRef = monitor(process, element(1, From)),
                    OwnerMRef = monitor_owner(Owner),
                    Cursor = #{engine => Engine, engine_mref => EngineMRef,
                               owner_mref => OwnerMRef,
                               call_ref => CallRef, worker => undefined,
                               checkpoint => none, owner => Owner,
                               principal => Principal, evidence => Evidence,
                               pending => {From, CallerMRef, open}},
                    {noreply, State#{cursors => Cursors#{Key => Cursor}}};
                {error, _} = Error ->
                    {reply, Error, State}
            end;
        {error, _} = Error ->
            {reply, Error, State}
    end;
handle_call({command, Owner, CursorId, Command}, From,
            State = #{cursors := Cursors}) ->
    Key = {Owner, CursorId},
    case maps:find(Key, Cursors) of
        {ok, #{pending := none, worker := Worker,
               call_ref := CallRef} = Cursor}
          when is_pid(Worker) ->
            CommandRef = make_ref(),
            CallerMRef = monitor(process, element(1, From)),
            Worker ! {quod_cursor_command, self(), CallRef, CursorId,
                      CommandRef, Command},
            Cursor1 = Cursor#{pending =>
                                {From, CallerMRef,
                                 {CommandRef, Command}}},
            {noreply, State#{cursors => Cursors#{Key => Cursor1}}};
        {ok, #{pending := none}} ->
            {reply, {error, not_ready}, State};
        {ok, _Busy} ->
            {reply, {error, busy}, State};
        error ->
            {reply, {error, not_found}, State}
    end;
handle_call({command_forwarded, GatewayKey, Link, CursorId, Command}, From,
            State = #{cursors := Cursors}) ->
    case find_forwarded_owner(GatewayKey, Link, CursorId, Cursors) of
        {ok, Owner} ->
            handle_call({command, Owner, CursorId, Command}, From, State);
        error ->
            {reply, {error, not_found}, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, bad_request}, State}.

handle_cast(_Message, State) -> {noreply, State}.

handle_info(
  {quod_cursor_solution, Worker, CallRef, CursorId, CommandRef,
   Bindings, Height}, State = #{cursors := Cursors}) ->
    case find_cursor_by_call_ref(CallRef, CursorId, Cursors) of
        {ok, Key,
         #{worker := Existing, evidence := Evidence,
           pending := Pending} = Cursor}
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
                     State#{cursors => Cursors#{Key => Cursor1}}};
                error ->
                    stop_unknown_cursor(Cursor),
                    {noreply, drop_cursor(Key, State)}
            end;
        _ ->
            {noreply, State}
    end;
handle_info({quod_proof_checkpoint, Engine, CallRef, Ref},
            State = #{cursors := Cursors}) ->
    case find_cursor_by_call(Engine, CallRef, Cursors) of
        {ok, Key, Cursor} ->
            {noreply,
             State#{cursors => Cursors#{Key =>
                                          Cursor#{checkpoint => Ref}}}};
        error ->
            {noreply, State}
    end;
handle_info({quod_proof_reply, Engine, CallRef, Reply},
            State = #{cursors := Cursors}) ->
    case find_cursor_by_call(Engine, CallRef, Cursors) of
        {ok, Key, Cursor} ->
            reply_pending(Cursor, Reply),
            {noreply, drop_cursor(Key, State)};
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
        {owner, CursorId, Cursor} ->
            owner_down(CursorId, Cursor, State);
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
    maps:foreach(fun(_Key, Cursor) -> stop_cursor_on_terminate(Cursor) end,
                 Cursors),
    ok.

cursor_solution_pending(open, {From, MRef, open}) ->
    {ok, From, MRef};
cursor_solution_pending(CommandRef,
                        {From, MRef, {CommandRef, next}}) ->
    {ok, From, MRef};
cursor_solution_pending(_CommandRef, _Pending) ->
    error.

find_cursor_by_call(Engine, CallRef, Cursors) ->
    maps:fold(
      fun(Key,
          #{engine := Engine0, call_ref := CallRef0} = Cursor, Acc) ->
              case Acc of
                  error when Engine0 =:= Engine, CallRef0 =:= CallRef ->
                      {ok, Key, Cursor};
                  _ -> Acc
              end
      end, error, Cursors).

find_cursor_by_call_ref(CallRef, CursorId, Cursors) ->
    maps:fold(
      fun(Key = {_Owner, CursorId0},
          #{call_ref := CallRef0} = Cursor, Acc) ->
              case Acc of
                  error when CursorId0 =:= CursorId,
                             CallRef0 =:= CallRef ->
                      {ok, Key, Cursor};
                  _ -> Acc
              end
      end, error, Cursors).

find_cursor_monitor(MRef, Cursors) ->
    maps:fold(
      fun(Key, Cursor, Acc) ->
              case Acc of
                  error ->
                      case Cursor of
                          #{engine_mref := MRef} ->
                              {engine, Key, Cursor};
                          #{owner_mref := MRef} ->
                              {owner, Key, Cursor};
                          #{pending := {_From, MRef, _Command}} ->
                              {caller, Key, Cursor};
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

drop_cursor(Key, State = #{cursors := Cursors}) ->
    case maps:take(Key, Cursors) of
        {Cursor, Cursors1} ->
            demonitor(maps:get(engine_mref, Cursor), [flush]),
            demonitor_optional(maps:get(owner_mref, Cursor, undefined)),
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

valid_owner({session, <<_:256>>, <<_:256>> = User}, User) -> true;
valid_owner({forwarder, <<_:256>>, Link, <<_:256>> = User}, User)
  when is_pid(Link) -> true;
valid_owner(_Owner, _User) -> false.

valid_owner_shape({session, <<_:256>>, <<_:256>>}) -> true;
valid_owner_shape({forwarder, <<_:256>>, Link, <<_:256>>})
  when is_pid(Link) -> true;
valid_owner_shape(_Owner) -> false.

monitor_owner({forwarder, <<_:256>>, Link, <<_:256>>}) ->
    monitor(process, Link);
monitor_owner({session, <<_:256>>, <<_:256>>}) ->
    undefined.

cursor_open_admission(Key, CursorId, Cursors) ->
    case maps:is_key(Key, Cursors) of
        true -> {error, busy};
        false ->
            case lists:any(
                   fun({_Owner, ExistingId}) -> ExistingId =:= CursorId end,
                   maps:keys(Cursors)) of
                true -> {error, not_found};
                false -> ok
            end
    end.

find_forwarded_owner(GatewayKey, Link, CursorId, Cursors) ->
    Matches =
        [Owner || {{Owner = {forwarder, Key, Link0, _User}, Id}, _Cursor}
                      <- maps:to_list(Cursors),
                  Key =:= GatewayKey, Link0 =:= Link, Id =:= CursorId],
    case Matches of [Owner] -> {ok, Owner}; _ -> error end.

owner_down(Key, Cursor, State) ->
    case maps:get(pending, Cursor) of
        {_From, _CallerMRef, {_CommandRef, accept}} ->
            reply_pending(
              Cursor,
              {error, {outcome_unknown,
                       operation_ref(maps:get(evidence, Cursor))}}),
            Cursors = maps:get(cursors, State),
            Cursor1 = Cursor#{owner_mref => undefined,
                              pending => detached_accept},
            {noreply, State#{cursors => Cursors#{Key => Cursor1}}};
        _ ->
            reply_pending(Cursor, {error, client_cursor_unavailable}),
            stop_unknown_cursor(Cursor),
            {noreply, drop_cursor(Key, State)}
    end.

operation_ref(#{operation_ref := Ref}) -> Ref;
operation_ref(#{request := #{target_namespace := Ns,
                             target_genesis_anchor := Anchor,
                             user_public_key := User,
                             operation_id := OperationId}}) ->
    {operation, Ns, Anchor, User, OperationId}.

demonitor_optional(undefined) -> ok;
demonitor_optional(MRef) -> demonitor(MRef, [flush]), ok.

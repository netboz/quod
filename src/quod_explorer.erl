-module(quod_explorer).
-moduledoc """
The **quod explorer** — an Etherscan-style web panel over one node: a live transaction
list fed over WebSocket (no polling), per-transaction detail, history paged off the
durable ledger, and a prove console that submits goals through the normal write path.

Serving layout (all under one cowboy listener):

| route | serves |
| ----- | ------ |
| `/`, `/assets/…` | the React bundle committed under `priv/explorer/` (source in `ui/`) |
| `/api/…` | REST reads + the prove/submit endpoint (`m:quod_explorer_http`) |
| `/ws` | the live event stream (`m:quod_explorer_ws`) |
| `/health` | plain liveness probe for the orchestrator |

**Disabled by default.** It is unauthenticated — and the prove endpoint **writes** —
so it must be turned on deliberately (`explorer.enabled`) and binds **loopback**
(`explorer.ip`, default `127.0.0.1`) unless an operator widens it on purpose. When
disabled, `start_link/0` returns `ignore`, so the supervisor starts no listener at
all — a bind failure can never crash node boot, co-located test nodes never collide
on the port, and no node exposes ledger content unless explicitly asked to.
""".
-behaviour(gen_server).

-export([start_link/0, cursor_open/2, cursor_command/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(LISTENER, quod_explorer_listener).

start_link() ->
    case application:get_env(quod, explorer_enabled, false) of
        true -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []);
        _    -> ignore   %% opt-in only — no process, no listener
    end.

-spec cursor_open(binary(), term()) -> term().
cursor_open(Ns, Goal) when is_binary(Ns) ->
    gen_server:call(?MODULE, {cursor_open, Ns, Goal}, infinity).

-spec cursor_command(<<_:256>>, next | accept | stop) -> term().
cursor_command(<<_:256>> = CursorId, Command)
  when Command =:= next; Command =:= accept; Command =:= stop ->
    gen_server:call(?MODULE, {cursor_command, CursorId, Command}, infinity).

init([]) ->
    Port = application:get_env(quod, explorer_port, 14569),
    Ip   = application:get_env(quod, explorer_ip, {127, 0, 0, 1}),
    Routes = [{'_', [
        {"/", cowboy_static, {priv_file, quod, "explorer/index.html"}},
        {"/favicon.png", cowboy_static, {priv_file, quod, "explorer/favicon.png"}},
        {"/assets/[...]", cowboy_static, {priv_dir, quod, "explorer/assets"}},
        {"/health", quod_explorer_http, health},
        {"/ws", quod_explorer_ws, []},
        {"/api/summary", quod_explorer_http, summary},
        {"/api/txs", quod_explorer_http, txs},
        {"/api/tx/:ns/:id", quod_explorer_http, tx},
        {"/api/block/:ns/:slot", quod_explorer_http, block},
        {"/api/prove", quod_explorer_http, prove},
        {"/api/proof-cursors", quod_explorer_http, cursor_open},
        {"/api/proof-cursors/:id/next", quod_explorer_http, cursor_next},
        {"/api/proof-cursors/:id/accept", quod_explorer_http, cursor_accept},
        {"/api/proof-cursors/:id", quod_explorer_http, cursor_stop}
    ]}],
    %% NEVER let the explorer take down the node: on bind error, log and run without a listener (it
    %% is optional; consensus must not depend on it). This is the opposite choice from the client
    %% endpoint (`m:quod_client`), which fails so its supervisor retries — nobody depends on the
    %% explorer being up, and everybody depends on the client being up.
    case quod_http_listener:start(
           #{name => ?LISTENER, ip => Ip, port => Port, routes => Routes}) of
        {ok, _} ->
            logger:info("quod: explorer on ~p:~p/", [Ip, Port]),
            {ok, #{cursors => #{}}};
        {error, Reason} ->
            logger:warning("quod: explorer disabled — listen on ~p:~p failed (~p)", [Ip, Port, Reason]),
            {ok, #{cursors => #{}}}
    end.

handle_call({cursor_open, Ns, Goal}, From,
            State = #{cursors := Cursors}) ->
    CursorId = new_cursor_id(Cursors),
    case quod_prolog:open_cursor(Ns, Goal, self(), CursorId) of
        {ok, Engine, CallRef} ->
            EngineMRef = monitor(process, Engine),
            CallerMRef = monitor(process, element(1, From)),
            Cursor = #{engine => Engine, engine_mref => EngineMRef,
                       call_ref => CallRef, worker => undefined,
                       checkpoint => none,
                       pending => {From, CallerMRef, open}},
            {noreply, State#{cursors => Cursors#{CursorId => Cursor}}};
        {error, _} = Error ->
            {reply, Error, State}
    end;
handle_call({cursor_command, CursorId, Command}, From,
            State = #{cursors := Cursors}) ->
    case maps:find(CursorId, Cursors) of
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
            {noreply, State#{cursors => Cursors#{CursorId => Cursor1}}};
        {ok, #{pending := none}} ->
            {reply, {error, not_ready}, State};
        {ok, _Busy} ->
            {reply, {error, busy}, State};
        error ->
            {reply, {error, not_found}, State}
    end;
handle_call(_Request, _From, State) -> {reply, {error, bad_request}, State}.
handle_cast(_Message, State) -> {noreply, State}.
handle_info(
  {quod_cursor_solution, Worker, CallRef, CursorId, CommandRef,
   Bindings, Height}, State = #{cursors := Cursors}) ->
    case maps:find(CursorId, Cursors) of
        {ok, #{call_ref := CallRef, worker := Existing,
               pending := Pending} = Cursor}
          when Existing =:= undefined; Existing =:= Worker ->
            case cursor_solution_pending(CommandRef, Pending) of
                {ok, From, CallerMRef} ->
                    demonitor(CallerMRef, [flush]),
                    gen_server:reply(
                      From, {solution, CursorId, Bindings, Height}),
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
                    %% Accept may already have crossed the durable submission
                    %% boundary.  Losing the HTTP observer must not kill that
                    %% exact worker; let it settle and clean the cursor on its
                    %% normal proof reply or deadline.
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
    quod_http_listener:stop(?LISTENER).

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

reply_pending(#{pending := {From, CallerMRef, _Command}}, Reply) ->
    demonitor(CallerMRef, [flush]),
    gen_server:reply(From, Reply);
reply_pending(_Cursor, _Reply) ->
    ok.

detach_accept_observer(
  MRef, Cursor = #{pending := {_From, MRef, {_CommandRef, accept}}}) ->
    {ok, Cursor#{pending => detached_accept}};
detach_accept_observer(_MRef, _Cursor) ->
    error.

%% The Explorer supervisor may restart after Accept has crossed the durable
%% submission boundary.  As with a disconnected HTTP observer, dropping the
%% UI owner must not kill that exact commit worker; its engine-owned deadline
%% and normal proof lifecycle still bound it.
stop_cursor_on_terminate(#{pending := detached_accept}) ->
    ok;
stop_cursor_on_terminate(Cursor) ->
    stop_unknown_cursor(Cursor).

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

stop_unknown_cursor(
  #{worker := Worker}) when is_pid(Worker) ->
    exit(Worker, kill),
    ok;
stop_unknown_cursor(#{engine := Engine, call_ref := CallRef}) ->
    quod_prolog:cancel_cursor(Engine, self(), CallRef).

-module(quod_namespace_manager).
-moduledoc """
Desired-state owner for per-ontology content and Brahms children.

The two child supervisors are intentionally replaceable. Their dynamic child
specs disappear if either supervisor process is restarted, so this manager
keeps the node's desired namespace configurations separately and reconciles
them after an exact supervisor `DOWN`. Desired state is serialized here and
mirrored in the application environment so a manager restart does not forget
it. A full application start clears that mirror before the supervision tree is
created; only namespaces requested during the current application lifetime are
recovered.
""".

-behaviour(gen_server).

-export([start_link/0,
         start_content/2, stop_content/1,
         start_brahms/2, stop_brahms/1]).
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2]).

-define(KEY, {namespace_manager, node}).
-define(DESIRED_ENV, namespace_desired).
-define(RETRY_MS, 250).

-record(s, {
    desired = #{content => #{}, brahms => #{}},
    ns_sup = undefined,
    ns_monitor = undefined,
    brahms_sup = undefined,
    brahms_monitor = undefined,
    retry = undefined
}).

start_link() ->
    gen_server:start_link(quod_reg:via(?KEY), ?MODULE, [], []).

start_content(Ns, Config) ->
    start_child(content, Ns, Config).

stop_content(Ns) ->
    stop_child(content, Ns).

start_brahms(Ns, Config) ->
    start_child(brahms, Ns, Config).

stop_brahms(Ns) ->
    stop_child(brahms, Ns).

start_child(Kind, Ns, Config)
  when is_binary(Ns), is_map(Config) ->
    gen_server:call(
      quod_reg:via(?KEY), {start, Kind, Ns, Config}, 15000);
start_child(_Kind, _Ns, _Config) ->
    {error, bad_config}.

stop_child(Kind, Ns) when is_binary(Ns) ->
    gen_server:call(
      quod_reg:via(?KEY), {stop, Kind, Ns}, 15000);
stop_child(_Kind, _Ns) ->
    {error, not_found}.

init([]) ->
    Desired = desired_env(),
    self() ! reconcile,
    {ok, #s{desired = Desired}}.

handle_call(
  {start, Kind, Ns, Config}, _From,
  S = #s{desired = Desired})
  when Kind =:= content; Kind =:= brahms ->
    KindDesired = maps:get(Kind, Desired),
    case maps:get(Ns, KindDesired, undefined) of
        undefined ->
            Desired1 =
                Desired#{Kind => KindDesired#{Ns => Config}},
            persist_desired(Desired1),
            S0 = S#s{desired = Desired1},
            {Result, S1} = ensure_one(Kind, Ns, Config, S0),
            maybe_notify_directory(Kind, Result),
            {reply, Result, schedule_reconcile_if_error(Result, S1)};
        Config ->
            {Result, S1} = ensure_one(Kind, Ns, Config, S),
            maybe_notify_directory(Kind, Result),
            {reply, Result, schedule_reconcile_if_error(Result, S1)};
        _OtherConfig ->
            {reply, {error, {already_configured, Ns}}, S}
    end;
handle_call(
  {stop, Kind, Ns}, _From,
  S = #s{desired = Desired})
  when Kind =:= content; Kind =:= brahms ->
    KindDesired = maps:get(Kind, Desired),
    case maps:is_key(Ns, KindDesired) of
        false ->
            {reply, {error, not_found}, S};
        true ->
            Desired1 =
                Desired#{Kind => maps:remove(Ns, KindDesired)},
            persist_desired(Desired1),
            Result = stop_one(Kind, Ns),
            maybe_notify_directory(Kind, Result),
            Normalized = normalize_stop(Result),
            S1 = S#s{desired = Desired1},
            {reply, Normalized,
             schedule_reconcile_if_stop_error(Normalized, S1)}
    end;
handle_call(_Request, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Message, S) ->
    {noreply, S}.

handle_info(reconcile, S) ->
    S0 = S#s{retry = undefined},
    {Changed, Complete, S1} = reconcile_all(bind_supervisors(S0)),
    case Changed of
        true -> quod_directory_control:namespace_changed();
        false -> ok
    end,
    {noreply,
     case Complete of
         true -> S1;
         false -> schedule_reconcile(S1)
     end};
handle_info(
  {'DOWN', Ref, process, Pid, _Reason},
  S = #s{ns_monitor = Ref, ns_sup = Pid}) ->
    {noreply,
     schedule_reconcile(
       S#s{ns_sup = undefined, ns_monitor = undefined})};
handle_info(
  {'DOWN', Ref, process, Pid, _Reason},
  S = #s{brahms_monitor = Ref, brahms_sup = Pid}) ->
    {noreply,
     schedule_reconcile(
       S#s{brahms_sup = undefined,
           brahms_monitor = undefined})};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, S) ->
    cancel_retry(S#s.retry),
    demonitor_if(S#s.ns_monitor),
    demonitor_if(S#s.brahms_monitor),
    ok.

desired_env() ->
    case application:get_env(quod, ?DESIRED_ENV, undefined) of
        #{content := Content, brahms := Brahms} = Desired
          when is_map(Content), is_map(Brahms) ->
            Desired;
        _ ->
            #{content => #{}, brahms => #{}}
    end.

persist_desired(Desired) ->
    application:set_env(quod, ?DESIRED_ENV, Desired).

bind_supervisors(S) ->
    {NsSup, NsMonitor} =
        bind_supervisor(
          quod_reg:where({quod_ns_sup, node}),
          S#s.ns_sup, S#s.ns_monitor),
    {BrahmsSup, BrahmsMonitor} =
        bind_supervisor(
          quod_reg:where({quod_brahms_sup, node}),
          S#s.brahms_sup, S#s.brahms_monitor),
    S#s{ns_sup = NsSup,
        ns_monitor = NsMonitor,
        brahms_sup = BrahmsSup,
        brahms_monitor = BrahmsMonitor}.

bind_supervisor(Pid, Pid, Ref)
  when is_pid(Pid), is_reference(Ref) ->
    {Pid, Ref};
bind_supervisor(Pid, _OldPid, OldRef)
  when is_pid(Pid) ->
    demonitor_if(OldRef),
    {Pid, monitor(process, Pid)};
bind_supervisor(_Pid, OldPid, OldRef) ->
    {OldPid, OldRef}.

reconcile_all(S = #s{desired = Desired}) ->
    {ContentChanged, ContentComplete, S1} =
        reconcile_kind(
          content, maps:get(content, Desired), S),
    {_BrahmsChanged, BrahmsComplete, S2} =
        reconcile_kind(
          brahms, maps:get(brahms, Desired), S1),
    {ContentChanged, ContentComplete andalso BrahmsComplete, S2}.

reconcile_kind(Kind, Desired, S) ->
    case supervisor_available(Kind, S) of
        false ->
            {false, false, S};
        true ->
            Running = running_children(Kind),
            Undesired =
                [Ns || Ns <- maps:keys(Running),
                       not maps:is_key(Ns, Desired)],
            StopResults =
                [stop_one(Kind, Ns) || Ns <- Undesired],
            Missing =
                [{Ns, Config}
                 || {Ns, Config} <- maps:to_list(Desired),
                    not maps:is_key(Ns, Running)],
            Results =
                [start_one(Kind, Ns, Config)
                 || {Ns, Config} <- Missing],
            Changed = lists:any(fun stop_succeeded/1, StopResults)
                orelse lists:any(fun start_succeeded/1, Results),
            Complete = lists:all(fun stop_succeeded/1, StopResults)
                andalso lists:all(fun start_succeeded/1, Results),
            {Changed, Complete, S}
    end.

supervisor_available(content, #s{ns_sup = Pid}) ->
    is_pid(Pid) andalso is_process_alive(Pid);
supervisor_available(brahms, #s{brahms_sup = Pid}) ->
    is_pid(Pid) andalso is_process_alive(Pid).

running_children(content) ->
    quod_ns_sup:children();
running_children(brahms) ->
    quod_brahms_sup:children().

ensure_one(Kind, Ns, Config, S) ->
    case running_pid(Kind, Ns) of
        Pid when is_pid(Pid) ->
            {{ok, Pid}, S};
        undefined ->
            {start_one(Kind, Ns, Config), S}
    end.

running_pid(content, Ns) ->
    quod_reg:where({quod_ns, Ns});
running_pid(brahms, Ns) ->
    quod_reg:where({quod_brahms, Ns}).

start_one(content, Ns, Config) ->
    try quod_ns_sup:start_child(Ns, Config)
    catch exit:_ -> {error, supervisor_unavailable}
    end;
start_one(brahms, Ns, Config) ->
    try quod_brahms_sup:start_child(Ns, Config)
    catch exit:_ -> {error, supervisor_unavailable}
    end.

stop_one(content, Ns) ->
    try quod_ns_sup:stop_child(Ns)
    catch exit:_ -> {error, supervisor_unavailable}
    end;
stop_one(brahms, Ns) ->
    try quod_brahms_sup:stop_child(Ns)
    catch exit:_ -> {error, supervisor_unavailable}
    end.

start_succeeded({ok, Pid}) when is_pid(Pid) -> true;
start_succeeded({ok, Pid, _Info}) when is_pid(Pid) -> true;
start_succeeded({error, {already_started, Pid}})
  when is_pid(Pid) -> true;
start_succeeded(_) -> false.

stop_succeeded(ok) -> true;
stop_succeeded({error, not_found}) -> true;
stop_succeeded(_) -> false.

normalize_stop(ok) -> ok;
normalize_stop({error, not_found}) -> ok;
normalize_stop(Other) -> Other.

maybe_notify_directory(content, Result) ->
    case start_succeeded(Result) orelse Result =:= ok of
        true -> quod_directory_control:namespace_changed();
        false -> ok
    end;
maybe_notify_directory(brahms, _Result) ->
    ok.

schedule_reconcile_if_error(Result, S) ->
    case start_succeeded(Result) of
        true -> S;
        false -> schedule_reconcile(S)
    end.

schedule_reconcile_if_stop_error(Result, S) ->
    case Result of
        ok -> S;
        _ -> schedule_reconcile(S)
    end.

schedule_reconcile(S = #s{retry = Ref})
  when is_reference(Ref) ->
    S;
schedule_reconcile(S) ->
    Ref = erlang:send_after(?RETRY_MS, self(), reconcile),
    S#s{retry = Ref}.

cancel_retry(Ref) when is_reference(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok;
cancel_retry(_) ->
    ok.

demonitor_if(Ref) when is_reference(Ref) ->
    demonitor(Ref, [flush]),
    ok;
demonitor_if(_) ->
    ok.

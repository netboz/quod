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

This process is also the sole publisher of the explorer's namespace-to-ledger
projection. A caller may die or time out after a start request is accepted, so
post-start genesis validation and publication must not live in that caller.
""".

-behaviour(gen_server).

-export([start_link/0,
         start_content/2, start_new_content/2, stop_content/1,
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

%% Runtime creation is an admission, not an idempotent ensure. The manager
%% starts and validates the newcomer before recording its desired state, so a
%% failed admission cannot remove or replace an older ontology with the name.
start_new_content(Ns, Config) ->
    start_new_child(content, Ns, Config).

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

start_new_child(Kind, Ns, Config)
  when Kind =:= content, is_binary(Ns), is_map(Config) ->
    gen_server:call(
      quod_reg:via(?KEY), {start_new, Kind, Ns, Config}, 15000);
start_new_child(_Kind, _Ns, _Config) ->
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
  {start_new, content, Ns, Config}, _From,
  S = #s{desired = Desired}) ->
    Content = maps:get(content, Desired),
    case {maps:is_key(Ns, Content), running_pid(content, Ns)} of
        {true, _Pid} ->
            {reply, {error, {already_configured, Ns}}, S};
        {false, Pid} when is_pid(Pid) ->
            %% A failed earlier stop can leave an undesired child alive. Never
            %% attach a new config to a process that was started under another.
            {reply, {error, {already_configured, Ns}}, S};
        {false, undefined} ->
            Result = start_one(content, Ns, Config),
            case Result of
                {ok, Pid} when is_pid(Pid) ->
                    complete_new_content(Ns, Config, S);
                {ok, Pid, _Info} when is_pid(Pid) ->
                    complete_new_content(Ns, Config, S);
                {error, {already_started, _Pid}} ->
                    {reply, {error, {already_configured, Ns}}, S};
                {error, already_present} ->
                    {reply, {error, {already_configured, Ns}}, S};
                {error, {already_present, _Child}} ->
                    {reply, {error, {already_configured, Ns}}, S};
                _ ->
                    {reply, Result, S}
            end
    end;
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
            {RawResult, S1} = ensure_one(Kind, Ns, Config, S0),
            Result = complete_started_child(
                       Kind, Ns, Config, RawResult),
            maybe_notify_directory(Kind, Result),
            {reply, Result, schedule_reconcile_if_error(Result, S1)};
        Config ->
            {RawResult, S1} = ensure_one(Kind, Ns, Config, S),
            Result = complete_started_child(
                       Kind, Ns, Config, RawResult),
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

complete_new_content(Ns, Config,
                     S = #s{desired = Desired}) ->
    case started_genesis(Ns, Config) of
        {ok, GenesisHash} ->
            Content = maps:get(content, Desired),
            Desired1 = Desired#{content => Content#{Ns => Config}},
            persist_desired(Desired1),
            publish_data_dir(Ns, Config),
            {reply, {ok, GenesisHash}, S#s{desired = Desired1}};
        {error, Reason} ->
            stop_rejected_new_content(Ns, S, Reason)
    end.

started_genesis(Ns, Config) ->
    case quod_simplex:genesis_hash(Ns) of
        Hash when is_binary(Hash), byte_size(Hash) =:= 32 ->
            case maps:get(mode, Config, undefined) of
                join ->
                    case maps:get(genesis_hash, Config, undefined) of
                        Hash -> {ok, Hash};
                        _ -> {error, genesis_mismatch}
                    end;
                create ->
                    {ok, Hash};
                _ ->
                    {error, genesis_unavailable}
            end;
        _ ->
            {error, genesis_unavailable}
    end.

stop_rejected_new_content(Ns, S, Reason) ->
    %% No desired entry exists yet, so a manager crash cannot resurrect this
    %% rejected admission. The replacement manager will also stop any child
    %% left behind by a failed cleanup.
    StopResult = normalize_stop(stop_one(content, Ns)),
    {reply, {error, Reason},
     schedule_reconcile_if_stop_error(StopResult, S)}.

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
                [{Ns, start_one(Kind, Ns, Config)}
                 || {Ns, Config} <- Missing],
            {Ready, Validated} = complete_running_children(Kind, Desired),
            Changed = lists:any(fun stop_succeeded/1, StopResults)
                orelse lists:any(
                         fun({Ns, Result}) ->
                             completed_start_succeeded(
                               Kind, Ns, Result, Validated)
                         end, Results),
            Complete = lists:all(fun stop_succeeded/1, StopResults)
                andalso lists:all(
                          fun({_Ns, Result}) ->
                              start_succeeded(Result)
                          end, Results)
                andalso Ready,
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

complete_started_child(content, Ns, Config, Result) ->
    case start_succeeded(Result) of
        true ->
            case validate_and_publish_content(Ns, Config) of
                ok -> Result;
                {error, _} = Error -> Error
            end;
        false ->
            Result
    end;
complete_started_child(brahms, _Ns, _Config, Result) ->
    Result.

complete_running_children(brahms, _Desired) ->
    {true, #{}};
complete_running_children(content, Desired) ->
    Dirs0 = application:get_env(quod, content_data_dirs, #{}),
    {Complete, Dirs, Validated} =
        maps:fold(
          fun(Ns, Config, {Complete0, DirsAcc, ValidAcc}) ->
              case running_pid(content, Ns) of
                  Pid when is_pid(Pid) ->
                      case started_genesis(Ns, Config) of
                          {ok, _GenesisHash} ->
                              Dir = quod_ledger_store:ledger_dir(Config),
                              {Complete0, DirsAcc#{Ns => Dir},
                               ValidAcc#{Ns => true}};
                          {error, _} ->
                              {false, DirsAcc, ValidAcc}
                      end;
                  undefined ->
                      {false, DirsAcc, ValidAcc}
              end
          end, {true, Dirs0, #{}}, Desired),
    case Dirs =:= Dirs0 of
        true -> ok;
        false -> application:set_env(quod, content_data_dirs, Dirs)
    end,
    {Complete, Validated}.

completed_start_succeeded(content, Ns, Result, Validated) ->
    start_succeeded(Result) andalso maps:is_key(Ns, Validated);
completed_start_succeeded(brahms, _Ns, Result, _Validated) ->
    start_succeeded(Result).

validate_and_publish_content(Ns, Config) ->
    case started_genesis(Ns, Config) of
        {ok, _GenesisHash} ->
            publish_data_dir(Ns, Config),
            ok;
        {error, _} = Error ->
            Error
    end.

%% The manager serializes every writer of this projection. Stopped ontologies
%% deliberately remain addressable by the explorer, so entries are not removed
%% when hosting intent is removed.
publish_data_dir(Ns, Config) ->
    Dir = quod_ledger_store:ledger_dir(Config),
    Dirs = application:get_env(quod, content_data_dirs, #{}),
    application:set_env(quod, content_data_dirs, Dirs#{Ns => Dir}).

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

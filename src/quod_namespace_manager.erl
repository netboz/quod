-module(quod_namespace_manager).
-moduledoc """
Desired-state owner for per-ontology content and Brahms children.

The two child supervisors are intentionally replaceable. Their dynamic child
specs disappear if either supervisor process is restarted, so this manager
keeps the node's desired namespace configurations separately and reconciles
them after an exact supervisor `DOWN`. Desired state is serialized here and
mirrored in the application environment. Dynamically created and joined
content is also checkpointed by this same owner, so a full application restart
restores deliberate hosting without scanning directories or starting unrelated
ledger data.

After the statically configured root becomes ready, this same owner reads its
committed `system_ontology/2` catalogue. Exact anchored system joins are
merged into the existing desired-state projection; there is no second system
ontology supervisor or restart mechanism. Local dynamic stop requests remove
only local intent and cannot override static or committed-root ownership.

This process is also the sole publisher of the explorer's namespace-to-ledger
projection. A caller may die or time out after a start request is accepted, so
post-start genesis validation and publication must not live in that caller.
Every potentially slow supervisor start or stop—direct lifecycle or desired
state reconciliation—runs through one monitored mutation lane. The manager
itself only owns state, ordering, persistence, and replies.
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
-define(RETRY_MAX_MS, 60000).
-define(SYSTEM_RETRY_MIN_MS, 1000).
-define(SYSTEM_RETRY_MAX_MS, 60000).
-define(SYSTEM_QUERY_TIMEOUT_MS, 15000).
-define(ROOT_NS, <<"quod:root">>).

-record(s, {
    desired = #{content => #{}, brahms => #{}},
    ns_sup = undefined,
    ns_monitor = undefined,
    brahms_sup = undefined,
    brahms_monitor = undefined,
    retry = undefined,
    mutation_worker = undefined,
    reconcile_dirty = false,
    reconcile_incomplete = false,
    pending_calls = undefined,
    durable_content = #{},
    static_content = #{},
    ephemeral_content = #{},
    system_content = #{},
    system_blocked = #{},
    system_query = undefined,
    system_retry = undefined,
    system_retry_ms = ?SYSTEM_RETRY_MIN_MS,
    system_dirty = false,
    reconcile_retry_ms = ?RETRY_MS
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
    Durable0 = quod_namespace_desired_store:load(),
    Desired0 = desired_env(),
    Static = application:get_env(quod, namespace_static_content, #{}),
    %% Static operator configuration takes ownership of a same-name ontology.
    %% Remove the superseded dynamic row instead of leaving latent intent that
    %% could unexpectedly reappear if the static block is removed later.
    Durable = maps:without(maps:keys(Static), Durable0),
    ok = persist_durable_if_changed(Durable0, Durable),
    Mirrored = maps:get(content, Desired0),
    System = maps:filter(
               fun(_Ns, Config) ->
                   is_map(Config)
                       andalso maps:get(system_ontology, Config, false) =:= true
               end, Mirrored),
    Ephemeral = maps:without(
                  maps:keys(maps:merge(maps:merge(Durable, Static), System)),
                  Mirrored),
    Content = content_projection(Durable, Ephemeral, System, Static),
    Desired = Desired0#{content => Content},
    persist_desired(Desired),
    true = quod_reg:subscribe({runtime, ?ROOT_NS}),
    self() ! reconcile,
    self() ! refresh_system_catalogue,
    {ok, #s{desired = Desired, durable_content = Durable,
            static_content = Static, ephemeral_content = Ephemeral,
            system_content = System, pending_calls = queue:new()}}.

handle_call(Request, From, S) ->
    S0 = reset_reconcile_backoff(S),
    {noreply, continue_work(enqueue_call(Request, From, S0))}.

begin_request(
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
            {work, {start_new, Ns, Config}, S}
    end;
begin_request(
  {start, Kind, Ns, Config}, _From,
  S = #s{desired = Desired})
  when Kind =:= content; Kind =:= brahms ->
    KindDesired = maps:get(Kind, Desired),
    case maps:get(Ns, KindDesired, undefined) of
        undefined ->
            SAdded = add_desired(Kind, Ns, Config, S),
            Desired1 = SAdded#s.desired,
            persist_desired(Desired1),
            {work, {ensure, Kind, Ns, Config}, SAdded};
        Config ->
            {work, {ensure, Kind, Ns, Config}, S};
        _OtherConfig ->
            {reply, {error, {already_configured, Ns}}, S}
    end;
begin_request(
  {stop, Kind, Ns}, _From,
  S = #s{desired = Desired, durable_content = Durable})
  when Kind =:= content; Kind =:= brahms ->
    KindDesired = maps:get(Kind, Desired),
    case maps:is_key(Ns, KindDesired) of
        false ->
            {reply, {error, not_found}, S};
        true ->
            Durable1 = remove_durable(Kind, Ns, Durable),
            ok = persist_durable_if_changed(Durable, Durable1),
            SRemoved = remove_desired(Kind, Ns, S#s{
                                                    durable_content = Durable1}),
            Desired1 = SRemoved#s.desired,
            persist_desired(Desired1),
            %% A local stop removes only local dynamic intent.  Static operator
            %% configuration and the committed root catalogue are independent,
            %% stronger desired-state owners; if either still names the
            %% ontology, stopping its child would only create a pointless
            %% stop/restart cycle and a window in which the system contract is
            %% false.
            Retained = maps:is_key(Ns, maps:get(Kind, Desired1)),
            case Retained of
                true -> {reply, ok, SRemoved};
                false -> {work, {stop, Kind, Ns}, SRemoved}
            end
    end;
begin_request(_Request, _From, S) ->
    {reply, {error, unknown_call}, S}.

run_request_work({start_new, Ns, Config}) ->
    case start_one(content, Ns, Config) of
        Result when is_tuple(Result) ->
            case start_succeeded(Result) of
                true ->
                    case started_genesis(Ns, Config) of
                        {ok, GenesisHash} ->
                            {start_new, Ns, Config,
                             {accepted, GenesisHash}};
                        {error, Reason} ->
                            Cleanup = normalize_stop(stop_one(content, Ns)),
                            {start_new, Ns, Config,
                             {rejected, Reason, Cleanup}}
                    end;
                false ->
                    {start_new, Ns, Config, {start_result, Result}}
            end
    end;
run_request_work({ensure, Kind, Ns, Config}) ->
    RawResult = ensure_one(Kind, Ns, Config),
    Validation =
        case {Kind, start_succeeded(RawResult)} of
            {content, true} -> started_genesis(Ns, Config);
            {brahms, true} -> ok;
            {_, false} -> skipped
        end,
    {ensure, Kind, Ns, Config, RawResult, Validation};
run_request_work({stop, Kind, Ns}) ->
    {stop, Kind, normalize_stop(stop_one(Kind, Ns))}.

finish_request(
  {start_new, Ns, Config, {accepted, GenesisHash}},
  S = #s{desired = Desired, durable_content = Durable}) ->
    DurableConfig =
        quod_namespace_desired_store:resume_config(Config, GenesisHash),
    Durable1 = Durable#{Ns => DurableConfig},
    ok = quod_namespace_desired_store:store(Durable1),
    Content = content_projection(
                Durable1, S#s.ephemeral_content,
                S#s.system_content, S#s.static_content),
    Desired1 = Desired#{content => Content},
    persist_desired(Desired1),
    publish_storage(Ns, Config),
    notify_content_changed(),
    {{ok, GenesisHash},
     S#s{desired = Desired1, durable_content = Durable1}};
finish_request(
  {start_new, _Ns, _Config, {rejected, Reason, Cleanup}}, S) ->
    {{error, Reason}, schedule_reconcile_if_stop_error(Cleanup, S)};
finish_request(
  {start_new, Ns, _Config, {start_result, Result}}, S) ->
    Reply = normalize_new_start_result(Ns, Result),
    {Reply, S};
finish_request(
  {ensure, Kind, Ns, Config, RawResult, Validation}, S) ->
    Result = complete_ensured_child(
               Kind, Ns, Config, RawResult, Validation),
    maybe_notify_directory(Kind, Result),
    {Result, schedule_reconcile_if_error(Result, S)};
finish_request({stop, Kind, Result}, S) ->
    maybe_notify_directory(Kind, Result),
    {Result, schedule_reconcile_if_stop_error(Result, S)}.

normalize_new_start_result(Ns, {error, {already_started, _Pid}}) ->
    {error, {already_configured, Ns}};
normalize_new_start_result(Ns, {error, already_present}) ->
    {error, {already_configured, Ns}};
normalize_new_start_result(Ns, {error, {already_present, _Child}}) ->
    {error, {already_configured, Ns}};
normalize_new_start_result(_Ns, Result) -> Result.

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

handle_cast(_Message, S) ->
    {noreply, S}.

handle_info(reconcile, S = #s{mutation_worker = undefined}) ->
    S0 = S#s{retry = undefined},
    case queue:is_empty(S0#s.pending_calls) of
        true -> {noreply, start_reconcile(S0)};
        false -> {noreply, S0#s{reconcile_dirty = true}}
    end;
handle_info(reconcile, S) ->
    {noreply, S#s{retry = undefined, reconcile_dirty = true}};
handle_info(
  {mutation_result, Token,
   {reconcile, Changed, Complete, StorageAdds}},
  S = #s{mutation_worker = {_Pid, MRef, Token, reconcile}}) ->
    demonitor(MRef, [flush]),
    publish_reconcile_storage(StorageAdds),
    case Changed of
        true -> notify_content_changed();
        false -> ok
    end,
    S0 = S#s{mutation_worker = undefined,
             reconcile_incomplete = not Complete},
    S1 = case Complete of
             true -> reset_reconcile_backoff(S0);
             false -> S0
         end,
    {noreply, continue_work(S1)};
handle_info(
  {mutation_result, Token, {call, From, Result}},
  S = #s{mutation_worker = {_Pid, MRef, Token, {call, From}}}) ->
    demonitor(MRef, [flush]),
    {Reply, S0} = finish_request(Result, S#s{mutation_worker = undefined}),
    gen_server:reply(From, Reply),
    {noreply, continue_work(S0)};
handle_info(
  {'DOWN', MRef, process, Pid, Reason},
  S = #s{mutation_worker = {Pid, MRef, _Token, Kind}}) ->
    logger:error("quod: namespace mutation worker failed: ~p", [Reason]),
    reply_failed_mutation(Kind),
    %% A failed worker must not strand either its caller or lifecycle callers
    %% queued behind it. Drain the queue, then reconcile the uncertain result.
    {noreply,
     continue_work(
       S#s{mutation_worker = undefined,
           reconcile_incomplete = true})};
handle_info(process_pending_call,
            S = #s{mutation_worker = undefined, pending_calls = Queue0}) ->
    case queue:out(Queue0) of
        {empty, _} ->
            {noreply, finish_reconcile_cycle(S)};
        {{value, {Request, From}}, Queue1} ->
            case begin_request(
                   Request, From, S#s{pending_calls = Queue1}) of
                {reply, Reply, S1} ->
                    gen_server:reply(From, Reply),
                    {noreply, continue_work(S1)};
                {work, Work, S1} ->
                    {noreply, start_call_worker(Work, From, S1)}
            end
    end;
handle_info(refresh_system_catalogue, S0) ->
    S = cancel_system_retry(S0),
    {noreply, start_system_query(S)};
handle_info({replay_ready, _Id, _Height}, S) ->
    {noreply, request_system_refresh(reset_system_backoff(S))};
handle_info({applied_live, Envelope}, S) ->
    case system_catalogue_changed(Envelope) of
        true ->
            {noreply, request_system_refresh(reset_system_backoff(S))};
        false -> {noreply, S}
    end;
handle_info(
  {system_catalogue_result, Token, Result},
  S = #s{system_query = {_Pid, MRef, Token, Timer}}) ->
    cancel_timer(Timer),
    demonitor(MRef, [flush]),
    S0 = S#s{system_query = undefined},
    {noreply, continue_system_refresh(finish_system_query(Result, S0))};
handle_info(
  {'DOWN', Ref, process, Pid, Reason},
  S = #s{system_query = {Pid, Ref, _Token, Timer}}) ->
    cancel_timer(Timer),
    logger:error(
      "quod: system-ontology catalogue worker failed: ~p", [Reason]),
    {noreply,
     schedule_system_retry(S#s{system_query = undefined})};
handle_info(
  {system_catalogue_timeout, Token},
  S = #s{system_query = {Pid, MRef, Token, _Timer}}) ->
    demonitor(MRef, [flush]),
    exit(Pid, kill),
    logger:error("quod: system-ontology catalogue query timed out"),
    {noreply,
     schedule_system_retry(S#s{system_query = undefined})};
handle_info(
  {'DOWN', Ref, process, Pid, _Reason},
  S = #s{ns_monitor = Ref, ns_sup = Pid}) ->
    {noreply,
     schedule_reconcile(
       reset_reconcile_backoff(
         S#s{ns_sup = undefined, ns_monitor = undefined}))};
handle_info(
  {'DOWN', Ref, process, Pid, _Reason},
  S = #s{brahms_monitor = Ref, brahms_sup = Pid}) ->
    {noreply,
     schedule_reconcile(
       reset_reconcile_backoff(
         S#s{brahms_sup = undefined,
             brahms_monitor = undefined}))};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, S) ->
    cancel_retry(S#s.retry),
    stop_mutation(S#s.mutation_worker),
    cancel_timer(S#s.system_retry),
    stop_system_query(S#s.system_query),
    demonitor_if(S#s.ns_monitor),
    demonitor_if(S#s.brahms_monitor),
    _ = catch quod_reg:unsubscribe({runtime, ?ROOT_NS}),
    ok.

%% Supervisor termination may legitimately wait for an ontology subtree to
%% finish.  Keep that wait out of the desired-state owner's mailbox: one
%% monitored worker executes the existing reconciliation path, while this
%% process continues accepting catalogue changes and records that another pass
%% is needed.  There is still exactly one reconciler and one desired-state
%% owner.
start_reconcile(S0) ->
    S = bind_supervisors(S0),
    Parent = self(),
    Token = make_ref(),
    {Pid, MRef} =
        spawn_monitor(
          fun() ->
              {Changed, Complete, StorageAdds} = reconcile_all(S),
              Parent !
                  {mutation_result, Token,
                   {reconcile, Changed, Complete, StorageAdds}}
          end),
    S#s{mutation_worker = {Pid, MRef, Token, reconcile},
        reconcile_dirty = false}.

enqueue_call(Request, From, S = #s{pending_calls = Queue}) ->
    S#s{pending_calls = queue:in({Request, From}, Queue)}.

continue_work(S = #s{mutation_worker = Worker}) when Worker =/= undefined -> S;
continue_work(S = #s{pending_calls = Queue}) ->
    case queue:is_empty(Queue) of
        false ->
            self() ! process_pending_call,
            S;
        true -> finish_reconcile_cycle(S)
    end.

finish_reconcile_cycle(S = #s{reconcile_dirty = true}) ->
    self() ! reconcile,
    S#s{reconcile_dirty = false, reconcile_incomplete = false};
finish_reconcile_cycle(S = #s{reconcile_incomplete = true}) ->
    schedule_reconcile(S#s{reconcile_incomplete = false});
finish_reconcile_cycle(S) -> reset_reconcile_backoff(S).

stop_mutation({Pid, MRef, _Token, _Kind}) ->
    demonitor(MRef, [flush]),
    exit(Pid, kill),
    ok;
stop_mutation(_) -> ok.

start_call_worker(Work, From, S) ->
    Parent = self(),
    Token = make_ref(),
    {Pid, MRef} =
        spawn_monitor(
          fun() ->
              Parent !
                  {mutation_result, Token,
                   {call, From, run_request_work(Work)}}
          end),
    S#s{mutation_worker = {Pid, MRef, Token, {call, From}}}.

reply_failed_mutation({call, From}) ->
    gen_server:reply(From, {error, outcome_unknown});
reply_failed_mutation(reconcile) -> ok.

request_system_refresh(S = #s{system_query = undefined}) ->
    self() ! refresh_system_catalogue,
    S;
request_system_refresh(S) ->
    S#s{system_dirty = true}.

start_system_query(S = #s{system_query = undefined}) ->
    Parent = self(),
    Token = make_ref(),
    {Pid, MRef} =
        spawn_monitor(
          fun() ->
              Result =
                  case quod_system_ontology:catalog() of
                      {ok, Height, Descriptors, Rejected} ->
                          case quod_system_ontology:materialize(
                                 Descriptors, S#s.system_content) of
                              {ok, Configs, Pending, Blocked} ->
                                  {ok, Height, Descriptors, Rejected,
                                   Configs, Pending, Blocked};
                              {error, _} = Error -> Error
                          end;
                      {error, _} = Error -> Error
                  end,
              Parent ! {system_catalogue_result, Token, Result}
          end),
    Timer = erlang:send_after(
              ?SYSTEM_QUERY_TIMEOUT_MS, self(),
              {system_catalogue_timeout, Token}),
    S#s{system_query = {Pid, MRef, Token, Timer},
        system_dirty = false};
start_system_query(S) ->
    S#s{system_dirty = true}.

finish_system_query(
  {ok, _Height, Descriptors, Rejected, Configs, Pending, Blocked}, S0) ->
    Retained = retain_pending_systems(
                 Pending, Descriptors, S0#s.system_content, Configs),
    System = retain_rejected_systems(
               Rejected, S0#s.system_content, Retained),
    Reported = reported_system_failures(Rejected, Blocked),
    log_blocked_systems(Reported, S0#s.system_blocked),
    S1 = install_system_content(
           System, S0#s{system_blocked = Reported}),
    case Pending of
        [] -> reset_system_backoff(S1);
        _ -> schedule_system_retry(S1)
    end;
%% Root itself is started by static bootstrap configuration.  Its replay-ready
%% event is the retry signal; polling a root which does not exist yet would only
%% produce log noise.  A malformed committed catalogue also waits for its next
%% root change rather than re-reading the same bad state in a tight loop.
finish_system_query({error, no_such_namespace}, S) -> S;
finish_system_query({error, root_not_ready}, S) -> S;
finish_system_query({error, {ontology_rebuilding, ?ROOT_NS}}, S) -> S;
finish_system_query({error, malformed_system_catalogue}, S) ->
    log_invalid_system_catalogue(malformed_system_catalogue, S);
finish_system_query({error, Reason}, S) ->
    logger:error(
      "quod: system-ontology catalogue unavailable or invalid: ~p",
      [Reason]),
    schedule_system_retry(S).

log_invalid_system_catalogue(Reason, S) ->
    logger:error(
      "quod: invalid committed system-ontology catalogue: ~p", [Reason]),
    S.

continue_system_refresh(S = #s{system_dirty = true}) ->
    request_system_refresh(S#s{system_dirty = false});
continue_system_refresh(S) -> S.

%% Root may carry unrelated policy and directory traffic. Re-reading and
%% re-materializing the whole system catalogue after every root transaction
%% would turn that traffic into work proportional to the catalogue size.
%% Replay-ready remains the full resnapshot boundary; live refreshes narrow to
%% exact changed `system_ontology/2` heads.
system_catalogue_changed(Envelope) when is_map(Envelope) ->
    quod_diff:touches_functor(
      maps:get(diff, Envelope, []), {system_ontology, 2});
system_catalogue_changed(_) -> false.

retain_pending_systems(Pending, Descriptors, Old, Resolved) ->
    ByName = maps:from_list(
               [{maps:get(namespace, D), D} || D <- Descriptors]),
    Kept = lists:foldl(
             fun(Ns, Acc) ->
                 case {maps:get(Ns, Old, undefined),
                       maps:get(Ns, ByName, undefined)} of
                     {Config, Descriptor}
                       when is_map(Config), is_map(Descriptor) ->
                         case config_matches_descriptor(Config, Descriptor) of
                             true -> Acc#{Ns => Config};
                             false -> Acc
                         end;
                     _ -> Acc
                 end
             end, #{}, Pending),
    maps:merge(Kept, Resolved).

retain_rejected_systems(Rejected, Old, Resolved) ->
    maps:fold(
      fun(Ns, #{reason := conflicting_system_ontology,
                anchors := Anchors}, Acc)
            when is_binary(Ns), is_list(Anchors) ->
              case maps:get(Ns, Old, undefined) of
                  #{genesis_hash := Anchor,
                    system_ontology := true} = Config ->
                      case lists:member(Anchor, Anchors) of
                          true -> Acc#{Ns => Config};
                          false -> Acc
                      end;
                  _ -> Acc
              end;
         (_Id, _Problem, Acc) -> Acc
      end, Resolved, Rejected).

reported_system_failures(Rejected, Blocked) ->
    maps:merge(
      Rejected,
      maps:map(fun(_Ns, Reason) -> #{reason => Reason} end, Blocked)).

config_matches_descriptor(
  Config, #{anchor := Anchor}) ->
    maps:get(genesis_hash, Config, undefined) =:= Anchor
        andalso maps:get(system_ontology, Config, false) =:= true.

install_system_content(System,
                       S = #s{system_content = OldSystem})
  when System =:= OldSystem ->
    S;
install_system_content(System,
                       S = #s{desired = Desired}) ->
    NewContent = content_projection(
                   S#s.durable_content, S#s.ephemeral_content,
                   System, S#s.static_content),
    Desired1 = Desired#{content => NewContent},
    persist_desired(Desired1),
    self() ! reconcile,
    reset_reconcile_backoff(
      S#s{desired = Desired1, system_content = System}).

schedule_system_retry(S = #s{system_retry = Ref})
  when is_reference(Ref) -> S;
schedule_system_retry(S = #s{system_retry_ms = Delay}) ->
    Ref = erlang:send_after(
            Delay, self(), refresh_system_catalogue),
    S#s{system_retry = Ref,
        system_retry_ms = min(?SYSTEM_RETRY_MAX_MS, Delay * 2)}.

reset_system_backoff(S) ->
    S#s{system_retry_ms = ?SYSTEM_RETRY_MIN_MS}.

log_blocked_systems(Blocked, OldBlocked) ->
    maps:foreach(
      fun(Id, Problem) ->
          case maps:get(Id, OldBlocked, undefined) of
              Problem -> ok;
              _ ->
                  logger:error(
                    "quod: rejected or unavailable system ontology ~p: ~p",
                    [Id, Problem])
          end
      end, Blocked).

cancel_system_retry(S = #s{system_retry = Ref}) ->
    cancel_timer(Ref),
    S#s{system_retry = undefined}.

stop_system_query({Pid, MRef, _Token, Timer}) ->
    cancel_timer(Timer),
    demonitor(MRef, [flush]),
    exit(Pid, kill),
    ok;
stop_system_query(_) -> ok.

cancel_timer(Ref) when is_reference(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok;
cancel_timer(_) -> ok.

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

content_projection(Durable, Ephemeral, System, Static) ->
    %% Static configuration owns ordinary hosting over stale node-local intent.
    %% A committed root system descriptor is stronger still: local config must
    %% never replace its exact genesis anchor.
    maps:merge(
      maps:merge(maps:merge(Durable, Ephemeral), Static), System).

add_desired(content, Ns, Config,
            S = #s{desired = Desired, ephemeral_content = Ephemeral}) ->
    Ephemeral1 = Ephemeral#{Ns => Config},
    Content = content_projection(
                S#s.durable_content, Ephemeral1,
                S#s.system_content, S#s.static_content),
    S#s{desired = Desired#{content => Content},
        ephemeral_content = Ephemeral1};
add_desired(brahms, Ns, Config, S = #s{desired = Desired}) ->
    Brahms = maps:get(brahms, Desired),
    S#s{desired = Desired#{brahms => Brahms#{Ns => Config}}}.

remove_desired(content, Ns, S = #s{desired = Desired}) ->
    Durable = maps:remove(Ns, S#s.durable_content),
    Ephemeral = maps:remove(Ns, S#s.ephemeral_content),
    Content = content_projection(
                Durable, Ephemeral,
                S#s.system_content, S#s.static_content),
    S#s{desired = Desired#{content => Content},
        durable_content = Durable, ephemeral_content = Ephemeral};
remove_desired(brahms, Ns, S = #s{desired = Desired}) ->
    Brahms = maps:get(brahms, Desired),
    S#s{desired = Desired#{brahms => maps:remove(Ns, Brahms)}}.

remove_durable(content, Ns, Durable) -> maps:remove(Ns, Durable);
remove_durable(brahms, _Ns, Durable) -> Durable.

persist_durable_if_changed(Content, Content) -> ok;
persist_durable_if_changed(_Old, New) ->
    quod_namespace_desired_store:store(New).

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
    {ContentChanged, ContentComplete, StorageAdds} =
        reconcile_kind(
          content, maps:get(content, Desired), S),
    {_BrahmsChanged, BrahmsComplete, _NoStorage} =
        reconcile_kind(
          brahms, maps:get(brahms, Desired), S),
    {ContentChanged, ContentComplete andalso BrahmsComplete, StorageAdds}.

reconcile_kind(Kind, Desired, S) ->
    case supervisor_available(Kind, S) of
        false ->
            {false, false, #{}};
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
            {Ready, Validated, StorageAdds} =
                complete_running_children(Kind, Desired),
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
            {Changed, Complete, StorageAdds}
    end.

supervisor_available(content, #s{ns_sup = Pid}) ->
    is_pid(Pid) andalso is_process_alive(Pid);
supervisor_available(brahms, #s{brahms_sup = Pid}) ->
    is_pid(Pid) andalso is_process_alive(Pid).

running_children(content) ->
    quod_ns_sup:children();
running_children(brahms) ->
    quod_brahms_sup:children().

ensure_one(Kind, Ns, Config) ->
    case running_pid(Kind, Ns) of
        Pid when is_pid(Pid) ->
            {ok, Pid};
        undefined ->
            start_one(Kind, Ns, Config)
    end.

running_pid(content, Ns) ->
    quod_reg:where({quod_ns, Ns});
running_pid(brahms, Ns) ->
    quod_reg:where({quod_brahms, Ns}).

start_one(content, Ns, Config) ->
    quod_ns_sup:start_child(Ns, Config);
start_one(brahms, Ns, Config) ->
    quod_brahms_sup:start_child(Ns, Config).

stop_one(content, Ns) ->
    quod_ns_sup:stop_child(Ns);
stop_one(brahms, Ns) ->
    quod_brahms_sup:stop_child(Ns).

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
        true -> notify_content_changed();
        false -> ok
    end;
maybe_notify_directory(brahms, _Result) ->
    ok.

notify_content_changed() ->
    quod_directory_control:namespace_changed(),
    _ = quod_reg:publish(
          {namespace_topology, node},
          {namespace_topology,
           lists:usort(quod_simplex:namespaces())}),
    ok.

complete_ensured_child(content, Ns, Config, Result, {ok, _GenesisHash}) ->
    publish_storage(Ns, Config),
    Result;
complete_ensured_child(content, _Ns, _Config, _Result, {error, _} = Error) ->
    Error;
complete_ensured_child(content, _Ns, _Config, Result, skipped) ->
    Result;
complete_ensured_child(brahms, _Ns, _Config, Result, _Validation) ->
    Result.

complete_running_children(brahms, _Desired) ->
    {true, #{}, #{}};
complete_running_children(content, Desired) ->
    {Complete, Validated, StorageAdds} =
        maps:fold(
          fun(Ns, Config, {Complete0, ValidAcc, DirsAcc}) ->
              case running_pid(content, Ns) of
                  Pid when is_pid(Pid) ->
                      case started_genesis(Ns, Config) of
                          {ok, _GenesisHash} ->
                              Dirs = content_storage(Config),
                              {Complete0, ValidAcc#{Ns => true},
                               DirsAcc#{Ns => Dirs}};
                          {error, _} ->
                              {false, ValidAcc, DirsAcc}
                      end;
                  undefined ->
                      {false, ValidAcc, DirsAcc}
              end
          end, {true, #{}, #{}}, Desired),
    {Complete, Validated, StorageAdds}.

publish_reconcile_storage(StorageAdds) when map_size(StorageAdds) =:= 0 -> ok;
publish_reconcile_storage(StorageAdds) ->
    Storage0 = application:get_env(quod, content_storage_dirs, #{}),
    application:set_env(
      quod, content_storage_dirs, maps:merge(Storage0, StorageAdds)).

completed_start_succeeded(content, Ns, Result, Validated) ->
    start_succeeded(Result) andalso maps:is_key(Ns, Validated);
completed_start_succeeded(brahms, _Ns, Result, _Validated) ->
    start_succeeded(Result).

%% The manager serializes every writer of this projection. Stopped ontologies
%% deliberately remain addressable by the explorer, so entries are not removed
%% when hosting intent is removed.
publish_storage(Ns, Config) ->
    Dirs = application:get_env(quod, content_storage_dirs, #{}),
    application:set_env(
      quod, content_storage_dirs, Dirs#{Ns => content_storage(Config)}).

content_storage(Config) ->
    #{data => quod_ledger_store:data_dir(Config),
      ledger => quod_ledger_store:ledger_dir(Config)}.

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
schedule_reconcile(S = #s{reconcile_retry_ms = Delay}) ->
    Ref = erlang:send_after(Delay, self(), reconcile),
    S#s{retry = Ref,
        reconcile_retry_ms = min(?RETRY_MAX_MS, Delay * 2)}.

reset_reconcile_backoff(S) ->
    S#s{reconcile_retry_ms = ?RETRY_MS}.

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

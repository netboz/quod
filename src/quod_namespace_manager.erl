-module(quod_namespace_manager).
-moduledoc """
Projection owner for per-ontology content and Brahms children.

The two child supervisors are intentionally replaceable. Their dynamic child
specs disappear if either supervisor process is restarted, so this manager
reconciles the desired projection derived from root bootstrap, the committed
root system catalogue, and the local node actor's committed hosting facts.
Lifecycle effects may start content once, but never become restart authority.

The physical node actor is the single bootstrap exception to that general
hosting store: one exact local pointer beside `node.key` resumes only its
already-present ledger, after which this manager verifies the committed node
instance and active-key binding. The pointer is identity bootstrap, never
hosting or directory authority.

After the statically configured root becomes ready, this same owner reads its
committed `system_ontology/2` catalogue. Exact anchored system joins are
merged into the existing desired-state projection; there is no second system
ontology supervisor or restart mechanism. A local stop affects the running
child only; committed root or node-actor facts remain the restart authority.

This process is also the sole publisher of the explorer's namespace-to-ledger
projection. A caller may die or time out after a start request is accepted, so
post-start genesis validation and publication must not live in that caller.
Every potentially slow supervisor start or stop—direct lifecycle or desired
state reconciliation—runs through one monitored mutation lane. The manager
itself owns only projection state, ordering, and replies.
""".

-behaviour(gen_server).

-export([start_link/0,
         start_content/2, start_new_content/2, stop_content/1,
         start_brahms/2, stop_brahms/1, adopt_node_actor/0,
         project_node_policy/4, hosting_snapshot/0]).
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2]).
-ifdef(TEST).
-export([test_node_actor_result_class/1, test_projection_conflicts/3,
         test_install_system_projection/4, test_retired_names/3,
         test_mutation_worker/0, test_recovery_state/0,
         test_arm_system_query/0]).
-endif.

-define(KEY, {namespace_manager, node}).
-define(DESIRED_ENV, namespace_desired).
-define(SYSTEM_QUERY_TIMEOUT_MS, 15000).
-define(ROOT_NS, <<"quod:root">>).

-record(s, {
    desired = #{content => #{}, brahms => #{}},
    ns_sup = undefined,
    ns_monitor = undefined,
    brahms_sup = undefined,
    brahms_monitor = undefined,
    mutation_worker = undefined,
    reconcile_dirty = false,
    pending_calls = undefined,
    bootstrap_content = #{},
    system_content = #{},
    node_content = #{},
    node_projection = none,
    retired_content = #{},
    system_blocked = #{},
    identity_blocked = #{},
    system_query = undefined,
    system_dirty = false,
    node_actor = none,
    route_waits = #{},
    system_route_waits = #{},
    node_route_waits = #{},
    runtime_waits = #{},
    hosting_revision = 0,
    ready_content = [],
    ready_private = []
}).

start_link() ->
    gen_server:start_link(quod_reg:via(?KEY), ?MODULE, [], []).

start_content(Ns, Config) ->
    start_child(content, Ns, Config).

%% Runtime creation is an admission, not an idempotent ensure. The manager
%% starts and validates the newcomer without creating restart authority. A
%% previously committed, exact-anchor node hosting projection may already name
%% it when create and host were one multi-ontology transaction.
start_new_content(Ns, Config) ->
    start_new_child(content, Ns, Config).

stop_content(Ns) ->
    stop_child(content, Ns).

start_brahms(Ns, Config) ->
    start_child(brahms, Ns, Config).

stop_brahms(Ns) ->
    stop_child(brahms, Ns).

-doc "Adopt the exact node-actor pointer persisted by the enrollment seam.".
adopt_node_actor() ->
    gen_server:cast(quod_reg:via(?KEY), adopt_node_actor).

-doc "Install one complete revisioned projection from the local node actor.".
project_node_policy(Namespace, Height, Scope, Projection) ->
    gen_server:call(quod_reg:via(?KEY),
                    {project_node_policy, Namespace, Height, Scope, Projection},
                    15000).

-doc "Return the manager-owned revisioned set of locally ready content identities.".
hosting_snapshot() ->
    gen_server:call(quod_reg:via(?KEY), hosting_snapshot, 5000).

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
    {NodeActor, NodeActorContent} = node_actor_bootstrap(),
    Desired0 = desired_env(),
    Static0 = application:get_env(quod, namespace_static_content, #{}),
    %% Configuration is bootstrap authority for root only. Ordinary and system
    %% hosting come from committed facts, never from a parallel config owner.
    RootBootstrap = maps:with([?ROOT_NS], Static0),
    log_ignored_static_content(maps:without([?ROOT_NS], Static0)),
    Bootstrap = merge_exact_content(RootBootstrap, NodeActorContent,
                                    node_actor_identity_conflict),
    Mirrored = maps:get(content, Desired0),
    System = maps:filter(
               fun(_Ns, Config) ->
                   is_map(Config)
                       andalso maps:get(system_ontology, Config, false) =:= true
               end, Mirrored),
    Content = content_projection(Bootstrap, System, #{}),
    Desired = Desired0#{content => Content},
    persist_desired(Desired),
    application:unset_env(quod, node_actor_principal),
    true = quod_reg:subscribe({runtime, ?ROOT_NS}),
    true = quod_reg:subscribe({namespace_topology, node}),
    NsMonitor = quod_reg:monitor_name({quod_ns_sup, node}, follow),
    BrahmsMonitor = quod_reg:monitor_name({quod_brahms_sup, node}, follow),
    self() ! reconcile,
    self() ! refresh_system_catalogue,
    maybe_subscribe_node_actor(NodeActor),
    {ok, #s{desired = Desired, bootstrap_content = Bootstrap,
            system_content = System, node_actor = NodeActor,
            ns_sup = quod_reg:where({quod_ns_sup, node}),
            ns_monitor = NsMonitor,
            brahms_sup = quod_reg:where({quod_brahms_sup, node}),
            brahms_monitor = BrahmsMonitor,
            pending_calls = queue:new()}}.

handle_call({project_node_policy, Namespace, Height, Scope, Projection}, _From, S) ->
    case install_node_projection(Namespace, Height, Scope, Projection, S) of
        {ok, S1} -> {reply, ok, S1};
        {error, _} = Error -> {reply, Error, S}
    end;
handle_call(hosting_snapshot, _From,
            S = #s{hosting_revision = Revision, ready_content = Ready,
                   ready_private = Private}) ->
    {reply, {ok, Revision, Ready, Private}, S};
handle_call(Request, From, S) ->
    {noreply, continue_work(enqueue_call(Request, From, S))}.

begin_request(
  {start_new, content, Ns, Config}, _From,
  S = #s{desired = Desired}) ->
    Content = maps:get(content, Desired),
    case {maps:get(Ns, Content, undefined), running_pid(content, Ns)} of
        {DesiredConfig, undefined} when is_map(DesiredConfig) ->
            %% In a composed create+host transaction the committed hosting
            %% fact can reach P before root's effect runs. It is the same
            %% authority, not a collision, only when both prepared configs bind
            %% the exact genesis anchor.
            case same_anchor(DesiredConfig, Config) of
                true -> {work, {start_new, Ns, Config}, S};
                false -> {reply, {error, {already_configured, Ns}}, S}
            end;
        {DesiredConfig, _Pid} when is_map(DesiredConfig) ->
            {reply, {error, {already_configured, Ns}}, S};
        {undefined, Pid} when is_pid(Pid) ->
            %% A failed earlier stop can leave an undesired child alive. Never
            %% attach a new config to a process that was started under another.
            {reply, {error, {already_configured, Ns}}, S};
        {undefined, undefined} ->
            {work, {start_new, Ns, Config}, S}
    end;
begin_request(
  {start, Kind, Ns, Config}, _From,
  S = #s{desired = Desired})
  when Kind =:= content; Kind =:= brahms ->
    KindDesired = maps:get(Kind, Desired),
    case maps:get(Ns, KindDesired, undefined) of
        undefined ->
            {work, {ensure, Kind, Ns, Config}, S};
        Config ->
            {work, {ensure, Kind, Ns, Config}, S};
        _OtherConfig ->
            {reply, {error, {already_configured, Ns}}, S}
    end;
begin_request(
  {stop, Kind, Ns}, _From,
  S = #s{desired = Desired})
  when Kind =:= content; Kind =:= brahms ->
    KindDesired = maps:get(Kind, Desired),
    case {maps:is_key(Ns, KindDesired), running_pid(Kind, Ns)} of
        {false, undefined} -> {reply, {error, not_found}, S};
        _ -> {work, {stop, Kind, Ns}, S}
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
  S) ->
    publish_storage(Ns, Config),
    notify_content_changed(),
    {{ok, GenesisHash}, S};
finish_request(
  {start_new, _Ns, _Config, {rejected, Reason, Cleanup}}, S) ->
    {{error, Reason}, log_mutation_failure(Cleanup, S)};
finish_request(
  {start_new, Ns, _Config, {start_result, Result}}, S) ->
    Reply = normalize_new_start_result(Ns, Result),
    {Reply, S};
finish_request(
  {ensure, Kind, Ns, Config, RawResult, Validation}, S) ->
    Result = complete_ensured_child(
               Kind, Ns, Config, RawResult, Validation),
    maybe_notify_directory(Kind, Result),
    {Result, log_mutation_failure(Result, S)};
finish_request({stop, Kind, Result}, S) ->
    maybe_notify_directory(Kind, Result),
    {Result, log_mutation_failure(Result, S)}.

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

handle_cast(adopt_node_actor, S) ->
    {NodeActor, NodeActorContent} = node_actor_bootstrap(),
    S1 = adopt_node_actor_state(NodeActor, NodeActorContent, S),
    case NodeActor of
        #{namespace := ActorNs} -> quod_runtime:reconcile_now(ActorNs);
        none -> ok
    end,
    self() ! reconcile,
    {noreply, S1};
handle_cast(_Message, S) ->
    {noreply, S}.

handle_info(reconcile, S = #s{mutation_worker = undefined}) ->
    S0 = sync_runtime_waits(S),
    case queue:is_empty(S0#s.pending_calls) of
        true -> {noreply, start_reconcile(S0)};
        false -> {noreply, S0#s{reconcile_dirty = true}}
    end;
handle_info(reconcile, S) ->
    {noreply, S#s{reconcile_dirty = true}};
handle_info(
  {mutation_result, Token,
   {reconcile, Changed, Complete, StorageAdds, NodeActorResult,
    IdentityBlocked}},
  S = #s{mutation_worker = {_Pid, MRef, Token, reconcile}}) ->
    demonitor(MRef, [flush]),
    publish_reconcile_storage(StorageAdds),
    case install_node_actor_result(NodeActorResult) of
        ok -> ok;
        {error, Reason} -> exit({node_actor_invalid, Reason})
    end,
    case {node_actor_result_class(NodeActorResult), S#s.node_actor} of
        {{ready, _}, #{namespace := ActorNs}} ->
            quod_runtime:reconcile_now(ActorNs);
        _ -> ok
    end,
    log_identity_blocked(IdentityBlocked, S#s.identity_blocked),
    S0 = install_ready_content(
           maps:keys(StorageAdds),
           sync_node_route_waits(
             S#s{mutation_worker = undefined,
                 identity_blocked = IdentityBlocked})),
    case Changed of
        true -> notify_content_changed();
        false -> ok
    end,
    S1 = case Complete of
             true -> S0#s{retired_content = #{}};
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
       S#s{mutation_worker = undefined})};
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
handle_info(refresh_system_catalogue, S) ->
    {noreply, start_system_query(S)};
handle_info({replay_ready, _Id, _Height}, S) ->
    self() ! reconcile,
    {noreply, request_system_refresh(S)};
handle_info({applied_live, Envelope}, S) ->
    case system_catalogue_changed(Envelope) of
        true ->
            {noreply, request_system_refresh(S)};
        false -> {noreply, S}
    end;
handle_info({namespace_topology, _Namespaces}, S) ->
    %% A lifecycle effect may materialize a ledger after its hosting fact was
    %% committed. The existing topology edge wakes the same reconciler.
    self() ! reconcile,
    {noreply, S};
handle_info({directory_route_available, Identity},
            S = #s{route_waits = Waits}) ->
    case maps:get(Identity, Waits, []) of
        [] -> {noreply, S};
        Kinds ->
            S1 = case lists:member(node, Kinds) of
                     true -> materialize_node_route(Identity, S);
                     false -> S
                 end,
            S2 = case lists:member(system, Kinds) of
                     true -> request_system_refresh(S1);
                     false -> S1
                 end,
            {noreply, S2}
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
  #s{system_query = {Pid, Ref, _Token, Timer}}) ->
    cancel_timer(Timer),
    exit({system_catalogue_worker_failed, Reason});
handle_info(
  {system_catalogue_timeout, Token},
  #s{system_query = {Pid, MRef, Token, _Timer}}) ->
    demonitor(MRef, [flush]),
    exit(Pid, kill),
    exit(system_catalogue_query_timeout);
handle_info({gproc, registered, Ref, _Name},
            S = #s{ns_monitor = Ref}) ->
    self() ! reconcile,
    {noreply, S#s{ns_sup = quod_reg:where({quod_ns_sup, node})}};
handle_info({gproc, unreg, Ref, _Name}, S = #s{ns_monitor = Ref}) ->
    {noreply, S#s{ns_sup = undefined}};
handle_info({gproc, registered, Ref, _Name},
            S = #s{brahms_monitor = Ref}) ->
    self() ! reconcile,
    {noreply, S#s{brahms_sup = quod_reg:where({quod_brahms_sup, node})}};
handle_info({gproc, unreg, Ref, _Name}, S = #s{brahms_monitor = Ref}) ->
    {noreply, S#s{brahms_sup = undefined}};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, S) ->
    stop_mutation(S#s.mutation_worker),
    stop_system_query(S#s.system_query),
    demonitor_supervisor({quod_ns_sup, node}, S#s.ns_monitor),
    demonitor_supervisor({quod_brahms_sup, node}, S#s.brahms_monitor),
    unsubscribe_waits(S#s.route_waits, directory_route),
    unsubscribe_waits(S#s.runtime_waits, runtime),
    _ = catch quod_reg:unsubscribe({runtime, ?ROOT_NS}),
    _ = catch quod_reg:unsubscribe({namespace_topology, node}),
    _ = unsubscribe_node_actor(S#s.node_actor),
    ok.

%% Supervisor termination may legitimately wait for an ontology subtree to
%% finish.  Keep that wait out of the desired-state owner's mailbox: one
%% monitored worker executes the existing reconciliation path, while this
%% process continues accepting catalogue changes and records that another pass
%% is needed.  There is still exactly one reconciler and one desired-state
%% owner.
start_reconcile(S) ->
    Parent = self(),
    Token = make_ref(),
    {Pid, MRef} =
        spawn_monitor(
          fun() ->
              {Changed, Complete, StorageAdds, ActorResult,
               IdentityBlocked} = reconcile_all(S),
              Parent !
                  {mutation_result, Token,
                   {reconcile, Changed, Complete, StorageAdds, ActorResult,
                    IdentityBlocked}}
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
    S#s{reconcile_dirty = false};
finish_reconcile_cycle(S) -> S.

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
    sync_system_route_waits(Pending, Descriptors, S1);
%% Root itself is started by static bootstrap configuration.  Its replay-ready
%% event is the retry signal; polling a root which does not exist yet would only
%% produce log noise.  A malformed committed catalogue also waits for its next
%% root change rather than re-reading the same bad state in a tight loop.
finish_system_query({error, no_such_namespace}, S) -> S;
finish_system_query({error, root_not_ready}, S) -> S;
finish_system_query({error, {ontology_rebuilding, ?ROOT_NS}}, S) -> S;
finish_system_query({error, malformed_system_catalogue}, S) ->
    log_invalid_system_catalogue(malformed_system_catalogue, S);
finish_system_query({error, Reason}, _S) ->
    exit({system_catalogue_unavailable, Reason}).

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
    {NewContent, NodeContent, Retired, Conflict} =
        install_system_projection(S#s.bootstrap_content, System,
                                  S#s.node_content, S#s.system_content),
    case Conflict of
        none -> ok;
        {node_host_anchor_conflict, Ns} = Reason ->
            logger:error(
              "quod: rejected node hosting projection conflicting with "
              "root system ontology ~p: ~p", [Ns, Reason]),
            wake_node_actor(S#s.node_actor)
    end,
    Desired1 = Desired#{content => NewContent},
    persist_desired(Desired1),
    self() ! reconcile,
    S#s{desired = Desired1, system_content = System,
        node_content = NodeContent,
        node_projection = invalidate_projection(Conflict,
                                                S#s.node_projection),
        retired_content = maps:merge(S#s.retired_content, Retired)}.

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

node_actor_bootstrap() ->
    case quod_node_actor:bootstrap() of
        none -> {none, #{}};
        {ok, Blob, Config} ->
            {ok, #{identity := {Ns, Anchor}}} = quod_agent_ref:decode(Blob),
            {#{blob => Blob, namespace => Ns, anchor => Anchor},
             #{Ns => Config}};
        {error, Reason} ->
            error({node_actor_bootstrap_failed, Reason})
    end.

adopt_node_actor_state(
  NodeActor, NodeActorContent,
  S = #s{desired = Desired, bootstrap_content = Bootstrap0,
         system_content = System, node_content = NodeContent,
         node_actor = PreviousActor}) ->
    RootBootstrap = maps:with([?ROOT_NS], Bootstrap0),
    Bootstrap = merge_exact_content(RootBootstrap, NodeActorContent,
                                    node_actor_identity_conflict),
    ok = projection_conflicts(Bootstrap, System, NodeContent),
    Content = content_projection(Bootstrap, System, NodeContent),
    Desired1 = Desired#{content => Content},
    persist_desired(Desired1),
    maybe_subscribe_adopted_node_actor(PreviousActor, NodeActor),
    S#s{desired = Desired1, bootstrap_content = Bootstrap,
        node_actor = NodeActor}.

install_node_projection(
  Namespace, Height, _Scope, Projection,
  S = #s{node_actor = #{namespace := Namespace},
         node_projection = Previous}) ->
    Revision = Height,
    case projection_revision(Previous, Revision) of
        stale -> {error, stale_node_hosting_projection};
        same -> {ok, S};
        newer ->
            case node_projection_content(Projection) of
                {ok, NodeContent, Contacts} ->
                    case projection_conflicts(
                           S#s.bootstrap_content, S#s.system_content,
                           NodeContent) of
                        ok ->
                            OldNames = maps:keys(S#s.node_content),
                            RetiredNames = OldNames -- maps:keys(NodeContent),
                            Retired = maps:with(RetiredNames, S#s.node_content),
                            Content = content_projection(
                                        S#s.bootstrap_content,
                                        S#s.system_content, NodeContent),
                            Desired1 = (S#s.desired)#{content => Content},
                            persist_desired(Desired1),
                            self() ! reconcile,
                            {ok, sync_node_route_waits(
                                   S#s{desired = Desired1,
                                       node_content = NodeContent,
                                       node_projection =
                                         #{revision => Revision,
                                           contacts => Contacts},
                                       retired_content = maps:merge(
                                                           S#s.retired_content,
                                                           Retired)})};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end
    end;
install_node_projection(_, _, _, _, _) ->
    {error, node_actor_context_mismatch}.

projection_revision(none, _Revision) -> newer;
projection_revision(#{revision := Height, status := invalid}, Height) -> newer;
projection_revision(#{revision := OldHeight}, Height) ->
    case Height - OldHeight of
        N when N > 0 -> newer;
        N when N < 0 -> stale;
        0 -> same
    end.

node_projection_content(#{hosts := Hosts, contacts := Contacts})
  when is_map(Hosts), is_map(Contacts) ->
    case application:get_env(quod, content_data_dir) of
        {ok, DataDir} ->
            {ok,
             maps:map(
               fun(_Ns, #{namespace := Ns, anchor := Anchor,
                          visibility := Visibility}) ->
                   (quod_ontology:local_resume_config(Ns, Anchor, DataDir))#{
                     hosting_visibility => Visibility,
                     local_material_required => true}
               end, Hosts),
             Contacts};
        _ -> {error, node_storage_unavailable}
    end;
node_projection_content(_) -> {error, malformed_node_hosting_projection}.

maybe_subscribe_adopted_node_actor(none, NodeActor) ->
    maybe_subscribe_node_actor(NodeActor);
maybe_subscribe_adopted_node_actor(#{namespace := Ns}, #{namespace := Ns}) ->
    ok;
maybe_subscribe_adopted_node_actor(PreviousActor, NodeActor) ->
    _ = unsubscribe_node_actor(PreviousActor),
    maybe_subscribe_node_actor(NodeActor).

merge_exact_content(Preferred, Additional, ConflictTag) ->
    maps:fold(
      fun(Ns, Config, Acc) ->
          case maps:get(Ns, Acc, undefined) of
              undefined -> Acc#{Ns => Config};
              Existing ->
                  case same_anchor(Existing, Config) of
                      true -> Acc;
                      false -> error({ConflictTag, Ns})
                  end
          end
      end, Preferred, Additional).

maybe_subscribe_node_actor(none) -> ok;
maybe_subscribe_node_actor(#{namespace := Ns}) ->
    true = quod_reg:subscribe({runtime, Ns}),
    ok.

unsubscribe_node_actor(none) -> ok;
unsubscribe_node_actor(#{namespace := Ns}) ->
    catch quod_reg:unsubscribe({runtime, Ns}),
    ok.

verify_node_actor(none) -> none;
verify_node_actor(#{blob := Blob}) ->
    case application:get_env(quod, node_pubkey) of
        {ok, <<_:256>> = PublicKey} -> quod_node_actor:verify(Blob, PublicKey);
        _ -> {error, node_identity_unavailable}
    end.

node_actor_complete(Result) ->
    node_actor_result_class(Result) =/= pending.

install_node_actor_result(Result) ->
    case node_actor_result_class(Result) of
        absent -> ok;
        {ready, Principal} ->
            application:set_env(quod, node_actor_principal, Principal),
            ok;
        pending -> ok;
        {fatal, Reason} -> {error, Reason}
    end.

node_actor_result_class(none) -> absent;
node_actor_result_class({ok, Principal}) -> {ready, Principal};
node_actor_result_class({error, node_actor_anchor_mismatch}) ->
    {fatal, node_actor_anchor_mismatch};
node_actor_result_class({error, node_actor_instance_mismatch}) ->
    {fatal, node_actor_instance_mismatch};
node_actor_result_class({error, node_actor_active_key_mismatch}) ->
    {fatal, node_actor_active_key_mismatch};
node_actor_result_class({error, node_actor_inactive_key}) ->
    {fatal, node_actor_inactive_key};
node_actor_result_class({error, malformed_node_actor_identity}) ->
    {fatal, malformed_node_actor_identity};
node_actor_result_class({error, invalid_node_actor_pointer}) ->
    {fatal, invalid_node_actor_pointer};
node_actor_result_class({error, bad_node_actor_pointer}) ->
    {fatal, bad_node_actor_pointer};
node_actor_result_class({error, _Transient}) -> pending.

-ifdef(TEST).
test_node_actor_result_class(Result) -> node_actor_result_class(Result).
test_projection_conflicts(Bootstrap, System, Node) ->
    projection_conflicts(Bootstrap, System, Node).
test_install_system_projection(Bootstrap, System, Node, OldSystem) ->
    install_system_projection(Bootstrap, System, Node, OldSystem).
test_retired_names(Retired, Running, Current) ->
    retired_content_names(Retired, Running, Current).
test_mutation_worker() ->
    S = sys:get_state(quod_reg:via(?KEY)),
    S#s.mutation_worker.
test_recovery_state() ->
    S = sys:get_state(quod_reg:via(?KEY)),
    #{system_blocked => S#s.system_blocked,
      identity_blocked => S#s.identity_blocked,
      route_waits => S#s.route_waits,
      runtime_waits => S#s.runtime_waits,
      system_query => case S#s.system_query of
                          undefined -> idle;
                          _ -> active
                      end,
      hosting_revision => S#s.hosting_revision,
      ready_content => S#s.ready_content}.
test_arm_system_query() ->
    Caller = self(),
    ReplyRef = make_ref(),
    _ = sys:replace_state(
          quod_reg:via(?KEY),
          fun(S = #s{system_query = undefined}) ->
              {Pid, MRef} = spawn_monitor(fun() -> receive stop -> ok end end),
              Token = make_ref(),
              Timer = erlang:send_after(
                        60000, self(), {system_catalogue_timeout, Token}),
              Caller ! {ReplyRef, Pid, Token},
              S#s{system_query = {Pid, MRef, Token, Timer}}
          end),
    receive {ReplyRef, Pid, Token} -> {Pid, Token} end.
-endif.

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

content_projection(Bootstrap, System, Node) ->
    %% Root bootstrap and root-catalogued system facts outrank node facts.
    maps:merge(Node, maps:merge(Bootstrap, System)).

same_anchor(A, B) ->
    maps:get(genesis_hash, A, undefined) =:=
        maps:get(genesis_hash, B, undefined).

projection_conflicts(Bootstrap, System, Node) ->
    Strong = maps:merge(Bootstrap, System),
    maps:fold(
      fun(Ns, Config, ok) ->
              case maps:get(Ns, Strong, undefined) of
                  undefined -> ok;
                  StrongConfig ->
                      case same_anchor(Config, StrongConfig) of
                          true -> ok;
                          false -> {error, {node_host_anchor_conflict, Ns}}
                      end
              end;
         (_Ns, _Config, Error) -> Error
      end, ok, Node).

install_system_projection(Bootstrap, System, Node, OldSystem) ->
    Strong = maps:merge(Bootstrap, System),
    ConflictNames =
        [Ns || {Ns, Config} <- maps:to_list(Node),
               case maps:get(Ns, Strong, undefined) of
                   undefined -> false;
                   StrongConfig -> not same_anchor(Config, StrongConfig)
               end],
    Node1 = maps:without(ConflictNames, Node),
    RemovedSystem = maps:without(maps:keys(System), OldSystem),
    Conflict = case ConflictNames of
                   [] -> none;
                   [Ns | _] -> {node_host_anchor_conflict, Ns}
               end,
    {content_projection(Bootstrap, System, Node1),
     Node1, RemovedSystem, Conflict}.

invalidate_projection(none, Projection) -> Projection;
invalidate_projection(_Conflict, none) -> none;
invalidate_projection(_Conflict, Projection) ->
    Projection#{status => invalid}.

wake_node_actor(none) -> ok;
wake_node_actor(#{namespace := Ns}) -> quod_runtime:reconcile_now(Ns).

log_ignored_static_content(Static) when map_size(Static) =:= 0 -> ok;
log_ignored_static_content(Static) ->
    logger:warning(
      "quod: ignoring non-root namespace_static_content identities ~p; "
      "committed root/node facts are the hosting authority",
      [maps:keys(Static)]).

sync_system_route_waits(Pending, Descriptors, S) ->
    PendingSet = maps:from_list([{Ns, true} || Ns <- Pending]),
    Wanted = maps:from_list(
               [{{maps:get(namespace, D), maps:get(anchor, D)}, true}
                || D <- Descriptors,
                   maps:is_key(maps:get(namespace, D), PendingSet)]),
    {S1, Added} = sync_route_wait_source(system, Wanted, S),
    case Added of
        true -> request_system_refresh(S1);
        false -> S1
    end.

sync_node_route_waits(S = #s{node_content = NodeContent}) ->
    Wanted = maps:fold(
               fun(Ns, Config, Acc) ->
                   case local_material_ready(Ns, Config) of
                       true -> Acc;
                       false -> Acc#{{Ns, maps:get(genesis_hash, Config)} => true}
                   end
               end, #{}, NodeContent),
    NewNodeWaits = maps:keys(Wanted) -- maps:keys(S#s.node_route_waits),
    {S1, _AddedSubscription} = sync_route_wait_source(node, Wanted, S),
    %% Subscribe first, then force the same exact-identity reread used by a
    %% directory wake. This remains necessary when a system wait already owns
    %% the shared gproc subscription.
    _ = [self() ! {directory_route_available, Identity}
         || Identity <- NewNodeWaits],
    S1.

sync_route_wait_source(system, Wanted, S) ->
    sync_route_wait_sources(S#s{system_route_waits = Wanted});
sync_route_wait_source(node, Wanted, S) ->
    sync_route_wait_sources(S#s{node_route_waits = Wanted}).

sync_route_wait_sources(S) ->
    Combined = maps:fold(
                 fun(Identity, _True, Acc) ->
                     Acc#{Identity => [system | maps:get(Identity, Acc, [])]}
                 end, #{}, S#s.system_route_waits),
    Wanted = maps:fold(
               fun(Identity, _True, Acc) ->
                   Acc#{Identity => [node | maps:get(Identity, Acc, [])]}
               end, Combined, S#s.node_route_waits),
    sync_waits(directory_route, Wanted, S#s.route_waits, S).

sync_runtime_waits(S = #s{desired = Desired, node_actor = NodeActor}) ->
    ActorNs = case NodeActor of
                  #{namespace := Ns} -> Ns;
                  none -> none
              end,
    Content = maps:get(content, Desired),
    Wanted = maps:from_list(
               [{Ns, replay_ready}
                || {Ns, Config} <- maps:to_list(Content),
                   Ns =/= ?ROOT_NS, Ns =/= ActorNs,
                   runtime_wait_required(Ns, Config)]),
    {S1, _Added} = sync_waits(runtime, Wanted, S#s.runtime_waits, S),
    S1.

runtime_wait_required(Ns, Config) ->
    case running_pid(content, Ns) of
        Pid when is_pid(Pid) ->
            started_genesis(Ns, Config) =/= {ok, maps:get(genesis_hash, Config)};
        undefined -> false
    end.

sync_waits(Kind, Wanted, Current, S) ->
    Removed = maps:keys(Current) -- maps:keys(Wanted),
    Added = maps:keys(Wanted) -- maps:keys(Current),
    _ = [catch quod_reg:unsubscribe({Kind, Key}) || Key <- Removed],
    _ = [true = quod_reg:subscribe({Kind, Key}) || Key <- Added],
    S1 = case Kind of
             directory_route -> S#s{route_waits = Wanted};
             runtime -> S#s{runtime_waits = Wanted}
         end,
    {S1, Added =/= []}.

materialize_node_route({Ns, Anchor} = Identity, S) ->
    case node_route_config(Ns, Anchor) of
        {ok, Config0} ->
            Existing = maps:get(Ns, S#s.node_content),
            Config = Config0#{hosting_visibility =>
                                  maps:get(hosting_visibility, Existing,
                                           private)},
            NodeContent = (S#s.node_content)#{Ns => Config},
            Content = content_projection(S#s.bootstrap_content,
                                         S#s.system_content, NodeContent),
            Desired = (S#s.desired)#{content => Content},
            persist_desired(Desired),
            self() ! reconcile,
            sync_node_route_waits(
              S#s{desired = Desired, node_content = NodeContent});
        {error, unavailable} -> S;
        {error, Reason} ->
            logger:error("quod: node-host route materialization failed for ~p: ~p",
                         [Identity, Reason]),
            S
    end.

node_route_config(Ns, Anchor) ->
    case quod_directory:validator_routes(Ns, Anchor) of
        {ok, Routes} when Routes =/= [] ->
            Seeds = lists:usort(
                      [Endpoint || #{endpoint := Endpoint} <- Routes]),
            quod_ontology:prepare_host_join(Ns, Anchor, Seeds);
        {ok, []} -> {error, unavailable};
        {error, unavailable} -> {error, unavailable};
        {error, Reason} -> {error, Reason}
    end.

unsubscribe_waits(Waits, Kind) ->
    _ = [catch quod_reg:unsubscribe({Kind, Key}) || Key <- maps:keys(Waits)],
    ok.

demonitor_supervisor(Key, Ref) when is_reference(Ref) ->
    _ = catch quod_reg:demonitor_name(Key, Ref),
    ok;
demonitor_supervisor(_Key, _Ref) -> ok.

reconcile_all(S = #s{desired = Desired}) ->
    {ContentChanged, ContentComplete, StorageAdds, IdentityBlocked} =
        reconcile_kind(
          content, maps:get(content, Desired), S),
    {_BrahmsChanged, BrahmsComplete, _NoStorage, _NoBlocked} =
        reconcile_kind(
          brahms, maps:get(brahms, Desired), S),
    ActorResult = verify_node_actor(S#s.node_actor),
    {ContentChanged,
     ContentComplete andalso BrahmsComplete
         andalso node_actor_complete(ActorResult),
     StorageAdds, ActorResult, IdentityBlocked}.

reconcile_kind(Kind, Desired, S) ->
    case supervisor_available(Kind, S) of
        false ->
            {false, false, #{}, #{}};
        true ->
            Running = running_children(Kind),
            IdentityBlocked = wrong_identity_rows(Kind, Running, Desired),
            Undesired = lists:usort(
                          retired_names(Kind, Running, S)
                          ++ maps:keys(IdentityBlocked)),
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
                              start_complete(Result)
                          end, Results)
                andalso Ready,
            {Changed, Complete, StorageAdds, IdentityBlocked}
    end.

retired_names(content, Running,
              #s{retired_content = Retired, desired = Desired}) ->
    Current = maps:get(content, Desired),
    retired_content_names(Retired, Running, Current);
retired_names(brahms, _Running, _S) -> [].

retired_content_names(Retired, Running, Current) ->
    [Ns || Ns <- maps:keys(Retired), maps:is_key(Ns, Running),
           not maps:is_key(Ns, Current)].

wrong_identity_rows(content, Running, Desired) ->
    maps:from_list(
      [{Ns, #{wanted_anchor => maps:get(genesis_hash, Config),
              running_anchor => current_genesis(Ns)}}
       || {Ns, Config} <- maps:to_list(Desired),
          maps:is_key(Ns, Running),
          started_genesis(Ns, Config) =:= {error, genesis_mismatch}]);
wrong_identity_rows(brahms, _Running, _Desired) -> #{}.

current_genesis(Ns) ->
    case quod_simplex:genesis_hash(Ns) of
        <<_:256>> = Anchor -> Anchor;
        _ -> unavailable
    end.

log_identity_blocked(Current, Previous) ->
    _ = maps:map(
          fun(Ns, Details) ->
              case maps:get(Ns, Previous, undefined) of
                  Details -> ok;
                  _ ->
                      logger:error(
                        "quod: stopping wrong-anchor hosted ontology ~p: ~p",
                        [Ns, Details])
              end
          end, Current),
    ok.

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
    case local_material_ready(Ns, Config) of
        true -> quod_ns_sup:start_child(Ns, Config);
        false -> {parked, local_material}
    end;
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

local_material_ready(Ns, #{local_material_required := true,
                           genesis_hash := Anchor,
                           data_dir := DataDir}) ->
    case quod_ontology:prepare_local_resume(Ns, Anchor, DataDir) of
        {ok, _} -> true;
        _ -> false
    end;
local_material_ready(_Ns, _Config) -> true.

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
                      case local_material_ready(Ns, Config) of
                          false -> {Complete0, ValidAcc, DirsAcc};
                          true -> {false, ValidAcc, DirsAcc}
                      end
              end
          end, {true, #{}, #{}}, Desired),
    {Complete, Validated, StorageAdds}.

publish_reconcile_storage(StorageAdds) when map_size(StorageAdds) =:= 0 -> ok;
publish_reconcile_storage(StorageAdds) ->
    Storage0 = application:get_env(quod, content_storage_dirs, #{}),
    application:set_env(
      quod, content_storage_dirs, maps:merge(Storage0, StorageAdds)).

install_ready_content(ReadyNames,
                      S = #s{ready_content = Old,
                             ready_private = OldPrivate}) ->
    Ready = ready_hosting_projection(ReadyNames, S),
    Private = private_route_projection(S),
    case Ready =:= Old andalso Private =:= OldPrivate of
        true -> S;
        false ->
            Revision = S#s.hosting_revision + 1,
            quod_directory_control:hosting_changed(
              self(), Revision, Ready, Private),
            S#s{hosting_revision = Revision, ready_content = Ready,
                ready_private = Private}
    end.

private_route_projection(#s{node_projection = #{contacts := Contacts}})
  when is_map(Contacts) ->
    lists:sort(maps:values(Contacts));
private_route_projection(_) -> [].

ready_hosting_projection(ReadyNames,
                         #s{bootstrap_content = Bootstrap,
                            system_content = System,
                            node_content = Node}) ->
    lists:sort(
      lists:filtermap(
        fun(Ns) ->
            case ready_hosting_row(Ns, Bootstrap, System, Node) of
                undefined -> false;
                Row -> {true, Row}
            end
        end, ReadyNames)).

ready_hosting_row(Ns, Bootstrap, System, Node) ->
    case {Ns =:= ?ROOT_NS, maps:get(Ns, Bootstrap, undefined)} of
        {true, #{genesis_hash := <<_:256>> = Anchor}} ->
            #{namespace => Ns, anchor => Anchor, source => bootstrap,
              visibility => discoverable};
        _ ->
            case maps:get(Ns, System, undefined) of
                #{genesis_hash := <<_:256>> = Anchor} ->
                    #{namespace => Ns, anchor => Anchor, source => system,
                      visibility => discoverable};
                undefined ->
                    case maps:get(Ns, Node, undefined) of
                        #{genesis_hash := <<_:256>> = Anchor,
                          hosting_visibility := Visibility}
                          when Visibility =:= discoverable;
                               Visibility =:= private ->
                            #{namespace => Ns, anchor => Anchor, source => node,
                              visibility => Visibility};
                        _ -> undefined
                    end
            end
    end.

completed_start_succeeded(content, Ns, Result, Validated) ->
    start_succeeded(Result) andalso maps:is_key(Ns, Validated);
completed_start_succeeded(brahms, _Ns, Result, _Validated) ->
    start_succeeded(Result).

start_complete({parked, local_material}) -> true;
start_complete(Result) -> start_succeeded(Result).

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

log_mutation_failure(Result, S) ->
    case Result of
        ok -> ok;
        {ok, _} -> ok;
        {ok, _, _} -> ok;
        _ -> logger:error("quod: namespace mutation did not complete: ~p",
                          [Result])
    end,
    S.

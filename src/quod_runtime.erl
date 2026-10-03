-module(quod_runtime).
-moduledoc """
Per-ontology owner of hosted actors and ordered live reaction discovery.

The committed ontology owns reaction rules and desired resources. Matching
queues ordinary actor goals; it never executes their durable writes itself.
Resource services accept only a named resource and scope, then select desired
rows from this owner's retained committed snapshot before installing them.
Caller overlays, supplied rows and arbitrary callback goals are never used.

One bounded worker serializes catalog discovery, ordered events and resource
selection. Real owner notifications wake affected resources and pending work;
recovery restores current obligations without replaying historical reactions.
The event frontier records processed canonical input, not completion of goals
or of every local resource. Consumers wait for their actual resource owner.
""".

-behaviour(gen_server).

-include("quod_ledger.hrl").
-include_lib("erlog/src/erlog_int.hrl").

-export([start_link/2, stats/1, effect_frontier/1,
         reconcile_now/1, reconcile_resource/5,
         project_agents/3, project_agent_observers/3, agent_request/6,
         agents/1, reaction_agents/2, catalog_after/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_continue/2, handle_info/2,
         terminate/2]).
-ifdef(TEST).
%% Pure catalogue planning and the production ordered fold.
-export([plan_runtime_catalog/1, alpha_normalize/1,
         test_run_events/4, test_drain_observations/4, test_recovery_pending/2]).
-endif.

-define(RECONCILE_BUDGET_MS, 30000).
-define(EVENT_BUDGET_MS, 1000).
-define(EVENT_BUDGET_CAP_MS, 60000).      %% ceiling on a whole batch's runner budget
-define(MAX_AGENT_PENDING, 16).
-define(MAX_AGENT_REQUEST_BYTES, 65536).
-define(MAX_AGENT_PENDING_BYTES, 1048576).
-define(MAX_HOSTED_AGENTS, 1024).
-define(MAX_EXEC_FAILURES, 5).            %% then crash deliberately: the supervisor path runs
-define(DEFAULT_MAX_QUEUED_EVENTS, 1024). %% >= 4 max-size blocks of per-tx envelopes

-record(s, {ns :: binary(),
            config :: map(),
            mode = booting :: booting | {replaying, term()} | {reconciling, term()}
                            | live | {unhealthy, term()},
            est = undefined :: tuple() | undefined,   %% attached snapshot handle
            height = 0 :: non_neg_integer(),          %% its height (the reconcile floor)
            binding = none :: none | map(),
            prolog_monitor :: reference(),
            subscriptions = [] :: [{binary(), binary()}],
            reactions = [] :: [tuple()],
            reaction_index = #{} :: #{tuple() => [tuple()]},
            source_interests = #{} ::
                #{{binary(), binary()} => #{tuple() => [tuple()]}},
            %% One local consumer reference per exact durable subscription.
            %% Verification, cache and materialized P remain shared node-wide.
            source_views = #{} :: #{{binary(), binary()} => map()},
            %% One message-driven attachment queue. It yields after every
            %% local owner call and is repopulated only by catalogue change or
            %% the foreign owner's gproc registration edge: no timer, batch
            %% cap, or retry ladder.
            source_attach_queue = [] :: [{binary(), binary()}],
            source_attach_token = none :: none | reference(),
            source_attempts = 0 :: non_neg_integer(),
            foreign_log_monitor = none :: none | reference(),
            %% One killable reader at a time: catalogue, event matching or resource selection.
            runner = none :: none | {reconcile | events | resource, pid(), reference(), reference(),
                                     reference()},
            resource_waiter = none,
            recovery_pending = none,
            resource_basis = #{} :: map(),
            resource_failures = #{} :: map(),
            resource_owners = #{} :: #{reference() => {quod_reg:key(), pid() | undefined}},
            node_identity = undefined :: term(),
            pending_edge = none :: none | term(),     %% a ready edge that arrived mid-reconcile
            last_recovery = undefined :: term(),      %% dedup: reconcile once per edge id
            %% The one ordered tier carries local apply envelopes and subscribed
            %% certified advances in arrival order. Resource hints share this queue,
            %% while their dependencies use actual installation notifications.
            queue = [] :: [tuple()],                  %% REVERSED work items
            queue_len = 0 :: non_neg_integer(),
            owned_turn = false :: boolean(),
            %% Follow acknowledgements owned by the current event runner. They
            %% are released on success, collapse, replay, or termination, so a
            %% dead reader can never wedge the shared follower.
            event_acks = [] :: [{reference(), reference()}],
            p_height = 0 :: non_neg_integer(),        %% ordered tier completed through here
            e_frontier = 0 :: non_neg_integer(),      %% canonical input released to the existing effect owner
            exec_failures = 0 :: non_neg_integer(),   %% consecutive execution failures (backoff)
            reconciles = 0 :: non_neg_integer(),
            reconcile_failures = 0 :: non_neg_integer(),
            collapses = 0 :: non_neg_integer(),       %% queue overflows + execution collapses
            dropped_events = 0 :: non_neg_integer(),
            rejected_subscriptions = 0 :: non_neg_integer(),
            events_seen = 0 :: non_neg_integer(),     %% direct applied_live received
            reaction_candidates = 0 :: non_neg_integer(),
            reaction_matches = 0 :: non_neg_integer(),
            reactions_executed = 0 :: non_neg_integer(),
            reaction_failures = 0 :: non_neg_integer(),
            observer = none,
            agent_projection_waiter = none, agent_pending_bytes = 0, agent_slots = 0,
            agent_capacity_blocked = false, agent_capacity_refusals = 0,
            agent_work_subscribed = false,
            agents = #{} :: map(),
            hosting_dirty = #{} :: map()}).   %% notices/work released after successful projection

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link(binary(), map()) -> {ok, pid()} | {error, term()}.
start_link(Ns, Config) ->
    gen_server:start_link(quod_reg:via({quod_runtime, Ns}), ?MODULE, {Ns, Config}, []).

%% These installation calls are private to the current owned selector worker.
project_agents(Ns, Scope, Hosts) ->
    gen_server:call(quod_reg:via({quod_runtime, Ns}), {project_agents, Scope, Hosts}, infinity).

project_agent_observers(Ns, Scope, Rows) ->
    gen_server:call(quod_reg:via({quod_runtime, Ns}), {project_agent_observers, Scope, Rows}, infinity).

%% Ordinary goals request convergence; only the resource owner selects rows.
reconcile_resource(Ns, MinHeight, Resource, Scope, Deadline) ->
    gen_server:call(quod_reg:via({quod_runtime, Ns}),
                    {reconcile_resource, MinHeight, Resource, Scope, Deadline}, infinity).

-doc "Queue a bounded live request for the executor selected by the current reaction.".
-spec agent_request(binary(), non_neg_integer(), term(), read | execute, term(),
                    pos_integer() | {expires, pos_integer()} |
                    {expires, pos_integer(), integer()}) ->
          ok | {error, term()}.
agent_request(Ns, Height, Executor, Mode, Goal, Budget) ->
    Mono = quod_time:mono_ms(), Now = quod_time:now_ms(),
    {Expires, Deadline} = case Budget of
        {expires, Expiry, Original} -> {Expiry, min(Original, Mono + Expiry - Now)};
        {expires, Expiry} -> {Expiry, Mono + Expiry - Now};
        Timeout -> {Now + Timeout, Mono + Timeout}
    end,
    gen_server:call(quod_reg:via({quod_runtime, Ns}),
      {agent_request, Height, Executor, Mode, Goal, {Expires, Deadline}}, infinity).

project_agent_work(Ns, Height, Instance, Step) ->
    gen_server:call(quod_reg:via({quod_runtime, Ns}),
                   {project_agent_work, Height, Instance, Step}, infinity).

-doc "Return current hosted process references, owned by this runtime incarnation.".
-spec agents(binary()) -> {pid(), [map()]}.
agents(Ns) -> gen_server:call(quod_reg:via({quod_runtime, Ns}), agents).

-doc "Operational counters + mode for `m:quod_metrics` and tests.".
-spec stats(binary()) -> map().
stats(Ns) ->
    try gen_server:call(quod_reg:via({quod_runtime, Ns}), get_stats, 1000)
    catch _:_ -> #{} end.

-doc "Return processed canonical input height for the existing effect owner.".
-spec effect_frontier(binary()) -> {ok, non_neg_integer()} | {error, unavailable}.
effect_frontier(Ns) when is_binary(Ns), byte_size(Ns) > 0 ->
    case quod_reg:where({quod_runtime, Ns}) of
        undefined -> {error, unavailable};
        Pid ->
            try gen_server:call(Pid, effect_frontier, 1000)
            catch exit:_ -> {error, unavailable}
            end
    end;
effect_frontier(_Ns) ->
    {error, unavailable}.

-doc "Observe current resource owners; unchanged readiness does not repeat selection.".
reconcile_now(Ns) ->
    gen_server:cast(quod_reg:via({quod_runtime, Ns}), reconcile_now).

%% Only the matching worker may borrow current actor bindings.
-spec reaction_agents(binary(), domain | {recovery, pid(), pos_integer(), map()}) -> [map()].
reaction_agents(Ns, Audience) ->
    gen_server:call(quod_reg:via({quod_runtime, Ns}), {reaction_agents, Audience}, infinity).

%%%===================================================================
%%% gen_server
%%%===================================================================

init({Ns, Config}) ->
    %% Supervised shutdown must run terminate/2. Links also stop owned workers
    %% on an untrappable runtime kill; monitors retain result/error correlation.
    process_flag(trap_exit, true),
    %% Subscribe BEFORE the (deferred) attach attempt: any ready edge published after the
    %% attach answer lands in our mailbox, so the boot race has no window.
    true = quod_reg:subscribe({runtime, Ns}),
    true = quod_reg:subscribe({node_actor, node}),
    PrologMonitor = quod_reg:monitor_name({quod_prolog, Ns}, follow),
    Owners = monitor_resource_owners(Ns),
    {ok, #s{ns = Ns, config = Config, prolog_monitor = PrologMonitor,
            resource_owners = Owners, node_identity = quod_node_actor:principal()},
     {continue, try_attach}}.

%% The restart-while-ready case: a runtime-only restart sees no ready edge (the KB is already
%% live), so probe once here. `infinity` deliberately — a bounded call into a replay-flooded
%% KB would time out and crash-loop the supervisor tail (the DA-H5 hazard); the KB answers
%% `not_ready` cheaply once the call is served, and the ready edge does the rest.
handle_continue(try_attach, S = #s{mode = booting}) ->
    case safe_attach(S#s.ns) of
        {ok, Est, H, Binding} -> {noreply, start_reconcile(boot, Est, H, S#s{binding = Binding})};
        {error, not_ready} -> {noreply, S}
    end;
handle_continue(try_attach, S) ->
    {noreply, S}.

handle_call({reconcile_resource, MinHeight, Resource, Scope, Deadline}, From, S = #s{mode = live}) ->
    case lists:member(Resource, [agent_hosts, agent_observers, node_ontologies,
                                effect_custody, agent_work, agent_custody])
         andalso valid_resource_scope(Resource, Scope, S)
         andalso is_integer(MinHeight) andalso MinHeight >= 0
         andalso quod_wire_term:is_ground(Scope) andalso is_integer(Deadline)
         andalso Deadline > quod_time:mono_ms() of
        true ->
            case S#s.queue_len < max_queued_events(S) of
                true ->
                    {Caller, _} = From,
                    Monitor = monitor(process, Caller, [{tag, resource_caller_down}]),
                    Item = {resource, MinHeight, Resource, Scope, Deadline, From, Monitor},
                    {noreply, maybe_run_events(S#s{queue = [Item | S#s.queue],
                                                   queue_len = S#s.queue_len + 1})};
                %% The refused goal is not replayed. Capacity loss of a
                %% committed-state service still owes normal readiness, just
                %% like canonical input overflow; recover from current truth.
                false -> {reply, {error, overloaded}, overflow_collapse(S)}
            end;
        false -> {reply, {error, invalid_resource_request}, S}
    end;
handle_call({reconcile_resource, _, _, _, _}, _From, S) ->
    {reply, {error, not_ready}, S};
handle_call({project_agent_observers, all, []}, {Caller, _},
            S = #s{runner = {resource, Caller, _, _, _}, observer = none}) ->
    {reply, ok, S};
handle_call({project_agent_observers, Scope, Rows}, {Caller, _},
            S = #s{runner = {resource, Caller, _, _, _}, observer = Existing, config = Config}) ->
    Observer = case Existing of
        none -> quod_agent_observer:new(maps:get(node_id, Config));
        _ -> Existing
    end,
    case quod_agent_observer:project(Scope, Rows, Observer) of
        {ok, Installed} ->
            {reply, ok, install_observer(Observer, Installed, Scope, [], S)};
        {blocked, capacity, Installed, Refused} ->
            {reply, {blocked, capacity}, install_observer(Observer, Installed, Scope, Refused, S)};
        {error, _} = Error ->
            case Existing of none -> quod_agent_observer:stop(Observer); _ -> ok end,
            {reply, Error, S}
    end;
handle_call({project_agent_observers, _, _}, _From, S) ->
    {reply, {error, stale_resource_owner}, S};
handle_call({resource_selected, Key, Basis}, {Caller, _},
            S = #s{runner = {resource, Caller, _, _, _}}) ->
    %% Canonical input may have arrived while the worker read its pinned view.
    %% Record dependencies before installation so the next applied delta also
    %% invalidates a result racing this check.
    Next = case Key of
        agent_recovery -> S;
        agent_custody -> S;
        _ ->
            Kept = case {Key, S#s.resource_waiter} of
                {{agent_work, _}, _} ->
                    maps:merge(maps:get(Key, S#s.resource_basis, #{}), Basis);
                {_, {{internal, _}, _}} -> Basis;
                _ -> maps:merge(maps:get(Key, S#s.resource_basis, #{}), Basis)
            end,
            S#s{resource_basis = (S#s.resource_basis)#{Key => Kept}}
    end,
    Checked = case Key of
        {agent_work, _} -> maps:get(Key, Next#s.resource_basis);
        _ -> Basis
    end,
    Changes = queued_resource_changes(S#s.queue, S#s.height),
    case map_size(Changes) > 0 andalso quod_resource_basis:affected(Checked, Changes) of
        true when Key =:= agent_recovery; Key =:= agent_custody ->
            {reply, {error, selection_superseded}, Next};
        true -> {reply, {error, selection_superseded}, queue_resource_key(Key, changed, Next)};
        false -> {reply, ok, Next}
    end;
handle_call({resource_selected, _, _}, _From, S) ->
    {reply, {error, stale_resource_owner}, S};
handle_call({deliver_recovery, Batch, Event, Metadata = #{deadline := Deadline}, Expiry}, {Caller, _},
            S = #s{runner = {resource, Caller, _, _, _}, recovery_pending = none,
                   observer = Observer, binding = #{identity := Identity}}) ->
    Node = maps:get(observer, Metadata),
    {agent_instance_ref, NodeNs, _, _} = Node,
    Mono = quod_time:mono_ms(),
    Bound = min(Deadline, Mono + Expiry - quod_time:now_ms()),
    case {quod_agent_observer:current(Batch, Observer), local_node_reference(),
          quod_reg:where({quod_runtime, NodeNs}), Bound > Mono} of
        {true, Node, Owner, true} when is_pid(Owner) ->
            Token = make_ref(), Monitor = monitor(process, Owner, [{tag, recovery_owner_down}]),
            Timer = erlang:start_timer(Bound, self(), {recovery_expired, Token}, [{abs, true}]),
            Evidence = Metadata#{deadline => Bound, evidence => maps:without([bindings], Batch)},
            Owner ! {owned_recovery, self(), Identity, Token, Event, Evidence, Expiry},
            {reply, ok, S#s{recovery_pending = {Owner, Token, Monitor, Timer}}};
        _ -> {reply, {error, stale_observation}, S}
    end;
handle_call({deliver_recovery, _, _, _, _}, _From, S) ->
    {reply, {error, stale_resource_owner}, S};
handle_call(agents, _From, S) ->
    {reply, {self(), [maps:with([binding, pid], A) || A = #{stopping := false} <- maps:values(S#s.agents)]}, S};
handle_call({reaction_agents, Audience}, {Caller, _},
            S = #s{runner = {events, Caller, _, _, _},
                   binding = #{request_timeout_ms := Timeout}}) ->
    {Bindings, Next} = audience_bindings(Audience, S),
    {reply, [B#{request_timeout_ms => Timeout} || B <- Bindings], Next};
handle_call({reaction_agents, _}, _From, S) -> {reply, [], S};
handle_call({project_agents, Scope, Hosts}, From = {Caller, _},
            S = #s{runner = {resource, Caller, _, _, _}, binding = #{identity := Identity}}) ->
    case agent_projection(Identity, Scope, Hosts, S) of
        {ok, Slots, Desired} ->
            Installed = install_agents(Slots, Desired,
                         S#s{agent_capacity_blocked = Scope =/= all andalso S#s.agent_capacity_blocked}),
            Reply = case Installed#s.agent_capacity_refusals > S#s.agent_capacity_refusals of
                true -> {blocked, capacity}; false -> ok end,
            case agent_retirements(Slots, Installed#s.agents) of
                Waiting when map_size(Waiting) > 0 ->
                    {noreply, Installed#s{agent_projection_waiter = {From, Waiting, Reply}}};
                _ -> {reply, Reply, Installed}
            end;
        {error, _} = Error -> {reply, Error, S}
    end;
handle_call({project_agents, _, _}, _From, S) ->
    {reply, {error, stale_resource_owner}, S};
handle_call({agent_request, H, Executor, Mode, Goal, {Expires, Deadline}},
            {Caller, _}, S = #s{runner = {events, Caller, _, _, _}}) ->
    case request_executor(Executor, S) of
        {ok, Slot, Agent, S1} ->
            case enqueue_agent_request(Slot, Agent, H, {Mode, Goal, Expires, Deadline}, S1) of
                {ok, _Ref, Next} -> {reply, ok, Next};
                {error, Reason} -> {reply, {error, Reason}, S1}
            end;
        {error, Reason, S1} -> {reply, {error, Reason}, S1}
    end;
handle_call({agent_request, _, _, _, _, _}, _From, S) ->
    {reply, {error, stale_executor}, S};
handle_call({project_agent_work, H, Instance, Step}, {Caller, _},
            S = #s{runner = {resource, Caller, _, _, _}}) ->
    {Reply, Next} = project_work(H, {agent, Instance}, Step, S),
    {reply, Reply, Next};
handle_call({project_agent_work, _, _, _}, _From, S) ->
    {reply, {error, stale_projection}, S};
handle_call(get_stats, _From, S) ->
    {reply, maps:merge(quod_agent_observer:stats(S#s.observer),
             #{mode => mode_tag(S#s.mode), height => S#s.height,
              runner_active => S#s.runner =/= none,
              subscriptions_active => length(S#s.subscriptions),
              reactions_active => length(S#s.reactions),
              source_targets_active => map_size(S#s.source_interests),
              source_interests_active =>
                  lists:sum(
                    [lists:sum([length(Is) || Is <- maps:values(Index)])
                     || Index <- maps:values(S#s.source_interests)]),
              source_views_active => map_size(S#s.source_views),
              source_views_ready => source_state_count(ready, S#s.source_views),
              source_views_building => source_state_count(building, S#s.source_views),
              source_views_unreachable =>
                  source_state_count(unreachable, S#s.source_views),
              source_attach_queued => length(S#s.source_attach_queue),
              source_attempts => S#s.source_attempts,
              p_height => S#s.p_height, e_frontier => S#s.e_frontier,
              queue_len => S#s.queue_len,
              reconciles => S#s.reconciles,
              reconcile_failures => S#s.reconcile_failures,
              hosted_agents => map_size(S#s.agents),
              hosted_agent_instances => S#s.agent_slots,
              agent_capacity_status => case S#s.agent_capacity_blocked of
                                           true -> blocked; false -> ready
                                       end,
              agent_capacity_refusals_total => S#s.agent_capacity_refusals,
              agent_pending_bytes => S#s.agent_pending_bytes,
              agent_work_idle => agent_work_count(idle, S),
              agent_work_blocked => agent_work_count(blocked, S),
              collapses => S#s.collapses,
              dropped_events => S#s.dropped_events,
              rejected_subscriptions => S#s.rejected_subscriptions,
              events_seen => S#s.events_seen,
              reaction_candidates => S#s.reaction_candidates,
              reaction_matches => S#s.reaction_matches,
              reactions_executed => S#s.reactions_executed,
              reaction_failures => S#s.reaction_failures,
              resource_dependencies => map_size(S#s.resource_basis),
              resource_failures => S#s.resource_failures}), S};
handle_call(effect_frontier, _From, S) ->
    {reply, {ok, S#s.e_frontier}, S};
handle_call(_Req, _From, S) -> {reply, {error, unknown_call}, S}.

handle_cast({runner_done, Ref, Outcome}, S = #s{runner = {Kind, _Pid, MRef, Ref, TRef}}) ->
    _ = erlang:cancel_timer(TRef),
    erlang:demonitor(MRef, [flush]),
    S1 = S#s{runner = none},
    case Kind of
        reconcile -> {noreply, reconcile_finished(Outcome, S1)};
        resource -> {noreply, resource_finished(Outcome, S1)};
        events    -> {noreply, events_finished(Outcome, S1)}
    end;
handle_cast({runner_done, _StaleRef, _Outcome}, S) ->
    {noreply, S};
handle_cast(reconcile_now, S) ->
    {noreply, owner_wake(refresh_resource_owners(S))};
handle_cast(_Msg, S) -> {noreply, S}.

%% A ready edge: the KB finished a rebuild (Id = RecoveryId, or `boot` for the quiet first
%% ready transition). Reconcile exactly once per edge; a `boot` edge counts only while booting.
handle_info({replay_ready, boot, _H}, S = #s{mode = booting}) ->
    {noreply, replace_snapshot_and_reconcile(boot, S)};
handle_info({replay_ready, boot, _H}, S) ->
    {noreply, S};
handle_info({replay_ready, Id, _H}, S = #s{last_recovery = Id}) ->
    {noreply, S};
handle_info({replay_ready, Id, _H}, S = #s{runner = {_, _, _, _, _}}) ->
    {noreply, S#s{pending_edge = Id}};
handle_info({replay_ready, Id, _H}, S) ->
    {noreply, replace_snapshot_and_reconcile(Id, S)};
handle_info({replay_started, Id, _From}, S = #s{mode = {replaying, Id}}) ->
    {noreply, S};
handle_info({replay_started, Id, _From}, S) ->
    %% Stop every old-snapshot reader. Keep their monitors until DOWN and only then tell
    %% quod_prolog to release the MVCC pin; queued state is covered by the ready reconciliation.
    {noreply, begin_replay(Id, S)};
handle_info(
  {quod_foreign_follow, FollowRef, NoticeRef, Identity, Notice}, S0) ->
    {noreply, handle_source_notice(
                FollowRef, NoticeRef, Identity, Notice, S0)};
handle_info({source_follow_attach, Token},
            S0 = #s{source_attach_token = Token}) ->
    {noreply,
     run_source_attach(S0#s{source_attach_token = none})};
handle_info({source_follow_attach, _StaleToken}, S) ->
    {noreply, S};
handle_info({gproc, registered, MRef, _Name}, S = #s{prolog_monitor = MRef}) ->
    {noreply, owner_wake(S)};
handle_info({gproc, unreg, MRef, _Name}, S = #s{prolog_monitor = MRef}) ->
    {noreply, owner_pending(S)};
handle_info(
  {gproc, registered, MRef, _Name},
  S = #s{foreign_log_monitor = MRef}) ->
    {noreply, queue_waiting_source_views(S)};
handle_info(
  {gproc, unreg, MRef, _Name},
  S = #s{foreign_log_monitor = MRef}) ->
    {noreply, foreign_log_down(S)};
handle_info({gproc, Status, Ref, _Name}, S = #s{resource_owners = Owners})
  when (Status =:= registered orelse Status =:= unreg), is_map_key(Ref, Owners) ->
    {noreply, refresh_node_identity(refresh_resource_owner(Ref, S))};
%% The direct post-commit envelope (est-carrying): the ordered tier's input. Enqueue in
%% arrival (= height) order; overflow collapses to one reconciliation at the newest snapshot.
handle_info({runtime_snapshot_advanced, Owner, H, Est},
            S = #s{binding = #{owner := Owner}, height = Before}) when is_integer(H), H > Before ->
    {noreply, enqueue_committed({snapshot, H, Est}, S)};
handle_info({runtime_snapshot_advanced, _Owner, _H, _Est}, S) ->
    {noreply, S};
handle_info({applied_live, Env, Est}, S = #s{mode = live}) ->
    {noreply, enqueue_committed({local, Env, Est}, S#s{events_seen = S#s.events_seen + 1})};
handle_info({applied_live, Env, Est}, S = #s{mode = {reconciling, _}}) ->
    {noreply, enqueue_committed({local, Env, Est}, S#s{events_seen = S#s.events_seen + 1})};
handle_info({applied_live, Env, _Est}, S = #s{mode = {unhealthy, _}}) ->
    Next = S#s{events_seen = S#s.events_seen + 1,
               dropped_events = S#s.dropped_events + 1},
    case maps:get(runtime_catalog, Env, keep) of
        keep -> {noreply, Next};
        _ -> {noreply, replace_snapshot_and_reconcile({catalog, make_ref()}, Next)}
    end;
handle_info({applied_live, _Env, _Est}, S) ->
    %% booting/replaying/unhealthy: the next reconcile rebuilds from a newer snapshot anyway
    {noreply, owner_wake(S#s{events_seen = S#s.events_seen + 1,
                               dropped_events = S#s.dropped_events + 1})};
%% Property copies (est-free applied/rejected): the explorer's feed, not ours — the direct
%% 3-tuple above is our only event channel (the double-delivery contract). While
%% the owner is unavailable, a publication is also a genuine readiness wake.
handle_info({applied_live, _Env}, S) -> {noreply, owner_wake(S)};
handle_info({rejected_live, _Env}, S) -> {noreply, S};
handle_info({projection_advanced, _Owner, _H}, S) ->
    {noreply, owner_wake(S)};
handle_info({node_actor_installed, Owner, Principal}, S) when is_pid(Owner) ->
    case {quod_reg:where({namespace_manager, node}), quod_node_actor:principal()} of
        {Owner, Principal} ->
            {noreply, refresh_resource_owners(S)};
        _ -> {noreply, S}
    end;
handle_info({node_hosting_invalidated, Owner}, S) when is_pid(Owner) ->
    %% A changed system projection can invalidate node hosting at the same
    %% ontology height. This explicit owner notice is not duplicate readiness.
    case quod_reg:where({namespace_manager, node}) of
        Owner -> {noreply, wake_node_projection(S)};
        _ -> {noreply, S}
    end;
handle_info({owned_recovery, Source, {Ns, Anchor}, Token, Event,
             Metadata = #{target := {agent_instance_ref, Ns, Anchor, _},
                          observer := {agent_instance_ref, NodeNs, _, _} = Node,
                          deadline := Deadline}, Expiry}, S) ->
    %% Only the current source owner can deliver this private observation. No
    %% Prolog term, remote publication or editable selector creates this envelope.
    case quod_reg:where({quod_runtime, Ns}) =:= Source andalso
         S#s.ns =:= NodeNs andalso local_node_reference() =:= Node andalso
         Expiry > quod_time:now_ms() andalso Deadline > quod_time:mono_ms() andalso
         lists:member(mode_tag(S#s.mode), [booting, reconciling, live]) andalso
         S#s.queue_len < max_queued_events(S) of
        true ->
            Item = {owned_recovery, Source, Token, Event, Metadata, Expiry},
            {noreply, maybe_run_events(S#s{queue = [Item | S#s.queue], queue_len = S#s.queue_len + 1})};
        false -> Source ! {recovery_consumed, self(), Token}, {noreply, S}
    end;
handle_info({recovery_consumed, Owner, Token},
            S = #s{recovery_pending = {Owner, Token, _, _}}) ->
    {noreply, maybe_run_events(clear_recovery_pending(S))};
handle_info({recovery_owner_down, Monitor, process, Owner, _},
            S = #s{recovery_pending = {Owner, _, Monitor, _}}) ->
    {noreply, maybe_run_events(clear_recovery_pending(S))};
handle_info({timeout, Timer, {recovery_expired, Token}},
            S = #s{recovery_pending = {_, Token, _, Timer}}) ->
    %% The original deadline releases only this unsent-evidence cursor. It
    %% neither cancels an admitted operation nor authorizes resubmission.
    {noreply, maybe_run_events(clear_recovery_pending(S))};
handle_info({agent_work_custody, Owner, Token, Pending}, S) when is_map(Pending) ->
    Next = maps:fold(fun(Slot, #{stopping := false,
                         work := Work = #{custody_owner := Owner0,
                                           status := {custody_query, Token0}}}, Acc)
                          when Owner0 =:= Owner, Token0 =:= Token ->
                        W = Work#{prior => Pending,
                                  status => case map_size(Pending) of 0 -> ready; _ -> custody end},
                        Updated = put_agent_work(Slot, W, Acc),
                        case map_size(Pending) of
                            0 -> queue_agent_work(Slot, W, Updated);
                            _ -> Updated
                        end;
                       (_, _, Acc) -> Acc
                    end, S, S#s.agents),
    {noreply, maybe_run_events(Next)};
handle_info({agent_work_custody_changed, Owner, Groups}, S) ->
    Next = maps:fold(fun(Slot, Agent = #{stopping := false,
                         work := Work = #{custody_owner := Owner0, status := custody,
                                           prior := Prior}}, Acc) when Owner0 =:= Owner ->
                        case lists:any(fun(Id) -> maps:is_key(Id, Prior) end, Groups) of
                            true -> query_agent_work_custody(Slot, Agent, Work, Acc);
                            false -> Acc
                        end;
                       (_, _, Acc) -> Acc
                    end, S, S#s.agents),
    {noreply, Next};
handle_info({agent_completed, Instance, Pid, Ref}, S = #s{agents = Agents}) ->
    case maps:get(Instance, Agents, none) of
        Agent = #{pid := Pid, pending := Pending} ->
            case maps:take(Ref, Pending) of
                {Bytes, Rest} ->
                    Next = S#s{agents = Agents#{Instance => Agent#{pending => Rest}},
                               agent_pending_bytes = S#s.agent_pending_bytes - Bytes},
                    %% Waiting projections get the released capacity before
                    %% the completing agent offers its next work item.
                    {noreply, maybe_run_events(finish_agent_work(
                                                Instance, Ref, wake_work_capacity(Next)))};
                error -> {noreply, S}
            end;
        _ -> {noreply, S}
    end;
handle_info({{agent_down, Instance}, Monitor, process, Pid, _Reason}, S) ->
    {noreply, maybe_run_events(agent_down(Instance, Pid, Monitor, S))};
handle_info({'DOWN', MRef, process, Pid, Reason},
            S = #s{runner = {Kind, Pid, MRef, _Ref, TRef}}) ->
    %% runner died without reporting (crash or budget kill)
    _ = erlang:cancel_timer(TRef),
    S1 = S#s{runner = none},
    case Kind of
        reconcile -> {noreply, reconcile_finished({error, {runner_down, Reason}}, S1)};
        resource -> {noreply, resource_finished({interrupted, {error, {resource_worker_down, Reason}}}, S1)};
        events    -> {noreply, events_finished({error, {runner_down, Reason}}, S1)}
    end;
handle_info({resource_caller_down, Monitor, process, _Caller, _},
            S = #s{resource_waiter = {_From, Monitor}, runner = {resource, Pid, _, _, _}}) ->
    exit(Pid, kill),
    {noreply, S};
handle_info({resource_caller_down, Monitor, process, _Caller, _}, S) ->
    {noreply, retain_queue(fun({resource, _, _, _, _, _, M}) -> M =/= Monitor;
                              (_) -> true end, S)};
handle_info({runner_kill, Ref}, S = #s{runner = {_Kind, Pid, _MRef, Ref, _TRef}}) ->
    exit(Pid, kill),   %% the DOWN above reports the failure
    {noreply, S};
handle_info({collapse_retry, Ref}, S = #s{last_recovery = {collapse, Ref}}) ->
    {noreply, attach_and_reconcile({collapse, make_ref()}, S)};
handle_info({'EXIT', _Worker, _Reason}, S) ->
    %% DOWN owns worker completion; gen_server handles the supervisor's exit.
    {noreply, S};
handle_info(Info, S = #s{observer = Observer}) when Observer =/= none ->
    {Next, Events} = quod_agent_observer:handle(Info, Observer),
    {noreply, queue_observations(Events, S#s{observer = Next})};
handle_info(_Info, S) -> {noreply, S}.

%% A dying server must not orphan its workers: unmonitored+unbudgeted (the kill timers die
%% with us), an orphan executing a looping goal would burn a scheduler unbounded while its
%% snapshot pin is released out from under it.
terminate(_Reason, S) ->
    _ = stop_source_views(kill_runner(S)),
    maps:foreach(fun(Ref, {Key, _Owner}) ->
        ok = quod_reg:demonitor_name(Key, Ref)
    end, S#s.resource_owners),
    ok = quod_reg:demonitor_name({quod_prolog, S#s.ns}, S#s.prolog_monitor).

%%%===================================================================
%%% reconciliation
%%%===================================================================

attach_and_reconcile(Id, S) ->
    case safe_attach(S#s.ns) of
        {ok, Est, H, Binding} ->
            start_reconcile(Id, Est, H, S#s{binding = Binding});
        {error, not_ready} ->
            %% raced a new rebuild — we are again awaiting a ready edge, and its arrival
            %% (clauses above) will retry; reflect that instead of a stale mode
            S#s{mode = booting}
    end.

%% A ready edge replaces the snapshot generation. Quiesce every reader first,
%% replay_started normally does this earlier, but the
%% ready boundary is independently safe if a start notification was delayed or
%% lost. Awaiting every DOWN before attach prevents the new MVCC pin from
%% invalidating an old worker's view.
replace_snapshot_and_reconcile(Id, S = #s{mode = booting, est = undefined, runner = none}) ->
    %% There is no previous reader to retire. Preserve evidence received by
    %% this incarnation while its first committed snapshot was unavailable.
    attach_and_reconcile(Id, S#s{pending_edge = none});
replace_snapshot_and_reconcile(Id, S) ->
    attach_and_reconcile(
      Id, (kill_runner(S))#s{pending_edge = none}).

%% attach_runtime is a call into a sibling that may be crashing/restarting right now; that
%% is indistinguishable from "not ready" for our purposes, and crashing here would burn
%% supervisor restart intensity for nothing (rest_for_one restarts us with the KB anyway).
safe_attach(Ns) ->
    try quod_prolog:attach_runtime(Ns)
    catch exit:_ -> {error, not_ready}
    end.

%% Snapshot discovery, validation and convergence run in the bounded worker.
%% Reconciliation reads current clauses, never the ledger or a founding catalogue.
start_reconcile(Id, Est, H, S0 = #s{ns = Ns, binding = Binding}) ->
    S = S0#s{est = Est, height = H, last_recovery = Id, pending_edge = none,
             mode = {reconciling, Id}, resource_basis = #{}, resource_failures = #{}},
    Budget = application:get_env(quod, runtime_reconcile_budget_ms, ?RECONCILE_BUDGET_MS),
    spawn_runner(reconcile, Budget,
                 fun(_Deadline) -> run_reconcile(Ns, Binding, Est, H) end, S).

spawn_runner(Kind, Budget, Fun, S) ->
    Server = self(),
    Ref = make_ref(),
    Deadline = erlang:monotonic_time(millisecond) + Budget,
    {Pid, MRef} = spawn_opt(fun() ->
        gen_server:cast(Server, {runner_done, Ref, Fun(Deadline)})
    end, [link, monitor]),
    TRef = erlang:send_after(max(0, Deadline - erlang:monotonic_time(millisecond)),
                            self(), {runner_kill, Ref}),
    S#s{runner = {Kind, Pid, MRef, Ref, TRef}}.

run_reconcile(_Ns, Binding, Est, _H) ->
    case stored_runtime_catalog(Est) of
        {ok, Catalog} ->
            case plan_runtime_catalog(Catalog) of
                {ok, Plan} -> {ok, Binding, Plan};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

reconcile_finished({ok, Binding, Plan}, S) ->
    case binding_live(Binding) of
        true -> reconcile_publish(Plan, S);
        false -> owner_pending(S)
    end;
reconcile_finished({error, Reason}, S0 = #s{ns = Ns}) ->
    S1 = S0#s{reconcile_failures = S0#s.reconcile_failures + 1},
    case S1#s.pending_edge of
        none ->
            case config_error(Reason) of
                true  -> unhealthy(Reason, S1);
                false -> execution_failure({reconcile_failed, Reason}, S1)
            end;
        Id ->
            %% a newer ready edge arrived mid-run: its fresh state is the retry we would
            %% otherwise wait for — use it now instead of parking unhealthy
            logger:warning("quod_runtime[~s]: reconcile failed (~0p); retrying with the "
                           "newer ready edge", [Ns, Reason]),
            replace_snapshot_and_reconcile(Id, S1)
    end.

reconcile_publish(Plan, S0 = #s{height = H}) ->
    Base = S0#s{p_height = H, e_frontier = H, reconciles = S0#s.reconciles + 1,
                exec_failures = 0},
    S1 = install_catalog_update(Plan, Base),
    _ = reconcile_direct_effects(),
    case S1#s.pending_edge of
        none -> queue_ready(ontology, all, drop_stale_queue(release_hosting(S1#s{mode = live})));
        Id -> replace_snapshot_and_reconcile(Id, S1)
    end.

owner_wake(S = #s{mode = booting}) ->
    replace_snapshot_and_reconcile({owner, make_ref()}, S);
owner_wake(S) -> S.

%% Only independently supervised resource owners need replacement monitors.
%% The namespace simplex already fate-shares with Prolog/runtime through
%% rest_for_one; that restart also reconstructs each finite agent-work pass.
monitor_resource_owners(Ns) ->
    Keys = [{namespace_manager, node}] ++
        case Ns of <<"quod:root">> -> [{quod_effect_journal, node}]; _ -> [] end,
    maps:from_list([begin
        Ref = quod_reg:monitor_name(Key, follow),
        {Ref, {Key, quod_reg:where(Key)}}
    end || Key <- Keys]).

refresh_resource_owners(S) ->
    Next = lists:foldl(fun refresh_resource_owner/2, S, maps:keys(S#s.resource_owners)),
    refresh_node_identity(Next).

refresh_resource_owner(Ref, S = #s{resource_owners = Owners}) ->
    {Key, Before} = maps:get(Ref, Owners),
    case quod_reg:where(Key) of
        Before -> S;
        Owner ->
            Next = S#s{resource_owners = Owners#{Ref => {Key, Owner}}},
            case is_pid(Owner) andalso S#s.mode =:= live of
                false -> Next;
                true ->
                    case Key of
                        {namespace_manager, node} -> wake_node_projection(Next);
                        {quod_effect_journal, node} -> queue_ready(effect_custody, all, Next)
                    end
            end
    end.

refresh_node_identity(S = #s{node_identity = Before}) ->
    case quod_node_actor:principal() of
        %% A reaction can install the node queue before its identity notice is
        %% processed. Deduplication must still reconcile that owned handle.
        Before when S#s.mode =:= live -> refresh_node_executor(S);
        Before -> S;
        Principal ->
            Next = S#s{node_identity = Principal},
            case S#s.mode of
                live -> wake_node_projection(queue_observer_reconcile(
                          queue_agent_reconcile(refresh_node_executor(Next))));
                _ -> Next
            end
    end.

wake_node_projection(S = #s{mode = live}) ->
    case node_scope(local_node_reference(), S) of
        true -> queue_ready(node_ontologies, all, S);
        false -> S
    end;
wake_node_projection(S) -> S.

owner_pending(S0) ->
    S = kill_runner(stop_source_views(S0)),
    ok = quod_prolog:runtime_detach(S#s.ns),
    drop_queue(S#s{mode = booting, binding = none, pending_edge = none,
                   last_recovery = undefined,
                   est = undefined}).

binding_live(#{owner := Owner, identity := {Ns, _}}) ->
    Owner =:= quod_reg:where({quod_prolog, Ns}) andalso is_process_alive(Owner);
binding_live(_) -> false.

reconcile_direct_effects() ->
    quod_effect_journal:reconcile().

%% Malformed current declarations fail loudly; execution failures retain the
%% existing collapse and backoff policy.
config_error({invalid_reaction, _}) -> true;
config_error(invalid_runtime_catalog) -> true;
config_error(_)                         -> false.

unhealthy(Reason, S = #s{ns = Ns}) ->
    %% Malformed declarations cannot dispatch work. Stop the owned reader and
    %% resources before releasing queued callers and subscriptions.
    logger:error("quod_runtime[~s]: unhealthy: ~0p", [Ns, Reason]),
    S1 = stop_source_views(kill_runner(S)),
    drop_queue(S1#s{mode = {unhealthy, Reason}}).

mode_tag(M) when is_atom(M) -> M;
mode_tag(M)                 -> element(1, M).

%%%===================================================================
%%% the ordered tier — live event batches
%%%===================================================================

%% Canonical transactions and their block-final snapshot advances share one
%% ordered input. A control-only block changes no reactions or declarations,
%% but its height must release readers awaiting that committed snapshot.
enqueue_committed(Item, S = #s{mode = live}) ->
    case S#s.queue_len < max_queued_events(S) of
        true -> maybe_run_events(S#s{queue = [Item | S#s.queue], queue_len = S#s.queue_len + 1});
        false -> overflow_collapse(S)
    end;
enqueue_committed(Item, S = #s{mode = {reconciling, _}}) ->
    case S#s.queue_len < max_queued_events(S) of
        true -> S#s{queue = [Item | S#s.queue], queue_len = S#s.queue_len + 1};
        false ->
            Pending = case S#s.pending_edge of none -> {collapse, make_ref()}; Id -> Id end,
            drop_queue(S#s{pending_edge = Pending, collapses = S#s.collapses + 1})
    end;
enqueue_committed(_Item, S) -> S.

maybe_run_events(S = #s{mode = live, runner = none, queue = Q}) when Q =/= [] ->
    {Items, Remaining, Turn, Dropped} = ready_work(lists:reverse(Q), S),
    Pending = S#s{queue = lists:reverse(Remaining), queue_len = length(Remaining),
                 owned_turn = Turn, dropped_events = S#s.dropped_events + Dropped},
    case Items of
        [] -> Pending;
        [{recovery_selection, Batch, Event, Expiry} | Rest] ->
            #{identity := Identity, request_timeout_ms := Timeout} = S#s.binding,
            Mono = quod_time:mono_ms(), Now = quod_time:now_ms(),
            Ceiling = min(Expiry, Now + Timeout),
            Deadline = Mono + max(0, Ceiling - Now),
            Scope = {Identity, Batch, Event, Ceiling, Deadline},
            Request = {resource, S#s.height, agent_recovery, Scope, Deadline,
                       {internal, agent_recovery}, none},
            start_resource(Request, prepend_ready_work(Rest, Pending));
        [{recovery_done, Source, Token} | Rest] ->
            Source ! {recovery_consumed, self(), Token},
            maybe_run_events(prepend_ready_work(Rest, Pending));
        [{resource, _, _, _, _, _, _} = Request | Rest] ->
            start_resource(Request, prepend_ready_work(Rest, Pending));
        [{resource_cursor, Requests, Notify} | Rest] ->
            drain_resource_cursor(Requests, Notify, prepend_ready_work(Rest, Pending));
        _ ->
            {Events, Tail} = lists:splitwith(fun(Item) -> not resource_work(Item) end, Items),
            start_event_batch(Events, prepend_ready_work(Tail, Pending))
    end;
maybe_run_events(S) -> S.

prepend_ready_work(Items, S) ->
    S#s{queue = S#s.queue ++ lists:reverse(Items), queue_len = S#s.queue_len + length(Items)}.

resource_work({resource, _, _, _, _, _, _}) -> true;
resource_work({resource_cursor, _, _}) -> true;
resource_work(_) -> false.

%% A cursor occupies one ordered queue slot, independent of actor population.
%% Move its remainder behind already queued input after selecting one resource:
%% newer canonical changes must progress before repeatedly superseding a reader.
drain_resource_cursor(Requests, Notify, S = #s{height = H}) ->
    case next_resource(maps:iterator(Requests), H) of
        {Key, {MinHeight, Wake, Deadline}} ->
            Remaining = maps:remove(Key, Requests),
            Next = case map_size(Remaining) =:= 0 andalso not Notify of
                true -> S;
                false -> S#s{queue = [{resource_cursor, Remaining, Notify} | S#s.queue],
                              queue_len = S#s.queue_len + 1}
            end,
            {Resource, Scope} = resource_scope(Key, Wake),
            start_resource({resource, MinHeight, Resource, Scope, Deadline,
                            {internal, Key}, none}, Next);
        none when map_size(Requests) =:= 0, Notify ->
            %% Return the compacted notice to ordinary eligibility scheduling;
            %% resource work itself never grants an actor or bypasses capacity.
            maybe_run_events(prepend_ready_work([{observed, {ready, ontology, all}}], S))
    end.

next_resource(Iterator, Height) ->
    case maps:next(Iterator) of
        {Key, {MinHeight, _, _} = Request, _Rest} when MinHeight =< Height ->
            {Key, Request};
        {_, _, Rest} -> next_resource(Rest, Height);
        none -> none
    end.

resource_scope({agent_work, Instance}, Wake) -> {agent_work, {Instance, Wake}};
resource_scope(Resource, _) -> {Resource, all}.

start_resource({resource, _Min, Resource, Scope, Deadline, From, Monitor},
               S = #s{ns = Ns, height = H, est = Est}) ->
    Budget = min(Deadline - quod_time:mono_ms(),
                 application:get_env(quod, runtime_reconcile_budget_ms, ?RECONCILE_BUDGET_MS)),
    case Budget > 0 of
        false -> resource_finished({interrupted, {error, deadline_exceeded}},
                                    S#s{resource_waiter = {From, Monitor}});
        true -> spawn_runner(resource, Budget,
                  fun(_) -> run_resource(Ns, H, Est, Resource, Scope, Deadline, From) end,
                  S#s{resource_waiter = {From, Monitor}})
    end.

%% A terminated or unstarted selector may never report its reads. Retain a
%% conservative dependency for persistent consumers until the next committed
%% change selects again. Occurrence-bound recovery and custody are never replayed.
resource_finished({interrupted, Reply}, S = #s{resource_waiter = {From, _}}) ->
    Basis = case From of
        {internal, Key} when Key =:= agent_hosts; Key =:= agent_observers;
                             Key =:= node_ontologies; Key =:= effect_custody;
                             is_tuple(Key), tuple_size(Key) =:= 2,
                             element(1, Key) =:= agent_work ->
            (S#s.resource_basis)#{Key => quod_resource_basis:unknown()};
        _ -> S#s.resource_basis
    end,
    resource_finished(Reply, S#s{resource_basis = Basis});
resource_finished(Reply, S0 = #s{resource_waiter = {From, Monitor}}) ->
    reply_resource(From, Monitor, Reply),
    S = case From of
        {internal, Key} ->
            Failures = case Reply of
                ok -> maps:remove(Key, S0#s.resource_failures);
                {error, selection_superseded} -> S0#s.resource_failures;
                _ -> (S0#s.resource_failures)#{Key => Reply}
            end,
            S0#s{resource_failures = Failures};
        _ -> S0
    end,
    next_after_runner(release_hosting(S#s{resource_waiter = none, agent_projection_waiter = none}));
resource_finished(_Reply, S) -> next_after_runner(S).

%% Physical evidence waits for actual executor capacity. Committed advances
%% continue while it waits, so its eventual Prolog proof sees current policy.
%% Only one captured assignment is released per batch; completion, not a timer,
%% wakes the remainder. All work still uses the same ordered runner and matcher.
ready_work(Items, S) ->
    {Ready, Waiting} = lists:partition(
        fun({resource, MinHeight, _, _, _, _, _}) -> MinHeight =< S#s.height;
           ({observed_host, _}) -> S#s.recovery_pending =:= none;
           ({resource_cursor, Requests, Notify}) ->
               (map_size(Requests) =:= 0 andalso Notify) orelse
                   next_resource(maps:iterator(Requests), S#s.height) =/= none;
           (_) -> true end, Items),
    {Run, Rest, Turn, Dropped} = ready_events(Ready, S),
    {Run, Waiting ++ Rest, Turn, Dropped}.

ready_events(Items, S) ->
    {Ordinary, Owned} = lists:partition(fun(Item) -> not owned_notice(Item) end, Items),
    case {Ordinary, Owned, S#s.owned_turn, owned_capacity(S)} of
        {[_|_], [_|_], true, true} ->
            {Selected, Rest, Dropped} = take_owned_notice(Owned, S, 0),
            case Selected of
                [] -> {Ordinary, Rest, false, Dropped};
                _ -> {Selected, Ordinary ++ Rest, false, Dropped}
            end;
        {[_|_], _, _, _} -> {Ordinary, Owned, Owned =/= [], 0};
        {[], _, _, true} ->
            {Selected, Rest, Dropped} = take_owned_notice(Owned, S, 0),
            {Selected, Rest, false, Dropped};
        {[], _, _, false} -> {[], Owned, true, 0}
    end.

owned_notice({observed_host, _}) -> true;
owned_notice({owned_recovery, _, _, _, _, _}) -> true;
owned_notice({recovery_done, _, _}) -> true;
owned_notice({observed, _}) -> true;
owned_notice({owned_notice, _, _, _}) -> true;
owned_notice(_) -> false.

%% One current-state/owner observation keeps a cursor over its reaction clauses
%% in the existing queue. A single candidate needs at most one node queue slot;
%% actual completion releases the next candidate, with canonical input free to
%% progress while that slot is occupied. No accepted goal is submitted again.
take_owned_notice([], _S, Dropped) -> {[], [], Dropped};
take_owned_notice([{owned_notice, Event, Audience, [Clause | More]} | Rest], _S, Dropped) ->
    Tail = case More of [] -> Rest; _ -> [{owned_notice, Event, Audience, More} | Rest] end,
    {[{owned_reaction, Event, Audience, Clause}], Tail, Dropped};
take_owned_notice([{owned_notice, _, _, []} | Rest], S, Dropped) ->
    take_owned_notice(Rest, S, Dropped);
take_owned_notice([{observed, Event} | Rest], S, Dropped) ->
    Clauses = maps:get({observed, 1}, S#s.reaction_index, []),
    take_owned_notice([{owned_notice, {observed, Event}, domain, Clauses} | Rest], S, Dropped);
take_owned_notice([{owned_recovery, Source, Token, Event, Metadata, Expiry} | Rest], S, Dropped) ->
    Clauses = maps:get({observed, 1}, S#s.reaction_index, []),
    Done = {recovery_done, Source, Token},
    case recovery_current(Source, Metadata, Expiry, S) of
        true ->
            Audience = {recovery, Source, Expiry, Metadata#{event => Event}},
            take_owned_notice([{owned_notice, {observed, Event}, Audience, Clauses}, Done | Rest], S, Dropped);
        false -> {[Done], Rest, Dropped + 1}
    end;
take_owned_notice([{recovery_done, _, _} = Done | Rest], _S, Dropped) ->
    {[Done], Rest, Dropped};
take_owned_notice([{observed_host, Batch} = Item | Rest], S, Dropped) ->
    case take_host_observation([Item], S#s.observer, quod_time:now_ms(), 0) of
        {[], [], Count} -> take_owned_notice(Rest, S, Dropped + Count);
        {[{observed, Event, Expiry}], Remaining, Count} ->
            {[{recovery_selection, Batch, Event, Expiry}], Rest ++ Remaining, Dropped + Count}
    end.

owned_capacity(S) ->
    NodeAvailable = case maps:get(node, S#s.agents, none) of
        none -> true;
        %% The node queue is sequential. Retain the next observation
        %% in this owner's cursor until completion; pre-filling its queue lets
        %% captured work displace the committed resource reads it depends on.
        #{pending := Pending, stopping := false} -> map_size(Pending) =:= 0;
        _ -> false
    end,
    NodeAvailable andalso
        S#s.agent_pending_bytes + ?MAX_AGENT_REQUEST_BYTES =< ?MAX_AGENT_PENDING_BYTES.

%% Like queue overflow and reset, count discarded queue items: one physical
%% batch, irrespective of how many captured instance bindings remain in it.
take_host_observation([], _Observer, _Now, Dropped) -> {[], [], Dropped};
take_host_observation([{observed_host, #{at := At}} | Rest], Observer, Now, Dropped)
  when At + 60000 =< Now ->
    take_host_observation(Rest, Observer, Now, Dropped + 1);
take_host_observation([{observed_host, Batch} | Rest], Observer, Now, Dropped) ->
    case quod_agent_observer:current(Batch, Observer) of
        false -> take_host_observation(Rest, Observer, Now, Dropped + 1);
        true ->
            case quod_agent_observer:next(Batch) of
                done -> take_host_observation(Rest, Observer, Now, Dropped);
                {Event, #{bindings := []}} -> {[owned_observation(Event)], Rest, Dropped};
                {Event, Next} -> {[owned_observation(Event)], Rest ++ [{observed_host, Next}], Dropped}
            end
    end.

owned_observation(Event = {agent_host_observed, _, _, _, _, _, _, _, _, _, _, Expiry}) ->
    {observed, Event, Expiry}.

-ifdef(TEST).
%% Exercise the consumer cursor and drop accounting without a running reader
%% or a wall-clock wait. Contact currency still uses the real directory owner.
test_drain_observations(Items, Observer, Plan, OwnedTurn) ->
    {Selected, Remaining, _Turn, Dropped} = ready_work(Items,
      #s{observer = Observer, reaction_index = maps:get(reaction_index, Plan),
         owned_turn = OwnedTurn}),
    {Selected, Remaining, Dropped}.

test_recovery_pending(Pending, reset) ->
    (kill_runner(#s{recovery_pending = Pending}))#s.recovery_pending;
test_recovery_pending(Pending, Message) ->
    {noreply, Next} = handle_info(Message, #s{recovery_pending = Pending}),
    Next#s.recovery_pending.
-endif.

start_event_batch(Items, S) ->
    Work = work_items(Items),
    Per = application:get_env(quod, runtime_event_budget_ms, ?EVENT_BUDGET_MS),
    Cap = application:get_env(quod, runtime_event_budget_cap_ms, ?EVENT_BUDGET_CAP_MS),
    Budget = min(max(1, work_budget_units(Work)) * Per, Cap),
    #s{ns = Ns, reaction_index = Reactions,
       source_interests = SourceInterests, subscriptions = Subscriptions} = S,
    spawn_runner(events, Budget,
      fun(_Deadline) -> run_events(Ns, Work, Reactions, SourceInterests,
                         maps:from_keys(Subscriptions, true), S#s.height, S#s.est)
      end, S#s{event_acks = event_ack_refs(Items)}).

%% Keep transaction boundaries and their exact post-transaction catalogue.
%% The snapshot remains block-final; eligibility proofs use that snapshot.
work_items(Batch) ->
    coalesce_changed_heads(lists:map(
      fun({local, Env, Est}) ->
              {local, maps:get(height, Env, 0), Est, changed_heads(Env),
               quod_runtime_predicates:diff_to_events(maps:get(applied_ops, Env, [])),
               maps:get(effects, Env, []), maps:get(runtime_catalog, Env, keep)};
         (Item) -> Item
      end, Batch)).

%% A block-final snapshot needs one convergence per contiguous local group.
%% Keep every transaction's events and post-transaction declarations intact.
coalesce_changed_heads([{local, H, Est, Heads, Events, Effects, Catalog} | Rest]) ->
    {SameBlock, Tail} = lists:splitwith(
        fun({local, NextH, _, _, _, _, _}) -> NextH =:= H;
           (_) -> false end, Rest),
    AllHeads = lists:usort(Heads ++ lists:append(
        [Hs || {local, _, _, Hs, _, _, _} <- SameBlock])),
    [{local, H, Est, AllHeads, Events, Effects, Catalog} |
     [{local, NH, NE, [], EV, EF, C} || {local, NH, NE, _, EV, EF, C} <- SameBlock]]
    ++ coalesce_changed_heads(Tail);
coalesce_changed_heads([Item | Rest]) -> [Item | coalesce_changed_heads(Rest)];
coalesce_changed_heads([]) -> [].

work_budget_units(Work) ->
    {Count, _} = lists:foldl(
        fun({local, H, _, _, _, _, _}, {N, {local, H}}) -> {N, {local, H}};
           ({local, H, _, _, _, _, _}, {N, _}) -> {N + 1, {local, H}};
           (_, {N, _}) -> {N + 1, other}
        end, {0, none}, Work),
    Count.

work_effects(Work) ->
    [{Height, Effects}
     || {local, Height, _Est, _Heads, _Events, Effects, _Catalog} <- Work,
        Effects =/= []].

work_changes(Work) ->
    lists:usort(lists:append([Heads || {local, _, _, Heads, _, _, _} <- Work])).

queue_changes([], S) -> S;
queue_changes(Heads, S = #s{queue = Q}) ->
    {Existing, Other} = lists:partition(fun({observed, {ontology_changed, _}}) -> true;
                                         (_) -> false end, Q),
    Merged = lists:usort(Heads ++ lists:append([Hs || {observed, {ontology_changed, Hs}} <- Existing])),
    Item = {observed, {ontology_changed, Merged}},
    case length(Other) < max_queued_events(S) of
        true -> S#s{queue = [Item | Other], queue_len = length(Other) + 1};
        false -> resource_notice_overflow(S)
    end.

event_ack_refs(Items) ->
    [{FollowRef, NoticeRef}
     || {remote, FollowRef, NoticeRef, _Identity, _Publications} <- Items].

%% Dispatch T with the preceding catalogue, then activate T's exact committed
%% declarations for later transactions, including another T at the same height.
run_events(Ns, Work, Reactions, SourceInterests, Subscriptions,
           Height0, Est0) ->
    try
        {Tip, TipEst, ReactionStats, _FinalReactionIndex,
         _FinalSourceInterests, _FinalSubscriptions, CatalogUpdate} =
            lists:foldl(
              fun({local, H, Est, _Heads, Events, _Effects, After},
                  {_PrevH, _PrevEst, Stats0, Reactions0, Sources0,
                   Subscriptions0, Catalog0}) ->
                      Stats1 = dispatch_local_reactions(
                                 Ns, H, Est, Events, Reactions0, Stats0),
                      {Reactions1, Sources1, Subscriptions1, Catalog1} =
                          advance_runtime_catalog(
                            After, Reactions0, Sources0, Subscriptions0, Catalog0),
                      {H, Est, Stats1, Reactions1, Sources1,
                       Subscriptions1, Catalog1};
                 ({snapshot, H, Est},
                  {_PrevH, _PrevEst, Stats, Reactions0, Sources0, Subscriptions0, Catalog0}) ->
                      {H, Est, Stats, Reactions0, Sources0, Subscriptions0, Catalog0};
                 ({owned_reaction, Event, Audience, Clause},
                  {H, Est, Stats0, Reactions0, Sources0, Subscriptions0, Catalog0}) ->
                      Stats1 = dispatch_candidates(Ns, H, Est, Audience, Event, [Clause], Stats0),
                      {H, Est, Stats1, Reactions0, Sources0, Subscriptions0, Catalog0};
                 ({remote, _FollowRef, _NoticeRef, Identity, Publications},
                  {H, Est, Stats0, Reactions0, Sources0,
                   Subscriptions0, Catalog0}) ->
                      Stats1 =
                          case maps:is_key(Identity, Subscriptions0) of
                              true ->
                                  dispatch_remote_reactions(
                                    Ns, H, Est, Identity, Publications,
                                    Sources0, Stats0);
                              false ->
                                  reaction_stat(dropped, Stats0)
                          end,
                      {H, Est, Stats1, Reactions0, Sources0,
                       Subscriptions0, Catalog0}
              end,
              {Height0, Est0, empty_reaction_stats(), Reactions,
               SourceInterests, Subscriptions, keep}, Work),
        {ok, Tip, TipEst, work_effects(Work), CatalogUpdate,
         ReactionStats, work_changes(Work)}
    catch throw:R -> {error, R}
    end.

-ifdef(TEST).
%% Drive the real ordered fold without a gen_server race. This is deliberately
%% narrower than run_events/7: tests supply the already-derived catalogue and
%% cannot invent an alternative dispatch path.
test_run_events(Work, Plan, Height0, Est0) ->
    run_events(
      <<"runtime:test">>, Work,
      maps:get(reaction_index, Plan), maps:get(source_interests, Plan),
      maps:from_keys(maps:get(subscriptions, Plan), true),
      Height0, Est0).
-endif.

advance_runtime_catalog(keep, ReactionIndex, SourceInterests, Subscriptions, CatalogUpdate) ->
    {ReactionIndex, SourceInterests, Subscriptions, CatalogUpdate};
advance_runtime_catalog({ok, StoredCatalog}, _, _, _, _) ->
    case plan_runtime_catalog(StoredCatalog) of
        {ok, Plan} ->
            {maps:get(reaction_index, Plan), maps:get(source_interests, Plan),
             maps:from_keys(maps:get(subscriptions, Plan), true), Plan};
        {error, Reason} -> throw(Reason)
    end;
advance_runtime_catalog({error, Reason}, _, _, _, _) ->
    throw({discovery_failed, Reason}).

empty_reaction_stats() ->
    #{candidates => 0, matches => 0, executed => 0,
      failures => 0, dropped => 0}.

dispatch_local_reactions(_Ns, _Height, _Est, [], _Index, Stats) ->
    Stats;
dispatch_local_reactions(Ns, Height, Est, [{observed, _} | Rest], Index, Stats0) ->
    %% Committed user content cannot mint local owner evidence and borrow a
    %% node observer's signing authority. Only the observed tier unwraps this
    %% reserved outer vocabulary into the common Prolog matcher.
    dispatch_local_reactions(Ns, Height, Est, Rest, Index,
                             reaction_stat(dropped, Stats0));
dispatch_local_reactions(Ns, Height, Est, [Event | Rest], Index, Stats0) ->
    Candidates = maps:get(functor_key(Event), Index, []),
    Stats1 = dispatch_candidates(
               Ns, Height, Est, domain, Event, Candidates, Stats0),
    dispatch_local_reactions(Ns, Height, Est, Rest, Index, Stats1).

dispatch_remote_reactions(_Ns, _Height, _Est, _Identity, [],
                          _SourceInterests, Stats) ->
    Stats;
dispatch_remote_reactions(Ns, Height, Est, Identity,
                          [{_SourceHeight, AppliedOps} | Rest],
                          SourceInterests, Stats0) ->
    Index = maps:get(Identity, SourceInterests, #{}),
    Stats1 = lists:foldl(
               fun(Event, Acc) ->
                       Candidates = maps:get(functor_key(Event), Index, []),
                       dispatch_candidates(
                         Ns, Height, Est, domain,
                         source_event(Identity, Event), Candidates, Acc)
               end, Stats0,
               quod_runtime_predicates:diff_to_events(AppliedOps)),
    dispatch_remote_reactions(
      Ns, Height, Est, Identity, Rest, SourceInterests, Stats1).

functor_key(Head) when is_atom(Head) -> {Head, 0};
functor_key(Head) when is_tuple(Head) -> {element(1, Head), tuple_size(Head) - 1}.

source_event({TargetNs, Anchor}, Event) ->
    {from, TargetNs, Anchor, Event}.

%% Local and subscribed occurrences enter this one continuation. Erlang only
%% narrows candidates; unification and goal selection stay in Prolog.

dispatch_candidates(Ns, Height, Est, Audience, Event, Candidates, Stats0) ->
    Agents = case Candidates of [] -> []; _ -> reaction_agents(Ns, Audience) end,
    lists:foldl(fun(Reaction, Acc0) ->
        lists:foldl(fun(Owner, Acc) ->
            dispatch_reaction(Ns, Height, Est, Owner, Event, Reaction, Acc)
        end, Acc0, Agents)
    end, Stats0, Candidates).

dispatch_reaction(Ns, Height, Est, Owner, Event, Reaction, Acc0) ->
    Acc1 = reaction_stat(candidates, Acc0),
    Started = erlang:monotonic_time(microsecond),
    Result = quod_runtime_predicates:run_reaction(
               Ns, Height, Owner, Reaction, Event, Est),
    Elapsed = erlang:monotonic_time(microsecond) - Started,
    ok = quod_metrics:observe_runtime_reaction(Ns, Result, Elapsed),
    case Result of
        unmatched -> Acc1;
        executed ->
            reaction_stat(executed, reaction_stat(matches, Acc1));
        {failed, _Reason} ->
            reaction_stat(failures, reaction_stat(matches, Acc1))
    end.

reaction_stat(Key, Stats) ->
    maps:update_with(Key, fun(N) -> N + 1 end, 1, Stats).

catalog_head({subscribes, _, _}) -> true;
catalog_head({react_on, _, _}) -> true;
catalog_head(_) -> false.

%% The full dereferenced head terms of the envelope's diff — INCLUDING retracted heads, so
%% per-key convergence can observe removals (nothing in the snapshot for key K ⇒ delete P[K]).
changed_heads(Env) ->
    [Head || {Kind, {Head, _Body}} <- maps:get(diff, Env, []),
             Kind =:= assert orelse Kind =:= asserta orelse Kind =:= retract].

release_direct_effects(HeightEffects) ->
    lists:foreach(
      fun({Height, Effects}) ->
          ok = quod_effect_journal:release_applied(Height, Effects)
      end, HeightEffects),
    ok.

events_finished({ok, Tip, TipEst, Effects, CatalogUpdate, ReactionStats, Changes},
                S0 = #s{mode = live}) ->
    S = install_catalog_update(CatalogUpdate, S0),
    S1 = S#s{est = TipEst, height = Tip,
             p_height = max(S#s.p_height, Tip),
             e_frontier = max(S#s.e_frontier, Tip),
             exec_failures = 0,
             reaction_candidates =
                 S#s.reaction_candidates + maps:get(candidates, ReactionStats),
             reaction_matches =
                 S#s.reaction_matches + maps:get(matches, ReactionStats),
             reactions_executed =
                 S#s.reactions_executed + maps:get(executed, ReactionStats),
             reaction_failures =
                 S#s.reaction_failures + maps:get(failures, ReactionStats),
             dropped_events =
                 S#s.dropped_events + maps:get(dropped, ReactionStats)},
    release_direct_effects(Effects),
    S2 = release_hosting(release_event_acks(S1)),
    ResourceChanges = resource_changes(Changes, Tip > S0#s.height),
    next_after_runner(floor_raise(queue_changes(Changes, invalidate_resources(ResourceChanges, S2))));
events_finished({error, Reason}, S) ->
    execution_failure({event_tier_failed, Reason}, S).

install_catalog_update(keep, S) ->
    S;
install_catalog_update(
  #{subscriptions := Subscriptions, reactions := Reactions,
    reaction_index := ReactionIndex,
    source_interests := SourceInterests,
    rejected_subscriptions := RejectedSubscriptions},
  S = #s{ns = Ns}) ->
    RejectedSubscriptions =:= 0 orelse
        logger:warning("quod_runtime[~s]: ~b malformed subscribes/2 clause(s) ignored",
                       [Ns, RejectedSubscriptions]),
    S1 = S#s{subscriptions = Subscriptions, reactions = Reactions,
             reaction_index = ReactionIndex,
             source_interests = SourceInterests,
             rejected_subscriptions =
                 S#s.rejected_subscriptions + RejectedSubscriptions},
    reconcile_source_views(Subscriptions, S1).

%%%===================================================================
%%% Shared certified source follows and subscribed reaction delivery
%%%===================================================================

reconcile_source_views(Subscriptions, S0) ->
    Desired = maps:from_keys(Subscriptions, true),
    Removed = [Identity || Identity <- maps:keys(S0#s.source_views),
                           not maps:is_key(Identity, Desired)],
    S1 = lists:foldl(fun stop_source_view/2, S0, Removed),
    S2 = lists:foldl(
           fun(Identity, Acc) ->
                   case maps:is_key(Identity, Acc#s.source_views) of
                       true -> Acc;
                       false -> enqueue_source_follow(Identity, Acc)
                   end
           end, S1, Subscriptions),
    %% Attachment yields through one self-message per identity, so a large
    %% catalogue never blocks this runtime turn. A missing owner is parked and
    %% woken by its one gproc name-follow monitor, never by a retry timer.
    drive_source_attach(
      maybe_release_foreign_log_monitor(
        ensure_foreign_log_monitor(S2))).

enqueue_source_follow(Identity, S0) ->
    Height = case maps:get(Identity, S0#s.source_views, undefined) of
                 #{state := State} -> source_last_height(State);
                 undefined -> 0
             end,
    queue_source_identities(
      [Identity],
      put_source_view(
        Identity,
        #{follow_ref => none, state => {building, Height}, attempt => 0}, S0)).

attach_source_follow(Identity, S0) ->
    Height = source_view_height(Identity, S0),
    {Attempt, S1} = next_source_attempt(S0),
    case quod_foreign_log:follow(Identity, projection) of
        {ok, FollowRef} ->
            put_source_view(
              Identity,
              #{follow_ref => FollowRef, state => {building, Height},
                attempt => Attempt}, S1);
        {error, Reason} ->
            mark_source_unreachable(Identity, Reason, Height, Attempt, S1)
    end.

source_view_height(Identity, #s{source_views = Views}) ->
    case maps:get(Identity, Views, undefined) of
        #{state := State} -> source_last_height(State);
        undefined -> 0
    end.

put_source_view(Identity, Row, S) ->
    S#s{source_views = (S#s.source_views)#{Identity => Row}}.

next_source_attempt(S = #s{source_attempts = Attempts}) ->
    {Attempts + 1, S#s{source_attempts = Attempts + 1}}.

mark_source_unreachable(Identity, Reason, Height, Attempt, S0) ->
    put_source_view(
      Identity,
      #{follow_ref => none, state => {unreachable, Reason, Height},
        attempt => Attempt}, S0).

ensure_foreign_log_monitor(S = #s{source_views = Views})
  when map_size(Views) =:= 0 ->
    clear_foreign_log_monitor(S);
ensure_foreign_log_monitor(S = #s{foreign_log_monitor = MRef})
  when is_reference(MRef) ->
    S;
ensure_foreign_log_monitor(S) ->
    MRef = quod_reg:monitor_name({foreign_log, node}, follow),
    S#s{foreign_log_monitor = MRef}.

clear_foreign_log_monitor(S = #s{foreign_log_monitor = none}) -> S;
clear_foreign_log_monitor(
  S = #s{foreign_log_monitor = MRef}) ->
    ok = quod_reg:demonitor_name({foreign_log, node}, MRef),
    S#s{foreign_log_monitor = none}.

handle_source_notice(FollowRef, NoticeRef, Identity, Notice, S0) ->
    case maps:get(Identity, S0#s.source_views, undefined) of
        #{follow_ref := FollowRef} = Row0 ->
            case source_notice_state(Notice) of
                {ok, State, Publications} ->
                    Row1 = Row0#{state => State},
                    S1 = S0#s{source_views =
                                  (S0#s.source_views)#{Identity => Row1}},
                    enqueue_source_publications(
                      FollowRef, NoticeRef, Identity, Publications, S1);
                error ->
                    erlang:error({invalid_source_follow_notice, Notice})
            end;
        _ ->
            S0
    end.

source_notice_state({building, Height})
  when is_integer(Height), Height >= 0 ->
    {ok, {building, Height}, []};
source_notice_state({unreachable, Reason, Height})
  when is_integer(Height), Height >= 0 ->
    {ok, {unreachable, Reason, Height}, []};
source_notice_state(
  {advanced, From, To, <<_:256>> = ProjectionId, Freshness, Heads,
   Publications})
  when is_integer(From), is_integer(To), To >= From,
       is_map(Freshness), is_list(Heads), is_list(Publications) ->
    case valid_source_publications(Publications, From, To) of
        true ->
            {ok, {ready, To, ProjectionId, Freshness,
                  #{from => From, changed_heads => Heads,
                    resnapshot => false}}, Publications};
        false ->
            error
    end;
source_notice_state(
  {resnapshot, To, <<_:256>> = ProjectionId, Freshness})
  when is_integer(To), To >= 0, is_map(Freshness) ->
    {ok, {ready, To, ProjectionId, Freshness,
          #{from => 0, changed_heads => [], resnapshot => true}}, []};
source_notice_state(_) ->
    error.

valid_source_publications(Publications, From, To) ->
    valid_source_publications(Publications, From, From, To).

valid_source_publications([], _From, _Previous, _To) -> true;
valid_source_publications([{Height, AppliedOps} | Rest], From, Previous, To)
  when is_integer(Height), Height > From, Height >= Previous, Height =< To,
       AppliedOps =/= [] ->
    quod_diff:valid_ops(AppliedOps)
        andalso valid_source_publications(Rest, From, Height, To);
valid_source_publications(_Malformed, _From, _Previous, _To) -> false.

enqueue_source_publications(FollowRef, NoticeRef, Identity, Publications, S0) ->
    case source_publications_relevant(Identity, Publications,
                                      S0#s.source_interests) of
        false ->
            ack_source_notice(FollowRef, NoticeRef, S0);
        true ->
            enqueue_relevant_source_publications(
              FollowRef, NoticeRef, Identity, Publications, S0)
    end.

enqueue_relevant_source_publications(FollowRef, NoticeRef, Identity,
                                     Publications, S0) ->
    case event_mode(S0#s.mode) of
        true ->
            case S0#s.queue_len < max_queued_events(S0) of
                true ->
                    Item = {remote, FollowRef, NoticeRef, Identity, Publications},
                    S1 = S0#s{queue = [Item | S0#s.queue],
                              queue_len = S0#s.queue_len + 1},
                    maybe_run_events(S1);
                false ->
                    %% The certified projection is already current. Reactions
                    %% are best-effort, so overload drops only this occurrence
                    %% and releases the follower to coalesce later advances.
                    ack_source_notice(
                      FollowRef, NoticeRef,
                      S0#s{dropped_events = S0#s.dropped_events + 1})
            end;
        false ->
            %% Boot/replay/unhealthy never replay historical E. Source views
            %% are normally absent in those modes; this handles a late notice
            %% from a superseded follow.
            ack_source_notice(
              FollowRef, NoticeRef,
              S0#s{dropped_events = S0#s.dropped_events + 1})
    end.

event_mode(live) -> true;
event_mode({reconciling, _}) -> true;
event_mode(_) -> false.

source_publications_relevant(Identity, Publications, SourceInterests) ->
    case maps:get(Identity, SourceInterests, undefined) of
        undefined -> false;
        Index ->
            lists:any(
              fun({_Height, AppliedOps}) ->
                      lists:any(
                        fun(Event) -> maps:is_key(functor_key(Event), Index) end,
                        quod_runtime_predicates:diff_to_events(AppliedOps))
              end, Publications)
    end.

ack_source_notice(FollowRef, NoticeRef, S) ->
    ok = quod_foreign_log:ack(FollowRef, NoticeRef),
    S.

%% Catalogue and owner-registration edges populate this queue. One identity is
%% attempted per mailbox turn, preserving responsiveness without a compiled
%% batch limit. Failed rows stay parked until a real owner replacement or a
%% later catalogue reconciliation supplies another edge.
queue_source_identities(Identities, S0) ->
    Existing = maps:from_keys(S0#s.source_attach_queue, true),
    Added = [Identity
             || Identity <- Identities,
                maps:is_key(Identity, S0#s.source_views),
                not maps:is_key(Identity, Existing),
                source_needs_attach(Identity, S0)],
    drive_source_attach(
      S0#s{source_attach_queue = S0#s.source_attach_queue ++ Added}).

queue_waiting_source_views(S) ->
    Waiting = [Identity
               || {Identity, Row} <- maps:to_list(S#s.source_views),
                  maps:get(follow_ref, Row, none) =:= none],
    queue_source_identities(lists:sort(Waiting), S).

source_needs_attach(Identity, #s{source_views = Views}) ->
    case maps:get(Identity, Views, undefined) of
        #{follow_ref := none} -> true;
        _ -> false
    end.

drive_source_attach(S = #s{source_attach_queue = [],
                           source_attach_token = none}) ->
    S;
drive_source_attach(S = #s{source_attach_token = Token})
  when is_reference(Token) ->
    S;
drive_source_attach(S) ->
    Token = make_ref(),
    self() ! {source_follow_attach, Token},
    S#s{source_attach_token = Token}.

run_source_attach(S0 = #s{source_attach_queue = [Identity | Rest]}) ->
    S1 = S0#s{source_attach_queue = Rest},
    S2 = case source_needs_attach(Identity, S1) of
             true -> attach_source_follow(Identity, S1);
             false -> S1
         end,
    drive_source_attach(S2);
run_source_attach(S) ->
    S.

stop_source_view(Identity, S0) ->
    S1 = drop_source_queue(Identity, S0),
    case maps:take(Identity, S1#s.source_views) of
        {Row, Views1} ->
            case maps:get(follow_ref, Row, none) of
                FollowRef when is_reference(FollowRef) ->
                    ok = quod_foreign_log:unfollow(FollowRef);
                none -> ok
            end,
            S1#s{source_views = Views1,
                 source_attach_queue =
                     lists:delete(Identity, S1#s.source_attach_queue)};
        error ->
            S1
    end.

stop_source_views(S0) ->
    S1 = lists:foldl(
           fun stop_source_view/2, S0, maps:keys(S0#s.source_views)),
    clear_foreign_log_monitor(
      S1#s{source_attach_queue = [], source_attach_token = none}).

maybe_release_foreign_log_monitor(S = #s{source_views = Views}) ->
    case map_size(Views) of
        0 -> clear_foreign_log_monitor(
               S#s{source_attach_queue = [], source_attach_token = none});
        _ -> S
    end.

foreign_log_down(S0) ->
    %% Every reference died with the owner. The gproc `follow` monitor remains
    %% armed and its exact `registered` edge will repopulate the attachment
    %% queue when the replacement owner is addressable.
    S1 = S0#s{source_attach_queue = [], source_attach_token = none},
    maps:fold(
      fun(Identity, Row, Acc0) ->
              Height = source_last_height(maps:get(state, Row)),
              put_source_view(
                Identity,
                #{follow_ref => none,
                  state => {unreachable, unavailable, Height},
                  attempt => maps:get(attempt, Row, 0)}, Acc0)
      end, S1, S1#s.source_views).

source_last_height({building, Height}) -> Height;
source_last_height({unreachable, _Reason, Height}) -> Height;
source_last_height({ready, Height, _ProjectionId, _Freshness, _Delta}) -> Height;
source_last_height(_) -> 0.

source_state_count(Status, Views) ->
    length([ok || Row <- maps:values(Views),
                  source_state_tag(maps:get(state, Row)) =:= Status]).

source_state_tag({ready, _, _, _, _}) -> ready;
source_state_tag({building, _}) -> building;
source_state_tag({unreachable, _, _}) -> unreachable.

%% After any runner completes: a parked ready edge wins; otherwise drain what queued.
next_after_runner(S = #s{pending_edge = none}) ->
    maybe_run_events(S);
next_after_runner(S = #s{pending_edge = Id}) ->
    replace_snapshot_and_reconcile(Id, S).

%% Execution failure: collapse pending work into ONE reconciliation at the newest snapshot.
%% Collapse ORDERING matters [DA M7]: any in-flight runner is killed first (its stale writes
%% must not land after the clear), then the queue drops and P bookkeeping clears, THEN the
%% fresh reconcile attaches. Consecutive failures back off exponentially; after
%% ?MAX_EXEC_FAILURES the server crashes deliberately so the supervisor path runs (the
%% backoff spacing keeps that far outside quod_ns's restart-intensity window).
execution_failure(Reason, S0 = #s{ns = Ns}) ->
    N = S0#s.exec_failures + 1,
    S1 = kill_runner(S0),
    S = drop_queue(S1#s{exec_failures = N,
                        collapses = S0#s.collapses + 1}),
    if
        N > ?MAX_EXEC_FAILURES ->
            logger:error("quod_runtime[~s]: ~b consecutive execution failures — giving up "
                         "to the supervisor: ~0p", [Ns, N, Reason]),
            exit({runtime_giving_up, Reason});
        N =:= 1 ->
            logger:warning("quod_runtime[~s]: execution failure (~0p) — collapsing to one "
                           "reconciliation", [Ns, Reason]),
            attach_and_reconcile({collapse, make_ref()}, S);
        true ->
            Delay = 1000 bsl (N - 1),
            logger:warning("quod_runtime[~s]: execution failure #~b (~0p) — retrying "
                           "reconciliation in ~b ms", [Ns, N, Reason, Delay]),
            Ref = make_ref(),
            _ = erlang:send_after(Delay, self(), {collapse_retry, Ref}),
            S#s{mode = {unhealthy, Reason}, last_recovery = {collapse, Ref}}
    end.

clear_recovery_pending(S = #s{recovery_pending = none}) -> S;
clear_recovery_pending(S = #s{recovery_pending = {_, _, Monitor, Timer}}) ->
    demonitor(Monitor, [flush]),
    _ = erlang:cancel_timer(Timer),
    S#s{recovery_pending = none}.

kill_runner(S00) ->
    S0 = drop_observations(stop_observer(stop_agents(clear_recovery_pending(S00)))),
    Workers = case S0#s.runner of
        none -> [];
        {_Kind, Pid, MRef, _Ref, TRef} ->
            _ = erlang:cancel_timer(TRef),
            [{Pid, MRef}]
    end,
    lists:foreach(fun({Pid, _MRef}) -> exit(Pid, kill) end, Workers),
    %% Await the reader before moving its retained MVCC floor.
    await_worker_downs(maps:from_list([{MRef, true} || {_Pid, MRef} <- Workers])),
    Cleared = case S0#s.resource_waiter of
        {From, Monitor} ->
            reply_resource(From, Monitor, {error, runtime_recovering}),
            S0#s{resource_waiter = none};
        none -> S0
    end,
    release_event_acks(Cleared#s{runner = none}).

await_worker_downs(Pending) when map_size(Pending) =:= 0 -> ok;
await_worker_downs(Pending) ->
    receive
        {'DOWN', MRef, process, _Pid, _Reason} when is_map_key(MRef, Pending) ->
            await_worker_downs(maps:remove(MRef, Pending))
    end.

begin_replay(Id, S0) ->
    S1 = kill_runner(stop_source_views(S0)),
    %% All readers are now dead, so releasing the base pin cannot invalidate a proof. The
    %% cast precedes any later re-attach call from this process by Erlang signal ordering.
    ok = quod_prolog:runtime_detach(S1#s.ns),
    drop_queue(S1#s{mode = {replaying, Id}, pending_edge = none}).

%% Queue overflow is BACKPRESSURE, not a fault: collapse to a reconciliation (kill the runner,
%% drop the queue, rebuild from the newest snapshot) but do NOT touch `exec_failures` and log at
%% notice — otherwise a load spike looks identical to a reader crash in the logs/metrics and
%% could (over enough distinct spikes) approach the deliberate-crash valve. Counted in
%% `collapses` so sustained overload is still visible.
overflow_collapse(S0 = #s{ns = Ns}) ->
    logger:notice("quod_runtime[~s]: event queue overflow — collapsing to one reconciliation "
                  "(backpressure, not a fault)", [Ns]),
    S1 = kill_runner(S0),
    S = drop_queue(S1#s{collapses = S1#s.collapses + 1}),
    attach_and_reconcile({collapse, make_ref()}, S).

%%% Hosted process lifecycle. D remains authoritative; these are current P handles.

request_executor({agent, Instance, Epoch, Key}, S = #s{agents = Agents}) ->
    Slot = {agent, Instance},
    case maps:get(Slot, Agents, none) of
        #{binding := #{epoch := Epoch, public_key := Key}, stopping := false} = Agent ->
            {ok, Slot, Agent, S};
        _ -> {error, stale_executor, S}
    end;
request_executor({node, Key}, S) ->
    case node_executor_binding(Key, S) of
        {ok, Binding} ->
            case maps:get(node, S#s.agents, none) of
                none ->
                    Next = start_agent(node, Binding, S),
                    {ok, node, maps:get(node, Next#s.agents), Next};
                #{binding := Binding, stopping := false} = Agent -> {ok, node, Agent, S};
                Agent ->
                    {error, stale_executor,
                     S#s{agents = (S#s.agents)#{node => stop_agent(Agent, Binding)}}}
            end;
        error -> {error, stale_executor, S}
    end;
request_executor(_, S) -> {error, stale_executor, S}.

node_executor_binding(Key, #s{binding = #{identity := {Ns, Anchor} = Source}, config = Config}) ->
    case {maps:get(node_id, Config), quod_node_actor:principal()} of
        {Key, {ok, Principal}} when is_binary(Key), byte_size(Key) =:= 32 ->
            case quod_agent_ref:materialize_principal(Principal) of
                {ok, {agent_instance_ref, Ns, Anchor, _} = Ref} ->
                    {ok, #{reference => Ref, credential => node, public_key => Key,
                           epoch => 0, source => Source}};
                _ -> error
            end;
        _ -> error
    end;
node_executor_binding(_, _) -> error.

%% An ontology can select only its hosted actors and, in its exact own scope,
%% the installed logical node. Event origin never supplies another authority.
audience_bindings(domain, S = #s{config = Config}) ->
    Hosted = [B || {{agent, _}, #{binding := B, stopping := false}} <- maps:to_list(S#s.agents)],
    case request_executor({node, maps:get(node_id, Config)}, S) of
        {ok, node, #{binding := Binding}, Next} -> {[Binding | Hosted], Next};
        {error, _, Next} -> {Hosted, Next}
    end;
audience_bindings({recovery, Source, Expiry, Metadata}, S) ->
    case recovery_current(Source, Metadata, Expiry, S) of
        true ->
            {Bindings, Next} = audience_bindings(domain, S),
            Node = maps:get(observer, Metadata),
            {[B#{request_expiry => Expiry, recovery => Metadata}
              || B = #{credential := node, reference := Ref} <- Bindings, Ref =:= Node], Next};
        false -> {[], S}
    end.

recovery_current(Source, #{target := {agent_instance_ref, Ns, _, _}, observer := Node,
                           deadline := Deadline, evidence := #{observer := Node} = Evidence}, Expiry, S) ->
    Expiry > quod_time:now_ms() andalso Deadline > quod_time:mono_ms() andalso node_scope(Node, S) andalso
    quod_reg:where({quod_runtime, Ns}) =:= Source andalso
    quod_agent_observer:evidence_current(Evidence);
recovery_current(_, _, _, _) -> false.

node_scope({agent_instance_ref, Ns, Anchor, _} = Node,
           #s{binding = #{identity := {Ns, Anchor}}}) -> local_node_reference() =:= Node;
node_scope(_, _) -> false.

refresh_node_executor(S = #s{config = Config}) ->
    case maps:is_key(node, S#s.agents) of
        false -> S;
        true ->
            Key = maps:get(node_id, Config),
            Desired = case node_executor_binding(Key, S) of
                {ok, Binding} -> #{node => Binding};
                error -> #{}
            end,
            install_agents({keys, [node]}, Desired, S)
    end.

agent_projection({Ns, Anchor}, Scope, Hosts, S) when is_list(Hosts) ->
    case agent_projection_scope(Scope, Hosts) of
        true ->
            case local_agent_projection(Ns, Anchor, Hosts) of
                {ok, Desired} ->
                    Slots = agent_projection_slots(Scope, Desired, S#s.agents),
                    {ok, Slots, Desired};
                Error -> Error
            end;
        false -> {error, invalid_agent_projection}
    end;
agent_projection(_, _, _, _) -> {error, invalid_agent_projection}.

agent_projection_scope(all, _) -> true;
agent_projection_scope({keys, Instances}, Hosts) when is_list(Instances) ->
    length(Instances) =:= length(lists:usort(Instances)) andalso
    quod_wire_term:is_ground(Instances) andalso
    lists:all(fun({host, I, _, _, _}) -> lists:member(I, Instances);
                 (_) -> false end, Hosts);
agent_projection_scope(_, _) -> false.

agent_projection_slots(all, Desired, Existing) ->
    {keys, lists:usort([Slot || Slot = {agent, _} <- maps:keys(Existing)] ++ maps:keys(Desired))};
agent_projection_slots({keys, Instances}, _Desired, _Existing) ->
    {keys, [{agent, Instance} || Instance <- Instances]}.

local_agent_projection(Ns, Anchor, Hosts) ->
    case quod_node_actor:principal() of
        {ok, Principal} ->
            {ok, NodeRef} = quod_agent_ref:materialize_principal(Principal),
            agent_projection(Hosts, NodeRef, Ns, Anchor, #{}, #{});
        _ -> {ok, #{}}
    end.

agent_projection([], _Node, _Ns, _Anchor, Acc, _Seen) -> {ok, Acc};
agent_projection([{host, Instance, Node, Epoch, <<_:256>> = Key} | Rest],
                 Local, Ns, Anchor, Acc, Seen)
  when is_integer(Epoch), Epoch > 0 ->
    case {quod_wire_term:is_ground({Instance, Node}), maps:is_key(Instance, Seen)} of
        {true, false} when Node =:= Local ->
            Binding = #{reference => {agent_instance_ref, Ns, Anchor, Instance},
                        epoch => Epoch, public_key => Key},
            agent_projection(Rest, Local, Ns, Anchor, Acc#{{agent, Instance} => Binding}, Seen#{Instance => true});
        {true, false} -> agent_projection(Rest, Local, Ns, Anchor, Acc, Seen#{Instance => true});
        _ -> {error, ambiguous_agent_projection}
    end;
agent_projection(_, _, _, _, _, _) -> {error, invalid_agent_projection}.

install_agents({keys, Instances}, Desired, S) ->
    %% Ordinary changes touch only the affected identities. Retiring children
    %% occupy their slot until DOWN. Refused bindings are published with the
    %% batch, not retained as another desired-state inventory.
    lists:foldl(fun(I, Acc) ->
        Next = maps:get(I, Desired, none),
        case {maps:get(I, Acc#s.agents, none), Next} of
            {none, none} -> Acc#s{hosting_dirty = maps:remove(I, Acc#s.hosting_dirty)};
            {none, Binding} ->
                case agent_slot_count(I) =:= 0 orelse Acc#s.agent_slots < max_hosted_agents(Acc) of
                    true -> start_agent(I, Binding, Acc);
                    false -> Acc#s{hosting_dirty = (Acc#s.hosting_dirty)#{I => {refused, Binding}},
                                    agent_capacity_blocked = true,
                                    agent_capacity_refusals = Acc#s.agent_capacity_refusals + 1}
                end;
            {#{binding := Binding, stopping := false}, Binding} -> Acc;
            {Agent, Binding} -> Acc#s{agents = (Acc#s.agents)#{I => stop_agent(Agent, Binding)}}
        end
    end, S, Instances).

agent_slot_count(node) -> 0;
agent_slot_count({agent, _}) -> 1.

max_hosted_agents(#s{config = Config}) ->
    Limit = maps:get(runtime_max_hosted_agents, Config,
                    application:get_env(quod, runtime_max_hosted_agents, ?MAX_HOSTED_AGENTS)),
    true = is_integer(Limit) andalso Limit >= 0 andalso Limit =< ?MAX_HOSTED_AGENTS,
    Limit.

enqueue_agent_request(Slot, Agent = #{pid := Pid, pending := Pending}, H, Request, S) ->
    Bytes = erlang:external_size(Request),
    case map_size(Pending) < ?MAX_AGENT_PENDING andalso
         Bytes =< ?MAX_AGENT_REQUEST_BYTES andalso
         S#s.agent_pending_bytes + Bytes =< ?MAX_AGENT_PENDING_BYTES of
        true ->
            Ref = make_ref(),
            Pid ! {agent_request, self(), Ref, H, Request, erlang:monotonic_time(microsecond)},
            {ok, Ref, S#s{agents = (S#s.agents)#{Slot => Agent#{pending => Pending#{Ref => Bytes}}},
                          agent_pending_bytes = S#s.agent_pending_bytes + Bytes,
                          hosting_dirty = (S#s.hosting_dirty)#{Slot =>
                                             maps:get(Slot, S#s.hosting_dirty, work)}}};
        false -> {error, busy}
    end.

%% A pass visits increasing binary domain keys once. An unsuccessful/unknown
%% request advances the pass too: completion is a wake, never a retry trigger.
%% Only a changed watched projection or a new hosted incarnation grants a new
%% pass. None of this progress is durable or evidence about a signed operation.
%% Selection reads belong to the entire pass, including its idle result. Only
%% starting a new pass retires them; capacity and completion continue the pass.
project_work(H, Slot, Step, S) ->
    case maps:get(Slot, S#s.agents, none) of
        Agent = #{stopping := false} ->
            case maps:get(work, Agent, none) of
                none when is_tuple(Step), element(1, Step) =:= cursor ->
                    Work = #{height => H, cursor => start,
                             prior => all, dirty => false,
                             custody_owner => quod_reg:where({quod_simplex, S#s.ns})},
                    {skip, query_agent_work_custody(Slot, Agent, Work,
                                                     clear_agent_work_basis(Slot, S))};
                none -> {{error, invalid_agent_work}, S};
                Work -> project_work_step(Step, H, Slot, Work, S)
            end;
        _ -> {skip, S}
    end.

%% Recovery asks the existing transaction owner for earlier custody once per
%% hosted incarnation. Subscribe before the snapshot; replies and subsequent
%% notices come from that same owner. Later refreshes can only shrink this set
%% of references, so this agent's new attempts cannot wake their own retry loop.
query_agent_work_custody(_Slot, _Agent, #{custody_owner := undefined}, S) -> S;
query_agent_work_custody(Slot, #{binding := #{reference := Ref}}, Work, S) ->
    case S#s.agent_work_subscribed of
        false -> true = quod_reg:subscribe({agent_work_custody, S#s.ns});
        true -> ok
    end,
    {ok, Blob} = quod_wire_term:encode_canonical(Ref),
    Token = make_ref(), Owner = maps:get(custody_owner, Work),
    Owner ! {agent_work_custody, self(), Token, Blob, maps:get(prior, Work)},
    put_agent_work(Slot, Work#{status => {custody_query, Token}},
                    S#s{agent_work_subscribed = true}).

project_work_step({cursor, Wake}, H, Slot, Work0, S) ->
    {Work, Current} = case Wake of
                          changed -> refresh_agent_work(H, Slot, Work0, S);
                          continue -> {Work0, S}
                      end,
    case maps:get(status, Work) of
        Status when Status =:= ready; Status =:= blocked ->
            case agent_work_capacity(Slot, Current) of
                true -> {{ok, maps:get(cursor, Work)},
                         put_agent_work(Slot, Work#{status => ready}, Current)};
                false -> {skip, put_agent_work(Slot, Work#{status => blocked}, Current)}
            end;
        _ -> {skip, put_agent_work(Slot, Work, Current)}
    end;
project_work_step(none, _H, Slot, Work = #{status := ready, dirty := Dirty}, S) ->
    case Dirty of
        true ->
            Next = put_agent_work(Slot, Work#{cursor => start, dirty => false},
                                  clear_agent_work_basis(Slot, S)),
            {ok, queue_agent_work(Slot, Work, Next)};
        false -> {ok, put_agent_work(Slot, Work#{status => idle}, S)}
    end;
project_work_step({work, Key, Goal, Budget}, H, Slot,
                  Work = #{status := ready, cursor := Cursor}, S)
  when is_binary(Key), is_integer(Budget), Budget > 0, Budget =< 60000 ->
    Request = {execute, Goal, quod_time:now_ms() + Budget, quod_time:mono_ms() + Budget},
    case (Cursor =:= start orelse Key > element(2, Cursor)) andalso
         erlang:external_size({Key, Request}) =< ?MAX_AGENT_REQUEST_BYTES of
        true ->
            case enqueue_agent_request(Slot, maps:get(Slot, S#s.agents), H, Request, S) of
                {ok, Ref, Next} ->
                    {ok, put_agent_work(Slot, Work#{cursor => {'after', Key}, status => {active, Ref}}, Next)};
                {error, busy} -> {ok, put_agent_work(Slot, Work#{status => blocked}, S)}
            end;
        false -> {{error, invalid_agent_work}, S}
    end;
project_work_step(_, _, _, _, S) -> {{error, invalid_agent_work}, S}.

refresh_agent_work(H, Slot, Work = #{height := Before, status := Status}, S)
  when is_integer(H), H > Before ->
    case Status of
        idle -> {Work#{height => H, cursor => start, status => ready, dirty => false},
                 clear_agent_work_basis(Slot, S)};
        _ -> {Work#{height => H, dirty => true}, S}
    end;
refresh_agent_work(_, _, Work, S) -> {Work, S}.

clear_agent_work_basis(Slot, S) ->
    S#s{resource_basis = maps:remove(work_resource_key(Slot), S#s.resource_basis)}.

put_agent_work(Slot, Work, S = #s{agents = Agents}) ->
    S#s{agents = Agents#{Slot => (maps:get(Slot, Agents))#{work => Work}}}.

agent_work_capacity(Slot, S) ->
    #{pending := Pending} = maps:get(Slot, S#s.agents),
    map_size(Pending) < ?MAX_AGENT_PENDING andalso
        S#s.agent_pending_bytes + ?MAX_AGENT_REQUEST_BYTES =< ?MAX_AGENT_PENDING_BYTES.

agent_work_count(Status, S) ->
    length([ok || #{stopping := false, work := #{status := W}} <- maps:values(S#s.agents),
                  W =:= Status]).

finish_agent_work(Slot, Ref, S) ->
    case maps:get(Slot, S#s.agents) of
        #{stopping := false, work := Work = #{status := {active, Ref}}} ->
            queue_agent_work(Slot, Work, put_agent_work(Slot, Work#{status => ready}, S));
        _ -> S
    end.

%% Refused work retains only its existing cursor, not another copy of a goal.
%% A real queue release wakes only projections waiting for that capacity.
wake_work_capacity(S) ->
    maps:fold(fun(Slot, #{stopping := false, work := Work = #{status := blocked}}, Acc) ->
                      case agent_work_capacity(Slot, Acc) of
                          true -> queue_agent_work(Slot, Work, Acc);
                          false -> Acc
                      end;
                 (_, _, Acc) -> Acc
              end, S, S#s.agents).

queue_agent_work({agent, Instance}, _Work, S) ->
    queue_ready(agent_work, {agent_work, Instance}, S).

start_agent(Instance, Binding, S) ->
    {ok, Pid} = quod_agent:start(self(), Instance, Binding),
    Agent = #{binding => Binding, pid => Pid,
              monitor => monitor(process, Pid, [{tag, {agent_down, Instance}}]),
              stopping => false, pending => #{}},
    S#s{agents = (S#s.agents)#{Instance => Agent},
        agent_slots = S#s.agent_slots + agent_slot_count(Instance),
        hosting_dirty = (S#s.hosting_dirty)#{Instance => installed}}.

release_hosting(S = #s{hosting_dirty = Dirty, agents = Agents, e_frontier = H}) ->
    maps:foreach(fun(_I, {refused, Binding}) ->
        quod_reg:publish({agent_hosting, S#s.ns},
                         {agent_refused, self(), Binding, capacity, H});
      (_I, {observation_refused, {watch, I, Host, Epoch, _}}) ->
        quod_reg:publish({agent_hosting, S#s.ns},
                         {agent_observation_refused, self(), I, Host, Epoch, capacity, H});
      (observer_capacity, {observation_status, Status}) ->
        quod_reg:publish({agent_hosting, S#s.ns},
                         {agent_observation_installed, self(), Status, H});
      (I, Kind) ->
        case maps:get(I, Agents, none) of
            #{pid := Pid, binding := Binding, stopping := false} ->
                Pid ! {agent_release, self(), H},
                case Kind of
                    installed -> quod_reg:publish({agent_hosting, S#s.ns},
                                   {agent_installed, self(), Pid, Binding, H});
                    work -> ok
                end;
            _ -> ok
        end
    end, Dirty),
    Cleared = S#s{hosting_dirty = #{}},
    Installed = [Instance || {{agent, Instance} = Slot, installed} <- maps:to_list(Dirty),
                            #{stopping := false} <- [maps:get(Slot, Agents, none)]],
    lists:foldl(fun(Instance, Acc) -> queue_ready(agent_work, {agent_work, Instance}, Acc) end,
                Cleared, Installed).

stop_agent(Agent = #{pid := Pid, stopping := false}, Next) ->
    Pid ! {agent_stop, self()},
    Agent#{stopping => true, successor => Next};
stop_agent(Agent, Next) -> Agent#{successor => Next}.

stop_agents(S) ->
    Agents = maps:map(fun(_, A) -> stop_agent(A, none) end, S#s.agents),
    S#s{agents = Agents, hosting_dirty = #{}, agent_projection_waiter = none,
        agent_capacity_blocked = false}.

work_resource_key({agent, Instance}) -> {agent_work, Instance};
work_resource_key(node) -> node.

agent_down(Instance, Pid, Monitor, S = #s{agents = Agents}) ->
    case maps:get(Instance, Agents, none) of
        Agent = #{pid := Pid, monitor := Monitor, pending := Pending} ->
            S1 = S#s{agents = maps:remove(Instance, Agents),
                      agent_slots = S#s.agent_slots - agent_slot_count(Instance),
                      agent_pending_bytes = S#s.agent_pending_bytes - lists:sum(maps:values(Pending)),
                      hosting_dirty = maps:remove(Instance, S#s.hosting_dirty),
                      resource_basis = maps:remove(work_resource_key(Instance), S#s.resource_basis),
                      resource_failures = maps:remove(work_resource_key(Instance), S#s.resource_failures)},
            Result = case Agent of
                #{stopping := true, successor := none} -> S1;
                #{stopping := true, successor := Binding} ->
                    Next = start_agent(Instance, Binding, S1),
                    case Next of
                        #s{mode = live, runner = none} -> release_hosting(Next);
                        _ -> Next
                    end;
                #{stopping := false} ->
                    case Instance of
                        node -> queue_ready(ontology, all, S1);
                        {agent, I} -> queue_ready(agent_hosts, {agent, I},
                                        observe_agent_down(maps:get(binding, Agent), S1))
                    end
            end,
            Released = case Result#s.agent_capacity_blocked andalso
                            Result#s.agent_slots < S#s.agent_slots of
                true -> queue_agent_reconcile(Result);
                false -> Result
            end,
            wake_work_capacity(finish_agent_projection(Monitor, Released));
        _ -> S
    end.

install_observer(Old, Installed, Scope, Refused, S) ->
    Clean = maps:filter(fun({observer, I}, _) ->
                            Scope =/= all andalso not lists:member(I, element(2, Scope));
                          (_, _) -> true
                        end, S#s.hosting_dirty),
    Dirty = lists:foldl(fun(Row = {watch, I, _, _, _}, Acc) ->
        Acc#{{observer, I} => {observation_refused, Row}}
    end, Clean, Refused),
    Status = quod_agent_observer:stats(Installed),
    Notices = case Status =:= quod_agent_observer:stats(Old) of
        true -> Dirty;
        false -> Dirty#{observer_capacity => {observation_status, Status}}
    end,
    Next = S#s{observer = Installed, hosting_dirty = Notices},
    case quod_agent_observer:capacity_released(Old, Installed) of
        true -> queue_observer_reconcile(Next);
        false -> Next
    end.

stop_observer(S = #s{observer = none}) -> S;
stop_observer(S = #s{observer = Observer}) ->
    ok = quod_agent_observer:stop(Observer),
    S#s{observer = none}.

queue_observations([], S) -> S;
queue_observations(Events, S = #s{mode = Mode})
  when Mode =:= live; is_tuple(Mode), element(1, Mode) =:= reconciling ->
    maybe_run_events(lists:foldl(fun queue_observation/2, S, Events));
queue_observations(Events, S) ->
    S#s{dropped_events = S#s.dropped_events + length(Events)}.

queue_observation({observed_host, Batch = #{host := Host}}, S = #s{queue = Queue}) ->
    case replace_host_observation(Host, Batch, Queue) of
        {replaced, Updated} -> S#s{queue = Updated, queue_len = length(Updated)};
        absent ->
            case maps:get(bindings, Batch) of
                [] -> S;
                _ -> admit_observation({observed_host, Batch}, S)
            end
    end;
queue_observation(Event, S) -> admit_observation({observed, Event}, S).

replace_host_observation(_Host, _Batch, []) -> absent;
replace_host_observation(Host, Batch, [{observed_host, #{host := Host} = Old} | Rest]) ->
    Merged = quod_agent_observer:merge(Batch, Old),
    case maps:get(bindings, Merged) of
        [] -> {replaced, Rest};
        _ -> {replaced, [{observed_host, Merged} | Rest]}
    end;
replace_host_observation(Host, Batch, [Item | Rest]) ->
    case replace_host_observation(Host, Batch, Rest) of
        absent -> absent;
        {replaced, Updated} -> {replaced, [Item | Updated]}
    end.

admit_observation(Item, S = #s{queue = Queue, queue_len = Count}) ->
    case Count < max_queued_events(S) of
        true -> S#s{queue = [Item | Queue], queue_len = Count + 1};
        false ->
            case Item of
                {observed, {ready, _, _}} -> resource_notice_overflow(S);
                _ -> S#s{dropped_events = S#s.dropped_events + 1}
            end
    end.

%% Scoped readiness notifications collapse into the same ordered resource
%% cursor. Its pending typed requests and original bounds survive compaction,
%% even when the queue budget has room for only one item.
resource_notice_overflow(S) ->
    Keep = [Item || Item <- S#s.queue, not resource_notice(Item)],
    queue_resource_cursor(#{}, true, S#s{queue = Keep, queue_len = length(Keep)}).

resource_notice({observed, {ready, _, _}}) -> true;
resource_notice({observed, {ontology_changed, _}}) -> true;
resource_notice({owned_notice, {observed, {ready, _, _}}, domain, _}) -> true;
resource_notice({owned_notice, {observed, {ontology_changed, _}}, domain, _}) -> true;
resource_notice(_) -> false.

queue_observer_reconcile(S) -> queue_ready(agent_observers, all, S).

observe_agent_down(#{reference := Ref, epoch := Epoch, public_key := Key}, S) ->
    Event = {agent_process_down, Ref, Epoch, Key, crypto:strong_rand_bytes(32)},
    queue_observations([Event], S);
observe_agent_down(_, S) -> S.

agent_retirements({keys, Instances}, Agents) ->
    maps:from_list([{M, I} || I <- Instances,
                            #{stopping := true, monitor := M} <- [maps:get(I, Agents, none)]]).

finish_agent_projection(_Monitor, S = #s{agent_projection_waiter = none}) -> S;
finish_agent_projection(Monitor, S = #s{agent_projection_waiter = {From, Waiting, Reply}}) ->
    case maps:remove(Monitor, Waiting) of
        Remaining when map_size(Remaining) > 0 ->
            S#s{agent_projection_waiter = {From, Remaining, Reply}};
        _ ->
            gen_server:reply(From, Reply),
            S#s{agent_projection_waiter = none}
    end.

%% Readiness names an owned resource, never a declaration or callback goal.
queue_agent_reconcile(S) -> queue_ready(agent_hosts, all, S).

queue_ready(Resource, Scope, S0) ->
    S = schedule_resource_notice(Resource, Scope, S0),
    Event = {ready, Resource, Scope},
    Item = {observed, Event},
    case lists:member(Item, S#s.queue) of
        true -> maybe_run_events(S);
        false -> queue_observations([Event], S)
    end.

schedule_resource_notice(ontology, all, S) ->
    Keys = [agent_hosts, agent_observers, node_ontologies, effect_custody] ++
           [{agent_work, I} || {{agent, I}, #{stopping := false}} <- maps:to_list(S#s.agents)],
    queue_resource_keys(Keys, changed, S);
schedule_resource_notice(agent_work, {agent_work, I}, S) ->
    queue_resource_key({agent_work, I}, continue, S);
schedule_resource_notice(Resource, _Scope, S) -> queue_resource_key(Resource, changed, S).

queue_resource_key(Key, Wake, S) -> queue_resource_keys([Key], Wake, S).

queue_resource_keys([], _Wake, S) -> S;
queue_resource_keys(Keys, Wake, S = #s{height = H}) ->
    Deadline = quod_time:mono_ms() +
        application:get_env(quod, runtime_reconcile_budget_ms, ?RECONCILE_BUDGET_MS),
    queue_resource_cursor(maps:from_keys(Keys, {H, Wake, Deadline}), false, S).

queue_resource_cursor(Added, Notify, S = #s{queue = Q, queue_len = Count}) ->
    case lists:keyfind(resource_cursor, 1, Q) of
        {resource_cursor, Existing, WasNotify} ->
            Requests = maps:merge_with(fun merge_resource_wake/3, Existing, Added),
            Cursor = {resource_cursor, Requests, Notify orelse WasNotify},
            S#s{queue = lists:keyreplace(resource_cursor, 1, Q, Cursor)};
        false ->
            Limit = max_queued_events(S),
            case Count < Limit of
                true -> S#s{queue = [{resource_cursor, Added, Notify} | Q],
                             queue_len = Count + 1};
                false when Limit =:= 0 -> unhealthy({resource_notice_capacity, 0}, S);
                false ->
                    Keep = [Item || Item <- Q, not resource_notice(Item)],
                    case length(Keep) < Count of
                        true -> queue_resource_cursor(Added, true,
                                  S#s{queue = Keep, queue_len = length(Keep)});
                        %% Canonical input/caller requests occupy every slot.
                        %% The existing lifecycle restores current obligations;
                        %% it never replays an occurrence or a submitted goal.
                        false -> overflow_collapse(S)
                    end
            end
    end.

merge_resource_wake(_Key, {OldHeight, OldWake, OldDeadline}, {Height, Wake, Deadline}) ->
    MergedWake = case OldWake =:= changed orelse Wake =:= changed of
        true -> changed;
        false -> continue
    end,
    {max(OldHeight, Height), MergedWake, min(OldDeadline, Deadline)}.

resource_key(agent_work, {Instance, _}) -> {agent_work, Instance};
resource_key(Resource, _) -> Resource.

resource_changes(Heads, HeightAdvanced) ->
    %% Enumeration observes predicate membership as well as the definitions
    %% whose types it inspected. Context can advance without either changing.
    Keys = case Heads of
        [] -> [];
        _ -> [predicate_registry | [{fact, functor_key(H)} || H <- Heads]]
    end,
    maps:from_keys(case HeightAdvanced of
        true -> [{input, committed_height} | Keys];
        false -> Keys
    end, true).

queued_resource_changes(Queue, Height) ->
    Advanced = lists:any(fun({local, Env, _}) -> maps:get(height, Env, 0) > Height;
                            ({snapshot, H, _}) -> H > Height;
                            (_) -> false end, Queue),
    resource_changes(lists:append([changed_heads(Env) || {local, Env, _} <- Queue]), Advanced).

invalidate_resources(Changes, S) when map_size(Changes) =:= 0 -> S;
invalidate_resources(Changes, S) ->
    Keys = maps:fold(fun(Key, Basis, Acc) ->
        case quod_resource_basis:affected(Basis, Changes) of
            true -> [Key | Acc];
            false -> Acc
        end
    end, [], S#s.resource_basis),
    queue_resource_keys(Keys, changed, S).

reply_resource({internal, _}, none, _) -> ok;
reply_resource(From, Monitor, Reply) ->
    demonitor(Monitor, [flush]),
    gen_server:reply(From, Reply).

drop_queue(S) -> retain_queue(fun(_) -> false end, S).

%% Reset discards observations from the previous owner incarnation. New
%% observations arriving while its replacement reconciles are not ledger data
%% and must survive the later height-based queue trimming.
drop_observations(S) ->
    retain_queue(fun({observed, _}) -> false;
                    ({observed, _, _}) -> false;
                    ({observed_host, _}) -> false;
                    ({owned_recovery, _, _, _, _, _}) -> false;
                    ({recovery_done, _, _}) -> false;
                    ({owned_notice, _, _, _}) -> false;
                    ({resource_cursor, _, _}) -> false;
                    (_) -> true end, S).

%% Only local envelopes at or below H are already represented in the snapshot.
drop_stale_queue(S = #s{height = H}) ->
    retain_queue(fun({local, Env, _Est}) -> maps:get(height, Env, 0) > H;
                    ({snapshot, NextH, _Est}) -> NextH > H;
                    (_) -> true end, S).

drop_source_queue(Identity, S) ->
    retain_queue(fun({remote, _, _, Source, _}) -> Source =/= Identity;
                    (_) -> true end, S).

retain_queue(_Keep, S = #s{queue_len = 0}) -> S;
retain_queue(Keep, S = #s{queue = Queue, dropped_events = Count}) ->
    {Kept, Dropped} = lists:partition(Keep, Queue),
    release_queue_acks(Dropped),
    S#s{queue = Kept, queue_len = length(Kept),
        dropped_events = Count + length(Dropped)}.

release_queue_acks(Items) ->
    lists:foreach(
      fun({remote, FollowRef, NoticeRef, _Identity, _Publications}) ->
              ok = quod_foreign_log:ack(FollowRef, NoticeRef);
         ({owned_recovery, Source, Token, _, _, _}) ->
             Source ! {recovery_consumed, self(), Token};
         ({recovery_done, Source, Token}) -> Source ! {recovery_consumed, self(), Token};
         ({resource, _, _, _, _, From, Monitor}) ->
             reply_resource(From, Monitor, {error, runtime_recovering});
         (_) -> ok
      end, Items),
    ok.

release_event_acks(S = #s{event_acks = Acks}) ->
    lists:foreach(
      fun({FollowRef, NoticeRef}) ->
              ok = quod_foreign_log:ack(FollowRef, NoticeRef)
      end, Acks),
    S#s{event_acks = []}.

%% The serialized reader has completed before its retained MVCC floor moves.
%% The cast is monotone server-side, so a stale/duplicate raise is harmless.
floor_raise(S = #s{height = 0}) -> S;
floor_raise(S = #s{ns = Ns, height = H}) ->
    ok = quod_prolog:runtime_floor(Ns, H),
    S.

max_queued_events(#s{config = Config}) ->
    maps:get(runtime_max_queued_events, Config,
             application:get_env(quod, runtime_max_queued_events,
                                 ?DEFAULT_MAX_QUEUED_EVENTS)).

%%% Resource selection runs to completion before touching the real owner.

valid_resource_scope(agent_custody,
                     {{agent_instance_ref, Ns, Anchor, _}, Epoch, Observer},
                     #s{binding = #{identity := {Ns, Anchor}}}) ->
    is_integer(Epoch) andalso Epoch > 0 andalso Observer =:= local_node_reference();
valid_resource_scope(agent_custody, _, _) -> false;
valid_resource_scope(_, _, _) -> true.

run_resource(Ns, H, Est, Resource, Scope, Deadline, {Caller, _}) ->
    case (Caller =:= internal orelse is_process_alive(Caller)) andalso Deadline > quod_time:mono_ms() of
        false -> {interrupted, {error, deadline_exceeded}};
        true ->
            Key = resource_key(Resource, Scope),
            {Outcome, Basis} = quod_resource_basis:capture(Est,
                fun(Observed) -> select_resource_description(Ns, H, Observed, Resource, Scope) end),
            Selected = case Outcome of
                {error, {throw, Reason, _Stack}} -> {error, Reason};
                _ -> Outcome
            end,
            Admission = case {Resource, Selected} of
                {agent_work, inactive} -> ok;
                _ -> gen_server:call(quod_reg:via({quod_runtime, Ns}),
                                      {resource_selected, Key, Basis}, infinity)
            end,
            case Admission of
                ok ->
                    case Deadline > quod_time:mono_ms() of
                        true -> install_resource(Ns, H, Selected);
                        false -> {error, deadline_exceeded}
                    end;
                Error -> Error
            end
    end.

select_resource_description(Ns, H, Est, agent_hosts, Changed) ->
    Goal = {agent_hosting_projection, Changed, local_node_reference(), {'Scope'}, {'Rows'}},
    case optional_selection(Ns, H, Est, Goal) of
        absent -> {agent_hosts, all, []};
        #{'Scope' := Scope, 'Rows' := Rows} -> {agent_hosts, Scope, Rows}
    end;
select_resource_description(Ns, H, Est, agent_observers, Changed) ->
    Goal = {agent_observation_projection, Changed, local_node_reference(), {'Scope'}, {'Rows'}},
    case optional_selection(Ns, H, Est, Goal) of
        absent -> {agent_observers, all, []};
        #{'Scope' := Scope, 'Rows' := Rows} -> {agent_observers, Scope, Rows}
    end;
select_resource_description(Ns, H, Est, node_ontologies, _Scope) ->
    case local_node_reference() of
        {agent_instance_ref, Ns, _, _} ->
            Goal = {node_ontology_hosting_projection, {'Hosts'}, {'Contacts'}},
            case optional_selection(Ns, H, Est, Goal) of
                absent -> {node_ontologies, [], []};
                #{'Hosts' := Hosts, 'Contacts' := Contacts} -> {node_ontologies, Hosts, Contacts}
            end;
        _ -> inactive
    end;
select_resource_description(<<"quod:root">> = Ns, H, Est, effect_custody, all) ->
    Goal = {findall, {'C'}, {effect_custody_capacity, {'C'}}, {'Capacities'}},
    case select_resource(Ns, H, Est, Goal) of
        #{'Capacities' := [Capacity]}
          when is_integer(Capacity), Capacity >= 0; Capacity =:= unlimited ->
            {effect_custody, Capacity};
        _ -> {error, invalid_effect_custody_capacity}
    end;
select_resource_description(_, _, _, effect_custody, _) -> inactive;
select_resource_description(Ns, H, Est, agent_work, {Instance, Wake}) ->
    case project_agent_work(Ns, H, Instance, {cursor, Wake}) of
        {ok, Cursor} ->
            Goal = {agent_work_goal, Instance, Cursor, {'Key'}, {'Goal'}, {'Budget'}},
            case select_resource(Ns, H, Est, Goal) of
                fail -> {agent_work, Instance, none};
                #{'Key' := Key, 'Goal' := WorkGoal, 'Budget' := Budget} ->
                    {agent_work, Instance, {work, Key, WorkGoal, Budget}}
            end;
        skip -> inactive;
        {error, _} = Error -> Error
    end;
select_resource_description(Ns, H, Est, agent_recovery,
          {{Ns, Anchor}, Batch,
           {agent_host_observed, _, Observer, I, Host, Epoch, Expected, Round,
            Observation, Kind, At, _Validity}, Ceiling, Deadline}) ->
    Goal = {agent_recovery_data, Observer, I, Host, Epoch, Expected, Round,
            Kind, At, Ceiling, {'Data'}},
    case select_resource(Ns, H, Est, Goal) of
        fail -> inactive;
        #{'Data' := {recovery, Sequence, Expiry, Preparation}}
          when is_integer(Sequence), Sequence > 0, is_integer(Expiry),
               Expiry > At, Expiry =< Ceiling,
               (Preparation =:= none orelse Preparation =:= required) ->
            Target = {agent_instance_ref, Ns, Anchor, I},
            Report = {observation, Sequence, Observation, Expiry},
            Event = {agent_recovery_ready, Observer, Target, Host, Epoch,
                     Expected, Round, Report, Kind, Preparation},
            Metadata = #{target => Target, epoch => Epoch, observer => Observer,
                         deadline => Deadline - (Ceiling - Expiry)},
            {agent_recovery, Batch, Event, Metadata, Expiry};
        _ -> {error, invalid_recovery_data}
    end;
select_resource_description(Ns, H, Est, agent_custody,
                            {{agent_instance_ref, Ns, _Anchor, I}, Epoch, Observer}) ->
    %% Exact identity and assignment are verified from the committed snapshot.
    Goal = {',', {agent_hosted, I, {'Host'}, Epoch, {'_'}},
                 {can_prepare_agent_key, Observer, I, {'Host'}, Epoch}},
    case select_resource(Ns, H, Est, Goal) of
        fail -> {error, preparation_not_authorized};
        _ -> authorized
    end;
select_resource_description(_, _, _, _, _) -> {error, invalid_resource_request}.

install_resource(Ns, _, {agent_hosts, Scope, Rows}) -> resource_result(project_agents(Ns, Scope, Rows));
install_resource(Ns, _, {agent_observers, Scope, Rows}) -> resource_result(project_agent_observers(Ns, Scope, Rows));
install_resource(Ns, H, {node_ontologies, Hosts, Contacts}) ->
    quod_node_actor:hosting_projection(Ns, H, all, Hosts, Contacts);
install_resource(_, _, {effect_custody, Capacity}) -> quod_effect_journal:configure_capacity(Capacity);
install_resource(Ns, H, {agent_work, Instance, Step}) -> resource_result(project_agent_work(Ns, H, Instance, Step));
install_resource(Ns, _, {agent_recovery, Batch, Event, Metadata, Expiry}) ->
    gen_server:call(quod_reg:via({quod_runtime, Ns}),
                    {deliver_recovery, Batch, Event, Metadata, Expiry}, infinity);
install_resource(_, _, authorized) -> ok;
install_resource(_, _, inactive) -> ok;
install_resource(_, _, {error, _} = Error) -> Error.

optional_selection(Ns, H, Est = #est{db = #db{mod = M, ref = R}}, Goal) ->
    %% Canonical removal leaves an empty interpreted procedure; both forms
    %% lack a selector definition. A defined selector whose body fails is an
    %% error instead. This semantic read retains the missing functor dependency.
    case M:get_procedure(R, functor_key(Goal)) of
        undefined -> absent;
        {clauses, []} -> absent;
        _ -> required_selection(Ns, H, Est, Goal)
    end.

local_node_reference() ->
    case quod_node_actor:principal() of
        {ok, Principal} ->
            {ok, Node} = quod_agent_ref:materialize_principal(Principal), Node;
        _ -> none
    end.

%% The current committed program supplies the selector; there is no caller
%% overlay and no governed bridge can perform I/O during row selection.
select_resource(Ns, H, Est, Goal) ->
    Context = quod_predicates:policy_verdict_context(Ns, H),
    case quod_proof_session:run_first(Goal, quod_predicates:set_context(Est, Context),
                                      #{read_set => true, read_only => true}) of
        {ok, Bindings, [], _ReadSet} -> Bindings;
        {fail, _} -> fail;
        {error, Reason} -> throw({resource_selection_failed, Reason})
    end.

required_selection(Ns, H, Est, Goal) ->
    case select_resource(Ns, H, Est, Goal) of
        fail -> throw({resource_selection_failed, {no_solution, functor_key(Goal)}});
        Bindings -> Bindings
    end.

resource_result(ok) -> ok;
resource_result({blocked, capacity}) -> ok;
resource_result({error, _} = Error) -> Error.

%%%===================================================================
%%% discovery — current stored declarations
%%%===================================================================

%% Capture after the canonical reducer, while this exact transaction's state
%% is still available. Unchanged transactions do no catalogue reads.
catalog_after(Est, AppliedOps) ->
    case lists:any(fun({Op, {Head, _}})
                        when Op =:= assert; Op =:= asserta; Op =:= retract ->
                           catalog_head(Head);
                      (_) -> false
                   end, AppliedOps) of
        true -> stored_runtime_catalog(Est);
        false -> keep
    end.

%% Capture ordered reaction heads and guards as source clauses.
%% Durable subscribes/2 declarations retain their stored-fact contract.
stored_runtime_catalog(Est) ->
    case quod_diff:interpreted_clauses(Est, {subscribes, 2}) of
        {ok, Subscriptions} ->
            Authored = quod_erlog_db_local_prove:wrap_state(Est),
            {_Tags, Reactions} = quod_common_primitives:authored_clauses({react_on, 2}, Authored),
            {ok, #{subscriptions => Subscriptions, reactions => Reactions}};
        {error, Reason} -> {error, {{subscribes, 2}, Reason}}
    end.

%% The stored clause order is the reaction order. Declaration writes have
%% already passed the ordinary ontology admission policy.
plan_runtime_catalog(StoredCatalog) when is_map(StoredCatalog) ->
    case plan_reactions(maps:get(reactions, StoredCatalog, []), []) of
        {ok, Reactions} ->
            {Subscriptions, RejectedSubscriptions} =
                plan_subscriptions(maps:get(subscriptions, StoredCatalog, [])),
            {ok, #{subscriptions => Subscriptions,
                   reactions => Reactions,
                   reaction_index => local_reaction_index(Reactions),
                   source_interests => source_interest_index(Reactions),
                   rejected_subscriptions => RejectedSubscriptions}};
        {error, _} = Error -> Error
    end;
plan_runtime_catalog(_) -> {error, invalid_runtime_catalog}.

plan_subscriptions(Clauses) when is_list(Clauses) ->
    {Targets, Rejected} =
        lists:foldl(
          fun(Clause, {Accepted, Refused}) ->
                  case valid_subscription_clause(Clause) of
                      {ok, Target} -> {Accepted#{Target => true}, Refused};
                      ignore       -> {Accepted, Refused};
                      error        -> {Accepted, Refused + 1}
                  end
          end, {#{}, 0}, Clauses),
    {lists:sort(maps:keys(Targets)), Rejected};
plan_subscriptions(_Malformed) ->
    {[], 1}.

valid_subscription_clause(
  {{subscribes, Ns, <<_:256>> = Anchor} = Head, {[], false}}) ->
    case quod_directory_shape:valid_namespace(Ns)
         andalso bounded_term(Head) of
        true  -> {ok, {Ns, Anchor}};
        false -> error
    end;
valid_subscription_clause(
  {{subscribes, _Ns, _Anchor}, {Goals, _HasCut}})
  when is_list(Goals), Goals =/= [] ->
    %% An ordinary rule that can prove subscribes/2 is application logic, not
    %% a runtime declaration and not malformed configuration.
    ignore;
valid_subscription_clause(_) ->
    error.

plan_reactions([Clause | Rest], Acc) ->
    Canonical = alpha_normalize(Clause),
    case valid_reaction_clause(Canonical) of
        {ok, _Source} -> plan_reactions(Rest, [reaction_head(Canonical) | Acc]);
        error -> {error, {invalid_reaction, Canonical}}
    end;
plan_reactions([], Acc) -> {ok, lists:reverse(Acc)};
plan_reactions(_, _) -> {error, invalid_runtime_catalog}.

reaction_head({':-', {react_on, _, _}, _} = Clause) -> Clause.

valid_reaction_clause({':-', {react_on, Pattern, Goal}, Guard} = Clause) ->
    case {reaction_pattern(Pattern), valid_goal_template(Goal),
          valid_callable(Guard), bounded_term(Clause)} of
        {{ok, Source, _}, true, true, true} -> {ok, Source};
        _ -> error
    end;
valid_reaction_clause(_) ->
    error.

reaction_pattern({from, Ns, <<_:256>> = Anchor, EventPattern}) ->
    case quod_directory_shape:valid_namespace(Ns)
         andalso valid_event_pattern(EventPattern) of
        true  -> {ok, {remote, {Ns, Anchor}}, EventPattern};
        false -> error
    end;
reaction_pattern(EventPattern) ->
    case valid_event_pattern(EventPattern) of
        true  -> {ok, local, EventPattern};
        false -> error
    end.

valid_event_pattern({Kind, FactPattern}) when Kind =:= assert; Kind =:= retract ->
    valid_callable(FactPattern) andalso bounded_term(FactPattern);
valid_event_pattern(EventPattern) ->
    quod_diff:valid_event_pattern(EventPattern).

valid_goal_template({_Variable}) -> true;
valid_goal_template(Goal) -> valid_callable(Goal).

valid_callable(Term) when is_atom(Term) -> true;
valid_callable(Term) when is_tuple(Term), tuple_size(Term) >= 2 ->
    is_atom(element(1, Term));
valid_callable(_) -> false.

bounded_term(Term) ->
    case quod_wire_term:encode(Term) of
        {ok, _} -> true;
        {error, bad_term} -> false
    end.

source_interest_index(Reactions) ->
    Reversed = lists:foldl(fun(Reaction, Index) ->
        case reaction_event_pattern(Reaction) of
            {from, Ns, Anchor, EventPattern} ->
                Target = {Ns, Anchor}, Key = functor_key(EventPattern),
                TargetIndex = maps:get(Target, Index, #{}),
                Updated = maps:update_with(Key, fun(L) -> [Reaction | L] end,
                                           [Reaction], TargetIndex),
                Index#{Target => Updated};
            _ -> Index
        end
    end, #{}, Reactions),
    maps:map(fun(_Target, Index) -> reverse_reaction_index(Index) end, Reversed).

local_reaction_index(Reactions) ->
    reverse_reaction_index(lists:foldl(fun(Reaction, Index) ->
        case reaction_event_pattern(Reaction) of
            {from, _, _, _} -> Index;
            Pattern ->
                maps:update_with(functor_key(Pattern), fun(L) -> [Reaction | L] end,
                                 [Reaction], Index)
        end
    end, #{}, Reactions)).

reverse_reaction_index(Index) ->
    maps:map(fun(_Key, Candidates) -> lists:reverse(Candidates) end, Index).

reaction_event_pattern({':-', {react_on, Pattern, _}, _}) -> Pattern.

%% Alpha-normalize Erlog variables by first occurrence. Stored clauses use
%% one-tuples (`{0}`, `{1}`, ...). Canonicalizing those names preserves sharing
%% within each clause. Anonymous `_` is fresh at every occurrence.
alpha_normalize(Term) ->
    {Normalized, _Vars, _Next} = alpha_normalize(Term, #{}, 0),
    Normalized.

alpha_normalize({Var}, Vars, Next) ->
    case Var of
        '_' -> {{Next}, Vars, Next + 1};
        _ ->
            case maps:find(Var, Vars) of
                {ok, Canonical} -> {{Canonical}, Vars, Next};
                error -> {{Next}, Vars#{Var => Next}, Next + 1}
            end
    end;
alpha_normalize(Term, Vars, Next) when is_tuple(Term) ->
    {Items, Vars1, Next1} = alpha_list(tuple_to_list(Term), Vars, Next),
    {list_to_tuple(Items), Vars1, Next1};
alpha_normalize([Head | Tail], Vars, Next) ->
    {Head1, Vars1, Next1} = alpha_normalize(Head, Vars, Next),
    {Tail1, Vars2, Next2} = alpha_normalize(Tail, Vars1, Next1),
    {[Head1 | Tail1], Vars2, Next2};
alpha_normalize(Term, Vars, Next) ->
    {Term, Vars, Next}.

alpha_list([Item | Rest], Vars, Next) ->
    {Item1, Vars1, Next1} = alpha_normalize(Item, Vars, Next),
    {Rest1, Vars2, Next2} = alpha_list(Rest, Vars1, Next1),
    {[Item1 | Rest1], Vars2, Next2};
alpha_list([], Vars, Next) ->
    {[], Vars, Next}.

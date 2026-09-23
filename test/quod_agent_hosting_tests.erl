-module(quod_agent_hosting_tests).
-include_lib("eunit/include/eunit.hrl").
-export([quod_predicate_module/0, load/1, test_host_barrier/3, test_fill_agents/3]).

quod_predicate_module() -> true.
load(Est) ->
    Projection = quod_predicates:register(Est, {test_host_barrier, 0}, projection,
                                           ?MODULE, test_host_barrier),
    Before = quod_predicates:register(Projection, {test_host_before, 0}, projection,
                                       ?MODULE, test_host_barrier),
    Reaction = quod_predicates:register(Before, {test_reaction_barrier, 0}, reaction,
                              ?MODULE, test_host_barrier),
    quod_predicates:register(Reaction, {test_fill_agents, 0}, reaction,
                              ?MODULE, test_fill_agents).
test_host_barrier(test_host_before, Next, St) ->
    quod_reg:where({host_test, barrier}) ! {host_projection_before, self()},
    receive release -> erlog_int:prove_body(Next, St) end;
test_host_barrier(_, Next, St) ->
    quod_reg:where({host_test, barrier}) ! {host_projection_waiting, self()},
    receive release -> erlog_int:prove_body(Next, St) end.


test_fill_agents(test_fill_agents, _Next, St) ->
    Context = quod_predicates:context(St),
    Ns = quod_predicates:ctx_ns(Context),
    Height = quod_predicates:ctx_height(Context),
    Executor = quod_predicates:ctx_executor(Context),
    Goal = {record_ping, binary:copy(<<"x">>, 64000)},
    Results = [quod_runtime:agent_request(Ns, Height, E, execute, Goal, 5000)
               || E <- lists:duplicate(9, Executor) ++
                       lists:duplicate(9, {agent, other, 1, <<91:256>>})],
    quod_reg:where({host_test, barrier}) ! {agent_queue_filled, self(), Results},
    receive release -> erlog_int:fail(St) end.


hosted_reactions_and_incarnation_recovery_test_() ->
    {timeout, 60, fun() -> with_host(fun exercise/1) end}.

hosted_agents_exchange_committed_events_test_() ->
    {timeout, 60, fun() -> with_host(fun exchange/1) end}.

signed_node_request_expiry_survives_foreign_scope_test_() ->
    {timeout, 60, fun() -> with_host(fun(#{namespace := Ns}) ->
        Expiry = quod_time:now_ms() + 10000,
        Goal = {'::', Ns, {',', {current_request_expiry, {0}},
                          {assertz, {recorded_expiry, {0}}}}},
        {ok, Bytes, Signature} = quod_node_actor:signed_goal(
            execute, Goal, crypto:strong_rand_bytes(32), Expiry),
        ?assertMatch({ok, _, _}, quod_client_goal_ingress:submit(Bytes, Signature)),
        ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(Ns, {recorded_expiry, Expiry})),
        {ok, WrongBytes, WrongSignature} = quod_node_actor:signed_goal(
            read, {'::', Ns, {current_request_expiry, Expiry + 1}},
            crypto:strong_rand_bytes(32), Expiry),
        ?assertMatch({ok, _, {normalized, {failed, _}}},
                     quod_client_goal_ingress:submit(WrongBytes, WrongSignature))
    end) end}.

conflicting_hosting_owners_are_permanently_unhealthy_test_() ->
    {timeout, 60, fun() -> with_host(fun(#{namespace := Ns}) ->
        ?assertEqual({error, unhealthy}, quod_runtime:await_revision(Ns, agent_hosting, 1, 5000)),
        ?assertMatch(#{mode := unhealthy, reconcile_failures := 1}, quod_runtime:stats(Ns))
    end, [{state_handler, other_hosting, [], [], other_hosting_projection},
          {':-', {other_hosting_projection, {'Scope'}}, {project_agent_hosts, all, []}}]) end}.

agent_queue_has_aggregate_byte_bound_and_reclaims_on_discard_test_() ->
    {timeout, 60, fun() -> with_host(fun(#{namespace := Ns, reference := Ref,
                                         node := Node, key := Key}) ->
        commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
        {Owner, _} = installed(Ref, 1),
        OtherRef = setelement(4, Ref, other),
        commit(Ns, {goal, {agent_hosted, other, Node, 1, <<91:256>>}}),
        {Owner, _} = installed(OtherRef, 1),
        true = quod_reg:reg({host_test, barrier}),
        try
            commit(Ns, {trigger_event, fill_agents}),
            receive
                {agent_queue_filled, _Runner, Results} ->
                    ?assertEqual(16, length([ok || ok <- Results])),
                    ?assertEqual(2, length([busy || {error, busy} <- Results])),
                    #{agent_pending_bytes := Bytes} = quod_runtime:stats(Ns),
                    ?assert(Bytes > 0 andalso Bytes =< 1048576),
                    exit(Owner, kill)
            after 5000 -> error(queue_not_filled)
            end,
            %% Runtime restart discards the unreleased queues; no historical
            %% reaction replay can reconstruct them in the replacement owner.
            {NextOwner, _} = installed(Ref, 1),
            {NextOwner, _} = installed(OtherRef, 1),
            ?assertNotEqual(Owner, NextOwner),
            ?assertMatch(#{agent_pending_bytes := 0}, quod_runtime:stats(Ns)),
            ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, {ping, {'Anything'}}))
        after gproc:unreg(quod_reg:name({host_test, barrier})) end
    end) end}.

atomic_recovery_commits_one_diff_and_restores_projection_test_() ->
    {timeout, 60, fun() -> with_host(fun(Ctx) -> atomic_recovery(Ctx, true) end) end}.

failed_atomic_recovery_does_not_commit_its_report_test_() ->
    {timeout, 60, fun() -> with_host(fun(Ctx) -> atomic_recovery(Ctx, rollback) end) end}.

reporting_without_takeover_authority_retains_observation_test_() ->
    {timeout, 60, fun() -> with_host(fun(Ctx) -> atomic_recovery(Ctx, false) end) end}.

atomic_recovery(#{namespace := Ns, reference := Ref, node := Node, key := Key}, Allow) ->
    commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
    {Owner, Child} = installed(Ref, 1),
    Round = crypto:strong_rand_bytes(32),
    Expiry = quod_time:now_ms() + 10000,
    {ok, Blob} = quod_wire_term:encode_canonical(Ref),
    {ok, NextKey} = quod_agent_vault:generate(Blob),
    Policy = [{can_report_agent_failure, Node, actor, Node, {'_'}},
              {can_prepare_agent_key, Node, actor, Node, 1},
              {':-', {agent_recovery_candidate, Node, actor, Node, 1, Round, Node, 1},
                       {agent_failure_support, actor, Node, 1, Round, Node, process_down}}],
    lists:foreach(fun(Fact) -> commit(Ns, {assertz, Fact}) end,
                  case Allow of false -> Policy;
                                _ -> [{can_assign_agent_host, Node, actor, {'_'}, {'_'}, Node, {'_'}}|Policy] end),
    ?assertMatch({ok, _, _}, node_goal(Ns,
      {goal, {agent_recovery_current, actor, Node, 1, Round}}, Expiry)),
    ?assertMatch({ok, _, _}, node_goal(Ns,
      {prepare_agent_and_converge, actor, Node, 1, Node, NextKey}, Expiry)),
    Before = quod_prolog:applied(Ns),
    Observation = {observation, 1, crypto:strong_rand_bytes(32), Expiry},
    Recovery = {report_agent_and_converge, actor, Node, 1, Round, Observation, process_down},
    Goal = case Allow of rollback -> {',', Recovery, fail}; _ -> Recovery end,
    Result = node_goal(Ns, Goal, Expiry),
    case Allow of
        true ->
            ?assertMatch({ok, _, _}, Result),
            ?assertEqual(Before + 1, quod_prolog:applied(Ns)),
            {Owner, Replacement} = installed(Ref, 2),
            ?assertNotEqual(Child, Replacement),
            ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(
              Ns, {agent_hosted, actor, Node, 2, NextKey})),
            ?assertMatch({fail, _}, quod_prolog:prove_ro(
              Ns, {agent_recovery_round, actor, Node, 1, Round}));
        false ->
            ?assertMatch({ok, _, _}, Result),
            ?assertEqual(Before + 1, quod_prolog:applied(Ns)),
            ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(
              Ns, {agent_hosted, actor, Node, 1, Key}));
        rollback ->
            ?assertMatch({ok, _, {normalized, {failed, _}}}, Result),
            ?assertEqual(Before, quod_prolog:applied(Ns)),
            ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(
              Ns, {agent_hosted, actor, Node, 1, Key})),
            ?assertEqual({Owner, [#{pid => Child, binding =>
              #{reference => Ref, epoch => 1, public_key => Key}}]}, quod_runtime:agents(Ns))
    end,
    Report = quod_prolog:prove_ro(Ns,
      {agent_failure_report, actor, Node, 1, Round, Node, Observation, process_down}),
    case Allow of
        false -> ?assertMatch({ok, [#{}], _}, Report);
        _ -> ?assertMatch({fail, _}, Report)
    end.

node_goal(Ns, Goal, Expiry) ->
    {ok, Bytes, Signature} = quod_node_actor:signed_goal(
      execute, {'::', Ns, Goal}, crypto:strong_rand_bytes(32), Expiry),
    quod_client_goal_ingress:submit(Bytes, Signature).

host_teardown_keeps_runtime_responsive_test_() ->
    {timeout, 60, fun() -> with_host(fun(Ctx) -> host_teardown(Ctx, 0) end) end}.

host_teardown_uses_runner_budget_not_default_call_timeout_test_() ->
    {timeout, 60, fun() -> with_host(fun(Ctx) -> host_teardown(Ctx, 5500) end) end}.

host_teardown(#{namespace := Ns, reference := Ref, node := Node, key := Key}, HoldMs) ->
        commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
        {Owner, Child} = installed(Ref, 1),
        {ok, Blob} = quod_wire_term:encode_canonical(Ref),
        {ok, NextKey} = quod_agent_vault:generate(Blob),
        ok = sys:suspend(Child),
        1 = erlang:trace(Owner, true, ['receive']),
        try
            commit(Ns, {goal, {agent_assignment, actor, Node, 1, Node, 2, NextKey}}),
            Runner = receive
                {trace, Owner, 'receive', {'$gen_call', {Caller, _}, {project_agents, _, _, _, _}}} -> Caller
            after 5000 -> error(projection_not_delivered)
            end,
            case HoldMs of
                0 -> ok;
                _ ->
                    %% A deadline control, not a readiness delay: cross the old
                    %% call timeout while staying inside the runner's 10s budget.
                    Boundary = erlang:start_timer(HoldMs, self(), call_deadline_boundary),
                    receive {timeout, Boundary, call_deadline_boundary} -> ok end,
                    ?assert(is_process_alive(Runner))
            end,
            %% The old child cannot finish stopping. The owner must nevertheless
            %% answer, and must not expose the replacement until that stop joins.
            ?assertMatch(#{}, gen_server:call(Owner, get_stats, 1000)),
            ?assertEqual({Owner, []}, quod_runtime:agents(Ns))
        after
            erlang:trace(Owner, false, ['receive']),
            sys:resume(Child)
        end,
        {Owner, Next} = installed(Ref, 2),
        ?assertNotEqual(Child, Next),
        ?assertNot(is_process_alive(Child)),
        commit(Ns, {trigger_event, {do_work, after_teardown}}),
        receive {agent_request_finished, Owner, Next, _, _, Result} ->
                    ?assertMatch({ok, _, _}, Result)
        after 5000 -> error(replacement_not_running)
        end.

failed_later_block_cannot_release_earlier_request_test_() ->
    {timeout, 60, fun() -> with_host(fun failed_batch/1) end}.

failed_batch(#{namespace := Ns, reference := Ref, node := Node, key := Key}) ->
    commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
    {Owner, Child} = installed(Ref, 1),
    Monitor = monitor(process, Child),
    1 = erlang:trace(Child, true, [procs]),
    true = quod_reg:reg({host_test, barrier}),
    commit(Ns, {trigger_event, pause_batch}),
    Runner = projection_waiting(),
    try
        commit(Ns, {trigger_event, {do_work, must_not_run}}),
        %% The existing founding gate rejects this later block's removal.
        commit(Ns, {retract, {react_on, {agent, actor}, {do_work, {'Value'}},
                             {submit_agent_goal, actor, execute, {record_ping, {'Value'}}, 5000}}}),
        quod_runtime:stats(Ns)
    after Runner ! release, gproc:unreg(quod_reg:name({host_test, barrier})) end,
    receive {'DOWN', Monitor, process, Child, _} -> ok after 5000 -> error(child_not_discarded) end,
    Delivered = erlang:trace_delivered(all),
    receive {trace_delivered, all, Delivered} -> ok after 5000 -> error(trace_not_delivered) end,
    %% The completed trace barrier makes this absence assertion deterministic:
    %% no request worker was started before the failed batch discarded the child.
    receive {trace, Child, spawn, _, _} -> error(request_released_from_failed_batch)
    after 0 -> ok
    end,
    ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, {ping, must_not_run})).

host_move_withdraws_child_and_revokes_released_signature_test_() ->
    {timeout, 60, fun() -> with_host(fun host_move/1) end}.

host_move(#{namespace := Ns, reference := Ref, node := Node, key := Key}) ->
    commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
    {Owner, Child} = installed(Ref, 1),
    {ok, Network} = quod_ontology:network_identity(),
    Request = #{network_identity => Network, agent_namespace => Ns,
      agent_genesis_anchor => element(3, Ref), agent_instance_text => <<"actor.">>,
      signing_public_key => Key, operation_id => crypto:strong_rand_bytes(32),
      not_after_ms => erlang:system_time(millisecond) + 10000,
      mode => execute, parser_version => 2, goal_text => <<"record_ping(stale).">>},
    {ok, Bytes, Signature} = quod_agent_vault:sign(Request, quod_time:mono_ms() + 5000),
    Remote = setelement(2, Node, <<"remote-node">>),
    Monitor = monitor(process, Child),
    commit(Ns, {goal, {agent_assignment, actor, Node, 1, Remote, 2, <<88:256>>}}),
    receive {'DOWN', Monitor, process, Child, _} -> ok after 5000 -> error(host_not_withdrawn) end,
    ?assertEqual({Owner, []}, quod_runtime:agents(Ns)),
    ?assertMatch({ok, _, {normalized, {failed, _}}},
                 quod_client_goal_ingress:submit(Bytes, Signature)),
    ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, {ping, stale})),
    {ok, Blob} = quod_wire_term:encode_canonical(Ref),
    {ok, NextKey} = quod_agent_vault:generate(Blob),
    commit(Ns, {goal, {agent_assignment, actor, Remote, 2, Node, 3, NextKey}}),
    {Owner, NextChild} = installed(Ref, 3),
    commit(Ns, {trigger_event, {do_work, returned}}),
    receive {agent_request_finished, Owner, NextChild, _, _, Result} ->
                ?assertMatch({ok, _, _}, Result)
    after 5000 -> error(returned_host_not_running)
    end.

running_request_deadline_kills_worker_without_claiming_rejection_test_() ->
    {timeout, 60, fun() -> with_host(fun(#{namespace := Ns, reference := Ref,
                                         node := Node, key := Key}) ->
        commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
        {Owner, Child} = installed(Ref, 1),
        Vault = quod_reg:where({agent_vault, node}),
        ok = sys:suspend(Vault),
        1 = erlang:trace(Child, true, [procs]),
        try
            commit(Ns, {trigger_event, {do_short_work, expires}}),
            Worker = receive {trace, Child, spawn, Pid, _} -> Pid
                     after 5000 -> error(worker_not_started) end,
            %% Freeze actual execution, independently of the wall-clock expiry
            %% and backend timeout. The child must cancel it at its own deadline.
            true = erlang:suspend_process(Worker),
            Monitor = monitor(process, Worker),
            receive
                {agent_request_finished, Owner, Child, _, _, Result} ->
                    ?assertMatch({error, {outcome_unknown, {operation, Ns, _, _, _}}}, Result)
            after 5000 -> error(deadline_not_enforced)
            end,
            receive {'DOWN', Monitor, process, Worker, killed} -> ok
            after 5000 -> error(expired_worker_not_joined)
            end,
            ?assert(is_process_alive(Child))
        after
            erlang:trace(Child, false, [procs]),
            sys:resume(Vault)
        end,
        ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, {ping, expires}))
    end) end}.

expired_queued_request_never_reaches_signing_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Ref = {agent_instance_ref, <<"expired-agent">>, <<1:256>>, worker},
    Binding = #{reference => Ref, epoch => 1, public_key => <<2:256>>},
    true = quod_reg:subscribe({agent, Ref}),
    {ok, Child} = quod_agent:start(self(), Binding),
    Token = make_ref(),
    try
        Child ! {agent_request, self(), Token, 7,
                 {execute, true, quod_time:now_ms() + 60000, quod_time:mono_ms() - 1}},
        %% The child's synchronous reply establishes that the request is queued.
        ?assertEqual({error, unsupported}, gen_server:call(Child, barrier)),
        Child ! {agent_release, self(), 7},
        receive
            {agent_request_finished, _, Child, Binding, Token, Result} ->
                ?assertEqual({error, deadline_exceeded}, Result)
        after 5000 -> error(expiry_not_reported)
        end
    after gen_server:stop(Child), quod_reg:unsubscribe({agent, Ref}) end.

hosting_refresh_survives_boot_and_uses_declared_owner_test_() ->
    {timeout, 60, fun() -> with_host(fun lifecycle_refresh/1) end}.

lifecycle_refresh(#{node := Node, directory := Dir, identity := Identity}) ->
    true = quod_reg:reg({host_test, barrier}),
    true = quod_reg:reg({namespace_manager, node}),
    {ok, Principal} = quod_node_actor:principal(),
    application:unset_env(quod, node_actor_principal),
    Ns = <<"host-test-lifecycle">>,
    Remote = setelement(2, Node, <<"remote">>),
    Rows = [{host, I, Remote, 1, <<81:256>>} || I <- lists:seq(1, 1100)] ++
           [{host, local, Node, 1, <<82:256>>}],
    true = quod_reg:subscribe({agent_hosting, Ns}),
    Sup = start_ontology(Ns, Dir, Identity, [],
      [{state_handler, custom_host_owner, [{'/', custom_hosts, 1}], [], install_hosts},
       {custom_hosts, Rows},
       {':-', {install_hosts, {'_'}},
         {',', test_host_before,
          {',', {custom_hosts, {'Rows'}},
           {',', {project_agent_hosts, all, {'Rows'}}, test_host_barrier}}}}]),
    Ref = {agent_instance_ref, Ns, quod_simplex:genesis_hash(Ns), local},
    try
        First = projection_before(),
        Runtime = quod_reg:where({quod_runtime, Ns}),
        ?assertEqual({Runtime, []}, quod_runtime:agents(Ns)),
        application:set_env(quod, node_actor_principal, Principal),
        quod_reg:publish({node_actor, node}, {node_actor_installed, self(), {ok, Principal}}),
        %% Snapshot call establishes that the notice was handled before the
        %% first runner can publish its declaration index.
        quod_runtime:stats(Ns),
        First ! release,
        Initial = projection_waiting(),
        Initial ! release,
        {Runtime, _} = installed(Ref, 1),
        %% This extra run proves the notice was parked before any projection
        %% owner was registered, rather than merely relying on its new snapshot.
        Refresh = projection_before(),
        Refresh ! release,
        Second = projection_waiting(),
        {Runtime, [#{pid := Child}]} = quod_runtime:agents(Ns),
        Parent = self(),
        ObserveDown = fun(State, {in, {{agent_down, local}, _, process, Pid, _}}, _) when Pid =:= Child ->
                              Parent ! hosting_down_handled, State;
                         (State, _, _) -> State
                      end,
        ok = sys:install(Runtime, {ObserveDown, none}),
        exit(Child, kill),
        receive hosting_down_handled -> ok after 5000 -> error(child_down_not_received) end,
        quod_runtime:stats(Ns),
        ok = sys:remove(Runtime, ObserveDown),
        Second ! release,
        Repair = projection_before(),
        Repair ! release,
        Third = projection_waiting(),
        Third ! release,
        {Runtime, Replacement} = installed(Ref, 1),
        ?assertNotEqual(Child, Replacement),
        ?assertMatch(#{hosted_agents := 1, reconcile_failures := 0}, quod_runtime:stats(Ns)),
        application:unset_env(quod, node_actor_principal),
        quod_reg:publish({node_actor, node}, {node_actor_installed, self(), {error, unavailable}}),
        WithdrawalBefore = projection_before(),
        WithdrawalBefore ! release,
        Withdrawal = projection_waiting(),
        ?assertNot(is_process_alive(Replacement)),
        ?assertEqual({Runtime, []}, quod_runtime:agents(Ns)),
        Withdrawal ! release
    after
        application:set_env(quod, node_actor_principal, Principal),
        stop_ontology(Sup),
        quod_reg:unsubscribe({agent_hosting, Ns}),
        gproc:unreg(quod_reg:name({host_test, barrier})),
        gproc:unreg(quod_reg:name({namespace_manager, node}))
    end.

projection_before() ->
    receive {host_projection_before, Runner} -> Runner
    after 5000 -> error(projection_did_not_start)
    end.

projection_waiting() ->
    receive {host_projection_waiting, Runner} -> Runner
    after 5000 -> error(projection_did_not_run)
    end.

exchange(#{namespace := SenderNs, reference := SenderRef, node := Node, key := Key,
           directory := Dir, identity := Identity}) ->
    commit(SenderNs, {goal, {agent_hosted, actor, Node, 1, Key}}),
    installed(SenderRef, 1),
    {ok, Foreign} = quod_foreign_log:start_link(#{cache_dir => filename:join(Dir, "foreign")}),
    ReceiverNs = <<"host-test-receiver">>,
    SourceAnchor = element(3, SenderRef),
    Source = filename:join(code:priv_dir(quod), "ontologies/agent_instance.pl"),
    true = quod_reg:subscribe({agent_hosting, ReceiverNs}),
    Receiver = start_ontology(ReceiverNs, Dir, Identity, quod_prolog:genesis_diff(Source),
      [{subscribes, SenderNs, SourceAnchor},
       {can_assign_agent_host, {node, maps:get(pubkey, Identity)}, receiver, {'_'}, {'_'}, Node, {'_'}},
       {can_invoke, {'_'}, Node, {'_'}, ReceiverNs},
       {can_invoke, {record_reply, {'_'}}, {agent_instance_ref, ReceiverNs, {'_'}, receiver}, {'_'}, ReceiverNs},
       {can_request_agent_signature, Node, receiver, {'_'}},
       {react_on, {agent, receiver}, {from, SenderNs, SourceAnchor, {request, {'Id'}}},
         {submit_agent_goal, receiver, execute, {record_reply, {'Id'}}, 5000}},
       {':-', {record_reply, {'Id'}}, {assertz, {answered, {'Id'}}}}]),
    Ref = {agent_instance_ref, ReceiverNs, quod_simplex:genesis_hash(ReceiverNs), receiver},
    {ok, Blob} = quod_wire_term:encode_canonical(Ref),
    {ok, ReceiverKey} = quod_agent_vault:generate(Blob),
    true = quod_reg:subscribe({agent, Ref}),
    try
        commit(ReceiverNs, {goal, {agent_hosted, receiver, Node, 1, ReceiverKey}}),
        {Owner, Child} = installed(Ref, 1),
        await_source_ready(ReceiverNs),
        commit(SenderNs, {trigger_event, {do_work, exchange}}),
        receive {agent_request_finished, Owner, Child, _, _, Result} -> ?assertMatch({ok, _, _}, Result)
        after 10000 -> error(cross_ontology_request_timeout)
        end,
        ?assertMatch({fail, _}, quod_prolog:prove_ro(SenderNs, {request, exchange})),
        ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(ReceiverNs, {answered, exchange})),
        exit(Owner, kill),
        {NextOwner, NextChild} = installed(Ref, 1),
        ?assertNotEqual(Owner, NextOwner),
        await_source_ready(ReceiverNs),
        ?assertMatch({ok, [#{'Ids' := [exchange]}], _}, quod_prolog:prove_ro(
          ReceiverNs, {findall, {'Id'}, {answered, {'Id'}}, {'Ids'}})),
        commit(SenderNs, {trigger_event, {do_work, after_receiver_restart}}),
        receive {agent_request_finished, NextOwner, NextChild, _, _, Result2} -> ?assertMatch({ok, _, _}, Result2)
        after 10000 -> error(cross_ontology_request_after_restart_timeout)
        end,
        ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(ReceiverNs, {answered, after_receiver_restart}))
    after
        quod_reg:unsubscribe({agent, Ref}),
        quod_reg:unsubscribe({agent_hosting, ReceiverNs}),
        stop_ontology(Receiver), gen_server:stop(Foreign)
    end.

%% Observe actual receipt, then use a synchronous snapshot to establish that
%% the owner's handler finished. Install observation before taking the snapshot;
%% each later check is triggered by a real follow notice, never a polling timer.
await_source_ready(Ns) ->
    Runtime = quod_reg:where({quod_runtime, Ns}),
    Parent = self(), Tag = make_ref(),
    Observe = fun(State, {in, {quod_foreign_follow, _, _, _, _}}, _) ->
                      Parent ! {source_notice, Tag}, State;
                 (State, _, _) -> State
              end,
    ok = sys:install(Runtime, {Observe, none}),
    try await_source_ready_snapshot(Ns, Tag)
    after sys:remove(Runtime, Observe) end.

await_source_ready_snapshot(Ns, Tag) ->
    case quod_runtime:stats(Ns) of
        #{source_views_ready := 1} -> ok;
        _ -> receive {source_notice, Tag} -> await_source_ready_snapshot(Ns, Tag)
             after 10000 -> error(source_view_not_ready)
             end
    end.


exercise(#{namespace := Ns, reference := Ref, node := Node, key := Key}) ->
    commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
    {Owner, First} = installed(Ref, 1),
    OtherRef = setelement(4, Ref, other),
    commit(Ns, {goal, {agent_hosted, other, Node, 1, <<91:256>>}}),
    {Owner, Other} = installed(OtherRef, 1),
    ?assertEqual({error, stale_projection}, quod_runtime:project_agents(Ns, 1, agent_hosting, all, [])),
    ?assertEqual({error, stale_executor}, quod_runtime:agent_request(
      Ns, 1, {agent, actor, 1, Key}, execute, {record_ping, forged}, 5000)),
    commit(Ns, {trigger_event, {do_work, first}}),
    receive
        {agent_request_finished, Owner, First, _, _, Result} ->
            ?assertMatch({ok, _, _}, Result)
    after 10000 -> error({agent_request_timeout, quod_runtime:stats(Ns)})
    end,
    ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(Ns, {ping, first})),
    ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, {do_work, first})),
    Monitor = monitor(process, First),
    exit(First, kill),
    receive {'DOWN', Monitor, process, First, killed} -> ok after 5000 -> error(child_still_alive) end,
    {Owner, Second} = installed(Ref, 1),
    ?assertNotEqual(First, Second),
    {Owner, Children} = quod_runtime:agents(Ns),
    ?assert(lists:any(fun(#{binding := #{reference := R}, pid := P}) ->
                             R =:= OtherRef andalso P =:= Other
                     end, Children)),
    {ok, Blob} = quod_wire_term:encode_canonical(Ref),
    {ok, NextKey} = quod_agent_vault:generate(Blob),
    commit(Ns, {goal, {agent_assignment, actor, Node, 1, Node, 2, NextKey}}),
    {Owner, Third} = installed(Ref, 2),
    ?assertNot(is_process_alive(Second)),
    ?assertNotEqual(Second, Third),
    ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(Ns, {agent_key, actor, Key, revoked})),
    RuntimeMonitor = monitor(process, Owner),
    ChildMonitor = monitor(process, Third),
    exit(Owner, kill),
    receive {'DOWN', RuntimeMonitor, process, Owner, killed} -> ok after 5000 -> error(runtime_still_alive) end,
    {NextOwner, Fourth} = installed(Ref, 2),
    ?assertNotEqual(Owner, NextOwner),
    ?assertNotEqual(Third, Fourth),
    receive {'DOWN', ChildMonitor, process, Third, _} -> ok after 5000 -> error(orphaned_child) end,
    %% Reconcile reconstructs the host; the earlier occurrence is not replayed.
    ?assertMatch({ok, [#{'Values' := [first]}], _}, quod_prolog:prove_ro(
      Ns, {findall, {'V'}, {ping, {'V'}}, {'Values'}})),
    commit(Ns, {trigger_event, {do_work, after_restart}}),
    receive
        {agent_request_finished, NextOwner, Fourth, _, _, Result2} ->
            ?assertMatch({ok, _, _}, Result2)
    after 10000 -> error(agent_request_after_restart_timeout)
    end,
    ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(Ns, {ping, after_restart})),
    ?assertMatch({fail, _}, quod_prolog:execute(Ns,
      {goal, {agent_assignment, actor, Node, 2, Node, 3, Key}})).

installed(Ref, Epoch) ->
    receive
        {agent_installed, Owner, Pid, #{reference := Ref, epoch := Epoch}, _Height} -> {Owner, Pid}
    after 10000 -> error({agent_install_timeout, Ref, Epoch})
    end.

commit(Ns, Goal) ->
    ?assertMatch({ok, _, _}, quod_ct:rp(Ns, Goal)).

with_host(Fun) -> with_host(Fun, []).

with_host(Fun, ExtraFacts) ->
    BeamPath = filename:join(filename:dirname(code:which(quod_predicates)),
                             atom_to_list(?MODULE) ++ ".beam"),
    {ok, _} = file:copy(code:which(?MODULE), BeamPath),
    {ok, _} = application:ensure_all_started(gproc),
    Keys = [node_pubkey, identity_key, node_actor_principal, namespace_desired,
            runtime_event_budget_ms, runtime_reconcile_budget_ms],
    Saved = [{K, application:get_env(quod, K)} || K <- Keys],
    %% Test barriers intentionally wait for the test process; give that
    %% synchronization its own budget without altering production defaults.
    application:set_env(quod, runtime_event_budget_ms, 10000),
    application:set_env(quod, runtime_reconcile_budget_ms, 10000),
    {Pub, _} = Pair = quod_identity:generate(),
    Identity = #{pubkey => Pub, key => quod_identity:key_term(Pair)},
    application:set_env(quod, node_pubkey, Pub),
    application:set_env(quod, identity_key, maps:get(key, Identity)),
    application:set_env(quod, namespace_desired,
      #{content => #{quod_ontology:root_ns() => #{genesis_hash => <<42:256>>}}, brahms => #{}}),
    {ok, Router} = quod_ask_router:start_link(),
    {ok, Auth} = quod_client_auth:start_link(#{network_id => <<42:256>>, node_key => Pub}),
    Dir = filename:join("/tmp", "quod_hosted_" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    ok = filelib:ensure_dir(filename:join(Dir, "file")),
    Unlock = filename:join(Dir, "unlock"),
    ok = quod_identity:write_atomic(Unlock, crypto:strong_rand_bytes(32), 8#600),
    {ok, Vault} = quod_agent_vault:start_link(#{directory => filename:join(Dir, "keys"), unlock_file => Unlock}),
    NodeNs = <<"host-test-node">>, Ns = <<"host-test-agent">>,
    NodeOntology = start_ontology(NodeNs, Dir, Identity, [],
      [{agent_key, physical_node, Pub, active},
       {can_invoke, {'_'}, {agent_instance_ref, NodeNs, {'_'}, physical_node}, {'_'}, NodeNs}]),
    Node = {agent_instance_ref, NodeNs, quod_simplex:genesis_hash(NodeNs), physical_node},
    {ok, NodeBlob} = quod_wire_term:encode_canonical(Node),
    application:set_env(quod, node_actor_principal, {agent, NodeBlob}),
    Source = filename:join(code:priv_dir(quod), "ontologies/agent_instance.pl"),
    Diff = quod_prolog:genesis_diff(Source),
    true = quod_reg:subscribe({agent_hosting, Ns}),
    ActorOntology = start_ontology(Ns, Dir, Identity, Diff,
      [{can_assign_agent_host, {node, Pub}, actor, {'_'}, {'_'}, Node, {'_'}},
       {can_assign_agent_host, {node, Pub}, actor, {'_'}, {'_'}, setelement(2, Node, <<"remote-node">>), {'_'}},
       {can_assign_agent_host, {node, Pub}, other, {'_'}, {'_'}, Node, {'_'}},
       {can_invoke, {'_'}, Node, {'_'}, Ns},
       {can_invoke, {record_ping, {'_'}}, {agent_instance_ref, Ns, {'_'}, actor}, {'_'}, Ns},
       {can_request_agent_signature, Node, actor, {'_'}},
       {react_on, {node, Pub}, pause_batch, test_reaction_barrier},
       {react_on, {agent, actor}, fill_agents, test_fill_agents},
       {react_on, {agent, actor}, {do_short_work, {'Value'}},
        {submit_agent_goal, actor, execute, {record_ping, {'Value'}}, 1000}},
       {react_on, {agent, actor}, {do_work, {'Value'}},
        {submit_agent_goal, actor, execute, {record_ping, {'Value'}}, 5000}},
       {':-', {record_ping, {'Value'}},
         {',', {assertz, {ping, {'Value'}}}, {trigger_event, {request, {'Value'}}}}}] ++ ExtraFacts),
    Ref = {agent_instance_ref, Ns, quod_simplex:genesis_hash(Ns), actor},
    {ok, RefBlob} = quod_wire_term:encode_canonical(Ref),
    {ok, Key} = quod_agent_vault:generate(RefBlob),
    true = quod_reg:subscribe({agent, Ref}),
    try Fun(#{namespace => Ns, reference => Ref, node => Node, key => Key,
              directory => Dir, identity => Identity})
    after
        quod_reg:unsubscribe({agent, Ref}),
        quod_reg:unsubscribe({agent_hosting, Ns}),
        stop_ontology(ActorOntology), stop_ontology(NodeOntology),
        gen_server:stop(Vault), gen_server:stop(Auth), gen_server:stop(Router),
        file:del_dir_r(Dir),
        ok = file:delete(BeamPath),
        lists:foreach(fun({K, undefined}) -> application:unset_env(quod, K);
                         ({K, {ok, V}}) -> application:set_env(quod, K, V)
                      end, Saved)
    end.

start_ontology(Ns, Dir, Identity, Diff, Terms) ->
    true = quod_reg:subscribe({runtime, Ns}),
    {ok, Sup} = quod_ns:start_link(Ns,
      #{node_id => maps:get(pubkey, Identity), identity => Identity,
        data_dir => filename:join(Dir, binary_to_list(Ns)), mode => create,
        external_predicate_modules => [quod_agent_predicates, ?MODULE],
        genesis_diff => Diff ++ quod_prolog:terms_to_diff(Terms)}),
    unlink(Sup),
    receive {replay_ready, _, _} -> ok after 10000 -> error({ontology_not_ready, Ns}) end,
    quod_reg:unsubscribe({runtime, Ns}),
    Sup.

stop_ontology(Sup) ->
    Monitor = monitor(process, Sup),
    exit(Sup, shutdown),
    receive {'DOWN', Monitor, process, Sup, _} -> ok after 5000 -> error(namespace_stop_timeout) end.

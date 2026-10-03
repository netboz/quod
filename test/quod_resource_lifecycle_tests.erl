-module(quod_resource_lifecycle_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

unchanged_notices_and_unrelated_changes_do_no_resource_work_test_() ->
    {timeout, 60, fun() -> with_owner(fun(#{namespace := Ns}, Owner) ->
        commit(Ns, both({assertz, {lifecycle_mode, first}},
                       replace_selector({lifecycle_mode, {'_'}}))),
        settled(Owner),
        Trace = start_trace(Owner),
        try
            quod_runtime:reconcile_now(Ns),
            settled(Owner),
            assert_no_work(counts(Trace)),
            commit(Ns, {assertz, unrelated_resource_fact}),
            settled(Owner),
            assert_no_work(counts(Trace)),
            commit(Ns, both({retract, {lifecycle_mode, first}},
                           {assertz, {lifecycle_mode, second}})),
            settled(Owner),
            Changed = counts(Trace),
            ?assert(maps:get(selections, Changed) > 0),
            ?assert(maps:get(installs, Changed) > 0),
            ?assertEqual([], maps:get(io, Changed))
        after stop_trace(Trace) end
    end) end}.

scoped_request_keeps_the_full_inventory_dependency_test_() ->
    {timeout, 60, fun() -> with_owner(fun(#{namespace := Ns}, Owner) ->
        Scoped = {agent_hosting_projection, {agent, actor}, {'_'}, {keys, [actor]}, []},
        commit(Ns, both({assertz, {lifecycle_revision, first}},
                       both(replace_selector({lifecycle_revision, {'_'}}), {assertz, Scoped}))),
        settled(Owner),
        ?assertEqual(ok, quod_runtime:reconcile_resource(Ns, quod_prolog:applied(Ns),
            agent_hosts, {agent, actor}, quod_time:mono_ms() + 5000)),
        settled(Owner),
        Trace = start_trace(Owner),
        try
            %% The narrow request never read lifecycle_revision/1. It must
            %% not erase the existing full inventory consumer's dependency.
            commit(Ns, both({retract, {lifecycle_revision, first}},
                           {assertz, {lifecycle_revision, second}})),
            settled(Owner),
            Changed = counts(Trace),
            ?assert(maps:get(selections, Changed) > 0),
            ?assert(lists:member({agent_hosts, all, []}, maps:get(descriptions, Changed)))
        after stop_trace(Trace) end
    end) end}.

committed_height_wakes_context_dependent_selection_test_() ->
    {timeout, 60, fun() -> with_owner(fun(#{namespace := Ns}, Owner) ->
        Target = quod_prolog:applied(Ns) + 2,
        commit(Ns, replace_selector(at_height(Target))),
        Before = settled(Owner),
        ?assert(maps:is_key(agent_hosts, maps:get(resource_failures, Before))),
        Trace = start_trace(Owner),
        try
            Target = advance_without_changes(Ns),
            After = settled(Owner, Target, deadline()),
            ?assertEqual(maps:get(events_seen, Before), maps:get(events_seen, After)),
            ?assertEqual(#{}, maps:get(resource_failures, After)),
            Changed = counts(Trace),
            ?assert(maps:get(selections, Changed) > 0),
            ?assert(maps:get(installs, Changed) > 0),
            ?assertEqual([], maps:get(io, Changed)),
            quod_runtime:reconcile_now(Ns),
            settled(Owner),
            assert_no_work(counts(Trace))
        after stop_trace(Trace) end
    end) end}.

committed_height_does_not_wake_predicate_only_selection_test_() ->
    {timeout, 60, fun() -> with_owner(fun(#{namespace := Ns}, Owner) ->
        commit(Ns, replace_selector(true)),
        Before = settled(Owner),
        Trace = start_trace(Owner),
        try
            Height = advance_without_changes(Ns),
            After = settled(Owner, Height, deadline()),
            ?assertEqual(maps:get(events_seen, Before), maps:get(events_seen, After)),
            assert_no_work(counts(Trace))
        after stop_trace(Trace) end
    end) end}.

queued_height_advance_supersedes_selection_before_installation_test_() ->
    {timeout, 60, fun() -> with_owner(fun(#{namespace := Ns}, Owner) ->
        Target = quod_prolog:applied(Ns) + 2,
        commit(Ns, replace_selector(at_height(Target))),
        settled(Owner),
        Runtime = maps:get(runtime, Owner),
        ok = sys:suspend(Runtime),
        try
            Request = gen_server:send_request(Runtime,
                {reconcile_resource, Target - 1, agent_hosts, all, deadline()}),
            Target = advance_without_changes(Ns),
            %% Both messages are actually delivered before the worker starts:
            %% its handoff must follow processing of the newer snapshot.
            {messages, Messages} = process_info(Runtime, messages),
            ?assert(lists:any(fun({'$gen_call', _, {reconcile_resource, _, agent_hosts, _, _}}) -> true;
                                (_) -> false end, Messages)),
            Engine = quod_reg:where({quod_prolog, Ns}),
            ?assert(lists:any(fun({runtime_snapshot_advanced, P, H, _}) ->
                                     P =:= Engine andalso H =:= Target;
                                (_) -> false end, Messages)),
            ok = sys:resume(Runtime),
            ?assertEqual({reply, {error, selection_superseded}},
                         gen_server:receive_response(Request, 10000)),
            ?assertEqual(#{}, maps:get(resource_failures, settled(Owner, Target, deadline())))
        after sys:resume(Runtime) end
    end) end}.

at_height(Height) ->
    both({current_prolog_flag, '$quod_ctx', {'Context'}},
         both({arg, 3, {'Context'}, {'Height'}}, {'>=', {'Height'}, Height})).

advance_without_changes(Ns) ->
    %% A real committed transaction with a stale read check advances the
    %% snapshot without changing a predicate or emitting a domain occurrence.
    {ok, Pub} = application:get_env(quod, node_pubkey),
    Tx = quod_ct:change(Ns, quod_ct:diff_for(must_not_apply),
                        #{{agent_hosting_projection, 4} => never_present}),
    {ok, Height} = quod_simplex:append(Ns, Tx#transaction{author = Pub}),
    ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, must_not_apply)),
    Height.

absent_selector_is_woken_when_defined_test_() ->
    {timeout, 60, fun() -> with_owner(fun(#{namespace := Ns}, Owner) ->
        commit(Ns, abolish_selector()),
        ?assertEqual(#{}, maps:get(resource_failures, settled(Owner))),
        Trace = start_trace(Owner),
        try
            commit(Ns, {assertz, selector(true)}),
            ?assertEqual(#{}, maps:get(resource_failures, settled(Owner))),
            Changed = counts(Trace),
            ?assert(maps:get(selections, Changed) > 0),
            ?assert(maps:get(installs, Changed) > 0)
        after stop_trace(Trace) end
    end) end}.

failed_selection_preserves_host_and_empty_selection_removes_it_test_() ->
    {timeout, 60, fun() -> with_owner(fun(F = #{namespace := Ns, reference := Ref}, Owner) ->
        Child = host(F, Owner),
        commit(Ns, replace_selector(lifecycle_enabled)),
        Failed = settled(Owner),
        ?assert(maps:is_key(agent_hosts, maps:get(resource_failures, Failed))),
        ?assertEqual(Child, child(Ref, Ns)),
        Monitor = monitor(process, Child),
        commit(Ns, {assertz, lifecycle_enabled}),
        receive {'DOWN', Monitor, process, Child, _} -> ok
        after 10000 -> error(empty_inventory_did_not_remove_host) end,
        ?assertEqual(#{}, maps:get(resource_failures, settled(Owner))),
        ?assertEqual(none, child(Ref, Ns))
    end) end}.

negative_and_reflective_dependencies_wake_the_real_owner_test_() ->
    [{Label, {timeout, 60, fun() -> with_owner(fun(#{namespace := Ns}, Owner) ->
        commit(Ns, replace_selector(Body)),
        Before = maps:get(resource_failures, settled(Owner)),
        ?assertEqual(InitiallyFails, maps:is_key(agent_hosts, Before)),
        Trace = start_trace(Owner),
        try
            commit(Ns, {assertz, Fact}),
            After = maps:get(resource_failures, settled(Owner)),
            ?assertEqual(not InitiallyFails, maps:is_key(agent_hosts, After)),
            ?assert(maps:get(selections, counts(Trace)) > 0)
        after stop_trace(Trace) end
    end) end}} || {Label, Body, Fact, InitiallyFails} <-
      [{"negative read", {'\\+', lifecycle_blocked}, lifecycle_blocked, false},
       {"absent predicate", {current_predicate, {'/', lifecycle_enabled, 0}},
          lifecycle_enabled, true},
       {"predicate property", {predicate_property, lifecycle_enabled, interpreted},
          lifecycle_enabled, true},
       {"predicate enumeration", both({current_predicate, {'/', {'Name'}, {'Arity'}}},
                                      {'=', {'Name'}, lifecycle_enumerated}),
          lifecycle_enumerated, true}]].

selection_errors_retain_the_reads_that_can_repair_them_test_() ->
    {timeout, 60, fun() -> with_owner(fun(#{namespace := Ns}, Owner) ->
        Body = both({lifecycle_mode, {'Mode'}},
                    {';', {'->', {'=', {'Mode'}, broken}, {throw, deadline_exceeded}}, true}),
        commit(Ns, both({assertz, {lifecycle_mode, broken}}, replace_selector(Body))),
        ?assert(maps:is_key(agent_hosts, maps:get(resource_failures, settled(Owner)))),
        Trace = start_trace(Owner),
        try
            %% A captured policy error with the same spelling as a runtime
            %% deadline still has selective, reported dependencies.
            commit(Ns, {assertz, unrelated_during_policy_error}),
            settled(Owner),
            assert_no_work(counts(Trace)),
            commit(Ns, both({retract, {lifecycle_mode, broken}},
                           {assertz, {lifecycle_mode, repaired}})),
            ?assertEqual(#{}, maps:get(resource_failures, settled(Owner))),
            ?assert(maps:get(installs, counts(Trace)) > 0)
        after stop_trace(Trace) end
    end) end}.

unreported_selector_death_keeps_a_repair_dependency_test_() ->
    {timeout, 60, fun() -> with_owner(fun(#{namespace := Ns}, Owner) ->
        Trace = #{tag := Tag} = start_trace(Owner),
        try
            LoopHead = {lifecycle_loop, ready},
            Loop = {':-', LoopHead, LoopHead},
            commit(Ns, both({assertz, Loop}, replace_selector(LoopHead))),
            Worker = receive
                {Tag, {trace, Pid, call,
                       {quod_runtime, select_resource_description,
                        [Ns, _, _, agent_hosts, _]}}} -> Pid
            after 10000 -> error(looping_selector_not_started) end,
            %% The interpreted loop cannot return its observations. Runtime
            %% completion below joins processing of the actual worker DOWN.
            exit(Worker, kill),
            ?assertEqual({error, {resource_worker_down, killed}},
                         maps:get(agent_hosts, maps:get(resource_failures, settled(Owner)))),
            clear_measurement(Trace),
            %% Changing the selector itself would hit its older successful
            %% basis and conceal loss of this newly encountered helper read.
            commit(Ns, both({abolish, {'/', lifecycle_loop, 1}},
                           {assertz, LoopHead})),
            ?assertEqual(#{}, maps:get(resource_failures, settled(Owner))),
            Repaired = counts(Trace),
            ?assert(maps:get(selections, Repaired) > 0),
            ?assert(maps:get(installs, Repaired) > 0),
            ?assertEqual([], maps:get(io, Repaired)),
            commit(Ns, {assertz, unrelated_after_worker_repair}),
            settled(Owner),
            assert_no_work(counts(Trace))
        after stop_trace(Trace) end
    end) end}.

unstarted_expired_selection_keeps_a_repair_dependency_test_() ->
    {timeout, 60, fun() -> with_owner(fun(#{namespace := Ns}, Owner) ->
        {ok, Budget} = application:get_env(quod, runtime_reconcile_budget_ms),
        Trace = start_trace(Owner),
        try
            %% Zero remaining allowance expires the real internal cursor before
            %% worker launch. Restore the fixture budget only after processing.
            try
                ok = application:set_env(quod, runtime_reconcile_budget_ms, 0),
                commit(Ns, replace_selector({lifecycle_enabled, ready})),
                ?assertEqual({error, deadline_exceeded},
                             maps:get(agent_hosts, maps:get(resource_failures, settled(Owner)))),
                assert_no_work(counts(Trace))
            after application:set_env(quod, runtime_reconcile_budget_ms, Budget) end,
            commit(Ns, {assertz, {lifecycle_enabled, ready}}),
            ?assertEqual(#{}, maps:get(resource_failures, settled(Owner))),
            Repaired = counts(Trace),
            ?assert(maps:get(selections, Repaired) > 0),
            ?assert(maps:get(installs, Repaired) > 0),
            ?assertEqual([], maps:get(io, Repaired)),
            commit(Ns, {assertz, unrelated_after_expired_selection}),
            settled(Owner),
            assert_no_work(counts(Trace))
        after stop_trace(Trace) end
    end) end}.

foreign_scope_cannot_supply_node_or_root_resource_policy_test_() ->
    {timeout, 60, fun() -> with_owner(fun(#{namespace := Ns}, Owner) ->
        NodeSelector = {':-', {node_ontology_hosting_projection, {'_'}, {'_'}},
                              {throw, foreign_node_resource_policy}},
        RootSelector = {':-', {effect_custody_capacity, {'_'}},
                              {throw, foreign_root_resource_policy}},
        commit(Ns, both({assertz, NodeSelector}, {assertz, RootSelector})),
        ?assertEqual(#{}, maps:get(resource_failures, settled(Owner))),
        %% The same typed owner interface must preserve governing scope even
        %% when called explicitly. Neither foreign definition may execute.
        [?assertEqual(ok, quod_runtime:reconcile_resource(
             Ns, quod_prolog:applied(Ns), Resource, all, quod_time:mono_ms() + 5000))
         || Resource <- [node_ontologies, effect_custody]],
        ?assertEqual(#{}, maps:get(resource_failures, settled(Owner)))
    end) end}.

change_while_selected_result_waits_cannot_leave_obsolete_inventory_test_() ->
    {timeout, 60, fun() -> with_owner(fun(F = #{namespace := Ns, node := Node,
                                              key := Key, reference := Ref}, Owner) ->
        Child = host(F, Owner),
        Monitor = monitor(process, Child),
        commit(Ns, both({assertz, {lifecycle_inventory, []}},
          both(abolish_selector(), {assertz,
            {':-', {agent_hosting_projection, all, {'_'}, all, {'Rows'}},
                   {lifecycle_inventory, {'Rows'}}}}))),
        receive {'DOWN', Monitor, process, Child, _} -> ok
        after 10000 -> error(initial_empty_inventory_not_installed) end,
        settled(Owner),
        Runtime = maps:get(runtime, Owner),
        Parent = self(), Token = make_ref(),
        %% Suspend the real worker at its synchronous selection handoff. The
        %% owner remains responsive and can accept the newer canonical input.
        %% No bridge or test predicate is added to the restricted policy proof.
        Pause = fun(false, {in, {'$gen_call', {Worker, _},
                                {resource_selected, agent_hosts, _}}}, _) ->
                         true = erlang:suspend_process(Worker),
                         Parent ! {selection_paused, Token, Worker}, true;
                   (State, _, _) -> State end,
        ok = sys:install(Runtime, {Pause, false}),
        Trace = start_trace(Owner),
        {Caller, CallerMonitor} = spawn_monitor(fun() ->
            Result = quod_runtime:reconcile_resource(Ns, quod_prolog:applied(Ns),
                         agent_hosts, all, quod_time:mono_ms() + 10000),
            Parent ! {selection_result, Token, Result}
        end),
        try
            Worker = receive {selection_paused, Token, Pid} -> Pid
                     after 10000 -> error(selection_not_paused) end,
            try
                %% This call joins processing of the selection handoff before the
                %% edit. The worker cannot install anything while suspended.
                _ = quod_runtime:stats(Ns),
                Rows = [{host, actor, Node, 1, Key}],
                commit(Ns, both({retract, {lifecycle_inventory, []}},
                               {assertz, {lifecycle_inventory, Rows}})),
                Height = quod_prolog:applied(Ns),
                received_input(Owner, Height),
                true = resume_worker(Runtime, Worker),
                receive {selection_result, Token, Result} ->
                    ?assert(lists:member(Result, [ok, {error, selection_superseded}]))
                after 10000 -> error(selection_not_completed) end,
                receive {'DOWN', CallerMonitor, process, Caller, normal} -> ok
                after 10000 -> error(selection_caller_not_completed) end,
                installed(Ref),
                settled(Owner),
                ?assert(is_pid(child(Ref, Ns))),
                ?assertEqual({agent_hosts, all, Rows}, lists:last(maps:get(descriptions, counts(Trace))))
            after catch resume_worker(Runtime, Worker) end
        after
            sys:remove(Runtime, Pause),
            stop_trace(Trace)
        end
    end) end}.

resume_worker(Runtime, Worker) ->
    _ = sys:replace_state(Runtime, fun(State) ->
        true = erlang:resume_process(Worker), State
    end),
    true.

%% Subscribe to actual owner processing before taking the first snapshot. Each
%% later check follows a completion or input notice, never a polling timer.
with_owner(Fun) ->
    quod_agent_hosting_tests:with_host(fun(F = #{namespace := Ns}) ->
        Runtime = quod_reg:where({quod_runtime, Ns}),
        Parent = self(), Tag = make_ref(),
        Observe = fun(State, {in, {'$gen_cast', {runner_done, _, _}}}, _) ->
                          Parent ! {owner_step, Tag}, State;
                     (State, {in, {'DOWN', _, process, _, _}}, _) ->
                          Parent ! {owner_step, Tag}, State;
                     (State, {in, {applied_live, Env, _}}, _) ->
                          Parent ! {owner_input, Tag, maps:get(height, Env)}, State;
                     (State, {in, {runtime_snapshot_advanced, _, H, _}}, _) ->
                          Parent ! {owner_input, Tag, H}, State;
                     (State, _, _) -> State end,
        ok = sys:install(Runtime, {Observe, none}),
        Owner = #{namespace => Ns, runtime => Runtime, tag => Tag},
        try settled(Owner), Fun(F, Owner)
        after sys:remove(Runtime, Observe) end
    end).

settled(Owner = #{namespace := Ns}) ->
    settled(Owner, quod_prolog:applied(Ns), deadline()).
settled(Owner = #{namespace := Ns, tag := Tag}, Height, Deadline) ->
    case quod_runtime:stats(Ns) of
        #{mode := live, height := H, runner_active := false, queue_len := 0} = Stats
          when H >= Height -> Stats;
        _ -> receive
                 {owner_step, Tag} -> settled(Owner, Height, Deadline);
                 {owner_input, Tag, _} -> settled(Owner, Height, Deadline)
             after remaining(Deadline) -> error({resource_owner_not_settled, Ns, Height}) end
    end.

received_input(#{namespace := Ns, tag := Tag}, Height) ->
    receive
        {owner_input, Tag, H} when H >= Height ->
            %% The synchronous call joins the observed receive with completion
            %% of its handler; the blocked selection leaves this input queued.
            ?assert(maps:get(queue_len, quod_runtime:stats(Ns)) > 0);
        {owner_input, Tag, _} -> received_input(#{namespace => Ns, tag => Tag}, Height)
    after 10000 -> error(newer_committed_input_not_received) end.

host(#{namespace := Ns, node := Node, key := Key, reference := Ref}, Owner) ->
    commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
    Pid = installed(Ref), settled(Owner), Pid.
installed(Ref) ->
    receive {agent_installed, _, Pid, #{reference := Ref, epoch := 1}, _} -> Pid
    after 10000 -> error(resource_host_not_installed) end.
child(Ref, Ns) ->
    {_, Agents} = quod_agent_hosting_tests:domain_agents(Ns),
    case [Pid || #{pid := Pid, binding := #{reference := R}} <- Agents, R =:= Ref] of
        [Pid] -> Pid;
        [] -> none
    end.

selector(Body) -> {':-', {agent_hosting_projection, all, {'_'}, all, []}, Body}.
abolish_selector() -> {abolish, {'/', agent_hosting_projection, 4}}.
replace_selector(Body) -> both(abolish_selector(), {assertz, selector(Body)}).
both(A, B) -> {',', A, B}.
commit(Ns, Goal) -> ?assertMatch({ok, _, _}, quod_ct:rp(Ns, Goal)).
deadline() -> erlang:monotonic_time(millisecond) + 10000.
remaining(Deadline) -> max(0, Deadline - erlang:monotonic_time(millisecond)).

%% Trace only the resource owner and workers it creates, not the proof/ledger
%% owners which must persist the real edits performed by these tests.
start_trace(#{namespace := Ns, runtime := Runtime}) ->
    Trace = #{session := Session, io := IO} = new_trace(),
    trace:function(Session, {quod_runtime, select_resource_description, 5},
                   [{[Ns, '_', '_', agent_hosts, '_'], [], []}], [local]),
    trace:function(Session, {quod_runtime, install_resource, 3},
                   [{[Ns, '_', {agent_hosts, '_', '_'}], [], []}], [local]),
    [trace:function(Session, MFA, true, [local]) || MFA <- IO],
    trace:process(Session, Runtime, true, [call, set_on_spawn]),
    clear_measurement(Trace),
    Trace.
counts(Trace = #{tag := Tag, io := IO}) ->
    trace_barrier(Trace),
    trace_counts(Tag, IO, #{selections => 0, installs => 0, descriptions => [], io => []}).
trace_counts(Tag, IO, Acc) ->
    receive
        {Tag, {trace, _, call, {quod_runtime, select_resource_description, _}}} ->
            trace_counts(Tag, IO, Acc#{selections := maps:get(selections, Acc) + 1});
        {Tag, {trace, _, call, {quod_runtime, install_resource, [_, _, Description]}}} ->
            trace_counts(Tag, IO, Acc#{installs := maps:get(installs, Acc) + 1,
                                     descriptions := maps:get(descriptions, Acc) ++ [Description]});
        {Tag, {trace, _, call, {M, F, Args}}} ->
            trace_counts(Tag, IO, record_io(M, F, Args, IO, Acc))
    after 0 -> Acc end.

%% A private session and tracer give every message this measurement's tag.
%% Old EUnit mailbox traces and other sessions cannot enter its counters.
new_trace() ->
    Parent = self(), Tag = make_ref(),
    Tracer = spawn_link(fun() -> trace_relay(Parent, Tag) end),
    Session = trace:session_create(?MODULE, Tracer, []),
    #{session => Session, tracer => Tracer, tag => Tag, io => io_mfas()}.
trace_relay(Parent, Tag) ->
    receive
        {barrier, Ref} -> Parent ! {Tag, barrier, Ref}, trace_relay(Parent, Tag);
        stop -> ok;
        Message -> Parent ! {Tag, Message}, trace_relay(Parent, Tag)
    end.
trace_barrier(#{session := Session, tracer := Tracer, tag := Tag}) ->
    Ref = trace:delivered(Session, all),
    receive {trace_delivered, all, Ref} -> ok
    after 10000 -> error(resource_trace_not_delivered) end,
    %% Delivery puts all earlier traces in the relay's mailbox. Its reply is
    %% therefore ordered after forwarding them to this test process.
    Tracer ! {barrier, Ref},
    receive {Tag, barrier, Ref} -> ok
    after 10000 -> error(resource_trace_relay_not_drained) end.
clear_measurement(Trace = #{tag := Tag}) ->
    trace_barrier(Trace),
    discard_trace(Tag).
discard_trace(Tag) ->
    receive {Tag, _} -> discard_trace(Tag) after 0 -> ok end.
stop_trace(Trace = #{session := Session, tracer := Tracer, tag := Tag}) ->
    trace_barrier(Trace),
    true = trace:session_destroy(Session),
    Monitor = monitor(process, Tracer),
    Tracer ! stop,
    receive {'DOWN', Monitor, process, Tracer, normal} -> ok
    after 10000 -> error(resource_tracer_not_stopped) end,
    discard_trace(Tag).
io_mfas() ->
    [{quod_simplex, history_view, 3}, {quod_ledger_store, open_ro_snapshot, 1},
     {quod_ledger_store, read_at, 2}, {file, write, 2}, {file, pwrite, 3},
     {file, write_file, 2}, {file, write_file, 3}, {file, sync, 1}, {file, datasync, 1}].
record_io(M, F, Args, IO, Acc) ->
    MFA = {M, F, length(Args)},
    case lists:member(MFA, IO) of
        true -> Acc#{io := [MFA | maps:get(io, Acc)]};
        false -> error({unexpected_measurement_trace, MFA})
    end.
assert_no_work(Counts) ->
    ?assertEqual(#{selections => 0, installs => 0, descriptions => [], io => []}, Counts).

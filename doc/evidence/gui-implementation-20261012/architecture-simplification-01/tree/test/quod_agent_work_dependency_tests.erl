-module(quod_agent_work_dependency_tests).
-include_lib("eunit/include/eunit.hrl").

finite_pass_retains_earlier_reads_and_retires_them_on_new_pass_test_() ->
    {timeout, 60, fun() ->
        quod_agent_hosting_tests:with_host(fun(F = #{namespace := Ns, reference := Ref,
                                                   node := Node, key := Key}) ->
            Runtime = quod_reg:where({quod_runtime, Ns}),
            Parent = self(), Tag = make_ref(),
            Observe = fun(State, {in, {'$gen_cast', {runner_done, _, _}}}, _) ->
                              Parent ! {work_owner_step, Tag}, State;
                         (State, {in, {applied_live, _, _}}, _) ->
                              Parent ! {work_owner_step, Tag}, State;
                         (State, {in, {runtime_snapshot_advanced, _, _, _}}, _) ->
                              Parent ! {work_owner_step, Tag}, State;
                         (State, {in, {agent_completed, _, _, _}}, _) ->
                              Parent ! {work_owner_step, Tag}, State;
                         (State, {in, {agent_work_custody, _, _, _}}, _) ->
                              Parent ! {work_owner_step, Tag}, State;
                         (State, _, _) -> State end,
            ok = sys:install(Runtime, {Observe, none}),
            Trace = trace:session_create(?MODULE, self(), []),
            trace:function(Trace, {quod_runtime, select_resource_description, 5},
                           [{[Ns, '_', '_', agent_work, '_'], [], []}], [local]),
            trace:process(Trace, Runtime, true, [call, set_on_spawn]),
            try
                commit(Ns, assertions(work_policy(F))),
                commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
                settled(Ns, Tag),
                completed(Ref),
                ?assert(selections(Trace, Ns) >= 2),

                commit(Ns, {assertz, unrelated_work_dependency}),
                settled(Ns, Tag),
                ?assertEqual(0, selections(Trace, Ns)),

                %% The terminal after(Key) lookup never reads this helper.
                %% Its earlier read still belongs to the idle pass's basis.
                commit(Ns, replace(work_early_dependency, first, second)),
                settled(Ns, Tag),
                ?assert(selections(Trace, Ns) >= 2),
                completed(Ref),

                %% A genuinely new pass changes its branch. Once it finishes,
                %% the old branch's helper must no longer invalidate the work.
                commit(Ns, replace(work_dependency_mode, early, current)),
                settled(Ns, Tag),
                ?assert(selections(Trace, Ns) >= 2),
                completed(Ref),
                commit(Ns, replace(work_early_dependency, second, obsolete)),
                settled(Ns, Tag),
                ?assertEqual(0, selections(Trace, Ns)),
                commit(Ns, replace(work_current_dependency, first, second)),
                settled(Ns, Tag),
                ?assert(selections(Trace, Ns) >= 2),
                completed(Ref)
            after
                true = trace:session_destroy(Trace),
                sys:remove(Runtime, Observe)
            end
        end)
    end}.

work_policy(#{namespace := Ns, reference := Ref}) ->
    [{can_invoke, true, Ref, {'_'}, Ns},
     {work_dependency_mode, early},
     {work_early_dependency, first}, {work_current_dependency, first},
     {':-', {agent_work_goal, actor, start, <<"one">>, true, 5000},
       {',', {work_dependency_mode, {'Mode'}},
         {';', {'->', {'=', {'Mode'}, early}, {work_early_dependency, {'_'}}},
               {work_current_dependency, {'_'}}}}}].

%% The selected signed true goal writes no watched state. Each completion only
%% advances this pass; none can manufacture another dependency-driven pass.
completed(Ref) ->
    receive
        {agent_request_finished, _, _, #{reference := Ref}, _,
         {ok, _, {normalized, {answers, _, _}}}} -> ok
    after 10000 -> error(work_request_not_completed) end.

settled(Ns, Tag) ->
    settled(Ns, Tag, quod_prolog:applied(Ns), quod_time:mono_ms() + 10000).
settled(Ns, Tag, Height, Deadline) ->
    case quod_runtime:stats(Ns) of
        #{mode := live, height := H, runner_active := false, queue_len := 0,
          agent_work_idle := 1, agent_pending_bytes := 0} when H >= Height -> ok;
        _ ->
            receive {work_owner_step, Tag} -> settled(Ns, Tag, Height, Deadline)
            after max(0, Deadline - quod_time:mono_ms()) -> error(work_owner_not_idle) end
    end.

selections(Trace, Ns) ->
    Ref = trace:delivered(Trace, all),
    receive {trace_delivered, all, Ref} -> count_selections(Ns, 0)
    after 10000 -> error(work_trace_not_delivered) end.
count_selections(Ns, Count) ->
    receive
        {trace, _, call, {quod_runtime, select_resource_description,
                         [Ns, _, _, agent_work, _]}} -> count_selections(Ns, Count + 1)
    after 0 -> Count end.

replace(Predicate, Before, After) ->
    {',', {retract, {Predicate, Before}}, {assertz, {Predicate, After}}}.
assertions(Facts) ->
    lists:foldr(fun(Fact, Rest) -> {',', {assertz, Fact}, Rest} end, true, Facts).
commit(Ns, Goal) -> ?assertMatch({ok, _, _}, quod_ct:rp(Ns, Goal)).

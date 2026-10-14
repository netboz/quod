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
                         (State, {in, {runtime_snapshot_advanced, _, _, _, _}}, _) ->
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
     {':-', {agent_work_goal, actor, start, <<"one">>, {execute,true}, 5000},
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

observation_uses_read_queue_and_exact_request_progress_test_() ->
    {timeout,60,fun() ->
        quod_agent_hosting_tests:with_host(fun(#{namespace := Ns,reference := Actor,
                node := Node,key := Key}) ->
            {agent_instance_ref,Ns,Anchor,Instance} = Actor,
            {ok,InstanceText} = quod_client_goal_parser:format(Instance),
            {ok,GoalText} = quod_client_goal_parser:format({assertz,observed_application}),
            Request = #{network_identity => <<42:256>>,agent_namespace => Ns,
                agent_genesis_anchor => Anchor,agent_instance_text => InstanceText,
                signing_public_key => Key,operation_id => crypto:strong_rand_bytes(32),
                not_after_ms => quod_time:now_ms()+60000,mode => execute,
                parser_version => 3,goal_text => GoalText},
            {ok,Bytes} = quod_client_goal:encode(Request),
            commit(Ns,assertions([
                {agent_work_goal,actor,start,<<"observe">>,{observe,Bytes},5000},
                {can_invoke,{committed_operation_outcome,Bytes,{'_'}},Actor,{'_'},Ns},
                {can_invoke,{assertz,observed_application},Actor,{'_'},Ns}])),
            Runtime = quod_reg:where({quod_runtime,Ns}),
            Parent = self(), Tag = make_ref(),
            Hook = fun(State,{in,_},_) -> Parent ! {work_owner_step,Tag},State;
                      (State,_,_) -> State end,
            ok = sys:install(Runtime,{Hook,none}),
            Trace = trace:session_create(gui_work_observation,self(),[]),
            trace:function(Trace,{quod_runtime,select_resource_description,5},
                [{[Ns,'_','_',agent_work,'_'],[],[]}],[local]),
            trace:process(Trace,Runtime,true,[call,set_on_spawn]),
            try
                commit(Ns,{goal,{agent_hosted,actor,Node,1,Key}}),
                {ok,_,{normalized,{read,_,{error,_}}}} = observation_result(Actor,Bytes),
                settled(Ns,Tag),
                ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,observed_application)),
                ?assert(selections(Trace,Ns) >= 2),
                commit(Ns,{assertz,unrelated_observation_update}),
                settled(Ns,Tag),
                ?assertEqual(0,selections(Trace,Ns)),
                %% Only this explicit test submission executes the stored goal.
                {ok,Bytes,Signature} = quod_agent_vault:sign(Request,quod_time:mono_ms()+5000),
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                    quod_client_goal_ingress:submit(Bytes,Signature)),
                {ok,_,{normalized,{read,_,{answers,_,[Answer]}}}} = observation_result(Actor,Bytes),
                {ok,[{<<"V0">>,committed}]} = quod_client_result:decode_binding(Answer),
                settled(Ns,Tag),
                ?assert(selections(Trace,Ns) >= 2),
                quod_lobby_tests:assert_read_has_no_io(fun() ->
                    lists:foreach(fun(_) ->
                        ok = quod_runtime:reconcile_resource(Ns,quod_prolog:applied(Ns),
                            agent_work,{actor,continue},quod_time:mono_ms()+5000)
                    end,lists:seq(1,20))
                end),
                ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,observed_application))
            after
                trace:session_destroy(Trace),sys:remove(Runtime,Hook)
            end
        end)
    end}.

observation_result(Actor,Original) ->
    receive {agent_request_finished,_,_,#{reference := Actor},_,Result} ->
        {ok,#{request_bytes := ReadBytes},_} = Result,
        ?assertNotEqual(Original,ReadBytes),
        {ok,#{mode := read,goal_text := Text}} = quod_client_goal:decode(ReadBytes),
        {ok,#{goal := {{'$quod_symbol',<<"committed_operation_outcome">>},Original,_}}} = quod_client_goal_parser:parse(Text,3),
        Result
    after 10000 -> error(observation_missing) end.

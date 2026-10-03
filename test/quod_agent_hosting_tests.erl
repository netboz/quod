-module(quod_agent_hosting_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlog/src/erlog_int.hrl").
-export([quod_predicate_module/0, load/1, test_host_barrier/3, test_fill_agents/3,
         test_fill_work_queue/3, test_local_wait/3,
         with_host/1, with_host/2, domain_agents/1]).

quod_predicate_module() -> true.
load(Est) ->
    Local = quod_predicates:register(Est, {test_local_wait, 0}, query, proof_bound,
                                    ?MODULE, test_local_wait),
    Reaction = quod_predicates:register(Local, {test_reaction_barrier, 0}, reaction,
                              ?MODULE, test_host_barrier),
    Completion = quod_predicates:register(Reaction, {test_fipa_completion, 0}, query, proof_bound,
                              ?MODULE, test_host_barrier),
    WorkQueue = quod_predicates:register(Completion, {test_fill_work_queue, 0}, reaction,
                              ?MODULE, test_fill_work_queue),
    quod_predicates:register(WorkQueue, {test_fill_agents, 0}, reaction,
                              ?MODULE, test_fill_agents).

test_local_wait(test_local_wait, Next, St) ->
    quod_reg:where({host_test, local_proof}) ! {local_proof_waiting, self()},
    receive release -> erlog_int:prove_body(Next, St) end.
test_host_barrier(test_fipa_completion, Next, St) ->
    #{operation_ref := Operation} = quod_proof_context:request_evidence(),
    quod_reg:where({host_test, barrier}) ! {fipa_completion_prepared, self(), Operation},
    receive release -> erlog_int:prove_body(Next, St) end;
test_host_barrier(_, Next, St) ->
    quod_reg:where({host_test, barrier}) ! {host_projection_waiting, self()},
    receive release -> erlog_int:prove_body(Next, St) end.


test_fill_agents(test_fill_agents, _Next, St) ->
    Context = quod_predicates:context(St),
    Ns = quod_predicates:ctx_ns(Context),
    Height = quod_predicates:ctx_height(Context),
    Executor = current_test_executor(Context),
    Goal = {record_ping, binary:copy(<<"x">>, 64000)},
    Results = [quod_runtime:agent_request(Ns, Height, E, execute, Goal, 5000)
               || E <- lists:duplicate(9, Executor) ++
                       lists:duplicate(9, {agent, other, 1, <<91:256>>})],
    quod_reg:where({host_test, barrier}) ! {agent_queue_filled, self(), Results},
    receive release -> erlog_int:fail(St) end.

current_test_executor(Context) ->
    {actor, {agent_instance_ref, _, _, Instance}, _} = quod_predicates:ctx_executor(Context),
    {_, Agents} = quod_runtime:agents(quod_predicates:ctx_ns(Context)),
    [#{binding := #{epoch := Epoch, public_key := Key}}] =
        [A || A = #{binding := #{reference := {agent_instance_ref, _, _, I}}} <- Agents,
              I =:= Instance],
    {agent, Instance, Epoch, Key}.

test_fill_work_queue(test_fill_work_queue, Next, St) ->
    Ctx = quod_predicates:context(St),
    Goal = {',', test_fipa_completion, {record_ping, queued}},
    Results = [quod_runtime:agent_request(quod_predicates:ctx_ns(Ctx),
                   quod_predicates:ctx_height(Ctx), current_test_executor(Ctx),
                   execute, Goal, 5000) || _ <- lists:seq(1, 16)],
    quod_reg:where({host_test, barrier}) ! {work_queue_admitted, Results},
    erlog_int:prove_body(Next, St).

projected_work_drains_more_than_queue_capacity_and_skips_refusal_test_() ->
    {timeout, 60, fun() -> with_projected_work(fun(#{namespace := Ns, reference := Ref,
                                                   node := Node, key := Key}) ->
        Keys = [<<N:256>> || N <- lists:seq(0, 23)],
        commit(Ns, work_assertions([{work_rejected, <<0:256>>} |
                                    [{work_pending, K} || K <- Keys]])),
        commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
        _ = installed(Ref, 1),
        work_status(Ns, agent_work_idle, 1),
        ?assertMatch({ok, [#{'Rows' := [<<0:256>>]}], _}, quod_prolog:prove_ro(Ns,
                     {findall, {'K'}, {work_pending, {'K'}}, {'Rows'}})),
        {ok, [#{'Rows' := Done}], _} = quod_prolog:prove_ro(Ns,
                     {findall, {'K'}, {work_done, {'K'}}, {'Rows'}}),
        ?assertEqual(tl(Keys), lists:sort(Done)),
        ?assertMatch(#{reconcile_failures := 0, agent_work_idle := 1}, quod_runtime:stats(Ns))
    end) end}.

projected_work_wakes_after_real_queue_capacity_release_test_() ->
    {timeout, 60, fun() -> with_projected_work(fun(#{namespace := Ns, reference := Ref,
                                                   node := Node, key := Key}) ->
        commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
        _ = installed(Ref, 1),
        work_status(Ns, agent_work_idle, 1),
        commit(Ns, {trigger_event, fill_work_queue}),
        receive {work_queue_admitted, Results} ->
            ?assertEqual(lists:duplicate(16, ok), Results)
        after 5000 -> error(work_queue_not_filled) end,
        First = receive {fipa_completion_prepared, Pid, _} -> Pid
                after 5000 -> error(work_queue_not_started) end,
        commit(Ns, {assertz, {work_pending, <<1:256>>}}),
        work_status(Ns, agent_work_blocked, 1),
        First ! release,
        lists:foreach(fun(_) ->
            receive {fipa_completion_prepared, NextProof, _} -> NextProof ! release
            after 5000 -> error(work_queue_not_released) end
        end, lists:seq(1, 15)),
        work_status(Ns, agent_work_idle, 1),
        ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(Ns, {work_done, <<1:256>>})),
        ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, {work_pending, <<1:256>>})),
        ?assertMatch(#{agent_work_blocked := 0, agent_work_idle := 1}, quod_runtime:stats(Ns))
    end) end}.

with_projected_work(Fun) ->
    {ok, _} = application:ensure_all_started(gproc),
    true = quod_reg:reg({host_test, barrier}),
    Ns = <<"host-test-agent">>,
    Principal = {agent_instance_ref, Ns, {'_'}, actor},
    Rules = quod_prolog:read_terms("test/fixtures/agent_work.pl") ++
        [{can_invoke, {finish_work, {'_'}}, Principal, {'_'}, Ns},
         {can_invoke, {',', test_fipa_completion, {record_ping, queued}}, Principal, {'_'}, Ns},
         owned_reaction(actor, fill_work_queue, true, test_fill_work_queue)],
    try with_host(fun(Ctx = #{namespace := Namespace}) ->
        Runtime = quod_reg:where({quod_runtime, Namespace}),
        Trace = trace:session_create(agent_work_status, self(), []),
        trace:function(Trace, {quod_runtime, project_work_step, 5},
                       [{'_', [], [{return_trace}]}], [local]),
        trace:process(Trace, Runtime, true, [call]),
        try Fun(Ctx)
        after trace:session_destroy(Trace) end
    end, Rules)
    after gproc:unreg(quod_reg:name({host_test, barrier})) end.

work_assertions(Facts) ->
    lists:foldr(fun(Fact, Rest) -> {',', {assertz, Fact}, Rest} end, true, Facts).

work_status(Ns, Key, Value) ->
    work_status(Ns, Key, Value, quod_time:mono_ms() + 10000).

work_status(Ns, Key, Value, Deadline) ->
    case quod_runtime:stats(Ns) of
        #{Key := Value} -> ok;
        _ ->
            Remaining = max(0, Deadline - quod_time:mono_ms()),
            receive
                {trace, _, return_from, {quod_runtime, project_work_step, 5}, _} ->
                    work_status(Ns, Key, Value, Deadline)
            after Remaining -> error({agent_work_status_missing, Key, Value}) end
    end.


logical_node_observations_wait_for_own_queue_without_blocking_input_test_() ->
    {timeout, 60, fun() ->
        {ok, _} = application:ensure_all_started(gproc),
        true = quod_reg:reg({host_test, local_proof}),
        try with_host(fun(#{node := Node = {agent_instance_ref, Ns, _, _}}) ->
            true = quod_reg:subscribe({agent, Node}),
            Rules = [{':-', {react_on, {observed, {ontology_changed, {'Heads'}}}, {record_ready, N}},
                       {',', {me, Node}, {member, node_readiness_tick, {'Heads'}}}}
                     || N <- lists:seq(1, 20)] ++
                    [{':-', {record_ready, {'N'}},
                      {',', test_local_wait, {assertz, {ready_done, {'N'}}}}}],
            commit(Ns, work_assertions(Rules)),
            Runtime = quod_reg:where({quod_runtime, Ns}),
            Parent = self(), Token = make_ref(),
            Observe = fun(State, {in, {'$gen_cast', {runner_done, _,
                                   {ok, Height, _, _, _, _, _}}}}, _) ->
                              Parent ! {canonical_processed, Token, Height}, State;
                         (State, _, _) -> State end,
            ok = sys:install(Runtime, {Observe, none}),
            try
                commit(Ns, {assertz, node_readiness_tick}),
                First = receive {local_proof_waiting, Pid} -> Pid
                        after 5000 -> error(readiness_goal_not_started) end,
                commit(Ns, {assertz, canonical_keeps_progressing}),
                Height = quod_prolog:applied(Ns),
                await_processed_height(Token, Height),
                First ! release,
                lists:foreach(fun(_) ->
                    receive {local_proof_waiting, Proof} -> Proof ! release
                    after 5000 -> error(ready_goal_lost_at_capacity) end
                end, lists:seq(2, 20)),
                ?assertEqual(lists:seq(1, 20), lists:sort(await_local_ready(Ns, Node, 20))),
                ?assertMatch({ok, [#{'Count' := 20}], _}, quod_prolog:prove_ro(Ns,
                    {',', {findall, {'N'}, {ready_done, {'N'}}, {'Done'}},
                          {length, {'Done'}, {'Count'}}})),
                ?assertMatch(#{reaction_failures := 0}, quod_runtime:stats(Ns))
            after sys:remove(Runtime, Observe), quod_reg:unsubscribe({agent, Node}) end
        end)
        after gproc:unreg(quod_reg:name({host_test, local_proof})) end
    end}.

await_processed_height(Token, Height) ->
    receive {canonical_processed, Token, Seen} when Seen >= Height -> ok;
            {canonical_processed, Token, _} -> await_processed_height(Token, Height)
    after 5000 -> error(canonical_input_blocked_by_actor_queue) end.

await_local_ready(Ns, Node, Expected) ->
    receive
        {agent_request_finished, _, _, #{reference := Node}, _, {ok, _, _}} ->
            {ok, [#{'Done' := Done}], _} = quod_prolog:prove_ro(Ns,
                {findall, {'N'}, {ready_done, {'N'}}, {'Done'}}),
            case length(Done) of
                Expected -> Done;
                _ -> await_local_ready(Ns, Node, Expected)
            end
    after 10000 -> error(readiness_commits_missing) end.

hosted_reactions_and_incarnation_recovery_test_() ->
    {timeout, 60, fun() -> with_host(fun exercise/1) end}.

hosted_agents_exchange_committed_events_test_() ->
    {timeout, 60, fun() -> with_host(fun exchange/1) end}.

runtime_owner_death_reaps_blocked_workers_test_() ->
    [{atom_to_list(Kind) ++ "/" ++ atom_to_list(Reason), {timeout, 30, fun() ->
        with_host(fun(#{namespace := Ns, reference := Ref, node := Node, key := Key}) ->
            commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
            {Runtime, _} = installed(Ref, 1),
            true = quod_reg:reg({host_test, barrier}),
            Pause = case Kind of resource -> pause_resource(Runtime, agent_hosts); reaction -> none end,
            try
                Runner = case Kind of
                    reaction ->
                        commit(Ns, {trigger_event, pause_batch}),
                        receive {host_projection_waiting, Pid} -> Pid
                        after 5000 -> error(reaction_worker_not_started) end;
                    resource ->
                        request_resource(Ns, agent_hosts),
                        paused_resource(Pause)
                end,
                Monitor = monitor(process, Runner),
                try
                    case Reason of
                        shutdown ->
                            ok = supervisor:terminate_child(quod_reg:where({quod_ns, Ns}), quod_runtime);
                        kill -> exit(Runtime, kill)
                    end,
                    receive {'DOWN', Monitor, process, Runner, _} -> ok
                    after 1000 -> error({orphaned_worker, Kind, Reason}) end
                after exit(Runner, kill), demonitor(Monitor, [flush]) end
            after remove_resource_pause(Runtime, Pause),
                  gproc:unreg(quod_reg:name({host_test, barrier})) end
        end)
    end}} || Kind <- [reaction, resource], Reason <- [shutdown, kill]].

%% Pause the real resource worker after its pure selection, at the existing
%% owner call before installation. Selector code needs no testing I/O bridge,
%% and the runtime remains free to handle commits and incarnation changes.
pause_resource(Runtime, Resource) ->
    Parent = self(), Token = make_ref(),
    Observe = fun(armed, {in, {'$gen_call', {Worker, _},
                             {resource_selected, Resource0, _}}}, _) when Resource0 =:= Resource ->
                      true = erlang:suspend_process(Worker),
                      Parent ! {resource_paused, Token, Worker}, done;
                 (State, _, _) -> State end,
    ok = sys:install(Runtime, {Observe, armed}),
    {Observe, Token}.

paused_resource({_Observe, Token}) ->
    receive {resource_paused, Token, Worker} -> Worker
    after 5000 -> error(resource_worker_not_selected) end.

resume_resource(Runtime, Worker) ->
    _ = sys:replace_state(Runtime, fun(State) ->
        true = erlang:resume_process(Worker), State
    end),
    true.

remove_resource_pause(_Runtime, none) -> ok;
remove_resource_pause(Runtime, {Observe, _}) ->
    case is_process_alive(Runtime) of true -> sys:remove(Runtime, Observe); false -> ok end.

request_resource(Ns, Resource) ->
    Height = quod_prolog:applied(Ns),
    spawn(fun() -> catch quod_runtime:reconcile_resource(
                         Ns, Height, Resource, all, quod_time:mono_ms() + 10000) end).

fipa_action_and_reply_commit_together_test_() ->
    {timeout, 60, fun() -> with_fipa_request(complete) end}.

fipa_rejected_reply_rolls_back_domain_action_test_() ->
    {timeout, 60, fun() -> with_fipa_request(reject_reply) end}.

fipa_unstarted_request_survives_restart_without_event_replay_test_() ->
    {timeout, 60, fun() -> with_fipa_request(restart_pending) end}.

fipa_request_continues_after_restart_during_proof_test_() ->
    {timeout, 60, fun() -> with_fipa_request(restart_proof) end}.

fipa_request_continues_after_key_rotation_during_proof_test_() ->
    {timeout, 60, fun() -> with_fipa_request(rotate_proof) end}.

fipa_request_continues_after_runtime_loss_with_durable_custody_test_() ->
    {timeout, 60, fun() -> with_fipa_request(restart_admitted) end}.

fipa_competing_completions_commit_once_test_() ->
    {timeout, 60, fun() -> with_fipa_request(competing_completion) end}.

with_fipa_request(Scenario) ->
    {ok, _} = application:ensure_all_started(gproc),
    true = quod_reg:reg({host_test, barrier}),
    try with_host(fun(Ctx = #{directory := Dir}) ->
        {ok, Foreign} = quod_foreign_log:start_link(
                          #{cache_dir => filename:join(Dir, "foreign")}),
        try fipa_request_exchange(Ctx, Scenario)
        after gen_server:stop(Foreign) end
    end, fipa_initiator_rules())
    after gproc:unreg(quod_reg:name({host_test, barrier})) end.

fipa_initiator_rules() ->
    Ns = <<"host-test-agent">>,
    Id = {'Id'}, Peer = {'Peer'}, Action = {'Action'}, Anchor = {'Anchor'},
    quod_prolog:read_terms(filename:join(code:priv_dir(quod), "ontologies/fipa_request.pl")) ++
      [allow_fipa_reply,
       {can_invoke, {fipa_request, actor, Id, Peer, Action},
        {agent_instance_ref, Ns, {'_'}, actor}, {'_'}, Ns},
       {':-', {can_invoke,
               {',', {current_ontology_identity, Ns, Anchor},
                      {fipa_receive_done, actor, Id, Action}}, Peer, {'_'}, Ns},
        {',', allow_fipa_reply,
         {fipa_conversation, actor, Id, initiator, Peer, Action, waiting}}},
       owned_reaction(actor, {start_fipa, Id, Peer, Action},
                      {fipa_request, actor, Id, Peer, Action})].

fipa_request_exchange(#{namespace := SenderNs, reference := SenderRef,
                       node := Node, key := SenderKey, directory := Dir,
                       identity := Identity}, Scenario) ->
    commit(SenderNs, {goal, {agent_hosted, actor, Node, 1, SenderKey}}),
    _ = installed(SenderRef, 1),
    ReceiverNs = <<"host-test-fipa-receiver">>,
    Terms = lists:append([quod_prolog:read_terms(filename:join(code:priv_dir(quod),
                                       "ontologies/" ++ File))
                         || File <- ["agent_instance.pl", "fipa_request.pl"]]),
    Rules = fipa_participant_rules(ReceiverNs, Node, SenderRef, maps:get(pubkey, Identity), Scenario),
    true = quod_reg:subscribe({agent_hosting, ReceiverNs}),
    Receiver = start_ontology(ReceiverNs, Dir, Identity, [], Terms ++ Rules),
    ReceiverRef = {agent_instance_ref, ReceiverNs, quod_simplex:genesis_hash(ReceiverNs), receiver},
    {ok, Blob} = quod_wire_term:encode_canonical(ReceiverRef),
    {ok, Key} = quod_agent_vault:generate(Blob),
    true = quod_reg:subscribe({agent, ReceiverRef}),
    Id = crypto:strong_rand_bytes(32), Action = {reserve, object},
    Waiting = {fipa_conversation, actor, Id, initiator, ReceiverRef, Action, waiting},
    Pending = {fipa_conversation, receiver, Id, participant, SenderRef, Action, pending},
    try
        commit(ReceiverNs, {goal, {agent_hosted, receiver, Node, 1, Key}}),
        _ = installed(ReceiverRef, 1),
        case Scenario of
            complete ->
                WrongAnchor = setelement(3, ReceiverRef, <<99:256>>),
                lists:foreach(fun({Peer, Requested}) ->
                    commit(SenderNs, {trigger_event, {start_fipa, Id, Peer, Requested}}),
                    ?assertMatch({normalized, {failed, _}}, fipa_request_result(SenderRef)),
                    ?assertMatch({fail, _}, quod_prolog:prove_ro(SenderNs,
                         {fipa_conversation, actor, Id, {'_'}, {'_'}, {'_'}, {'_'}})),
                    ?assertMatch({fail, _}, quod_prolog:prove_ro(ReceiverNs, injected))
                end, [{WrongAnchor, Action}, {ReceiverRef, {assertz, injected}}]);
            _ -> ok
        end,
        commit(SenderNs, {trigger_event, {start_fipa, Id, ReceiverRef, Action}}),
        Reaction = receive {host_projection_waiting, Runner} -> Runner
                   after 10000 -> error(fipa_request_reaction_missing) end,
        ?assertMatch({normalized, {committed, _, _}}, fipa_request_result(SenderRef)),
        ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(SenderNs, Waiting)),
        ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(ReceiverNs, Pending)),
        case Scenario of
            competing_completion ->
                %% Both separately signed proofs stage the whole transition
                %% before either can commit. This tests domain concurrency,
                %% not permission to retry an uncertain signed operation.
                fipa_competing_completions(ReceiverRef, Key, Id),
                fipa_assert_done(SenderNs, ReceiverNs, Waiting, Pending);
            restart_pending ->
                %% Projection queued the guarded step, but the ordered reaction
                %% barrier has not released it. Startup continues from state,
                %% without replaying this event or sending a manual wake.
                stop_ontology(Receiver),
                ?assertEqual({error, not_ready}, quod_simplex:history_view_at(
                    {ReceiverNs, element(3, ReceiverRef)}, 1, quod_time:mono_ms() + 1000)),
                Resumed = start_ontology(ReceiverNs, Dir, Identity, [], [],
                            #{mode => join, genesis_hash => element(3, ReceiverRef)}),
                try
                    _ = installed(ReceiverRef, 1),
                    ?assertMatch({normalized, {committed, _, _}},
                                 fipa_request_result(ReceiverRef)),
                    ?assertMatch(#{reconcile_failures := 0, reaction_failures := 0}, quod_runtime:stats(ReceiverNs)),
                    fipa_assert_done(SenderNs, ReceiverNs, Waiting, Pending)
                after stop_ontology(Resumed) end;
            restart_admitted ->
                Engine = quod_reg:where({quod_prolog, ReceiverNs}),
                Parent = self(), Token = make_ref(),
                Hold = fun(_State, {in, {'$gen_call', _, {activate_dtx_vote, _, Group}}}, _) ->
                               Parent ! {fipa_custody_held, Token, Group},
                               receive {release_fipa_custody, Token} -> done end;
                          (State, _, _) -> State
                       end,
                ok = sys:install(Engine, {Token, Hold, none}),
                try
                    Reaction ! release,
                    GroupRef = receive {fipa_custody_held, Token, Group0} -> Group0
                               after 5000 -> error(fipa_custody_not_reserved) end,
                    {_, Consensus} = sys:get_state(quod_reg:where({quod_simplex, ReceiverNs})),
                    ?assertMatch(#{reserved := 1}, quod_simplex:test_dtx_admission_state(Consensus)),
                    {OldRuntime, [#{pid := OldChild}]} = domain_agents(ReceiverNs),
                    ChildMonitor = monitor(process, OldChild),
                    exit(OldRuntime, kill),
                    receive {'DOWN', ChildMonitor, process, OldChild, _} -> ok
                    after 5000 -> error(admitted_worker_survived_owner) end,
                    Engine ! {release_fipa_custody, Token},
                    {NewRuntime, _} = installed(ReceiverRef, 1),
                    ?assertNotEqual(OldRuntime, NewRuntime),
                    %% The original admitted group may finish while its actor
                    %% is stopped. Recovery must observe that outcome, not
                    %% manufacture a second execution just to emit a reply.
                    await_fipa_done(SenderNs, ReceiverNs, Waiting, Pending, GroupRef),
                    fipa_assert_done(SenderNs, ReceiverNs, Waiting, Pending)
                after
                    Engine ! {release_fipa_custody, Token},
                    catch sys:remove(Engine, Token)
                end;
            During when During =:= restart_proof; During =:= rotate_proof ->
                Reaction ! release,
                {OldProof, OldOperation} = fipa_prepared(),
                ProofMonitor = monitor(process, OldProof),
                Resume = case During of
                    restart_proof ->
                        stop_ontology(Receiver),
                        Reopened = start_ontology(ReceiverNs, Dir, Identity, [], [],
                                    #{mode => join, genesis_hash => element(3, ReceiverRef)}),
                        _ = installed(ReceiverRef, 1),
                        Reopened;
                    rotate_proof ->
                        {ok, NextKey} = quod_agent_vault:generate(Blob),
                        commit(ReceiverNs, {goal, {agent_assignment, receiver,
                                                   Node, 1, Node, 2, NextKey}}),
                        _ = installed(ReceiverRef, 2),
                        Receiver
                end,
                try
                    receive {'DOWN', ProofMonitor, process, OldProof, _} -> ok
                    after 5000 -> error(old_fipa_proof_survived) end,
                    {NewProof, NewOperation} = fipa_prepared(),
                    ?assertNotEqual(OldOperation, NewOperation),
                    NewProof ! release,
                    ?assertMatch({normalized, {committed, _, _}}, fipa_request_result(ReceiverRef)),
                    fipa_assert_done(SenderNs, ReceiverNs, Waiting, Pending)
                after stop_ontology(Resume) end;
            reject_reply ->
                commit(SenderNs, {retract, allow_fipa_reply}),
                Reaction ! release,
                ?assertMatch({normalized, {failed, _}}, fipa_request_result(ReceiverRef)),
                ?assertMatch({fail, _}, quod_prolog:prove_ro(ReceiverNs, {reserved, object})),
                ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(ReceiverNs, {available, object})),
                ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(ReceiverNs, Pending)),
                ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(SenderNs, Waiting));
            complete ->
                Reaction ! release,
                ?assertMatch({normalized, {committed, _, _}}, fipa_request_result(ReceiverRef)),
                fipa_assert_done(SenderNs, ReceiverNs, Waiting, Pending),
                commit(SenderNs, {trigger_event, {start_fipa, Id, ReceiverRef, Action}}),
                ?assertMatch({normalized, {failed, _}}, fipa_request_result(SenderRef)),
                fipa_assert_done(SenderNs, ReceiverNs, Waiting, Pending),
                %% Read back through real ledger replay with A's old processes gone.
                stop_ontology(quod_reg:where({quod_ns, SenderNs})),
                Resumed = start_ontology(SenderNs, Dir, Identity, [], [],
                            #{mode => join, genesis_hash => element(3, SenderRef)}),
                try
                    _ = installed(SenderRef, 1),
                    fipa_assert_done(SenderNs, ReceiverNs, Waiting, Pending),
                    ?assertMatch(#{reconcile_failures := 0, reaction_failures := 0}, quod_runtime:stats(SenderNs))
                after stop_ontology(Resumed) end
        end
    after
        quod_reg:unsubscribe({agent, ReceiverRef}),
        quod_reg:unsubscribe({agent_hosting, ReceiverNs}),
        stop_ontology(Receiver)
    end.

fipa_participant_rules(Ns, Node, Sender, Pub, Scenario) ->
    Id = {'Id'}, Action = {'Action'}, Anchor = {'Anchor'},
    Handling = case fipa_automatic(Scenario) of
        true ->
            [{fipa_request_continuation, receiver, 5000},
             owned_reaction(receiver, {fipa_request_received, receiver, Id, Sender, Action},
                            true, {',', test_reaction_barrier, fail})];
        false ->
            [owned_reaction(receiver, {fipa_request_received, receiver, Id, Sender, Action},
                            {fipa_fulfil_request, receiver, Id}, test_reaction_barrier)]
    end,
    Reserve = {',', {retract, {available, object}}, {assertz, {reserved, object}}},
    ReserveBody = case Scenario of
        During when During =:= restart_proof; During =:= rotate_proof ->
            {',', test_fipa_completion, Reserve};
        _ -> Reserve
    end,
    [{can_assign_agent_host, {node, Pub}, receiver, {'_'}, {'_'}, Node, {'_'}},
     {can_invoke, {'_'}, Node, {'_'}, Ns},
     {can_invoke, {fipa_fulfil_request, receiver, Id},
      {agent_instance_ref, Ns, {'_'}, receiver}, {'_'}, Ns},
     {can_invoke, {',', {fipa_fulfil_request, receiver, Id}, test_fipa_completion},
      {agent_instance_ref, Ns, {'_'}, receiver}, {'_'}, Ns},
     {can_invoke, {',', {current_ontology_identity, Ns, Anchor},
                       {fipa_receive_request, receiver, Id, Action}}, Sender, {'_'}, Ns},
     {can_request_agent_signature, Node, receiver, {'_'}},
     {fipa_request_allowed, receiver, Sender, {reserve, object}},
     {fipa_request_goal, receiver, {reserve, object}, {reserved, object}},
     {available, object},
     {action, reserve_object, [{available, object}], {reserved, object}},
     {':-', reserve_object, ReserveBody}] ++ Handling.

fipa_automatic(restart_pending) -> true;
fipa_automatic(restart_proof) -> true;
fipa_automatic(rotate_proof) -> true;
fipa_automatic(restart_admitted) -> true;
fipa_automatic(_) -> false.

fipa_prepared() ->
    receive {fipa_completion_prepared, Proof, Operation} -> {Proof, Operation}
    after 5000 -> error(fipa_proof_not_prepared) end.

fipa_competing_completions({agent_instance_ref, Ns, Anchor, receiver}, Key, Id) ->
    {ok, Network} = quod_ontology:network_identity(),
    Goal = {',', {fipa_fulfil_request, receiver, Id}, test_fipa_completion},
    {ok, GoalText} = quod_client_goal_parser:format(Goal),
    Request = #{network_identity => Network, agent_namespace => Ns,
                agent_genesis_anchor => Anchor, agent_instance_text => <<"receiver.">>,
                signing_public_key => Key, not_after_ms => quod_time:now_ms() + 10000,
                mode => execute, parser_version => 2, goal_text => GoalText},
    Parent = self(),
    Jobs = [begin
        {ok, Bytes, Signature} = quod_agent_vault:sign(
            Request#{operation_id => crypto:strong_rand_bytes(32)}, quod_time:mono_ms() + 5000),
        {ok, #{operation_ref := Operation}} = quod_client_goal:verify(Bytes, Signature),
        {Pid, Monitor} = spawn_monitor(fun() ->
            Result = case quod_client_goal_ingress:submit(Bytes, Signature) of
                         {ok, _, Outcome} -> Outcome;
                         Error -> Error
                     end,
            Parent ! {fipa_completion_result, Operation, Result}
        end),
        {Operation, Pid, Monitor}
    end || _ <- [first, second]],
    try
        Prepared = [receive {fipa_completion_prepared, Proof, Op} -> {Op, Proof}
                    after 5000 -> error(fipa_completion_not_prepared) end
                    || {Op, _, _} <- Jobs],
        [{First, FirstProof}, {Second, SecondProof}] = Prepared,
        FirstProof ! release,
        receive {fipa_completion_result, First, FirstResult} ->
            ?assertMatch({normalized, {committed, _, _}}, FirstResult)
        after 5000 -> error(first_fipa_completion_missing) end,
        SecondProof ! release,
        receive {fipa_completion_result, Second, SecondResult} ->
            ?assertMatch({normalized, {failed, _}}, SecondResult),
            {normalized, {failed, Reasons}} = SecondResult,
            ?assertEqual({ok, [conflict_retry]}, quod_wire_term:decode_failure_reasons(Reasons))
        after 5000 -> error(second_fipa_completion_missing) end
    after
        lists:foreach(fun({_Op, Pid, Monitor}) ->
            exit(Pid, kill),
            receive {'DOWN', Monitor, process, Pid, _} -> ok
            after 1000 -> error(fipa_completion_worker_survived) end
        end, Jobs)
    end.

fipa_request_result(Ref) ->
    receive
        {agent_request_finished, _, _, #{reference := Ref}, _, {ok, _, Outcome}} -> Outcome;
        {agent_request_finished, Owner, Child, #{reference := Ref}, _,
         {error, {outcome_unknown, Operation}} = Result} ->
            %% Keep the first failure's actual owner and retained outcome;
            %% diagnostics neither resubmit nor change the assertion below.
            Ns = element(2, Ref),
            Outcome = quod_prolog:outcome(Operation),
            Underlying = case Outcome of
                {ok, #{outcome_ref := {group, _, _, _, _, _} = Group}} ->
                    quod_prolog:outcome(Group);
                _ -> none
            end,
            io:format("FIPA uncertain completion: ~p~n", [
                #{owner => Owner, child => Child,
                  current_owner => quod_reg:where({quod_runtime, Ns}),
                  outcome => Outcome, group => Underlying,
                  consensus => maps:with([slot, protocol_view, last_applied,
                      custody_depth, custody_ready, progress_timeouts,
                      owner_current, dtx_admission_waiting, syncing],
                      quod_simplex:stats(Ns)),
                  foreign_history => quod_foreign_log:test_lifecycle_state()}]),
            %% Observe only the original operation's receipt, without another
            %% submission. An atomic group receipt can still name a pending
            %% group; this is not evidence that the domain transition finished.
            Receipt = catch quod_ct:await_operation_complete(Ns, Operation, 15000),
            io:format("FIPA original operation receipt after uncertainty: ~p~n", [Receipt]),
            Result;
        {agent_request_finished, _, _, #{reference := Ref}, _, Result} -> Result
    after 10000 -> error({fipa_request_result_missing, Ref}) end.

await_fipa_done(SenderNs, ReceiverNs, Waiting, Pending, GroupRef) ->
    true = quod_reg:subscribe({runtime, SenderNs}),
    true = quod_reg:subscribe({runtime, ReceiverNs}),
    try await_fipa_done_read(SenderNs, ReceiverNs, Waiting, Pending, GroupRef,
                            quod_time:mono_ms() + 15000)
    after
        quod_reg:unsubscribe({runtime, SenderNs}),
        quod_reg:unsubscribe({runtime, ReceiverNs})
    end.

await_fipa_done_read(SenderNs, ReceiverNs, Waiting, Pending, GroupRef, Deadline) ->
    case {quod_prolog:prove_ro(SenderNs, setelement(7, Waiting, done)),
          quod_prolog:prove_ro(ReceiverNs, setelement(7, Pending, done))} of
        {{ok, [_], _}, {ok, [_], _}} -> ok;
        _ ->
            Remaining = max(0, Deadline - quod_time:mono_ms()),
            receive
                {applied_live, _} -> await_fipa_done_read(SenderNs, ReceiverNs, Waiting, Pending, GroupRef, Deadline);
                {projection_advanced, _, _} -> await_fipa_done_read(SenderNs, ReceiverNs, Waiting, Pending, GroupRef, Deadline);
                {replay_ready, _, _} -> await_fipa_done_read(SenderNs, ReceiverNs, Waiting, Pending, GroupRef, Deadline)
            after Remaining ->
                error({fipa_recovery_not_complete, quod_prolog:outcome(GroupRef),
                       quod_runtime:stats(ReceiverNs)})
            end
    end.

fipa_assert_done(SenderNs, ReceiverNs, Waiting, Pending) ->
    ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(SenderNs, setelement(7, Waiting, done))),
    ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(ReceiverNs, setelement(7, Pending, done))),
    ?assertMatch({ok, [#{'Objects' := [object]}], _}, quod_prolog:prove_ro(ReceiverNs,
       {findall, {'Object'}, {reserved, {'Object'}}, {'Objects'}})),
    ?assertMatch({fail, _}, quod_prolog:prove_ro(SenderNs,
       {fipa_request_completed, actor, element(3, Waiting), element(5, Waiting), element(6, Waiting)})).

unexpected_child_exit_enters_ontology_reaction_test_() ->
    {timeout, 60, fun() ->
        with_host(fun(#{namespace := Ns, reference := Ref, node := Node, key := Key}) ->
            true = quod_reg:reg({host_test, barrier}),
            try
                commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
                {Owner, Child} = installed(Ref, 1),
                OtherRef = setelement(4, Ref, other),
                commit(Ns, {goal, {agent_hosted, other, Node, 1, <<91:256>>}}),
                {Owner, _} = installed(OtherRef, 1),
                exit(Child, kill),
                Runner = receive {host_projection_waiting, R} -> R
                         after 5000 -> error(missing_process_down_reaction) end,
                %% Handler ran through real unification, with exact incarnation
                %% guards. No event fact was asserted by lifecycle observation.
                ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns,
                    {agent_process_down, Ref, 1, Key, {'_'}})),
                Runner ! release,
                {Owner, Replacement} = installed(Ref, 1),
                ?assertNotEqual(Child, Replacement),
                %% Direct restoration handles intentional assignment changes;
                %% only an unexpected death may create a failure observation.
                1 = erlang:trace_pattern({quod_runtime, observe_agent_down, 2}, true, [local]),
                1 = erlang:trace(Owner, true, [call]),
                try
                    {ok, Blob} = quod_wire_term:encode_canonical(Ref),
                    {ok, NextKey} = quod_agent_vault:generate(Blob),
                    commit(Ns, {goal, {agent_assignment, actor, Node, 1, Node, 2, NextKey}}),
                    {Owner, _} = installed(Ref, 2),
                    Barrier = erlang:trace_delivered(Owner),
                    receive {trace_delivered, Owner, Barrier} -> ok
                    after 1000 -> error(retirement_trace_incomplete) end,
                    receive
                        {trace, Owner, call, {quod_runtime, observe_agent_down, _}} ->
                            error(intentional_exit_reported)
                    after 0 -> ok end
                after
                    erlang:trace(Owner, false, [call]),
                    erlang:trace_pattern({quod_runtime, observe_agent_down, 2}, false, [local])
                end
            after gproc:unreg(quod_reg:name({host_test, barrier})) end
        end, fun process_down_rules/1)
    end}.

process_down_rules(_Pub) ->
    [{':-', {react_on,
              {observed, {agent_process_down,
                {agent_instance_ref, <<"host-test-agent">>, {'Anchor'}, actor},
                1, {'Key'}, {'Observation'}}},
              true},
       {',', {me, {agent_instance_ref, <<"host-test-agent">>, {'_'}, other}},
        {',', {agent_hosted, actor, {'Node'}, 1, {'Key'}},
         {',', {agent_identifier, {'Observation'}},
          {',', test_reaction_barrier, fail}}}}}].

observation_during_restoration_survives_pending_installation_test_() ->
    {timeout, 60, fun() ->
        true = quod_reg:reg({host_test, barrier}),
        try with_host(fun(#{namespace := Ns, reference := Ref, node := Node, key := Key}) ->
            commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
            {Runtime, Child} = installed(Ref, 1),
            OtherRef = setelement(4, Ref, other),
            commit(Ns, {goal, {agent_hosted, other, Node, 1, <<91:256>>}}),
            {Runtime, _} = installed(OtherRef, 1),
            Pause = pause_resource(Runtime, agent_hosts),
            request_resource(Ns, agent_hosts),
            Runner = paused_resource(Pause),
            Parent = self(),
            Handled = fun(State, {in, {{agent_down, {agent, actor}}, _, process, Pid, _}}, _)
                           when Pid =:= Child -> Parent ! observed_child_down, State;
                         (State, _, _) -> State end,
            ok = sys:install(Runtime, {Handled, none}),
            try
                exit(Child, kill),
                receive observed_child_down -> ok
                after 5000 -> error(child_down_not_processed_during_restoration) end,
                _ = quod_runtime:stats(Ns),
                true = resume_resource(Runtime, Runner),
                receive {host_projection_waiting, Reaction} -> Reaction ! release
                after 5000 -> error(fresh_observation_lost_during_restoration) end,
                _ = installed(Ref, 1),
                ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns,
                             {agent_process_down, Ref, 1, Key, {'_'}}))
            after
                catch resume_resource(Runtime, Runner),
                sys:remove(Runtime, Handled), remove_resource_pause(Runtime, Pause)
            end
        end, fun process_down_rules/1)
        after gproc:unreg(quod_reg:name({host_test, barrier})) end
    end}.

optional_recovery_policy_uses_direct_resource_selection_test_() ->
    {timeout, 60, fun() -> with_host(fun(#{namespace := Ns, reference := Ref,
                                         node := Node, key := Key}) ->
        commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
        _ = installed(Ref, 1),
        ?assertMatch(#{mode := live, reconcile_failures := 0}, quod_runtime:stats(Ns))
    end, fun(_Pub) ->
        {ok, Terms} = erlog_io:read_file(filename:join(code:priv_dir(quod),
                                                      "ontologies/agent_recovery_policy.pl")),
        Terms
    end) end}.

physical_loss_drives_signed_policy_and_host_activation_test_() ->
    [{atom_to_list(Loss), {timeout, 60, fun() ->
        with_host(fun(Ctx) -> physical_recovery(Ctx, Loss) end, fun(_Pub) ->
            {ok, Terms} = erlog_io:read_file(filename:join(code:priv_dir(quod),
                                                          "ontologies/agent_recovery_policy.pl")),
            Terms
        end)
    end}} || Loss <- [graceful, abrupt]].

physical_recovery(#{namespace := Ns, reference := Ref = {agent_instance_ref, Ns, Anchor, _},
                    node := Node = {agent_instance_ref, NodeNs, _, _},
                    key := Key, directory := Dir, identity := Identity}, Loss) ->
    EnvKeys = [listen_port, node_addr, identity_cert],
    Saved = [{K, application:get_env(quod, K)} || K <- EnvKeys],
    {ok, _} = application:ensure_all_started(quic),
    {ok, Socket} = gen_udp:open(0),
    {ok, Port} = inet:port(Socket), ok = gen_udp:close(Socket),
    application:set_env(quod, listen_port, Port),
    application:set_env(quod, node_addr, {"127.0.0.1", Port}),
    application:set_env(quod, identity_cert,
                        maps:get(cert, Identity)),
    {ok, Directory} = quod_directory:start_link(),
    {ok, Transport} = quod_quic:start_link(),
    {Peer, PeerKey, Endpoint} = quod_agent_peer:start(filename:join(Dir, "remote")),
    Old = setelement(2, Node, <<"remote-node">>),
    OldKey = crypto:strong_rand_bytes(32),
    Runtime = quod_reg:where({quod_runtime, Ns}),
    true = quod_reg:subscribe({agent, Node}),
    try
        %% Setup uses ordinary committed policy. Actual recovery has no operator
        %% assignment and uses the optional policy's exact report threshold.
        Facts = [{agent_recovery_observer, actor, Node}, {agent_recovery_threshold, actor, 1},
                 {eligible_agent_host, actor, Node}, {agent_host_rank, actor, Node, 1},
                 {ping, durable_before_loss}],
        lists:foreach(fun(F) -> commit(Ns, {assertz, F}) end, Facts),
        Operations = [{report_agent_observation, actor, Old, 1, {'_'}, {'_'}, {'_'}, {'_'}},
                      {report_agent_observation_with_custody, actor, Old, 1,
                       {'_'}, {'_'}, {'_'}, {'_'}, {'_'}},
                      {prepare_agent_and_converge, actor, Old, 1, Node, Key}],
        commit(NodeNs, work_assertions([{can_execute_for, Ns, Anchor, G} || G <- Operations])),
        1 = erlang:trace_pattern({quod_agent_observer, handle, 2},
                                 [{'_', [], [{return_trace}]}], [local]),
        1 = erlang:trace(Runtime, true, [call]),
        {ok, Blob} = quod_wire_term:encode_canonical(Old),
        {ok, _} = quod_directory:install_generation(
          #{author => {node_actor, Blob}, node_key => PeerKey, endpoint => Endpoint,
            epoch => 1, generation => 1, page => 0, last => true,
            hosted => [{element(2, Old), element(3, Old), observer, node}]}),
        commit(Ns, {goal, {agent_hosted, actor, Old, 1, OldKey}}),
        await_observer_coverage(Runtime, Old),
        erlang:trace(Runtime, false, [call]),
        erlang:trace_pattern({quod_agent_observer, handle, 2}, false, [local]),
        case Loss of
            graceful ->
                Prepared = node_request(Ns, Anchor,
                              {prepare_agent_and_converge, actor, Old, 1, Node, Key},
                              quod_time:now_ms() + 10000),
                ?assertMatch({ok, _, {normalized, {committed, [_], _}}}, Prepared);
            abrupt -> ok
        end,
        ok = case Loss of
            graceful -> quod_agent_peer:stop(Peer);
            %% Default stdio peer stop closes control and halts the VM without
            %% joining application shutdown hooks. No UDP port is rebound here.
            abrupt -> peer:stop(Peer)
        end,
        {Runtime, Child} = installed(Ref, 2),
        ?assert(is_process_alive(Child)),
        {ok, [#{'ActiveKey' := ActiveKey}], _} = quod_prolog:prove_ro(
            Ns, {agent_hosted, actor, Node, 2, {'ActiveKey'}}),
        case Loss of
            graceful -> ?assertEqual(Key, ActiveKey);
            abrupt -> ?assertNotEqual(Key, ActiveKey)
        end,
        ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(Ns, {agent_key, actor, OldKey, revoked})),
        ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(Ns, {ping, durable_before_loss})),
        ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, {agent_failure_report, actor,
                     {'_'}, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}})),
        commit(Ns, {trigger_event, {do_work, after_automatic_move}}),
        receive {agent_request_finished, Runtime, Child, _, _, Result} ->
            ?assertMatch({ok, _, {normalized, {committed, [_], _}}}, Result)
        after 10000 -> error(recovered_agent_not_executing) end,
        ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(Ns, {ping, after_automatic_move}))
    after
        erlang:trace(Runtime, false, [call]),
        erlang:trace_pattern({quod_agent_observer, handle, 2}, false, [local]),
        catch quod_agent_peer:stop(Peer),
        gen_server:stop(Transport), gen_server:stop(Directory),
        quod_reg:unsubscribe({agent, Node}),
        lists:foreach(fun({K, undefined}) -> application:unset_env(quod, K);
                         ({K, {ok, V}}) -> application:set_env(quod, K, V) end, Saved)
    end.

await_observer_coverage(Runtime, Host) ->
    receive
        {trace, Runtime, return_from, {quod_agent_observer, handle, 2},
         {#{hosts := Hosts}, _}} ->
            case maps:find(Host, Hosts) of
                {ok, #{delivered := {_, reachable, _}, pending := none}} -> ok;
                _ -> await_observer_coverage(Runtime, Host)
            end
    after 6000 -> error(no_runtime_observer_coverage) end.

node_execution_policy_installs_through_ordinary_signed_goal_test_() ->
    {timeout, 60, fun() -> with_host(fun(Ctx = #{namespace := Ns,
        reference := {agent_instance_ref, Ns, Anchor, _}, node := {agent_instance_ref, NodeNs, NodeAnchor, _}}) ->
        Submit = fun(Goal) ->
            {ok, B, Sig} = quod_node_actor:signed_goal(execute, Goal,
                crypto:strong_rand_bytes(32), quod_time:now_ms() + 10000),
            quod_client_goal_ingress:submit(B, Sig)
        end,
        ?assertMatch({ok, _, {normalized, {committed, [_], {transaction, NodeNs, NodeAnchor, _}}}},
                     Submit({assertz, {can_execute_for, Ns, Anchor, true}})),
        ?assertMatch({ok, _, {normalized, {failed, _}}},
                     Submit({node_authorized_goal, Ns, Anchor, true})),
        Source = filename:join(code:priv_dir(quod), "ontologies/node_execution.pl"),
        [SourceRule] = [Term || {':-', {node_authorized_goal, _, _, _}, _} = Term
                          <- quod_prolog:read_terms(Source)],
        RuleText = iolist_to_binary([erlog_io:writeq1(SourceRule), $.]),
        {ok, #{goal := Rule}} = quod_client_goal_parser:parse(RuleText, 2),
        {ok, Bytes, Signature} = quod_node_actor:signed_goal(
          execute, {assertz, Rule}, crypto:strong_rand_bytes(32), quod_time:now_ms() + 10000),
        ?assertMatch({ok, _, {normalized, {committed, [_], {transaction, NodeNs, NodeAnchor, _}}}},
                     quod_client_goal_ingress:submit(Bytes, Signature)),
        %% The same denial/grant/revocation exercise now runs on a node founded
        %% without the helper: ordinary pure-rule installation needs no new
        %% system action or external-predicate manifest.
        node_execution(Ctx)
    end, [], legacy) end}.

node_executor_requires_exact_delegation_at_execution_test_() ->
    {timeout, 60, fun() -> with_host(fun node_execution/1) end}.

node_execution(#{namespace := Ns, reference := {agent_instance_ref, Ns, Anchor, _},
                 node := Node = {agent_instance_ref, NodeNs, _, _}}) ->
    true = quod_reg:subscribe({agent, Node}),
    try
        Expiry = quod_time:now_ms() + 30000,
        Denied = node_request(Ns, Anchor, {record_ping, delegated}, Expiry),
        ?assertMatch({ok, _, {normalized, {failed, _}}}, Denied),
        ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, {ping, delegated})),
        Wrong = {can_execute_for, Ns, <<99:256>>, {record_ping, delegated}},
        commit(NodeNs, {assertz, Wrong}),
        WrongAnchor = node_request(Ns, Anchor, {record_ping, delegated}, Expiry),
        ?assertMatch({ok, _, {normalized, {failed, _}}}, WrongAnchor),
        Grant = {can_execute_for, Ns, Anchor, {record_ping, delegated}},
        commit(NodeNs, {assertz, Grant}),
        Allowed = node_request(Ns, Anchor, {record_ping, delegated}, Expiry),
        ?assertMatch({ok, _, {normalized, {committed, [_], {transaction, Ns, Anchor, _}}}}, Allowed),
        ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(Ns, {ping, delegated})),
        WrongGoal = node_request(Ns, Anchor, {record_ping, ungranted}, Expiry),
        ?assertMatch({ok, _, {normalized, {failed, _}}}, WrongGoal),
        ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, {ping, ungranted})),
        commit(NodeNs, {retract, Grant}),
        Withdrawn = node_request(Ns, Anchor, {record_ping, delegated}, Expiry),
        ?assertMatch({ok, _, {normalized, {failed, _}}}, Withdrawn),
        ?assertEqual({error, stale_node_executor}, quod_node_actor:signed_goal(
          execute, true, crypto:strong_rand_bytes(32), Expiry, {Node, <<99:256>>})),
        ?assertMatch(#{hosted_agents := 0, agent_pending_bytes := 0}, quod_runtime:stats(Ns))
    after quod_reg:unsubscribe({agent, Node}) end.

node_request(Ns, Anchor, Goal, Expiry) ->
    {ok, Bytes, Signature} = quod_node_actor:signed_goal(
        execute, {node_authorized_goal, Ns, Anchor, Goal},
        crypto:strong_rand_bytes(32), Expiry),
    quod_client_goal_ingress:submit(Bytes, Signature).

logical_node_queue_is_scoped_and_withdrawal_retires_owned_actors_test_() ->
    {timeout, 60, fun() -> with_host(fun unrelated_node_retirement/1) end}.

unrelated_node_retirement(#{namespace := Ns, reference := Ref,
                           node := Node = {agent_instance_ref, NodeNs, _, _}, key := Key}) ->
    {ok, Principal} = quod_node_actor:principal(),
    delayed_node_identity_notice(NodeNs, Principal),
    commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
    {Owner, Hosted} = installed(Ref, 1),
    {Owner, [#{pid := Hosted, binding := #{reference := Ref}}]} = quod_runtime:agents(Ns),
    true = quod_reg:subscribe({agent, Node}),
    commit(NodeNs, {assertz, {':-', {react_on, node_scope_probe, true}, {me, Node}}}),
    commit(NodeNs, {trigger_event, node_scope_probe}),
    NodeChild = receive
        {agent_request_finished, _, Pid, #{reference := Node}, _, Result} ->
            ?assertMatch({ok, _, _}, Result), Pid
    after 5000 -> error(node_scope_reaction_not_executed) end,
    {NodeOwner, [#{pid := NodeChild, binding := #{reference := Node}}]} = quod_runtime:agents(NodeNs),
    HostedMonitor = monitor(process, Hosted), NodeMonitor = monitor(process, NodeChild),
    try
        application:unset_env(quod, node_actor_principal),
        true = quod_reg:reg({namespace_manager, node}),
        quod_reg:publish({node_actor, node}, {node_actor_installed, self(), {error, unavailable}}),
        receive {'DOWN', HostedMonitor, process, Hosted, _} -> ok
        after 5000 -> error(logical_withdrawal_not_reconciled) end,
        receive {'DOWN', NodeMonitor, process, NodeChild, _} -> ok
        after 5000 -> error(node_queue_not_withdrawn) end,
        ?assertEqual({Owner, []}, quod_runtime:agents(Ns)),
        ?assertEqual({NodeOwner, []}, quod_runtime:agents(NodeNs))
    after
        demonitor(HostedMonitor, [flush]), demonitor(NodeMonitor, [flush]),
        application:set_env(quod, node_actor_principal, Principal),
        quod_reg:unsubscribe({agent, Node}),
        gproc:unreg(quod_reg:name({namespace_manager, node}))
    end.

%% Model a principal becoming visible to reaction admission before its owner
%% notice is processed. All synchronization uses the real runtime interface.
%% Register the fixture publisher only after the later withdrawal so its
%% registration cannot accidentally refresh the installed-identity cache early.
delayed_node_identity_notice(NodeNs, Principal) ->
    quod_runtime:reconcile_now(NodeNs),
    {Runtime, Existing} = quod_runtime:agents(NodeNs),
    Monitors = [{Pid, monitor(process, Pid)} || #{pid := Pid} <- Existing],
    try
        application:unset_env(quod, node_actor_principal),
        quod_runtime:reconcile_now(NodeNs),
        ?assertEqual({Runtime, []}, quod_runtime:agents(NodeNs)),
        lists:foreach(fun({Pid, Monitor}) ->
            receive {'DOWN', Monitor, process, Pid, _} -> ok
            after 5000 -> error(initial_node_queue_not_withdrawn) end
        end, Monitors)
    after
        [demonitor(Monitor, [flush]) || {_, Monitor} <- Monitors],
        application:set_env(quod, node_actor_principal, Principal)
    end.

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

failed_staged_assignment_cannot_install_hosted_process_test_() ->
    {timeout, 60, fun() -> with_host(fun(#{namespace := Ns, reference := Ref,
                                         node := Node, key := Key}) ->
        commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
        {Runtime, Child} = installed(Ref, 1),
        Goal = {',', {assertz, {agent_key, uncommitted, Key, active}},
                 {',', {assertz, {agent_host, uncommitted, Node, 1, Key}}, fail}},
        ?assertEqual(fail, quod_prolog:execute(Ns, Goal)),
        {Runtime, Agents} = quod_runtime:agents(Ns),
        ?assertEqual([Child], [P || #{pid := P, binding := #{reference :=
                              {agent_instance_ref, Ns0, _, _}}} <- Agents, Ns0 =:= Ns]),
        ?assertMatch({fail, _}, quod_prolog:prove_ro(Ns, {agent_host, uncommitted, {'_'}, {'_'}, {'_'}})),
        ?assertMatch(#{mode := live, reconcile_failures := 0}, quod_runtime:stats(Ns))
    end) end}.

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
            after 5000 -> error(queue_not_filled) end,
            %% The guard kept these queues unreleased. Direct resource
            %% restoration reconstructs processes, never their discarded goals.
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
              #{reference => Ref, epoch => 1, public_key => Key}}]}, domain_agents(Ns))
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
                {trace, Owner, 'receive', {'$gen_call', {Caller, _}, {project_agents, _, _}}} -> Caller
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
            ?assertEqual({Owner, []}, domain_agents(Ns))
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
    ?assertEqual({Owner, []}, domain_agents(Ns)),
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
            commit(Ns, {trigger_event, {do_short_work, expires, quod_time:now_ms() + 1000}}),
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
    {ok, Child} = quod_agent:start(self(), {agent, worker}, Binding),
    Token = make_ref(),
    try
        Child ! {agent_request, self(), Token, 7,
                 {execute, true, quod_time:now_ms() + 60000, quod_time:mono_ms() - 1},
                 erlang:monotonic_time(microsecond)},
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
    true = quod_reg:reg({namespace_manager, node}),
    {ok, Principal} = quod_node_actor:principal(),
    application:unset_env(quod, node_actor_principal),
    Ns = <<"host-test-lifecycle">>,
    Remote = setelement(2, Node, <<"remote">>),
    Rows = [{host, I, Remote, 1, <<81:256>>} || I <- lists:seq(1, 1100)] ++
           [{host, local, Node, 1, <<82:256>>}],
    true = quod_reg:subscribe({agent_hosting, Ns}),
    Sup = start_ontology(Ns, Dir, Identity, [],
      [{custom_hosts, Rows},
       {':-', {agent_hosting_projection, {'_'}, {'Node'}, all, {'Hosts'}},
         {';', {'->', {'=', {'Node'}, none}, {'=', {'Hosts'}, []}},
                {custom_hosts, {'Hosts'}}}}]),
    Ref = {agent_instance_ref, Ns, quod_simplex:genesis_hash(Ns), local},
    Runtime = quod_reg:where({quod_runtime, Ns}),
    try
        ?assertEqual({Runtime, []}, domain_agents(Ns)),
        BootPause = pause_resource(Runtime, agent_hosts),
        request_resource(Ns, agent_hosts),
        First = paused_resource(BootPause),
        try
            application:set_env(quod, node_actor_principal, Principal),
            quod_reg:publish({node_actor, node}, {node_actor_installed, self(), {ok, Principal}}),
            _ = quod_runtime:stats(Ns),
            true = resume_resource(Runtime, First)
        after catch resume_resource(Runtime, First), remove_resource_pause(Runtime, BootPause) end,
        {Runtime, Child} = installed(Ref, 1),
        RefreshPause = pause_resource(Runtime, agent_hosts),
        request_resource(Ns, agent_hosts),
        Refresh = paused_resource(RefreshPause),
        try
            Monitor = monitor(process, Child),
            exit(Child, kill),
            receive {'DOWN', Monitor, process, Child, _} -> ok
            after 5000 -> error(hosted_child_not_stopped) end,
            true = resume_resource(Runtime, Refresh)
        after catch resume_resource(Runtime, Refresh), remove_resource_pause(Runtime, RefreshPause) end,
        {Runtime, Replacement} = installed(Ref, 1),
        ?assertNotEqual(Child, Replacement),
        ?assertMatch(#{hosted_agent_instances := 1, reconcile_failures := 0}, quod_runtime:stats(Ns)),
        WithdrawalMonitor = monitor(process, Replacement),
        application:unset_env(quod, node_actor_principal),
        quod_reg:publish({node_actor, node}, {node_actor_installed, self(), {error, unavailable}}),
        receive {'DOWN', WithdrawalMonitor, process, Replacement, _} -> ok
        after 10000 -> error(agent_not_withdrawn) end,
        ?assertEqual({Runtime, []}, domain_agents(Ns))
    after
        application:set_env(quod, node_actor_principal, Principal),
        stop_ontology(Sup),
        quod_reg:unsubscribe({agent_hosting, Ns}),
        gproc:unreg(quod_reg:name({namespace_manager, node}))
    end.

domain_agents(Ns) ->
    {Owner, Agents} = quod_runtime:agents(Ns),
    {Owner, [A || A = #{binding := #{reference := {agent_instance_ref, _, _, _}}} <- Agents]}.

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
       owned_reaction(receiver, {from, SenderNs, SourceAnchor, {request, {'Id'}}},
                      {record_reply, {'Id'}}),
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
    ?assertEqual({error, stale_resource_owner}, quod_runtime:project_agents(Ns, all, [])),
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

with_host(Fun, ExtraFacts) -> with_host(Fun, ExtraFacts, current).

with_host(Fun, ExtraFacts, NodePolicy) ->
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
    Identity = #{pubkey => Pub, key => quod_identity:key_term(Pair),
                 cert => quod_identity:mint_cert(Pair)},
    application:set_env(quod, node_pubkey, Pub),
    application:set_env(quod, identity_key, maps:get(key, Identity)),
    application:set_env(quod, namespace_desired,
      #{content => #{quod_ontology:root_ns() => #{genesis_hash => <<42:256>>}}, brahms => #{}}),
    {ok, Router} = quod_ask_router:start_link(),
    {ok, Auth} = quod_client_auth:start_link(#{network_id => <<42:256>>, node_key => Pub}),
    Dir = filename:join("/tmp", "quod_hosted_" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8)))),
    ok = filelib:ensure_dir(filename:join(Dir, "file")),
    Unlock = filename:join(Dir, "unlock"),
    ok = quod_file:write_atomic(Unlock, crypto:strong_rand_bytes(32), 8#600),
    {ok, Vault} = quod_agent_vault:start_link(#{directory => filename:join(Dir, "keys"), unlock_file => Unlock}),
    NodeNs = <<"host-test-node">>, Ns = <<"host-test-agent">>,
    NodeExecution = filename:join(code:priv_dir(quod), "ontologies/node_execution.pl"),
    NodeDiff = case NodePolicy of
        current -> quod_prolog:genesis_diff(NodeExecution);
        legacy -> []
    end,
    NodeFacts = [{agent_key, physical_node, Pub, active},
                 {node_ontology, NodeNs}, {instance_of, node, physical_node}],
    LegacyAdmission = case NodePolicy of
        current -> [];
        legacy -> [{can_invoke, {'_'}, {agent_instance_ref, NodeNs, {'_'}, physical_node},
                    [NodeNs], NodeNs}]
    end,
    NodeOntology = start_ontology(NodeNs, Dir, Identity, NodeDiff, NodeFacts ++ LegacyAdmission),
    Node = {agent_instance_ref, NodeNs, quod_simplex:genesis_hash(NodeNs), physical_node},
    {ok, NodeBlob} = quod_wire_term:encode_canonical(Node),
    application:set_env(quod, node_actor_principal, {agent, NodeBlob}),
    Source = filename:join(code:priv_dir(quod), "ontologies/agent_instance.pl"),
    Diff = quod_prolog:genesis_diff(Source),
    true = quod_reg:subscribe({agent_hosting, Ns}),
    Additional = case ExtraFacts of
        F when is_function(F, 1) -> F(Pub);
        Facts -> Facts
    end,
    ActorOntology = start_ontology(Ns, Dir, Identity, Diff,
      [{can_assign_agent_host, {node, Pub}, actor, {'_'}, {'_'}, Node, {'_'}},
       {can_assign_agent_host, {node, Pub}, actor, {'_'}, {'_'}, setelement(2, Node, <<"remote-node">>), {'_'}},
       {can_assign_agent_host, {node, Pub}, other, {'_'}, {'_'}, Node, {'_'}},
       {can_invoke, {'_'}, Node, {'_'}, Ns},
       {can_invoke, {record_ping, {'_'}}, {agent_instance_ref, Ns, {'_'}, actor}, {'_'}, Ns},
       {can_request_agent_signature, Node, actor, {'_'}},
       owned_reaction(actor, pause_batch, true, test_reaction_barrier),
       owned_reaction(actor, fill_agents, true, test_fill_agents),
       owned_reaction(actor, {do_short_work, {'Value'}, {'Expiry'}},
                      {record_ping, {'Value'}}, {limit_reaction_expiry, {'Expiry'}}),
       owned_reaction(actor, {do_work, {'Value'}}, {record_ping, {'Value'}}),
       {':-', {record_ping, {'Value'}},
         {',', {assertz, {ping, {'Value'}}}, {trigger_event, {request, {'Value'}}}}}] ++ Additional),
    Ref = {agent_instance_ref, Ns, quod_simplex:genesis_hash(Ns), actor},
    {ok, RefBlob} = quod_wire_term:encode_canonical(Ref),
    {ok, Key} = quod_agent_vault:generate(RefBlob),
    true = quod_reg:subscribe({agent, Ref}),
    Result = try
        {ok, Fun(#{namespace => Ns, reference => Ref, node => Node, key => Key,
                   directory => Dir, identity => Identity})}
    catch Class:Reason:Stack -> {failed, Class, Reason, Stack}
    after
        quod_reg:unsubscribe({agent, Ref}),
        quod_reg:unsubscribe({agent_hosting, Ns}),
        stop_ontology(ActorOntology), stop_ontology(NodeOntology),
        gen_server:stop(Vault), gen_server:stop(Auth), gen_server:stop(Router),
        ok = file:delete(BeamPath),
        lists:foreach(fun({K, undefined}) -> application:unset_env(quod, K);
                         ({K, {ok, V}}) -> application:set_env(quod, K, V)
                      end, Saved)
    end,
    case Result of
        {ok, Value} ->
            ok = file:del_dir_r(Dir),
            Value;
        {failed, FailureClass, FailureReason, FailureStack} ->
            io:format("Failed hosted-agent fixture retained at ~s~n", [Dir]),
            erlang:raise(FailureClass, FailureReason, FailureStack)
    end.

owned_reaction(Instance, Event, Goal) -> owned_reaction(Instance, Event, Goal, true).

owned_reaction(Instance, Event, Goal, Guard) ->
    {':-', {react_on, Event, Goal},
      {',', {me, {agent_instance_ref, {'_'}, {'_'}, Instance}}, Guard}}.

start_ontology(Ns, Dir, Identity, Diff, Terms) ->
    start_ontology(Ns, Dir, Identity, Diff, Terms, #{}).

start_ontology(Ns, Dir, Identity, Diff, Terms, BootConfig) ->
    true = quod_reg:subscribe({runtime, Ns}),
    {ok, Sup} = quod_ns:start_link(Ns, maps:merge(
      #{node_id => maps:get(pubkey, Identity), identity => Identity,
        data_dir => filename:join(Dir, binary_to_list(Ns)), mode => create,
        external_predicate_modules => [quod_agent_predicates, quod_agent_work_predicates, ?MODULE],
        genesis_diff => Diff ++ quod_prolog:terms_to_diff(Terms)}, BootConfig)),
    unlink(Sup),
    receive {replay_ready, _, _} -> ok after 10000 -> error({ontology_not_ready, Ns}) end,
    quod_reg:unsubscribe({runtime, Ns}),
    %% This fixture directly owns namespace supervisors. Retain the same
    %% anchored hosting declaration that the real namespace manager keeps
    %% across a child restart; a dead child must not become a foreign target.
    {ok, #{content := Content} = Projection} = application:get_env(quod, namespace_desired),
    Anchor = quod_simplex:genesis_hash(Ns),
    application:set_env(quod, namespace_desired,
        Projection#{content => Content#{Ns => #{genesis_hash => Anchor}}}),
    Sup.

stop_ontology(Sup) ->
    Monitor = monitor(process, Sup),
    exit(Sup, shutdown),
    receive {'DOWN', Monitor, process, Sup, _} -> ok after 5000 -> error(namespace_stop_timeout) end.

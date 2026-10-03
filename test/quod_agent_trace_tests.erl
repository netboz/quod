-module(quod_agent_trace_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").

-define(SECRET, <<"agent-trace-private-payload">>).

hosted_queue_trace_preserves_release_parenting_and_redaction_test_() ->
    {timeout, 60, fun() -> quod_trace_tests:with_tracer(fun() ->
      quod_agent_hosting_tests:with_host(fun(Ctx) ->
        #{namespace := Ns, reference := Ref} = Ctx,
        {Owner, Child} = install(Ctx),
        Parent = self(), Tag = make_ref(),
        Observe = fun(State, {in, {agent_request, RequestOwner, _, _,
                        {execute, {record_ping, ?SECRET}, Expiry, _}, At}}, _)
                        when RequestOwner =:= Owner ->
                          Parent ! {Tag, At, Expiry},
                          receive {release_request, Tag} -> State end;
                     (State, _, _) -> State
                  end,
        ok = sys:install(Child, {Observe, none}),
        try
            commit(Ns, {trigger_event, trace_queue}),
            {QueuedAt, Expires} = receive {Tag, At, Expiry} -> {At, Expiry}
            after 5000 -> error(agent_request_not_received) end,
            ReleasedAt = erlang:monotonic_time(microsecond),
            Child ! {release_request, Tag},
            {ok, #{request := Request}, {normalized, {committed, _, _}}} = completed(Ref),
            ?assertEqual(Expires, maps:get(not_after_ms, Request)),
            {Root, Sign, Submit} = request_spans(<<"agent">>, <<"committed">>),
            ?assert(maps:get('quod.agent.queue_us', attributes(Root)) >= ReleasedAt - QueuedAt),
            Trace = Root#span.trace_id,
            Targets = [quod_trace_tests:take_span(<<"quod.client.target_execute">>, Trace)
                       || _ <- [1, 2]],
            ?assertEqual(lists:sort([Sign#span.span_id, Submit#span.span_id]),
                         lists:sort([S#span.parent_span_id || S <- Targets])),
            ?assertMatch({ok, [#{}], _}, quod_prolog:prove_ro(Ns, {ping, ?SECRET}))
        after
            Child ! {release_request, Tag},
            sys:remove(Child, Observe)
        end
    end, [owned_reaction(trace_queue, {record_ping, ?SECRET}, true)]) end) end}.

checkpointed_worker_loss_is_traced_as_pending_test_() ->
    {timeout, 60, fun() -> quod_trace_tests:with_tracer(fun() ->
      quod_agent_hosting_tests:with_host(fun(Ctx) ->
        #{namespace := Ns, reference := Ref} = Ctx,
        install(Ctx),
        true = quod_reg:reg({host_test, barrier}),
        try
            commit(Ns, {trigger_event, trace_pending}),
            Runner = reaction_barrier(),
            Engine = quod_reg:where({quod_prolog, Ns}),
            Simplex = quod_reg:where({quod_simplex, Ns}),
            Parent = self(), Tag = make_ref(),
            Observe = fun(State, {in, {'$gen_call', {Worker, _},
                          {checkpoint_and_release_proof_snapshot, _, Checkpoint}}}, _) ->
                              Parent ! {Tag, Worker, Checkpoint},
                              receive {release_checkpoint, Tag} -> State end;
                         (State, _, _) -> State
                      end,
            ok = sys:install(Engine, {Observe, none}),
            try
                Runner ! release,
                {Worker, Checkpoint} = receive {Tag, W, C} -> {W, C}
                                      after 5000 -> error(proof_not_checkpointed) end,
                %% Stop ordering only after authentication and proof sealing.
                %% The normal checkpoint owner must retain uncertainty when
                %% this worker dies, without changing any request deadline.
                ok = sys:suspend(Simplex),
                Engine ! {release_checkpoint, Tag},
                ?assert(maps:get(proof_waiters, quod_prolog:stats(Ns)) >= 1),
                exit(Worker, kill),
                ?assertMatch({ok, _, {normalized, {pending, Checkpoint}}}, completed(Ref)),
                request_spans(<<"agent">>, <<"pending">>)
            after
                Engine ! {release_checkpoint, Tag},
                sys:resume(Simplex),
                sys:remove(Engine, Observe)
            end
        after gproc:unreg(quod_reg:name({host_test, barrier})) end
    end, [owned_reaction(trace_pending, {record_ping, ?SECRET},
                         test_reaction_barrier)]) end) end}.

custody_trace_uses_existing_node_worker_without_exporting_key_test_() ->
    {timeout, 60, fun() -> quod_trace_tests:with_tracer(fun() ->
      quod_agent_hosting_tests:with_host(fun(Ctx) ->
        #{namespace := Ns, reference := AgentRef,
          node := {agent_instance_ref, NodeNs, NodeAnchor, _} = Node,
          identity := #{pubkey := Pub}, key := Key} = Ctx,
        Anchor = element(3, AgentRef),
        commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
        commit(Ns, {assertz, {can_prepare_agent_key, Node, actor, Node, 1}}),
        commit(element(2, Node), {assertz, {can_execute_for, Ns, Anchor,
                                          {record_preparation, {'_'}}}}),
        %% Exercise already-matched work in the node's own behavior scope.
        %% Its trusted handler constructs the permitted foreign operation;
        %% the runtime never wraps a foreign reaction as node work.
        {ok, Child} = quod_agent:start(self(), node,
            #{reference => Node, credential => node, epoch => 0, public_key => Pub,
              source => {NodeNs, NodeAnchor}}),
        true = quod_reg:subscribe({agent, Node}),
        try
            Work = {custody, AgentRef, 1, {0},
                    {node_authorized_goal, Ns, Anchor, {record_preparation, {0}}}},
            Child ! {agent_request, self(), make_ref(), 1,
                     {{node, Node, execute}, Work, quod_time:now_ms() + 10000,
                      quod_time:mono_ms() + 10000}, erlang:monotonic_time(microsecond)},
            Child ! {agent_release, self(), 1},
            ?assertMatch({ok, _, {normalized, {committed, _, _}}}, completed(Node)),
            {Root, _, _} = request_spans(<<"node">>, <<"committed">>),
            Prepare = quod_trace_tests:take_span(<<"quod.agent.custody_prepare">>, Root#span.trace_id),
            ?assertEqual(Root#span.span_id, Prepare#span.parent_span_id),
            ?assertEqual(#{'quod.agent.result' => <<"ok">>}, attributes(Prepare)),
            ?assertMatch({ok, [#{'Key' := <<_:256>>}], _},
                quod_prolog:prove_ro(Ns, {trace_prepared, {prepared, {'Key'}}}))
        after gen_server:stop(Child), quod_reg:unsubscribe({agent, Node}) end
    end, [{':-', {record_preparation, {'Prepared'}},
           {assertz, {trace_prepared, {'Prepared'}}}}]) end) end}.

owned_reaction(Event, Goal, Guard) ->
    {':-', {react_on, Event, Goal},
     {',', {me, {agent_instance_ref, {'_'}, {'_'}, actor}}, Guard}}.

install(#{namespace := Ns, reference := Ref, node := Node, key := Key}) ->
    commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
    receive {agent_installed, Owner, Child, #{reference := Ref, epoch := 1}, _} -> {Owner, Child}
    after 5000 -> error(agent_not_installed) end.

reaction_barrier() ->
    receive {host_projection_waiting, Runner} -> Runner
    after 5000 -> error(reaction_not_waiting) end.

completed(Ref) ->
    receive {agent_request_finished, _, _, #{reference := Ref}, _, Result} -> Result
    after 15000 -> error(agent_request_not_completed) end.

request_spans(Kind, Result) ->
    %% This isolated fixture admits exactly one live request. Its root selects
    %% the trace; every child assertion then uses that exact trace identity.
    Root = quod_trace_tests:take_span(<<"quod.agent.request">>),
    Sign = quod_trace_tests:take_span(<<"quod.agent.governed_sign">>, Root#span.trace_id),
    Submit = quod_trace_tests:take_span(<<"quod.agent.submit">>, Root#span.trace_id),
    RootAttributes = attributes(Root),
    ?assertEqual(#{'quod.agent.executor_kind' => Kind, 'quod.agent.mode' => <<"execute">>,
                   'quod.agent.result' => Result}, maps:remove('quod.agent.queue_us', RootAttributes)),
    ?assert(maps:get('quod.agent.queue_us', RootAttributes) >= 0),
    ?assertEqual(#{'quod.agent.result' => <<"ok">>}, attributes(Sign)),
    ?assertEqual(#{'quod.agent.result' => Result}, attributes(Submit)),
    lists:foreach(fun(S) -> ?assertEqual(Root#span.span_id, S#span.parent_span_id) end,
                  [Sign, Submit]),
    ?assertEqual(nomatch, binary:match(term_to_binary([attributes(S) || S <- [Root, Sign, Submit]]),
                                     ?SECRET)),
    {Root, Sign, Submit}.

attributes(Span) -> otel_attributes:map(Span#span.attributes).
commit(Ns, Goal) -> ?assertMatch({ok, _, _}, quod_ct:rp(Ns, Goal)).

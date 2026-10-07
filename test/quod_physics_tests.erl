-module(quod_physics_tests).
-include_lib("eunit/include/eunit.hrl").

optional_retained_world_test_() ->
    {timeout, 90, fun() ->
        with_world(fun(#{namespace := Ns, node := Node, key := Key}) ->
            true = quod_reg:subscribe({physics, Ns}),
            try
                commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
                reconcile(Ns),
                ?assertEqual(#{}, worlds(Ns)),
                ?assertMatch({_, []}, quod_agent_hosting_tests:domain_agents(Ns)),
                commit(Ns, {',', {retract, {physics_space, room, disabled, actor}},
                                  {assertz, {physics_space, room, enabled, actor}}}),
                {Pid, World} = installed(Ns),
                #{World := #{spec := Spec}} = worlds(Ns),
                Fence = quod_physics:fence(Spec),
                {ok, Frame, Counters} = quod_physics:snapshot(Pid, #{fence => Fence, structure => 1, tick => -1}),
                ?assertEqual(2, length(maps:get(poses, Frame))),
                ?assertEqual(1, maps:get(installs, Counters)),
                reconcile(Ns),
                #{World := #{pid := Pid}} = worlds(Ns),
                #{installs := 1} = gen_server:call(Pid, status),
                commit(Ns, {',', {retract, {physics_body, room, 2, 1, dynamic,
                                             {vector,0,3000,0}, {box,500,500,500}, 1}},
                  {',', {assertz, {physics_body, room, 2, 2, dynamic,
                                             {vector,0,5000,0}, {box,500,500,500}, 1}},
                    {',', {retract, {physics_structure, room, 1}},
                          {assertz, {physics_structure, room, 2}}}}}),
                {Pid, World} = installed(Ns),
                {ok, #{structure := 2}, #{installs := 2}} = quod_physics:snapshot(Pid, #{fence => Fence, structure => 2, tick => -1}),
                ?assertEqual({error, unavailable}, quod_physics:snapshot(Pid, Frame)),
                Monitor = monitor(process, Pid),
                commit(Ns, {',', {retract, {physics_space, room, enabled, actor}},
                                  {assertz, {physics_space, room, disabled, actor}}}),
                receive {'DOWN', Monitor, process, Pid, _} -> ok
                after 10000 -> error(world_not_retired) end,
                reconcile(Ns),
                ?assertEqual(#{}, worlds(Ns))
            after quod_reg:unsubscribe({physics, Ns}) end
        end)
    end}.

current_view_credit_and_revision_test_() ->
    {timeout, 60, fun() -> with_world(fun(F = #{namespace := Ns}) ->
        {Pid, World} = enable(F),
        #{World := #{spec := Spec}} = worlds(Ns),
        Expected = #{fence => quod_physics:fence(Spec), structure => 1,
                     incarnation => maps:get(run_token, Spec)},
        {ok, Ref, First} = quod_physics:watch(Pid, Expected),
        ?assertEqual({error, view_busy}, quod_physics:watch(Pid, Expected)),
        %% Processing the owner's sleeping notice proves many actual steps
        %% completed while the initial frame held the only delivery credit.
        receive {physics_status, _, Pid, World, _, sleeping} -> ok
        after 15000 -> error(world_never_slept) end,
        _ = gen_server:call(Pid, status),
        receive {physics_frame, Pid, Ref, _} -> error(uncredited_frame)
        after 0 -> ok end,
        quod_physics:ack(Pid, Ref, maps:get(tick, First)),
        Latest = receive {physics_frame, Pid, Ref, Frame} -> Frame
                 after 5000 -> error(no_latest_frame) end,
        ?assert(maps:get(tick, Latest) > maps:get(tick, First)),
        assert_no_physics_io(fun() ->
            quod_physics:ack(Pid, Ref, maps:get(tick, Latest)),
            _ = gen_server:call(Pid, status),
            receive {physics_frame, Pid, Ref, _} -> error(unchanged_frame)
            after 0 -> ok end
        end),
        commit(Ns, {',', {retract, {physics_structure, room, 1}},
                        {assertz, {physics_structure, room, 2}}}),
        receive {physics_refresh, Pid, Ref} -> ok
        after 5000 -> error(no_revision_invalidation) end,
        ?assertEqual({error, unavailable}, quod_physics:watch(Pid, Expected)),
        {ok, Fresh, _} = quod_physics:watch(Pid, Expected#{structure => 2}),
        quod_physics:unwatch(Pid, Fresh)
    end) end}.

signed_client_view_lifecycle_test_() ->
    {timeout, 90, fun() -> with_door(fun(F = #{namespace := Ns, identity := Identity}) ->
        {Pid, World} = enable(F),
        Pub = maps:get(pubkey, Identity),
        commit(Ns, {assertz, {agent_key, viewer, Pub, active}}),
        Parent = self(),
        Socket = spawn_link(fun() -> simulation_socket(Parent, #{peer => {127,0,0,1}}) end),
        try
            Session = simulation_session(Identity),
            Open = fun() -> Socket ! {client, simulation_open(F, Session)} end,
            Open(),
            First = simulation_reply(Socket, <<"projection">>),
            FirstFrame = maps:get(<<"frame">>, First),
            ?assertEqual(1, length(maps:get(<<"poses">>, FirstFrame))),
            ?assertEqual(<<"10">>, maps:get(<<"body">>, hd(maps:get(<<"poses">>, FirstFrame)))),
            %% Appearance is a durable view change, never a physical reset.
            Before = gen_server:call(Pid, status),
            commit(Ns, {',', {retract, {view_colour, <<"#FFFFFF">>}},
                            {assertz, {view_colour, <<"#123456">>}}}),
            _ = simulation_reply(Socket, <<"refresh">>),
            Open(),
            Fresh = simulation_reply(Socket, <<"projection">>),
            ?assertNotEqual(maps:get(<<"view">>, First), maps:get(<<"view">>, Fresh)),
            ?assertEqual(maps:get(incarnation, Before), maps:get(incarnation, gen_server:call(Pid, status))),
            ?assertEqual(maps:get(installs, Before), maps:get(installs, gen_server:call(Pid, status))),
            %% Timer delivery is synchronized with the actual attached state;
            %% old timer references cannot invalidate a replacement projection.
            #{timer := AttachedTimer} = simulation_state(Socket),
            Socket ! {timeout, AttachedTimer, expired},
            _ = simulation_reply(Socket, <<"refresh">>),
            Open(), _ = simulation_reply(Socket, <<"projection">>),
            Socket ! {timeout, AttachedTimer, expired},
            ?assert(maps:is_key(pid, simulation_state(Socket))),
            %% Hold installation at its real lifecycle owner while the signed
            %% read observes a newer committed structure. No sleeps or polling.
            Runtime = quod_reg:where({quod_runtime, Ns}),
            ok = sys:suspend(Runtime),
            try
                commit(Ns, {',', {retract, {physics_structure,room,2}},
                                {assertz, {physics_structure,room,3}}}),
                _ = simulation_reply(Socket, <<"refresh">>),
                Open(),
                ?assertEqual(<<"waiting_for_installation">>,
                    maps:get(<<"reason">>, simulation_reply(Socket, <<"unavailable">>))),
                #{timer := WaitingTimer} = simulation_state(Socket),
                Socket ! {timeout, WaitingTimer, waiting_expired},
                ?assertEqual(<<"expired">>,
                    maps:get(<<"reason">>, simulation_reply(Socket, <<"unavailable">>))),
                ?assertEqual(#{peer => {127,0,0,1}}, simulation_state(Socket))
            after sys:resume(Runtime) end,
            {Pid, World} = installed(Ns),
            Open(), _ = simulation_reply(Socket, <<"projection">>),
            %% The existing signed close moves the real hinge. Its durable
            %% intent invalidates the view before accepting more current poses.
            true = quod_reg:subscribe({runtime, Ns}),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                door_action(Ns, {physics_close_door,room,10,0,<<81:256>>})),
            _ = simulation_reply(Socket, <<"refresh">>),
            await_door(Ns, {close,1,<<81:256>>}, closed),
            reconcile(Ns),
            Open(),
            Closed = simulation_reply(Socket, <<"projection">>),
            ?assertNotEqual(maps:get(<<"poses">>, FirstFrame),
                            maps:get(<<"poses">>, maps:get(<<"frame">>, Closed))),
            %% Owner death invalidates this subscription; the new run cannot
            %% reuse its token or accept its outstanding acknowledgement.
            exit(Pid, kill),
            _ = simulation_reply(Socket, <<"refresh">>),
            {Next, World} = installed(Ns),
            ?assertNotEqual(Pid, Next),
            Open(),
            Restored = simulation_reply(Socket, <<"projection">>),
            ?assertNotEqual(maps:get(<<"incarnation">>, FirstFrame),
                            maps:get(<<"incarnation">>, maps:get(<<"frame">>, Restored))),
            %% Revocation must go back through ordinary signed proof policy.
            commit(Ns, {retract, {can_view_physics, room, {'_'}}}),
            _ = simulation_reply(Socket, <<"refresh">>),
            Open(),
            ?assertEqual(<<"view_not_authorized_or_ready">>,
                         maps:get(<<"reason">>, simulation_reply(Socket, <<"unavailable">>))),
            commit(Ns, {assertz, {can_view_physics,room,{'_'}}}),
            commit(Ns, {',', {retract, {physics_allowances,room,{limits,64,64,256,1000000},16667,-9810,10000}},
                            {assertz, {physics_allowances,room,{limits,1,1,256,1000000},16667,-9810,10000}}}),
            receive {physics_status,_,_,World,_,{failed,body_allowance}} -> ok
            after 15000 -> error(no_failed_installation) end,
            Open(),
            ?assertEqual(<<"simulation_failed">>,
                maps:get(<<"reason">>, simulation_reply(Socket, <<"unavailable">>)))
        after Socket ! stop end
    end, false, fun(Rules) ->
        Ns = <<"host-test-agent">>,
        Marks = [{mark, <<"door">>, <<"box">>,
                  [{f,<<"width">>,2000},{f,<<"height">>,2000},{f,<<"depth">>,200}],
                  {body_pose,10,{'R'}}, {surface,{'Colour'},0,900,0,[]}, unlabelled,
                  {depicts,Ns,{'Anchor'},door}}],
        Rules ++ [{can_invoke,{physics_client_view,{'_'}},
                    {agent_instance_ref,Ns,{'_'},viewer},{'_'},Ns},
                  {can_view_physics,room,{'_'}}, {view_colour,<<"#FFFFFF">>},
                  {':-', {physics_view,room,Marks},
                    {',', {current_ontology_identity,Ns,{'Anchor'}},
                      {',', {view_colour,{'Colour'}},
                            {physics_body,room,10,{'R'},{'_'},{'_'},{'_'},{'_'}}}}}]
    end) end}.

simulation_session(Identity = #{pubkey := Pub}) ->
    Nonce = crypto:strong_rand_bytes(32),
    {ok, C} = quod_client_auth:issue_challenge(Pub, Nonce, {127,0,0,1}),
    Id = maps:get(challenge_id, C),
    {ok, Bytes} = quod_client_auth:challenge_bytes(<<42:256>>, Pub, Id, Pub, Nonce,
        maps:get(server_nonce, C), maps:get(expires_ms, C)),
    {ok, #{session_id := Session}} = quod_client_auth:complete_challenge(Id, quod_identity:sign(Bytes, Identity)),
    Session.

simulation_open(#{namespace := Ns, reference := {agent_instance_ref,_,Anchor,_}, identity := Identity}, Session) ->
    Request = #{network_identity => <<42:256>>, agent_namespace => Ns,
        agent_genesis_anchor => Anchor, agent_instance_text => <<"viewer.">>,
        signing_public_key => maps:get(pubkey, Identity), operation_id => crypto:strong_rand_bytes(32),
        not_after_ms => quod_time:now_ms()+30000, mode => read, parser_version => 3,
        goal_text => <<"physics_client_view(View).">>},
    {ok, Bytes} = quod_client_goal:encode(Request),
    Enc = fun(B) -> base64:encode(B, #{mode => urlsafe, padding => false}) end,
    iolist_to_binary(json:encode(#{type => open, session_id => Enc(Session), request => Enc(Bytes),
        signature => Enc(quod_identity:sign(Bytes, Identity))})).

simulation_reply(Socket, Type) ->
    receive
        {simulation, Socket, #{<<"type">> := Type} = Message} -> Message;
        {simulation, Socket, Message} -> error({unexpected_simulation_reply, Type, Message})
    after 10000 -> error({missing_simulation_reply, Type}) end.

simulation_socket(Parent, S) ->
    receive
        stop -> quod_client_simulation:terminate(normal, unused, S);
        {inspect, Ref} -> Parent ! {simulation_state, Ref, S}, simulation_socket(Parent, S);
        Message ->
            Result = case Message of
                {client, Bytes} -> quod_client_simulation:websocket_handle({text, Bytes}, S);
                _ -> quod_client_simulation:websocket_info(Message, S)
            end,
            Next = case Result of
                {ok, State} -> State;
                {reply, {text, Json}, State} -> Parent ! {simulation, self(), json:decode(Json)}, State;
                Other -> error({invalid_socket_result, Other})
            end,
            simulation_socket(Parent, Next)
    end.

simulation_state(Socket) ->
    Ref = make_ref(), Socket ! {inspect, Ref},
    receive {simulation_state, Ref, State} -> State
    after 5000 -> error(socket_state_unavailable) end.

with_world(Fun) -> with_world(Fun, fun(Rules) -> Rules end).
with_world(Fun, Transform) ->
    Ns = <<"host-test-agent">>,
    Actor = {agent_instance_ref, Ns, {'_'}, actor},
    Rules = quod_prolog:read_terms("priv/ontologies/quod_physics.pl") ++
        [{can_invoke, {physics_store_request, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}}, Actor, {'_'}, Ns},
         {can_invoke, {physics_activate, {'_'}, {'_'}, {'_'}}, Actor, {'_'}, Ns},
         {can_invoke, {physics_cancel_activation, {'_'}, {'_'}, {'_'}}, Actor, {'_'}, Ns},
         {physics_space, room, disabled, actor},
         {physics_run, room, 0, none}, {physics_structure, room, 1},
         {physics_allowances, room, {limits, 64, 64, 256, 1000000}, 16667, -9810, 10000},
         {physics_body, room, 1, 1, fixed, {vector,0,-500,0}, {box,10000,500,10000}, 1},
         {physics_body, room, 2, 1, dynamic, {vector,0,3000,0}, {box,500,500,500}, 1}],
    try quod_agent_hosting_tests:with_host(Fun, Transform(Rules))
    after catch quod_reg:unsubscribe({physics, Ns}) end.

worlds(Ns) -> gen_server:call(quod_reg:via({quod_runtime, Ns}), physics_worlds).
reconcile(Ns) ->
    ?assertEqual(ok, quod_runtime:reconcile_resource(Ns, quod_prolog:applied(Ns), physics_worlds,
                                                   all, quod_time:mono_ms() + 10000)).
installed(Ns) -> installed(Ns, quod_simplex:genesis_hash(Ns)).
installed(Ns, Anchor) ->
    receive
        {physics_status, _, Pid, World = {world_ref,Ns,Anchor,_}, _, installed} ->
            case worlds(Ns) of
                #{World := #{pid := Pid, stopping := false}} -> {Pid, World};
                _ -> installed(Ns, Anchor)
            end;
        {physics_status, _, _, {world_ref,Ns,Anchor,_}, _, Status}
          when Status =:= activating; Status =:= awaiting_actor; Status =:= capacity;
               Status =:= sleeping -> installed(Ns, Anchor);
        {physics_status, _, _, {world_ref,Ns,Anchor,_}, _, {unavailable,_}} -> installed(Ns, Anchor);
        {physics_status, _, _, {world_ref,Ns,Other,_}, _, _} when Other =/= Anchor -> installed(Ns, Anchor);
        {physics_status, _, Pid, World, _, Error} ->
            case worlds(Ns) of
                #{World := #{pid := Pid, stopping := false}} -> error({physics_installation, Error, request_result()});
                _ -> installed(Ns, Anchor)
            end
    after 15000 -> error({physics_not_installed, worlds(Ns), quod_runtime:stats(Ns)}) end.
commit(Ns, Goal) -> ?assertMatch({ok, _, _}, quod_ct:rp(Ns, Goal)).

request_result() ->
    receive {agent_request_finished, _, _, _, _, Result} -> brief(Result)
    after 1000 -> missing_result end.
brief({ok, _, {normalized, {failed, Blob}}}) -> redact(quod_wire_term:decode_failure_reasons(Blob));
brief({ok, _, Outcome}) -> Outcome;
brief({error, {custody_unresolved, Result}}) -> {custody_unresolved, brief(Result)};
brief(Result) -> Result.

redact(B) when is_binary(B) -> {bytes, byte_size(B)};
redact(T) when is_tuple(T) -> list_to_tuple([redact(X) || X <- tuple_to_list(T)]);
redact(L) when is_list(L) -> [redact(X) || X <- L];
redact(X) -> X.

sleeping_world_and_unchanged_cost_test_() ->
    {timeout, 60, fun() -> with_world(fun(F = #{namespace := Ns}) ->
        {Pid, World} = enable(F),
        receive {physics_status, _, Pid, World, _, sleeping} -> ok
        after 15000 -> error(world_never_slept) end,
        Before = gen_server:call(Pid, status),
        #{World := #{spec := Spec}} = worlds(Ns),
        Fence = quod_physics:fence(Spec),
        assert_no_physics_io(fun() ->
            [reconcile(Ns) || _ <- lists:seq(1, 5)],
            {ok, Frame, _} = quod_physics:snapshot(Pid, #{fence => Fence, structure => 1, tick => -1}),
            {ok, Frame, _} = quod_physics:snapshot(Pid, #{fence => Fence, structure => 1, tick => -1}),
            ?assertMatch({ok, unchanged, _}, quod_physics:snapshot(Pid, Frame)),
            After = gen_server:call(Pid, status),
            ?assertEqual(maps:with([installs,steps,tick,incarnation], Before),
                         maps:with([installs,steps,tick,incarnation], After))
        end)
    end) end}.

assert_no_physics_io(Fun) ->
    Collector = spawn_link(fun() -> trace_calls([]) end),
    Trace = trace:session_create(physics_unchanged, Collector, []),
    Watched = [{quod_physics_native,new_world,3}, {quod_ledger_store,fold,5},
               {quod_ledger_store,fold_groups,3}, {quod_ledger_store,open,3},
               {quod_file,write_atomic,3}, {dets,insert,2}, {dets,sync,1}, {file,write,2}, {file,sync,1}, {file,datasync,1}],
    [trace:function(Trace, MFA, true, [local]) || MFA <- Watched],
    trace:process(Trace, all, true, [call]),
    try
        Fun(),
        Delivered = trace:delivered(Trace, all),
        receive {trace_delivered, all, Delivered} -> ok after 5000 -> error(trace_timeout) end,
        Collected = make_ref(), Collector ! {finish,self(),Collected},
        Calls = receive {trace_calls,Collected,AllCalls} -> AllCalls
                after 5000 -> error(trace_collection_timeout) end,
        ?assertEqual([], Calls)
    after
        trace:session_destroy(Trace), unlink(Collector), exit(Collector,kill)
    end.

same_host_restart_and_runtime_retirement_test_() ->
    {timeout, 90, fun() -> with_world(fun(F = #{namespace := Ns}) ->
        {First, World} = enable(F),
        #{World := #{spec := Spec1}} = worlds(Ns),
        Fence1 = quod_physics:fence(Spec1),
        {ok, Frame1, _} = quod_physics:snapshot(First, #{fence => Fence1, structure => 1, tick => -1}),
        M = monitor(process, First), exit(First, kill),
        receive {'DOWN', M, process, First, killed} -> ok after 5000 -> error(still_alive) end,
        {Second, World} = installed(Ns),
        ?assertNotEqual(First, Second),
        #{World := #{spec := Spec2}} = worlds(Ns),
        ?assertEqual(maps:get(epoch, Spec1), maps:get(epoch, Spec2)),
        ?assertEqual(maps:get(generation, Spec1) + 1, maps:get(generation, Spec2)),
        ?assertEqual({error, unavailable}, quod_physics:snapshot(Second, Frame1)),
        {ok, Frame2, _} = quod_physics:snapshot(Second, #{fence => quod_physics:fence(Spec2), structure => 1, tick => -1}),
        ?assertNot(quod_physics:accepts(Frame1, Frame2)),
        Runtime = quod_reg:where({quod_runtime, Ns}),
        R = monitor(process, Runtime), M2 = monitor(process, Second),
        exit(Runtime, kill),
        receive {'DOWN', R, process, Runtime, killed} -> ok after 5000 -> error(runtime_alive) end,
        receive {'DOWN', M2, process, Second, _} -> ok after 5000 -> error(orphan_simulator) end,
        {Third, World} = installed(Ns),
        ?assertNotEqual(Second, Third),
        #{World := #{spec := Spec3}} = worlds(Ns),
        ?assertEqual(maps:get(generation, Spec2) + 1, maps:get(generation, Spec3))
    end) end}.

native_failure_does_not_retry_definition_test_() ->
    {timeout, 60, fun() -> with_world(fun(F = #{namespace := Ns, node := Node, key := Key}) ->
        commit(Ns, {',', {retract, {physics_allowances, room, {limits,64,64,256,1000000},16667,-9810,10000}},
                          {assertz, {physics_allowances, room, {limits,1,1,256,1000000},16667,-9810,10000}}}),
        true = quod_reg:subscribe({physics, Ns}),
        commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
        commit(Ns, {',', {retract, {physics_space,room,disabled,actor}},
                          {assertz, {physics_space,room,enabled,actor}}}),
        Pid = receive {physics_status, _, P, _, _, {failed, body_allowance}} -> P
              after 15000 -> error(native_failure_not_visible) end,
        Before = gen_server:call(Pid, status),
        [reconcile(Ns) || _ <- lists:seq(1, 5)],
        ?assertEqual(Before, gen_server:call(Pid, status)),
        ?assertEqual({error, unavailable}, quod_physics:snapshot(Pid, ignored)),
        ?assertEqual({error, simulation_failed}, quod_physics:watch(Pid, ignored)),
        commit(Ns, {',', {retract, {physics_allowances, room, {limits,1,1,256,1000000},16667,-9810,10000}},
                          {assertz, {physics_allowances, room, {limits,64,64,256,1000000},16667,-9810,10000}}}),
        {Replacement, _} = installed(Ns),
        ?assertNotEqual(Pid, Replacement),
        _ = F,
        quod_reg:unsubscribe({physics, Ns})
    end) end}.

enable(#{namespace := Ns, node := Node, key := Key}) ->
    true = quod_reg:subscribe({physics, Ns}),
    commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
    commit(Ns, {',', {retract, {physics_space,room,disabled,actor}},
                      {assertz, {physics_space,room,enabled,actor}}}),
    installed(Ns).
trace_calls(Acc) ->
    receive
        {trace, _, call, Call} -> trace_calls([Call | Acc]);
        {finish,From,Ref} -> From ! {trace_calls,Ref,lists:reverse(Acc)}
    end.

uncertain_activation_keeps_original_custody_test_() ->
    {timeout, 90, fun() ->
        {ok, _} = application:ensure_all_started(gproc),
        true = quod_reg:reg({host_test, barrier}),
        try with_world(fun(#{namespace := Ns, node := Node, key := Key}) ->
            true = quod_reg:subscribe({physics, Ns}),
            commit(Ns, {goal, {agent_hosted, actor, Node, 1, Key}}),
            commit(Ns, {',', {retract, {physics_space,room,disabled,actor}},
                              {assertz, {physics_space,room,enabled,actor}}}),
            {Proof, Operation} = receive {fipa_completion_prepared, P, Op} -> {P, Op}
                                 after 10000 -> error(request_not_submitted) end,
            reconcile(Ns),
            [{World, #{pid := First, spec := Spec1}}] = maps:to_list(worlds(Ns)),
            {request, FirstToken, 0, Bytes, Signature} = maps:get(custody, Spec1),
            {ok, #{operation_ref := Operation}} = quod_client_goal:verify(Bytes, Signature),
            M = monitor(process, First), exit(First, kill),
            receive {'DOWN', M, process, First, killed} -> ok after 5000 -> error(still_alive) end,
            Second = receive {physics_status, _, P2, World, _, activating} when P2 =/= First -> P2
                     after 10000 -> error(replacement_not_started) end,
            ?assertMatch(#{installs := 0, steps := 0}, gen_server:call(Second, status)),
            ?assertMatch({ok, _, {operation_pending, Operation}},
                         quod_client_goal_ingress:resolve_operation(Bytes, Signature)),
            Proof ! release,
            NextProof = receive {fipa_completion_prepared, P3, Op2} when Op2 =/= Operation -> P3
                        after 15000 -> error(fresh_request_not_submitted) end,
            ?assertMatch(#{installs := 0, steps := 0}, gen_server:call(Second, status)),
            #{World := #{spec := #{generation := 1, run_token := FirstToken}}} = worlds(Ns),
            NextProof ! release,
            {Second, World} = installed(Ns),
            #{World := #{spec := #{generation := 2, run_token := NextToken}}} = worlds(Ns),
            ?assertNotEqual(FirstToken, NextToken),
            ?assertMatch({ok, _, {operation_outcome, _, #{status := committed}}},
                         quod_client_goal_ingress:resolve_operation(Bytes, Signature))
        end, fun(Rules) ->
            [case R of
                 {':-', Head = {physics_activate, _, _, _}, Body} ->
                     {':-', Head, {',', test_fipa_completion, Body}};
                 _ -> R
             end || R <- Rules]
        end)
        after gproc:unreg(quod_reg:name({host_test, barrier})) end
    end}.

host_assignment_replacement_test_() ->
    {timeout, 90, fun() -> with_world(fun(F = #{namespace := Ns, node := Node, reference := Ref}) ->
        {First, World} = enable(F),
        {ok, Blob} = quod_wire_term:encode_canonical(Ref),
        {ok, Key2} = quod_agent_vault:generate(Blob),
        commit(Ns, {goal, {agent_assignment,actor,Node,1,Node,2,Key2}}),
        {Second, World} = installed(Ns),
        ?assertNotEqual(First, Second),
        #{World := #{spec := #{epoch := 2, generation := 2}}} = worlds(Ns),
        Remote = setelement(2, Node, <<"remote-node">>),
        M = monitor(process, Second),
        commit(Ns, {goal, {agent_assignment,actor,Node,2,Remote,3,<<75:256>>}}),
        receive {'DOWN', M, process, Second, _} -> ok after 10000 -> error(old_host_running) end,
        reconcile(Ns), ?assertEqual(#{}, worlds(Ns)),
        {ok, Key4} = quod_agent_vault:generate(Blob),
        commit(Ns, {goal, {agent_assignment,actor,Remote,3,Node,4,Key4}}),
        {Third, World} = installed(Ns),
        ?assertNotEqual(Second, Third),
        #{World := #{spec := #{epoch := 4, generation := 3}}} = worlds(Ns)
    end) end}.

replay_retires_world_without_replaying_reactions_test_() ->
    {timeout, 90, fun() -> with_world(fun(F = #{namespace := Ns}) ->
        {First, World} = enable(F),
        commit(Ns, {trigger_event, {do_work, replay_once}}),
        {ok, GoalBlob} = quod_durable_term:encode_goal({record_ping,replay_once}),
        receive {agent_request_finished, _, _, _, _,
                 {ok, #{goal_blob := GoalBlob}, {normalized, {committed, _, _}}}} -> ok
        after 10000 -> error(live_reaction_not_completed) end,
        Before = worlds(Ns), #{World := #{spec := #{generation := G}}} = Before,
        M = monitor(process, First), Prolog = quod_reg:where({quod_prolog,Ns}),
        exit(Prolog, kill),
        receive {'DOWN', M, process, First, _} -> ok after 10000 -> error(replay_kept_old_world) end,
        {Next, World} = installed(Ns),
        ?assertNotEqual(First, Next),
        #{World := #{spec := #{generation := NextG}}} = worlds(Ns),
        ?assertEqual(G+1, NextG),
        ?assertMatch({ok, [#{'Rows' := [replay_once]}], _}, quod_prolog:prove_ro(Ns,
            {findall, {'V'}, {ping, {'V'}}, {'Rows'}}))
    end) end}.

runtime_collapse_retires_native_world_test_() ->
    {timeout, 90, fun() ->
        {ok, _} = application:ensure_all_started(gproc),
        true = quod_reg:reg({host_test, local_proof}),
        Saved = application:get_env(quod, runtime_max_queued_events),
        try with_world(fun(F = #{namespace := Ns}) ->
            {First, World} = enable(F),
            #{World := #{spec := #{generation := G}}} = worlds(Ns),
            Runtime = quod_reg:where({quod_runtime,Ns}),
            commit(Ns, {assertz, physics_gate}),
            Reader = receive {local_proof_waiting, P} -> P after 10000 -> error({selector_not_waiting,quod_runtime:stats(Ns)}) end,
            M = monitor(process, First), R = monitor(process, Reader),
            Parent = self(), Tag = make_ref(),
            Observe = fun(State, {in, {'$gen_call', _, {reconcile_resource, _, physics_worlds, future, _}}}, _) ->
                              Parent ! {queued,Tag}, State;
                         (State, {in, {applied_live, _, _}}, _) -> Parent ! {committed,Tag}, State;
                         (State, _, _) -> State end,
            ok = sys:install(Runtime,{Observe,none}),
            try
                %% Retire the gate in committed truth while the old snapshot's
                %% reader is paused. Recovery must select an unblocked snapshot.
                commit(Ns,{retract,physics_gate}),
                receive {committed,Tag} -> ok after 5000 -> error(commit_not_delivered) end,
                BaseQueue = maps:get(queue_len,quod_runtime:stats(Ns)),
                application:set_env(quod,runtime_max_queued_events,BaseQueue+2),
                [begin
                    spawn(fun() -> Parent ! {future_result, Tag,
                        quod_runtime:reconcile_resource(Ns,quod_prolog:applied(Ns)+100,
                            physics_worlds,future,quod_time:mono_ms()+10000)} end),
                    receive {queued,Tag} -> ok after 5000 -> error(queue_not_received) end,
                    ?assertEqual(BaseQueue+Count,maps:get(queue_len,quod_runtime:stats(Ns)))
                 end || Count <- [1,2]],
                ?assertEqual({error,overloaded},quod_runtime:reconcile_resource(Ns,0,
                    physics_worlds,all,quod_time:mono_ms()+10000))
            after
                application:set_env(quod,runtime_max_queued_events,1024),
                sys:remove(Runtime,Observe)
            end,
            receive {'DOWN',M,process,First,_} -> ok after 5000 -> error(collapse_kept_world) end,
            receive {'DOWN',R,process,Reader,_} -> ok after 5000 -> error(collapse_kept_reader) end,
            [receive {future_result,Tag,{error,runtime_recovering}} -> ok
             after 5000 -> error(caller_not_released) end || _ <- [1,2]],
            {Next,World} = installed(Ns), ?assertNotEqual(First,Next),
            #{World := #{spec := #{generation := NextG}}} = worlds(Ns),
            ?assertEqual(G+1,NextG),
            ?assert(maps:get(collapses,quod_runtime:stats(Ns)) >= 1)
        end, fun(Rules) ->
            [case Rule of
                {':-',Head = {physics_projection,_,_},Body} ->
                    {':-',Head,{',', {';', {'->',physics_gate,test_physics_snapshot},true}, Body}};
                _ -> Rule
             end || Rule <- Rules]
        end)
        after
            case Saved of undefined -> application:unset_env(quod,runtime_max_queued_events);
                          {ok,V} -> application:set_env(quod,runtime_max_queued_events,V) end,
            gproc:unreg(quod_reg:name({host_test,local_proof}))
        end
    end}.

native_boundary_retires_on_unwind_test() ->
    {ok, R} = quod_physics_native:new_world({2,2,1,1000.0},1/60,-9.81),
    Body = {1,1,true,{0.0,3.0,0.0},{0.5,0.5,0.5},1.0},
    {ok,1} = quod_physics_native:install(R,[Body]),
    Parent = self(),
    spawn(fun() -> Parent ! {foreign_native_call,quod_physics_native:step(R)} end),
    receive {foreign_native_call, Result} -> ?assertEqual({error,wrong_owner},Result)
    after 5000 -> error(native_call_not_returned) end,
    ?assertMatch({ok,{true,[_],[]}},quod_physics_native:sample(R)),
    %% Rustler's list iterator panics on an improper tail. Decoding is inside
    %% this adapter's unwind boundary, so the partially touched resource dies.
    ?assertEqual({error,native_failure},quod_physics_native:install(R,[Body|malformed])),
    ?assertEqual({error,retired},quod_physics_native:sample(R)),
    ?assertEqual(ok,quod_physics_native:retire(R)),
    ?assertEqual({error,invalid_step},quod_physics_native:new_world({2,2,1,1000.0},1.0e-320,-9.81)).

snapshot_replacement_coalesces_while_native_owner_is_busy_test_() ->
    {timeout, 60, fun() -> with_world(fun(F = #{namespace := Ns}) ->
        {Pid, World} = enable(F),
        receive {physics_status,_,Pid,World,_,sleeping} -> ok
        after 15000 -> error(world_never_slept) end,
        ok = sys:suspend(Pid),
        try
            [begin
                OldY = case Rev of 2 -> 3000; _ -> (Rev-1)*1000 end,
                commit(Ns, {',', {retract,{physics_body,room,2,Rev-1,dynamic,{vector,0,OldY,0},{box,500,500,500},1}},
                   {',', {assertz,{physics_body,room,2,Rev,dynamic,{vector,0,Rev*1000,0},{box,500,500,500},1}},
                    {',', {retract,{physics_structure,room,Rev-1}}, {assertz,{physics_structure,room,Rev}}}}}),
                reconcile(Ns)
             end || Rev <- lists:seq(2,6)],
            {message_queue_len, Queued} = process_info(Pid,message_queue_len),
            ?assert(Queued =< 2)
        after sys:resume(Pid) end,
        await_structure(Ns,Pid,World,6),
        #{installs := Installs} = gen_server:call(Pid,status),
        ?assert(Installs =< 3)
    end) end}.

await_structure(Ns,Pid,World,Structure) ->
    #{World := #{spec := Spec}} = worlds(Ns),
    Expected = #{fence => quod_physics:fence(Spec),structure => Structure,tick => -1},
    case quod_physics:snapshot(Pid,Expected) of
        {ok,_,_} -> ok;
        _ -> receive {physics_status,_,Pid,World,_,installed} -> await_structure(Ns,Pid,World,Structure)
             after 10000 -> error(latest_structure_not_installed) end
    end.

activation_timeout_is_unresolved_not_rejection_test_() ->
    {timeout, 60, fun() ->
        {ok,_} = application:ensure_all_started(gproc),
        true = quod_reg:reg({host_test,barrier}),
        try with_world(fun(#{namespace := Ns,node := Node,key := Key}) ->
            true = quod_reg:subscribe({physics,Ns}),
            commit(Ns,{goal,{agent_hosted,actor,Node,1,Key}}),
            commit(Ns,{',',{retract,{physics_space,room,disabled,actor}},
                           {assertz,{physics_space,room,enabled,actor}}}),
            Operation = receive {fipa_completion_prepared,_,Op} -> Op
                        after 10000 -> error(activation_not_started) end,
            Pid = receive {physics_status,_,P,_,_,{unavailable,activation_unresolved}} -> P
                  after 10000 -> error(timeout_not_reported) end,
            [{World,#{spec := Spec}}] = maps:to_list(worlds(Ns)),
            {request,_,0,Bytes,Signature} = Custody = maps:get(custody,Spec),
            ?assertMatch({ok,#{operation_ref := Operation}},quod_client_goal:verify(Bytes,Signature)),
            [reconcile(Ns) || _ <- lists:seq(1,5)],
            ?assertMatch(#{phase := unresolved,installs := 0,steps := 0},gen_server:call(Pid,status)),
            #{World := #{spec := #{custody := Custody,generation := 0}}} = worlds(Ns),
            ?assertMatch({ok,_,{operation_pending,Operation}},quod_client_goal_ingress:resolve_operation(Bytes,Signature))
        end,fun(Rules) ->
            [case R of
                {':-',Head = {physics_activate,_,_,_},Body} -> {':-',Head,{',',test_fipa_completion,Body}};
                {physics_allowances,W,L,D,G,_} -> {physics_allowances,W,L,D,G,1000};
                _ -> R
             end || R <- Rules]
        end)
        after gproc:unreg(quod_reg:name({host_test,barrier})) end
    end}.

unobserved_custody_has_explicit_lifecycle_exit_test_() ->
    {timeout,60,fun() ->
        {ok,_} = application:ensure_all_started(gproc),
        true = quod_reg:reg({host_test,barrier}),
        try with_world(fun(#{namespace := Ns,node := Node,key := Key}) ->
            true = quod_reg:subscribe({physics,Ns}),
            commit(Ns,{goal,{agent_hosted,actor,Node,1,Key}}),
            commit(Ns,{',',{retract,{physics_space,room,disabled,actor}},
                           {assertz,{physics_space,room,enabled,actor}}}),
            Proof = receive {fipa_completion_prepared,P,_} -> P
                    after 5000 -> error(custody_store_not_paused) end,
            Old = receive {physics_status,_,P0,_,_,{unavailable,activation_custody_unresolved}} -> P0
                  after 5000 -> error(unobserved_custody_not_reported) end,
            [reconcile(Ns) || _ <- lists:seq(1,3)],
            [{World,#{pid := Old,spec := #{generation := 0,custody := none}}}] = maps:to_list(worlds(Ns)),
            M = monitor(process,Old),
            commit(Ns,{',',{retract,physics_store_gate},
                {',',{retract,{physics_space,room,enabled,actor}},
                     {assertz,{physics_space,room,disabled,actor}}}}),
            receive {'DOWN',M,process,Old,_} -> ok after 5000 -> error(old_owner_not_retired) end,
            Proof ! release,
            commit(Ns,{',',{retract,{physics_space,room,disabled,actor}},
                           {assertz,{physics_space,room,enabled,actor}}}),
            {New,World} = installed(Ns),
            ?assertNotEqual(Old,New),
            ?assertMatch(#{World := #{spec := #{generation := 1}}},worlds(Ns))
        end,fun(Rules) -> [physics_store_gate|[case Rule of
            {':-',Head = {physics_store_request,_,_,_,_,_,_},Body} ->
                {':-',Head,{',',{';',{'->',physics_store_gate,test_fipa_completion},true},Body}};
            {physics_allowances,W,L,D,G,_} -> {physics_allowances,W,L,D,G,1000};
            _ -> Rule
        end || Rule <- Rules]] end)
        after gproc:unreg(quod_reg:name({host_test,barrier})) end
    end}.

native_reports_the_exceeded_output_allowance_test() ->
    {ok,R} = quod_physics_native:new_world({2,0,2,1000.0},1/60,-9.81),
    {ok,1} = quod_physics_native:install(R,[{1,1,true,{0.0,2.0,0.0},{0.5,0.5,0.5},1.0}]),
    ?assertEqual({error,pose_allowance},quod_physics_native:sample(R)),
    ?assertEqual({error,retired},quod_physics_native:step(R)).

native_density_is_not_a_coordinate_budget_test() ->
    {ok,R} = quod_physics_native:new_world({1,1,1,1000.0},1/60,-9.81),
    {ok,1} = quod_physics_native:install(R,[{1,1,true,{0.0,2.0,0.0},{0.5,0.5,0.5},7850.0}]),
    ?assertMatch({ok,{true,[_],[]}},quod_physics_native:step(R)),
    ok = quod_physics_native:retire(R).

malformed_activation_is_a_selection_failure_test_() ->
    {timeout,60,fun() -> with_world(fun(#{namespace := Ns,node := Node,key := Key}) ->
        commit(Ns,{goal,{agent_hosted,actor,Node,1,Key}}),
        commit(Ns,{',',{retract,{physics_space,room,disabled,actor}},
                       {',',{assertz,{physics_request,room,malformed}},
                            {assertz,{physics_space,room,enabled,actor}}}}),
        [begin
            ?assertEqual({error,invalid_physics_projection},
                quod_runtime:reconcile_resource(Ns,quod_prolog:applied(Ns),physics_worlds,
                                                all,quod_time:mono_ms()+10000)),
            ?assertEqual(#{},worlds(Ns))
         end || _ <- lists:seq(1,3)],
        ?assertMatch({ok,[#{'G' := 0}],_},quod_prolog:prove_ro(Ns,{physics_run,room,{'G'},none}))
    end) end}.

physics_admission_preserves_event_release_test_() ->
    {timeout,60,fun() ->
        {ok,_} = application:ensure_all_started(gproc),
        true = quod_reg:reg({host_test,barrier}),
        try with_world(fun(F = #{namespace := Ns}) ->
            {Pid,World} = enable(F),
            #{World := #{spec := #{custody := {request,_,_,Bytes,Signature}}}} = worlds(Ns),
            commit(Ns,{',',{trigger_event,{do_work,release_regression}},
                           {trigger_event,pause_batch}}),
            Runner = receive {host_projection_waiting,P} -> P
                     after 5000 -> error(event_batch_not_paused) end,
            Runtime = quod_reg:where({quod_runtime,Ns}),
            %% Exercise the admitted owner's production message while a real
            %% earlier reaction is queued above the installed event frontier.
            Runtime ! {physics_work,Pid,World,make_ref(),resolve,{Bytes,Signature},
                       {quod_time:now_ms()+5000,quod_time:mono_ms()+5000}},
            _ = quod_runtime:stats(Ns),
            Runner ! release,
            {ok,GoalBlob} = quod_durable_term:encode_goal({record_ping,release_regression}),
            receive {agent_request_finished,_,_,_,_,
                     {ok,#{goal_blob := GoalBlob},{normalized,{committed,_,_}}}} -> ok
            after 10000 -> error(reaction_lost_its_release) end,
            ?assertMatch({ok,[#{}],_},quod_prolog:prove_ro(Ns,{ping,release_regression}))
        end)
        after gproc:unreg(quod_reg:name({host_test,barrier})) end
    end}.


explicit_activation_cancellation_test_() ->
    [{atom_to_list(Scenario), {timeout,90,fun() -> cancelled_activation(Scenario) end}}
     || Scenario <- [never_submitted, prepared_before_cancellation, activation_wins, disabled]].

cancelled_activation(Scenario) ->
    {ok,_} = application:ensure_all_started(gproc),
    true = quod_reg:reg({host_test,barrier}),
    OldToken = <<77:256>>,
    %% Install the barrier after the old proof has captured its custody/run
    %% reads and staged writes, but before its transaction can submit them.
    BarrierTransform = fun(Rules) -> [case Rule of
        {':-',Head = {physics_activate,_,_,Token},{transaction,Body}}
          when Scenario =:= prepared_before_cancellation ->
            {':-',Head,{transaction,{',',Body,{';',{'->',{'=',Token,OldToken},test_fipa_completion},true}}}};
        _ -> Rule
    end || Rule <- Rules] end,
    try with_world(fun(F = #{namespace := Ns,node := Node,key := Key,reference := Actor}) ->
        true = quod_reg:subscribe({physics,Ns}),
        commit(Ns,{goal,{agent_hosted,actor,Node,1,Key}}),
        Runtime = quod_reg:where({quod_runtime,Ns}),
        ok = sys:suspend(Runtime),
        {Bytes,Signature} = try
            commit(Ns,{',',{retract,{physics_space,room,disabled,actor}},
                           {assertz,{physics_space,room,enabled,actor}}}),
            {B,Sig} = sign_fixture(F,{physics_activate,room,0,OldToken}),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},submit_fixture(F,
                {physics_store_request,room,0,none,OldToken,B,Sig})),
            {B,Sig}
        after sys:resume(Runtime) end,
        Request = {request,OldToken,0,Bytes,Signature},
        Anchor = element(3, Actor),
        Waiting = receive {physics_status,Runtime,P,{world_ref,Ns,Anchor,room},_,
                           {unavailable,activation_unresolved}} -> P
                  after 10000 -> error(stored_request_not_recovered) end,
        ?assertMatch({ok,[#{}],_},quod_prolog:prove_ro(Ns,
                      {physics_activation_status,room,Request,pending})),
        ?assertMatch({ok,_,{normalized,{failed,_}}},submit_fixture(F,
                      {physics_cancel_activation,room,0,Request})),
        commit(Ns,{assertz,{can_cancel_physics_activation,room,Actor}}),
        [?assertMatch({ok,_,{normalized,{failed,_}}},submit_fixture(F,Goal)) || Goal <-
            [{physics_cancel_activation,room,{'G'},Request},
             {physics_cancel_activation,room,0,{'Request'}}]],
        ?assertMatch({ok,_,{normalized,{failed,_}}},submit_fixture(F,
            {physics_cancel_activation,room,0,{request,<<78:256>>,0,Bytes,Signature}})),
        Parent = self(), Tag = make_ref(),
        Proof = case Scenario of
            prepared_before_cancellation ->
                spawn(fun() -> Parent ! {old_activation,Tag,quod_client_goal_ingress:submit(Bytes,Signature)} end),
                receive {fipa_completion_prepared,P0,_} -> P0
                after 10000 -> error(old_activation_not_prepared) end;
            activation_wins ->
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                             quod_client_goal_ingress:submit(Bytes,Signature)), none;
            never_submitted -> none;
            disabled ->
                commit(Ns,{',',{retract,{physics_space,room,enabled,actor}},
                               {assertz,{physics_space,room,disabled,actor}}}), none
        end,
        ok = sys:suspend(Runtime),
        Cancelled = try
            Result = submit_fixture(F,{physics_cancel_activation,room,0,Request}),
            case Scenario of
                never_submitted ->
                    %% With the owner paused, generation/prior still match:
                    %% only the durable cancellation fence forbids resurrection.
                    ?assertMatch({ok,_,{normalized,{failed,_}}},submit_fixture(F,
                        {physics_store_request,room,0,none,OldToken,Bytes,Signature}));
                disabled ->
                    commit(Ns,{',',{retract,{physics_space,room,disabled,actor}},
                                   {assertz,{physics_space,room,enabled,actor}}});
                _ -> ok
            end,
            Result
        after sys:resume(Runtime) end,
        case Scenario of
            activation_wins -> ?assertMatch({ok,_,{normalized,{failed,_}}},Cancelled);
            _ ->
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},Cancelled),
                ?assertMatch({ok,[#{}],_},quod_prolog:prove_ro(Ns,
                            {physics_activation_status,room,Request,cancelled}))
        end,
        case Proof of
            none when Scenario =:= never_submitted ->
                ?assertNotMatch({ok,_,{normalized,{committed,_,_}}},
                                quod_client_goal_ingress:submit(Bytes,Signature));
            none -> ok;
            _ -> Proof ! release,
                 receive {old_activation,Tag,Outcome} ->
                     ?assertNotMatch({ok,_,{normalized,{committed,_,_}}},Outcome)
                 after 10000 -> error(old_activation_did_not_finish) end
        end,
        {Next,World} = installed(Ns),
        #{World := #{spec := #{generation := Generation,run_token := NewToken}}} = worlds(Ns),
        ?assertNotEqual(OldToken,NewToken),
        case Scenario of
            activation_wins -> ?assertEqual(2,Generation);
            _ -> ?assertNotEqual(Waiting,Next), ?assertEqual(1,Generation)
        end
    end,BarrierTransform)
    after gproc:unreg(quod_reg:name({host_test,barrier})) end.

sign_fixture(F,Goal) -> sign_fixture(F,Goal,quod_time:now_ms()+30000).
sign_fixture(#{namespace := Ns,reference := {agent_instance_ref,Ns,Anchor,Instance},key := Key},Goal,Expiry) ->
    {ok,Network} = quod_ontology:network_identity(),
    {ok,InstanceText} = quod_client_goal_parser:format(Instance),
    {Canonical,_,_} = erlog_int:term_instance(Goal,0),
    {ok,GoalText} = quod_client_goal_parser:format(Canonical),
    Request = #{network_identity => Network,agent_namespace => Ns,agent_genesis_anchor => Anchor,
                agent_instance_text => InstanceText,signing_public_key => Key,
                operation_id => crypto:strong_rand_bytes(32),not_after_ms => Expiry,
                mode => execute,parser_version => 3,goal_text => GoalText},
    {ok,Bytes,Signature} = quod_agent_vault:sign(Request,quod_time:mono_ms()+5000),
    {Bytes,Signature}.
submit_fixture(F,Goal) ->
    {Bytes,Signature} = sign_fixture(F,Goal),
    quod_client_goal_ingress:submit(Bytes,Signature).

native_nonfinite_quarantine_retires_world_test() ->
    {ok,R} = quod_physics_native:new_world({1,1,1,3.4e38},1/60,-9.81),
    {ok,1} = quod_physics_native:install(R,[{1,1,true,{3.0e38,2.0,0.0},{1.0e38,1.0e-20,1.0e-20},1.0}]),
    ?assertEqual({error,non_finite_state},quod_physics_native:step(R)),
    ?assertEqual({error,retired},quod_physics_native:step(R)).

unexpected_owner_failure_is_quarantined_test_() ->
    {timeout,60,fun() -> with_world(fun(F = #{namespace := Ns}) ->
        {Pid,World} = enable(F),
        #{World := #{spec := #{generation := G}}} = worlds(Ns),
        ok = sys:terminate(Pid,fixture_owner_fault),
        receive {physics_status,_,Pid,World,_,{failed,{owner_down,fixture_owner_fault}}} -> ok
        after 5000 -> error(owner_failure_not_visible) end,
        [reconcile(Ns) || _ <- lists:seq(1,3)],
        ?assertMatch(#{World := #{pid := Pid,stopping := dead,spec := #{generation := G}}},worlds(Ns)),
        commit(Ns,{',',{retract,{physics_structure,room,1}},
                       {assertz,{physics_structure,room,2}}}),
        {Next,World} = installed(Ns),
        ?assertNotEqual(Pid,Next),
        NextG = G+1,
        ?assertMatch(#{World := #{spec := #{generation := NextG}}},worlds(Ns))
    end) end}.

late_activation_does_not_clear_owner_quarantine_test_() ->
    {timeout,60,fun() ->
        {ok,_} = application:ensure_all_started(gproc),
        true = quod_reg:reg({host_test,barrier}),
        try with_world(fun(#{namespace := Ns,node := Node,key := Key}) ->
            true = quod_reg:subscribe({physics,Ns}),
            commit(Ns,{goal,{agent_hosted,actor,Node,1,Key}}),
            commit(Ns,{',',{retract,{physics_space,room,disabled,actor}},
                           {assertz,{physics_space,room,enabled,actor}}}),
            {Proof,Operation} = receive {fipa_completion_prepared,P,Op} -> {P,Op}
                                after 5000 -> error(activation_not_paused) end,
            reconcile(Ns),
            [{World,#{pid := Pid,spec := #{generation := 0}}}] = maps:to_list(worlds(Ns)),
            ok = sys:terminate(Pid,fixture_owner_fault),
            receive {physics_status,_,Pid,World,_,{failed,{owner_down,fixture_owner_fault}}} -> ok
            after 5000 -> error(owner_failure_not_visible) end,
            Proof ! release,
            receive {agent_request_finished,_,_,_,_,
                     {ok,#{operation_ref := Operation},{normalized,{committed,_,_}}}} -> ok
            after 10000 -> error(late_activation_not_committed) end,
            [reconcile(Ns) || _ <- lists:seq(1,3)],
            ?assertMatch(#{World := #{pid := Pid,stopping := dead,spec := #{generation := 1}}},worlds(Ns))
        end,fun(Rules) -> [case Rule of
            {':-',Head = {physics_activate,_,_,_},Body} -> {':-',Head,{',',test_fipa_completion,Body}};
            _ -> Rule
        end || Rule <- Rules] end)
        after gproc:unreg(quod_reg:name({host_test,barrier})) end
    end}.

%% Deterministic delivery races at the real simulator's runtime protocol seam.
%% This owner controls replies; no signed write is fabricated or submitted.
activation_delivery_races_test() ->
    with_simulator(none,fun(Pid,Spec) ->
        Ref = physics_work(Pid,activate),
        assert_uncertain_custody_closed(Pid,Spec,Ref)
    end),
    Custody = {request,<<44:256>>,0,<<1>>,<<0:512>>},
    with_simulator(Custody,fun(Pid,Spec) ->
        Ref = physics_work(Pid,resolve),
        Selection = make_ref(),
        Current = Spec#{generation => 1,run_token => <<44:256>>},
        Pid ! {physics_selected,self(),Selection,Current},
        receive {physics_selection_applied,Pid,_,Selection} -> ok end,
        Pid ! {physics_result,self(),Ref,{ok,ignored,{operation_pending,ignored}}},
        NewRef = physics_work(Pid,resolve),
        Pid ! {physics_result,self(),NewRef,{ok,ignored,{operation_outcome,ignored,#{status => committed}}}},
        Activation = physics_work(Pid,activate),
        ?assertMatch(#{installs := 0},gen_server:call(Pid,status)),
        assert_uncertain_custody_closed(Pid,Current,Activation)
    end).

assert_uncertain_custody_closed(Pid,Spec,Ref) ->
    Pid ! {physics_result,self(),Ref,{error,{custody_unresolved,timeout}}},
    receive {physics_status,Pid,_,_,{unavailable,activation_custody_unresolved}} -> ok
    after 5000 -> error(custody_uncertainty_not_distinguished) end,
    [begin
        Selection = make_ref(),
        Pid ! {physics_selected,self(),Selection,Spec},
        receive {physics_selection_applied,Pid,_,Selection} -> ok end,
        ?assertMatch(#{phase := unresolved},gen_server:call(Pid,status))
     end || _ <- lists:seq(1,3)],
    receive {physics_work,Pid,_,_,_,_,_} -> error(uncertain_custody_resubmitted)
    after 0 -> ok end.

with_simulator(Custody,Fun) ->
    {ok,_} = application:ensure_all_started(gproc),
    Anchor = crypto:strong_rand_bytes(32),
    Spec = #{world => {world_ref,<<"delivery-test">>,Anchor,room},
             authority => {agent_instance_ref,<<"delivery-test">>,Anchor,actor},
             epoch => 1,key => <<1:256>>,generation => 0,run_token => none,
             custody => Custody,budget => 5000},
    {ok,Pid} = quod_physics:start(self(),Spec),
    try Fun(Pid,Spec) after gen_server:stop(Pid) end.

physics_work(Pid,Kind) ->
    receive {physics_work,Pid,_,Ref,Kind,_,_} -> Ref
    after 5000 -> error({physics_work_missing,Kind}) end.

interrupted_initial_physics_selector_reselects_test_() ->
    {timeout,60,fun() ->
        {ok,_} = application:ensure_all_started(gproc),
        true = quod_reg:reg({host_test,local_proof}),
        try with_world(fun(F = #{namespace := Ns}) ->
            {_,World} = enable(F),
            commit(Ns,{assertz,physics_gate}),
            OldReader = receive {local_proof_waiting,P0} -> P0
                        after 5000 -> error(old_selector_not_paused) end,
            Runtime = quod_reg:where({quod_runtime,Ns}),
            M = monitor(process,Runtime), exit(Runtime,kill),
            receive {'DOWN',M,process,Runtime,killed} -> ok end,
            FirstReader = receive {local_proof_waiting,P1} when P1 =/= OldReader -> P1
                          after 10000 -> error(initial_selector_not_paused) end,
            NewRuntime = quod_reg:where({quod_runtime,Ns}),
            Parent = self(), Tag = make_ref(),
            Observe = fun(State,{in,{'DOWN',_,process,P,_}},_) when P =:= FirstReader ->
                              Parent ! {selector_down,Tag}, State;
                         (State,_,_) -> State end,
            ok = sys:install(NewRuntime,{Observe,none}),
            try
                exit(FirstReader,kill),
                receive {selector_down,Tag} -> ok after 5000 -> error(selector_not_retired) end,
                ?assertMatch(#{resource_failures := #{physics_worlds :=
                    {error,{resource_worker_down,killed}}}},quod_runtime:stats(Ns)),
                %% No read basis was reported. Even an unrelated committed
                %% fact must wake this interrupted persistent consumer.
                commit(Ns,{assertz,unrelated_physics_reselection}),
                Reader = receive {local_proof_waiting,P2} -> P2
                         after 10000 -> error(interrupted_selector_lost_dependency) end,
                commit(Ns,{retract,physics_gate}),
                Reader ! release,
                {_,World} = installed(Ns)
            after sys:remove(NewRuntime,Observe) end
        end,fun(Rules) -> [case Rule of
            {':-',Head = {physics_projection,_,_},Body} ->
                {':-',Head,{',',{';',{'->',physics_gate,test_physics_snapshot},true},Body}};
            _ -> Rule
        end || Rule <- Rules] end)
        after gproc:unreg(quod_reg:name({host_test,local_proof})) end
    end}.

obstructed_door_signed_transition_test_() ->
    {timeout,90,fun() -> with_door(fun(F = #{namespace := Ns}) ->
        {Pid,World} = enable(F),
        true = quod_reg:subscribe({runtime,Ns}),
        Id = <<101:256>>, R = {close,1,Id},
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_door,room,10,0,Id})),
        await_door(Ns,R,{blocked,3}),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_door,room,10,1,{finished,R,{blocked,3}}})),
        {ok,[#{'Request' := {request,Sample,{blocked,3},Bytes,Signature}}],_} =
            quod_prolog:prove_ro(Ns,{physics_door_request,room,10,{'Request'}}),
        ?assertMatch({ok,_,{operation_outcome,_,#{status := committed}}},
                     quod_client_goal_ingress:resolve_operation(Bytes,Signature)),
        %% The same operation resolves to the original result; no second event.
        ?assertMatch({ok,_,_},quod_client_goal_ingress:submit(Bytes,Signature)),
        ?assertMatch({ok,_,{normalized,{failed,_}}},door_action(Ns,{physics_finish_door,Sample,{blocked,3}})),
        reconcile(Ns),
        #{World := #{pid := Pid,spec := Spec}} = worlds(Ns),
        {ok,Frame,Before} = quod_physics:snapshot(Pid,#{fence => quod_physics:fence(Spec),structure => 2,tick => -1}),
        [{10,_,_,_,_,_}] = [P || P = {10,_,_,_,_,_} <- maps:get(poses,Frame)],
        assert_no_physics_io(fun() ->
            [reconcile(Ns) || _ <- lists:seq(1,5)],
            #{installs := Installs} = Before,
            ?assertMatch(#{installs := Installs},gen_server:call(Pid,status))
        end),
        Monitor = monitor(process,Pid),exit(Pid,kill),
        receive {'DOWN',Monitor,process,Pid,killed} -> ok after 5000 -> error(door_owner_alive) end,
        {Next,World} = installed(Ns),
        ?assertNotEqual(Pid,Next),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_door,room,10,1,{finished,R,{blocked,3}}})),
        ok
    end,true) end}.

unobstructed_door_signed_transition_test_() ->
    {timeout,90,fun() -> with_door(fun(F = #{namespace := Ns}) ->
        _ = enable(F),true = quod_reg:subscribe({runtime,Ns}),
        Id = <<102:256>>,R = {close,1,Id},
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_door,room,10,0,Id})),
        await_door(Ns,R,closed),
        ok
    end,false) end}.

with_door(Fun,Obstructed) -> with_door(Fun,Obstructed,fun(Rules) -> Rules end).
with_door(Fun,Obstructed,Transform) ->
    with_world(fun(F = #{namespace := Ns}) ->
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
            {physics_add_door,room,10,11,{local,basic_door,1},{vector,0,1500,0},1})),
        try Fun(F) after quod_reg:unsubscribe({runtime,Ns}) end
    end,fun(Rules) ->
        Ns = <<"host-test-agent">>,Actor = {agent_instance_ref,Ns,{'_'},actor},
        Base = [Rule || Rule <- Rules, not (is_tuple(Rule) andalso element(1,Rule) =:= physics_body andalso element(3,Rule) =:= 2)],
        Obstacle = case Obstructed of
            true -> [{physics_body,room,3,1,fixed,{vector,1500,1500,-500},{box,200,1000,200},1}];
            false -> []
        end,
        Transform(Base ++ Obstacle ++ [
            {can_invoke,{physics_store_door_request,{'_'},{'_'},{'_'},{'_'},{'_'}},Actor,{'_'},Ns},
            {can_invoke,{physics_finish_door,{'_'},{'_'}},Actor,{'_'},Ns},
            {can_edit_physics,room,{'_'}},
            {can_close_physics_door,room,10,{'_'}},
            {can_cancel_physics_door,room,10,{'_'}},
            {physics_door_class,basic_door,1,{door,{box,50,1000,50},{box,1000,1000,100},1,1500,{motor,100,10,1000,20}}}])
    end).

door_action(Ns,Goal) ->
    {ok,Bytes,Signature} = quod_node_actor:signed_goal(execute,{'::',Ns,Goal},
        crypto:strong_rand_bytes(32),quod_time:now_ms()+10000),
    quod_client_goal_ingress:submit(Bytes,Signature).

await_door(Ns,R,Result) ->
    receive
        {applied_live,#{ns := Ns,applied_ops := Ops}} ->
            case lists:member({event,{physics_door_finished,room,10,R,Result}},Ops) of
                true -> ok;
                false -> await_door(Ns,R,Result)
            end;
        {physics_status,_,_,_,_,{failed,Why}} -> error({door_failed,Why});
        {physics_status,_,_,_,_,{door_observation,_,State}} when State =/= committed ->
            error({door_observation_failed,State,request_result()})
    after 15000 -> error({door_not_finished,
        maps:map(fun(_,#{pid := P,spec := S}) -> {gen_server:call(P,status),maps:with([generation,structure],S)} end,worlds(Ns)),
        quod_runtime:stats(Ns),request_result()}) end.

terminal_outcome_bridge_captures_failed_alternatives_test_() ->
    {timeout,90,fun() -> with_door(fun(F = #{namespace := Ns}) ->
        _ = enable(F),true = quod_reg:subscribe({runtime,Ns}),
        Id = <<111:256>>,R = {close,1,Id},
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_door,room,10,0,Id})),
        await_door_result(Ns,R,{blocked,3}),
        {ok,[#{'C' := {request,_,_,Bytes,Sig}}],_} =
            quod_prolog:prove_ro(Ns,{physics_door_request,room,10,{'C'}}),
        {ok,#{operation_ref := {operation,_,_,Agent,Op}}} = quod_client_goal:verify(Bytes,Sig),
        Height = quod_prolog:applied(Ns),Key = {1,Agent,Op},
        {{ok,Token},_} = {quod_prolog:operation_dependency(Ns,Key,Height,1000),ignored},
        Query = {committed_operation_outcome,Bytes,Sig,committed},
        assert_no_physics_io(fun() ->
            [begin
                ?assertEqual({ok,Token},quod_prolog:operation_dependency(Ns,Key,Height,1000)),
                with_outcome_session(Ns,Height,fun(Session,Bind,Ctx) ->
                    Goal = case Mode of
                        alternative -> {';', {',',Query,fail},true};
                        negation -> {'\\+',setelement(4,Query,rejected)};
                        cut -> {',',Query,'!'}
                    end,
                    ok = quod_proof_session:open(Session,<<1:128>>,Goal,allowed,Ctx,
                                                 quod_transaction_scope:empty_selection()),
                    ?assertMatch({solution,_},quod_proof_session:next(Session,<<1:128>>)),
                    ?assertEqual(Token,maps:get(Key,quod_proof_session:read_set(Session))),
                    {ok,Plan} = quod_proof_session:seal(Session,Bind),
                    ?assertEqual(Token,maps:get(Key,quod_ct:plan_material(read_check,Plan)))
                end)
            end || Mode <- [alternative,negation,cut]]
        end),
        with_outcome_session(Ns,0,fun(Session,Bind,Ctx) ->
            ok = quod_proof_session:open(Session,<<1:128>>,{'\\+',Query},allowed,Ctx,
                                         quod_transaction_scope:empty_selection()),
            ?assertMatch({error,_},quod_proof_session:next(Session,<<1:128>>)),
            ?assertEqual([{committed_operation_outcome,3}],quod_proof_session:live_bridges(Session)),
            ok = quod_proof_session:open(Session,<<2:128>>,{assertz,{after_error,true}},allowed,Ctx,
                                         quod_transaction_scope:empty_selection()),
            ?assertMatch({solution,_},quod_proof_session:next(Session,<<2:128>>)),
            ?assertEqual({error,{non_transactional_dependency,{committed_operation_outcome,3}}},
                         quod_proof_session:seal(Session,Bind))
        end)
    end,true) end}.

with_outcome_session(Ns,Height,Fun) ->
    Anchor = quod_simplex:genesis_hash(Ns),
    Proof = <<112:256>>,
    _ = quod_proof_context:start(Proof,false,{Ns,Anchor},quod_time:mono_ms()+10000,anonymous),
    Session = quod_proof_session:start(
        quod_runtime_predicates:load(quod_ct:committed_kb([])),#{read_set => true}),
    try
        Fun(Session,#{target => {Ns,Anchor},origin => {Ns,Anchor},base_height => Height,
                      proof_id => Proof,principal => anonymous,request_binding => none},
            quod_predicates:proof_context(Ns,Height,undefined,[{Ns,Anchor}]))
    after
        quod_proof_session:stop(Session),
        quod_proof_context:stop(fun(_) -> ok end,fun(_) -> ok end)
    end.

competing_obstacle_edit_resolves_before_replacement_test_() ->
    {timeout,90,fun() ->
        {ok,_} = application:ensure_all_started(gproc),
        true = quod_reg:reg({host_test,barrier}),
        try with_door(fun(F = #{namespace := Ns}) ->
            _ = enable(F),true = quod_reg:subscribe({runtime,Ns}),
            Id = <<103:256>>,R = {close,1,Id},
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_door,room,10,0,Id})),
            Proof = receive {fipa_completion_prepared,P,_} -> P
                    after 10000 -> error(door_proof_not_paused) end,
            {ok,[#{'C' := {request,_,_,Bytes,Signature}}],_} =
                quod_prolog:prove_ro(Ns,{physics_door_request,room,10,{'C'}}),
            ?assertMatch({ok,_,{operation_pending,_}},quod_client_goal_ingress:resolve_operation(Bytes,Signature)),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
                {physics_move_body,room,3,1,2,{vector,5000,1500,-500}})),
            Proof ! release,
            await_door_result(Ns,R,closed),
            ?assertMatch({ok,_,{operation_outcome,_,#{status := rejected}}},
                         quod_client_goal_ingress:resolve_operation(Bytes,Signature)),
            {ok,[#{'C' := {request,_,closed,NewBytes,_}}],_} =
                quod_prolog:prove_ro(Ns,{physics_door_request,room,10,{'C'}}),
            ?assertNotEqual(Bytes,NewBytes)
        end,true,fun(Rules) -> [case Rule of
            {':-',Head = {physics_finish_door,_,_},Body} ->
                {':-',Head,{',',Body,{';',{'->',{physics_structure,room,2},test_fipa_completion},true}}};
            _ -> Rule
        end || Rule <- Rules] end)
        after gproc:unreg(quod_reg:name({host_test,barrier})) end
    end}.

%% Races may emit intermediate pending/rejected states; completion is the
%% applied consequence event, never a send trace or a delay.
await_door_result(Ns,R,Result) ->
    receive
        {applied_live,#{ns := Ns,applied_ops := Ops}} ->
            case lists:member({event,{physics_door_finished,room,10,R,Result}},Ops) of
                true -> ok;
                false -> await_door_result(Ns,R,Result)
            end;
        {physics_status,_,_,_,_,{failed,Why}} -> error({door_failed,Why})
    after 15000 -> error({door_not_finished,
        maps:map(fun(_,#{pid := P,spec := S}) -> {gen_server:call(P,status),maps:with([generation,structure],S)} end,worlds(Ns)),
        quod_runtime:stats(Ns),request_result()}) end.

saturated_actor_retains_required_door_observation_test_() ->
    {timeout,90,fun() ->
        {ok,_} = application:ensure_all_started(gproc),
        true = quod_reg:reg({host_test,barrier}),
        try with_door(fun(F = #{namespace := Ns}) ->
            {Pid,_} = enable(F),true = quod_reg:subscribe({runtime,Ns}),
            commit(Ns,{trigger_event,fill_work_queue}),
            receive {work_queue_admitted,Results} -> ?assertEqual(lists:duplicate(16,ok),Results)
            after 5000 -> error(queue_not_filled) end,
            First = receive {fipa_completion_prepared,P,_} -> P
                    after 5000 -> error(queue_not_running) end,
            Id = <<104:256>>,R = {close,1,Id},
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_door,room,10,0,Id})),
            %% Sleeping is emitted only after the native contact has braked.
            receive {physics_status,_,Pid,_,_,sleeping} -> ok
            after 10000 -> error(door_not_braked) end,
            ?assertMatch(#{observations := #{10 := offered}},gen_server:call(Pid,status)),
            First ! release,
            lists:foreach(fun(_) ->
                receive {fipa_completion_prepared,Next,_} -> Next ! release
                after 5000 -> error(queue_not_drained) end
            end,lists:seq(1,15)),
            await_door_result(Ns,R,{blocked,3})
        end,true,fun(Rules) ->
            Ns = <<"host-test-agent">>,Principal = {agent_instance_ref,Ns,{'_'},actor},
            Rules ++ [{can_invoke,{',',test_fipa_completion,{record_ping,queued}},Principal,{'_'},Ns},
                {':-',{react_on,fill_work_queue,true},test_fill_work_queue}]
        end)
        after gproc:unreg(quod_reg:name({host_test,barrier})) end
    end}.

pending_door_restart_preserves_original_outcome_test_() ->
    [{atom_to_list(Outcome),{timeout,90,fun() -> pending_door_restart(Outcome) end}} ||
      Outcome <- [committed,rejected]].

pending_door_restart(Outcome) ->
        {ok,_} = application:ensure_all_started(gproc),
        true = quod_reg:reg({host_test,barrier}),
        try with_door(fun(F = #{namespace := Ns}) ->
            {First,World} = enable(F),true = quod_reg:subscribe({runtime,Ns}),
            Id = <<105:256>>,R = {close,1,Id},
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_door,room,10,0,Id})),
            Proof = receive {fipa_completion_prepared,P,_} -> P
                    after 10000 -> error(door_proof_not_paused) end,
            {ok,[#{'C' := {request,_,_,Bytes,Signature}}],_} =
                quod_prolog:prove_ro(Ns,{physics_door_request,room,10,{'C'}}),
            Monitor = monitor(process,First),exit(First,kill),
            receive {'DOWN',Monitor,process,First,killed} -> ok end,
            Second = receive {physics_status,_,P2,World,_,activating} when P2 =/= First -> P2
                     after 5000 -> error(successor_not_started) end,
            ?assertMatch({ok,_,{operation_pending,_}},quod_client_goal_ingress:resolve_operation(Bytes,Signature)),
            Result = case Outcome of
                committed -> {blocked,3};
                rejected ->
                    ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
                        {physics_move_body,room,3,1,2,{vector,5000,1500,-500}})),
                    closed
            end,
            Proof ! release,
            await_door_result(Ns,R,Result),
            {Second,World} = installed(Ns),
            ?assertMatch({ok,_,{operation_outcome,_,#{status := Outcome}}},
                         quod_client_goal_ingress:resolve_operation(Bytes,Signature)),
            {ok,[#{'C' := {request,_,_,SavedBytes,_}}],_} =
                quod_prolog:prove_ro(Ns,{physics_door_request,room,10,{'C'}}),
            case Outcome of
                committed -> ?assertEqual(Bytes,SavedBytes);
                rejected -> ?assertNotEqual(Bytes,SavedBytes)
            end
        end,true,fun(Rules) -> [case Rule of
            {':-',Head = {physics_finish_door,_,_},Body} ->
                {':-',Head,{',',Body,{';',{'->',{physics_run,room,1,{'_'}},test_fipa_completion},true}}};
            _ -> Rule
        end || Rule <- Rules] end)
        after gproc:unreg(quod_reg:name({host_test,barrier})) end.

pending_custody_and_delayed_sample_cannot_finish_new_close_test_() ->
    {timeout,90,fun() -> with_door(fun(F = #{namespace := Ns}) ->
        {Pid,World} = enable(F),true = quod_reg:subscribe({runtime,Ns}),
        #{World := #{spec := Spec}} = worlds(Ns),
        ok = sys:suspend(Pid),
        try
            Id = <<106:256>>,R = {close,1,Id},
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_door,room,10,0,Id})),
            At = quod_time:now_ms(),Expiry = At+10000,
            Sample = {door_sample,room,10,R,maps:get(authority,Spec),maps:get(epoch,Spec),
                maps:get(generation,Spec),maps:get(run_token,Spec),2,2,2,1,500,{contact,3,1},{validity,At,Expiry}},
            %% Every forged/stale component is rejected even with the real
            %% physics actor's signature and an otherwise exact goal binding.
            Invalid = [setelement(5,Sample,maps:get(node,F)),
                setelement(7,Sample,0),setelement(8,Sample,<<99:256>>),
                setelement(9,Sample,1),setelement(10,Sample,1),
                setelement(12,Sample,0),setelement(14,Sample,{contact,3,99}),
                setelement(15,Sample,{validity,At,Expiry+1})],
            lists:foreach(fun(Bad) ->
                {B,SG} = sign_fixture(F,{physics_finish_door,Bad,{blocked,3}},Expiry),
                {SB,SS} = sign_fixture(F,{physics_store_door_request,Bad,{blocked,3},none,B,SG},Expiry),
                ?assertMatch({ok,_,{normalized,{failed,_}}},quod_client_goal_ingress:submit(SB,SS))
            end,Invalid),
            {Bytes,Sig} = sign_fixture(F,{physics_finish_door,Sample,{blocked,3}},Expiry),
            Store = {physics_store_door_request,Sample,{blocked,3},none,Bytes,Sig},
            {StoreBytes,StoreSig} = sign_fixture(F,Store,Expiry),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},quod_client_goal_ingress:submit(StoreBytes,StoreSig)),
            Custody = {request,Sample,{blocked,3},Bytes,Sig},
            NewSample = setelement(12,Sample,2),
            {NewBytes,NewSig} = sign_fixture(F,{physics_finish_door,NewSample,{blocked,3}},Expiry),
            {ReplaceBytes,ReplaceSig} = sign_fixture(F,
                {physics_store_door_request,NewSample,{blocked,3},Custody,NewBytes,NewSig},Expiry),
            %% An absent outcome raises a typed unavailable error rather than
            %% proving absence. The public boundary conservatively normalizes it.
            ?assertMatch({ok,_,{normalized,{error,proof_unavailable}}},quod_client_goal_ingress:submit(ReplaceBytes,ReplaceSig)),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
                {physics_move_body,room,3,1,2,{vector,1500,1500,-500}})),
            %% Edit after store but before the original proof: no transaction
            %% entered ordering, so exact resolution must remain unknown.
            ?assertMatch({ok,_,{normalized,{failed,_}}},quod_client_goal_ingress:submit(Bytes,Sig)),
            ?assertMatch({ok,_,{operation_pending,_}},quod_client_goal_ingress:resolve_operation(Bytes,Sig)),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_cancel_door,room,10,R})),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_door,room,10,1,Id})),
            ?assertNotMatch({ok,_,{normalized,{committed,_,_}}},quod_client_goal_ingress:submit(Bytes,Sig)),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_door,room,10,2,{closing,{close,2,Id}}})),
            %% The reaction event pattern alone never supplies private owner authority.
            commit(Ns,{trigger_event,{observed,NewSample}})
        after sys:resume(Pid) end,
        await_door_result(Ns,{close,2,<<106:256>>},{blocked,3})
    end,true) end}.

shared_class_is_authorized_then_materialized_locally_test_() ->
    {timeout,90,fun() -> with_world(fun(F = #{namespace := Ns,node := Node}) ->
        {agent_instance_ref,ClassNs,ClassAnchor,_} = Node,
        Definition = {door,{box,50,1000,50},{box,1000,1000,100},1,1500,{motor,100,10,1000,20}},
        Class = {physics_door_class,shared_door,1,Definition},
        commit(ClassNs,{assertz,Class}),
        Source = {class_ref,ClassNs,ClassAnchor,shared_door,1},
        Add = {physics_add_door,room,10,11,Source,{vector,0,1500,0},1},
        %% Hosting the class ontology conveys no query authority.
        ?assertMatch({ok,_,{normalized,{failed,_}}},door_action(Ns,Add)),
        Query = {',',{current_ontology_identity,ClassNs,ClassAnchor},{physics_door_class,shared_door,1,{'_'}}},
        Grant = {can_invoke,Query,Node,{'_'},ClassNs},
        commit(ClassNs,{assertz,Grant}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,Add)),
        commit(ClassNs,{',',{retract,Grant},{retract,Class}}),
        {Pid,World} = enable(F),
        #{World := #{pid := Pid,spec := #{hinges := [_],structure := 2}}} = worlds(Ns),
        [reconcile(Ns) || _ <- lists:seq(1,3)],
        ?assertMatch(#{installs := 1},gen_server:call(Pid,status)),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_door_source,room,10,Source}))
    end,fun(Rules) -> Rules ++ [{can_edit_physics,room,{'_'}}] end) end}.

expired_queued_observation_is_freshly_sampled_test_() ->
    [{atom_to_list(Name),{timeout,90,fun() -> queued_observation_expiry(Admitted) end}} ||
      {Name,Admitted} <- [{runtime_cursor,false},{actor_queue,true}]].

queued_observation_expiry(Admitted) ->
        {ok,_} = application:ensure_all_started(gproc),
        true = quod_reg:reg({host_test,barrier}),
        try with_door(fun(F = #{namespace := Ns}) ->
            {Pid,_} = enable(F),true = quod_reg:subscribe({runtime,Ns}),
            commit(Ns,{',',{retract,{physics_allowances,room,{limits,64,64,256,1000000},16667,-9810,10000}},
                {assertz,{physics_allowances,room,{limits,64,64,256,1000000},16667,-9810,1000}}}),
            reconcile(Ns),
            Runtime = quod_reg:where({quod_runtime,Ns}),Parent = self(),Tag = make_ref(),
            Observe = fun(State,{in,{physics_observation,P,_,_,_,Sample,_}},_) when P =:= Pid ->
                              Parent ! {sample_seen,Tag,element(12,Sample),element(15,Sample)},State;
                         (State,_,_) -> State end,
            Accepted = fun(State,{in,{physics_admitted,_,_}},_) ->
                               Parent ! {sample_admitted,Tag},State;
                          (State,_,_) -> State end,
            ok = sys:install(Runtime,{Observe,none}),
            ok = sys:install(Pid,{Accepted,none}),
            try
                commit(Ns,{trigger_event,fill_work_queue}),
                receive {work_queue_admitted,Results} -> ?assertEqual(lists:duplicate(16,ok),Results)
                after 5000 -> error(queue_not_filled) end,
                First = receive {fipa_completion_prepared,Running,_} -> Running
                        after 5000 -> error(queue_not_running) end,
                case Admitted of
                    true ->
                        First ! release,
                        receive {fipa_completion_prepared,_,_} -> ok
                        after 5000 -> error(second_not_running) end;
                    false -> ok
                end,
                Id = <<107:256>>,R = {close,1,Id},
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_door,room,10,0,Id})),
                {Tick,Expiry} = receive {sample_seen,Tag,T,{validity,_,E}} -> {T,E}
                               after 5000 -> error(sample_not_offered) end,
                case Admitted of
                    true -> receive {sample_admitted,Tag} -> ok
                            after 1000 -> error(sample_not_admitted) end;
                    false -> ok
                end,
                %% The held work reaches its original execution deadline. This
                %% real capacity edge consumes the expired cursor and resamples.
                await_door_result(Ns,R,{blocked,3}),
                {ok,[#{'C' := {request,Sample,_,_,_}}],_} =
                    quod_prolog:prove_ro(Ns,{physics_door_request,room,10,{'C'}}),
                ?assert(element(12,Sample) > Tick),
                {validity,NewAt,_} = element(15,Sample),?assert(NewAt >= Expiry)
            after sys:remove(Runtime,Observe),sys:remove(Pid,Accepted) end
        end,true,fun(Rules) ->
            Ns = <<"host-test-agent">>,Principal = {agent_instance_ref,Ns,{'_'},actor},
            Rules ++ [{can_invoke,{',',test_fipa_completion,{record_ping,queued}},Principal,{'_'},Ns},
                {':-',{react_on,fill_work_queue,true},test_fill_work_queue}]
        end)
        after gproc:unreg(quod_reg:name({host_test,barrier})) end.

full_event_queue_keeps_wake_after_hinge_sleeps_test_() ->
    {timeout,90,fun() ->
        Saved = application:get_env(quod,runtime_max_queued_events),
        try with_door(fun(F = #{namespace := Ns}) ->
            {Pid,_} = enable(F),true = quod_reg:subscribe({runtime,Ns}),
            Parent = self(),Tag = make_ref(),Runtime = quod_reg:where({quod_runtime,Ns}),
            Pause = fun(none,{in,{physics_selected,_,_,#{doors := #{10 := #{state := {closing,_}}}}}},_) ->
                            Parent ! {closing_selected,Tag,self()},receive release -> held end;
                       (State,_,_) -> State end,
            Queued = fun(State,{in,{'$gen_call',_,{reconcile_resource,_,physics_worlds,future,_}}},_) ->
                              Parent ! {future_queued,Tag},State;
                        (State,_,_) -> State end,
            ok = sys:install(Pid,{Pause,none}),ok = sys:install(Runtime,{Queued,none}),
            try
                Id = <<108:256>>,R = {close,1,Id},
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_door,room,10,0,Id})),
                receive {closing_selected,Tag,Pid} -> ok after 5000 -> error(close_not_selected) end,
                Base = maps:get(queue_len,quod_runtime:stats(Ns)),
                application:set_env(quod,runtime_max_queued_events,Base+1),
                Caller = spawn(fun() -> quod_runtime:reconcile_resource(Ns,quod_prolog:applied(Ns)+100,
                    physics_worlds,future,quod_time:mono_ms()+30000) end),
                receive {future_queued,Tag} -> ok after 5000 -> error(future_not_queued) end,
                ?assertEqual(Base+1,maps:get(queue_len,quod_runtime:stats(Ns))),
                Pid ! release,
                receive {physics_status,_,Pid,_,_,observation_capacity} -> ok
                after 5000 -> error(observation_not_refused) end,
                receive {physics_status,_,Pid,_,_,sleeping} -> ok
                after 5000 -> error(held_hinge_not_sleeping) end,
                ?assertMatch(#{observations := #{10 := capacity}},gen_server:call(Pid,status)),
                case Saved of undefined -> application:unset_env(quod,runtime_max_queued_events);
                              {ok,Limit} -> application:set_env(quod,runtime_max_queued_events,Limit) end,
                exit(Caller,kill),
                await_door_result(Ns,R,{blocked,3})
            after Pid ! release,sys:remove(Pid,Pause),sys:remove(Runtime,Queued) end
        end,true)
        after case Saved of undefined -> application:unset_env(quod,runtime_max_queued_events);
                            {ok,V} -> application:set_env(quod,runtime_max_queued_events,V) end end
    end}.

sleeping_does_not_erase_explicit_reconciliation_test_() ->
    {timeout,90,fun() -> with_door(fun(F = #{namespace := Ns}) ->
        {Pid,World} = enable(F),true = quod_reg:subscribe({runtime,Ns}),
        #{World := #{spec := Spec}} = worlds(Ns),
        Runtime = quod_reg:where({quod_runtime,Ns}),
        Parent = self(),Tag = make_ref(),
        Observe = fun(State,{in,{physics_selected,_,_,_}},_) ->
                          Parent ! {selection_processed,Tag},State;
                     (State,_,_) -> State end,
        ok = sys:install(Pid,{Observe,none}),
        try
            Runtime ! {physics_status,Pid,World,maps:get(run_token,Spec),{unavailable,resolve}},
            Runtime ! {physics_status,Pid,World,maps:get(run_token,Spec),sleeping},
            _ = quod_runtime:stats(Ns),
            reconcile(Ns),
            receive {selection_processed,Tag} -> ok
            after 5000 -> error(reconciliation_lost_after_sleep) end
        after sys:remove(Pid,Observe) end
    end,true) end}.

generic_observation_clause_cannot_consume_door_request_test_() ->
    {timeout,90,fun() -> with_door(fun(F = #{namespace := Ns}) ->
        _ = enable(F),true = quod_reg:subscribe({runtime,Ns}),
        Id = <<109:256>>,R = {close,1,Id},
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_door,room,10,0,Id})),
        await_door_result(Ns,R,{blocked,3})
    end,true,fun(Rules) -> [{react_on,{observed,{'_'}},true}|Rules] end) end}.

%% A terminally rejected original remains in durable custody until its new
%% signed request is stored. Expiry of the unsigned replacement must still
%% obtain a fresh native sample. Exercise the real owner message protocol.
expired_replacement_observation_resamples_test_() ->
    {timeout,20,fun() -> with_door_simulator(true,fun(Pid,_,Token) ->
        {First,Tick} = door_sample_message(Pid,Token),
        Pid ! {physics_result,self(),First,{error,expired_observation}},
        {Second,NextTick} = door_sample_message(Pid,Token),
        ?assertNotEqual(First,Second), ?assert(NextTick > Tick)
    end) end}.

observation_edit_delivery_order_test_() ->
    observation_edit_delivery_order(#{structure => 2}).

observation_budget_delivery_order_test_() ->
    observation_edit_delivery_order(#{budget => 2500}).

observation_edit_delivery_order(Change) ->
    [{lists:flatten(io_lib:format("~p/~p/~p",[Saved,Order,Result])),{timeout,20,fun() ->
        with_door_simulator(Saved,fun(Pid,Spec,Token) ->
            {First,Tick} = door_sample_message(Pid,Token),
            Select = {physics_selected,self(),make_ref(),maps:merge(Spec,Change)},
            Reply = {physics_result,self(),First,Result},
            case Order of
                selection_first -> Pid ! Select, Pid ! Reply;
                result_first -> Pid ! Reply, Pid ! Select
            end,
            case Saved of true -> reject_door_resolve(Pid); false -> ok end,
            {Second,NextTick} = door_sample_message(Pid,Token),
            ?assertNotEqual(First,Second), ?assert(NextTick > Tick)
        end)
    end}} || Saved <- [false,true], Order <- [selection_first,result_first],
           Result <- [{error,stale_observation},{error,{request_not_submitted,refused}},
                      {error,unmatched},{error,{reaction_guard,refused}},
                      {error,invalid_reaction_request},{error,stale_executor}]].

actor_queue_expiry_resamples_test() ->
    with_door_simulator(false,fun(Pid,_,Token) ->
        {First,Tick} = door_sample_message(Pid,Token),
        Pid ! {physics_admitted,self(),First},
        Pid ! {physics_result,self(),First,{error,{request_not_submitted,deadline_exceeded}}},
        {Second,NextTick} = door_sample_message(Pid,Token),
        ?assertNotEqual(First,Second), ?assert(NextTick > Tick)
    end).

door_sample_message(Pid,Token) ->
    receive {physics_observation,Pid,_,Token,Ref,Sample,_} -> {Ref,element(12,Sample)}
    after 1000 -> error(required_observation_lost) end.

reject_door_resolve(Pid) ->
    Resolve = physics_work(Pid,resolve),
    Pid ! {physics_result,self(),Resolve,{ok,ignored,{operation_outcome,ignored,#{status => rejected}}}}.

with_door_simulator(SavedCustody,Fun) ->
    with_simulator(none,fun(Pid,Spec) ->
        {Activation,Token} = receive
            {physics_work,Pid,_,A,activate,{{physics_activate,room,0,T},_},_} -> {A,T}
        after 5000 -> error(activation_missing) end,
        R = {close,1,<<111:256>>},
        Sample = {door_sample,room,10,R,maps:get(authority,Spec),1,1,Token,1,1,1,1,0,clear,
                  {validity,quod_time:now_ms(),quod_time:now_ms()+5000}},
        Saved = case SavedCustody of true -> {request,Sample,closed,<<1>>,<<0:512>>}; false -> none end,
        Current = Spec#{generation => 1,run_token => Token,
            custody => {request,Token,0,<<2>>,<<0:512>>},
            limits => {2,2,1,100.0},dt => 1/60,gravity => 0.0,structure => 1,
            bodies => [{10,1,true,{0.0,1.0,0.0},{1.0,1.0,0.1},1.0},
                       {11,1,false,{0.0,1.0,0.0},{0.05,1.0,0.05},1.0}],
            hinges => [{{10,1,11,{0.0,0.0,0.0},1.5,{100.0,10.0,1000.0,0.02}},0.0}],
            doors => #{10 => #{sequence => 1,state => {closing,R},custody => Saved,outcome_key => none}}},
        Pid ! {physics_selected,self(),make_ref(),Current},
        Pid ! {physics_result,self(),Activation,{ok,ignored,{normalized,{committed,ignored,ignored}}}},
        case SavedCustody of true -> reject_door_resolve(Pid); false -> ok end,
        Fun(Pid,Current,Token)
    end).

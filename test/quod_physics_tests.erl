-module(quod_physics_tests).
-include_lib("eunit/include/eunit.hrl").

first_host_and_complete_configuration_commit_together_test_() ->
    [{binary_to_list(Ns),{timeout,90,fun() -> with_world(Ns,
        fun(F) -> first_physical_configuration(F, Gravity) end,
        fun(Rules) -> [R || R <- Rules, not lists:member(element(1,R),
            [instance_of,physics_space,physics_run,physics_structure,
             physics_next_body,physics_allowances,physics_body_definition])] end)
    end}} || {Ns,Gravity} <- [{<<"gallery-first-physics">>,-9810},
                             {<<"workshop-first-physics">>,-1620}]].

first_physical_configuration(#{namespace := Ns,node := Node,reference := Agent,key := Key}, Gravity) ->
    Anchor = element(3,Agent), Remote = setelement(2,Node,<<"remote-node">>),
    Grant = {can_assign_agent_host,Node,actor,none,0,Node,Key},
    RemoteGrant = {can_assign_agent_host,Node,actor,none,0,Remote,<<33:256>>},
    commit(Ns,list_conjunction([{assertz,R} || R <-
        [Grant,RemoteGrant,{can_prepare_agent_key,Node,actor,none,0,Node}]])),
    {ok,ReadBytes,ReadSignature} = quod_node_actor:signed_goal(read,
        {'::',Ns,{prepare_agent_key_custody,Agent,none,0,Node,{0}}},
        crypto:strong_rand_bytes(32),quod_time:now_ms()+10000),
    {ok,_,{normalized,{read,_,{answers,1,[Prepared]}}}} =
        quod_client_goal_ingress:submit(ReadBytes,ReadSignature),
    ?assertEqual({ok,[{<<"V0">>,Key}]},quod_durable_term:decode_result(Prepared)),
    ?assertEqual(#{},worlds(Ns)),
    ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{space_instance,room,physical_space})),
    ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{agent_host,actor,{'_'},{'_'},{'_'}})),
    Rows = first_physics_rows(Node,Gravity),
    Goal = first_physics_goal(Ns,Anchor,Node,Key,Rows),
    %% A real incomplete camera definition rolls back the host and all bodies.
    MissingCamera = [R || R <- Rows, element(1,R) =/= physics_viewpoint],
    ?assertMatch({ok,_,{normalized,{failed,_}}},
        door_action(Ns,first_physics_goal(Ns,Anchor,Node,Key,MissingCamera))),
    assert_unconfigured(Ns),
    true = quod_reg:reg({host_test,local_proof}),
    true = quod_reg:subscribe({physics,Ns}),
    try
        %% A prepared key reserves no assignment right. Revoke after proof,
        %% before commit, and require the ordinary predicate OCC conflict.
        Parent = self(), Tag = make_ref(),
        {Caller,Monitor} = spawn_monitor(fun() -> Parent ! {first_assignment,Tag,
            door_action(Ns,{',',Goal,test_local_wait})} end),
        Proof = receive {local_proof_waiting,P} -> P after 5000 -> error(initial_proof_missing) end,
        try
            commit(Ns,{retract,Grant}), Proof ! release,
            receive {first_assignment,Tag,Refused} ->
                ?assertMatch({ok,_,{normalized,{error,conflict_retry}}},Refused)
            after 10000 -> error(initial_revocation_not_resolved) end
        after
            Proof ! release, exit(Caller,kill),
            receive {'DOWN',Monitor,process,Caller,_} -> ok after 1000 -> error(initial_caller_alive) end
        end,
        assert_unconfigured(Ns), commit(Ns,{assertz,Grant}),
        %% Both candidates prove against the absent assignment. Releasing the
        %% local candidate first makes the competing destination deterministic.
        Results = live_compete(Ns,[Goal,first_physics_goal(Ns,Anchor,Remote,<<33:256>>,Rows)]),
        ?assertMatch([{1,{ok,_,{normalized,{committed,_,_}}}},
                      {2,{ok,_,{normalized,{error,conflict_retry}}}}],Results),
        {Pid,World = {world_ref,Ns,Anchor,room}} = installed(Ns),
        #{World := #{spec := Spec}} = worlds(Ns),
        ?assertEqual(Gravity/1000,maps:get(gravity,Spec)),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{agent_hosted,actor,Node,1,Key})),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
            {physics_control,room,Node,1,{controlled,pilot,eye}})),
        ?assertMatch({2,1,controlled,_,{solid,{capsule,0.5,0.25}},_},
            lists:keyfind(2,1,maps:get(bodies,Spec))),
        ?assertMatch(#{navigation_ready := true},gen_server:call(Pid,status)),
        ?assertEqual(Anchor,quod_simplex:genesis_hash(Ns))
    after gproc:unreg(quod_reg:name({host_test,local_proof})) end.

assert_unconfigured(Ns) ->
    [?assertMatch({fail,_},quod_prolog:prove_ro(Ns,Goal)) || Goal <-
        [{space_instance,room,physical_space},
         {agent_host,actor,{'_'},{'_'},{'_'}},{agent_key,actor,{'_'},active},
         {physics_space,room,{'_'},{'_'}},{physics_body_definition,room,{'_'},{'_'},{'_'},{'_'},{'_'}}]],
    reconcile(Ns), ?assertEqual(#{},worlds(Ns)).

first_physics_goal(Ns,Anchor,Host,Key,Rows) ->
    Checks = [{physics_checked_body,B,K,P,S,D,1000000} ||
        {physics_body_definition,room,B,_,K,P,{owned,S,D}} <- Rows],
    {transaction,list_conjunction([
        {current_ontology_identity,Ns,Anchor},
        {'\\+',{physics_space,room,{0},{1}}},
        {goal,{agent_hosted,actor,Host,1,Key}}] ++ Checks ++
        [{assertz,R} || R <- Rows] ++
        [{physics_control_agent,room,0,none,{controlled,pilot,eye}}])}.

first_physics_rows(Principal,Gravity) ->
    [{instance_of,physical_space,room},{physics_space,room,enabled,actor},
     {physics_run,room,0,none},{physics_structure,room,1},{physics_next_body,room,5},
     {physics_allowances,room,{limits,16,16,128,1000000,{geometry,32,128,128}},16667,Gravity,10000},
     {physics_body_definition,room,1,1,fixed,{vector,0,-250,0},{owned,{box,8000,250,8000},1}},
     {physics_body_definition,room,2,1,controlled,{vector,0,1200,3000},{owned,{capsule,500,250},1}},
     {physics_body_definition,room,3,1,fixed,{vector,-1500,550,0},{owned,
         {parts,[{part,{vector,0,0,0},{box,600,100,300}},
                 {part,{vector,0,-300,0},{box,150,300,150}}]},1}},
     {physics_body_definition,room,4,1,fixed,{vector,0,0,-4000},{owned,
         {parts,[{part,{vector,-2000,1500,0},{box,250,1500,250}},
                 {part,{vector,2000,1500,0},{box,250,1500,250}},
                 {part,{vector,0,3250,0},{box,2250,250,250}}]},1}},
     {instance_of,agent,pilot},
     {physics_agent,room,pilot,1,2,
         {motion,{grounded,900},2000,1600,500,{query_limits,2,0,8,128},[]}},
     {physics_viewpoint,room,pilot,eye,2,{pose,{vector,0,700,0},{rotation,0,100,0}},
         {tracking,view_only,500}},
     {can_view_physics,room,Principal},{can_control_physics_agent,room,Principal,pilot}].

live_source_control_continuity_test_() ->
    {timeout,90,fun() -> with_live_source(<<"live-controls">>,fun(F =
            #{namespace := Ns,source := Source,destination := Destination,subject := Subject}) ->
        commit(Ns,{',',{retract,{physics_admission,room,Subject,fixed,{vector,4000,1000,0}}},
            {assertz,{physics_admission,room,Subject,controlled,{vector,4000,1000,0}}}}),
        {Pid,World} = enable(F),
        Admission = door_action(Source,{space_place,obstacle,0,Destination}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Admission),
        {Pid,World} = installed_structure(Ns,2), await_live_receipt(Admission),
        Limits = {query_limits,2,0,8,128},
        {_,Expected,Frame,Ref,Initial} = install_test_control(F,Pid,World,
            {motion,free,2000,1600,1000,Limits,[]},4),
        Command = fun(Sequence) -> control_goal({'::',Ns,{physics_control_input,room,Frame,1,Sequence,
            {drive,{vector,0,0,0},{angular,0,0,0}},{0}}}) end,
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Command(1)),
        quod_physics:ack(Pid,Ref,maps:get(tick,Initial)),
        _ = input_frame(Pid,Ref,maps:get(node,F),1),
        Runtime = quod_reg:where({quod_runtime,Ns}), Parent = self(), Token = make_ref(),
        Observe = fun(State,{in,{quod_foreign_follow,_,_,{Source0,_},
                        {advanced,_,Height,_,_,_,_}}},_) when Source0 =:= Source ->
                        Parent ! {live_source_height,Token,Height}, State;
                     (State,_,_) -> State end,
        ok = sys:install(Runtime,{Observe,none}),
        try
            Before = gen_server:call(Pid,status),
            commit(Source,{assertz,{unrelated_note,hello}}), Height = quod_prolog:applied(Source),
            await_live_source_height(Token,Height), _ = quod_runtime:stats(Ns),
            After = gen_server:call(Pid,status),
            ?assertMatch(#{navigation_ready := true},After),
            ?assertEqual(maps:get(inputs,Before),maps:get(inputs,After)),
            ?assertEqual(maps:get(installs,Before),maps:get(installs,After)),
            receive {physics_refresh,Pid,Ref} -> error(unrelated_source_retired_view) after 0 -> ok end,
            %% The original registration remains valid. No source invocation
            %% grant is needed for hot input after signed view admission.
            commit(Source,{retract,{can_invoke,{'_'},maps:get(node,F),{'_'},Source}}),
            await_live_source_height(Token,quod_prolog:applied(Source)), _ = quod_runtime:stats(Ns),
            ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Command(2)),
            ?assertMatch({ok,_,_},quod_physics:snapshot(Pid,Expected#{tick => -1})),
            quod_physics:ack(Pid,Ref,maps:get(tick,Initial))
        after sys:remove(Runtime,Observe), quod_physics:unwatch(Pid,Ref) end
    end) end}.

live_source_signed_view_test_() ->
    {timeout,90,fun() -> with_live_source(<<"live-signed-view">>,fun(F =
            #{namespace := Ns,source := Source,destination := Destination,subject := Subject,
              identity := Identity}) ->
        commit(Ns,{',',{retract,{physics_admission,room,Subject,fixed,{vector,4000,1000,0}}},
            {assertz,{physics_admission,room,Subject,controlled,{vector,4000,1000,0}}}}),
        {Pid,World} = enable(F), Admission = door_action(Source,{space_place,obstacle,0,Destination}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Admission),
        {Pid,World} = installed_structure(Ns,2), await_live_receipt(Admission),
        Human = {agent_instance_ref,Ns,quod_simplex:genesis_hash(Ns),viewer},
        commit(Ns,{assertz,{agent_key,viewer,maps:get(pubkey,Identity),active}}),
        {_,_,OldFrame,OldRef,_} = install_test_control(F#{node => Human},Pid,World,
            {motion,free,2000,1600,1000,{query_limits,2,0,8,128},[]},4),
        quod_physics:unwatch(Pid,OldRef), _ = gen_server:call(Pid,status),
        commit(Ns,{',',{assertz,{can_view_physics,room,Human}},{assertz,{world_view,room,playing,[]}}}),
        reconcile(Ns),
        Parent = self(), Socket = spawn_link(fun() -> simulation_socket(Parent,#{peer => {127,0,0,1}}) end),
        Runtime = quod_reg:where({quod_runtime,Ns}), Token = make_ref(),
        Observe = fun(State,{in,{quod_foreign_follow,_,_,{Source0,_},
                        {advanced,_,Height,_,_,_,_}}},_) when Source0 =:= Source ->
                        Parent ! {live_source_height,Token,Height}, State;
                     (State,_,_) -> State end,
        ok = sys:install(Runtime,{Observe,none}),
        try
            Session = simulation_session(Identity),
            Socket ! {client,simulation_open(F,Session,Human)},
            Projection = simulation_reply(Socket,<<"projection">>),
            #{pid := Pid,ref := Ref,view := View,owners := Owners} = simulation_state(Socket),
            ?assertNot(lists:member(Source,maps:values(Owners))),
            Initial = maps:get(<<"frame">>,Projection),
            Registration = base64:decode(maps:get(<<"registration">>,Initial),#{mode => urlsafe,padding => false}),
            Frame = setelement(3,OldFrame,Registration),
            Command = fun(Seq) ->
                Goal = {'::',Ns,{physics_control_input,room,Frame,1,Seq,
                    {drive,{vector,0,0,0},{angular,0,0,0}},{0}}},
                {ok,Text} = quod_client_goal_parser:format(Goal),
                Request = #{network_identity => <<42:256>>,agent_namespace => Ns,
                    agent_genesis_anchor => element(3,Human),agent_instance_text => <<"viewer.">>,
                    signing_public_key => maps:get(pubkey,Identity),operation_id => crypto:strong_rand_bytes(32),
                    not_after_ms => quod_time:now_ms()+10000,mode => control,parser_version => 3,goal_text => Text},
                {ok,Bytes} = quod_client_goal:encode(Request),
                quod_client_goal_ingress:submit(Bytes,quod_identity:sign(Bytes,Identity))
            end,
            ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Command(1)),
            commit(Source,{assertz,{unrelated_note,visible_view_stays_open}}),
            await_live_source_height(Token,quod_prolog:applied(Source)), _ = quod_runtime:stats(Ns),
            ?assertMatch(#{pid := Pid,ref := Ref,view := View,installed := true},simulation_state(Socket)),
            ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Command(2)),
            %% The source editor and viewer are different principals. Only
            %% the editor has source entry grants; both use ordinary signed goals.
            Edit = door_action(Source,{physics_edit_definition,obstacle,1,{geometry,{ball,600},1}}),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},Edit),
            _ = simulation_reply(Socket,<<"refresh">>),
            await_live_receipt(Edit), {Pid,World} = installed_structure(Ns,3),
            Socket ! {client,simulation_open(F,Session,Human)},
            Fresh = simulation_reply(Socket,<<"projection">>),
            ?assertNotEqual(Registration,base64:decode(maps:get(<<"registration">>,maps:get(<<"frame">>,Fresh)),
                #{mode => urlsafe,padding => false}))
        after sys:remove(Runtime,Observe), Socket ! stop end
    end) end}.

unsimulated_definition_edit_test_() ->
    {timeout,60,fun() -> with_live_source(<<"unsimulated-definitions">>,fun(
            #{namespace := Ns,source := Source,destination := Destination}) ->
        Hook = {':-',{space_physical_change,{'W'},{'S'},{'Change'}},{physics_space_change,{'W'},{'S'},{'Change'}}},
        commit(Ns,{',',{'$quod_retract_exact',Hook},{assertz,{space_physical_change,room,{'_'},{'_'}}}}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Source,{space_place,obstacle,0,Destination})),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},
            door_action(Source,{physics_edit_definition,obstacle,1,{geometry,{ball,600},1}})),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Source,{physics_definition,obstacle,2,{geometry,{ball,600},1}})),
        ?assertEqual(#{},worlds(Ns))
    end) end}.

live_source_failure_isolates_world_test_() ->
    {timeout,90,fun() -> with_live_source(<<"independent-worlds">>,fun(F =
            #{namespace := Ns,source := Source,destination := Destination,node := Node}) ->
        {First,World} = enable(F), Admission = door_action(Source,{space_place,obstacle,0,Destination}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Admission),
        {First,World} = installed_structure(Ns,2), await_live_receipt(Admission),
        Anchor = quod_simplex:genesis_hash(Ns), SecondWorld = {world_ref,Ns,Anchor,archive},
        Actor = {agent_instance_ref,Ns,Anchor,other},
        {ok,Blob} = quod_wire_term:encode_canonical(Actor), {ok,Key} = quod_agent_vault:prepare(Blob, 0),
        commit(Ns,{goal,{agent_hosted,other,Node,1,Key}}),
        Rules = [{can_invoke,{physics_store_request,{'_'},{'_'},{'_'},{'_'},{'_'},{'_'}},Actor,{'_'},Ns},
                 {can_invoke,{physics_activate,{'_'},{'_'},{'_'}},Actor,{'_'},Ns},
                 {can_request_agent_signature,Node,other,{'_'}},
                 {instance_of,physical_space,archive},{physics_space,archive,enabled,other},
                 {physics_run,archive,0,none},{physics_structure,archive,1},{physics_next_body,archive,2},
                 {physics_allowances,archive,{limits,8,8,32,1000000,{geometry,8,64,64}},16667,0,10000},
                 {physics_body_definition,archive,1,1,fixed,{vector,0,0,0},{owned,{ball,500},1}}],
        commit(Ns,list_conjunction([{assertz,R} || R <- Rules])),
        {Second,SecondWorld} = installed_world(Ns,SecondWorld), reconcile(Ns),
        Before = gen_server:call(Second,status),
        #{World := #{spec := FirstSpec}} = worlds(Ns),
        Runtime = quod_reg:where({quod_runtime,Ns}), Parent = self(), Token = make_ref(),
        Observe = fun(State,{in,{physics_invalidation_seen,P,W,_}},_)
                        when P =:= First, W =:= World -> Parent ! {first_world_invalidated,Token}, State;
                     (State,_,_) -> State end,
        ok = sys:install(Runtime,{Observe,none}),
        try
            commit(Source,{retract,{physics_definition_delegate,obstacle,World,maps:get(authority,FirstSpec),1}}),
            receive {first_world_invalidated,Token} -> ok after 5000 -> error(source_not_invalidated) end,
            reconcile(Ns),
            ?assertMatch(#{navigation_ready := false},gen_server:call(First,status)),
            ?assertMatch(#{navigation_ready := true},gen_server:call(Second,status)),
            ?assertEqual(maps:with([installs,steps,tick,incarnation],Before),
                         maps:with([installs,steps,tick,incarnation],gen_server:call(Second,status)))
        after sys:remove(Runtime,Observe) end
    end) end}.

installed_world(Ns,Expected) ->
    case installed(Ns) of
        {Pid,Expected} -> {Pid,Expected};
        _ -> installed_world(Ns,Expected)
    end.

await_live_source_height(Token,Minimum) ->
    receive
        {live_source_height,Token,H} when H >= Minimum -> ok;
        {live_source_height,Token,_} -> await_live_source_height(Token,Minimum)
    after 5000 -> error(source_delta_not_delivered) end.

live_source_busy_owner_coalesces_test_() ->
    {timeout,90,fun() -> with_live_source(<<"live-source-busy">>,fun(F =
            #{namespace := Ns,source := Source,destination := Destination}) ->
        {Pid,World} = enable(F),
        Admission = door_action(Source,{space_place,obstacle,0,Destination}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Admission),
        {Pid,World} = installed_structure(Ns,2), await_live_receipt(Admission), reconcile(Ns),
        Runtime = quod_reg:where({quod_runtime,Ns}), Parent = self(), Token = make_ref(),
        Observe = fun(State,{in,{quod_foreign_follow,_,_,{Source0,_},
                        {advanced,_,Height,_,_,_,_}}},_) when Source0 =:= Source ->
                        Parent ! {live_source_height,Token,Height}, State;
                     (State,_,_) -> State end,
        ok = sys:install(Runtime,{Observe,none}), ok = sys:suspend(Pid),
        try
            [begin
                commit(Source,{assertz,{unrelated_note,N}}),
                await_live_source_height(Token,quod_prolog:applied(Source)),
                _ = quod_runtime:stats(Ns)
             end || N <- lists:seq(1,10)],
            {message_queue_len,Queued} = process_info(Pid,message_queue_len),
            ?assert(Queued =< 2)
        after sys:resume(Pid), sys:remove(Runtime,Observe) end,
        {Pid,World} = installed_structure(Ns,2)
    end) end}.

live_source_shared_owner_busy_test_() ->
    {timeout,60,fun() -> with_live_source(<<"live-shared-busy">>,fun(F =
            #{namespace := Ns,source := Source,destination := Destination}) ->
        {Pid,World} = enable(F),
        Admission = door_action(Source,{space_place,obstacle,0,Destination}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Admission),
        {Pid,World} = installed_structure(Ns,2), await_live_receipt(Admission), reconcile(Ns),
        Foreign = quod_reg:where({foreign_log,node}),
        ok = sys:suspend(Foreign),
        try
            %% The retained verified reader remains alive and unchanged even
            %% while the shared log owner handles unrelated work.
            reconcile(Ns),
            ?assertMatch(#{navigation_ready := true},gen_server:call(Pid,status))
        after sys:resume(Foreign) end
    end) end}.

live_source_reader_replacement_test_() ->
    {timeout,60,fun() -> with_live_source(<<"live-reader-replacement">>,fun(F =
            #{namespace := Ns,source := Source,destination := Destination}) ->
        {Pid,World} = enable(F),
        Admission = door_action(Source,{space_place,obstacle,0,Destination}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Admission),
        {Pid,World} = installed_structure(Ns,2), await_live_receipt(Admission), reconcile(Ns),
        Identity = {Source,quod_simplex:genesis_hash(Source)},
        {ok,Probe} = quod_foreign_log:follow(Identity,projection),
        Reader = live_probe_reader(Probe,Identity),
        ok = quod_foreign_log:unfollow(Probe),
        Before = gen_server:call(Pid,status),
        Runtime = quod_reg:where({quod_runtime,Ns}), Parent = self(), Token = make_ref(),
        Observe = fun(State,{in,{quod_foreign_follow,_,_,Identity0,
                        {resnapshot,_,_,#{reader := {Next,_}}}}},_)
                        when Identity0 =:= Identity, Next =/= Reader ->
                        Parent ! {live_reader_replaced,Token,Next}, State;
                     (State,_,_) -> State end,
        ok = sys:install(Runtime,{Observe,none}),
        try
            Monitor = monitor(process,Reader), exit(Reader,kill),
            receive {'DOWN',Monitor,process,Reader,killed} -> ok after 5000 -> error(reader_not_retired) end,
            receive {live_reader_replaced,Token,_} -> ok after 5000 -> error(reader_not_rebuilt) end,
            _ = quod_runtime:stats(Ns),
            %% The same source/follow and physics incarnation now use a fresh
            %% reader generation, acknowledged by the actual runtime consumer.
            {Pid,World} = installed_structure(Ns,2),
            ?assertEqual(maps:get(incarnation,Before),maps:get(incarnation,gen_server:call(Pid,status)))
        after sys:remove(Runtime,Observe) end
    end) end}.

live_probe_reader(Probe,Identity) ->
    receive {quod_foreign_follow,Probe,Notice,Identity,State} ->
        quod_foreign_log:ack(Probe,Notice),
        case State of
            {resnapshot,_,_,#{reader := {Reader,_}}} -> Reader;
            {advanced,_,_,_,#{reader := {Reader,_}},_,_} -> Reader;
            _ -> live_probe_reader(Probe,Identity)
        end
    after 5000 -> error(missing_retained_reader) end.

live_source_requires_stored_subscription_test_() ->
    {timeout,60,fun() -> with_live_source(<<"live-subscription">>,fun(F =
            #{namespace := Ns,source := Source,destination := Destination}) ->
        _ = enable(F), Subscription = {subscribes,Source,quod_simplex:genesis_hash(Source)},
        commit(Ns,{',',{retract,Subscription},{assertz,{':-',Subscription,{'=',1,1}}}}),
        ?assertMatch({ok,_,{normalized,{failed,_}}},door_action(Source,{space_place,obstacle,0,Destination})),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Source,{space_assignment,obstacle,0,none})),
        commit(Ns,{assertz,Subscription}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Source,{space_place,obstacle,0,Destination})),
        _ = installed_structure(Ns,2)
    end) end}.

live_source_authority_replacement_test_() ->
    {timeout,90,fun() -> with_live_source(<<"live-authority">>,fun(F =
            #{namespace := Ns,source := Source,destination := Destination,node := Node}) ->
        {Old,World} = enable(F),
        Admission = door_action(Source,{space_place,obstacle,0,Destination}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Admission),
        {Old,World} = installed_structure(Ns,2), await_live_receipt(Admission),
        #{World := #{spec := Before}} = worlds(Ns),
        Authority = {agent_instance_ref,Ns,quod_simplex:genesis_hash(Ns),other},
        {ok,Blob} = quod_wire_term:encode_canonical(Authority),
        {ok,Key} = quod_agent_vault:prepare(Blob, 0),
        commit(Ns,{goal,{agent_hosted,other,Node,1,Key}}),
        commit(Ns,list_conjunction([{assertz,R} || R <- [
            {can_invoke,{physics_store_request,{'_'},{'_'},{'_'},{'_'},{'_'},{'_'}},Authority,{'_'},Ns},
            {can_invoke,{physics_activate,{'_'},{'_'},{'_'}},Authority,{'_'},Ns},
            {can_request_agent_signature,Node,other,{'_'}}]])),
        Switch = {physics_assign_authority,room,actor,other},
        ?assertMatch({ok,_,{normalized,{failed,_}}},door_action(Ns,Switch)),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_space,room,enabled,actor})),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Source,
            {physics_definition_delegate,obstacle,World,maps:get(authority,Before),1})),
        commit(Source,{assertz,{can_delegate_physics_definition,obstacle,Node,World,Authority}}),
        Monitor = monitor(process,Old),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,Switch)),
        receive {'DOWN',Monitor,process,Old,_} -> ok after 5000 -> error(old_authority_alive) end,
        {New,World} = installed_structure(Ns,2), ?assertNotEqual(Old,New),
        #{World := #{spec := After}} = worlds(Ns),
        ?assertEqual(Authority,maps:get(authority,After)),
        ?assertEqual(maps:get(generation,Before)+1,maps:get(generation,After)),
        ?assertEqual(maps:get(bodies,Before),maps:get(bodies,After)),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Source,
            {physics_definition_delegate,obstacle,World,Authority,1}))
    end) end}.

live_source_moving_door_contact_test_() ->
    {timeout,90,fun() -> with_live_source(<<"live-door">>,fun(F =
            #{namespace := Ns,source := Source,destination := Destination,subject := Subject}) ->
        Actor = {agent_instance_ref,Ns,quod_simplex:genesis_hash(Ns),actor},
        Rules = [{can_invoke,{physics_store_hinged_request,{'_'},{'_'},{'_'},{'_'}},Actor,{'_'},Ns},
                 {can_invoke,{physics_finish_hinged,{'_'},{'_'}},Actor,{'_'},Ns},
                 {can_close_physics_hinged,room,10,{'_'}},
                 {physics_hinged_class,basic_door,1,
                    hinged_recipe()}],
        commit(Ns,list_conjunction([{assertz,R} || R <- Rules] ++ [
            {retract,{physics_admission,room,Subject,fixed,{vector,4000,1000,0}}},
            {assertz,{physics_admission,room,Subject,fixed,{vector,1500,1500,-500}}},
            {retract,{physics_body_definition,room,2,{'_'},{'_'},{'_'},{'_'}}}])),
        {Pid,World} = enable(F),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},
            door_action(Source,{space_place,obstacle,0,Destination})),
        {Pid,World} = installed_structure(Ns,2),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
            {physics_add_hinged,room,10,11,{local,basic_door,1},{vector,0,1500,0},2})),
        {Pid,World} = installed_structure(Ns,3),
        true = quod_reg:subscribe({runtime,Ns}),
        try
            Id = <<153:256>>, Request = {close,1,Id},
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                door_action(Ns,{physics_close_hinged,room,10,0,Id})),
            await_door(Ns,Request,{blocked,4}),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
                {physics_hinged,room,10,1,{finished,Request,{blocked,4}}}))
        after quod_reg:unsubscribe({runtime,Ns}) end
    end) end}.

%% Signed source edits and both receiver consequences use the actual atomic lane.
%% The runtime reads the retained certified projection, without a reaction rule.
live_source_lifecycle_test_() ->
    [{binary_to_list(WorldNs),{timeout,90,fun() ->
        with_live_source(WorldNs,fun(F = #{namespace := Ns,source := Source,subject := Subject,
                                     destination := Destination,node := Principal}) ->
            {Pid,World} = enable(F),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                door_action(Source,{space_place,obstacle,0,Destination})),
            {Pid,World} = installed_structure(Ns,2),
            #{World := #{spec := Before}} = worlds(Ns),
            ?assertMatch({4,2,fixed,_,{solid,{box,0.25,1.0,0.25}},_},
                         lists:keyfind(4,1,maps:get(bodies,Before))),
            Query = {place,{pose,{vector,3000,1000,0},{rotation,0,0,0}}},
            Limits = {query_limits,2,0,8,128},
            ?assertMatch({ok,_,{clear,_,_}},quod_physics:motion_query(Pid,
                #{fence => quod_physics:fence(Before),structure => 2,
                  incarnation => maps:get(run_token,Before)}, {2,1},Query,Limits,1000)),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{space_placement,room,Subject,1})),
            %% Receiver denial rolls back the staged source shape as well.
            commit(Ns,{retract,{can_refresh_physics_definition,room,Principal,Subject}}),
            ?assertMatch({ok,_,{normalized,{failed,_}}},door_action(Source,
                {physics_edit_definition,obstacle,1,{geometry,{ball,750},1}})),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Source,
                {physics_definition,obstacle,1,{geometry,{box,250,1000,250},1}})),
            commit(Ns,{assertz,{can_refresh_physics_definition,room,Principal,Subject}}),
            commit(Ns,{retract,{can_edit_physics,room,Principal}}),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Source,
                {physics_edit_definition,obstacle,1,{geometry,{ball,750},1}})),
            {Pid,World} = installed_structure(Ns,3),
            #{World := #{spec := After}} = worlds(Ns),
            ?assertMatch({4,3,fixed,_,{solid,{ball,0.75}},_},
                         lists:keyfind(4,1,maps:get(bodies,After))),
            ?assertMatch({ok,_,{occupied,4,_}},quod_physics:motion_query(Pid,
                #{fence => quod_physics:fence(After),structure => 3,
                  incarnation => maps:get(run_token,After)}, {2,1},Query,Limits,1000)),
            ?assertEqual(lists:keyfind(2,1,maps:get(bodies,Before)),
                         lists:keyfind(2,1,maps:get(bodies,After))),
            ?assertMatch({error,unavailable},quod_physics:body_state(Pid,
                #{fence => quod_physics:fence(Before),structure => 2},{4,2},1000)),
            %% Deletion composes withdrawal and keeps the assignment tombstone.
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                door_action(Source,{physics_delete_definition,obstacle,2})),
            {Pid,World} = installed_structure(Ns,4),
            #{World := #{spec := Removed}} = worlds(Ns),
            ?assertEqual(false,lists:keyfind(4,1,maps:get(bodies,Removed))),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Source,
                {',',{physical_assignment,obstacle,2,none},{physics_definition,obstacle,3,none}})),
            ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{space_placement,room,Subject,{'_'}})),
            %% Recreate under the same entity, but never reuse its retired body.
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Source,
                {physics_edit_definition,obstacle,3,{geometry,{capsule,500,250},1}})),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                door_action(Source,{space_place,obstacle,2,Destination})),
            {Pid,World} = installed_structure(Ns,5),
            #{World := #{spec := Recreated}} = worlds(Ns),
            ?assertEqual(false,lists:keyfind(4,1,maps:get(bodies,Recreated))),
            ?assertMatch({5,5,fixed,_,{solid,{capsule,0.5,0.25}},_},
                         lists:keyfind(5,1,maps:get(bodies,Recreated)))
        end)
    end}} || WorldNs <- [<<"live-workshop">>,<<"live-observatory">>]].

live_source_stale_install_and_revocation_test_() ->
    {timeout,90,fun() -> with_live_source(<<"live-fenced">>,fun(F =
            #{namespace := Ns,source := Source,destination := Destination,subject := Subject}) ->
        {Pid,World} = enable(F),
        Admission = door_action(Source,{space_place,obstacle,0,Destination}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Admission),
        {Pid,World} = installed_structure(Ns,2),
        await_live_receipt(Admission), reconcile(Ns),
        #{World := #{spec := Spec}} = worlds(Ns),
        Grant = {physics_definition_delegate,obstacle,World,maps:get(authority,Spec),1},
        Runtime = quod_reg:where({quod_runtime,Ns}), Parent = self(), Token = make_ref(),
        Pause = fun(false,{in,{'$gen_call',{Worker,_},{resource_selected,physics_worlds,_}}},_) ->
                        true = erlang:suspend_process(Worker),
                        Parent ! {source_selection_paused,Token,Worker}, true;
                   (State,_,_) -> State end,
        Seen = fun(State,{in,{physics_invalidation_seen,Pid0,World0,_}},_)
                        when Pid0 =:= Pid, World0 =:= World ->
                        Parent ! {source_invalidated,Token}, State;
                  (State,_,_) -> State end,
        ok = sys:install(Runtime,{Pause,false}), ok = sys:install(Runtime,{Seen,none}),
        {Caller,Monitor} = spawn_monitor(fun() ->
            Result = quod_runtime:reconcile_resource(Ns,quod_prolog:applied(Ns),
                         physics_worlds,all,quod_time:mono_ms()+10000),
            Parent ! {source_selection_result,Token,Result}
        end),
        Worker = receive {source_selection_paused,Token,W} -> W
                 after 5000 -> error(source_selector_not_paused) end,
        try
            _ = worlds(Ns),
            %% Administrative grant removal is deliberately outside normal
            %% withdrawal: it must fail closed, not erase the committed body.
            commit(Source,{retract,Grant}),
            receive {source_invalidated,Token} -> ok
            after 5000 -> error(source_did_not_invalidate) end,
            ?assertMatch(#{navigation_ready := false},gen_server:call(Pid,status)),
            true = resume_live_worker(Runtime,Worker),
            receive {source_selection_result,Token,Result} ->
                ?assertEqual({error,selection_superseded},Result)
            after 5000 -> error(stale_source_install_not_rejected) end,
            receive {'DOWN',Monitor,process,Caller,normal} -> ok
            after 5000 -> error(source_caller_not_finished) end,
            reconcile(Ns),
            ?assertMatch(#{World := #{pid := Pid}},worlds(Ns)),
            ?assertMatch(#{navigation_ready := false},gen_server:call(Pid,status)),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{space_placement,room,Subject,1})),
            commit(Source,{assertz,Grant}),
            {Pid,World} = installed_structure(Ns,2)
        after
            catch resume_live_worker(Runtime,Worker),
            catch sys:remove(Runtime,Pause), catch sys:remove(Runtime,Seen)
        end
    end) end}.

resume_live_worker(Runtime,Worker) ->
    _ = sys:replace_state(Runtime,fun(State) -> true = erlang:resume_process(Worker), State end), true.

live_source_unchanged_work_and_recovery_test_() ->
    {timeout,90,fun() -> with_live_source(<<"live-recovery">>,fun(F =
            #{namespace := Ns,source := Source,destination := Destination}) ->
        {Pid,World} = enable(F),
        Admission = door_action(Source,{space_place,obstacle,0,Destination}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Admission),
        {Pid,World} = installed_structure(Ns,2), await_live_receipt(Admission),
        reconcile(Ns), Before = gen_server:call(Pid,status),
        assert_no_live_geometry_work(fun() ->
            [reconcile(Ns) || _ <- lists:seq(1,20)],
            ?assertEqual(maps:with([installs,steps,tick,incarnation],Before),
                         maps:with([installs,steps,tick,incarnation],gen_server:call(Pid,status)))
        end),
        %% Retained source owner replacement rebuilds current verified state.
        %% No subscribed reaction exists to reconstruct the body.
        #{World := #{spec := BeforeSpec}} = worlds(Ns),
        Expected = #{fence => quod_physics:fence(BeforeSpec),structure => 2,
                     incarnation => maps:get(run_token,BeforeSpec)},
        ?assertMatch({ok,_,_},quod_physics:body_state(Pid,Expected,{4,2},1000)),
        Runtime = quod_reg:where({quod_runtime,Ns}), Parent = self(), Token = make_ref(),
        Seen = fun(State,{in,{physics_invalidation_seen,Owner,_,_}},_) when Owner =:= Pid ->
                        Parent ! {live_source_lost,Token}, State;
                  (State,_,_) -> State end,
        ok = sys:install(Runtime,{Seen,none}),
        try
            Foreign = quod_reg:where({foreign_log,node}), gen_server:stop(Foreign),
            receive {live_source_lost,Token} -> ok after 5000 -> error(source_loss_not_delivered) end,
            ?assertEqual({error,unavailable},quod_physics:body_state(Pid,Expected,{4,2},1000))
        after sys:remove(Runtime,Seen) end,
        {ok,Replacement} = quod_foreign_log:start_link(
            #{cache_dir => filename:join(maps:get(directory,F),"foreign")}),
        try
            {Pid,World} = installed_structure(Ns,2),
            #{World := #{spec := Spec}} = worlds(Ns),
            ?assertMatch({4,2,fixed,_,{solid,{box,0.25,1.0,0.25}},_},
                         lists:keyfind(4,1,maps:get(bodies,Spec))),
            ?assertEqual(maps:get(incarnation,Before),maps:get(incarnation,gen_server:call(Pid,status)))
        after gen_server:stop(Replacement) end
    end) end}.

assert_no_live_geometry_work(Fun) ->
    Collector = spawn_link(fun() -> trace_calls([]) end),
    Trace = trace:session_create(live_geometry_unchanged,Collector,[]),
    Watched = [{quod_foreign_projection,start_monitor,4},{quod_committed_projection,apply_entry,3},
               {quod_physics_native,install,2},{quod_physics_native,install_hinges,2},
               {quod_physics_native,new_world,3},{quod_ledger_store,fold,5},
               {quod_ledger_store,open,3},{file,write,2},{file,pwrite,3},
               {file,sync,1},{file,datasync,1}],
    [trace:function(Trace,MFA,[{'_',[],[{message,{caller}}]}],[local]) || MFA <- Watched],
    trace:process(Trace,all,true,[call]),
    try
        Fun(), Delivered = trace:delivered(Trace,all),
        receive {trace_delivered,all,Delivered} -> ok after 5000 -> error(trace_timeout) end,
        Ref = make_ref(), Collector ! {finish,self(),Ref},
        Calls = receive {trace_calls,Ref,Rows} -> Rows after 5000 -> error(trace_timeout) end,
        ?assertEqual([],Calls)
    after trace:session_destroy(Trace),unlink(Collector),exit(Collector,kill) end.

await_live_receipt({ok,#{operation_ref := Op = {operation,Ns,_,_,_}},_}) ->
    true = quod_reg:subscribe({runtime,Ns}),
    try await_live_receipt(Ns,Op,quod_time:mono_ms()+5000)
    after quod_reg:unsubscribe({runtime,Ns}) end.
await_live_receipt(Ns,Op,Deadline) ->
    Remaining = Deadline-quod_time:mono_ms(), ?assert(Remaining > 0),
    {ok,#{applied_floor := Floor,outcome := Outcome}} = quod_prolog:outcome_snapshot(Ns,Op,Remaining),
    case Outcome of
        #{operation_state := terminal,receipt_height := Height} when Height =< Floor -> ok;
        _ -> receive {projection_advanced,_,Height} when Height > Floor ->
                    await_live_receipt(Ns,Op,Deadline)
             after Remaining -> error(live_receipt_not_published) end
    end.

live_source_atomic_conflicts_test_() ->
    {timeout,90,fun() -> with_live_source(<<"live-conflicts">>,fun(F =
            #{namespace := Ns,source := Source,destination := Destination,subject := Subject}) ->
        {Pid,World} = enable(F),
        true = quod_reg:reg({host_test,local_proof}),
        try
            %% Two complete candidate admissions cannot consume the same slot/ID.
            Results = live_compete(Source,[{space_place,obstacle,0,Destination},
                                           {space_place,obstacle,0,Destination}]),
            assert_live_conflict(Results), {Pid,World} = installed_structure(Ns,2),
            ?assertMatch({ok,[#{'Ids' := [4]}],_},quod_prolog:prove_ro(Ns,
                {findall,{'B'},{physics_body_definition,room,{'B'},{'_'},{'_'},{'_'},
                                       {live,Subject,1,1,{'_'}}},{'Ids'}})),
            %% Either edit or withdrawal may win. Their receiver changes stay
            %% atomic; the losing prepared proof cannot restore a retired body.
            Mixed = live_compete(Source,[{physics_edit_definition,obstacle,1,{geometry,{ball,600},1}},
                                        {space_withdraw,obstacle,1,Destination}]),
            assert_live_conflict(Mixed), {Pid,World} = installed_structure(Ns,3),
            #{World := #{spec := Spec}} = worlds(Ns),
            case lists:keyfind(edit,1,[{case N of 1 -> edit; 2 -> withdraw end,R} || {N,R} <- Mixed]) of
                {edit,{ok,_,{normalized,{committed,_,_}}}} ->
                    ?assertMatch({4,3,fixed,_,{solid,{ball,0.6}},_},lists:keyfind(4,1,maps:get(bodies,Spec))),
                    ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Source,{physical_assignment,obstacle,1,Destination}));
                _ ->
                    ?assertEqual(false,lists:keyfind(4,1,maps:get(bodies,Spec))),
                    ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Source,{physical_assignment,obstacle,2,none})),
                    ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Source,
                        {physics_definition,obstacle,1,{geometry,{box,250,1000,250},1}}))
            end
        after gproc:unreg(quod_reg:name({host_test,local_proof})) end
    end) end}.

live_compete(Source,Goals) ->
    Parent = self(), Token = make_ref(),
    Jobs = [begin
        {Pid,Monitor} = spawn_monitor(fun() -> Parent ! {live_race,Token,N,
            door_action(Source,{',',Goal,test_local_wait})} end),
        Proof = receive {local_proof_waiting,P} -> P after 5000 -> error(race_proof_missing) end,
        {Pid,Monitor,Proof}
    end || {N,Goal} <- lists:zip(lists:seq(1,length(Goals)),Goals)],
    try
        [{_,_,First},{_,_,Second}] = Jobs,
        try
            First ! release,
            One = receive {live_race,Token,N1,R1} -> {N1,R1} after 10000 -> error(first_race_timeout) end,
            Second ! release,
            Two = receive {live_race,Token,N2,R2} -> {N2,R2} after 10000 -> error(second_race_timeout) end,
            [One,Two]
        after First ! release, Second ! release end
    after
        [begin exit(P,kill), receive {'DOWN',M,process,P,_} -> ok after 1000 -> error(race_caller_alive) end end
         || {P,M,_} <- Jobs]
    end.

assert_live_conflict(Results) ->
    ?assertEqual(1,length([R || {_,{ok,_,{normalized,{committed,_,_}}} = R} <- Results])),
    [Failure] = [R || {_,R} <- Results, case R of
        {ok,_,{normalized,{committed,_,_}}} -> false; _ -> true end],
    case Failure of
        {ok,_,{normalized,{error,conflict_retry}}} -> ok;
        _ -> assert_reason(conflict_retry,Failure)
    end.

live_source_nonphysical_admission_test_() ->
    {timeout,60,fun() -> with_live_source(<<"live-catalogue">>,fun(
            #{namespace := Ns,source := Source,destination := Destination}) ->
        commit(Ns,{retract,{instance_of,physical_space,room}}),
        Height = quod_prolog:applied(Source),
        assert_reason({not_physical_space,room},door_action(Source,{space_place,obstacle,0,Destination})),
        ?assertEqual(Height,quod_prolog:applied(Source)),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Source,{space_assignment,obstacle,0,none})),
        ?assertMatch({fail,_},quod_prolog:prove_ro(Source,{physics_definition_delegate,obstacle,{'_'},{'_'},{'_'}})),
        ?assertEqual(#{},worlds(Ns))
    end) end}.

with_live_source(Ns,Fun) ->
    with_world(Ns,fun(F = #{directory := Dir,identity := Identity,node := Principal}) ->
        Source = <<Ns/binary,"-objects">>,
        Anchor = quod_simplex:genesis_hash(Ns), Destination = {entity_ref,Ns,Anchor,room},
        World = {world_ref,Ns,Anchor,room}, Authority = {agent_instance_ref,Ns,Anchor,actor},
        Terms = quod_prolog:read_terms("priv/ontologies/quod_physics.pl") ++
                quod_prolog:read_terms("priv/ontologies/space.pl") ++
            [{can_invoke,{'_'},Principal,{'_'},Source}, {instance_of,artifact,obstacle},
             {physics_definition,obstacle,1,{geometry,{box,250,1000,250},1}},
             {physics_definition_allowance,obstacle,1000000},
             {can_edit_physics_definition,obstacle,Principal},
             {can_delegate_physics_definition,obstacle,Principal,World,Authority},
             {can_enter_space,obstacle,Principal,Destination,physical},
             {can_leave_space,obstacle,Principal,Destination,physical}],
        SourceSup = quod_agent_hosting_tests:start_ontology(Source,Dir,Identity,[],Terms),
        {ok,Foreign} = quod_foreign_log:start_link(#{cache_dir => filename:join(Dir,"foreign")}),
        Subject = {entity_ref,Source,quod_simplex:genesis_hash(Source),obstacle},
        try
            Rules = [{subscribes,Source,quod_simplex:genesis_hash(Source)},
                     {can_admit_space_member,room,Principal,Subject,physical},
                     {can_remove_space_member,room,Principal,Subject,physical},
                     {can_edit_physics,room,Principal},
                     {can_refresh_physics_definition,room,Principal,Subject},
                     {physics_admission,room,Subject,fixed,{vector,4000,1000,0}},
                     {':-',{space_physical_change,{'W'},{'S'},{'Change'}},
                           {physics_space_change,{'W'},{'S'},{'Change'}}}],
            commit(Ns,list_conjunction([{assertz,R} || R <- Rules])),
            Fun(F#{source => Source,subject => Subject,destination => Destination})
        after
            catch gen_server:stop(Foreign), quod_agent_hosting_tests:stop_ontology(SourceSup)
        end
    end,fun(Rules) -> [case R of
        {physics_allowances,W,Limits,Step,_,Budget} -> {physics_allowances,W,Limits,Step,0,Budget};
        {physics_body_definition,W,2,Rev,_,Pose,Definition} ->
            {physics_body_definition,W,2,Rev,controlled,Pose,Definition};
        _ -> R end || R <- Rules] end).

installed_structure(Ns,Structure) ->
    {Pid,World} = installed(Ns),
    case worlds(Ns) of
        #{World := #{spec := #{structure := Structure}}} -> {Pid,World};
        _ -> installed_structure(Ns,Structure)
    end.

list_conjunction([]) -> true;
list_conjunction([Goal|Rest]) -> {',',Goal,list_conjunction(Rest)}.

supported_geometry_signed_edit_test_() ->
    Tetrahedron = [{vector,0,0,0},{vector,500,0,0},{vector,0,500,0},{vector,0,0,500}],
    Shapes = [{box,fixed,{box,500,500,500}}, {ball,fixed,{ball,500}}, {capsule,fixed,{capsule,500,250}},
        {convex,fixed,{convex,Tetrahedron}},
        {dynamic_ball,dynamic,{ball,500}}, {controlled_capsule,controlled,{capsule,500,250}},
        {dynamic_convex,dynamic,{convex,Tetrahedron}},
        {parts,fixed,{parts,[{part,{pose,{vector,-750,0,0},{rotation,0,100,0}},{box,250,500,250}},
                       {part,{vector,750,0,0},{ball,250}}]}},
        {surface,fixed,{surface,[{vector,-500,0,-500},{vector,500,0,-500},{vector,0,0,500}],
                           [{triangle,0,2,1}]}}],
    [{atom_to_list(Name),{timeout,60,fun() ->
        with_world(fun(F = #{namespace := Ns,node := Principal}) ->
            {Pid,World} = enable(F),
            #{World := #{spec := Spec}} = worlds(Ns), Fence = quod_physics:fence(Spec),
            Expected = #{fence => Fence,structure => 1,tick => -1},
            {ok,Before,_} = quod_physics:snapshot(Pid,Expected),
            {2,1,world,_,Rotation,_} = lists:keyfind(2,1,maps:get(poses,Before)),
            Move = {physics_move_body,room,2,1,1,{vector,4000,3000,0}},
            ?assertMatch({ok,_,{normalized,{failed,_}}},door_action(Ns,Move)),
            commit(Ns,{assertz,{can_edit_physics,room,Principal}}),
            MoveResult = door_action(Ns,Move),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},MoveResult),
            {Pid,World} = installed(Ns),
            {ok,After,#{installs := Installs}} = quod_physics:snapshot(Pid,Expected#{structure => 2}),
            {2,2,world,Position,Rotation,_} = lists:keyfind(2,1,maps:get(poses,After)),
            ?assertEqual({4.0,3.0,0.0},Position),
            ?assertEqual({error,unavailable},quod_physics:snapshot(Pid,Expected)),
            ?assertMatch({ok,_,{normalized,{failed,_}}},door_action(Ns,Move)),
            await_source_receipt(MoveResult),
            assert_no_physics_io(fun() ->
                reconcile(Ns), reconcile(Ns),
                ?assertMatch(#{installs := Installs},gen_server:call(Pid,status))
            end)
        end,fun(Rules) -> [case Rule of
            {physics_body_definition, room, 2, 1, _, _, {owned, _, _}} ->
                {physics_body_definition, room, 2, 1, Kind, {pose,{vector,0,3000,0},{rotation,0,250,0}}, {owned, Shape, 1}};
            {physics_allowances,W,Limits,Step,_,Budget} ->
                {physics_allowances,W,Limits,Step,0,Budget};
            _ -> Rule
        end || Rule <- Rules] end)
    end}} || {Name,Kind,Shape} <- Shapes].

invalid_geometry_signed_edit_leaves_state_unchanged_test_() ->
    Surface = {surface,[{vector,0,0,0},{vector,500,0,0},{vector,0,0,500}],[{triangle,0,1,2}]},
    Invalid = [{dynamic,Surface}, {controlled,Surface}, {fixed,{box,0,500,500}},
        {fixed,{ball,1000001}}, {fixed,{capsule,0,100}}, {fixed,{parts,[]}},
        {fixed,{parts,[{part,{vector,0,0,0},Surface}]}},
        {fixed,{parts,[{part,{pose,{vector,0,0,0},{rotation,bad,0,0}},{ball,100}}]}},
        {fixed,{convex,[{vector,0,0,0},{vector,500,0,0},{vector,0,0,500}]}},
        {fixed,setelement(3,Surface,[{triangle,0,1,3}])},
        {fixed,setelement(3,Surface,[{triangle,0,1,1}])}],
    {timeout,60,fun() -> with_world(fun(#{namespace := Ns,node := Principal}) ->
        commit(Ns,{assertz,{can_edit_physics,room,Principal}}),
        lists:foreach(fun({Kind,Shape}) ->
            Body = {physics_body_definition, room, 2, 1, Kind, {vector,0,3000,0}, {owned, Shape, 1}},
            commit(Ns,{',',{retract,{physics_body_definition, room, 2, {'_'}, {'_'}, {'_'}, {owned, {'_'}, {'_'}}}},
                          {assertz,Body}}),
            Height = quod_prolog:applied(Ns),
            assert_reason({invalid_physics_body,2},door_action(Ns,
                {physics_move_body,room,2,1,1,{vector,4000,3000,0}})),
            ?assertEqual(Height,quod_prolog:applied(Ns)),
            ?assertMatch({ok,[_],Height},quod_prolog:prove_ro(Ns,{',',Body,{physics_structure,room,1}})),
            ?assertEqual(#{},worlds(Ns))
        end,Invalid)
    end) end}.

numeric_geometry_and_hinge_refusals_test_() ->
    {timeout,60,fun() -> with_door(fun(#{namespace := Ns}) ->
        %% The envelope protects the existing integer-to-double conversion before
        %% unit division. Policy range failures below remain a separate refusal.
        {ok,[#{'NativeMax' := Max}],_} = quod_prolog:prove_ro(Ns,
            {physics_native_scalar_limit,{'NativeMax'}}),
        ?assertEqual(((1 bsl 53)-1) bsl 971,Max),
        [?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_milli_integer,X}))
            || X <- [-Max,0,Max]],
        [?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{physics_milli_integer,X}))
            || X <- [-Max-1,Max+1]],
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_positive_scalar,Max})),
        ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{physics_positive_scalar,Max+1})),
        ?assertEqual(1.7976931348623157e308,float(Max)),
        ?assert(is_float(Max/1000)), ?assert(is_float(-Max/1000000)),
        %% Max+1 still rounds to Max; test actual conversion overflow separately.
        ?assertError(badarith,(Max+(1 bsl 971))/1000),
        Huge = 1 bsl 2048,
        Position = {vector,0,3000,0}, Shape = {box,500,500,500},
        Bodies = [{physics_body_definition, room, 2, 1, fixed, Position, {owned, Shape, Huge}},
            {physics_body_definition, room, 2, 1, fixed, {pose,Position,{rotation,0,Huge,0}}, {owned, Shape, 1}},
            {physics_body_definition, room, 2, 1, fixed, Position, {owned, {parts,[{part,{vector,1000001,0,0},{ball,100}}]}, 1}},
            {physics_body_definition, room, 18446744073709551616, 1, fixed, Position, {owned, Shape, 1}}],
        lists:foreach(fun(Body) ->
            commit(Ns,{assertz,Body}), Height = quod_prolog:applied(Ns), Id = element(3,Body),
            assert_reason({invalid_physics_body,Id},door_action(Ns,
                {physics_move_body,room,Id,1,2,{vector,4000,3000,0}})),
            ?assertEqual(Height,quod_prolog:applied(Ns)), commit(Ns,{retract,Body})
        end,Bodies),
        Body = {physics_body_definition, room, 2, 1, fixed, Position, {owned, Shape, 1}}, commit(Ns,{assertz,Body}),
        BeforeRange = quod_prolog:applied(Ns),
        assert_reason({coordinate_allowance,1000000},door_action(Ns,
            {physics_move_body,room,2,1,2,{vector,1000001,3000,0}})),
        ?assertEqual(BeforeRange,quod_prolog:applied(Ns)), commit(Ns,{retract,Body}),
        lists:foreach(fun({Name,Recipe,Reason}) ->
            commit(Ns,{assertz,{physics_hinged_class,Name,1,Recipe}}),
            Height = quod_prolog:applied(Ns),
            assert_reason(Reason,door_action(Ns,
                {physics_add_hinged,room,12,13,{local,Name,1},Position,2})),
            ?assertEqual(Height,quod_prolog:applied(Ns)),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_next_body,room,12}))
        end,[{zero_axis,setelement(5,hinged_recipe(),{vector,0,0,0}),invalid_hinge_definition},
             {wide_arc,setelement(7,hinged_recipe(),{limits,-2500,2500}),invalid_hinge_definition},
             {outside_target,setelement(9,hinged_recipe(),hinged_command(2000)),invalid_hinge_command}]),
        commit(Ns,{assertz,{physics_hinged_class,non_box,1,setelement(3,hinged_recipe(),{ball,500})}}),
        Pose = {pose,Position,{rotation,0,250,0}},
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
            {physics_add_hinged,room,12,13,{local,non_box,1},Pose,2})),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
            {physics_body_definition,room,12,3,dynamic,Pose,{owned,{ball,500},1}})),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
            {physics_move_hinged,room,10,0,3,Pose})),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
            {physics_body_definition,room,10,4,dynamic,Pose,{owned,{box,1000,1000,100},1}})),
        ?assertEqual(#{},worlds(Ns))
    end,false) end}.

native_hinge_revision_and_restore_validation_test() ->
    Frame = {1,1,fixed,{{5.0,0.0,0.0},{0.0,0.25,0.0}},{solid,{box,0.05,1.0,0.05}},1.0},
    Moving = {2,3,dynamic,{{5.0,0.0,0.0},{0.0,0.25,0.0}},{solid,{ball,0.5}},1.0},
    Hinge = {{2,3},7,{1,1},{0.0,1.0,0.0},{{0.0,1.0,0.0},{-1.0,0.0,0.0}},{-1.5,1.5},1.5},
    lists:foreach(fun({Definition,Restore,Reason}) ->
        {ok,R} = quod_physics_native:new_world({2,2,4,100.0,2,0,0},1/60,0.0),
        try
            ?assertEqual({ok,2},quod_physics_native:install(R,[Frame,Moving])),
            ?assertEqual({error,Reason},quod_physics_native:install_hinges(R,[{Definition,Restore}])),
            ?assertEqual({error,retired},quod_physics_native:sample(R))
        after quod_physics_native:retire(R) end
    end,[{setelement(3,Hinge,{1,2}),1.5,invalid_hinge},
         {setelement(4,Hinge,{0.0,0.0,0.0}),1.5,invalid_hinge},
         {Hinge,2.0,invalid_hinge},
         {setelement(5,Hinge,{{100.0,0.0,0.0},{-10.0,0.0,0.0}}),0.0,coordinate_allowance}]),
    {ok,Valid} = quod_physics_native:new_world({2,2,4,100.0,2,0,0},1/60,0.0),
    try
        {ok,2} = quod_physics_native:install(Valid,[Frame,Moving]),
        ?assertEqual({ok,1},quod_physics_native:install_hinges(Valid,[{Hinge,1.5}])),
        ?assertEqual({ok,[{2,1500,false}]},quod_physics_native:hinge_samples(Valid)),
        ?assertEqual({error,stale_revision},quod_physics_native:control_hinge(Valid,2,6,hold)),
        ?assertEqual({error,retired},quod_physics_native:sample(Valid))
    after quod_physics_native:retire(Valid) end.

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
                commit(Ns, {',', {retract, {physics_body_definition, room, 2, 1, dynamic, {vector,0,3000,0}, {owned, {box,500,500,500}, 1}}},
                  {',', {assertz, {physics_body_definition, room, 2, 2, dynamic, {vector,0,5000,0}, {owned, {box,500,500,500}, 1}}},
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

system_physics_world_policy_test_() ->
    [{binary_to_list(Ns), {timeout, 60, fun() ->
        with_world(Ns, fun(F = #{node := Principal}) ->
            {ok, [#{'Manifest' := Manifest}], _} = quod_prolog:prove_ro(
                Ns, {external_predicate_modules, {'Manifest'}}),
            ?assertNot(lists:keymember(quod_physics_predicates, 1, Manifest)),
            ?assertEqual(#{}, worlds(Ns)),
            {Pid, World} = enable(F),
            ?assertEqual({world_ref, Ns, quod_simplex:genesis_hash(Ns), room}, World),
            #{World := #{spec := #{gravity := InstalledGravity}}} = worlds(Ns),
            ?assertEqual(Gravity / 1000, InstalledGravity),
            Goal = {physics_body_state, room, 1, {0}},
            ?assertMatch({ok, _, {normalized,{read,_,{failed, _}}}}, body_read(Ns, Goal)),
            case Permission of
                allowed ->
                    commit(Ns, {assertz, {can_read_physics_body, room, Principal, 1}}),
                    ?assertMatch({ok, _, {normalized,{read,_,{answers, _, [_]}}}}, body_read(Ns, Goal));
                denied ->
                    commit(Ns, {assertz, {can_read_physics_body, another_space, Principal, 1}}),
                    ?assertMatch({ok, _, {normalized,{read,_,{failed, _}}}}, body_read(Ns, Goal))
            end,
            %% A real instance-property edit reaches the retained resource selector.
            %% Gravity requires a replacement run; the world identity stays fixed.
            Monitor = monitor(process, Pid),
            commit(Ns, {',', {retract, {attribute, room, gravity, Gravity}},
                             {assertz, {attribute, room, gravity, 0}}}),
            receive {'DOWN', Monitor, process, Pid, _} -> ok
            after 10000 -> error(gravity_change_did_not_retire_run) end,
            {Replacement, World} = installed(Ns),
            ?assertNotEqual(Pid, Replacement),
            #{World := #{spec := #{gravity := 0.0}}} = worlds(Ns),
            ?assertMatch({ok, [_], _}, quod_prolog:prove_ro(
                Ns, {external_predicate_modules, Manifest}))
        end, fun(Rules) ->
            [case Rule of
                 {physics_allowances, room, Limits, Step, _, Budget} ->
                     {':-', {physics_allowances, {'W'}, Limits, Step, {'G'}, Budget},
                            {attribute, {'W'}, gravity, {'G'}}};
                 _ -> Rule
             end || Rule <- Rules] ++ [{attribute, room, gravity, Gravity}]
        end)
    end}} || {Ns, Gravity, Permission} <-
        [{<<"physics-policy-earth">>, -9800, allowed},
         {<<"physics-policy-moon">>, -1620, denied}]].

signed_live_body_predicate_test_() ->
    {timeout,60,fun() -> with_world(fun(F = #{namespace := Ns,node := Human}) ->
        {Pid,World} = enable(F),
        Goal = {physics_body_state,room,1,{0}},
        commit(Ns,{assertz,{can_invoke,{physics_body_state,{'_'},{'_'},{'_'}},Human,{'_'},Ns}}),
        ?assertMatch({ok,_,{normalized,{read,_,{failed,_}}}},body_read(Ns,Goal)),
        commit(Ns,{assertz,{can_read_physics_body,room,Human,1}}),
        #{World := #{spec := Spec}} = worlds(Ns),
        Expected = #{fence => quod_physics:fence(Spec),structure => 1,
                     incarnation => maps:get(run_token,Spec)},
        ?assertMatch({ok,_,{1,1,world,_,_,_}},quod_physics:body_state(Pid,Expected,{1,1},1000)),
        ?assertMatch({ok,_,{normalized,{read,_,{answers,_,[_]}}}},body_read(Ns,Goal)),
        #{installs := Installs,queries := Queries} = gen_server:call(Pid,status),
        assert_no_physics_io(fun() ->
            [?assertMatch({ok,_,{normalized,{read,_,{answers,_,[_]}}}},body_read(Ns,Goal))
             || _ <- lists:seq(1,3)]
        end),
        ?assertMatch(#{installs := Installs,queries := Q} when Q =:= Queries+3,
                     gen_server:call(Pid,status)),
        ?assertEqual({error,unavailable},quod_physics:body_state(Pid,Expected#{structure => 0},{1,1},1000)),
        ?assertEqual({error,unavailable},quod_physics:body_state(Pid,Expected,{1,0},1000)),
        ?assertEqual({error,unavailable},quod_physics:body_state(Pid,Expected#{incarnation => <<0:256>>},{1,1},1000)),
        %% Even a world invocation grant cannot manufacture the private handle.
        commit(Ns,{assertz,{can_invoke,{'$quod_sample_physics',{'_'},{'_'},{'_'},{'_'},{'_'},{'_'}},Human,{'_'},Ns}}),
        Frame = {physics_frame,World,maps:get(authority,Spec),maps:get(epoch,Spec),
                 maps:get(generation,Spec),maps:get(run_token,Spec),1},
        ?assertMatch({ok,_,{normalized,{read,_,{error,_}}}},
                     body_read(Ns,{'$quod_sample_physics',forged,{physics_body_state,room,1},Frame,1,none,{0}})),
        commit(Ns,{retract,{can_read_physics_body,room,Human,1}}),
        ?assertMatch({ok,_,{normalized,{read,_,{failed,_}}}},body_read(Ns,Goal))
    end) end}.

body_read(Ns,Goal) ->
    {ok,Bytes,Signature} = quod_node_actor:signed_goal(read,{'::',Ns,Goal},
        crypto:strong_rand_bytes(32),quod_time:now_ms()+10000),
    quod_client_goal_ingress:submit(Bytes,Signature).

assert_reason(Reason,{ok,E,{normalized,{read,_,Outcome}}}) ->
    assert_reason(Reason,{ok,E,{normalized,Outcome}});
assert_reason(Reason,{ok,_,{normalized,{failed,Blob}}}) ->
    {ok,Reasons} = quod_wire_term:decode_failure_reasons(Blob),
    ?assert(lists:member(Reason,Reasons)).

assert_reason_count(Reason, Count, {ok,E,{normalized,{read,_,Outcome}}}) ->
    assert_reason_count(Reason,Count,{ok,E,{normalized,Outcome}});
assert_reason_count(Reason, Count, {ok,_,{normalized,{failed,Blob}}}) ->
    {ok,Reasons} = quod_wire_term:decode_failure_reasons(Blob),
    ?assertEqual(Count,length([R || R <- Reasons,R =:= Reason])).

input_admission_reasons_test_() ->
    {timeout,60,fun() -> with_chair(fun(F = #{namespace := Ns}) ->
        {Pid,World} = enable(F), Limits = {query_limits,2,0,8,128},
        {_,Expected,Frame,_,_} = install_test_control(F,Pid,World,
            {motion,free,2000,1600,1000,Limits,[]}),
        {control_frame,_,Registration} = Frame,
        Installed = Expected#{registration => Registration}, Control = maps:get(control,Expected),
        Input = {{push,{body,3,1},{vector,1000,0,0}},{push_limits,3,1,5000,5000}},
        Request = fun(E,C,S,I,X,D) -> {physics_input,E,C,S,I,X,D} end,
        Expiry = quod_time:now_ms()+5000, Deadline = quod_time:mono_ms()+5000,
        Call = fun(E,C,S,I,X,D) -> gen_server:call(Pid,Request(E,C,S,I,X,D)) end,
        [?assertEqual({error,{stale_projection,1}},Call(E,Control,1,Input,Expiry,Deadline)) || E <-
            [Installed#{fence => stale},Installed#{structure => 0},Installed#{incarnation => <<0:256>>}]],
        ?assertEqual({error,control_not_installed},Call(Installed,setelement(3,Control,2),1,Input,Expiry,Deadline)),
        ?assertEqual({error,control_not_installed},Call(Installed,Control,1,
            {element(1,Input),{push_limits,3,1,6000,5000}},Expiry,Deadline)),
        ?assertEqual({error,stale_registration},Call(Installed#{registration => <<0:256>>},Control,1,Input,Expiry,Deadline)),
        ?assertEqual({error,expired},Call(Installed,Control,1,Input,quod_time:now_ms()-1,Deadline)),
        ?assertEqual({error,expired},Call(Installed,Control,1,Input,Expiry,quod_time:mono_ms()-1)),
        %% Both calls precede the owner's self-scheduled step. Response delivery
        %% proves processing; no sleep, polling or send trace selects this race.
        ok = sys:suspend(Pid),
        A = gen_server:send_request(Pid,Request(Installed,Control,1,Input,Expiry,Deadline)),
        B = gen_server:send_request(Pid,Request(Installed,Control,2,Input,Expiry,Deadline)),
        ok = sys:resume(Pid),
        ?assertEqual({reply,ok},gen_server:receive_response(A,5000)),
        ?assertEqual({reply,{error,discrete_pending}},gen_server:receive_response(B,5000)),
        ?assertEqual({error,{stale_sequence,1}},Call(Installed,Control,1,Input,Expiry,Deadline)),
        #{World := #{spec := #{navigation_guard := {Guard,G}}}} = worlds(Ns),
        atomics:put(Guard,1,G+1),
        try ?assertEqual({error,reinstalling},Call(Installed,Control,2,Input,Expiry,Deadline))
        after atomics:put(Guard,1,G) end
    end) end}.

hot_control_policy_reasons_test_() ->
    {timeout,90,fun() -> with_chair(fun(F = #{namespace := Ns,node := Human}) ->
        {Pid,World} = enable(F),
        {Definition,_,Frame,_,_} = install_test_control(F,Pid,World,
            {motion,free,2000,1600,1000,{query_limits,2,0,8,128},[]}),
        Runtime = quod_reg:where({quod_runtime,Ns}), ok = sys:suspend(Runtime),
        try
        assert_reason_count({ambiguous_control,room},0,body_read(Ns,
            {physics_control_state,room,Human,99,{0}})),
        assert_reason_count({ambiguous_agent,pilot},0,body_read(Ns,
            {physics_agent_configuration,room,Human,pilot,eye,setelement(3,Definition,99)})),
        Go = {physics_control_input,room,Frame,1,1,{drive,{vector,0,0,0},{angular,0,0,0}},{0}},
        [begin
            {ok,_,{normalized,{failed,Reasons}}} = control_goal({'::',Ns,setelement(6,Go,Input)}),
            {ok,Decoded} = quod_wire_term:decode_failure_reasons(Reasons),
            ?assertEqual([],[R || R = {coordinate_allowance,_} <- Decoded])
        end || Input <- [{drive,{vector,2001,0,0},{angular,0,0,0}},
                         {drive,{vector,0,0,0},{angular,0,1601,0}},
                         {push,{body,3,1},{vector,5001,0,0}}]],
        Checkpoint = {physics_checkpoint_body,room,3,1,0,<<209:256>>},
        assert_reason({control_conflict,1},door_action(Ns,{physics_control_agent,room,0,none,none})),
        Other = {agent_instance_ref,<<"other">>,<<99:256>>,someone},
        commit(Ns,{assertz,{physics_control,room,Other,1,{controlled,pilot,eye}}}),
        assert_reason({agent_controlled,pilot},door_action(Ns,
            {physics_control_agent,room,1,{controlled,pilot,eye},{controlled,pilot,eye}})),
        commit(Ns,{retract,{physics_control,room,Other,1,{controlled,pilot,eye}}}),
        Agent = {physics_agent,room,pilot,1,2,element(6,Definition)},
        Mount = {physics_viewpoint,room,pilot,eye,2,element(3,element(7,Definition)),element(4,element(7,Definition))},
        Body = {physics_body_definition, room, 2, 1, controlled, {vector,-3000,1000,0}, {owned, {box,500,1000,500}, 1}},
        [?assertEqual(ok,begin
            commit(Ns,{'$quod_retract_exact',Fact}),
            ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,Fact)),
            Result = control_goal({'::',Ns,Go}),
            case Result of
                {ok,_,{normalized,{failed,_}}} -> assert_reason({ambiguous_agent,pilot},Result);
                _ -> error({missing_configuration_accepted,Fact,redact(brief(Result))})
            end,
            commit(Ns,{assertz,Fact}),ok end) || Fact <- [Agent,Mount,Body]],
        Ambiguous = setelement(4,Agent,2),
        commit(Ns,{assertz,Ambiguous}),
        assert_reason({ambiguous_agent,pilot},control_goal({'::',Ns,Go})),
        commit(Ns,{'$quod_retract_exact',Ambiguous}),
        commit(Ns,{retract,{physics_control,room,Human,1,{controlled,pilot,eye}}}),
        assert_reason({no_control,room},control_goal({'::',Ns,Go})),
        assert_reason_count({no_control,room},1,control_goal({'::',Ns,
            setelement(6,Go,{push,{body,3,1},{vector,1000,0,0}})})),
        commit(Ns,{assertz,{physics_control,room,Human,1,{controlled,pilot,eye}}}),
        DuplicateControl = {physics_control,room,Human,2,none},
        commit(Ns,{assertz,DuplicateControl}),
        assert_reason({ambiguous_control,room},control_goal({'::',Ns,Go})),
        commit(Ns,{retract,DuplicateControl}),
        assert_reason({body_not_free,3},door_action(Ns,setelement(4,Checkpoint,0))),
        RestPolicy = {physics_rest_policy,room,3,{recovery,5,128}},
        commit(Ns,{retract,RestPolicy}),
        assert_reason({rest_policy_missing,3},door_action(Ns,Checkpoint)),
        commit(Ns,{assertz,RestPolicy}),
        Waiting = {physics_rest,room,3,1,{waiting,{rest,1,<<210:256>>}}},
        commit(Ns,{assertz,Waiting}),
        assert_reason_count({ambiguous_checkpoint,3},0,body_read(Ns,
            {physics_rest_state,room,3,99,{0}})),
        assert_reason({checkpoint_pending,3},door_action(Ns,setelement(5,Checkpoint,1))),
        assert_reason({checkpoint_conflict,3},door_action(Ns,Checkpoint)),
        OtherWaiting = setelement(5,Waiting,idle),
        commit(Ns,{assertz,OtherWaiting}),
        assert_reason({ambiguous_checkpoint,3},door_action(Ns,Checkpoint)),
        commit(Ns,{retract,OtherWaiting}), commit(Ns,{retract,Waiting}),
        {ok,HeldBytes,HeldSignature} = quod_node_actor:signed_goal(execute,
            {'::',Ns,{assertz,{held_checkpoint,1}}},crypto:strong_rand_bytes(32),quod_time:now_ms()+10000),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},quod_client_goal_ingress:submit(HeldBytes,HeldSignature)),
        Held = {physics_rest_request,room,3,{request,held,rest,HeldBytes,HeldSignature}},
        commit(Ns,{assertz,Held}),
        assert_reason_count({ambiguous_checkpoint_custody,3},0,body_read(Ns,
            {physics_rest_custody,room,3,none})),
        assert_reason({checkpoint_custody_held,3},door_action(Ns,Checkpoint)),
        OtherHeld = setelement(4,Held,{request,other,rest,HeldBytes,HeldSignature}),
        commit(Ns,{assertz,OtherHeld}),
        assert_reason({ambiguous_checkpoint_custody,3},door_action(Ns,Checkpoint)),
        commit(Ns,{retract,OtherHeld}), commit(Ns,{retract,Held}),
        PushPolicy = {physics_push_allowances,room,{'_'},3,{push_limits,5000,5000}},
        commit(Ns,{'$quod_retract_exact',PushPolicy}),
        assert_reason({push_allowances_missing,3},control_goal({'::',Ns,
            setelement(6,Go,{push,{body,3,1},{vector,1000,0,0}})})),
        commit(Ns,{assertz,PushPolicy}),
        SmallPush = {physics_push_allowances,room,{'_'},3,{push_limits,1,5000}},
        commit(Ns,{asserta,SmallPush}),
        ?assertMatch({ok,_,{normalized,{read,_,{answers,_,[_]}}}},body_read(Ns,{',',
            {physics_push_configuration,room,Human,3,1,{0},5000},
            {'>',{0},1000}})),
        commit(Ns,{'$quod_retract_exact',SmallPush}),
        commit(Ns,{assertz,{can_query_physics_motion,room,Human,2,{'_'}}}),
        Query = {physics_motion_query,room,2,{travel,{vector,1,0,0},{angular,0,0,0}},{0}},
        assert_reason({query_allowances_missing,room},body_read(Ns,Query)),
        QueryPolicy = {physics_query_allowances,room,Human,{query_allowances,2,0,8,128,1,1000}},
        commit(Ns,{',',{assertz,QueryPolicy},
            {assertz,setelement(4,QueryPolicy,{query_allowances,2,0,8,128,2000,1000})}}),
        ?assertMatch({ok,_,{normalized,{read,_,{answers,_,[_]}}}},body_read(Ns,
            setelement(4,Query,{travel,{vector,1000,0,0},{angular,0,0,0}}))),
        {ok,_,{normalized,{read,_,{failed,QueryReasons}}}} = body_read(Ns,
            setelement(4,Query,{travel,{vector,2001,0,0},{angular,0,0,0}})),
        {ok,DecodedQueryReasons} = quod_wire_term:decode_failure_reasons(QueryReasons),
        ?assertEqual([],[R || R = {coordinate_allowance,_} <- DecodedQueryReasons]),
        Allowances = {physics_allowances,room,{limits,64,64,256,1000000,{geometry,256,4096,4096}},16667,-9810,10000},
        commit(Ns,{retract,Allowances}),
        commit(Ns,{',',{assertz,{can_view_physics,room,Human}},{assertz,{world_view,room,playing,[]}}}),
        assert_view_selection(unavailable,body_read(Ns,{client_world_view,room,playing,[],{0}}))
        after sys:resume(Runtime) end
    end) end}.

hot_control_error_and_owner_results_test_() ->
    {timeout,90,fun() -> with_chair(fun(F = #{namespace := Ns,node := Human}) ->
        {Pid,World} = enable(F),
        {Definition,_,ControlFrame,_,_} = install_test_control(F,Pid,World,
            {motion,free,2000,1600,1000,{query_limits,2,0,8,128},[]}),
        {control_frame,Frame,_} = ControlFrame,
        Drive = {drive,{vector,0,0,0},{angular,0,0,0}},
        Go = {physics_control_input,room,ControlFrame,1,1,Drive,{0}},
        Read = {physics_body_state,room,1,{0}},
        commit(Ns,{assertz,{can_read_physics_body,room,Human,1}}),
        [?assertMatch({ok,_,{normalized,{read,_,{error,_}}}},body_read(Ns,Goal)) || Goal <-
            [{physics_body_state,room,{0},{1}}, {physics_body_state,room,bad_body,{0}},
             {physics_body_state,room,-1,{0}},
             {physics_motion_query,room,1,{0},{1}},
             {'$quod_sample_physics',forged,{physics_body_state,room,1},Frame,1,none,{0}}]],
        ?assertMatch({ok,_,{normalized,{error,_}}},control_goal({'::',Ns,setelement(6,Go,{0})})),
        ?assertMatch({ok,_,{normalized,{error,_}}},door_action(Ns,Read)),
        ?assertMatch({ok,_,{normalized,{read,_,{error,_}}}},body_read(Ns,Go)),
        ?assertMatch({ok,_,{normalized,{error,_}}},door_action(Ns,Go)),
        ?assertMatch({ok,_,{normalized,{error,_}}},control_goal({'::',Ns,
            {'$quod_stage_physics_input',forged,Go,none,500,{query_limits,2,0,8,128},{0}}})),
        Runtime = quod_reg:where({quod_runtime,Ns}), ok = sys:suspend(Runtime),
        try
            %% Authored policy return values still cross the real opaque handle.
            remove_physics_policy(Ns,physics_body_read_projection),
            Policy = fun(Fence,Revision) -> {physics_body_read_projection,room,1,Fence,Revision} end,
            Bad = Policy(invalid_frame,1), commit(Ns,{assertz,Bad}),
            ?assertMatch({ok,_,{normalized,{read,_,{error,_}}}},body_read(Ns,Read)),
            commit(Ns,{retract,Bad}), WrongWorld = setelement(2,Frame,setelement(4,World,other)),
            Wrong = Policy(WrongWorld,1), commit(Ns,{assertz,Wrong}),
            ?assertMatch({ok,_,{normalized,{read,_,{error,_}}}},body_read(Ns,Read)),
            commit(Ns,{retract,Wrong}), BadRevision = Policy(Frame,0), commit(Ns,{assertz,BadRevision}),
            ?assertMatch({ok,_,{normalized,{read,_,{error,_}}}},body_read(Ns,Read)),
            commit(Ns,{retract,BadRevision}), MissingSample = Policy(Frame,2), commit(Ns,{assertz,MissingSample}),
            %% Missing body/revision is an explicit sample answer, not owner loss.
            {ok,_,{normalized,{read,_,{answers,_,[SampleBinding]}}}} = body_read(Ns,Read),
            {ok,SamplePairs} = quod_client_result:decode_binding(SampleBinding),
            ?assertEqual([unavailable],[Value || {_,Value} <- SamplePairs]),
            commit(Ns,{retract,MissingSample}), commit(Ns,{assertz,Policy(Frame,1)}),
            remove_physics_policy(Ns,physics_input_projection),
            Projection = fun(Lease,Limits) -> {physics_input_projection,room,ControlFrame,1,1,Drive,
                {control,Human,1,Definition},Lease,Limits} end,
            BadLease = Projection(0,{query_limits,2,0,8,128}), commit(Ns,{assertz,BadLease}),
            ?assertMatch({ok,_,{normalized,{error,_}}},control_goal({'::',Ns,Go})),
            commit(Ns,{retract,BadLease}), BadLimits = Projection(500,invalid_limits), commit(Ns,{assertz,BadLimits}),
            ?assertMatch({ok,_,{normalized,{error,_}}},control_goal({'::',Ns,Go})),
            commit(Ns,{retract,BadLimits}), commit(Ns,{assertz,Projection(500,{query_limits,2,0,8,128})}),
            gen_server:stop(Pid),
            assert_reason({physics_world_unavailable,room},body_read(Ns,Read)),
            assert_reason({physics_world_unavailable,room},control_goal({'::',Ns,Go})),
            Reader = refusing_test_owner(World,read),
            NameMonitor = quod_reg:monitor_name({physics_world,World},info),
            assert_reason({physics_owner_unavailable,room},body_read(Ns,Read)),
            receive {test_owner_called,Reader,read} -> ok after 5000 -> error(owner_not_called) end,
            receive {gproc,unreg,NameMonitor,_} -> ok after 5000 -> error(owner_name_not_retired) end,
            Releaser = refusing_test_owner(World,release),
            ?assertMatch({ok,_,{normalized,{error,_}}},control_goal({'::',Ns,Go})),
            receive {test_owner_called,Releaser,release} -> ok after 5000 -> error(release_not_called) end,
            receive {test_owner_called,Releaser,_} -> error(uncertain_release_repeated) after 0 -> ok end
        after sys:resume(Runtime) end
    end) end}.

remove_physics_policy(Ns,Functor) ->
    [commit(Ns,{'$quod_retract_exact',Rule}) || Rule = {':-',Head,_} <-
        quod_prolog:read_terms("priv/ontologies/quod_physics.pl"),element(1,Head) =:= Functor],ok.

%% A controlled owner disappearance tests the lost-reply production seam.
refusing_test_owner(World,Mode) ->
    Parent = self(), {Pid,Monitor} = spawn_monitor(fun() ->
        true = quod_reg:reg({physics_world,World}), Parent ! {test_owner_ready,self()},
        receive {'$gen_call',_,_Request} -> Parent ! {test_owner_called,self(),Mode} end
    end),
    receive {test_owner_ready,Pid} -> ok after 5000 -> error(test_owner_not_registered) end,
    erlang:demonitor(Monitor,[flush]), Pid.

signed_motion_query_owner_test_() ->
    {timeout,60,fun() -> with_world(fun(F = #{namespace := Ns,node := Human}) ->
        {Pid,World} = enable(F),
        Goal = {physics_motion_query,room,2,{travel,{vector,5000,0,2000},{angular,0,0,0}},{0}},
        commit(Ns,{',',{assertz,{can_invoke,{physics_motion_query,{'_'},{'_'},{'_'},{'_'}},Human,{'_'},Ns}},
            {assertz,{physics_query_allowances,room,Human,{query_allowances,2,0,8,128,20000,3141}}}}),
        ?assertMatch({ok,_,{normalized,{read,_,{failed,_}}}},body_read(Ns,Goal)),
        commit(Ns,{assertz,{can_query_physics_motion,room,Human,2,{'_'}}}),
        ?assertMatch({ok,_,{normalized,{read,_,{answers,_,[_]}}}},body_read(Ns,Goal)),
        %% A write-mode proof cannot use a live query to admit a durable edit.
        ?assertMatch({ok,_,{normalized,{error,_}}},door_action(Ns,Goal)),
        #{World := #{spec := Spec}} = worlds(Ns),
        Expected = #{fence => quod_physics:fence(Spec),structure => 1,
                     incarnation => maps:get(run_token,Spec)},
        Query = {travel,{vector,5000,0,2000},{angular,0,0,0}},
        Limits = {query_limits,2,0,8,128},
        {ok,_,{clipped,{{X,_,Z},_},_,_}} = quod_physics:motion_query(Pid,Expected,{2,1},Query,Limits,1000),
        ?assert(X < 1.4 andalso X > 1.39), ?assert(abs(Z-2.0) < 0.001),
        {ok,_,Before} = quod_physics:body_state(Pid,Expected,{2,1},1000),
        assert_no_physics_io(fun() ->
            [?assertMatch({ok,_,{normalized,{read,_,{answers,_,[_]}}}},body_read(Ns,Goal)) || _ <- lists:seq(1,3)]
        end),
        ?assertMatch({ok,_,Before},quod_physics:body_state(Pid,Expected,{2,1},1000)),
        ?assertMatch({ok,_,{occupied,3,_}},quod_physics:motion_query(Pid,Expected,{2,1},
            {place,{pose,{vector,2000,1002,0},{rotation,0,0,0}}},Limits,1000)),
        ?assertMatch({ok,_,exhausted},quod_physics:motion_query(Pid,Expected,{2,1},Query,{query_limits,2,0,8,1},1000)),
        ?assertMatch({ok,_,unavailable},quod_physics:motion_query(Pid,Expected,{2,0},Query,Limits,1000)),
        ?assertMatch({error,unavailable},quod_physics:motion_query(Pid,Expected#{structure => 0},{2,1},Query,Limits,1000)),
        ?assertMatch({ok,_,{normalized,{read,_,{answers,_,[_]}}}},body_read(Ns,Goal)),
        commit(Ns,{retract,{can_query_physics_motion,room,Human,2,{'_'}}}),
        ?assertMatch({ok,_,{normalized,{read,_,{failed,_}}}},body_read(Ns,Goal))
    end,fun(Rules) ->
        [case Rule of
            {physics_body_definition, room, 2, 1, _, _, {owned, _, _}} ->
                {physics_body_definition, room, 2, 1, controlled, {vector,0,1002,0}, {owned, {box,500,1000,500}, 1}};
            _ -> Rule
        end || Rule <- Rules] ++
        [{physics_body_definition, room, 3, 1, fixed, {vector,2000,2000,0}, {owned, {box,100,3000,10000}, 1}}]
    end) end}.

signed_control_releases_only_successful_proof_test_() ->
    {timeout,60,fun() -> with_world(fun(F = #{namespace := Ns,node := Human}) ->
        {Pid,World} = enable(F),
        Limits = {query_limits,2,0,8,128},
        {_,Expected,Frame,Ref,Initial} = install_test_control(F,Pid,World,
            {motion,free,2000,1600,500,Limits,[]}),
        Drive = {drive,{vector,2000,0,0},{angular,0,0,0}},
        {control_frame,_,Registration} = Frame,
        ?assertEqual({error,expired},gen_server:call(Pid,
            {physics_input,Expected#{registration => Registration},maps:get(control,Expected),1,
             {Drive,Limits},quod_time:now_ms()+500,quod_time:mono_ms()-1})),
        Command = fun(Seq,Input) -> {physics_control_input,room,Frame,1,Seq,Input,{0}} end,
        Go = Command(10,Drive),
        ?assertMatch({ok,_,{normalized,{read,_,{error,_}}}},body_read(Ns,Go)),
        ?assertMatch({ok,_,{normalized,{error,_}}},door_action(Ns,Go)),
        ?assertMatch({ok,_,{normalized,{failed,_}}},control_goal({'::',Ns,{',',Go,fail}})),
        ?assertMatch(#{inputs := M} when map_size(M) =:= 0,gen_server:call(Pid,status)),
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},control_goal(
            {';', {',',{'::',Ns,Go},fail},true})),
        ?assertMatch(#{inputs := M} when map_size(M) =:= 0,gen_server:call(Pid,status)),
        %% Negation and a cut followed by failure must restore the staged
        %% operation in another ontology's proof scope.
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},control_goal(
            {'\\+', {',',{'::',Ns,Go},fail}})),
        ?assertMatch({ok,_,{normalized,{failed,_}}},control_goal(
            {'::',Ns,{physics_test_cut,Go}})),
        ?assertMatch(#{inputs := M} when map_size(M) =:= 0,gen_server:call(Pid,status)),
        %% A control proof promises one indivisible live operation. A second
        %% staged command fails the entire proof rather than partially applying.
        assert_reason(transient_already_staged,control_goal(
            {'::',Ns,{',',Go,Command(11,Drive)}})),
        ?assertMatch(#{inputs := M} when map_size(M) =:= 0,gen_server:call(Pid,status)),
        quod_physics:ack(Pid,Ref,maps:get(tick,Initial)),
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},control_goal({'::',Ns,Go})),
        ?assertMatch(#{inputs := #{Human := #{sequence := 10}}},gen_server:call(Pid,status)),
        Moved = receive {physics_frame,Pid,Ref,V} -> V after 5000 -> error(control_did_not_move) end,
        {2,1,world,{X,_,_},_,_} = lists:keyfind(2,1,maps:get(poses,Moved)),
        ?assert(X > 0.0),
        assert_reason({stale_sequence,10},control_goal({'::',Ns,Go})),
        Stop = {drive,{vector,0,0,0},{angular,0,0,0}},
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},control_goal({'::',Ns,Command(11,Stop)})),
        assert_no_physics_io(fun() ->
            [?assertMatch({ok,_,{normalized,{answers,_,[_]}}},control_goal({'::',Ns,Command(Seq,Stop)}))
             || Seq <- lists:seq(12,14)]
        end),
        commit(Ns,{retract,{can_control_physics_agent,room,Human,pilot}}),
        {Pid,World} = installed(Ns),
        ?assertMatch(#{inputs := #{Human := #{sequence := 14,result := suspended}}},gen_server:call(Pid,status)),
        ?assertMatch({ok,_,{normalized,{failed,_}}},control_goal({'::',Ns,Command(15,Drive)})),
        commit(Ns,{assertz,{can_control_physics_agent,room,Human,pilot}}),
        {Pid,World} = installed(Ns),
        assert_reason(stale_registration,control_goal({'::',Ns,Go})),
        %% Even a higher-sequence command from the disconnected view cannot
        %% control its replacement registration.
        assert_reason(stale_registration,control_goal({'::',Ns,Command(100,Drive)})),
        {ok,FreshRef,FreshView} = quod_physics:watch(Pid,Expected,none),
        {control_frame,BaseFrame,_} = Frame,
        FreshFrame = {control_frame,BaseFrame,maps:get(registration,FreshView)},
        assert_reason(stale_registration,control_goal({'::',Ns,Command(100,Drive)})),
        FreshCommand = setelement(3,Command(15,Stop),FreshFrame),
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},control_goal({'::',Ns,FreshCommand})),
        quod_physics:unwatch(Pid,FreshRef)
    end,fun(Rules) -> [case R of
        {physics_body_definition, room, 2, 1, _, _, {owned, _, _}} ->
            {physics_body_definition, room, 2, 1, controlled, {vector,0,1002,0}, {owned, {box,500,1000,500}, 1}};
        _ -> R end || R <- Rules] ++
        [{':-',{physics_test_cut,{'Goal'}},
            {';',{',',{call,{'Goal'}},{',','!',fail}},true}}] end) end}.

install_test_control(F,Pid,World,Motion) -> install_test_control(F,Pid,World,Motion,2).
install_test_control(#{namespace := Ns,node := Human},Pid,World,Motion,Body) ->
    #{World := #{spec := Before}} = worlds(Ns),
    {Body,Revision,_,_,_,_} = lists:keyfind(Body,1,maps:get(bodies,Before)),
    View = {viewpoint,eye,{pose,{vector,0,100,0},{rotation,0,0,0}},{tracking,view_only,500}},
    Definition = {controlled_agent,pilot,1,Body,Revision,Motion,View},
    commit(Ns,{',',{assertz,{instance_of,agent,pilot}},
        {',',{assertz,{physics_agent,room,pilot,1,Body,Motion}},
        {',',{assertz,{physics_viewpoint,room,pilot,eye,Body,element(3,View),element(4,View)}},
        {',',{assertz,{can_control_physics_agent,room,Human,pilot}},
        {',',{assertz,{physics_control,room,Human,1,{controlled,pilot,eye}}},
             {assertz,{can_invoke,{'_'},Human,{'_'},Ns}}}}}}}),
    reconcile(Ns), {Pid,World} = installed(Ns),
    #{World := #{spec := Spec}} = worlds(Ns),
    Frame = {physics_frame,World,maps:get(authority,Spec),maps:get(epoch,Spec),
             maps:get(generation,Spec),maps:get(run_token,Spec),maps:get(structure,Spec)},
    Expected = #{fence => quod_physics:fence(Spec),incarnation => maps:get(run_token,Spec),
                 structure => maps:get(structure,Spec),control => {control,Human,1,Definition}},
    {ok,Ref,Initial} = quod_physics:watch(Pid,Expected,none),
    {Definition,Expected,{control_frame,Frame,maps:get(registration,Initial)},Ref,Initial}.

grounded_reinstall_and_wedge_settling_test_() ->
    [{atom_to_list(Terrain),{timeout,60,fun() -> with_world(fun(F = #{namespace := Ns,node := Human}) ->
        {Pid,World} = enable(F),
        Motion = {motion,{grounded,900},2000,1600,500,{query_limits,2,0,8,128},[]},
        {_,Expected,Frame,Ref,Initial} = install_test_control(F,Pid,World,Motion),
        %% Consume only already-delivered idle notices before issuing input.
        _ = gen_server:call(Pid,status), flush_sleeping(Pid),
        quod_physics:ack(Pid,Ref,maps:get(tick,Initial)),
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},control_goal({'::',Ns,
            {physics_control_input,room,Frame,1,1,{drive,{vector,0,0,0},{angular,0,0,0}},{0}}})),
        {Falling,_} = input_frame(Pid,Ref,Human,1),
        {2,1,world,{_,Y0,_},_,_} = lists:keyfind(2,1,maps:get(poses,Falling)),
        ?assert(Y0 > 1.0),
        %% This update invalidates navigation while the agent is in the air.
        %% No new command or view is supplied after installation.
        commit(Ns,{',',{retract,{physics_structure,room,1}},{assertz,{physics_structure,room,2}}}),
        {Pid,World} = installed(Ns),
        receive {physics_status,_,Pid,World,_,sleeping} -> ok
        after 5000 -> error(grounded_body_never_settled) end,
        {ok,Settled,_} = quod_physics:snapshot(Pid,Expected#{structure => 2,tick => -1}),
        {2,1,world,{_,Y,_},_,_} = lists:keyfind(2,1,maps:get(poses,Settled)),
        ?assert(Y < 0.72 andalso Y >= 0.5),
        Before = gen_server:call(Pid,status),
        assert_no_physics_io(fun() ->
            [reconcile(Ns) || _ <- lists:seq(1,3)],
            ?assertEqual(maps:with([steps,tick,installs],Before),
                maps:with([steps,tick,installs],gen_server:call(Pid,status)))
        end),
        %% Removing/moving the support wakes a settled body without another
        %% input, including when its old contact was a non-landing wedge.
        RemoveWedge = case Terrain of floor -> true; wedge -> {retract,{physics_body_definition, room, 3, {'_'}, {'_'}, {'_'}, {owned, {'_'}, {'_'}}}} end,
        commit(Ns,{',',{retract,{physics_body_definition, room, 1, 1, fixed, {vector,0,-500,0}, {owned, {box,10000,500,10000}, 1}}},
            {',',{assertz,{physics_body_definition, room, 1, 2, fixed, {vector,0,-2500,0}, {owned, {box,10000,500,10000}, 1}}},
            {',',RemoveWedge,{',',{retract,{physics_structure,room,2}},{assertz,{physics_structure,room,3}}}}}}),
        {Pid,World} = installed(Ns),
        receive {physics_status,_,Pid,World,_,sleeping} -> ok
        after 5000 -> error(changed_support_never_settled) end,
        {ok,Lower,_} = quod_physics:snapshot(Pid,Expected#{structure => 3,tick => -1}),
        {2,1,world,{_,LowerY,_},_,_} = lists:keyfind(2,1,maps:get(poses,Lower)),
        ?assert(LowerY < -1.49 andalso LowerY >= -1.5)
    end,fun(Rules) ->
        Base = [case R of
            {physics_body_definition, room, 2, 1, _, _, {owned, _, _}} ->
                {physics_body_definition, room, 2, 1, controlled, {vector,0,1500,0}, {owned, {ball,500}, 1}};
            _ -> R end || R <- Rules],
        case Terrain of
            floor -> Base;
            wedge -> Base ++ [{physics_body_definition, room, 3, 1, fixed, {vector,0,0,0}, {owned, {surface,[{vector,-10000,10000,-10000},{vector,0,0,-10000},{vector,10000,10000,-10000},
                          {vector,-10000,10000,10000},{vector,0,0,10000},{vector,10000,10000,10000}],
                         [{triangle,0,3,1},{triangle,1,3,4},{triangle,1,4,2},{triangle,2,4,5}]}, 1}}]
        end
    end) end}} || Terrain <- [floor,wedge]].

flush_sleeping(Pid) ->
    receive {physics_status,_,Pid,_,_,sleeping} -> flush_sleeping(Pid) after 0 -> ok end.

signed_landing_reposition_and_feedback_test_() ->
    {timeout,60,fun() -> with_world(fun(F = #{namespace := Ns,node := Human}) ->
        {Pid,World} = enable(F),
        Motion = {motion,{grounded,700},2000,1600,500,{query_limits,2,0,8,128},
                  [{teleport,6000,2000,700},{snap,785},reposition]},
        {_,_,Frame,Ref,Initial} = install_test_control(F,Pid,World,Motion),
        ?assert(is_float(maps:get(view_clearance,Initial))),
        quod_physics:ack(Pid,Ref,maps:get(tick,Initial)),
        Command = fun(Seq,Input) -> control_goal({'::',Ns,
            {physics_control_input,room,Frame,1,Seq,Input,{0}}}) end,
        ?assertMatch({ok,_,{normalized,{failed,_}}},Command(0,{snap,2000})),
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Command(1,{teleport,{vector,2000,2000,0}})),
        {Occupied,{occupied,3,_}} = input_frame(Pid,Ref,Human,1),
        ?assertMatch({2,1,world,{0.0,_,0.0},_,_},lists:keyfind(2,1,maps:get(poses,Occupied))),
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Command(2,{teleport,{vector,4000,2000,0}})),
        {_,{blocked,3,_}} = input_frame(Pid,Ref,Human,2),
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Command(3,{teleport,{vector,0,2000,3000}})),
        {Landed,{clipped,_,_,_}} = input_frame(Pid,Ref,Human,3),
        {2,1,world,{_,Y,3.0},_,_} = lists:keyfind(2,1,maps:get(poses,Landed)),
        ?assert(Y >= 1.0 andalso Y < 1.003),
        %% Reposition is explicit and occupancy checked, but unlike teleport it
        %% is permitted to repair an invalid placement without a clear path.
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Command(4,
            {reposition,{pose,{vector,2000,1002,0},{rotation,0,0,0}}})),
        {Rejected,{occupied,3,_}} = input_frame(Pid,Ref,Human,4),
        ?assertMatch({2,1,world,{_,_,3.0},_,_},lists:keyfind(2,1,maps:get(poses,Rejected))),
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Command(5,{snap,785})),
        {Turned,_} = input_frame(Pid,Ref,Human,5),
        {2,1,world,_,{_,Qy,_,_},_} = lists:keyfind(2,1,maps:get(poses,Turned)),
        ?assert(Qy > 0.3),
        quod_physics:unwatch(Pid,Ref)
    end,fun(Rules) -> [case R of
        {physics_body_definition, room, 2, 1, _, _, {owned, _, _}} ->
            {physics_body_definition, room, 2, 1, controlled, {vector,0,1002,0}, {owned, {box,500,1000,500}, 1}};
        _ -> R end || R <- Rules] ++
        [{physics_body_definition, room, 3, 1, fixed, {vector,2000,2000,0}, {owned, {box,100,3000,2000}, 1}}]
    end) end}.

foreign_signed_control_view_and_reconnect_test_() ->
    {timeout,60,fun() -> with_world(fun(F = #{namespace := Ns,node := Human,identity := Identity}) ->
        {Pid,World} = enable(F),
        Motion = {motion,free,2000,1600,500,{query_limits,2,0,8,128},[]},
        {_,_,_,Ref,_} = install_test_control(F,Pid,World,Motion),
        quod_physics:unwatch(Pid,Ref), _ = gen_server:call(Pid,status),
        commit(Ns,{',',{assertz,{can_view_physics,room,Human}},{assertz,{world_view,room,playing,[]}}}),
        reconcile(Ns),
        Parent = self(), Socket = spawn_link(fun() -> simulation_socket(Parent,#{peer => {127,0,0,1}}) end),
        try
            Session = simulation_session(Identity),
            Open = fun() -> Socket ! {client,simulation_open(F,Session,Human)} end,
            Open(), First = simulation_reply(Socket,<<"projection">>),
            Frame = maps:get(<<"frame">>,First),
            ?assertEqual(<<"2">>,maps:get(<<"body">>,hd(maps:get(<<"poses">>,Frame)))),
            ?assertEqual(<<"[]">>,maps:get(<<"marks">>,First)),
            ?assertMatch(#{<<"sequence">> := <<"-1">>},maps:get(<<"control_state">>,Frame)),
            %% Socket reopening revokes the old registration without changing
            %% body geometry or authority. The source principal remains Human.
            Open(), Second = simulation_reply(Socket,<<"projection">>),
            ?assertNotEqual(maps:get(<<"registration">>,Frame),
                maps:get(<<"registration">>,maps:get(<<"frame">>,Second))),
            %% A different signed session must retire the old subscription,
            %% even for the same actor, world and goal.
            SameScope = simulation_state(Socket), OtherSession = simulation_session(Identity),
            Socket ! {client,simulation_open(F,OtherSession,Human)},
            _ = simulation_reply(Socket,<<"projection">>),
            ChangedScope = simulation_state(Socket),
            ?assertNotEqual(maps:get(monitor,SameScope),maps:get(monitor,ChangedScope)),
            ?assertNotEqual(maps:get(dependency_monitors,SameScope),maps:get(dependency_monitors,ChangedScope)),
            ?assertEqual(false,erlang:read_timer(maps:get(timer,SameScope))),
            #{inputs := Inputs} = gen_server:call(Pid,status), ?assertEqual(#{},Inputs),
            %% An advance in the foreign signer's ontology invalidates this
            %% projection too, even if the world's height is much higher.
            {agent_instance_ref,Source,_,_} = Human,
            commit(Source,{assertz,{source_changed,true}}),
            _ = simulation_reply(Socket,<<"refresh">>),
            commit(Ns,{assertz,{physics_agent,room,pilot,2,2,Motion}}),
            Open(),
            ?assertMatch(#{<<"selection">> := <<"unavailable">>},simulation_reply(Socket,<<"projection">>))
        after Socket ! stop end
    end,fun(Rules) -> [case R of
        {physics_body_definition, room, 2, 1, _, _, {owned, _, _}} ->
            {physics_body_definition, room, 2, 1, controlled, {vector,0,1002,0}, {owned, {box,500,1000,500}, 1}};
        _ -> R end || R <- Rules] end) end}.

input_frame(Pid,Ref,Principal,Seq) ->
    receive {physics_frame,Pid,Ref,Frame} ->
        quod_physics:ack(Pid,Ref,maps:get(tick,Frame)),
        case maps:get(Principal,maps:get(inputs,Frame,#{}),none) of
            #{sequence := Seq,pending := false,result := Result} -> {Frame,Result};
            _ -> input_frame(Pid,Ref,Principal,Seq)
        end
    after 5000 -> error({missing_input_result,Seq,gen_server:call(Pid,status)}) end.

changed_control_view_retains_sequence_test_() ->
    {timeout,60,fun() -> with_chair(fun(F = #{namespace := Ns,node := Human,identity := Identity}) ->
        {Pid,World} = enable(F),
        Motion = {motion,free,2000,1600,1000,{query_limits,2,0,8,128},[]},
        {Definition,Expected,OldFrame,Ref,Initial} = install_test_control(F,Pid,World,Motion),
        quod_physics:ack(Pid,Ref,maps:get(tick,Initial)),
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},control_goal({'::',Ns,
            {physics_control_input,room,OldFrame,1,7,
                {drive,{vector,0,0,0},{angular,0,0,0}},{0}}})),
        _ = input_frame(Pid,Ref,Human,7),
        quod_physics:unwatch(Pid,Ref), _ = gen_server:call(Pid,status),
        commit(Ns,{',',{assertz,{can_view_physics,room,Human}},{assertz,{world_view,room,playing,[]}}}),
        Move = door_action(Ns,{physics_move_body,room,2,1,1,{vector,-3000,1000,0}}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},Move),
        await_source_receipt(Move),
        {Pid,World} = installed(Ns),
        Parent = self(), Socket = spawn_link(fun() -> simulation_socket(Parent,#{peer => {127,0,0,1}}) end),
        try
            Socket ! {client,simulation_open(F,simulation_session(Identity),Human)},
            Projection = simulation_reply(Socket,<<"projection">>),
            Frame = maps:get(<<"frame">>,Projection),
            ?assertMatch(#{<<"sequence">> := <<"7">>,<<"pending">> := false,<<"result">> := <<"suspended">>},
                maps:get(<<"control_state">>,Frame)),
            Monitor = monitor(process,Socket), Socket ! stop,
            receive {'DOWN',Monitor,process,Socket,normal} -> ok
            after 5000 -> error(socket_not_released) end,
            {ok,FreshRef,FreshView} = quod_physics:watch(Pid,Expected#{structure => 2,
                control => {control,Human,1,setelement(5,Definition,2)}},none),
            quod_physics:ack(Pid,FreshRef,maps:get(tick,FreshView)),
            #{World := #{spec := Spec}} = worlds(Ns),
            ControlFrame = {control_frame,{physics_frame,World,maps:get(authority,Spec),maps:get(epoch,Spec),
                maps:get(generation,Spec),maps:get(run_token,Spec),2},
                maps:get(registration,FreshView)},
            ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},control_goal({'::',Ns,
                {physics_control_input,room,ControlFrame,1,8,{push,{body,3,1},{vector,1000,0,0}},{0}}})),
            _ = input_frame(Pid,FreshRef,Human,8),
            ?assertMatch(#{inputs := #{Human := #{sequence := 8,result := pushed}}},gen_server:call(Pid,status)),
            quod_physics:unwatch(Pid,FreshRef)
        after Socket ! stop end
    end) end}.

control_goal(Goal) ->
    {ok,Bytes,Signature} = quod_node_actor:signed_goal(control,Goal,
        crypto:strong_rand_bytes(32),quod_time:now_ms()+10000),
    quod_client_goal_ingress:submit(Bytes,Signature).

control_only_installation_and_revocation_test_() ->
    {timeout, 60, fun() -> with_world(fun(F = #{namespace := Ns, reference := Principal}) ->
        {Pid, World} = enable(F),
        commit(Ns, {',', {assertz,{instance_of,agent,pilot}},
            {',',{assertz,{physics_agent,room,pilot,1,2,{motion,grounded}}},
            {',',{assertz,{physics_viewpoint,room,pilot,eye,2,
                {pose,{vector,0,100,0},{rotation,0,0,0}},view_only}},
            {',',{assertz,{can_control_physics_agent,room,Principal,pilot}},
                 {assertz,{physics_control,room,Principal,1,{controlled,pilot,eye}}}}}}}),
        reconcile(Ns),
        #{World := #{spec := Spec}} = worlds(Ns),
        [Control] = maps:get(agent_controls, Spec),
        {Pid, World} = installed(Ns),
        Expected = #{fence => quod_physics:fence(Spec), structure => 1,
            incarnation => maps:get(run_token,Spec), control => Control},
        {ok, Ref, _} = quod_physics:watch(Pid,Expected,none),
        #{installs := Installs} = gen_server:call(Pid,status),
        assert_no_physics_io(fun() -> reconcile(Ns) end),
        ?assertMatch(#{installs := Installs},gen_server:call(Pid,status)),
        commit(Ns,{retract,{can_control_physics_agent,room,Principal,pilot}}),
        receive {physics_refresh,Pid,Ref} -> ok
        after 5000 -> error(control_not_revoked) end,
        {Pid,World} = installed(Ns),
        ?assertEqual({error,unavailable},quod_physics:watch(Pid,Expected,none)),
        ?assertMatch(#{installs := Installs},gen_server:call(Pid,status)),
        %% Grant dependencies are retained by the real runtime selector. Their
        %% restoration installs a fresh view opportunity without touching bodies.
        commit(Ns,{assertz,{can_control_physics_agent,room,Principal,pilot}}),
        {Pid,World} = installed(Ns),
        {ok,Fresh,_} = quod_physics:watch(Pid,Expected,none),
        quod_physics:unwatch(Pid,Fresh)
    end) end}.

renewed_control_preserves_input_and_fences_registration_test_() ->
    {timeout,60,fun() -> with_world(fun(F = #{namespace := Ns,node := Human}) ->
        {Pid,World} = enable(F),
        Motion = {motion,free,2000,1600,1000,{query_limits,2,0,8,128},[{snap,785}]},
        {_,Expected,OldFrame,Ref,Initial} = install_test_control(F,Pid,World,Motion),
        quod_physics:ack(Pid,Ref,maps:get(tick,Initial)),
        Input = {drive,{vector,1000,0,0},{angular,0,0,0}},
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},control_goal({'::',Ns,
            {physics_control_input,room,OldFrame,1,7,Input,{0}}})),
        {Moving,_} = input_frame(Pid,Ref,Human,7),
        %% Inspect the actual retained row without duplicating the owner's
        %% record definition or creating a second input-state interface.
        Row = fun() ->
            [Inputs] = [M || M <- tuple_to_list(sys:get_state(Pid)),
                            is_map(M),is_map_key(Human,M)],
            maps:get(Human,Inputs)
        end,
        Original = maps:with([control,sequence,input,expiry],Row()),
        {ok,Fresh,Renewed} = quod_physics:watch(Pid,Expected,Ref),
        ?assertEqual(Original,maps:with([control,sequence,input,expiry],Row())),
        ?assertNotEqual(Ref,Fresh),
        ?assertNotEqual(maps:get(registration,Initial),maps:get(registration,Renewed)),
        ?assertEqual({error,view_busy},quod_physics:watch(Pid,Expected,Ref)),
        ?assertEqual({error,view_busy},quod_physics:watch(Pid,Expected#{structure => 99},Fresh)),
        Parent = self(),
        Other = spawn(fun() -> Parent ! {foreign_watch,self(),quod_physics:watch(Pid,Expected,Fresh)} end),
        receive {foreign_watch,Other,Reply} -> ?assertEqual({error,view_busy},Reply)
        after 5000 -> error(foreign_watch_missing) end,
        %% Retired acknowledgements and detach messages have no authority over
        %% the replacement. Only its own acknowledgement releases credit.
        quod_physics:ack(Pid,Ref,maps:get(tick,Moving)),
        quod_physics:unwatch(Pid,Ref), _ = gen_server:call(Pid,status),
        receive {physics_frame,Pid,Fresh,_} -> error(uncredited_renewal_frame) after 0 -> ok end,
        ?assertEqual(Original,maps:with([control,sequence,input,expiry],Row())),
        quod_physics:ack(Pid,Fresh,maps:get(tick,Renewed)),
        {Continued,_} = input_frame(Pid,Fresh,Human,7),
        {2,1,world,{X0,_,_},_,_} = lists:keyfind(2,1,maps:get(poses,Renewed)),
        {2,1,world,{X1,_,_},_,_} = lists:keyfind(2,1,maps:get(poses,Continued)),
        ?assert(X1 > X0),
        ?assertMatch({ok,_,{normalized,{failed,_}}},control_goal({'::',Ns,
            {physics_control_input,room,OldFrame,1,8,Input,{0}}})),
        {control_frame,Physical,_} = OldFrame,
        CurrentFrame = {control_frame,Physical,maps:get(registration,Renewed)},
        ?assertMatch({ok,_,{normalized,{failed,_}}},control_goal({'::',Ns,
            {physics_control_input,room,CurrentFrame,1,7,Input,{0}}})),
        ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},control_goal({'::',Ns,
            {physics_control_input,room,CurrentFrame,1,8,{snap,785},{0}}})),
        _ = input_frame(Pid,Fresh,Human,8),
        assert_no_physics_io(fun() ->
            {ok,Final,_} = quod_physics:watch(Pid,Expected,Fresh),
            ?assertEqual(8,maps:get(sequence,Row())),
            quod_physics:unwatch(Pid,Final), _ = gen_server:call(Pid,status)
        end),
        ?assertEqual(0,maps:get(expiry,Row())),
        ?assertEqual(disconnected,maps:get(result,Row()))
    end,fun(Rules) -> [case R of
        {physics_body_definition,room,2,1,_,_,{owned,_,_}} ->
            {physics_body_definition,room,2,1,controlled,{vector,0,1002,0},{owned,{box,500,1000,500},1}};
        _ -> R end || R <- Rules] end) end}.

current_view_credit_and_revision_test_() ->
    {timeout, 60, fun() -> with_world(fun(F = #{namespace := Ns}) ->
        {Pid, World} = enable(F),
        #{World := #{spec := Spec}} = worlds(Ns),
        Expected = #{fence => quod_physics:fence(Spec), structure => 1,
                     incarnation => maps:get(run_token, Spec)},
        {ok, Ref, First} = quod_physics:watch(Pid, Expected,none),
        ?assertEqual({error, view_busy}, quod_physics:watch(Pid, Expected,none)),
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
        ?assertEqual({error, unavailable}, quod_physics:watch(Pid, Expected,none)),
        {Pid,World} = installed(Ns),
        {ok, Fresh, _} = quod_physics:watch(Pid, Expected#{structure => 2},none),
        quod_physics:unwatch(Pid, Fresh)
    end) end}.

ordinary_space_views_test_() ->
    [{binary_to_list(Ns),{timeout,60,fun() -> with_world(Ns,
      fun(F = #{namespace := N,node := Human,identity := Identity}) ->
        Parent = self(), Socket = spawn_link(fun() -> simulation_socket(Parent,#{peer => {127,0,0,1}}) end),
        Session = simulation_session(Identity),
        Open = fun() -> Socket ! {client,simulation_open(F,Session,Human)} end,
        Selection = fun(Expected) ->
            Open(), ?assertEqual(Expected,maps:get(<<"selection">>,simulation_reply(Socket,<<"projection">>)))
        end,
        Change = fun(Goal) -> commit(N,Goal), _ = simulation_reply(Socket,<<"refresh">>) end,
        try
            Selection(<<"disabled">>),
            renew_simulation(Socket,Open,20),
            ?assertEqual(#{},worlds(N)),
            #{timer := Timer,installed := true} = simulation_state(Socket),
            Socket ! {timeout,Timer,expired}, _ = simulation_reply(Socket,<<"refresh">>),
            Selection(<<"disabled">>),
            Change({retract,{can_view_physics,room,{'_'}}}), Selection(<<"denied">>),
            Change({assertz,{can_view_physics,room,{'_'}}}), Selection(<<"disabled">>),
            {Pid,World} = enable(F), _ = simulation_reply(Socket,<<"refresh">>),
            Selection(<<"active">>),
            renew_simulation(Socket,Open,20),
            Runtime = quod_reg:where({quod_runtime,N}), Token = make_ref(),
            Retired = fun(State,{in,{physics_down,_,process,P,_}},_) when P =:= Pid ->
                              Parent ! {retired,Token}, State;
                         (State,_,_) -> State end,
            ok = sys:install(Runtime,{Retired,none}),
            try
                ok = sys:suspend(Pid),
                try
                    Change({',',{retract,{instance_of,physical_space,room}},
                                {assertz,{instance_of,space,room}}}),
                    reconcile(N),
                    ?assertMatch(#{World := #{pid := Pid,stopping := true}},worlds(N))
                after sys:resume(Pid) end,
                receive {retired,Token} -> ok after 10000 -> error(world_not_retired) end,
                %% This snapshot joins the runtime's DOWN handler, not just process death.
                ?assertEqual(#{},worlds(N))
            after sys:remove(Runtime,Retired) end,
            ?assertMatch({ok,[#{}],_},quod_prolog:prove_ro(N,{agent_hosting_projection,all,Human,all,[]})),
            Selection(<<"nonphysical">>),
            renew_simulation(Socket,Open,20),
            Change({assertz,{physics_control,room,Human,1,{controlled,pilot,eye}}}),
            Selection(<<"unavailable">>),
            Change({retract,{physics_control,room,Human,1,{controlled,pilot,eye}}}),
            Selection(<<"nonphysical">>),
            Change({assertz,{world_view,room,playing,[{mark,<<"other">>,<<"group">>,[],
                {transform,0,0,0,0,0,0},no_surface,unlabelled,depicts_nothing}]}}), Selection(<<"unavailable">>),
            Socket ! {client,simulation_open(F#{space => absent},Session,Human)},
            ?assertMatch(#{<<"selection">> := <<"unavailable">>},simulation_reply(Socket,<<"projection">>))
        after Socket ! stop end
      end,fun(Rules) -> Rules ++ [{can_view_physics,room,{'_'}},{world_view,room,playing,[]}] end)
    end}} || Ns <- [<<"ordinary-workshop">>,<<"ordinary-observatory">>]].

renew_simulation(Socket,Open,Count) ->
    Before = simulation_state(Socket),
    Retained = [heights,anchors,owners,follows,dependency_monitors,dependency_names,local_ready,monitor,pid],
    assert_no_physics_io(fun() ->
        lists:foreach(fun(_) ->
            Old = simulation_state(Socket),
            Open(), _ = simulation_reply(Socket,<<"projection">>),
            Current = simulation_state(Socket),
            ?assertEqual(maps:with(Retained,Before),maps:with(Retained,Current)),
            ?assertNotEqual(maps:get(timer,Old),maps:get(timer,Current)),
            ?assertNot(maps:is_key(candidate_timer,Current)),
            ?assertEqual(false,erlang:read_timer(maps:get(timer,Old))),
            case maps:find(ref,Old) of
                {ok,Ref} -> ?assertNotEqual(Ref,maps:get(ref,Current));
                error -> ?assertNot(maps:is_key(ref,Current))
            end,
            Socket ! {timeout,maps:get(timer,Old),expired},
            ?assertEqual(Current,simulation_state(Socket))
        end,lists:seq(1,Count))
    end).

navigation_dependencies_fence_view_test_() ->
    {timeout,60,fun() -> with_world(fun(F = #{namespace := Ns,node := Human,identity := Identity}) ->
        Rendering = <<"physics-test-rendering">>, Anchor = quod_simplex:genesis_hash(Rendering),
        Height = quod_prolog:applied(Rendering), OriginHeight = quod_prolog:applied(element(2,Human)),
        Parent = self(), Socket = spawn_link(fun() -> simulation_socket(Parent,#{peer => {127,0,0,1}}) end),
        Session = simulation_session(Identity),
        Open = fun(H) -> Socket ! {client,simulation_open(F#{dependencies =>
            [{dependency,Rendering,Anchor,H}]},Session,Human)} end,
        try
            Open(Height), _ = simulation_reply(Socket,<<"projection">>),
            commit(Rendering,{assertz,{navigation_policy,changed}}),
            _ = simulation_reply(Socket,<<"refresh">>),
            ?assertEqual(OriginHeight,quod_prolog:applied(element(2,Human))),
            Open(Height), ?assertMatch(#{<<"reason">> := <<"navigation_changed">>},simulation_reply(Socket,<<"refresh">>)),
            ?assertNot(maps:is_key(installed,simulation_state(Socket))),
            Open(quod_prolog:applied(Rendering)), _ = simulation_reply(Socket,<<"projection">>),
            Open(18446744073709551615),
            ?assertMatch(#{<<"reason">> := <<"navigation_changed">>},simulation_reply(Socket,<<"refresh">>)),
            Fenced = F#{dependencies => [{dependency,Rendering,<<99:256>>,0}]},
            Socket ! {client,simulation_open(Fenced,Session,Human)},
            ?assertMatch(#{<<"reason">> := <<"navigation_changed">>},simulation_reply(Socket,<<"refresh">>)),
            ?assertNot(maps:is_key(installed,simulation_state(Socket))),
            ?assertEqual(#{},worlds(Ns))
        after Socket ! stop end
    end,fun(Rules) -> Rules ++ [{can_view_physics,room,{'_'}},{world_view,room,playing,[]}] end) end}.

opening_worker_cancellation_test_() ->
    {timeout,60,fun() -> with_world(fun(F = #{node := Human,identity := Identity}) ->
        Parent = self(), Socket = spawn(fun() -> simulation_socket(Parent,#{peer => {127,0,0,1}}) end),
        Session = simulation_session(Identity),
        true = quod_reg:reg({host_test,local_proof}),
        try
            Open = fun() ->
                Socket ! {client,simulation_open(F,Session,Human)},
                receive {local_proof_waiting,Proof} -> Proof after 5000 -> error(opening_proof_not_waiting) end
            end,
            Socket ! {client,simulation_open(F#{expires => 18446744073709551615},Session,Human)},
            ?assertMatch(#{<<"reason">> := <<"invalid_view_deadline">>},simulation_reply(Socket,<<"unavailable">>)),
            ?assertEqual(#{peer => {127,0,0,1}},simulation_state(Socket)),
            Proof = Open(), #{opening := {Ref,Worker,_},timer := Timer} = simulation_state(Socket),
            M = monitor(process,Worker), ProofMonitor = monitor(process,Proof),
            Socket ! {timeout,Timer,expired},
            ?assertMatch(#{<<"reason">> := <<"expired">>},simulation_reply(Socket,<<"unavailable">>)),
            receive {'DOWN',M,process,Worker,Reason} -> ?assertEqual(killed,Reason)
            after 5000 -> error({opening_not_cancelled,opening_cancellation_state(Worker,Proof,Socket)}) end,
            receive {'DOWN',ProofMonitor,process,Proof,_} -> ok
            after 5000 -> error({proof_not_cancelled,opening_cancellation_state(Worker,Proof,Socket)}) end,
            receive {simulation_opening_down,Socket,Worker} -> ok after 5000 -> error(socket_cleanup_missing) end,
            Socket ! {view_opened,Ref,retired_result},
            ?assertEqual(#{peer => {127,0,0,1}},simulation_state(Socket)),
            Open(), #{opening := {_,Fresh,_}} = simulation_state(Socket),
            Socket ! {client,simulation_open(F,Session,Human)},
            ?assertMatch(#{<<"reason">> := <<"dependency_recovering">>},simulation_reply(Socket,<<"unavailable">>)),
            _ = simulation_reply(Socket,<<"refresh">>),
            receive {simulation_opening_down,Socket,Fresh} -> ok after 5000 -> error(reopen_cleanup_missing) end,
            Open(), #{opening := {_,Last,_}} = simulation_state(Socket),
            LastMonitor = monitor(process,Last), exit(Socket,kill),
            receive {'DOWN',LastMonitor,process,Last,killed} -> ok
            after 5000 -> error(socket_did_not_reap_opening) end
        after gproc:unreg(quod_reg:name({host_test,local_proof})), exit(Socket,kill) end
    end,fun(Rules) -> Rules ++ [{can_view_physics,room,{'_'}},
        {':-',{world_view,room,playing,[]},test_physics_snapshot}] end) end}.

uncertain_renewal_attachment_closes_and_releases_test_() ->
    {timeout,30,fun() -> with_world(fun(F = #{namespace := Ns,node := Human,identity := Identity}) ->
        {Pid,World} = enable(F),
        Motion = {motion,free,2000,1600,1000,{query_limits,2,0,8,128},[]},
        {_,Expected,_,Ref,_} = install_test_control(F,Pid,World,Motion),
        quod_physics:unwatch(Pid,Ref), _ = gen_server:call(Pid,status),
        commit(Ns,{',',{assertz,{can_view_physics,room,Human}},{assertz,{world_view,room,playing,[]}}}),
        reconcile(Ns),
        Parent = self(), Socket = spawn_link(fun() -> simulation_socket(Parent,#{peer => {127,0,0,1}}) end),
        SocketMonitor = monitor(process,Socket), Session = simulation_session(Identity),
        Open = fun() -> Socket ! {client,simulation_open(F,Session,Human)} end,
        Open(), _ = simulation_reply(Socket,<<"projection">>),
        Gate = fun(armed,{in,{'$gen_call',_,{watch,_,_}}},_) ->
                Parent ! {attachment_waiting,self()},
                receive resume_attachment -> released end;
            (released,{in,{'DOWN',_,process,Who,_}},_) when Who =:= Socket ->
                Parent ! {attachment_owner_down,self()}, observed;
            (State,_,_) -> State
        end,
        ok = sys:install(Pid,{Gate,armed}),
        try
            Open(),
            receive {attachment_waiting,Pid} -> ok after 5000 -> error(attachment_not_requested) end,
            %% Let the real local call time out with an unknown result. The
            %% socket must close; a late native registration must not survive it.
            receive {simulation_closed,Socket,1011,_} -> ok
            after 10000 -> error(uncertain_attachment_did_not_close) end,
            receive {'DOWN',SocketMonitor,process,Socket,normal} -> ok
            after 5000 -> error(uncertain_socket_not_terminated) end,
            Pid ! resume_attachment,
            receive {attachment_owner_down,Pid} -> ok
            after 5000 -> error(late_registration_not_released) end,
            {ok,Fresh,_} = quod_physics:watch(Pid,Expected,none),
            quod_physics:unwatch(Pid,Fresh), _ = gen_server:call(Pid,status)
        after Pid ! resume_attachment, sys:remove(Pid,Gate), Socket ! stop end
    end) end}.

renewal_retains_certified_foreign_dependency_test_() ->
    {timeout,30,fun() ->
        Fixture = quod_foreign_log_tests:foreign_fixture(<<"renewed-remote-view">>),
        Ns = maps:get(ns,Fixture), Anchor = maps:get(anchor,Fixture), Identity = {Ns,Anchor},
        Dir = quod_foreign_log_tests:temp_dir("renewed-view"),
        Foreign = quod_foreign_log_tests:start_owner(Dir,
            quod_foreign_log_tests:chain_fetch(Ns,maps:get(chain,Fixture))),
        try
            ?assertMatch({ok,#{slot := 2}},quod_foreign_log:current(
                [{maps:get(pub,Fixture),[{"127.0.0.1",19000}]}],Identity,1000)),
            {ok,Follow} = quod_foreign_log:follow(Identity,progress),
            await_foreign_view(Follow,Identity),
            Monitor = monitor(process,Foreign),
            true = quod_reg:subscribe({physics,Ns}),
            Timer = erlang:start_timer(30000,self(),expired),
            State = #{peer => {127,0,0,1},namespace => Ns,anchor => Anchor,instance => room,
                source => Ns,source_anchor => Anchor,expected_dependencies => [],
                installed => true,expires => quod_time:now_ms()+30000,timer => Timer,
                heights => #{},anchors => #{},owners => #{},local_ready => #{},dependency_names => #{},
                dependency_monitors => #{Monitor => Foreign},follows => #{Follow => {Ns,Anchor,2,true}},
                follow_requests => gen_server:reqids_new(),snapshots => gen_server:reqids_new()},
            {ok,Binding} = quod_wire_term:encode_bindings(#{<<"View">> =>
                {world_view,{entity_ref,Ns,Anchor,room},[],nonphysical}},10000),
            %% Enter at the trusted signed-proof completion seam. The foreign
            %% reference, certified progress and lifetime are the real owner's;
            %% this isolates retention from signature/ACL admission tests.
            try assert_no_physics_io(fun() ->
                Final = lists:foldl(fun(I,S) ->
                    Expiry = quod_time:now_ms()+30000+I, Ref = make_ref(), M = make_ref(),
                    Candidate = erlang:start_timer(Expiry-quod_time:now_ms(),self(),expired),
                    Pending = S#{candidate_timer => Candidate,opening => {Ref,self(),M}},
                    Result = {ok,#{request_digest => crypto:strong_rand_bytes(32),request => #{not_after_ms => Expiry}},
                        {normalized,{read,[{Ns,Anchor,2}],{answers,2,[Binding]}}}},
                    {ok,Completed} = quod_client_simulation:websocket_info({view_opened,Ref,Result},Pending),
                    {reply,{text,Json},Renewed} = quod_client_simulation:websocket_info(
                        {'DOWN',M,process,self(),normal},Completed),
                    ?assertMatch(#{<<"type">> := <<"projection">>,<<"selection">> := <<"nonphysical">>},json:decode(Json)),
                    ?assertEqual(maps:get(follows,State),maps:get(follows,Renewed)),
                    ?assertEqual(maps:get(dependency_monitors,State),maps:get(dependency_monitors,Renewed)),
                    ?assertEqual(false,erlang:read_timer(maps:get(timer,S))),
                    Renewed
                end,State,lists:seq(1,20)),
                ?assertMatch(#{follow_consumers := 1},quod_foreign_log:stats()),
                quod_client_simulation:terminate(normal,unused,Final),
                ?assertMatch(#{follow_consumers := 0},quod_foreign_log:stats())
            end)
            after catch quod_client_simulation:terminate(normal,unused,State) end
        after quod_foreign_log_tests:stop_owner(Foreign), file:del_dir_r(Dir) end
    end}.

await_foreign_view(Follow,Identity) ->
    receive {quod_foreign_follow,Follow,Notice,Identity,State} ->
        quod_foreign_log:ack(Follow,Notice),
        case State of
            {certified,2,_} -> ok;
            {building,_} -> await_foreign_view(Follow,Identity);
            _ -> error({unexpected_foreign_view_state,State})
        end
    after 3000 -> error(foreign_view_not_certified) end.

renewal_worker_cancellation_test_() ->
    {timeout,60,fun() -> with_world(fun(F = #{namespace := Ns,node := Human,identity := Identity}) ->
        _ = enable(F),
        Session = simulation_session(Identity), Parent = self(),
        true = quod_reg:reg({host_test,local_proof}),
        try lists:foreach(fun(Reason) ->
            Socket = spawn_link(fun() -> simulation_socket(Parent,#{peer => {127,0,0,1}}) end),
            Open = fun() ->
                Socket ! {client,simulation_open(F,Session,Human)},
                receive {local_proof_waiting,Proof} -> Proof
                after 5000 -> error(renewal_proof_missing) end
            end,
            try
                InitialProof = Open(), InitialProof ! release,
                _ = simulation_reply(Socket,<<"projection">>),
                Installed = simulation_state(Socket),
                Proof = Open(),
                Pending = #{opening := {Ref,Worker,_},timer := Old,candidate_timer := Candidate} = simulation_state(Socket),
                ?assertEqual(maps:with([pid,ref,monitor,timer,follows,dependency_monitors],Installed),
                             maps:with([pid,ref,monitor,timer,follows,dependency_monitors],Pending)),
                WorkerMonitor = monitor(process,Worker), ProofMonitor = monitor(process,Proof),
                {Type,ExpectedReason} = case Reason of
                    expired -> Socket ! {timeout,Old,expired}, {<<"refresh">>,<<"expired">>};
                    candidate_expired -> Socket ! {timeout,Candidate,expired}, {<<"unavailable">>,<<"expired">>};
                    proof_failed -> exit(Worker,kill), {<<"unavailable">>,<<"proof_unavailable">>};
                    revoked -> commit(Ns,{retract,{can_view_physics,room,{'_'}}}), {<<"refresh">>,<<"durable_gap">>}
                end,
                ?assertEqual(ExpectedReason,maps:get(<<"reason">>,simulation_reply(Socket,Type))),
                receive {'DOWN',WorkerMonitor,process,Worker,_} -> ok
                after 5000 -> error(renewal_worker_not_cancelled) end,
                receive {'DOWN',ProofMonitor,process,Proof,_} -> ok
                after 5000 -> error(renewal_proof_not_cancelled) end,
                receive {simulation_opening_down,Socket,Worker} -> ok
                after 5000 -> error(renewal_cleanup_missing) end,
                ?assertEqual(false,erlang:read_timer(Old)),
                ?assertEqual(false,erlang:read_timer(Candidate)),
                Socket ! {view_opened,Ref,retired_result},
                ?assertEqual(#{peer => {127,0,0,1}},simulation_state(Socket))
            after Socket ! stop end
        end,[expired,candidate_expired,proof_failed,revoked])
        after gproc:unreg(quod_reg:name({host_test,local_proof})) end
    end,fun(Rules) -> Rules ++ [{can_view_physics,room,{'_'}},
        {':-',{world_view,room,playing,[]},test_physics_snapshot}] end) end}.

opening_cancellation_state(Worker,Proof,Socket) ->
    Info = fun(Pid) -> #{pid => Pid,alive => is_process_alive(Pid),
        info => process_info(Pid,[status,current_function,current_stacktrace,message_queue_len,monitored_by])} end,
    #{worker => Info(Worker),proof => Info(Proof),socket => Info(Socket),
      mailbox => process_info(self(),messages),
      socket_state => try simulation_state(Socket) catch Class:Reason -> {Class,Reason} end}.

assert_view_selection(Selection,{ok,_,{normalized,{read,_,{answers,_,[Blob]}}}}) ->
    {ok,Pairs} = quod_client_result:decode_binding(Blob),
    ?assert(lists:any(fun({_,{world_view,_,_,S}}) -> S =:= Selection; (_) -> false end,Pairs)).

signed_mixed_view_uses_rendering_policy_test_() ->
    {timeout,60,fun() -> with_world(fun(F = #{namespace := Ns}) ->
        _ = enable(F),
        Body = {mark,<<"body">>,<<"group">>,[],{body_pose,1,1},no_surface,unlabelled,
                {depicts,<<"source-instance">>,<<91:256>>,object}},
        Decoration = {mark,<<"decoration">>,<<"group">>,[],
                       {relative,<<"body">>,{transform,0,1000,0,0,0,0}},
                       no_surface,unlabelled,depicts_nothing},
        Read = fun(Marks) ->
            commit(Ns,{assertz,{world_view,room,playing,Marks}}),
            Result = body_read(Ns,{client_world_view,room,playing,[],{0}}),
            commit(Ns,{retract,{world_view,room,playing,Marks}}), Result
        end,
        ?assertMatch({ok,_,{normalized,{read,_,{answers,_,[_]}}}},Read([Body,Decoration])),
        Twin = setelement(2,Body,<<"second-occurrence">>),
        ?assertMatch({ok,_,{normalized,{read,_,{answers,_,[_]}}}},Read([Body,Twin,Decoration])),
        lists:foreach(fun(Marks) ->
            assert_view_selection(unavailable,Read(Marks))
        end,[[Decoration,Body], [Body,Body], [setelement(8,Body,depicts_nothing)],
             [setelement(5,Body,{body_pose,1,2})],
             [Body,setelement(5,Decoration,{relative,<<"body">>,{transform,0,0.5,0,0,0,0}})]]),
        RenderingNs = <<"physics-test-rendering">>,
        commit(RenderingNs,{',',{retract,{limit,<<"scene">>,512}},
                               {assertz,{limit,<<"scene">>,2}}}),
        ?assertMatch({ok,_,{normalized,{read,_,{answers,_,[_]}}}},Read([Body,Decoration])),
        assert_view_selection(unavailable,Read([Body,Twin,Decoration]))
    end,fun(Rules) -> Rules ++ [{can_view_physics,room,{'_'}}] end) end}.

registered_view_dependency_waits_for_replay_test_() ->
    {timeout,30,fun() -> with_world(fun(#{namespace := Ns}) ->
        %% Enter at the retained-view dependency seam, after proof admission.
        %% Hold the real consensus owner so a restarted engine registers while
        %% still unable to reconstruct its committed projection.
        Sup = quod_reg:where({quod_ns,Ns}),
        Simplex = quod_reg:where({quod_simplex,Ns}),
        Anchor = quod_simplex:genesis_hash(Ns), Height = quod_prolog:applied(Ns),
        [ok = supervisor:terminate_child(Sup,Child) ||
            Child <- [quod_runtime,quod_feed,quod_catchup,quod_prolog]],
        ?assertEqual(undefined,quod_reg:where({quod_prolog,Ns})),
        ok = sys:suspend(Simplex),
        Parent = self(),
        Socket = spawn_link(fun() ->
            true = quod_reg:subscribe({runtime,Ns}),
            Name = quod_reg:monitor_name({quod_prolog,Ns},follow),
            Timer = erlang:start_timer(10000,self(),expired),
            State = #{peer => {127,0,0,1},timer => Timer,
                pending => {<<0:256>>,quod_time:now_ms()+10000,fail},
                heights => #{Ns => Height},anchors => #{Ns => Anchor},owners => #{},
                local_ready => #{Ns => false},dependency_monitors => #{},
                dependency_names => #{Name => Ns},follows => #{},
                follow_requests => gen_server:reqids_new(),snapshots => gen_server:reqids_new()},
            Parent ! {dependency_following,self()},
            simulation_socket(Parent,State)
        end),
        Monitor = monitor(process,Socket),
        try
            receive {dependency_following,Socket} -> ok
            after 1000 -> error(dependency_follow_not_installed) end,
            {ok,Engine} = supervisor:restart_child(Sup,quod_prolog),
            Paused = simulation_reply(Socket,<<"unavailable">>),
            ?assertEqual(<<"dependency_recovering">>,maps:get(<<"reason">>,Paused)),
            State = simulation_state(Socket),
            ?assertEqual(#{Engine => Ns},maps:get(owners,State)),
            ?assertEqual(#{Ns => {recovering,{Engine,boot}}},maps:get(local_ready,State)),
            ?assertEqual(#{},maps:get(dependency_names,State)),
            ?assertNot(maps:is_key(pid,State)),
            ok = sys:resume(Simplex),
            %% Boot readiness becomes the exact replay run before ready. Both
            %% notifications come from the actual engine, not the test.
            Replaying = simulation_reply(Socket,<<"unavailable">>),
            ?assertEqual(<<"dependency_recovering">>,maps:get(<<"reason">>,Replaying)),
            _ = simulation_reply(Socket,<<"refresh">>),
            ?assertEqual(#{peer => {127,0,0,1}},simulation_state(Socket)),
            ?assertEqual(Anchor,quod_simplex:genesis_hash(Ns)),
            ?assert(quod_prolog:applied(Ns) >= Height)
        after
            _ = catch sys:resume(Simplex),
            Socket ! stop,
            receive {'DOWN',Monitor,process,Socket,_} -> ok
            after 1000 -> error(dependency_socket_not_stopped) end
        end
    end) end}.

signed_client_view_lifecycle_test_() ->
    {timeout, 90, fun() -> with_door(fun(F = #{namespace := Ns, identity := Identity}) ->
        {Pid, World} = enable(F),
        Pub = maps:get(pubkey, Identity),
        commit(Ns, {assertz, {agent_key, viewer, Pub, active}}),
        reconcile(Ns),
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
            {ok, #{goal := ParsedMarks}} = quod_client_goal_parser:parse(
                <<(maps:get(<<"marks">>, First))/binary, ".">>, 3),
            {ok, ProjectedMarks} = quod_wire_term:materialize_symbols(ParsedMarks),
            ?assertMatch([{mark,<<"frame">>,_,_,{transform,5000,2000,3000,0,90,0},_,_,depicts_nothing},
                          {mark,<<"door">>,_,_,{relative,<<"frame">>,{body_pose,10,_}},_,_,
                           {depicts,<<"foreign-subject">>,<<99:256>>,door}},
                          {mark,<<"decoration">>,_,_,{relative,<<"door">>,_},_,_,depicts_nothing}], ProjectedMarks),
            %% The shared rendering policy is a real third proof dependency.
            %% Denial retains its subscription, so a grant wakes the same view.
            Rendering = <<"physics-test-rendering">>,
            #{heights := ViewHeights} = simulation_state(Socket),
            ?assertEqual(quod_prolog:applied(Rendering),maps:get(Rendering,ViewHeights)),
            commit(Rendering,{',',{retract,{limit,<<"scene">>,512}},
                                  {assertz,{limit,<<"scene">>,2}}}),
            _ = simulation_reply(Socket,<<"refresh">>),
            Open(), ?assertMatch(#{<<"selection">> := <<"unavailable">>},simulation_reply(Socket,<<"projection">>)),
            ?assertNot(maps:is_key(pid,simulation_state(Socket))),
            commit(Rendering,{',',{retract,{limit,<<"scene">>,2}},
                                  {assertz,{limit,<<"scene">>,512}}}),
            _ = simulation_reply(Socket,<<"refresh">>),
            Open(), _ = simulation_reply(Socket,<<"projection">>),
            %% Hold the real engine's snapshot reply. The socket must still
            %% process expiry and cancel its request without re-proving.
            RenderingEngine = quod_reg:where({quod_prolog,Rendering}),
            SnapshotGate = fun(armed,{in,{'$gen_call',_,get_stats}},_) ->
                Parent ! {snapshot_waiting,self()},
                receive release_snapshot -> released end;
                (State,_,_) -> State
            end,
            ok = sys:install(RenderingEngine,{SnapshotGate,armed}),
            try
                Open(),
                receive {snapshot_waiting,RenderingEngine} -> ok
                after 5000 -> error(snapshot_not_requested) end,
                #{timer := SnapshotTimer,snapshots := Requests} = simulation_state(Socket),
                ?assert(gen_server:reqids_size(Requests) > 0),
                ?assertEqual(Pid,maps:get(pid,simulation_state(Socket))),
                ?assert(maps:is_key(candidate_timer,simulation_state(Socket))),
                Socket ! {timeout,SnapshotTimer,expired},
                ?assertEqual(<<"expired">>,maps:get(<<"reason">>,
                    simulation_reply(Socket,<<"refresh">>))),
                ?assertEqual(#{peer => {127,0,0,1}},simulation_state(Socket))
            after
                RenderingEngine ! release_snapshot,
                sys:remove(RenderingEngine,SnapshotGate)
            end,
            Open(), _ = simulation_reply(Socket,<<"projection">>),
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
                Socket ! {timeout, WaitingTimer, expired},
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
                door_action(Ns, {physics_close_hinged,room,10,0,<<81:256>>})),
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
            ?assertEqual(<<"denied">>,
                         maps:get(<<"selection">>, simulation_reply(Socket, <<"projection">>))),
            commit(Ns, {assertz, {can_view_physics,room,{'_'}}}),
            _ = simulation_reply(Socket, <<"refresh">>),
            commit(Ns, {',', {retract, {physics_allowances,room,{limits,64,64,256,1000000,{geometry,256,4096,4096}},16667,-9810,10000}},
                            {assertz, {physics_allowances,room,{limits,1,1,256,1000000,{geometry,256,4096,4096}},16667,-9810,10000}}}),
            receive {physics_status,_,_,World,_,{failed,body_allowance}} -> ok
            after 15000 -> error(no_failed_installation) end,
            Open(),
            ?assertEqual(<<"simulation_failed">>,
                maps:get(<<"reason">>, simulation_reply(Socket, <<"unavailable">>)))
        after Socket ! stop end
    end, false, fun(Rules) ->
        Ns = <<"host-test-agent">>,
        Marks = [{mark, <<"frame">>, <<"group">>, [],
                  {transform,5000,2000,3000,0,90,0},no_surface,unlabelled,depicts_nothing},
                 {mark, <<"door">>, <<"box">>,
                  [{f,<<"width">>,2000},{f,<<"height">>,2000},{f,<<"depth">>,200}],
                  {relative,<<"frame">>,{body_pose,10,{'R'}}}, {surface,{'Colour'},0,900,0,[]}, unlabelled,
                  {depicts,<<"foreign-subject">>,<<99:256>>,door}},
                 {mark,<<"decoration">>,<<"group">>,[],
                  {relative,<<"door">>,{transform,1000,0,0,0,0,45}},no_surface,unlabelled,depicts_nothing}],
        Rules ++ [{can_invoke,{',',{current_ontology_identity,Ns,{'_'}},{client_world_view,room,playing,{'_'},{'_'}}},
                    {agent_instance_ref,Ns,{'_'},viewer},{'_'},Ns},
                  {can_view_physics,room,{'_'}}, {view_colour,<<"#FFFFFF">>},
                  {':-', {world_view,room,playing,Marks},
                    {',', {current_ontology_identity,Ns,{'Anchor'}},
                      {',', {view_colour,{'Colour'}},
                            {physics_body_definition, room, 10, {'R'}, {'_'}, {'_'}, {owned, {'_'}, {'_'}}}}}}]
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
    simulation_open(#{namespace => Ns,reference => {agent_instance_ref,Ns,Anchor,viewer},identity => Identity},
                    Session,{agent_instance_ref,Ns,Anchor,viewer}).
simulation_open(F = #{namespace := Ns, reference := {agent_instance_ref,_,Anchor,_}, identity := Identity}, Session,
                {agent_instance_ref,Source,SourceAnchor,Instance}) ->
    %% Render a named View binding with the same anchored goal as the client.
    Goal = iolist_to_binary([quod_client_goal_parser:value_text(Ns)," :: (current_ontology_identity(",
        quod_client_goal_parser:value_text(Ns),",",quod_client_goal_parser:value_text(Anchor),"), client_world_view(",
        quod_client_goal_parser:value_text(maps:get(space,F,room)),",playing,",
        quod_client_goal_parser:value_text(maps:get(dependencies,F,[])),",View))."]),
    {ok,InstanceText} = quod_client_goal_parser:format(Instance),
    Request = #{network_identity => <<42:256>>, agent_namespace => Source,
        agent_genesis_anchor => SourceAnchor, agent_instance_text => InstanceText,
        signing_public_key => maps:get(pubkey, Identity), operation_id => crypto:strong_rand_bytes(32),
        not_after_ms => maps:get(expires,F,quod_time:now_ms()+30000), mode => read, parser_version => 3,
        goal_text => Goal},
    {ok, Bytes} = quod_client_goal:encode(Request),
    Enc = fun(B) -> base64:encode(B, #{mode => urlsafe, padding => false}) end,
    iolist_to_binary(json:encode(#{type => open, session_id => Enc(Session), request => Enc(Bytes),
        world_namespace => Ns,world_anchor => Enc(Anchor),
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
                {reply,{close,Code,Reason},State} ->
                    Parent ! {simulation_closed,self(),Code,Reason},
                    quod_client_simulation:terminate(normal,unused,State), closed;
                Other -> error({invalid_socket_result, Other})
            end,
            case {Message,S} of
                {{'DOWN',M,process,P,_},#{opening := {_,P,M}}} -> Parent ! {simulation_opening_down,self(),P};
                _ -> ok
            end,
            case Next of closed -> ok; _ -> simulation_socket(Parent,Next) end
    end.

simulation_state(Socket) ->
    Ref = make_ref(), Socket ! {inspect, Ref},
    receive {simulation_state, Ref, State} -> State
    after 5000 -> error(socket_state_unavailable) end.

with_world(Fun) -> with_world(Fun, fun(Rules) -> Rules end).
with_world(Fun, Transform) ->
    with_world(<<"host-test-agent">>, Fun, Transform).
with_world(Ns, Fun, Transform) ->
    Rules = world_rules(Ns),
    WithRendering = fun(F = #{directory := Dir, identity := Identity}) ->
        RenderingNs = <<"physics-test-rendering">>,
        Rendering = quod_agent_hosting_tests:start_ontology(RenderingNs, Dir, Identity,
            quod_prolog:genesis_diff("priv/ontologies/quod_rendering.pl"),
            [{can_invoke,{'_'},{node,maps:get(pubkey,Identity)},{'_'},RenderingNs}]),
        try
            commit(Ns, {assertz, {rendering_vocabulary, RenderingNs, quod_simplex:genesis_hash(RenderingNs)}}),
            Fun(F)
        after quod_agent_hosting_tests:stop_ontology(Rendering) end
    end,
    try quod_agent_hosting_tests:with_host(WithRendering, Transform(Rules), current, Ns)
    after catch quod_reg:unsubscribe({physics, Ns}) end.

world_rules(Ns) ->
    Actor = {agent_instance_ref, Ns, {'_'}, actor},
    quod_prolog:read_terms("priv/ontologies/quod_physics.pl") ++
        quod_prolog:read_terms("priv/ontologies/quod_hinged.pl") ++
        quod_prolog:read_terms("priv/ontologies/space.pl") ++ [{instance_of,physical_space,room}] ++
        [{can_invoke, {physics_store_request, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}, {'_'}}, Actor, {'_'}, Ns},
         {can_invoke, {physics_activate, {'_'}, {'_'}, {'_'}}, Actor, {'_'}, Ns},
         {can_invoke, {physics_cancel_activation, {'_'}, {'_'}, {'_'}}, Actor, {'_'}, Ns},
         {physics_space, room, disabled, actor},
         {physics_run, room, 0, none}, {physics_structure, room, 1}, {physics_next_body,room,4},
         {physics_allowances, room, {limits, 64, 64, 256, 1000000,{geometry,256,4096,4096}}, 16667, -9810, 10000},
         {physics_body_definition, room, 1, 1, fixed, {vector,0,-500,0}, {owned, {box,10000,500,10000}, 1}},
         {physics_body_definition, room, 2, 1, dynamic, {vector,0,3000,0}, {owned, {box,500,500,500}, 1}}].

worlds(Ns) -> gen_server:call(quod_reg:via({quod_runtime, Ns}), physics_worlds).
reconcile(Ns) ->
    ?assertEqual(ok, quod_runtime:reconcile_resource(Ns, quod_prolog:applied(Ns), physics_worlds,
                                                   all, quod_time:mono_ms() + 10000)).
installed(Ns) -> installed(Ns, quod_simplex:genesis_hash(Ns)).
installed(Ns, Anchor) ->
    receive
        {physics_status, _, Pid, World = {world_ref,Ns,Anchor,_}, _, installed} ->
            case is_process_alive(Pid) of
                false -> installed(Ns,Anchor);
                true -> case worlds(Ns) of
                    #{World := #{pid := Pid, stopping := false}} ->
                        case gen_server:call(Pid,status) of
                            #{phase := active,navigation_ready := true} -> {Pid,World};
                            _ -> installed(Ns,Anchor)
                        end;
                    _ -> installed(Ns, Anchor)
                end
            end;
        {physics_status, _, _, {world_ref,Ns,Anchor,_}, _, Status}
          when Status =:= activating; Status =:= awaiting_actor; Status =:= capacity;
               Status =:= sleeping -> installed(Ns, Anchor);
        {physics_status, _, _, {world_ref,Ns,Anchor,_}, _, {unavailable,_}} -> installed(Ns, Anchor);
        {physics_status, _, _, {world_ref,Ns,Anchor,_}, _, {observation,_,_}} -> installed(Ns,Anchor);
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
    Watched = [{quod_physics_native,new_world,3}, {quod_physics_native,install,2},
               {quod_physics_native,install_hinges,2}, {quod_physics_native,control_hinge,4}, {quod_ledger_store,append,2}, {quod_ledger_store,fold,5},
               {quod_ledger_store,fold_groups,3}, {quod_ledger_store,open,3},
               {quod_file,write_atomic,3}, {dets,insert,2}, {dets,sync,1}, {file,write,2}, {file,sync,1}, {file,datasync,1}],
    Match = [{'_',[],[{message,{caller}}]}],
    [trace:function(Trace, MFA, Match, [local]) || MFA <- Watched],
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
        commit(Ns, {',', {retract, {physics_allowances, room, {limits,64,64,256,1000000,{geometry,256,4096,4096}},16667,-9810,10000}},
                          {assertz, {physics_allowances, room, {limits,1,1,256,1000000,{geometry,256,4096,4096}},16667,-9810,10000}}}),
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
        ?assertEqual({error, simulation_failed}, quod_physics:watch(Pid, ignored,none)),
        commit(Ns, {',', {retract, {physics_allowances, room, {limits,1,1,256,1000000,{geometry,256,4096,4096}},16667,-9810,10000}},
                          {assertz, {physics_allowances, room, {limits,64,64,256,1000000,{geometry,256,4096,4096}},16667,-9810,10000}}}),
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
        {trace, Pid, call, {M,F,Args}, Caller} ->
            Keys = case catch gproc:info(Pid,gproc) of
                {gproc,Entries} -> [Key || {Key,_} <- Entries];
                _ -> []
            end,
            trace_calls([#{pid => Pid,call => {M,F,length(Args)},
                           caller => Caller,registered_keys => Keys} | Acc]);
        {finish,From,Ref} -> From ! {trace_calls,Ref,lists:reverse(Acc)}
    end.

%% Target application finality can precede its source's durable receipt. Wait
%% for that original operation before measuring unrelated unchanged checks.
await_source_receipt({ok,#{operation_ref := Op = {operation,Ns,_,_,_}},
                     {normalized,{committed,_,Target}}}) ->
    Engine = quod_reg:where({quod_prolog,Ns}),
    Monitor = monitor(process,Engine),
    true = quod_reg:subscribe({runtime,Ns}),
    try await_source_receipt(Engine,Monitor,Ns,Op,Target,quod_time:mono_ms()+5000)
    after demonitor(Monitor,[flush]), quod_reg:unsubscribe({runtime,Ns}) end.

await_source_receipt(Engine,Monitor,Ns,Op,Target,Deadline) ->
    Remaining = Deadline-quod_time:mono_ms(),
    ?assert(Remaining > 0),
    {ok,#{applied_floor := Floor,outcome := Outcome}} =
        quod_prolog:outcome_snapshot(Ns,Op,Remaining),
    case Outcome of
        #{operation_state := terminal,receipt_height := Height,
          outcome_ref := {applications,[Target]}} when Height =< Floor -> ok;
        #{operation_state := unresolved,outcome_ref := {applications,[Target]}} ->
            receive
                {projection_advanced,Engine,Height} when Height > Floor ->
                    await_source_receipt(Engine,Monitor,Ns,Op,Target,Deadline);
                {'DOWN',Monitor,process,Engine,Reason} -> error({source_down,Reason})
            after max(0,Deadline-quod_time:mono_ms()) -> error(source_receipt_not_installed) end
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
        {ok, Key2} = quod_agent_vault:prepare(Blob, 1),
        commit(Ns, {goal, {agent_assignment,actor,Node,1,Node,2,Key2}}),
        {Second, World} = installed(Ns),
        ?assertNotEqual(First, Second),
        #{World := #{spec := #{epoch := 2, generation := 2}}} = worlds(Ns),
        Remote = setelement(2, Node, <<"remote-node">>),
        M = monitor(process, Second),
        commit(Ns, {goal, {agent_assignment,actor,Node,2,Remote,3,<<75:256>>}}),
        receive {'DOWN', M, process, Second, _} -> ok after 10000 -> error(old_host_running) end,
        reconcile(Ns), ?assertEqual(#{}, worlds(Ns)),
        {ok, Key4} = quod_agent_vault:prepare(Blob, 3),
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
    {ok, R} = quod_physics_native:new_world({2,2,1,1000.0,256,4096,4096},1/60,-9.81),
    Body = {1,1,dynamic,{{0.0,3.0,0.0},{0.0,0.0,0.0}},{solid,{box,0.5,0.5,0.5}},1.0},
    {ok,1} = quod_physics_native:install(R,[Body]),
    Parent = self(),
    spawn(fun() -> Parent ! {foreign_native_call,quod_physics_native:step(R,false)} end),
    receive {foreign_native_call, Result} -> ?assertEqual({error,wrong_owner},Result)
    after 5000 -> error(native_call_not_returned) end,
    ?assertMatch({ok,{true,[_],[]}},quod_physics_native:sample(R)),
    %% Rustler's list iterator panics on an improper tail. Decoding is inside
    %% this adapter's unwind boundary, so the partially touched resource dies.
    ?assertEqual({error,native_failure},quod_physics_native:install(R,[Body|malformed])),
    ?assertEqual({error,retired},quod_physics_native:sample(R)),
    ?assertEqual(ok,quod_physics_native:retire(R)),
    ?assertEqual({error,invalid_step},quod_physics_native:new_world({2,2,1,1000.0,256,4096,4096},1.0e-320,-9.81)).

snapshot_replacement_coalesces_while_native_owner_is_busy_test_() ->
    {timeout, 60, fun() -> with_world(fun(F = #{namespace := Ns}) ->
        {Pid, World} = enable(F),
        receive {physics_status,_,Pid,World,_,sleeping} -> ok
        after 15000 -> error(world_never_slept) end,
        ok = sys:suspend(Pid),
        try
            [begin
                OldY = case Rev of 2 -> 3000; _ -> (Rev-1)*1000 end,
                commit(Ns, {',', {retract,{physics_body_definition, room, 2, Rev-1, dynamic, {vector,0,OldY,0}, {owned, {box,500,500,500}, 1}}},
                   {',', {assertz,{physics_body_definition, room, 2, Rev, dynamic, {vector,0,Rev*1000,0}, {owned, {box,500,500,500}, 1}}},
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
    {ok,R} = quod_physics_native:new_world({2,0,2,1000.0,256,4096,4096},1/60,-9.81),
    {ok,1} = quod_physics_native:install(R,[{1,1,dynamic,{{0.0,2.0,0.0},{0.0,0.0,0.0}},{solid,{box,0.5,0.5,0.5}},1.0}]),
    ?assertEqual({error,pose_allowance},quod_physics_native:sample(R)),
    ?assertEqual({error,retired},quod_physics_native:step(R,false)).

native_density_is_not_a_coordinate_budget_test() ->
    {ok,R} = quod_physics_native:new_world({1,1,1,1000.0,256,4096,4096},1/60,-9.81),
    {ok,1} = quod_physics_native:install(R,[{1,1,dynamic,{{0.0,2.0,0.0},{0.0,0.0,0.0}},{solid,{box,0.5,0.5,0.5}},7850.0}]),
    ?assertMatch({ok,{true,[_],[]}},quod_physics_native:step(R,false)),
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
    {ok,R} = quod_physics_native:new_world({1,1,1,1.7e308,256,4096,4096},1/60,-9.81),
    {ok,1} = quod_physics_native:install(R,[{1,1,dynamic,{{1.5e308,2.0,0.0},{0.0,0.0,0.0}},{solid,{box,1.0e308,1.0e-150,1.0e-150}},1.0}]),
    ?assertEqual({error,non_finite_state},quod_physics_native:step(R,false)),
    ?assertEqual({error,retired},quod_physics_native:step(R,false)).

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
    Guard = atomics:new(1,[{signed,false}]),
    Spec = #{world => {world_ref,<<"delivery-test">>,Anchor,room},
             authority => {agent_instance_ref,<<"delivery-test">>,Anchor,actor},
             epoch => 1,key => <<1:256>>,generation => 0,run_token => none,
             custody => Custody,budget => 5000,navigation_guard => {Guard,0}},
    {ok,Pid} = quod_physics:start(self(),Spec),
    try Fun(Pid,Spec) after gen_server:stop(Pid) end.

input_uninstalled_world_and_expiry_test() ->
    with_simulator(none,fun(Pid,_) ->
        Request = {physics_input,#{},{control,principal,1,configuration},1,input,
                   quod_time:now_ms()+5000,quod_time:mono_ms()+5000},
        ?assertEqual({error,physics_world_unavailable},gen_server:call(Pid,Request)),
        Effect = {physics_input,Pid,#{},{control,principal,1,configuration},1,input,quod_time:now_ms()-1},
        ?assertEqual({error,expired},quod_effect:release_transient(Effect,quod_time:mono_ms()+5000))
    end).

unguarded_world_is_refused_test() ->
    {ok,_} = application:ensure_all_started(gproc),
    World = {world_ref,<<"unguarded-test">>,crypto:strong_rand_bytes(32),room},
    ?assertMatch({error,_},quod_physics:start(self(),#{world => World})),
    ?assertEqual(undefined,quod_reg:where({physics_world,World})).

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
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_hinged,room,10,0,Id})),
        await_door(Ns,R,{blocked,3}),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_hinged,room,10,1,{finished,R,{blocked,3}}})),
        {ok,[#{'Request' := {request,Sample,{blocked,3},Bytes,Signature}}],_} =
            quod_prolog:prove_ro(Ns,{physics_hinged_request,room,10,{'Request'}}),
        ?assertMatch({ok,_,{operation_outcome,_,#{status := committed}}},
                     quod_client_goal_ingress:resolve_operation(Bytes,Signature)),
        %% The same operation resolves to the original result; no second event.
        ?assertMatch({ok,_,_},quod_client_goal_ingress:submit(Bytes,Signature)),
        ?assertMatch({ok,_,{normalized,{failed,_}}},door_action(Ns,{physics_finish_hinged,Sample,{blocked,3}})),
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
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_hinged,room,10,1,{finished,R,{blocked,3}}})),
        ok
    end,true) end}.

idle_compound_agent_blocks_moving_door_test_() ->
    {timeout,90,fun() -> with_door(fun(F = #{namespace := Ns}) ->
        {Pid,World} = enable(F), true = quod_reg:subscribe({runtime,Ns}),
        #{World := #{spec := Spec}} = worlds(Ns),
        Expected = #{fence => quod_physics:fence(Spec),structure => 2,tick => -1},
        {ok,Before,_} = quod_physics:snapshot(Pid,Expected),
        Body = lists:keyfind(3,1,maps:get(poses,Before)),
        R = {close,1,<<122:256>>},
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},
            door_action(Ns,{physics_close_hinged,room,10,0,<<122:256>>})),
        await_door(Ns,R,{blocked,3}), reconcile(Ns),
        {ok,After,_} = quod_physics:snapshot(Pid,Expected),
        ?assertEqual(Body,lists:keyfind(3,1,maps:get(poses,After))),
        %% Once the motor brakes, a player can leave contact through the
        %% retained physical query path without pushing the door.
        reconcile(Ns),
        QueryExpected = Expected#{incarnation => maps:get(run_token,Spec)},
        {ok,_,Escape} = quod_physics:motion_query(Pid,QueryExpected,{3,1},
            {travel,{vector,0,0,2000},{angular,0,0,0}},{query_limits,2,0,8,128},1000),
        ?assertMatch({clear,_,_},Escape),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
            {physics_hinged,room,10,1,{finished,R,{blocked,3}}}))
    end,true,fun(Rules) ->
        [case Rule of
            {physics_body_definition, room, 3, Rev, fixed, Position, {owned, Box, Density}} ->
                {physics_body_definition, room, 3, Rev, controlled, {pose,Position,{rotation,0,0,0}}, {owned, {parts,[{part,{vector,0,0,0},Box},
                         {part,{vector,0,900,0},{ball,100}}]}, Density}};
            _ -> Rule
        end || Rule <- Rules]
    end) end}.

native_geometry_budget_and_retained_parts_test() ->
    Limits = {2,2,8,100.0,2,8,4},
    Shape = {parts,[{{{0.0,0.0,0.0},{0.0,0.0,0.0}},{ball,0.5}},
                   {{{1.0,0.0,0.0},{0.0,1.5,0.0}},{box,0.5,0.2,0.1}}]},
    Row = {1,1,controlled,{{0.0,1.0,0.0},{0.0,0.0,0.0}},Shape,1.0},
    {ok,R} = quod_physics_native:new_world(Limits,1/60,-9.81),
    ?assertEqual({ok,1},quod_physics_native:install(R,[Row])),
    Before = quod_physics_native:sample(R),
    ?assertEqual({ok,0},quod_physics_native:install(R,[Row])),
    ?assertEqual(Before,quod_physics_native:sample(R)),
    Extra = {2,1,fixed,{{5.0,0.0,0.0},{0.0,0.0,0.0}},{solid,{box,1.0,1.0,1.0}},1.0},
    ?assertEqual({error,geometry_allowance},quod_physics_native:install(R,[Row,Extra])),
    ?assertEqual({error,retired},quod_physics_native:sample(R)).

unobstructed_door_signed_transition_test_() ->
    {timeout,90,fun() -> with_door(fun(F = #{namespace := Ns}) ->
        _ = enable(F),true = quod_reg:subscribe({runtime,Ns}),
        Id = <<102:256>>,R = {close,1,Id},
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_hinged,room,10,0,Id})),
        await_door(Ns,R,closed),
        ok
    end,false) end}.

hinged_command(Target) -> {position,Target,{motor,100,10,1000},{stop,20,target_or_contact}}.
hinged_recipe() ->
    {hinged,{box,50,1000,50},{box,1000,1000,100},1,{vector,0,1,0},
        {anchors,{vector,0,0,0},{vector,-1000,0,0}},{limits,-1500,1500},1500,hinged_command(0)}.

test_physics_frame(Spec) ->
    {physics_frame,maps:get(world,Spec),maps:get(authority,Spec),maps:get(epoch,Spec),
        maps:get(generation,Spec),maps:get(run_token,Spec),maps:get(structure,Spec)}.
test_hinge_sample(Spec,Revision,R,Tick,Angle,Contact,At,Expiry) ->
    {physics_sample,test_physics_frame(Spec),{activity,{hinge,10,Revision},R,hinged_command(0)},
        {revisions,[{joint,10,Revision},{body,10,Revision},{body,11,Revision}]},
        Tick,{validity,At,Expiry},{joint_position_mrad,Angle,Contact}}.

with_door(Fun,Obstructed) -> with_door(Fun,Obstructed,fun(Rules) -> Rules end).
with_door(Fun,Obstructed,Transform) ->
    with_world(fun(F = #{namespace := Ns}) ->
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
            {physics_add_hinged,room,10,11,{local,basic_door,1},{vector,0,1500,0},1})),
        %% Cleanup must preserve a failure before the test subscribed.
        try Fun(F) after catch quod_reg:unsubscribe({runtime,Ns}) end
    end,fun(Rules) ->
        Ns = <<"host-test-agent">>,Actor = {agent_instance_ref,Ns,{'_'},actor},
        Base = [Rule || Rule <- Rules, not (is_tuple(Rule) andalso element(1,Rule) =:= physics_body_definition andalso element(3,Rule) =:= 2)],
        Obstacle = case Obstructed of
            true -> [{physics_body_definition, room, 3, 1, fixed, {vector,1500,1500,-500}, {owned, {box,200,1000,200}, 1}}];
            false -> []
        end,
        Transform(Base ++ Obstacle ++ [
            {can_invoke,{physics_store_hinged_request,{'_'},{'_'},{'_'},{'_'}},Actor,{'_'},Ns},
            {can_invoke,{physics_finish_hinged,{'_'},{'_'}},Actor,{'_'},Ns},
            {can_edit_physics,room,{'_'}},
            {can_close_physics_hinged,room,10,{'_'}},
            {can_cancel_physics_hinged,room,10,{'_'}},
            {physics_hinged_class,basic_door,1,hinged_recipe()}])
    end).

door_action(Ns,Goal) ->
    {ok,Bytes,Signature} = quod_node_actor:signed_goal(execute,{'::',Ns,Goal},
        crypto:strong_rand_bytes(32),quod_time:now_ms()+10000),
    quod_client_goal_ingress:submit(Bytes,Signature).

await_door(Ns,R,Result) ->
    receive
        {applied_live,#{ns := Ns,applied_ops := Ops}} ->
            case lists:member({event,{physics_hinged_finished,room,10,R,Result}},Ops) of
                true -> ok;
                false -> await_door(Ns,R,Result)
            end;
        {physics_status,_,_,_,_,{failed,Why}} -> error({door_failed,Why});
        {physics_status,_,_,_,_,{observation,_,State}} when State =/= committed ->
            error({observation_failed,State,request_result()})
    after 15000 -> error({door_not_finished,
        maps:map(fun(_,#{pid := P,spec := S}) -> {gen_server:call(P,status),maps:with([generation,structure],S)} end,worlds(Ns)),
        quod_runtime:stats(Ns),request_result()}) end.

terminal_outcome_bridge_captures_failed_alternatives_test_() ->
    {timeout,90,fun() -> with_door(fun(F = #{namespace := Ns}) ->
        _ = enable(F),true = quod_reg:subscribe({runtime,Ns}),
        Id = <<111:256>>,R = {close,1,Id},
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_hinged,room,10,0,Id})),
        await_door_result(Ns,R,{blocked,3}),
        {ok,[#{'C' := {request,_,_,Bytes,Sig}}],_} =
            quod_prolog:prove_ro(Ns,{physics_hinged_request,room,10,{'C'}}),
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
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_hinged,room,10,0,Id})),
            Proof = receive {fipa_completion_prepared,P,_} -> P
                    after 10000 -> error(door_proof_not_paused) end,
            {ok,[#{'C' := {request,_,_,Bytes,Signature}}],_} =
                quod_prolog:prove_ro(Ns,{physics_hinged_request,room,10,{'C'}}),
            ?assertMatch({ok,_,{operation_pending,_}},quod_client_goal_ingress:resolve_operation(Bytes,Signature)),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
                {physics_move_body,room,3,1,2,{vector,5000,1500,-500}})),
            Proof ! release,
            await_door_result(Ns,R,closed),
            ?assertMatch({ok,_,{operation_outcome,_,#{status := rejected}}},
                         quod_client_goal_ingress:resolve_operation(Bytes,Signature)),
            {ok,[#{'C' := {request,_,closed,NewBytes,_}}],_} =
                quod_prolog:prove_ro(Ns,{physics_hinged_request,room,10,{'C'}}),
            ?assertNotEqual(Bytes,NewBytes)
        end,true,fun(Rules) -> [case Rule of
            {':-',Head = {physics_finish_hinged,_,_},Body} ->
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
            case lists:member({event,{physics_hinged_finished,room,10,R,Result}},Ops) of
                true -> ok;
                false -> await_door_result(Ns,R,Result)
            end;
        {physics_status,_,_,_,_,{failed,Why}} -> error({door_failed,Why})
    after 15000 -> error({door_not_finished,
        maps:map(fun(_,#{pid := P,spec := S}) -> {gen_server:call(P,status),maps:with([generation,structure],S)} end,worlds(Ns)),
        quod_runtime:stats(Ns),request_result()}) end.

saturated_actor_retains_required_observation_test_() ->
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
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_hinged,room,10,0,Id})),
            %% Sleeping is emitted only after the native contact has braked.
            receive {physics_status,_,Pid,_,_,sleeping} -> ok
            after 10000 -> error(door_not_braked) end,
            ?assertMatch(#{observations := #{{hinge,10} := offered}},gen_server:call(Pid,status)),
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
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_hinged,room,10,0,Id})),
            Proof = receive {fipa_completion_prepared,P,_} -> P
                    after 10000 -> error(door_proof_not_paused) end,
            {ok,[#{'C' := {request,_,_,Bytes,Signature}}],_} =
                quod_prolog:prove_ro(Ns,{physics_hinged_request,room,10,{'C'}}),
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
                quod_prolog:prove_ro(Ns,{physics_hinged_request,room,10,{'C'}}),
            case Outcome of
                committed -> ?assertEqual(Bytes,SavedBytes);
                rejected -> ?assertNotEqual(Bytes,SavedBytes)
            end
        end,true,fun(Rules) -> [case Rule of
            {':-',Head = {physics_finish_hinged,_,_},Body} ->
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
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_hinged,room,10,0,Id})),
            At = quod_time:now_ms(),Expiry = At+10000,
            Sample = test_hinge_sample(Spec,2,R,1,500,{contact,3,1},At,Expiry),
            %% Every forged/stale component is rejected even with the real
            %% physics actor's signature and an otherwise exact goal binding.
            Frame = element(2,Sample), WorldRef = element(2,Frame),
            Invalid = [setelement(2,Sample,setelement(2,Frame,setelement(2,WorldRef,<<"other-world">>))),
                setelement(2,Sample,setelement(2,Frame,setelement(3,WorldRef,<<99:256>>))),
                setelement(2,Sample,setelement(2,Frame,setelement(4,WorldRef,other_space))),
                setelement(2,Sample,setelement(3,Frame,maps:get(node,F))),
                setelement(2,Sample,setelement(4,Frame,2)),
                setelement(3,Sample,{activity,{hinge,10,1},R,hinged_command(0)}),
                setelement(3,Sample,{activity,{hinge,10,2},{close,2,Id},hinged_command(0)}),
                setelement(3,Sample,{activity,{hinge,10,2},R,hinged_command(100)}),
                setelement(4,Sample,{revisions,[{body,10,2},{body,11,2}]}),
                setelement(7,Sample,{rest_pose_mm_quaternion_million,{pose,{vector,0,0,0},{quaternion,0,0,0,1000000}}}),
                setelement(2,Sample,setelement(5,Frame,0)),
                setelement(2,Sample,setelement(6,Frame,<<99:256>>)),
                setelement(2,Sample,setelement(7,Frame,1)),
                setelement(4,Sample,{revisions,[{joint,10,2},{body,10,1},{body,11,2}]}),
                setelement(5,Sample,0),
                setelement(7,Sample,{joint_position_mrad,500,{contact,3,99}}),
                setelement(6,Sample,{validity,At,Expiry+1})],
            lists:foreach(fun(Bad) ->
                {B,SG} = sign_fixture(F,{physics_finish_hinged,Bad,{blocked,3}},Expiry),
                {SB,SS} = sign_fixture(F,{physics_store_hinged_request,Bad,{blocked,3},B,SG},Expiry),
                ?assertMatch({ok,_,{normalized,{failed,_}}},quod_client_goal_ingress:submit(SB,SS))
            end,Invalid),
            {Bytes,Sig} = sign_fixture(F,{physics_finish_hinged,Sample,{blocked,3}},Expiry),
            Store = {physics_store_hinged_request,Sample,{blocked,3},Bytes,Sig},
            {StoreBytes,StoreSig} = sign_fixture(F,Store,Expiry),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},quod_client_goal_ingress:submit(StoreBytes,StoreSig)),
            NewSample = setelement(5,Sample,2),
            {NewBytes,NewSig} = sign_fixture(F,{physics_finish_hinged,NewSample,{blocked,3}},Expiry),
            {ReplaceBytes,ReplaceSig} = sign_fixture(F,
                {physics_store_hinged_request,NewSample,{blocked,3},NewBytes,NewSig},Expiry),
            %% An absent outcome raises a typed unavailable error rather than
            %% proving absence. The public boundary conservatively normalizes it.
            ?assertMatch({ok,_,{normalized,{error,proof_unavailable}}},quod_client_goal_ingress:submit(ReplaceBytes,ReplaceSig)),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
                {physics_move_body,room,3,1,2,{vector,1500,1500,-500}})),
            %% Edit after store but before the original proof: no transaction
            %% entered ordering, so exact resolution must remain unknown.
            ?assertMatch({ok,_,{normalized,{failed,_}}},quod_client_goal_ingress:submit(Bytes,Sig)),
            ?assertMatch({ok,_,{operation_pending,_}},quod_client_goal_ingress:resolve_operation(Bytes,Sig)),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_cancel_hinged,room,10,R})),
            ?assertNotMatch({ok,_,{normalized,{committed,_,_}}},
                door_action(Ns,{physics_close_hinged,room,10,1,Id})),
            ?assertMatch({ok,_,{operation_pending,_}},quod_client_goal_ingress:resolve_operation(Bytes,Sig)),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
                {physics_move_hinged,room,10,1,3,{vector,0,1500,0}})),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_hinged,room,10,1,Id})),
            ?assertNotMatch({ok,_,{normalized,{committed,_,_}}},quod_client_goal_ingress:submit(Bytes,Sig)),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_hinged,room,10,2,{closing,{close,2,Id}}})),
            %% The reaction event pattern alone never supplies private owner authority.
            commit(Ns,{trigger_event,{observed,NewSample}})
        after sys:resume(Pid) end,
        await_door_result(Ns,{close,2,<<106:256>>},{blocked,3})
    end,true) end}.

shared_class_is_authorized_then_materialized_locally_test_() ->
    {timeout,90,fun() -> with_world(fun(F = #{namespace := Ns,node := Node}) ->
        {agent_instance_ref,ClassNs,ClassAnchor,_} = Node,
        Definition = hinged_recipe(),
        Class = {physics_hinged_class,shared_door,1,Definition},
        commit(ClassNs,{assertz,Class}),
        Source = {class_ref,ClassNs,ClassAnchor,shared_door,1},
        Add = {physics_add_hinged,room,10,11,Source,{vector,0,1500,0},1},
        %% Hosting the class ontology conveys no query authority.
        ?assertMatch({ok,_,{normalized,{failed,_}}},door_action(Ns,Add)),
        Query = {',',{current_ontology_identity,ClassNs,ClassAnchor},{physics_hinged_class,shared_door,1,{'_'}}},
        Grant = {can_invoke,Query,Node,{'_'},ClassNs},
        commit(ClassNs,{assertz,Grant}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,Add)),
        commit(ClassNs,{',',{retract,Grant},{retract,Class}}),
        {Pid,World} = enable(F),
        #{World := #{pid := Pid,spec := #{hinges := [_],structure := 2}}} = worlds(Ns),
        [reconcile(Ns) || _ <- lists:seq(1,3)],
        ?assertMatch(#{installs := 1},gen_server:call(Pid,status)),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_hinged_source,room,10,Source}))
    end,fun(Rules) -> Rules ++ [{can_edit_physics,room,{'_'}}] end) end}.

expired_queued_observation_is_freshly_sampled_test_() ->
    [{atom_to_list(Name),{timeout,90,fun() -> queued_observation_expiry(Admitted) end}} ||
      {Name,Admitted} <- [{runtime_cursor,false},{actor_queue,true}]].

queued_observation_expiry(Admitted) ->
        {ok,_} = application:ensure_all_started(gproc),
        true = quod_reg:reg({host_test,barrier}),
        try with_door(fun(F = #{namespace := Ns}) ->
            {Pid,_} = enable(F),true = quod_reg:subscribe({runtime,Ns}),
            commit(Ns,{',',{retract,{physics_allowances,room,{limits,64,64,256,1000000,{geometry,256,4096,4096}},16667,-9810,10000}},
                {assertz,{physics_allowances,room,{limits,64,64,256,1000000,{geometry,256,4096,4096}},16667,-9810,1000}}}),
            reconcile(Ns),
            Runtime = quod_reg:where({quod_runtime,Ns}),Parent = self(),Tag = make_ref(),
            Observe = fun(State,{in,{physics_observation,P,_,_,_,Sample,_}},_) when P =:= Pid ->
                              Parent ! {sample_seen,Tag,element(5,Sample),element(6,Sample)},State;
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
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_hinged,room,10,0,Id})),
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
                    quod_prolog:prove_ro(Ns,{physics_hinged_request,room,10,{'C'}}),
                ?assert(element(5,Sample) > Tick),
                {validity,NewAt,_} = element(6,Sample),?assert(NewAt >= Expiry)
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
            Pause = fun(none,{in,{physics_selected,_,_,#{activities := #{{hinge,10} := #{request := {close,_,_}}}}}},_) ->
                            Parent ! {closing_selected,Tag,self()},receive release -> held end;
                       (State,_,_) -> State end,
            Queued = fun(State,{in,{'$gen_call',_,{reconcile_resource,_,physics_worlds,future,_}}},_) ->
                              Parent ! {future_queued,Tag},State;
                        (State,_,_) -> State end,
            ok = sys:install(Pid,{Pause,none}),ok = sys:install(Runtime,{Queued,none}),
            try
                Id = <<108:256>>,R = {close,1,Id},
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_hinged,room,10,0,Id})),
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
                ?assertMatch(#{observations := #{{hinge,10} := capacity}},gen_server:call(Pid,status)),
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
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_close_hinged,room,10,0,Id})),
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

observation_command_delivery_order_test_() ->
    observation_edit_delivery_order(control).

observation_edit_delivery_order(Change) ->
    [{lists:flatten(io_lib:format("~p/~p/~p",[Saved,Order,Result])),{timeout,20,fun() ->
        with_door_simulator(Saved,fun(Pid,Spec,Token) ->
            {First,Tick} = door_sample_message(Pid,Token),
            Changed = case Change of
                control ->
                    Activities = maps:get(activities,Spec), Activity = maps:get({hinge,10},Activities),
                    Spec#{activities => Activities#{{hinge,10} => Activity#{command => hinged_command(100),
                        native_command => {position,0.1,{100.0,10.0,1000.0},{0.02,target_or_contact}}}}};
                _ -> maps:merge(Spec,Change)
            end,
            Select = {physics_selected,self(),make_ref(),Changed},
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
    receive {physics_observation,Pid,_,Token,Ref,Sample,_} -> {Ref,element(5,Sample)}
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
        Sample = test_hinge_sample(Spec#{generation => 1,run_token => Token,structure => 1},
            1,R,1,0,clear,quod_time:now_ms(),quod_time:now_ms()+5000),
        Saved = case SavedCustody of true -> {request,Sample,closed,<<1>>,<<0:512>>}; false -> none end,
        Current = Spec#{generation => 1,run_token => Token,
            custody => {request,Token,0,<<2>>,<<0:512>>},
            limits => {2,2,1,100.0,2,0,0},dt => 1/60,gravity => 0.0,structure => 1,
            bodies => [{10,1,dynamic,{{0.0,1.0,0.0},{0.0,0.0,0.0}},{solid,{box,1.0,1.0,0.1}},1.0},
                       {11,1,fixed,{{0.0,1.0,0.0},{0.0,0.0,0.0}},{solid,{box,0.05,1.0,0.05}},1.0}],
            hinges => [{{{10,1},1,{11,1},{0.0,1.0,0.0},{{0.0,0.0,0.0},{-1.0,0.0,0.0}},
                         {-1.5,1.5},1.5},0.0}],
            activities => #{{hinge,10} => #{reference => {hinge,10,1},request => R,
                command => hinged_command(0),native_command => {position,0.0,{100.0,10.0,1000.0},{0.02,target_or_contact}},
                references => [{joint,10,1},{body,10,1},{body,11,1}],custody => Saved,outcome_key => none}}},
        Pid ! {physics_selected,self(),make_ref(),Current},
        Pid ! {physics_result,self(),Activation,{ok,ignored,{normalized,{committed,ignored,ignored}}}},
        case SavedCustody of true -> reject_door_resolve(Pid); false -> ok end,
        Fun(Pid,Current,Token)
    end).


same_namespace_signed_chair_push_test_() ->
    {timeout,60,fun() -> with_chair(fun(F = #{namespace := Ns,identity := Identity}) ->
        {Pid,World} = enable(F),
        Anchor = quod_simplex:genesis_hash(Ns),
        Principal = {agent_instance_ref,Ns,Anchor,viewer},
        commit(Ns,{assertz,{agent_key,viewer,maps:get(pubkey,Identity),active}}),
        {_,_,_,OldRef,_} = install_test_control(F#{node => Principal},Pid,World,
            {motion,free,2000,1600,1000,{query_limits,2,0,8,128},[]}),
        quod_physics:unwatch(Pid,OldRef), _ = gen_server:call(Pid,status),
        commit(Ns,{',',{assertz,{can_view_physics,room,Principal}},
                       {assertz,{world_view,room,playing,[]}}}), reconcile(Ns),
        Parent = self(), Socket = spawn_link(fun() -> simulation_socket(Parent,#{peer => {127,0,0,1}}) end),
        try
            Socket ! {client,simulation_open(F,simulation_session(Identity),Principal)},
            Projection = simulation_reply(Socket,<<"projection">>),
            #{control := Control} = simulation_state(Socket),
            #{World := #{spec := Spec}} = worlds(Ns),
            Frame = {physics_frame,World,maps:get(authority,Spec),maps:get(epoch,Spec),
                maps:get(generation,Spec),maps:get(run_token,Spec),maps:get(structure,Spec)},
            Initial = maps:get(<<"frame">>,Projection),
            Registration = base64:decode(maps:get(<<"registration">>,Initial),#{mode => urlsafe,padding => false}),
            Goal = {'::',Ns,{',',{current_ontology_identity,Ns,Anchor},
                {physics_control_input,room,{control_frame,Frame,Registration},
                    1,1,{push,{body,3,1},{vector,1000,0,0}},{0}}}},
            {Canonical,_,_} = erlog_int:term_instance(Goal,0),
            {ok,Text} = quod_client_goal_parser:format(Canonical),
            Request = #{network_identity => <<42:256>>,
                agent_namespace => Ns,agent_genesis_anchor => Anchor,agent_instance_text => <<"viewer.">>,
                signing_public_key => maps:get(pubkey,Identity),operation_id => crypto:strong_rand_bytes(32),
                not_after_ms => quod_time:now_ms()+10000,mode => control,parser_version => 3,goal_text => Text},
            {Both,_,_} = erlog_int:term_instance({',',Goal,Goal},0),
            {ok,BothText} = quod_client_goal_parser:format(Both),
            {ok,BothBytes} = quod_client_goal:encode(Request#{goal_text => BothText}),
            assert_reason(transient_already_staged,
                quod_client_goal_ingress:submit(BothBytes,quod_identity:sign(BothBytes,Identity))),
            ?assertMatch(#{inputs := Empty} when map_size(Empty) =:= 0,gen_server:call(Pid,status)),
            {ok,Bytes} = quod_client_goal:encode(Request#{operation_id => crypto:strong_rand_bytes(32)}),
            ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},
                quod_client_goal_ingress:submit(Bytes,quod_identity:sign(Bytes,Identity))),
            ?assertMatch(#{inputs := #{Principal := #{sequence := 1}}},gen_server:call(Pid,status)),
            {ok,DuplicateBytes} = quod_client_goal:encode(Request#{operation_id => crypto:strong_rand_bytes(32)}),
            {ok,_,{normalized,{failed,DuplicateReasons}}} =
                quod_client_goal_ingress:submit(DuplicateBytes,quod_identity:sign(DuplicateBytes,Identity)),
            ?assertEqual({ok,[{stale_sequence,1}]},quod_wire_term:decode_failure_reasons(DuplicateReasons)),
            View = maps:get(<<"view">>,Projection),
            simulation_ack(Socket,View,Initial),
            _ = simulation_input_frame(Socket,View,<<"1">>),
            Expected = #{fence => quod_physics:fence(Spec),incarnation => maps:get(run_token,Spec),structure => 1},
            {ok,_,{3,1,world,{X,_,_},_,_}} = quod_physics:body_state(Pid,Expected,{3,1},1000),
            ?assert(X > 0),
            ?assertMatch({control,Principal,_,_},Control)
        after Socket ! stop end
    end) end}.

simulation_ack(Socket,View,Frame) ->
    Socket ! {client,iolist_to_binary(json:encode(#{type => ack,view => View,tick => maps:get(<<"tick">>,Frame)}))}.

simulation_input_frame(Socket,View,Sequence) ->
    Delivered = simulation_reply(Socket,<<"simulation_frame">>),
    Frame = maps:get(<<"frame">>,Delivered),
    simulation_ack(Socket,View,Frame),
    case maps:get(<<"control_state">>,Frame) of
        #{<<"sequence">> := Sequence,<<"pending">> := false,<<"result">> := <<"pushed">>} -> Frame;
        _ -> simulation_input_frame(Socket,View,Sequence)
    end.

signed_chair_push_checkpoint_and_recovery_test_() ->
    {timeout,90,fun() -> with_chair(fun(F = #{namespace := Ns,node := Human}) ->
        {Pid,World} = enable(F), true = quod_reg:subscribe({runtime,Ns}),
        try
            {_,Expected,OldFrame,_,_} = install_test_control(F,Pid,World,
                {motion,free,2000,1600,1000,{query_limits,2,0,8,128},[]}),
            Push = {push,{body,3,1},{vector,1000,0,0}},
            Send = fun(Fence,Seq,Input) -> control_goal({'::',Ns,
                {physics_control_input,room,Fence,1,Seq,Input,{0}}}) end,
            OldCommand = fun(Seq,Input) -> Send(OldFrame,Seq,Input) end,
            ?assertMatch({ok,_,{normalized,{failed,_}}},OldCommand(0,{push,{body,3,0},{vector,1000,0,0}})),
            ?assertMatch({ok,_,{normalized,{failed,_}}},OldCommand(0,{push,{body,3,1},{vector,5001,0,0}})),
            commit(Ns,{retract,{can_push_physics_body,room,{'_'},3}}), reconcile(Ns),
            ?assertMatch({ok,_,{normalized,{failed,_}}},OldCommand(0,Push)),
            commit(Ns,{assertz,{can_push_physics_body,room,{'_'},3}}), reconcile(Ns),
            assert_reason(stale_registration,OldCommand(1,Push)),
            {ok,Ref,Initial} = quod_physics:watch(Pid,Expected,none),
            Frame = setelement(3,OldFrame,maps:get(registration,Initial)),
            Command = fun(Seq,Input) -> Send(Frame,Seq,Input) end,
            ?assertMatch({ok,_,{normalized,{failed,_}}},control_goal({'::',Ns,
                {',',{physics_control_input,room,Frame,1,1,Push,{0}},fail}})),
            ?assertMatch(#{inputs := M} when map_size(M) =:= 0,gen_server:call(Pid,status)),
            quod_physics:ack(Pid,Ref,maps:get(tick,Initial)),
            ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Command(1,Push)),
            {Moved,pushed} = input_frame(Pid,Ref,Human,1),
            {3,1,world,{X,_,_},_,{Vx,_,_}} = lists:keyfind(3,1,maps:get(poses,Moved)),
            ?assert(X > 0.0), ?assert(Vx > 0.0),
            ?assertNotMatch({ok,_,{normalized,{answers,_,[_]}}},Command(1,Push)),
            %% Individually bounded impulses must also respect resulting speed.
            ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Command(2,
                {push,{body,3,1},{vector,5000,0,0}})),
            {_,refused} = input_frame(Pid,Ref,Human,2),
            %% Appearance and unchanged resource installation cannot reset the body.
            commit(Ns,{assertz,{chair_label,<<"Moved chair">>}}), reconcile(Ns),
            {ok,_,{3,1,world,{Later,_,_},_,_}} = quod_physics:body_state(Pid,Expected,{3,1},1000),
            ?assert(Later >= X),
            R = {rest,1,<<201:256>>},
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                door_action(Ns,{physics_checkpoint_body,room,3,1,0,<<201:256>>})),
            await_rest(Ns,R), reconcile(Ns),
            FirstCP = rest_checkpoint_fact(Ns),
            %% Explicitly checkpointing an unchanged sleeping chair still
            %% requires a new sample; routine reconciliation requires no work.
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                door_action(Ns,{physics_checkpoint_body,room,3,1,1,<<205:256>>})),
            await_rest(Ns,{rest,2,<<205:256>>}), reconcile(Ns),
            CP = rest_checkpoint_fact(Ns),
            ?assert(element(7,element(4,CP)) > element(7,element(4,FirstCP))),
            {rest_v1,3,1,_,world_mm_quaternion_million,{pose,{vector,SavedX,_,_},_},zero_velocity} = CP,
            ?assert(SavedX > 0),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
                {physics_body_definition, room, 3, 1, dynamic, {vector,0,500,0}, {owned, {box,500,500,500}, 1}})),
            {ok,[#{'C' := {request,Sample,rest,Bytes,Signature}}],_} =
                quod_prolog:prove_ro(Ns,{physics_rest_request,room,3,{'C'}}),
            ?assertMatch({ok,_,{operation_outcome,_,#{status := committed}}},
                quod_client_goal_ingress:resolve_operation(Bytes,Signature)),
            ?assertMatch({ok,_,{normalized,{failed,_}}},submit_fixture(F,{physics_finish_rest,Sample})),
            Before = gen_server:call(Pid,status),
            assert_no_physics_io(fun() ->
                [reconcile(Ns) || _ <- lists:seq(1,3)],
                ?assertEqual(maps:with([installs,steps],Before),
                    maps:with([installs,steps],gen_server:call(Pid,status)))
            end),
            %% A second, uncheckpointed push is deliberately lost on runtime
            %% collapse. Recovery must use the rest checkpoint, not this motion.
            {ok,ResumeRef,ResumeView} = quod_physics:watch(Pid,Expected,none),
            ResumeFrame = setelement(3,Frame,maps:get(registration,ResumeView)),
            quod_physics:ack(Pid,ResumeRef,maps:get(tick,ResumeView)),
            ?assertMatch({ok,_,{normalized,{answers,_,[_]}}},Send(ResumeFrame,3,Push)),
            {Unsaved,pushed} = input_frame(Pid,ResumeRef,Human,3),
            {3,1,world,{UnsavedX,_,_},_,{UnsavedVx,_,_}} = lists:keyfind(3,1,maps:get(poses,Unsaved)),
            ?assert(UnsavedX > SavedX/1000), ?assert(UnsavedVx > 0),
            Monitor = monitor(process,Pid), exit(quod_reg:where({quod_runtime,Ns}),kill),
            receive {'DOWN',Monitor,process,Pid,_} -> ok after 5000 -> error(chair_owner_alive) end,
            {Next,World} = installed(Ns), ?assertNotEqual(Pid,Next),
            #{World := #{spec := Spec}} = worlds(Ns),
            ?assert(maps:get(generation,Spec) > element(5,element(2,Frame))),
            Fresh = #{fence => quod_physics:fence(Spec),structure => 1,incarnation => maps:get(run_token,Spec)},
            {ok,_,{3,1,world,{RestoredX,_,_},_,_}} = quod_physics:body_state(Next,Fresh,{3,1},1000),
            ?assert(abs(RestoredX-SavedX/1000) < 0.002),
            ?assertNotMatch({ok,_,{normalized,{answers,_,[_]}}},Command(3,Push)),
            ?assertMatch(#{inputs := M} when map_size(M) =:= 0,gen_server:call(Next,status)),
            %% Editing owns the baseline and checkpoint invalidation in one commit.
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
                {physics_move_body,room,3,1,1,{vector,4000,500,0}})),
            ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{physics_checkpoint,room,CP})),
            {Next,World} = installed(Ns),
            {ok,_,{3,2,world,{EditX,_,_},_,_}} = quod_physics:body_state(Next,Fresh#{structure => 2},{3,2},1000),
            ?assert(abs(EditX-4.0) < 0.001)
        after catch quod_reg:unsubscribe({runtime,Ns}) end
    end) end}.

with_chair(Fun) -> with_chair(Fun,fun(Rules) -> Rules end).
with_chair(Fun,Transform) -> with_world(Fun,fun(Rules) ->
    Ns = <<"host-test-agent">>, Actor = {agent_instance_ref,Ns,{'_'},actor},
    Transform([case R of {physics_body_definition, room, 2, 1, _, _, {owned, _, _}} ->
        {physics_body_definition, room, 2, 1, controlled, {vector,-3000,1000,0}, {owned, {box,500,1000,500}, 1}}; _ -> R end || R <- Rules] ++
    [{physics_body_definition, room, 3, 1, dynamic, {vector,0,500,0}, {owned, {box,500,500,500}, 1}},
     {can_push_physics_body,room,{'_'},3},
     {physics_push_allowances,room,{'_'},3,{push_limits,5000,5000}},
     {can_checkpoint_physics_body,room,3,{'_'}}, {physics_rest_policy,room,3,{recovery,5,128}},
     {can_edit_physics,room,{'_'}},
     {can_invoke,{physics_store_rest_request,{'_'},{'_'},{'_'}},Actor,{'_'},Ns},
     {can_invoke,{physics_finish_rest,{'_'}},Actor,{'_'},Ns}])
end).

rest_checkpoint_fact(Ns) ->
    {ok,[#{'C' := CP}],_} = quod_prolog:prove_ro(Ns,{physics_checkpoint,room,{'C'}}), CP.
await_rest(Ns,R) ->
    receive
        {applied_live,#{ns := Ns,applied_ops := Ops}} ->
            case lists:member({event,{physics_body_checkpointed,room,3,R}},Ops) of
                true -> ok; false -> await_rest(Ns,R)
            end;
        {physics_status,_,_,_,_,{failed,Why}} -> error({rest_failed,Why});
        {physics_status,_,_,_,_,{observation,{rest,3},State}} when State =/= committed ->
            error({rest_observation_failed,State,request_result()})
    after 15000 -> error({rest_not_finished,worlds(Ns),request_result()}) end.

native_rest_recovery_rejects_overlap_and_bad_rotation_test() ->
    Ground = {1,1,fixed,{{0.0,-0.5,0.0},{0.0,0.0,0.0}},{solid,{box,10.0,0.5,10.0}},1.0},
    Chair = {2,1,dynamic,{{0.0,0.5,0.0},{0.0,0.0,0.0}},{solid,{box,0.5,0.5,0.5}},1.0},
    Wall = {3,1,fixed,{{2.0,0.5,0.0},{0.0,0.0,0.0}},{solid,{box,0.5,0.5,0.5}},1.0},
    lists:foreach(fun({Rows,Pose}) ->
        {ok,Resource} = quod_physics_native:new_world({3,3,4,100.0,64,1024,1024},1/60,-9.81),
        {ok,_} = quod_physics_native:install(Resource,Rows),
        ?assertEqual({error,invalid_checkpoint},quod_physics_native:restore_rest(Resource,[{2,1,Pose,0.005,128}])),
        ?assertEqual({error,retired},quod_physics_native:sample(Resource))
    end,[{[Ground,Chair,Wall],{{2.0,0.5,0.0},{0.0,0.0,0.0,1.0}}},
         {[Ground,Chair],{{2.0,0.5,0.0},{0.0,0.0,0.0,0.0}}}]).

rest_recovery_overlap_fails_visibly_test_() ->
    {timeout,60,fun() -> with_chair(fun(F = #{namespace := Ns}) ->
        {Pid,World} = enable(F),
        #{World := #{spec := Spec}} = worlds(Ns),
        Source = {source,maps:get(authority,Spec),maps:get(epoch,Spec),maps:get(generation,Spec),
                  maps:get(run_token,Spec),1,1},
        %% The live chair keeps its current pose; only its successor restores.
        CP = {rest_v1,3,1,Source,world_mm_quaternion_million,
              {pose,{vector,-3000,1000,0},{quaternion,0,0,0,1000000}},zero_velocity},
        commit(Ns,{assertz,{physics_checkpoint,room,CP}}), reconcile(Ns),
        Monitor = monitor(process,Pid), exit(Pid,kill),
        receive {'DOWN',Monitor,process,Pid,killed} -> ok after 5000 -> error(chair_owner_alive) end,
        receive {physics_status,_,Next,World,_,{failed,invalid_checkpoint}} when Next =/= Pid ->
            ?assertMatch(#{phase := {failed,invalid_checkpoint}},gen_server:call(Next,status)),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_checkpoint,room,CP}))
        after 10000 -> error(overlap_not_reported) end
    end) end}.

chair_edit_races_prepared_checkpoint_test_() ->
    {timeout,90,fun() ->
        {ok,_} = application:ensure_all_started(gproc),
        true = quod_reg:reg({host_test,barrier}),
        try with_chair(fun(F = #{namespace := Ns}) ->
            {Pid,World} = enable(F), true = quod_reg:subscribe({runtime,Ns}),
            try
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
                    {physics_checkpoint_body,room,3,1,0,<<202:256>>})),
                {Proof,Operation} = receive {fipa_completion_prepared,P,Op} -> {P,Op}
                        after 10000 -> error(rest_proof_not_paused) end,
                {ok,[#{'C' := Custody = {request,_,rest,Bytes,Signature}}],_} =
                    quod_prolog:prove_ro(Ns,{physics_rest_request,room,3,{'C'}}),
                ?assertMatch({ok,_,{operation_pending,_}},quod_client_goal_ingress:resolve_operation(Bytes,Signature)),
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
                    {physics_move_body,room,3,1,1,{vector,4000,500,0}})),
                Proof ! release,
                receive {agent_request_finished,_,_,_,_,{ok,#{operation_ref := Operation},{normalized,{error,conflict_retry}}}} -> ok
                after 10000 -> error({rest_race_not_rejected,request_result()}) end,
                %% The client failure can precede terminal publication. Wait
                %% on applied progress; never infer rejection from that reply.
                await_checkpoint_rejection(Ns,Bytes,Signature,quod_time:mono_ms()+10000),
                ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{physics_checkpoint,room,{'_'}})),
                ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_rest_request,room,3,Custody})),
                %% The cancelled request cannot be resampled or replayed on restart.
                Monitor = monitor(process,Pid), exit(Pid,kill),
                receive {'DOWN',Monitor,process,Pid,killed} -> ok after 5000 -> error(owner_alive) end,
                {Next,World} = installed(Ns),
                ?assertMatch(#{observations := O} when map_size(O) =:= 0,gen_server:call(Next,status))
            after catch quod_reg:unsubscribe({runtime,Ns}) end
        end,fun(Rules) -> [case Rule of
            {':-',Head = {physics_finish_rest,_},Body} -> {':-',Head,{',',Body,test_fipa_completion}};
            _ -> Rule end || Rule <- Rules] end)
        after gproc:unreg(quod_reg:name({host_test,barrier})) end
    end}.

chair_unknown_checkpoint_custody_is_not_resubmitted_test_() ->
    {timeout,60,fun() -> with_chair(fun(F = #{namespace := Ns}) ->
        {Pid,World} = enable(F),
        #{World := #{spec := Spec}} = worlds(Ns),
        ok = sys:suspend(Pid),
        try
            R = {rest,1,<<203:256>>},
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
                {physics_checkpoint_body,room,3,1,0,<<203:256>>})),
            At = quod_time:now_ms(), Expiry = At+10000,
            Sample = {physics_sample,test_physics_frame(Spec),{activity,{rest,3,1},R,rest},
                {revisions,[{body,3,1}]},1,{validity,At,Expiry},
                {rest_pose_mm_quaternion_million,{pose,{vector,500,500,0},{quaternion,0,0,0,1000000}}}},
            {Bytes,Signature} = sign_fixture(F,{physics_finish_rest,Sample},Expiry),
            {Store,StoreSig} = sign_fixture(F,{physics_store_rest_request,Sample,Bytes,Signature},Expiry),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},quod_client_goal_ingress:submit(Store,StoreSig)),
            NewSample = setelement(5,Sample,2),
            {NewBytes,NewSig} = sign_fixture(F,{physics_finish_rest,NewSample},Expiry),
            {Replace,ReplaceSig} = sign_fixture(F,{physics_store_rest_request,NewSample,NewBytes,NewSig},Expiry),
            ?assertMatch({ok,_,{normalized,{error,proof_unavailable}}},quod_client_goal_ingress:submit(Replace,ReplaceSig)),
            ?assertMatch({ok,_,{operation_pending,_}},quod_client_goal_ingress:resolve_operation(Bytes,Signature))
        after sys:resume(Pid) end,
        reconcile(Ns),
        receive {physics_status,_,Pid,World,_,{unavailable,{observation,{rest,3},unresolved}}} -> ok
        after 10000 -> error(unknown_checkpoint_not_held) end,
        ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{physics_checkpoint,room,{'_'}})),
        assert_no_physics_io(fun() -> [reconcile(Ns) || _ <- lists:seq(1,3)] end),
        {ok,[#{'C' := Original}],_} = quod_prolog:prove_ro(Ns,{physics_rest_request,room,3,{'C'}}),
        Monitor = monitor(process,Pid), exit(Pid,kill),
        receive {'DOWN',Monitor,process,Pid,killed} -> ok after 5000 -> error(chair_owner_alive) end,
        {Next,World} = installed(Ns),
        receive {physics_status,_,Next,World,_,{unavailable,{observation,{rest,3},unresolved}}} -> ok
        after 10000 -> error(recovered_unknown_not_held) end,
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_rest_request,room,3,Original})),
        ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{physics_checkpoint,room,{'_'}})),
        %% An authored edit fences the old finish even if its backend outcome
        %% stays unknown. A distinct request must be able to checkpoint the edit.
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
            {physics_move_body,room,3,1,1,{vector,4000,500,0}})),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_rest_request,room,3,Original})),
        {request,_,rest,OldBytes,OldSignature} = Original,
        ?assertMatch({ok,_,{operation_pending,_}},
            quod_client_goal_ingress:resolve_operation(OldBytes,OldSignature)),
        true = quod_reg:subscribe({runtime,Ns}),
        try
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
                {physics_checkpoint_body,room,3,2,1,<<206:256>>})),
            await_rest(Ns,{rest,2,<<206:256>>}),
            ?assertMatch({rest_v1,3,2,_,_,_,_},rest_checkpoint_fact(Ns)),
            ?assertMatch({ok,_,{operation_pending,_}},
                quod_client_goal_ingress:resolve_operation(OldBytes,OldSignature))
        after catch quod_reg:unsubscribe({runtime,Ns}) end
    end) end}.

%% The real owner renews certainly-unsent rest evidence only after another
%% completed native step; no expiry is appended to an old sample identity.
expired_rest_observation_resamples_test_() ->
    {timeout,20,fun() -> with_simulator(none,fun(Pid,Spec) ->
        {Activation,Token} = receive
            {physics_work,Pid,_,A,activate,{{physics_activate,room,0,T},_},_} -> {A,T}
        after 5000 -> error(activation_missing) end,
        R = {rest,1,<<204:256>>},
        Current = Spec#{generation => 1,run_token => Token,
            custody => {request,Token,0,<<2>>,<<0:512>>},
            limits => {1,1,0,100.0,1,0,0},dt => 1/60,gravity => 0.0,structure => 1,
            bodies => [{3,1,dynamic,{{0.0,0.5,0.0},{0.0,0.0,0.0}},{solid,{box,0.5,0.5,0.5}},1.0}],
            hinges => [],activities => #{{rest,3} => #{reference => {rest,3,1},
                request => R,command => rest,native_command => none,references => [{body,3,1}],
                custody => none,outcome_key => none}}},
        Pid ! {physics_selected,self(),make_ref(),Current},
        Pid ! {physics_result,self(),Activation,{ok,ignored,{normalized,{committed,ignored,ignored}}}},
        {First,Tick} = rest_sample_message(Pid,Token),
        Pid ! {physics_result,self(),First,{error,expired_observation}},
        {Second,NextTick} = rest_sample_message(Pid,Token),
        ?assertNotEqual(First,Second), ?assert(NextTick > Tick),
        ?assertMatch(#{steps := Steps} when Steps =:= NextTick,gen_server:call(Pid,status))
    end) end}.

rest_sample_message(Pid,Token) ->
    receive {physics_observation,Pid,_,Token,Ref,Sample = {physics_sample,_,{activity,{rest,_,_},_,rest},_,_,_,_},_} ->
        {Ref,element(5,Sample)}
    after 10000 -> error(rest_observation_lost) end.

authored_nonbox_edit_invalidates_rest_checkpoint_test_() ->
    [{atom_to_list(Kind),{timeout,60,fun() ->
        Shape = case Kind of
            ball -> {ball,500};
            compound -> {parts,[{part,{pose,{vector,0,0,0},{rotation,0,0,0}},{box,500,500,500}}]}
        end,
        OldPose = {pose,{vector,0,500,0},{rotation,0,785,0}},
        with_chair(fun(F = #{namespace := Ns}) ->
            _ = enable(F), true = quod_reg:subscribe({runtime,Ns}),
            try
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
                    {physics_checkpoint_body,room,3,1,0,<<207:256>>})),
                await_rest(Ns,{rest,1,<<207:256>>}),
                ?assertMatch({rest_v1,3,1,_,_,_,_},rest_checkpoint_fact(Ns)),
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
                    {physics_move_body,room,3,1,1,{vector,4000,500,0}})),
                ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{physics_checkpoint,room,{'_'}})),
                ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_body_definition, room, 3, 2, dynamic, {pose,{vector,4000,500,0},{rotation,0,785,0}}, {owned, Shape, 1}}))
            after catch quod_reg:unsubscribe({runtime,Ns}) end
        end,fun(Rules) -> [case R of {physics_body_definition, room, 3, 1, dynamic, _, {owned, _, 1}} ->
            {physics_body_definition, room, 3, 1, dynamic, OldPose, {owned, Shape, 1}}; _ -> R end || R <- Rules] end)
    end}} || Kind <- [ball,compound]].

await_checkpoint_rejection(Ns,Bytes,Signature,Deadline) ->
    Engine = quod_reg:where({quod_prolog,Ns}),
    case quod_client_goal_ingress:resolve_operation(Bytes,Signature) of
        {ok,_,{operation_pending,_}} ->
            Remaining = max(0,Deadline-quod_time:mono_ms()),
            receive {projection_advanced,Engine,_} -> await_checkpoint_rejection(Ns,Bytes,Signature,Deadline)
            after Remaining -> error(checkpoint_rejection_not_published) end;
        Outcome -> ?assertMatch({ok,_,{operation_outcome,_,#{status := rejected}}},Outcome)
    end.

%% Both examples compose the same production libraries. Only these authored
%% data/rule files choose object geometry, axis, target and domain consequence.
generic_hinged_signed_view_recovery_test_() ->
    {timeout,180,fun() -> with_hinged_examples(fun(First,Second) ->
        [verify_hinged_signed_view(F) || F <- [First,Second]]
    end) end}.

verify_hinged_signed_view(F = #{namespace := Ns,identity := Identity,target := Target}) ->
    Obstacle = maps:get(obstacle,F),
    {Admission,_,_} = erlog_int:term_instance({transaction,list_conjunction([
            {current_principal,{'P'}},{can_edit_physics,room,{'P'}},
            {physics_body_capacity,room,1},{physics_allocate_body,room,12},
            {physics_advance_structure,room,3},
            {assertz,{physics_body_definition,room,12,3,fixed,Obstacle,{owned,{box,200,1000,200},1}}}])},0),
    ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,Admission)),
    {Pid,World} = enable(F),
    Pub = maps:get(pubkey,Identity),
    commit(Ns,{assertz,{agent_key,viewer,Pub,active}}),
    Principal = {agent_instance_ref,Ns,quod_simplex:genesis_hash(Ns),viewer},
    ViewGoal = {',',{current_ontology_identity,Ns,{'_'}},
                     {client_world_view,room,playing,{'_'},{'_'}}},
    Rules = quod_prolog:read_terms("priv/ontologies/hinged_example_view.pl") ++
        [{can_invoke,ViewGoal,Principal,{'_'},Ns},{can_view_physics,room,Principal},
         {':-',{world_view,room,playing,{'Marks'}},{hinged_example_view,room,{'Marks'}}}],
    commit(Ns,list_conjunction([{assertz,R} || R <- Rules])), reconcile(Ns),
    {ok,[#{'Marks' := AuthoredMarks}],_} = quod_prolog:prove_ro(Ns,{world_view,room,playing,{'Marks'}}),
    ?assertMatch({ok,[_],_},quod_prolog:prove_ro(<<"physics-test-rendering">>,{well_formed_scene,AuthoredMarks})),
    Parent = self(), Socket = spawn_link(fun() -> simulation_socket(Parent,#{peer => {127,0,0,1}}) end),
    try
        Session = simulation_session(Identity),
        Open = fun() -> Socket ! {client,simulation_open(F,Session)} end,
        Open(), Initial = simulation_reply(Socket,<<"projection">>),
        ?assertEqual(<<"active">>,maps:get(<<"selection">>,Initial)),
        InitialPose = hinged_view_pose(Initial),
        assert_hinged_view_label(Initial,<<"Ready to close">>),
        %% The viewer's key is real, but viewing grants no mutation authority.
        Id = <<181:256>>, Goal = {physics_close_hinged,room,10,0,Id},
        ?assertMatch({ok,_,{normalized,{failed,_}}},hinged_view_action(F,Goal)),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_hinged,room,10,0,idle})),
        commit(Ns,{assertz,{can_invoke,Goal,Principal,{'_'},Ns}}),
        true = quod_reg:subscribe({runtime,Ns}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},hinged_view_action(F,Goal)),
        _ = await_hinged_ops(Ns,{close,1,Id},{blocked,12}),
        _ = simulation_reply(Socket,<<"refresh">>), Open(),
        Blocked = simulation_reply(Socket,<<"projection">>),
        assert_hinged_view_label(Blocked,<<"Blocked">>),
        BlockedPose = hinged_view_pose(Blocked), ?assertNotEqual(InitialPose,BlockedPose),
        {ok,[#{'Angle' := BlockedAngle}],_} = quod_prolog:prove_ro(Ns,
            {physics_checkpoint,room,{hinge,10,2,{body,10,2},{body,11,2},1,{'_'},{'Angle'}}}),
        ?assert(abs(BlockedAngle-Target) > 20),
        M1 = monitor(process,Pid), exit(Pid,kill),
        receive {'DOWN',M1,process,Pid,killed} -> ok after 5000 -> error(owner_alive) end,
        _ = simulation_reply(Socket,<<"refresh">>),
        {BlockedOwner,World} = installed(Ns), ?assertNotEqual(Pid,BlockedOwner), Open(),
        RestoredBlocked = simulation_reply(Socket,<<"projection">>),
        assert_hinged_view_label(RestoredBlocked,<<"Blocked">>),
        assert_hinged_view_restored_pose(BlockedPose,hinged_view_pose(RestoredBlocked)),
        {vector,OX,OY,OZ} = Obstacle,
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
            {physics_move_body,room,12,3,3,{vector,OX+5000,OY,OZ}})),
        _ = simulation_reply(Socket,<<"refresh">>), Open(),
        _ = simulation_reply(Socket,<<"projection">>),
        NextId = <<182:256>>, NextGoal = {physics_close_hinged,room,10,1,NextId},
        commit(Ns,{assertz,{can_invoke,NextGoal,Principal,{'_'},Ns}}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},hinged_view_action(F,NextGoal)),
        _ = await_hinged_ops(Ns,{close,2,NextId},closed),
        _ = simulation_reply(Socket,<<"refresh">>), Open(),
        Closed = simulation_reply(Socket,<<"projection">>),
        assert_hinged_view_label(Closed,<<"Closed">>),
        ClosedPose = hinged_view_pose(Closed), ?assertNotEqual(InitialPose,ClosedPose),
        {ok,[#{'Angle' := Angle}],_} = quod_prolog:prove_ro(Ns,
            {physics_checkpoint,room,{hinge,10,2,{body,10,2},{body,11,2},2,{'_'},{'Angle'}}}),
        ?assert(abs(Angle-Target) =< 20),
        BeforeOther = quod_prolog:applied(maps:get(other_namespace,F)),
        M = monitor(process,BlockedOwner), exit(BlockedOwner,kill),
        receive {'DOWN',M,process,BlockedOwner,killed} -> ok after 5000 -> error(owner_alive) end,
        _ = simulation_reply(Socket,<<"refresh">>),
        {Next,World} = installed(Ns), ?assertNotEqual(BlockedOwner,Next), Open(),
        Restored = simulation_reply(Socket,<<"projection">>),
        assert_hinged_view_label(Restored,<<"Closed">>),
        assert_hinged_view_restored_pose(ClosedPose,hinged_view_pose(Restored)),
        ?assertEqual(BeforeOther,quod_prolog:applied(maps:get(other_namespace,F))),
        {ok,[#{'Results' := Results}],_} = quod_prolog:prove_ro(Ns,
            {findall,{'R'},{hinged_result,maps:get(meaning,F),{'R'}},{'Results'}}),
        ?assertEqual([{close,2,NextId}],Results)
    after
        Socket ! stop, catch quod_reg:unsubscribe({runtime,Ns})
    end.

hinged_view_action(#{namespace := Ns,identity := Identity},Goal) ->
    Anchor = quod_simplex:genesis_hash(Ns),
    {Scoped,_,_} = erlog_int:term_instance({'::',Ns,Goal},0),
    {ok,Text} = quod_client_goal_parser:format(Scoped),
    Request = #{network_identity => <<42:256>>,agent_namespace => Ns,
        agent_genesis_anchor => Anchor,agent_instance_text => <<"viewer.">>,
        signing_public_key => maps:get(pubkey,Identity),operation_id => crypto:strong_rand_bytes(32),
        not_after_ms => quod_time:now_ms()+10000,mode => execute,parser_version => 3,goal_text => Text},
    {ok,Bytes} = quod_client_goal:encode(Request),
    quod_client_goal_ingress:submit(Bytes,quod_identity:sign(Bytes,Identity)).

hinged_view_pose(Projection) ->
    [Pose] = maps:get(<<"poses">>,maps:get(<<"frame">>,Projection)),
    ?assertEqual(<<"10">>,maps:get(<<"body">>,Pose)), Pose.

assert_hinged_view_label(Projection,Text) ->
    {ok,#{goal := Parsed}} = quod_client_goal_parser:parse(<<(maps:get(<<"marks">>,Projection))/binary,".">>,3),
    {ok,[{mark,<<"hinged-example">>,<<"group">>,[],{body_pose,10,2},no_surface,
          {label,Text,<<"above">>},{depicts,_,_,_}}|Parts]} = quod_wire_term:materialize_symbols(Parsed),
    ?assert(lists:all(fun({mark,_,_,_,{relative,<<"hinged-example">>,_},_,_,depicts_nothing}) -> true;
                        (_) -> false end,Parts)).

assert_hinged_view_restored_pose(Before,After) ->
    %% The durable angle rounds to mrad; recovery may differ by its half-mrad.
    [begin ?assert(abs(A-B) =< 0.002) end ||
        {A,B} <- lists:zip(maps:get(<<"position">>,Before),maps:get(<<"position">>,After))],
    Q = maps:get(<<"rotation">>,Before), R = maps:get(<<"rotation">>,After),
    Dot = lists:sum([A*B || {A,B} <- lists:zip(Q,R)]),
    ?assert(abs(Dot) >= 0.999999).

authored_hinged_examples_in_independent_worlds_test_() ->
    {timeout,120,fun() -> with_hinged_examples(fun(First,Second) ->
        {P1,W1} = enable(First), {P2,W2} = enable(Second),
        ?assertNotEqual(W1,W2), ?assertNotEqual(P1,P2),
        [begin
            Ns = maps:get(namespace,F), true = quod_reg:subscribe({runtime,Ns}),
            R = {close,1,<<161:256>>},
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                door_action(Ns,{physics_close_hinged,room,10,0,<<161:256>>})),
            Ops = await_hinged_ops(Ns,R,closed),
            ?assert(lists:member({event,{physics_hinged_finished,room,10,R,closed}},Ops)),
            Meaning = maps:get(meaning,F),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{hinged_result,Meaning,R})),
            {ok,[#{'A' := Angle}],_} = quod_prolog:prove_ro(Ns,
                {physics_checkpoint,room,{hinge,10,2,{body,10,2},{body,11,2},1,{'_'},{'A'}}}),
            ?assert(abs(Angle-maps:get(target,F)) =< 20), reconcile(Ns)
        end || F <- [First,Second]],
        #{namespace := A,target := Target} = First, #{namespace := B} = Second,
        BeforeB = gen_server:call(P2,status), HeightB = quod_prolog:applied(B),
        %% A real command change affects only its owner; no geometry rebuild.
        Calls = physics_trace_calls([{quod_physics_native,control_hinge,4},
            {quod_physics_native,install,2},{quod_physics_native,install_hinges,2}],fun() ->
            commit(A,{',',{retract,{physics_hinged_control,room,10,hinged_command(Target)}},
                          {assertz,{physics_hinged_control,room,10,hinged_command(-200)}}}),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                door_action(A,{physics_close_hinged,room,10,1,<<162:256>>})),
            _ = await_hinged_ops(A,{close,2,<<162:256>>},closed), reconcile(A)
        end),
        ?assertMatch([#{pid := P1,call := {quod_physics_native,control_hinge,4}}],Calls),
        ?assertEqual(HeightB,quod_prolog:applied(B)),
        ?assertEqual(maps:with([installs,incarnation],BeforeB),
                     maps:with([installs,incarnation],gen_server:call(P2,status))),
        assert_no_physics_io(fun() -> assert_no_live_geometry_work(fun() ->
            [begin reconcile(A),reconcile(B) end || _ <- lists:seq(1,5)]
        end) end),
        %% Recovery restores each current result without replaying its effect.
        [begin
            Ns = maps:get(namespace,F), M = monitor(process,Pid), exit(Pid,kill),
            receive {'DOWN',M,process,Pid,killed} -> ok after 5000 -> error(owner_alive) end,
            {Next,World} = installed(Ns), ?assertNotEqual(Pid,Next),
            {ok,[#{'Rows' := Rows}],_} = quod_prolog:prove_ro(Ns,
                {findall,{'R'},{hinged_result,maps:get(meaning,F),{'R'}},{'Rows'}}),
            ?assertEqual(Count,length(Rows))
        end || {F,Pid,World,Count} <- [{First,P1,W1,2},{Second,P2,W2,1}]]
    end) end}.

with_hinged_examples(Fun) ->
    A = <<"hinged-gallery">>, B = <<"hinged-workshop">>,
    Door = "test/fixtures/hinged-door.pl", Lid = "test/fixtures/hinged-lid.pl",
    with_world(A,fun(F = #{node := Node,directory := Dir,identity := Identity}) ->
        Rules = hinged_example_rules(B,world_rules(B),Lid) ++
            [{rendering_vocabulary,<<"physics-test-rendering">>,
              quod_simplex:genesis_hash(<<"physics-test-rendering">>)}],
        Sup = quod_agent_hosting_tests:start_ontology(B,Dir,Identity,
            quod_prolog:genesis_diff("priv/ontologies/agent_instance.pl"),
            [{can_assign_agent_host,{node,maps:get(pubkey,Identity)},actor,{'_'},{'_'},Node,{'_'}},
             {can_invoke,{'_'},Node,{'_'},B},{can_request_agent_signature,Node,actor,{'_'}}|Rules]),
        Ref = {agent_instance_ref,B,quod_simplex:genesis_hash(B),actor},
        {ok,Blob} = quod_wire_term:encode_canonical(Ref), {ok,Key} = quod_agent_vault:prepare(Blob,0),
        try Fun((add_hinged_example(F))#{other_namespace => B},
                (add_hinged_example(F#{namespace => B,reference => Ref,key => Key}))#{other_namespace => A})
        after
            [catch quod_reg:unsubscribe(Topic) || Topic <- [{physics,B},{runtime,A},{runtime,B}]],
            quod_agent_hosting_tests:stop_ontology(Sup)
        end
    end,fun(Rules) -> hinged_example_rules(A,Rules,Door) end).

hinged_example_rules(Ns,Rules,File) ->
    Actor = {agent_instance_ref,Ns,{'_'},actor},
    [R || R <- Rules, not (element(1,R) =:= physics_body_definition andalso element(3,R) =:= 2)] ++
        quod_prolog:read_terms(File) ++
        [{can_invoke,{physics_store_hinged_request,{'_'},{'_'},{'_'},{'_'}},Actor,{'_'},Ns},
         {can_invoke,{physics_finish_hinged,{'_'},{'_'}},Actor,{'_'},Ns},
         {can_edit_physics,room,{'_'}},{can_close_physics_hinged,room,10,{'_'}},
         {can_cancel_physics_hinged,room,10,{'_'}}].
add_hinged_example(F = #{namespace := Ns}) ->
    {ok,[#{'Name' := Name,'Pose' := Pose,'Target' := Target,'Obstacle' := Obstacle,'Meaning' := Meaning}],_} =
        quod_prolog:prove_ro(Ns,{hinged_example,{'Name'},{'Pose'},{'Target'},{'Obstacle'},{'Meaning'}}),
    ?assertMatch({normalized,{committed,_,_}},brief(door_action(Ns,
        {physics_add_hinged,room,10,11,{local,Name,1},Pose,1}))),
    F#{target => Target,meaning => Meaning,obstacle => Obstacle}.

await_hinged_ops(Ns,R,Result) ->
    receive
        {applied_live,#{ns := Ns,applied_ops := Ops}} ->
            case lists:member({event,{physics_hinged_finished,room,10,R,Result}},Ops) of
                true -> Ops; false -> await_hinged_ops(Ns,R,Result)
            end
    after 15000 -> error({hinged_consequence_missing,Ns,R,Result,quod_runtime:stats(Ns)}) end.

physics_trace_calls(Watched,Fun) ->
    Collector = spawn_link(fun() -> trace_calls([]) end),
    Trace = trace:session_create(hinged_controls,Collector,[]),
    [trace:function(Trace,MFA,[{'_',[],[{message,{caller}}]}],[local]) || MFA <- Watched],
    trace:process(Trace,all,true,[call]),
    try
        Fun(), Delivered = trace:delivered(Trace,all),
        receive {trace_delivered,all,Delivered} -> ok after 5000 -> error(trace_timeout) end,
        Ref = make_ref(), Collector ! {finish,self(),Ref},
        receive {trace_calls,Ref,Rows} -> Rows after 5000 -> error(trace_timeout) end
    after trace:session_destroy(Trace),unlink(Collector),exit(Collector,kill) end.

hinged_receiver_completion_is_atomic_test_() ->
    [{atom_to_list(Mode),{timeout,90,fun() -> hinged_receiver_completion(Mode) end}} ||
        Mode <- [commit,denied,rollback,conflict]].

hinged_receiver_completion(Mode) ->
    {ok,_} = application:ensure_all_started(gproc),
    true = quod_reg:reg({host_test,barrier}),
    try with_door(fun(F = #{namespace := Ns,node := {agent_instance_ref,Receiver,Anchor,_},reference := Actor}) ->
        {ok,Foreign} = quod_foreign_log:start_link(#{cache_dir => filename:join(maps:get(directory,F),"foreign")}),
        try
        R = {close,1,<<163:256>>},
        ReceiverAction = {'::',Receiver,{',',{current_ontology_identity,Receiver,Anchor},{receive_hinged,{'R'}}}},
        Consequence = {physics_hinged_consequence,room,10,{'R'},closed,ReceiverAction},
        ReceiverRules = [receiver_allowed,
            {':-',{receive_hinged,{'R'}},{',',receiver_allowed,{assertz,{received_hinged,{'R'}}}}}],
        Grants = case Mode of denied -> []; _ -> [{can_invoke,{'_'},Actor,{'_'},Receiver}] end,
        commit(Receiver,list_conjunction([{assertz,T} || T <- ReceiverRules++Grants])),
        Additional = case Mode of rollback -> [{physics_hinged_consequence,room,10,{'_'},closed,fail}]; _ -> [] end,
        commit(Ns,list_conjunction([{assertz,T} || T <- [Consequence|Additional]])),
        {Pid,World} = enable(F), true = quod_reg:subscribe({runtime,Ns}),
        ?assertMatch({ok,_,{normalized,{committed,_,_}}},
            door_action(Ns,{physics_close_hinged,room,10,0,<<163:256>>})),
        case Mode of
            M when M =:= commit; M =:= conflict ->
                Proof = receive {fipa_completion_prepared,P,_} -> P
                        after 10000 -> error(atomic_hinge_proof_missing) end,
                try
                    assert_hinged_unfinished(Ns,Receiver,R),
                    case Mode of conflict -> commit(Receiver,{retract,receiver_allowed}); _ -> ok end
                after Proof ! release end;
            _ -> ok
        end,
        case Mode of
            commit ->
                _ = await_hinged_ops(Ns,R,closed),
                {ok,[#{'C' := {request,_,closed,Bytes,Sig}}],_} =
                    quod_prolog:prove_ro(Ns,{physics_hinged_request,room,10,{'C'}}),
                ?assertMatch({ok,_,{operation_outcome,_,#{status := committed}}},
                    await_hinged_outcome(Ns,Bytes,Sig,quod_time:mono_ms()+10000)),
                ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Receiver,{received_hinged,R}));
            _ ->
                receive {physics_status,_,Pid,World,_,{unavailable,{observation,{hinge,10},unresolved}}} -> ok
                after 15000 -> error(atomic_refusal_not_delivered) end,
                assert_hinged_unfinished(Ns,Receiver,R)
        end
        after gen_server:stop(Foreign) end
    end,false,fun(Rules) ->
        [case Rule of
            {':-',Head = {physics_finish_hinged,_,_},Body} when Mode =:= commit; Mode =:= conflict ->
                {':-',Head,{',',Body,test_fipa_completion}};
            _ -> Rule
        end || Rule <- Rules]
    end)
    after gproc:unreg(quod_reg:name({host_test,barrier})) end.

await_hinged_outcome(Ns,Bytes,Sig,Deadline) ->
    Owner = quod_reg:where({quod_prolog,Ns}),
    case quod_client_goal_ingress:resolve_operation(Bytes,Sig) of
        {ok,_,{operation_outcome,_,#{status := committed}}} = Result -> Result;
        Pending ->
            Remaining = max(0,Deadline-quod_time:mono_ms()),
            receive {projection_advanced,Owner,_} -> await_hinged_outcome(Ns,Bytes,Sig,Deadline)
            after Remaining -> error({hinged_outcome_not_published,brief(Pending)}) end
    end.

assert_hinged_unfinished(Ns,Receiver,R) ->
    ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_hinged,room,10,1,{closing,R}})),
    ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{physics_checkpoint,room,{'_'}})),
    ?assertMatch({fail,_},quod_prolog:prove_ro(Receiver,{received_hinged,R})).

shared_fixed_support_moves_atomically_test_() ->
    {timeout,90,fun() -> with_door(fun(F = #{namespace := Ns}) ->
        Joint = {hinge,{body,20,2},2,{body,11,2},{vector,1,0,0},
            {anchors,{vector,0,2000,0},{vector,0,0,0}},{limits,-1000,1000},200},
        Body = {physics_body_definition,room,20,2,dynamic,{vector,0,1500,0},{owned,{ball,100},1}},
        commit(Ns,list_conjunction([{assertz,Body},{assertz,{physics_joint,room,Joint}}])),
        Move = {physics_move_hinged,room,10,0,2,{pose,{vector,3000,1500,0},{rotation,0,200,0}}},
        ?assertMatch({ok,_,{normalized,{failed,_}}},door_action(Ns,Move)),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_structure,room,2})),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,Body)),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
            {physics_body_definition,room,11,2,fixed,{vector,0,1500,0},{'_'}})),
        commit(Ns,list_conjunction([{assertz,T} || T <-
            [{physics_hinged,room,20,0,idle},{physics_hinged_control,room,20,hinged_command(-300)},
             {can_close_physics_hinged,room,20,{'_'}}]])),
        {Pid,_} = enable(F), ok = sys:suspend(Pid),
        try
            [begin ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,
                {physics_close_hinged,room,D,0,<<164:256>>})) end || D <- [10,20]],
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,setelement(4,Move,1))),
            [begin
                ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
                    {physics_hinged,room,D,1,{cancelled,{close,1,<<164:256>>}}})),
                ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
                    {physics_joint,room,{hinge,{body,D,3},3,{body,11,3},{'_'},{'_'},{'_'},{'_'}}}))
            end || D <- [10,20]]
        after sys:resume(Pid) end,
        {Pid,_} = installed_structure(Ns,3),
        true = quod_reg:reg({host_test,local_proof}),
        try assert_live_conflict(live_compete(Ns,[setelement(5,setelement(4,Move,1),3),
                                               setelement(5,setelement(4,Move,1),3)]))
        after gproc:unreg(quod_reg:name({host_test,local_proof})) end,
        {Pid,_} = installed_structure(Ns,4)
    end,false) end}.

hinged_command_edit_fences_signed_sample_test_() ->
    [{atom_to_list(Stage),{timeout,60,fun() -> with_door(fun(F = #{namespace := Ns}) ->
        {Pid,World} = enable(F), #{World := #{spec := Spec}} = worlds(Ns),
        ok = sys:suspend(Pid),
        try
            R = {close,1,<<165:256>>},
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                door_action(Ns,{physics_close_hinged,room,10,0,<<165:256>>})),
            At = quod_time:now_ms(), Expiry = At+10000,
            Sample = test_hinge_sample(Spec,2,R,1,500,{contact,3,1},At,Expiry),
            {Bytes,Sig} = sign_fixture(F,{physics_finish_hinged,Sample,{blocked,3}},Expiry),
            {Store,StoreSig} = sign_fixture(F,{physics_store_hinged_request,Sample,{blocked,3},Bytes,Sig},Expiry),
            case Stage of after_store ->
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},quod_client_goal_ingress:submit(Store,StoreSig));
                before_store -> ok
            end,
            commit(Ns,{',',{retract,{physics_hinged_control,room,10,hinged_command(0)}},
                          {assertz,{physics_hinged_control,room,10,hinged_command(100)}}}),
            {Submission,Signature} = case Stage of before_store -> {Store,StoreSig}; after_store -> {Bytes,Sig} end,
            ?assertMatch({ok,_,{normalized,{failed,_}}},quod_client_goal_ingress:submit(Submission,Signature)),
            ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{physics_checkpoint,room,{'_'}})),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_hinged,room,10,1,{closing,R}})),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},door_action(Ns,{physics_cancel_hinged,room,10,R}))
        after sys:resume(Pid) end
    end,true) end}} || Stage <- [before_store,after_store]].

authored_hinged_obstruction_and_permissions_test_() ->
    {timeout,120,fun() -> with_hinged_examples(fun(First,Second) ->
        [begin
            #{namespace := Ns,obstacle := Position} = F,
            commit(Ns,{',',{physics_advance_structure,room,3},
                {assertz,{physics_body_definition,room,3,3,fixed,Position,{owned,{box,200,1000,200},1}}}}),
            {Pid,_} = enable(F),true = quod_reg:subscribe({runtime,Ns}),
            Close = {can_close_physics_hinged,room,10,{'_'}},
            Cancel = {can_cancel_physics_hinged,room,10,{'_'}},
            commit(Ns,{retract,Close}),
            ?assertMatch({ok,_,{normalized,{failed,_}}},
                door_action(Ns,{physics_close_hinged,room,10,0,<<166:256>>})),
            commit(Ns,{assertz,Close}),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                door_action(Ns,{physics_close_hinged,room,10,0,<<166:256>>})),
            _ = await_hinged_ops(Ns,{close,1,<<166:256>>},{blocked,3}),
            ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{hinged_result,{'_'},{'_'}})),
            ok = sys:suspend(Pid),
            try
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                    door_action(Ns,{physics_close_hinged,room,10,1,<<167:256>>})),
                R = {close,2,<<167:256>>},commit(Ns,{retract,Cancel}),
                ?assertMatch({ok,_,{normalized,{failed,_}}},
                    door_action(Ns,{physics_cancel_hinged,room,10,R})),
                commit(Ns,{assertz,Cancel}),
                ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                    door_action(Ns,{physics_cancel_hinged,room,10,R})),
                ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{physics_hinged,room,10,2,{cancelled,R}}))
            after sys:resume(Pid) end
        end || F <- [First,Second]]
    end) end}.

finished_hinged_group_move_can_close_again_test_() ->
    {timeout,120,fun() -> with_hinged_examples(fun(First,Second) ->
        [begin
            #{namespace := Ns} = F, {Pid,World} = enable(F),
            true = quod_reg:subscribe({runtime,Ns}),
            R1 = {close,1,<<168:256>>},
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                door_action(Ns,{physics_close_hinged,room,10,0,<<168:256>>})),
            _ = await_hinged_ops(Ns,R1,closed),
            {ok,[#{'C' := {request,_,closed,OldBytes,OldSignature}}],_} =
                quod_prolog:prove_ro(Ns,{physics_hinged_request,room,10,{'C'}}),
            {ok,[#{'Pose' := Pose}],_} = quod_prolog:prove_ro(Ns,
                {hinged_example,{'_'},{'Pose'},{'_'},{'_'},{'_'}}),
            ?assertMatch({ok,_,{normalized,{committed,_,_}}},
                door_action(Ns,{physics_move_hinged,room,10,1,2,Pose})),
            {Pid,World} = installed_structure(Ns,3),
            ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,{physics_checkpoint,room,{'_'}})),
            %% A group edit invalidates the physical checkpoint, not the
            %% recorded completion of the original custodied operation.
            ?assertMatch({normalized,{committed,_,_}},
                brief(door_action(Ns,{physics_close_hinged,room,10,1,<<169:256>>}))),
            _ = await_hinged_ops(Ns,{close,2,<<169:256>>},closed),
            {ok,[#{'C' := {request,_,closed,NewBytes,_}}],_} =
                quod_prolog:prove_ro(Ns,{physics_hinged_request,room,10,{'C'}}),
            ?assertNotEqual(OldBytes,NewBytes),
            ?assertMatch({ok,_,{operation_outcome,_,#{status := committed}}},
                quod_client_goal_ingress:resolve_operation(OldBytes,OldSignature)),
            ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
                {physics_checkpoint,room,{hinge,10,3,{body,10,3},{body,11,3},1,{'_'},{'_'}}}))
        end || F <- [First,Second]]
    end) end}.

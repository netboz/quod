-module(quod_physics_control_tests).
-include_lib("eunit/include/eunit.hrl").

signed_binding_switch_and_release_test_() ->
    {timeout, 60, fun() -> with_control(fun(F = #{namespace := Ns, human := Human}) ->
        ?assertMatch({normalized,{committed,_,_}}, action(F, bind(0,none,compact,eye))),
        ?assertMatch({ok,[_],_}, quod_prolog:prove_ro(Ns,
            {physics_control,room,Human,1,{controlled,compact,eye}})),
        ?assertMatch({normalized,{read,_,{answers,_,[_]}}}, read(F)),
        ?assertMatch({normalized,{failed,_}}, action(F, bind(0,none,wide,cockpit))),
        ?assertMatch({normalized,{committed,_,_}},
            action(F, bind(1,{controlled,compact,eye},wide,cockpit))),
        {ok,[Configuration],_} = quod_prolog:prove_ro(Ns,
            {physics_control_configuration,room,Human,2,{'C'}}),
        ?assertMatch({controlled_agent,wide,1,3,1,
            {motion,grounded},{viewpoint,cockpit,{pose,{vector,250,300,-200},{rotation,0,1500,0}},view_only}},
            maps:get('C',Configuration)),
        ?assertMatch({normalized,{committed,_,_}}, action(F,
            {physics_control_agent,room,2,{controlled,wide,cockpit},none})),
        ?assertMatch({normalized,{read,_,{failed,_}}}, read(F)),
        %% Release retains its epoch: the original bind never becomes valid again.
        ?assertMatch({normalized,{failed,_}}, action(F,bind(0,none,compact,eye))),
        ?assertMatch({ok,[_],_}, quod_prolog:prove_ro(Ns,{physics_control,room,Human,3,none})),
        ?assertMatch({normalized,{committed,_,_}},action(F,bind(3,none,compact,eye)))
    end) end}.

binding_permission_and_geometry_guards_test_() ->
    {timeout, 60, fun() -> with_control(fun(F = #{namespace := Ns, human := Human}) ->
        ?assertMatch({normalized,{failed,_}}, action(F,bind(0,none,unknown,eye))),
        ?assertMatch({normalized,{failed,_}}, action(F,bind(0,none,compact,cockpit))),
        commit(Ns,{retract,{can_control_physics_agent,room,Human,compact}}),
        ?assertMatch({normalized,{failed,_}}, action(F,bind(0,none,compact,eye))),
        commit(Ns,{assertz,{can_control_physics_agent,room,Human,compact}}),
        ?assertMatch({normalized,{committed,_,_}}, action(F,bind(0,none,compact,eye))),
        commit(Ns,{retract,{can_control_physics_agent,room,Human,compact}}),
        ?assertMatch({normalized,{read,_,{failed,_}}},read(F)),
        %% Revocation does not prevent releasing one's own existing selection.
        ?assertMatch({normalized,{committed,_,_}},action(F,
            {physics_control_agent,room,1,{controlled,compact,eye},none})),
        commit(Ns,{assertz,{physics_agent,room,wide,2,3,{motion,grounded}}}),
        ?assertMatch({normalized,{failed,_}},action(F,bind(2,none,wide,cockpit)))
    end) end}.

exclusive_control_and_no_body_mutation_test_() ->
    {timeout, 60, fun() -> with_control(fun(F = #{namespace := Ns, human := Human}) ->
        Before = bodies(Ns),
        Other = {agent_instance_ref,<<"other">>,<<99:256>>,someone},
        commit(Ns,{',',{assertz,{physics_control,room,Other,1,{controlled,compact,eye}}},
            {assertz,{can_control_physics_agent,room,Other,compact}}}),
        ?assertMatch({normalized,{failed,_}},action(F,bind(0,none,compact,eye))),
        %% A revoked holder still owns the binding. Regranting it must never
        %% resurrect a second controller after someone else acquired the agent.
        commit(Ns,{retract,{can_control_physics_agent,room,Other,compact}}),
        ?assertMatch({normalized,{failed,_}},action(F,bind(0,none,compact,eye))),
        ?assertMatch({normalized,{committed,_,_}},action(F,bind(0,none,wide,cockpit))),
        ?assertEqual(Before,bodies(Ns)),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
            {physics_control,room,Human,1,{controlled,wide,cockpit}})),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,
            {physics_control,room,Other,1,{controlled,compact,eye}}))
    end) end}.

ambiguous_body_ownership_test_() ->
    {timeout, 60, fun() -> with_control(fun(F = #{namespace := Ns}) ->
        commit(Ns,{assertz,{physics_agent,room,alias,1,2,{motion,grounded}}}),
        ?assertMatch({normalized,{failed,_}},action(F,bind(0,none,compact,eye)))
    end) end}.

subclass_agent_binding_test_() ->
    {timeout,60,fun() -> with_control(fun(F) ->
        ?assertMatch({normalized,{committed,_,_}},action(F,bind(0,none,compact,eye)))
    end, [{isa,pilot_class,{':',quod,{':',agent,agent}}},{instance_of,pilot_class,compact}]) end}.

bind(Epoch, Previous, Agent, Viewpoint) ->
    {physics_control_agent,room,Epoch,Previous,{controlled,Agent,Viewpoint}}.

read(F) -> signed(F,read,{physics_client_control,room,{0}}).
action(F,Goal) -> signed(F,execute,Goal).

signed(#{namespace := Ns, human := {agent_instance_ref,HumanNs,HumanAnchor,human},
         identity := Identity},Mode,Goal) ->
    {ok,Text} = quod_client_goal_parser:format_clause({'::',Ns,Goal}),
    Request = #{network_identity => <<42:256>>,agent_namespace => HumanNs,
        agent_genesis_anchor => HumanAnchor,agent_instance_text => <<"human.">>,
        signing_public_key => maps:get(pubkey,Identity),operation_id => crypto:strong_rand_bytes(32),
        not_after_ms => quod_time:now_ms()+10000,mode => Mode,parser_version => 3,goal_text => Text},
    {ok,Bytes} = quod_client_goal:encode(Request),
    {ok,_,Outcome} = quod_client_goal_ingress:submit(Bytes,quod_identity:sign(Bytes,Identity)),
    Outcome.

commit(Ns,Goal) -> ?assertMatch({ok,_,_},quod_ct:rp(Ns,Goal)).
bodies(Ns) ->
    Row = {body,{'Id'},{'Revision'},{'Kind'},{'Position'},{'Shape'},{'Density'}},
    {ok,[#{'Bodies' := Bodies}],_} = quod_prolog:prove_ro(Ns,
        {findall,Row,{physics_body_definition, room, {'Id'}, {'Revision'}, {'Kind'}, {'Position'}, {owned, {'Shape'}, {'Density'}}},{'Bodies'}}),
    Bodies.

with_control(Fun) ->
    with_control(Fun, [{instance_of,{':',quod,{':',agent,agent}},compact}]).

with_control(Fun, CompactFacts) ->
    Ns = <<"host-test-agent">>,
    Rules = quod_prolog:read_terms("priv/ontologies/quod_physics.pl") ++
        [{can_invoke,{physics_control_agent,{'_'},{'_'},{'_'},{'_'}},{'_'},{'_'},Ns},
         {can_invoke,{physics_client_control,{'_'},{'_'}},{'_'},{'_'},Ns},
         {can_view_physics,room,{'_'}},
         {physics_space,room,disabled,actor},
         {instance_of,{':',quod,{':',agent,agent}},wide},
         {physics_body_definition, room, 2, 1, fixed, {vector,0,1000,0}, {owned, {box,200,200,200}, 1}},
         {physics_body_definition, room, 3, 1, fixed, {vector,2000,1000,0}, {owned, {box,1000,300,500}, 1}},
         {physics_agent,room,compact,1,2,{motion,grounded}},
         {physics_agent,room,wide,1,3,{motion,grounded}},
         {physics_viewpoint,room,compact,eye,2,{pose,{vector,0,100,0},{rotation,0,0,0}},view_only},
         {physics_viewpoint,room,wide,cockpit,3,{pose,{vector,250,300,-200},{rotation,0,1500,0}},view_only}]
        ++ CompactFacts,
    quod_agent_hosting_tests:with_host(fun(F = #{reference := {agent_instance_ref,_,Anchor,_}}) ->
        Human = {agent_instance_ref,Ns,Anchor,human},
        commit(Ns,{',',{assertz,{can_control_physics_agent,room,Human,compact}},
                      {assertz,{can_control_physics_agent,room,Human,wide}}}),
        Fun(F#{human => Human})
    end,fun(Pub) -> Rules ++
        [{instance_of,human_user,human},
         {agent_key,human,Pub,active},
         {can_invoke,{'_'},{agent_instance_ref,Ns,{'_'},human},{'_'},Ns}]
    end).

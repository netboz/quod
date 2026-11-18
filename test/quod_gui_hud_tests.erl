-module(quod_gui_hud_tests).
-include_lib("eunit/include/eunit.hrl").
-import(quod_gui_menu_tests,[property/2,children/1,wedge/2,edit/2,conj/1]).

%% The human's HUD is one ordinary instance read through the signed view.

hud_composes_standing_context_and_contributions_test_() ->
    {timeout,120,fun() -> with_hud(fun(C=#{namespace:=Ns,destination:=Dest}) ->
        A = quod_simplex:genesis_hash(Ns), Room = {entity_ref,Ns,A,room},
        edit(Ns,conj([{assertz,{account_setup,me,{complete,hud_fixture}}},
            {assertz,{attribute,personal,transform,{transform,0,0,0,0,0,0}}},
            {assertz,{':-',{instance_of,note,n1},true}},{assertz,{attribute,n1,name,<<"Shopping">>}}])),
        ?assertMatch([_],signed_read(C,{entity_eidolons,me,attention,questions,{'V'}})),
        ?assertMatch([_],signed_read(C,{entity_eidolons,me,menu,default,{'V'}})),
        ?assertEqual([{1,<<"Your attention">>},{2,<<"Me">>}],strip(C)),
        [Attention,Me] = children(hud(C)),
        ?assertMatch({choice,{entity_ref,Ns,A,me},{eidolon,attention,questions,_}},property(Attention,target)),
        ?assertMatch({choice,{entity_ref,Ns,A,me},{eidolon,menu,default,_}},property(Me,target)),
        %% A space offers contextual commands only while the agent is placed in it.
        Worlds = {item,{choice,Room,{eidolon,playing,solid,{recipe,Ns,A,space}}},<<"Worlds">>,<<>>,available,[]},
        edit(<<"quod:space">>,{assertz,{class_eidolon,space,hud,tools,{recipe,Ns,A,test_hud}}}),
        edit(Ns,conj([
            {assertz,{eidolon,test_hud,{subject,{'_'},room},{hud,[Worlds]}}},
            {assertz,{space_assignment_state,personal,1,Room}},
            {assertz,{space_placement,room,{entity_ref,Ns,A,personal},1}}])),
        ?assertEqual([<<"Your attention">>,<<"Me">>,<<"Worlds">>],[L || {_,L} <- strip(C)]),
        edit(Ns,conj([{retract,{space_assignment_state,personal,1,Room}},
            {retract,{space_placement,room,{entity_ref,Ns,A,personal},1}}])),
        ?assertEqual([<<"Your attention">>,<<"Me">>],[L || {_,L} <- strip(C)]),
        %% The human contributes directly; another principal must ask instead.
        Rename = {eidolon,{operation,instance},rename,{recipe,Ns,A,note_rename}},
        Note = {entity_ref,Ns,A,n1},
        executed(C,{hud_contribute,Note,Rename}),
        ?assertEqual([<<"Your attention">>,<<"Me">>,<<"Rename note">>],[L || {_,L} <- strip(C)]),
        Enter = {eidolon,{operation,instance},enter,{recipe,<<"quod:space">>,quod_simplex:genesis_hash(<<"quod:space">>),space_enter}},
        Elsewhere = {entity_ref,Dest,quod_simplex:genesis_hash(Dest),room},
        {Bytes,Sig} = node_signed(Ns,{hud_contribute,Elsewhere,Enter}),
        ?assertMatch({ok,_,{normalized,{failed,_}}},quod_client_goal_ingress:submit(Bytes,Sig)),
        %% Instead an agent leaves an offer; only the human's own answer places it.
        %% A stranger (a real signed principal nothing here admits) cannot even
        %% leave one until the human's receiver policy names it.
        Closet = {entity_ref,Ns,A,closed}, EnterHere = {eidolon,{operation,instance},enter,{recipe,<<"quod:space">>,quod_simplex:genesis_hash(<<"quod:space">>),space_enter}},
        StrangerPair = {StrangerKey,_} = quod_identity:generate(),
        Stranger = {agent_instance_ref,Ns,A,stranger},
        edit(Ns,conj([{assertz,{':-',{instance_of,agent,stranger},true}},{assertz,{agent_key,stranger,StrangerKey,active}}])),
        S = C#{human=>Stranger,human_pair=>StrangerPair},
        Before = strip(C),
        refused(S,{hud_offer,Closet,EnterHere}),
        fails(Ns,{hud_offered,my_hud,{'_'},{'_'},{'_'}}),
        edit(Ns,{assertz,{gui_receiver_policy,me,Stranger}}),
        executed(S,{hud_offer,Closet,EnterHere}),
        {ok,[#{'P':=Stranger}],_} = quod_prolog:prove_ro(Ns,{hud_offered,my_hud,{'P'},Closet,EnterHere}),
        ?assertEqual(Before,strip(C)),
        Views = signed_read(C,{gui_operations,{entity_ref,Ns,A,me},{'V'}}),
        Offers = [V || V = {operation_view,answer_hud_offer,_,_,_,_,_,_,_,_} <- Views],
        ?assertMatch([_],Offers),
        [{operation_view,answer_hud_offer,_,_,Form,_,_,_,_,_}] = Offers,
        ?assertMatch([{option,{offer,Stranger,Closet,EnterHere},<<"Enter space">>}],
                     options(Form,{hud_offer_choice,{entity_ref,Ns,A,me}})),
        executed(C,{hud_answer_offer,{entity_ref,Ns,A,me},{offer,Stranger,Closet,EnterHere},accept}),
        ?assertEqual(Before++[{length(Before)+1,<<"Enter space">>}],strip(C)),
        fails(Ns,{hud_offered,my_hud,{'_'},{'_'},{'_'}}),
        executed(C,{hud_withdraw,Closet,EnterHere}),
        %% A declined offer leaves nothing; only its contributor may withdraw it.
        executed(S,{hud_offer,Closet,EnterHere}),
        executed(C,{hud_answer_offer,{entity_ref,Ns,A,me},{offer,Stranger,Closet,EnterHere},decline}),
        ?assertEqual(Before,strip(C)), fails(Ns,{hud_offered,my_hud,{'_'},{'_'},{'_'}}),
        executed(S,{hud_offer,Closet,EnterHere}),
        {Bytes2,Sig2} = node_signed(Ns,{hud_withdraw_offer,Closet,EnterHere}),
        ?assertMatch({ok,_,{normalized,fail}},quod_client_goal_ingress:submit(Bytes2,Sig2)),
        executed(S,{hud_withdraw_offer,Closet,EnterHere}),
        fails(Ns,{hud_offered,my_hud,{'_'},{'_'},{'_'}}),
        %% A contribution whose source cannot be read stays, dimmed, with a reason.
        executed(C,{hud_contribute,Elsewhere,Enter}),
        %% A broad retract would first match the foundation's generic clause.
        %% Install the exact remaining ACL so this fixture really withdraws U.
        edit(Dest,{transaction,{',',{abolish,{'/',can_invoke,4}},
            {assertz,{can_invoke,{'Goal'},maps:get(node,C),{'Chain'},{'Target'}}}}}),
        {ok,ProbeBytes,ProbeSig} = quod_node_actor:signed_goal(read,
            {'::',Dest,{findall,{0},{can_invoke,true,{0},[],Dest},{1}}},crypto:strong_rand_bytes(32),quod_time:now_ms()+20000),
        {ok,_,{normalized,{read,_,{answers,_,[Probe]}}}} = quod_client_goal_ingress:submit(ProbeBytes,ProbeSig),
        {ok,ProbeBindings} = quod_client_result:decode_binding(Probe),
        ?assertEqual([maps:get(node,C)],proplists:get_value(<<"V1">>,ProbeBindings)),
        {DeniedBytes,DeniedSignature} = quod_personal_agent_tests:request(C,read,{'::',Dest,{gui_menu_source,room,{'V'}}}),
        ?assertMatch({ok,_,{normalized,{read,_,{failed,_}}}},quod_client_goal_ingress:submit(DeniedBytes,DeniedSignature)),
        Unreadable = wedge(hud(C),4),
        ?assertEqual({<<"Unavailable">>,false,<<"Unavailable: its source can't be reached.">>},
                     {property(Unreadable,label),property(Unreadable,enabled),property(Unreadable,help)}),
        executed(C,{hud_withdraw,Elsewhere,Enter}),
        ?assertEqual([<<"Your attention">>,<<"Me">>,<<"Rename note">>],[L || {_,L} <- strip(C)]),
        %% The authored allowance nests later commands under More.
        edit(Ns,conj([{retract,{hud_allowance,my_hud,12}},{assertz,{hud_allowance,my_hud,2}}])),
        ?assertEqual([{1,<<"Your attention">>},{2,<<"More">>}],strip(C)),
        ?assertEqual([<<"Me">>,<<"Rename note">>],[property(W,label) || W <- children(wedge(hud(C),2))]),
        quod_outcome_result_tests:assert_unchanged_reads(
            [Ns,<<"quod:user">>,<<"quod:agent">>,<<"quod:gui">>,<<"quod:space">>,Dest],
            fun() -> ?assertEqual([{1,<<"Your attention">>},{2,<<"More">>}],strip(C)) end,0)
    end) end}.

hud_space_owner_authority_and_storing_acl_test_() ->
    {timeout,120,fun() -> with_hud(fun(C=#{namespace:=Ns,destination:=Dest,human:=Human}) ->
        A = quod_simplex:genesis_hash(Ns), DA = quod_simplex:genesis_hash(Dest),
        {Key,_} = Pair = quod_identity:generate(), Owner = {agent_instance_ref,Dest,DA,owner},
        Foreign = C#{human=>Owner,human_pair=>Pair}, Room = {entity_ref,Dest,DA,room},
        Subject = {entity_ref,Ns,A,n1}, Choice = {eidolon,{operation,instance},rename,{recipe,Ns,A,note_rename}},
        edit(Dest,conj([{assertz,{agent_key,owner,Key,active}},
            {assertz,{can_invoke,{'_'},Owner,{'_'},{'_'}}},
            {retract,{attribute,room,owner,Human}},{assertz,{attribute,room,owner,Owner}}])),
        edit(Ns,{assertz,{space_assignment_state,personal,1,Room}}),
        executed(Foreign,{hud_contribute,Subject,Choice}),
        ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,{hud_contribution,my_hud,Subject,Choice,Owner})),
        edit(Dest,conj([{retract,{attribute,room,owner,Owner}},{assertz,{attribute,room,owner,Human}}])),
        Another = {entity_ref,Ns,A,n2},
        refused(Foreign,{hud_contribute,Another,Choice}),
        fails(Ns,{hud_contribution,my_hud,Another,Choice,{'_'}}),
        %% Losing the space role does not prevent withdrawing one's own row.
        executed(Foreign,{hud_withdraw,Subject,Choice}),
        edit(Dest,conj([{retract,{attribute,room,owner,Human}},{assertz,{attribute,room,owner,Owner}}])),
        [Delegation] = [Clause || Clause={':-',
            {can_invoke,{',',{current_ontology_identity,_,_},{',',{instance_of,{':',quod,{':',gui,hud}},_},_}},_,_,_},_}
            <- quod_personal_agent_tests:user_terms()],
        edit(Ns,{retract,Delegation}),
        refused(Foreign,{hud_contribute,Subject,Choice}),
        fails(Ns,{hud_contribution,my_hud,Subject,Choice,{'_'}})
    end) end}.

hud(C) ->
    {Bytes,Signature} = quod_personal_agent_tests:request(C,read,{'::',<<"quod:gui">>,{hud_commands,{'View'}}}),
    Reply = quod_client_goal_ingress:submit(Bytes,Signature),
    {ok,_,{normalized,{read,_,{answers,_,[Binding]}}}} = Reply,
    {ok,[{_,{hud,Tree}}]} = quod_client_result:decode_binding(Binding),
    Tree.
strip(C) -> [{property(W,slot),property(W,label)} || W <- children(hud(C))].
executed(C,Goal) when element(1,Goal) =:= hud_contribute; element(1,Goal) =:= hud_offer;
                      element(1,Goal) =:= hud_withdraw; element(1,Goal) =:= hud_withdraw_offer ->
    executed(C,hud_goal(maps:get(namespace,C),Goal));
executed(C,{hud_answer_offer,Human,Offer,Answer}) ->
    executed(C,{'::',<<"quod:gui">>,{hud_answer_offer,Human,Offer,Answer}});
executed(C,Goal) ->
    {Bytes,Signature} = quod_personal_agent_tests:request(C,execute,Goal),
    Result = quod_client_goal_ingress:submit(Bytes,Signature),
    refusal(Goal,Result),
    ?assertMatch({ok,_,{normalized,{committed,_,_}}},Result),
    {ok,Evidence,_} = Result, Op = quod_client_goal:operation_ref(Evidence),
    ?assertMatch(#{operation_state:=terminal},quod_ct:await_operation_complete(element(2,Op),Op,10000)).
refusal(Goal,{ok,_,{normalized,{failed,Blob}}}) ->
    io:format(user,"REFUSED ~P: ~p~n",[Goal,8,quod_wire_term:decode_failure_reasons(Blob)]);
refusal(_,{ok,_,{normalized,{committed,_,_}}}) -> ok;
refusal(Goal,{ok,_,{normalized,Other}}) -> io:format(user,"REFUSED ~P: ~P~n",[Goal,8,Other,12]);
refusal(Goal,Other) -> io:format(user,"REFUSED ~P: ~P~n",[Goal,8,Other,12]).
node_signed(Ns,Goal) ->
    {ok,Bytes,Sig} = quod_node_actor:signed_goal(execute,hud_goal(Ns,Goal),crypto:strong_rand_bytes(32),quod_time:now_ms()+20000),
    {Bytes,Sig}.


fails(Ns,Goal) -> ?assertMatch(fail,quod_prolog:prove_ro(Ns,Goal)).
options({component,Id,_,Properties,Children},Wanted) ->
    case Id of Wanted -> proplists:get_value(options,[{K,V} || {property,K,V} <- Properties]);
        _ -> lists:append([case options(Ch,Wanted) of undefined -> []; O -> O end || Ch <- Children]) end.
signed_read(C,Goal) ->
    {Bytes,Signature} = quod_personal_agent_tests:request(C,read,Goal),
    {ok,_,{normalized,{read,_,{answers,_,[Binding]}}}} = quod_client_goal_ingress:submit(Bytes,Signature),
    {ok,[{_,Value}]} = quod_client_result:decode_binding(Binding),
    Value.
refused(C,Goal) ->
    {Bytes,Signature} = quod_personal_agent_tests:request(C,execute,hud_goal(maps:get(namespace,C),Goal)),
    ?assertMatch({ok,_,{normalized,{failed,_}}},quod_client_goal_ingress:submit(Bytes,Signature)).

with_hud(Fun) ->
    quod_personal_agent_tests:with_personal(fun(C=#{namespace:=Ns,directory:=Dir,identity:=Node,human:=Human}) ->
        Gui = <<"quod:gui">>, Space = <<"quod:space">>, Dest = <<"hud:destination">>,
        GuiOwner = quod_agent_hosting_tests:start_ontology(Gui,Dir,Node,[],quod_ct:gui_terms()),
        Pin = {gui_vocabulary,Gui,quod_simplex:genesis_hash(Gui)},
        Owners = [quod_agent_hosting_tests:start_ontology(Name,Dir,Node,[],Terms) || {Name,Terms} <- [
            {Space,quod_prolog:read_terms("priv/ontologies/quod_space.pl") ++ [Pin]},
            {quod_ontology:root_ns(),[{system_ontology,Gui,quod_simplex:genesis_hash(Gui)},
                {can_invoke,{'_'},{'_'},{'_'},{'_'}}]},
            {Dest,[{can_invoke,{'_'},Human,{'_'},{'_'}},
                {can_invoke,{'_'},maps:get(node,C),{'_'},{'_'}},Pin,
                {instance_of,{':',quod,{':',space,space}},room}, {attribute,room,owner,Human}]}]],
        try
            edit(Ns,{assertz,Pin}), edit(<<"quod:user">>,{assertz,Pin}),
            Fun(C#{destination=>Dest,network=>quod_simplex:genesis_hash(quod_ontology:root_ns())})
        after [quod_agent_hosting_tests:stop_ontology(S) || S <- lists:reverse([GuiOwner|Owners])] end
    end,quod_prolog:read_terms("test/fixtures/note-operations.pl") ++
        [{instance_of,{':',quod,{':',space,space}},S} || S <- [room,closed]]).

hud_goal(Ns,{Function,Subject,Choice}) ->
    {'::',<<"quod:gui">>,{Function,{entity_ref,Ns,quod_simplex:genesis_hash(Ns),my_hud},{choice,Subject,Choice}}}.

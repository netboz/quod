-module(quod_gui_menu_tests).
-include_lib("eunit/include/eunit.hrl").
-export([with_menus/1,property/2,children/1,wedge/2,edit/2,conj/1]).

%% Pie menus are class-selected Eidolons read through the signed human path.

icon_bytes_are_public_signed_facts_test_() ->
    {timeout,90,fun() -> with_menus(fun(C) ->
        Gui = <<"quod:gui">>,
        Assets = [A || A={gui_asset,_,_,_} <- quod_ct:gui_terms()],
        ?assertEqual(36,length(Assets)),
        ?assertEqual(100690,lists:sum([byte_size(B) || {gui_asset,_,_,B} <- Assets])),
        quod_lobby_tests:assert_read_has_no_io(fun() ->
            lists:foreach(fun({gui_asset,Digest,Mime,Bytes}) ->
                lists:foreach(fun(_) ->
                    ?assertEqual(Bytes,read(C,{'::',Gui,{gui_asset,Digest,Mime,{'Bytes'}}}))
                end,[first,unchanged]),
                ?assertEqual(Digest,string:lowercase(binary:encode_hex(crypto:hash(sha256,Bytes))))
            end,Assets)
        end),
        [Asset={gui_asset,Digest,_,_}|_] = Assets,
        {Request,Signature} = quod_personal_agent_tests:request(C,execute,{'::',Gui,{assertz,Asset}}),
        ?assertMatch({ok,_,{normalized,{failed,_}}},quod_client_goal_ingress:submit(Request,Signature)),
        {BadRead,BadSignature} = quod_personal_agent_tests:request(C,read,
            {'::',Gui,{gui_asset,Digest,<<"image/jpeg">>,{'Bytes'}}}),
        ?assertMatch({ok,_,{normalized,{read,_,{failed,_}}}},quod_client_goal_ingress:submit(BadRead,BadSignature))
    end) end}.

release_terms_use_the_existing_signed_edit_gate_test_() ->
    {timeout,90,fun() -> with_menus(fun(C=#{identity:=#{pubkey:=NodeKey}}) ->
        Gui = <<"quod:gui">>, Root = quod_ontology:root_ns(),
        File = "doc/evidence/live-ontology-release-0.7.282-20261108/quod_source_release.erl",
        {ok,quod_source_release,Beam} = compile:file(File,[binary,return_errors]),
        {module,quod_source_release} = code:load_binary(quod_source_release,File,Beam),
        Asset = {gui_asset,<<"release-test">>,<<"application/octet-stream">>,<<0,34,92,137,255>>},
        {planned,Goal} = quod_source_release:terms(Gui,[Asset],true),
        ?assertMatch({'::',Gui,{',',{current_ontology_identity,Gui,_},
            {',',system_prolog_edit,{transaction,{assertz,Asset}}}}},Goal),
        fails(Gui,Asset),
        ?assertNotMatch({ok,_,_},quod_source_release:terms(Gui,[Asset],false)),
        fails(Gui,Asset),
        edit(Root,{assertz,{':-',{system_source_access,
            {ontology_ref,Gui,quod_simplex:genesis_hash(Gui)},editable},
            {current_principal,{node,NodeKey}}}}),
        ?assertMatch({ok,_,_},quod_source_release:terms(Gui,[Asset],false)),
        ?assertEqual(element(4,Asset),read(C,{'::',Gui,{gui_asset,element(2,Asset),element(3,Asset),{'Bytes'}}}))
    end) end}.

default_pie_for_an_instance_test_() ->
    {timeout,90,fun() -> with_menus(fun(C=#{namespace:=Ns}) ->
        Anchor = quod_simplex:genesis_hash(Ns),
        edit(Ns,{',',{assertz,{':-',{instance_of,note,n1},true}},{assertz,{attribute,n1,name,<<"Shopping">>}}}),
        {menu,Tree} = menu(C,n1),
        ?assertEqual(<<"Shopping">>,property(Tree,label)),
        %% Actions first, then the inherited source under Inspect.
        [Rename,Inspect] = children(Tree),
        ?assertEqual({<<"Inspect">>,2},{property(Inspect,label),property(Inspect,slot)}),
        ?assertMatch([{<<"Source">>,{choice,{entity_ref,Ns,Anchor,n1},{eidolon,prolog,source,_}}}],
                     [{property(I,label),property(I,target)} || I <- children(Inspect)]),
        ?assertEqual(<<"Rename note">>,property(Rename,label)),
        ?assertEqual(1,property(Rename,slot)),
        ?assertEqual(true,property(Rename,enabled)),
        ?assertMatch({choice,{entity_ref,Ns,Anchor,n1},{eidolon,{operation,instance},rename,_}},
                     property(Rename,target)),
        plain_labels(Tree),
        %% The menu choice is never offered as one of its own wedges.
        {ok,[#{'Choices':=Choices}],_} = quod_prolog:prove_ro(Ns,{entity_eidolons,n1,{'Choices'}}),
        ?assertMatch([_],[E || E={eidolon,menu,default,_} <- Choices])
    end) end}.

space_pie_overrides_the_default_test_() ->
    {timeout,90,fun() -> with_menus(fun(C=#{namespace:=Ns}) ->
        Anchor = quod_simplex:genesis_hash(Ns),
        Room = {entity_ref,Ns,Anchor,room},
        edit(Ns,conj([{assertz,{account_setup,me,{complete,menu_fixture}}},
            {assertz,{space_assignment_state,personal,1,Room}},
            {assertz,{space_placement,room,{entity_ref,Ns,Anchor,personal},1}},
            {assertz,{space_member,room,{entity_ref,Ns,Anchor,closed}}},
            {assertz,{attribute,closed,name,<<"Closet">>}},
            {assertz,{attribute,room,name,<<"Workshop">>}},
            {assertz,{instance_permission,room,space_visit,deny}},
            {assertz,{attribute,room,dimensions,{box,{q,4,<<"m">>},{q,3,<<"m">>},{q,5,<<"m">>}}}},
            {assertz,{attribute,room,exterior,solid}},{assertz,{attribute,room,transform,{transform,0,0,0,0,0,0}}}])),
        {menu,Tree} = menu(C,room),
        ?assertEqual(<<"Workshop">>,property(Tree,label)),
        plain_labels(Tree),
        Create = wedge(Tree,1), ?assertEqual(<<"Create here">>,property(Create,label)),
        ?assertMatch({image,{asset,_,<<"image/png">>},{resources,_,_}},property(Create,image)),
        {image,{asset,Digest,_},{resources,Transfer,Pixels}} = property(Create,image),
        IconBytes = read(C,{'::',<<"quod:gui">>,{gui_asset,Digest,<<"image/png">>,{0}}}),
        <<_:16/binary,Width:32,Height:32,_/binary>> = IconBytes,
        ?assertEqual({byte_size(IconBytes),Width*Height},{Transfer,Pixels}),
        ?assertEqual(5,property(Create,back)),
        ?assertEqual(lists:sort([<<"Create space">>,<<"Create space with rational lengths">>,
                                 <<"Create infinite space">>]),
                     lists:sort([property(I,label) || I <- children(Create)])),
        %% Show as offers how the inside looks, never the current choice again.
        ?assertEqual(<<"Show as">>,property(wedge(Tree,2),label)),
        ?assertEqual([<<"Matrix walls">>,<<"Wire box walls">>],
                     lists:sort([property(I,label) || I <- children(wedge(Tree,2))])),
        %% Leave keeps the fixed bottom wedge and asks for a second press; the
        %% unauthorized choice stays visible, dimmed, with its plain reason.
        Leave = wedge(Tree,5),
        ?assertEqual(<<"Leave space">>,property(Leave,label)),
        ?assertEqual(true,property(Leave,confirm)),
        ?assertEqual(false,property(Leave,enabled)),
        ?assertEqual(<<"You are not allowed to do this here.">>,property(Leave,help)),
        [GoTo] = [W || W <- children(Tree), property(W,label) =:= <<"Go to">>],
        [Closet] = children(GoTo),
        ?assertEqual(<<"Closet">>,property(Closet,label)),
        ?assertMatch({choice,{entity_ref,Ns,Anchor,closed},{eidolon,{operation,instance},enter,_}},
                     property(Closet,target)),
        %% The class itself keeps the shared default pie: its creation forms.
        {menu,ClassPie} = menu(C,space_class()),
        ?assertEqual(lists:sort([<<"Create space">>,<<"Create space with rational lengths">>,<<"Create infinite space">>]),
                     lists:sort([property(W,label) || W <- children(ClassPie), property(W,target) =/= undefined,
                                 element(1,element(2,property(W,target))) =:= class_ref])),
        %% Availability reads the storing ontology's committed ACL again.
        edit(Ns,{retract,{instance_permission,room,space_visit,deny}}),
        {menu,Owned} = menu(C,room),
        ?assertEqual(true,property(wedge(Owned,5),enabled))
    end) end}.

interior_boundary_uses_the_exterior_recipes_test_() ->
    {timeout,120,fun() -> with_menus(fun(C=#{namespace:=Ns}) ->
        A = quod_simplex:genesis_hash(Ns), T = {transform,0,0,0,0,0,0},
        edit(Ns,conj([{assertz,{account_setup,me,{complete,interior_fixture}}},
            {assertz,{attribute,room,owner,maps:get(human,C)}},{assertz,{attribute,closed,owner,maps:get(human,C)}},
            {assertz,{attribute,room,dimensions,{box,{q,4,<<"m">>},{q,3,<<"m">>},{q,5,<<"m">>}}}},
            {assertz,{attribute,room,exterior,solid}},{assertz,{attribute,room,transform,T}},
            {assertz,{attribute,closed,dimensions,infinite}},
            {assertz,{attribute,closed,exterior,solid}},{assertz,{attribute,closed,transform,T}}])),
        quod_space_creation_tests:with_models(C,fun() ->
            ?assertEqual([],boundary(C,Ns,A)),
            executed(C,space({space_represent,ref(Ns,room),solid,T,none,solid,T,wireframe})),
            applied(Ns,fun() -> boundary(C,Ns,A) =/= [] end),
            {[Root],Parts} = boundary(C,Ns,A),
            ?assertMatch({mark,_,<<"group">>,[],T,no_surface,_,{depicts,Ns,A,room}},Root),
            ?assertMatch([{mark,_,<<"wire_box">>,[{f,<<"width">>,4000},{f,<<"height">>,3000},{f,<<"depth">>,5000}],_,_,_,_}],Parts),
            %% One recipe answers both selectors: it is the exterior wireframe.
            ?assertMatch([{part,_,{wire_box,4000,3000,5000},_,_,_,_}],
                read(C,space({eidolon,space_wireframe,
                    {subject,{ontology_ref,Ns,A},room},{'Parts'}}))),
            executed(C,space({space_represent,ref(Ns,room),solid,T,wireframe,solid,T,matrix})),
            applied(Ns,fun() -> case boundary(C,Ns,A) of {_,P} -> length(P) =:= 2; [] -> false end end),
            {[_],Matrix} = boundary(C,Ns,A),
            ?assertMatch([{mark,_,<<"box">>,_,_,{surface,_,_,_,_,220,[]},_,_},{mark,_,<<"wire_box">>,_,_,_,_,_}],Matrix),
            executed(C,space({space_represent,ref(Ns,room),solid,T,matrix,solid,T,none})),
            applied(Ns,fun() -> boundary(C,Ns,A) =:= [] end),
            ?assertEqual([],boundary(C,Ns,A)),
            fails(Ns,{attribute,room,interior,{'_'}}),
            %% Infinite extent refuses finite boundaries with the existing reason.
            denied(C,space({space_represent,ref(Ns,closed),solid,T,none,solid,T,matrix}),{space_exterior_unavailable,matrix,infinite})
        end)
    end) end}.

boundary(C,Ns,A) ->
    Marks = read(C,space({world_view,ref(Ns,room),playing,{'Marks'}})),
    case [M || M={mark,_,<<"group">>,_,_,_,_,{depicts,N,H,room}} <- Marks, {N,H}=:={Ns,A}] of
        [] -> [];
        [Root] -> {[Root],[M || M={mark,_,_,_,{relative,P,_},_,_,_} <- Marks, P =:= element(2,Root)]}
    end.
executed(C,Goal) ->
    {Bytes,Signature} = quod_personal_agent_tests:request(C,execute,Goal),
    Result = quod_client_goal_ingress:submit(Bytes,Signature),
    ?assertMatch({ok,_,{normalized,{committed,_,_}}},Result),
    {ok,Evidence,_} = Result, Op = quod_client_goal:operation_ref(Evidence),
    ?assertMatch(#{operation_state:=terminal},quod_ct:await_operation_complete(element(2,Op),Op,10000)).
denied(C,Goal,Reason) ->
    {Bytes,Signature} = quod_personal_agent_tests:request(C,execute,Goal),
    {ok,_,{normalized,{failed,Blob}}} = quod_client_goal_ingress:submit(Bytes,Signature),
    {ok,Reasons} = quod_wire_term:decode_failure_reasons(Blob),
    ?assertMatch({true,_},{lists:member(Reason,Reasons),Reasons}).
fails(Ns,Goal) -> ?assertMatch({fail,_},quod_prolog:prove_ro(Ns,Goal)).
%% A committed change becomes readable when the owner's projection advances;
%% recheck on those notices only, never on a timer.
applied(Ns,Ready) ->
    true = quod_reg:subscribe({runtime,Ns}),
    try applied_loop(Ready,quod_time:mono_ms()+10000) after quod_reg:unsubscribe({runtime,Ns}) end.
applied_loop(Ready,Deadline) ->
    case Ready() of
        true -> ok;
        false -> receive {projection_advanced,_,_} -> applied_loop(Ready,Deadline)
                 after max(0,Deadline-quod_time:mono_ms()) -> error(change_not_applied) end
    end.

unplaced_agent_pie_offers_the_ways_in_test_() ->
    {timeout,90,fun() -> with_menus(fun(C=#{namespace:=Ns}) ->
        Anchor = quod_simplex:genesis_hash(Ns),
        edit(Ns,conj([{assertz,{account_setup,me,{complete,menu_fixture}}},
            {assertz,{attribute,room,name,<<"Workshop">>}},
            {assertz,{attribute,personal,transform,{transform,0,0,0,0,0,0}}}])),
        {menu,Tree} = menu(C,personal),
        ?assertEqual(<<"You are nowhere yet">>,property(Tree,label)),
        plain_labels(Tree),
        Known = wedge(Tree,1), ?assertEqual(<<"Enter a known space">>,property(Known,label)),
        ?assertMatch([{<<"Workshop">>,{choice,{entity_ref,Ns,Anchor,room},{eidolon,{operation,instance},enter,_}}}],
            [{property(I,label),property(I,target)} || I <- children(Known), property(I,label) =:= <<"Workshop">>]),
        ?assertEqual(<<"Create a space">>,property(wedge(Tree,3),label)),
        ?assertEqual(3,length(children(wedge(Tree,3)))),
        ?assertEqual([<<"quod:space">>],lists:usort([Owner || Item <- children(wedge(Tree,3)),
            {choice,{class_ref,Owner,_,space},_} <- [property(Item,target)]])),
        Account = wedge(Tree,5),
        ?assertMatch([{choice,{entity_ref,Ns,Anchor,me},{eidolon,prolog,source,_}}],
                     [property(I,target) || I <- children(Account)]),
        %% The human, also an agent, keeps the shared default pie.
        {menu,Human} = menu(C,me),
        ?assertEqual([<<"Inspect">>],[property(W,label) || W <- children(Human)])
    end) end}.

%% The pie arrives through the same live view socket the client opens.
menu_view_socket_projects_the_pie_test_() ->
    {timeout,90,fun() -> with_menus(fun(C=#{namespace:=Ns}) ->
        Parent = self(),
        Socket = spawn_link(fun() -> quod_physics_tests:simulation_socket(Parent,#{peer=>{127,0,0,1}}) end),
        Reader = #{agent=>{Ns,quod_simplex:genesis_hash(Ns)},key_pair=>maps:get(human_pair,C),
                   network=>maps:get(network,C),instance=><<"me.">>},
        try
            Socket ! {client,quod_gui_question_tests:gui_open_message(Reader,maps:get(session,C),menu,Ns,
                quod_simplex:genesis_hash(Ns),space_class(),0)},
            #{<<"value">>:=Value,<<"kind">>:=<<"menu">>} = quod_physics_tests:simulation_reply(Socket,<<"projection">>),
            ?assertNotEqual(nomatch,binary:match(Value,<<"Create infinite space">>)),
            Old = read(C,{'::',<<"quod:gui">>,{gui_icon,create_finite,{'Icon'}}}),
            New = read(C,{'::',<<"quod:gui">>,{gui_icon,accept,{'Icon'}}}),
            {image,{asset,OldDigest,_},_} = Old,
            {image,{asset,NewDigest,_},_} = New,
            ?assertNotEqual(nomatch,binary:match(Value,quod_client_goal_parser:value_text(OldDigest))),
            edit(<<"quod:gui">>,{transaction,conj([{retract,{gui_icon,create_finite,Old}},
                                                  {assertz,{gui_icon,create_finite,New}}])}),
            ?assertMatch(#{<<"type">>:=<<"refresh">>},quod_physics_tests:simulation_reply(Socket,<<"refresh">>)),
            Socket ! {client,quod_gui_question_tests:gui_open_message(Reader,maps:get(session,C),menu,Ns,
                quod_simplex:genesis_hash(Ns),space_class(),0)},
            #{<<"value">>:=Changed} = quod_physics_tests:simulation_reply(Socket,<<"projection">>),
            ?assertEqual(nomatch,binary:match(Changed,quod_client_goal_parser:value_text(OldDigest))),
            ?assertNotEqual(nomatch,binary:match(Changed,quod_client_goal_parser:value_text(NewDigest)))
        after Socket ! stop end
    end) end}.

overflow_nests_under_more_and_keeps_pins_test_() ->
    {timeout,90,fun() -> with_menus(fun(C=#{namespace:=Ns}) ->
        Gui = <<"quod:gui">>, Subject = {entity_ref,Ns,quod_simplex:genesis_hash(Ns),n1},
        Item = fun(N,Options) -> {item,{choice,Subject,{eidolon,playing,list_to_atom("s"++integer_to_list(N)),
                    {recipe,Ns,quod_simplex:genesis_hash(Ns),r}}},
                    list_to_binary("Item "++integer_to_list(N)),<<>>,available,Options} end,
        Entries = [Item(N,[]) || N <- lists:seq(1,9)] ++ [Item(10,[{slot,5}])],
        {ok,[#{'T':=Tree}],_} = quod_prolog:prove_ro(Gui,{menu_tree,{menu,<<"Many">>,<<>>,[],Entries},{'T'}}),
        ?assertEqual(8,length(children(Tree))),
        ?assertEqual([1,2,3,4,5,6,7,8],[property(W,slot) || W <- children(Tree)]),
        ?assertEqual(<<"Item 10">>,property(wedge(Tree,5),label)),
        More = wedge(Tree,8),
        ?assertEqual(<<"More">>,property(More,label)),
        ?assertEqual([<<"Item 7">>,<<"Item 8">>,<<"Item 9">>],[property(W,label) || W <- children(More)]),
        ?assertEqual({wedge,[8,1]},element(2,hd(children(More)))),
        %% A nested level keeps the wedge pointing back at its parent free.
        ?assertEqual(4,property(More,back)),
        ?assertEqual(none,property(Tree,back)),
        ?assertEqual([1,2,3],[property(W,slot) || W <- children(More)]),
        %% A recipe's own wedge count is an authored allowance, not a cap.
        {ok,[#{'T':=Four}],_} = quod_prolog:prove_ro(Gui,{menu_tree,
            {menu,<<"Few">>,<<>>,[{wedges,4}],[Item(N,[]) || N <- lists:seq(1,5)]},{'T'}}),
        ?assertEqual(4,length(children(Four))),
        %% "More" is an ordinary pie with the vocabulary's wedges.
        ?assertEqual({8,3,[1,2]},{property(wedge(Four,4),wedges),property(wedge(Four,4),back),
                                  [property(W,slot) || W <- children(wedge(Four,4))]}),
        %% Conflicting or impossible positions and empty labels are refused.
        [?assertMatch({fail,_},quod_prolog:prove_ro(Gui,{menu_tree,Bad,{'T'}})) || Bad <- [
            {menu,<<"Clash">>,<<>>,[],[Item(1,[{slot,2}]),Item(2,[{slot,2}])]},
            {menu,<<"Outside">>,<<>>,[{wedges,4}],[Item(1,[{slot,5}])]},
            {menu,<<"Back">>,<<>>,[],[{menu,<<"Sub">>,<<>>,[{slot,1}],[Item(1,[{slot,5}])]}]},
            {menu,<<"Too few">>,<<>>,[{wedges,1}],[Item(1,[]),Item(2,[])]},
            {menu,<<>>,<<>>,[],[Item(1,[])]},
            {menu,<<"Unlabelled">>,<<>>,[],[setelement(3,Item(1,[]),<<>>)]}]],
        ?assert(is_map(C))
    end) end}.

%% The ordinary forms fixture plus the root catalogue every node has, so the
%% shared thing/ontology associations resolve their exact GUI vocabulary.
with_menus(Fun) ->
    quod_gui_stage1_tests:with_forms(fun(C=#{identity:=Node,directory:=Dir}) ->
        Gui = <<"quod:gui">>, Root = quod_ontology:root_ns(),
        Sup = quod_agent_hosting_tests:start_ontology(Root,Dir,Node,[],
            [{system_ontology,Gui,quod_simplex:genesis_hash(Gui)},
             {can_invoke,{'_'},{'_'},{'_'},{'_'}}]),
        try Fun(C#{network=>quod_simplex:genesis_hash(Root)})
        after quod_agent_hosting_tests:stop_ontology(Sup) end
    end).

menu(C,Entity) ->
    read(C,{client_menu,Entity,{'View'}}).

read(C,Goal) ->
    {Bytes,Signature} = quod_personal_agent_tests:request(C,read,Goal),
    case quod_client_goal_ingress:submit(Bytes,Signature) of
        {ok,_,{normalized,{read,_,{answers,_,[Binding]}}}} ->
            {ok,[{_,Value}]} = quod_client_result:decode_binding(Binding), Value;
        {ok,_,{normalized,{read,_,{failed,Blob}}}} ->
            {ok,Reasons} = quod_wire_term:decode_failure_reasons(Blob),
            error({menu_read_failed,Goal,lists:flatten(io_lib:format("~P",[Reasons,12]))});
        {ok,_,{normalized,Other}} -> error({menu_read_error,element(1,Other)})
    end.
ref(Ns,Id) -> {entity_ref,Ns,quod_simplex:genesis_hash(Ns),Id}.
space_class() -> {':',quod,{':',space,space}}.
space(Goal) -> {'::',<<"quod:space">>,Goal}.

property({component,_,_,Properties,_},Key) -> proplists:get_value(Key,[{K,V} || {property,K,V} <- Properties]).
children({component,_,_,_,Children}) -> Children.
wedge(Menu,Slot) -> [W] = [W || W <- children(Menu), property(W,slot) =:= Slot], W.
plain_labels(Component = {component,_,Kind,_,Children}) ->
    ?assert(lists:member(Kind,[menu,menu_item])),
    Label = property(Component,label), ?assert(is_binary(Label) andalso Label =/= <<>>),
    [plain_labels(Child) || Child <- Children], ok.
conj([G]) -> G;
conj([G|Gs]) -> {',',G,conj(Gs)}.
edit(Ns,Goal) -> ?assertMatch({ok,_,_},quod_prolog:execute(Ns,Goal)).

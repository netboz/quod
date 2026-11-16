-module(quod_show_as_tests).
-include_lib("eunit/include/eunit.hrl").

%% Which Eidolon a viewer sees: their own choice, else the instance's, else
%% the class default. "Show as" in the pie changes only what that viewer sees;
%% the choice is stored in their own ontology, never on the thing.

-import(quod_gui_menu_tests,[with_menus/1,edit/2,conj/1,read/2,menu/2,boundary/4,executed/2,
                             applied/2,icon/2,ref/2,space/1,fails/2,property/2,children/1]).

inside_show_as_changes_only_what_i_see_test_() ->
    {timeout,180,fun() -> with_menus(fun(C=#{namespace:=Ns}) ->
        A = quod_simplex:genesis_hash(Ns), Room = ref(Ns,room),
        inside(Ns,room),
        ?assertEqual([],boundary(C,Ns,A,room)),
        ?assertEqual([<<"Matrix">>,<<"Wire">>],shows(C,room)),
        choose(C,Room,{show,interior,matrix}),
        applied(Ns,fun() -> boundary(C,Ns,A,room) =/= [] end),
        {[_],Walls} = boundary(C,Ns,A,room),
        ?assertMatch([{mark,_,<<"box">>,_,_,_,_,_},{mark,_,<<"corner_box">>,_,_,_,_,_}],Walls),
        %% The space's own facts are unchanged; the choice is the human's.
        fails(Ns,{attribute,room,interior,{'_'}}),
        holds(Ns,{attribute,me,show_as,{shown,Room,interior,matrix}}),
        ?assertEqual([<<"Default">>,<<"Wire">>],shows(C,room)),
        %% A proof with no viewer sees the instance's choice: no walls.
        {ok,[#{'M':=NodeMarks}],_} = quod_prolog:prove_ro(<<"quod:space">>,{world_view,Room,playing,{'M'}}),
        ?assertEqual([],[M || M={mark,_,<<"group">>,_,_,_,_,{depicts,_,_,room}} <- NodeMarks]),
        %% Another human in the same space sees no walls.
        other_human(C,fun(Other) -> ?assertEqual([],boundary(Other,Ns,A,room)) end),
        %% Default removes my own choice.
        choose(C,Room,{show,interior,default}),
        applied(Ns,fun() -> boundary(C,Ns,A,room) =:= [] end),
        fails(Ns,{attribute,me,show_as,{'_'}}),
        ?assertEqual([<<"Matrix">>,<<"Wire">>],shows(C,room))
    end) end}.

outside_show_as_changes_only_what_i_see_test_() ->
    {timeout,180,fun() -> with_menus(fun(C=#{namespace:=Ns}) ->
        A = quod_simplex:genesis_hash(Ns), Room = ref(Ns,room), T = {transform,0,0,0,0,0,0},
        inside(Ns,closed),
        %% The room stands in the space I am in and shows a box inside it.
        edit(Ns,conj([{assertz,{':-',{instance_of,{':',quod,{':',space,space}},box},true}},
            {assertz,{attribute,box,dimensions,{box,{q,1,<<"m">>},{q,1,<<"m">>},{q,1,<<"m">>}}}},
            {assertz,{attribute,box,exterior,solid}},{assertz,{attribute,box,transform,T}},
            {assertz,{space_member,room,ref(Ns,box)}},
            {assertz,{space_member,closed,Room}}])),
        Box = fun(Viewer) -> [M || M={mark,_,_,_,_,_,_,{depicts,_,_,box}} <- world(Viewer,Ns,closed)] end,
        ?assertEqual([],Box(C)),
        %% Each wedge carries the icon declared with its Eidolon; Default its own.
        ?assertEqual([{<<"Contents">>,icon(C,contents)}],wedges(C,room)),
        choose(C,Room,{show,playing,contents}),
        applied(Ns,fun() -> Box(C) =/= [] end),
        ?assertEqual([{<<"Default">>,icon(C,default)},{<<"Solid">>,icon(C,solid)}],wedges(C,room)),
        holds(Ns,{attribute,room,exterior,solid}),
        %% Another viewer still sees the marker.
        other_human(C,fun(Other) -> ?assertEqual([],Box(Other)) end)
    end) end}.

infinite_space_offers_no_walls_test_() ->
    {timeout,120,fun() -> with_menus(fun(C=#{namespace:=Ns}) ->
        inside(Ns,closed),
        {menu,Tree} = menu(C,closed),
        ?assertEqual([],[W || W <- children(Tree), property(W,label) =:= <<"Show as">>]),
        ?assertEqual([],[N || {operation_view,N={show,interior,_},_,_,_,_,_,_,_} <- read(C,{gui_operations,ref(Ns,closed),{'V'}})])
    end) end}.

%% An Eidolon added to the class later is offered with nothing else to
%% change; a choice whose Eidolon the class no longer lists counts as none.
new_eidolon_appears_by_itself_test_() ->
    {timeout,180,fun() -> with_menus(fun(C=#{namespace:=Ns}) ->
        A = quod_simplex:genesis_hash(Ns), Room = ref(Ns,room), T = {transform,0,0,0,0,0,0},
        Space = <<"quod:space">>, SA = quod_simplex:genesis_hash(Space),
        inside(Ns,room),
        executed(C,space({space_represent,Room,solid,T,none,solid,T,wireframe})),
        applied(Ns,fun() -> length(walls(C,Ns,A)) =:= 1 end),
        ?assertEqual([<<"Matrix">>],shows(C,room)),
        Icon = icon(C,matrix),
        Glass = {class_eidolon,space,interior,glass,{recipe,Space,SA,space_matrix}},
        edit(Space,conj([{assertz,Glass},
            {assertz,{attribute,{eidolon,space,interior,glass},label,<<"Glass">>}},
            {assertz,{attribute,{eidolon,space,interior,glass},image,Icon}}])),
        {menu,Tree} = menu(C,room),
        [Show] = [W || W <- children(Tree), property(W,label) =:= <<"Show as">>],
        ?assertEqual([{<<"Glass">>,Icon},{<<"Matrix">>,Icon}],
                     lists:sort([{property(W,label),property(W,image)} || W <- children(Show)])),
        choose(C,Room,{show,interior,glass}),
        applied(Ns,fun() -> length(walls(C,Ns,A)) =:= 2 end),
        edit(Space,{retract,Glass}),
        %% The stored choice remains but no longer counts: the instance's shows.
        applied(Ns,fun() -> length(walls(C,Ns,A)) =:= 1 end),
        holds(Ns,{attribute,me,show_as,{shown,Room,interior,glass}}),
        ?assertEqual([<<"Matrix">>],shows(C,room))
    end) end}.

reflected_ontology_opens_without_walls_test_() ->
    {timeout,120,fun() -> with_menus(fun(C=#{namespace:=Ns}) ->
        A = quod_simplex:genesis_hash(Ns), Ontology = {ontology_ref,Ns,A},
        ?assert(is_list(world(C,Ns,Ontology))),
        ?assertEqual([],boundary(C,Ns,A,Ontology))
    end) end}.

%% The open world view follows what it read, the viewer's own choice included.
open_world_view_refreshes_on_my_choice_test_() ->
    {timeout,120,fun() -> with_menus(fun(C=#{namespace:=Ns}) ->
        A = quod_simplex:genesis_hash(Ns), Parent = self(),
        inside(Ns,room),
        Socket = spawn_link(fun() -> quod_physics_tests:simulation_socket(Parent,#{peer=>{127,0,0,1}}) end),
        Reader = #{agent=>{Ns,A},key_pair=>maps:get(human_pair,C),network=>maps:get(network,C),instance=><<"me.">>},
        try
            Socket ! {client,quod_gui_question_tests:gui_open_message(Reader,maps:get(session,C),world,Ns,A,room,0)},
            #{<<"marks">>:=<<"[]">>} = quod_physics_tests:simulation_reply(Socket,<<"projection">>),
            choose(C,ref(Ns,room),{show,interior,matrix}),
            ?assertMatch(#{<<"type">>:=<<"refresh">>},quod_physics_tests:simulation_reply(Socket,<<"refresh">>))
        after Socket ! stop end
    end) end}.

%% The personal agent is inside Space, a finite room or the infinite closet.
inside(Ns,Space) ->
    A = quod_simplex:genesis_hash(Ns), T = {transform,0,0,0,0,0,0},
    edit(Ns,conj([{assertz,{account_setup,me,{complete,show_as_fixture}}},
        {assertz,{space_assignment_state,personal,1,ref(Ns,Space)}},
        {assertz,{space_placement,Space,{entity_ref,Ns,A,personal},1}},
        {assertz,{attribute,room,dimensions,{box,{q,4,<<"m">>},{q,3,<<"m">>},{q,5,<<"m">>}}}},
        {assertz,{attribute,room,exterior,solid}},{assertz,{attribute,room,transform,T}},
        {assertz,{attribute,closed,dimensions,infinite}},
        {assertz,{attribute,closed,exterior,solid}},{assertz,{attribute,closed,transform,T}},
        %% Like a user's own ontology, the store names its rendering vocabulary.
        {assertz,{rendering_vocabulary,<<"creation-rendering">>,quod_simplex:genesis_hash(<<"creation-rendering">>)}}])).

shows(C,Space) -> [Label || {Label,_} <- wedges(C,Space)].
wedges(C,Space) ->
    {menu,Tree} = menu(C,Space),
    [Show] = [W || W <- children(Tree), property(W,label) =:= <<"Show as">>],
    lists:sort([{property(I,label),property(I,image)} || I <- children(Show)]).

%% The offered action, chosen as the client does: its current revision, its
%% one submit control, no fields.
choose(C,Subject,Name) ->
    [Revision] = [R || {operation_view,N,_,R,_,_,_,_,_,_} <- read(C,{gui_operations,Subject,{'V'}}), N =:= Name],
    Goal = {gui_operation,Subject,Name,Revision,show_as_submit,[],{'Results'}},
    {B,S} = quod_personal_agent_tests:request(C,execute,Goal),
    case quod_client_goal_ingress:submit(B,S) of
        {ok,_,{normalized,{failed,Blob}}} -> {ok,Rs} = quod_wire_term:decode_failure_reasons(Blob), error({refused,Name,Rs});
        {ok,Evidence,{normalized,{committed,_,_}}} ->
            Op = quod_client_goal:operation_ref(Evidence),
            #{operation_state:=terminal} = quod_ct:await_operation_complete(element(2,Op),Op,10000), ok
    end.

world(Viewer,Ns,Space) -> read(Viewer,space({world_view,ref(Ns,Space),playing,{'Marks'}})).
walls(C,Ns,A) -> case boundary(C,Ns,A,room) of {_,Parts} -> Parts; [] -> [] end.
holds(Ns,Goal) -> ?assertMatch({ok,[_],_},quod_prolog:prove_ro(Ns,Goal)).

%% A second human, in their own ontology, allowed to read this one.
other_human(C=#{namespace:=Ns,directory:=Dir,identity:=Node},Fun) ->
    {Key,_} = Pair = quod_identity:generate(), OtherNs = <<"other-human">>,
    Sup = quod_agent_hosting_tests:start_ontology(OtherNs,Dir,Node,[],
        quod_personal_agent_tests:user_terms() ++
            [{instance_of,{':',quod,{':',user,human_user}},me},{agent_key,me,Key,active}]),
    Other = {agent_instance_ref,OtherNs,quod_simplex:genesis_hash(OtherNs),me},
    edit(Ns,{assertz,{can_invoke,{'_'},Other,{'_'},{'_'}}}),
    try Fun(C#{human=>Other,human_pair=>Pair})
    after quod_agent_hosting_tests:stop_ontology(Sup) end.

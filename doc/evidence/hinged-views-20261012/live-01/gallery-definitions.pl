physics_hinged_class(container_lid,1,
 hinged(box(1000,200,100),parts([part(vector(0,0,0),box(1000,100,1000)),
 part(vector(0,150,HandleZ),ball(150))]),1,vector(1,0,0),
 anchors(vector(0,0,0),vector(0,0,AnchorZ)),limits(Lower,1200),Baseline,
 position(400,motor(1000,100,1000),stop(20,target_or_contact)))) :-
 HandleZ is -700,AnchorZ is -1000,Lower is -1300,Baseline is -1200.
physics_hinged_consequence(room,3,Request,closed,assertz(hinged_result(container_closed,Request))).
hinged_example_appearance(room,3,<<"hinged-lid">>,container_lid,
 [part(<<"hinged-lid/panel">>,<<"box">>,[f(<<"width">>,2000),f(<<"height">>,200),f(<<"depth">>,2000)],
 transform(0,0,0,0,0,0),surface(<<"#C48A45">>,0,900,0,[])),
 part(<<"hinged-lid/handle">>,<<"sphere">>,[f(<<"diameter">>,300)],
 transform(0,150,HandleZ,0,0,0),surface(<<"#D7CB9F">>,600,450,0,[]))]) :- HandleZ is -700.
can_close_physics_hinged(W,D,P) :- hinged_example_permission(W,D,P).
can_cancel_physics_hinged(W,D,P) :- hinged_example_permission(W,D,P).
can_edit_physics(W,P) :- hinged_example_owner(W,P).
can_view_physics(W,P) :- hinged_example_owner(W,P).
lobby_owner(P) :- hinged_example_owner(room,P).
lobby_space(room,[playing]).
world_view(room,playing,Marks) :- hinged_example_view(room,Hinges),
 hinged_fixture_view(room,Fixtures),append(Hinges,Fixtures,Marks).
hinged_fixture_view(W,Marks) :- current_ontology_identity(Ns,Anchor),
 findall(mark(Id,Kind,Fields,body_pose(B,R),Surface,unlabelled,depicts(Ns,Anchor,Subject)),
 (hinged_fixture_appearance(W,B,Id,Kind,Fields,Surface,Subject),
 physics_body_definition(W,B,R,_,_,_)),Bodies),
 append(Bodies,[mark(<<"console">>,<<"box">>,
 [f(<<"width">>,1200),f(<<"height">>,800),f(<<"depth">>,200)],
 transform(3200,500,0,0,0,0),surface(<<"#174452">>,0,900,0,[]),
 label(<<"Console">>,<<"above">>),depicts(Ns,Anchor,console))],Marks).
hinged_fixture_appearance(room,1,<<"floor">>,<<"box">>,
 [f(<<"width">>,16000),f(<<"height">>,500),f(<<"depth">>,16000)],
 surface(<<"#736E5D">>,0,900,0,[]),gallery_floor).
hinged_fixture_appearance(room,4,<<"hinged-lid/frame">>,<<"box">>,
 [f(<<"width">>,2000),f(<<"height">>,400),f(<<"depth">>,200)],
 surface(<<"#737373">>,0,900,0,[]),lid_frame).
hinged_fixture_appearance(room,5,<<"hinged-lid/obstacle">>,<<"box">>,
 [f(<<"width">>,400),f(<<"height">>,2000),f(<<"depth">>,400)],
 surface(<<"#AB4646">>,0,900,0,[]),lid_obstacle).
lobby_menu(console,[menu_entry(prove_goal,<<"Prove a goal">>,open_view(proof_console))]).
lobby_workspace(console,prove_console,form(<<"Prolog console">>,
 [editor(goal,<<"Prolog goal">>),bindings(results,<<"Bindings">>),
 button(run,<<"Run">>),button(next,<<"Next solution">>),button(accept,<<"Accept solution">>),
 button(stop,<<"Stop">>),button(resolve,<<"Check saved outcome">>)])).
can_invoke(physics_store_hinged_request(_,_,_,_),P,_,Ns) :-
 current_ontology_identity(Ns,Anchor),P=agent_instance_ref(Ns,Anchor,physics_authority).
can_invoke(physics_finish_hinged(_,_),P,_,Ns) :-
 current_ontology_identity(Ns,Anchor),P=agent_instance_ref(Ns,Anchor,physics_authority).
rendering_vocabulary(<<"quod:rendering">>,<<"\x59\\xd5\\xdf\\x07\\xa7\\xe6\\x59\\x44\\x34\\xa7\\x6d\\x54\\x61\\xa6\\x8f\\x4d\\xc3\\xb5\\xa4\\x8e\\xdb\\xc1\\xb8\\xa6\\x02\\xc9\\x9a\\x48\\x79\\x33\\xa1\\x3d\">>).

physics_hinged_class(vertical_door, 1,
    hinged(box(50,1000,50), box(1000,1000,100), 1, vector(0,1,0),
           anchors(vector(0,0,0),vector(X,0,0)), limits(Lower,1500), 1500,
           position(0,motor(100,10,1000),stop(20,target_or_contact)))) :-
    X is -1000, Lower is -1500.
physics_hinged_consequence(personal_lobby,5,Request,closed,
                          assertz(hinged_result(passage_closed,Request))).
hinged_example_appearance(personal_lobby,5,<<"hinged-door">>,vertical_door,
 [part(<<"hinged-door/panel">>,<<"box">>,
 [f(<<"width">>,2000),f(<<"height">>,2000),f(<<"depth">>,200)],
 transform(0,0,0,0,0,0),surface(<<"#4678AB">>,0,900,0,[]))]).
can_close_physics_hinged(W,D,P) :- hinged_example_permission(W,D,P).
can_cancel_physics_hinged(W,D,P) :- hinged_example_permission(W,D,P).
can_edit_physics(W,P) :- hinged_example_owner(W,P).
world_view(W,Mode,Marks) :- instance_of(lobby,W),lobby_view(Mode,Base),
 hinged_example_view(W,Extra),hinged_fixture_view(W,Fixtures),
 append(Base,Extra,WithHinges),append(WithHinges,Fixtures,Marks).
hinged_fixture_view(W,Marks) :- current_ontology_identity(Ns,Anchor),
 findall(mark(Id,Kind,Fields,body_pose(B,R),Surface,unlabelled,depicts(Ns,Anchor,Subject)),
 (hinged_fixture_appearance(W,B,Id,Kind,Fields,Surface,Subject),
 physics_body_definition(W,B,R,_,_,_)),Marks).
hinged_fixture_appearance(personal_lobby,6,<<"hinged-door/frame">>,<<"box">>,
 [f(<<"width">>,100),f(<<"height">>,2000),f(<<"depth">>,100)],
 surface(<<"#737373">>,0,900,0,[]),door_frame).
hinged_fixture_appearance(personal_lobby,7,<<"hinged-door/obstacle">>,<<"box">>,
 [f(<<"width">>,400),f(<<"height">>,2000),f(<<"depth">>,400)],
 surface(<<"#AB4646">>,0,900,0,[]),door_obstacle).
can_invoke(physics_store_hinged_request(_,_,_,_),P,_,Ns) :-
 current_ontology_identity(Ns,Anchor),P=agent_instance_ref(Ns,Anchor,physics_authority).
can_invoke(physics_finish_hinged(_,_),P,_,Ns) :-
 current_ontology_identity(Ns,Anchor),P=agent_instance_ref(Ns,Anchor,physics_authority).

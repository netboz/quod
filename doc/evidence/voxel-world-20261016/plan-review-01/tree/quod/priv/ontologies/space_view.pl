%% Pure space depiction, composed with the space vocabulary and ordinary
%% entity Eidolons. Membership and physical bindings stay with their owners.
world_view(Space, Mode, Marks) :-
    space_instance(Space,space),
    findall(Subject,space_contains(Space,Subject),Raw), sort(Raw,Subjects),
    space_scene_parts(Subjects,Space,Mode,Parts),
    modelling_vocabulary(Ns,A),
    Ns::(current_ontology_identity(Ns,A),model(Parts,Marks)).

space_scene_parts([],_,_,[]).
space_scene_parts([entity_ref(Ns,A,Entity)|Rest],Space,Mode,Parts) :-
    Ns::(current_ontology_identity(Ns,A),entity_scene(Entity,Mode,Scene)),
    (Scene = hidden -> Placed = []
    ; Scene = appearance(Id,Style,Context,Layout,Eidolons),
      findall(Recipe,member(eidolon(Mode,Style,Recipe),Eidolons),Recipes),
      space_entity_model(Recipes,Context,Model),
      space_entity_pose(Space,entity_ref(Ns,A,Entity),Layout,Pose),
      modelling_vocabulary(MNs,MA),
      MNs::(current_ontology_identity(MNs,MA),
            place_model(Id,Pose,depicts(Ns,A,Entity),Model,Placed))),
    space_scene_parts(Rest,Space,Mode,Tail), append(Placed,Tail,Parts).

space_entity_pose(Space,Subject,_,body_pose(Body,Revision)) :-
    space_placement(Space,Subject,Assignment),
    findall(binding(B,R),physics_body_definition(Space,B,R,_,_,live(Subject,Assignment,_,_)),
            [binding(Body,Revision)]).
space_entity_pose(Space,Subject,Layout,Layout) :-
    \+ space_placement(Space,Subject,_), space_member(Space,Subject),
    Layout = transform(_,_,_,_,_,_).

space_entity_model([recipe(Ns,A,Recipe)],Context,Model) :-
    Ns::(current_ontology_identity(Ns,A),eidolon(Recipe,Context,Model)).
space_entity_model([],_,Parts) :- space_eidolon_status(<<"No matching eidolon">>,Parts).
space_entity_model([_,_|_],_,Parts) :- space_eidolon_status(<<"Choose an eidolon">>,Parts).
space_eidolon_status(Text,
    [part(<<"eidolon-status">>,group,transform(0,0,0,0,0,0),
          no_surface,label(Text,<<"above">>),depicts_nothing)]).

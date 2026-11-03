%% Compose with voxel_world.pl and space_view.pl. The application supplies
%% exact modelling/rendering vocabulary references and authored presentation.
%% A ground occurrence is an ordinary space member with a class-selected
%% Eidolon; it allocates no second physical body or scene owner.
isa(voxel_ground,thing).
instance_of(voxel_ground,terrain(W)) :- voxel_terrain_binding(W,_,_).
space_member(W,entity_ref(Ns,A,terrain(W))) :-
    voxel_terrain_binding(W,_,_),current_ontology_identity(Ns,A).

voxel_presentation(_,_,_,_,_) :- fail.
voxel_view_range(_,_) :- fail.

class_eidolon(voxel_ground,Mode,smooth,recipe(Ns,A,voxel_surface)) :-
    member(Mode,[playing,edition]),current_ontology_identity(Ns,A).
entity_scene(terrain(W),Mode,appearance(Id,smooth,terrain(W),transform(0,0,0,0,0,0),Choices)) :-
    findall(I,voxel_presentation(W,I,_,_,_),[Id]),
    entity_eidolons(terrain(W),Mode,smooth,Choices).
eidolon(voxel_surface,terrain(W),
    [part(<<"ground">>,Geometry,body_pose(Body,Revision),terrain_surfaces,unlabelled,Subject)]) :-
    voxel_surface_mark(W,mark(_,<<"terrain">>,Geometry,body_pose(Body,Revision),
                              terrain_surfaces,unlabelled,Subject)).

voxel_surface_mark(W,mark(Id,<<"terrain">>,terrain_geometry(<<"qvt1">>,Palette,View,Resources),
                         body_pose(Body,Revision),terrain_surfaces,unlabelled,depicts(Ns,A,terrain(W)))) :-
    findall(presentation(I,P,V,R),voxel_presentation(W,I,P,V,R),[presentation(Id,Palette,View,Resources)]),
    voxel_terrain_binding(W,Body,Revision),current_ontology_identity(Ns,A).

%% Appearance edits use the normal transaction and exact previous value. They
%% neither revise the terrain body nor change numerical/collision inputs.
voxel_set_view(W,Expected,View) :-
    term_variables([W,Expected,View],[]),
    transaction((current_principal(P),can_manage_voxel_world(W,P,view),
        findall(presentation(I,C,V,R),voxel_presentation(W,I,C,V,R),[presentation(Id,Palette,Before,Resources)]),
        (Before = Expected -> true ; fail_with_reason(voxel_view_conflict(W))),
        (Before = View -> true
        ; retract(voxel_presentation(W,Id,Palette,Before,Resources)),
          assertz(voxel_presentation(W,Id,Palette,View,Resources))),
        voxel_validate_presentation(W))).

voxel_validate_presentation(W) :-
    voxel_surface_mark(W,Mark),rendering_vocabulary(Ns,A),
    in_ontology(Ns,A,well_formed_mark(Mark)).

%% User-owned world library. Compose with the existing lobby, terrain, GUI
%% source and question behaviors. Rows are projections, never a second registry.
lobby_terrain_world(W) :-
    instance_of(voxel_world,W),voxel_world_owner(W,Human),lobby_owner(Human).
world_arrival(_,_) :- fail.
world_library_allowance(16).
world_spawn_allowance(-16000,160000,sampling_limits(4000,40000,120000,12000)).
instance_of(quod:agent:agent,world_responder).
lobby_hosted_actor(world_responder).
gui_pending_allowance(world_responder,8).
gui_completion_allowance(world_responder,30000).

world_library_workspace(View) :-
    current_principal(Human),lobby_owner(Human),gui_vocabulary(Ns,A),
    in_ontology(Ns,A,gui_view(space_library,View)).
world_library_status(Status) :-
    current_principal(Human),lobby_owner(Human),
    (agent_hosted(world_responder,_,_,_) -> Status = configured ; Status = setup_required).
world_library_preparation(State) :-
    world_library_status(Status),
    (Status = configured -> State = ready
    ; current_ontology_identity(Ns,A),
      quod:agent::agent_preparation_assignment(agent_instance_ref(Ns,A,world_responder),none,0),
      findall(N,physics_initial_host(personal_lobby,N),[Node]),
      prepare_agent_key_custody(agent_instance_ref(Ns,A,world_responder),none,0,Node,Key),
      State = prepared(Node,Key)).
world_library_initialize(Node,Key) :-
    term_variables([Node,Key],[]),
    transaction((current_principal(Human),lobby_owner(Human),
        findall(N,physics_initial_host(personal_lobby,N),[Node]),
        current_ontology_identity(Ns,A),
        quod:agent::agent_preparation_assignment(agent_instance_ref(Ns,A,world_responder),none,0),
        quod:agent::goal(agent_hosted(agent_instance_ref(Ns,A,world_responder),Node,1,Key)))).

world_library(Rows) :-
    current_principal(Human),lobby_owner(Human),current_ontology_identity(Ns,A),
    findall(world(entity_ref(Ns,A,W),Name),
        (lobby_terrain_world(W),one_attribute(W,display_name,Name),
         voxel_world_owner(W,Human),voxel_world_definition(W,_,Spec),Spec \= none),Rows),
    findall(L,world_library_allowance(L),[Limit]),length(Rows,Count),
    (Count =< Limit -> true ; fail_with_reason(world_library_allowance(Count,Limit))).
space_navigation(W,Modes) :-
    current_principal(Human),can_view_physics(W,Human),lobby_modes(Modes).

world_library_form(create,world_creation).
world_library_form(settings(W),voxel_view_settings(W)) :- lobby_terrain_world(W).
world_library_form(edit(W),voxel_excavation(W)) :- lobby_terrain_world(W).
world_library_open(Action,Reference) :-
    current_principal(Human),lobby_owner(Human),
    world_library_form(Action,Form),current_ontology_identity(Ns,A),
    <<"quod:gui">>::gui_open(form_ref(Ns,A,Form),Reference).

gui_question_policy(Form,Human,agent_instance_ref(Ns,A,world_responder)) :-
    lobby_owner(Human),current_ontology_identity(Ns,A),world_library_form(_,Form).
gui_responder_policy(world_responder,form_ref(Ns,A,Form),Human) :-
    current_ontology_identity(Ns,A),gui_question_policy(Form,Human,_).

instance_of(quod:gui:form,world_creation).
instance_of(quod:gui:text_box,world_creation_name).
instance_of(quod:gui:button,create_world).
instance_of(Class,voxel_setting(world_creation,Key)) :- voxel_parameter(Key,Class,_,_,_).
gui_children(world_creation,Children) :-
    voxel_generation_fields(world_creation,Fields,_),
    findall(Id,member(field(Id,_),Fields),Controls),
    append([world_creation_name|Controls],[create_world],Children).
attribute(world_creation,label,<<"Create world">>).
attribute(world_creation,help,<<"Choose a landscape to explore. Each world keeps its own settings and changes.">>).
attribute(world_creation_name,label,<<"World name (optional)">>).
attribute(world_creation_name,help,<<"Leave blank to generate a name. The name is saved when the world is created.">>).
attribute(world_creation_name,max_bytes,160).
attribute(create_world,label,<<"Create world">>).
gui_initial(world_creation,world_creation_name,<<"">>).
gui_initial(world_creation,voxel_setting(world_creation,Key),Value) :- voxel_parameter(Key,_,_,Value,_).
gui_form(world_creation,[field(world_creation_name,Name)|Fields],
         submit(create_world,world_creation_entered(Name,Recipe))) :-
    voxel_generation_fields(world_creation,Fields,Recipe).

%% Only the source's currently applying, accepted question can create a world.
%% Its occurrence supplies identity; display names can be duplicated safely.
%% This governed lifecycle stores its decided memberships as source clauses.
world_creation_entered(EnteredName,Recipe) :-
    transaction((current_principal(Actor),
        gui_question_policy(world_creation,Human,Actor),
        findall(Q,gui_application_active(Q),[Reference]),
        Reference = question_ref(Ns,A,_),current_ontology_identity(Ns,A),
        <<"quod:gui">>::gui_answer(Reference,form_ref(Ns,A,world_creation),Human,_,create_world,_),
        term_digest(world(Reference),Id),W = world(Id),
        world_library_count(Count),findall(L,world_library_allowance(L),[Limit]),
        (Count < Limit -> true ; fail_with_reason(world_library_allowance(Count,Limit))),
        \+ instance_of(voxel_world,W),world_creation_name(EnteredName,Reference,Name),
        voxel_generation_spec(Recipe,Spec),
        world_spawn_candidate(Spec,Pose),
        assertz(attribute(W,display_name,Name)),assertz(voxel_world_owner(W,Human)),
        assertz((instance_of(voxel_world,W) :- true)),
        assertz(physics_structure(W,1)),
        assertz(physics_next_body(W,0)),assertz(physics_run(W,0,none)),
        assertz(physics_definition(world_pilot(W),1,geometry(capsule(500,250),1))),
        assertz(world_arrival(W,Pose)),
        assertz((instance_of(sky_sphere,world_sky(W)) :- true)),
        assertz(attribute(world_sky(W),mark_id,<<"sky">>)),
        assertz(attribute(world_sky(W),panorama,belfast_sunset_puresky)),
        assertz(attribute(world_sky(W),diameter,80000)),
        assertz(attribute(world_sky(W),rotation,75)),
        assertz(attribute(world_sky(W),brightness,1000)),
        assertz(attribute(world_sky(W),tint,<<"#BCC9D8">>)),
        world_palette(Palette),world_render_resources(Resources),
        world_initial_view(Spec,View),
        assertz(voxel_presentation(W,<<"terrain">>,Palette,View,Resources)),
        voxel_create(W,0,Spec),voxel_validate_presentation(W))).
world_library_count(Count) :- findall(W,lobby_terrain_world(W),Worlds),length(Worlds,Count).

world_creation_name(Entered,Occurrence,Name) :-
    binary_codes(Entered,Codes),
    (Codes = [] ->
        findall(ontology_ref(N,A),names_vocabulary(N,A),[ontology_ref(Ns,Anchor)]),
        in_ontology(Ns,Anchor,
             draw(<<"landscape">>,<<"world">>,<<"neutral">>,Occurrence,Name))
    ; Name = Entered).

%% A bounded pure candidate search samples the nine lattice columns enclosing
%% the whole capsule. All cells above the highest solid corner are empty in
%% this quantized surface. Native admission still owns installed clearance.
world_spawn_candidate(Spec,vector(0,Y,0)) :-
    voxel_sampling_field(Spec,Field),Field = field_v1(_,S,_,_),
    findall(allowance(L,H,B),world_spawn_allowance(L,H,B),[allowance(Low,High,Limits)]),
    Bottom is Low // S,Top is High // S,N is Top-Bottom+1,Outside is -1,
    '$quod_voxel'(sample(Field,vector(Outside,Bottom,Outside),dimensions(3,N,3)),Limits,samples_v1(Bytes,_)),
    binary_codes(Bytes,Densities),world_highest_solid(Densities,N,0,Outside,Highest),
    (Highest >= 0,Highest+5 < N -> Y is (Bottom+Highest+1)*S+1000
    ; fail_with_reason(world_arrival_unavailable)).
world_highest_solid([],_,_,Highest,Highest).
world_highest_solid([D|Ds],N,I,Before,Highest) :-
    Row is (I // 3) mod N,
    (D >= 128,Row > Before -> Next = Row ; Next = Before),
    J is I+1,world_highest_solid(Ds,N,J,Next,Highest).

world_palette(Palette) :-
    lobby_vocabulary(Ns,A),in_ontology(Ns,A,world_palette(Palette)).
space_member(W,entity_ref(Ns,A,world_sky(W))) :-
    lobby_terrain_world(W),current_ontology_identity(Ns,A).

%% Visual demand uses the existing finite viewing window and physical resource
%% admission. No independent default presentation quota is imposed on it.
world_render_resources(resources(unlimited,unlimited,unlimited,unlimited,unlimited)).

%% Viewing policy scales with ground detail: the initial window spans the same
%% number of chunks, including its prefetch and retained border.
world_initial_view(Spec,view_distance(Distance,Prefetch,Retention)) :-
    voxel_sampling_field(Spec,field_v1(_,Spacing,_,_)),
    Distance is 16*Spacing,Prefetch is 4*Spacing,Retention is 8*Spacing.

lobby_physical_space(W,world_authority(W),world_pilot(W)) :- lobby_terrain_world(W).
instance_of(quod:agent:agent,world_authority(W)) :- lobby_terrain_world(W).
instance_of(quod:agent:agent,world_pilot(W)) :- lobby_terrain_world(W).
physics_space(W,enabled,world_authority(W)) :- lobby_terrain_world(W).
physics_initial_host(W,Node) :- lobby_terrain_world(W),physics_initial_host(personal_lobby,Node).
physics_initial_control(W,world_pilot(W),eye) :- lobby_terrain_world(W).
lobby_admission(W,world_pilot(W),controlled,Pose) :- world_arrival(W,Pose).
physics_allowances(W,limits(16,16,128,1000000,geometry(8192,8000000,2000000)),16667,Gravity,10000) :-
    lobby_terrain_world(W),Gravity is -9810.
voxel_allowances(W,voxel_limits(sampling_limits(1331,20000,100000,3993),
    surface_limits(512,10000,10000),4096,69120,134217728)) :- lobby_terrain_world(W).
voxel_initial_chunks(W,terrain_v1(_,smooth,field_v1(_,S,_,_)),[chunk_v1(0,C,0)]) :-
    world_arrival(W,vector(_,Y,_)),C is (Y-1000) // (8*S).
voxel_view_range(W,range(Step,Maximum,Step)) :-
    lobby_terrain_world(W),voxel_world_state(W,_,Spec),
    voxel_sampling_field(Spec,field_v1(_,Spacing,_,_)),
    Step is 8*Spacing//1000,Maximum is 3*Step.
voxel_brush_controls(W,range(Low,1000000,100),range(600,2000,100)) :-
    lobby_terrain_world(W), Low is -1000000.
can_create_voxel_world(W,Actor) :- lobby_terrain_world(W),gui_question_policy(world_creation,_,Actor).
can_manage_voxel_world(W,Actor,view) :- gui_question_policy(voxel_view_settings(W),_,Actor).
can_edit_voxel_world(W,Actor,_) :- gui_question_policy(voxel_excavation(W),_,Actor).

%% Personal lobby behaviour. Founding supplies lobby_owner/1, exact vocabulary
%% references and device class memberships; no user registry here.
%% Found with quod_agent_predicates for proof-bound identity checks.
can_invoke(_, Principal, _, _) :- lobby_owner(Principal).

ontology_source_mode(editable) :- current_principal(Principal), lobby_owner(Principal).

isa(lobby, physical_space).
instance_of(agent, physics_authority).
physics_space(personal_lobby, enabled, physics_authority).
physics_run(personal_lobby, 0, none).
physics_structure(personal_lobby, 1).
physics_next_body(personal_lobby, 0).
physics_initial_control(personal_lobby, pilot, eye).
physics_allowances(personal_lobby,
    limits(16,16,128,1000000,geometry(32,384,512)),16667,Gravity,10000) :-
    Gravity is -9810.

physics_admission(personal_lobby,entity_ref(Ns,A,floor),fixed,vector(0,0,0)) :-
    current_ontology_identity(Ns,A).
physics_admission(personal_lobby,entity_ref(Ns,A,personal_roof),fixed,vector(0,0,0)) :-
    current_ontology_identity(Ns,A).
physics_admission(personal_lobby,entity_ref(Ns,A,console),fixed,vector(0,0,3850)) :-
    current_ontology_identity(Ns,A).
physics_admission(personal_lobby,entity_ref(Ns,A,pilot),controlled,vector(0,1000,2800)) :-
    current_ontology_identity(Ns,A).
physics_definition_allowance(Entity,1000000) :- physics_definition(Entity,_,_).

%% The same admission, control and hosting policy serves every owned space.
%% Composition adds world membership, never another initialization path.
lobby_physical_space(personal_lobby,physics_authority,pilot).
lobby_hosted_actor(Authority) :- lobby_physical_space(_,Authority,_).

physics_agent(W,Pilot,1,Body,
    motion(grounded(900),2500,1600,500,query_limits(2,0,8,128),[jump(3000)])) :-
    lobby_physical_space(W,Authority,Pilot),
    physical_assignment(Pilot,Assignment,entity_ref(Ns,A,W)),
    physics_definition_delegate(Pilot,world_ref(Ns,A,W),
                                agent_instance_ref(Ns,A,Authority),Assignment),
    physics_body_definition(W,Body,_,controlled,_,
                            live(entity_ref(Ns,A,Pilot),Assignment,_,_)).
physics_viewpoint(W,Pilot,eye,Body,
    pose(vector(0,700,0),rotation(0,0,0)),tracking(view_only,500)) :-
    physics_agent(W,Pilot,_,Body,_).

can_initialize_physics(W,Owner) :- lobby_owner(Owner),lobby_physical_space(W,_,_).
can_view_physics(W,Owner) :- lobby_owner(Owner),lobby_physical_space(W,_,_).
can_read_physics_body(W,Owner,_) :- can_view_physics(W,Owner).
can_control_physics_agent(W,Owner,Pilot) :- lobby_owner(Owner),lobby_physical_space(W,_,Pilot).
can_edit_physics(W,Owner) :- lobby_owner(Owner),lobby_physical_space(W,_,_).
can_cancel_physics_activation(W,Owner) :- can_edit_physics(W,Owner).
can_edit_physics_definition(Entity,Owner) :- lobby_owner(Owner), physics_definition(Entity,_,_).
can_refresh_physics_definition(W,Owner,_) :- can_edit_physics(W,Owner).

can_enter_space(Entity,Owner,entity_ref(Ns,A,W),physical) :-
    lobby_owner(Owner),lobby_physical_space(W,_,_),current_ontology_identity(Ns,A),
    physics_admission(W,entity_ref(Ns,A,Entity),_,_).
can_leave_space(Entity,Owner,Destination,physical) :-
    can_enter_space(Entity,Owner,Destination,physical).
can_admit_space_member(W,Owner,Subject,physical) :-
    lobby_owner(Owner),lobby_physical_space(W,_,_),physics_admission(W,Subject,_,_).
can_remove_space_member(W,Owner,_,physical) :- can_edit_physics(W,Owner).
can_delegate_physics_definition(Entity,Owner,World,Authority) :-
    lobby_owner(Owner),physics_definition(Entity,_,_),
    lobby_physical_space(W,_,_),physics_world_authority(W,World,Authority).
space_physical_change(Space,Subject,Change) :- physics_space_change(Space,Subject,Change).

can_prepare_agent_key(Owner,Actor,none,0,Node) :-
    lobby_owner(Owner),lobby_hosted_actor(Actor),physics_initial_host(personal_lobby,Node).
can_assign_agent_host(Owner,Actor,none,0,Node,_) :-
    lobby_owner(Owner),lobby_hosted_actor(Actor),physics_initial_host(personal_lobby,Node).
can_invoke((agent_hosted(Authority,Node,Epoch,Key),sign_agent_request(_,_)),Node,_,_) :-
    lobby_physical_space(_,Authority,_),physics_initial_host(personal_lobby,Node),
    agent_hosted(Authority,Node,Epoch,Key).
can_request_agent_signature(Node,Authority,
    agent_goal_v1(_,agent_instance_ref(Ns,A,Authority),_,Key,_,_,Mode,3,_)) :-
    member(Mode,[read,execute]),lobby_physical_space(_,Authority,_),
    current_ontology_identity(Ns,A),physics_initial_host(personal_lobby,Node),
    agent_hosted(Authority,Node,_,Key).
can_invoke(physics_store_request(W,_,_,_,_,_),agent_instance_ref(Ns,A,Authority),_,Ns) :-
    lobby_physical_space(W,Authority,_),current_ontology_identity(Ns,A).
can_invoke(physics_store_retired(W,_,_,_,_,_,_,_),agent_instance_ref(Ns,A,Authority),_,Ns) :-
    lobby_physical_space(W,Authority,_),current_ontology_identity(Ns,A).
can_invoke(physics_activate(W,_,_),agent_instance_ref(Ns,A,Authority),_,Ns) :-
    lobby_physical_space(W,Authority,_),current_ontology_identity(Ns,A).

lobby_space(Space, Modes) :-
    findall(S, instance_of(lobby, S), [Space]), findall(M, lobby_modes(M), [Modes]).

lobby_modes(Modes) :-
    lobby_vocabulary(Namespace, Anchor),
    Namespace::(current_ontology_identity(Namespace, Anchor), lobby_modes(Modes)).

%% Every visual parameter is durable lobby state. Exact-one reads make an
%% incomplete or ambiguous edit fail closed instead of inventing a default.
lobby_sky(Entity,sky(Entity, Panorama, Diameter, Rotation, Brightness, Tint)) :-
    instance_of(sky_sphere,Entity),
    one_attribute(Entity, panorama, Panorama),
    one_attribute(Entity, diameter, Diameter),
    one_attribute(Entity, rotation, Rotation),
    one_attribute(Entity, brightness, Brightness),
    one_attribute(Entity, tint, Tint).

one_attribute(Entity, Name, Value) :-
    findall(V, attribute(Entity, Name, V), [Value]).

%% Appearance metadata describes an occurrence; a solid's pose comes only
%% from its admitted binding in space_view.pl. The played capsule is hidden.
space_member(personal_lobby,entity_ref(Ns,A,personal_sky)) :- current_ontology_identity(Ns,A).
entity_scene(Pilot,_,hidden) :- lobby_physical_space(_,_,Pilot).
entity_scene(Entity,Mode,appearance(Id,Style,Context,Layout,Eidolons)) :-
    \+ lobby_physical_space(_,_,Entity), one_attribute(Entity,mark_id,Id),
    (instance_of(sky_sphere,Entity) ->
        Style = panoramic, lobby_sky(Entity,Sky),
        current_ontology_identity(Ns,A), Context = environment(Sky,Ns,A),
        Layout = transform(0,0,0,0,0,0)
    ; Style = solid, Context = device(Entity), Layout = physical),
    member(Mode,[playing,edition]), entity_eidolons(Entity,Mode,Style,Eidolons).

class_eidolon(Class,Mode,Style,Recipe) :-
    lobby_vocabulary(Ns,A), vocabulary_class(Class,Ns,Local),
    Ns::(current_ontology_identity(Ns,A),class_eidolons([Local],Mode,Style,Choices)),
    member(eidolon(Mode,Style,Recipe),Choices).
class_eidolon(sky_sphere,Mode,Style,Recipe) :-
    environment_eidolons(Ns,A),
    Ns::(current_ontology_identity(Ns,A),class_eidolon(sky_sphere,Mode,Style,Recipe)).

no_follow(vocabulary_class/3).
vocabulary_class(Reference, Namespace, Class) :-
    nonvar(Reference), Reference = _:_, !,
    '$quod_owner_name'(Reference, Owner, Class), ontology_name(Owner, Namespace).
vocabulary_class(Class, _, Class).

lobby_menu(Device, Entries) :-
    entity_classes(Device, Raw), lobby_vocabulary(Vocabulary,_),
    findall(Class,(member(C,Raw),vocabulary_class(C,Vocabulary,Class)),Classes),
    lobby_vocabulary(Namespace, Anchor),
    Namespace::(current_ontology_identity(Namespace, Anchor),
                device_menu(Classes, Entries)).

lobby_workspace(Device, ViewId, View) :-
    lobby_menu(Device, Entries),
    member(menu_entry(_, _, open_view(ViewId)), Entries),
    gui_vocabulary(Namespace, Anchor),
    Namespace::(current_ontology_identity(Namespace, Anchor),
                gui_view(ViewId, View)).

%% Optional physical worlds use explicitly assigned, independently hosted actors.
%% Space policy supplies every allowance and hosting/signing grant.
%% Distances are millimetres, time microseconds, density kg/m3.

agent_hosting_suspended(I) :- physics_space(W, _, I), \+ physics_enabled(W, I).

%% Classification, enablement and configuration have one shared eligibility
%% rule. Class membership by itself allocates nothing and grants no access.
physics_enabled(W, I) :-
    physics_space(W, enabled, I),
    once((instance_of(Class,W),isa(Class,quod:space:physical_space))),
    unique_solution(physics_space(W,Mode,Actor)), Mode = enabled, Actor = I,
    physics_required_allowances(W, _, _, _, _),
    \+ physics_definition_delegate(W,_,_,_).

%% First assignment uses the same governed custody and admission actions as
%% later authoring. The caller retains the ordinary signed execute request;
%% preparation is a stable read after the world's exact identity exists.
can_initialize_physics(_, _) :- fail.
physics_initial_host(_, _) :- fail.
physics_initial_control(_, _, _) :- fail.

physics_preparation(W, State) :-
    current_principal(P), can_initialize_physics(W, P),
    unique_solution(physics_space(W,Mode,Authority)),
    (Mode = disabled -> State = disabled
    ; physics_enabled(W,Authority),
      (agent_hosted(Authority,_,_,_) ->
          physics_client_control(W,_), State = ready
      ; current_ontology_identity(Ns,Anchor),
        quod:agent::agent_preparation_assignment(agent_instance_ref(Ns,Anchor,Authority),none,0),
        unique_solution(physics_initial_host(W,Node)),
        prepare_agent_key_custody(agent_instance_ref(Ns,Anchor,Authority),none,0,Node,Key),
        State = prepared(Node,Key))).

physics_initialize(W, Node, Key) :-
    term_variables([W,Node,Key], []),
    transaction((current_principal(P), can_initialize_physics(W,P),
        physics_enabled(W,Authority),
        unique_solution(physics_initial_host(W,SelectedNode)), SelectedNode = Node,
        current_ontology_identity(Ns,Anchor),
        quod:agent::agent_preparation_assignment(agent_instance_ref(Ns,Anchor,Authority),none,0),
        quod:agent::goal(agent_hosted(agent_instance_ref(Ns,Anchor,Authority),Node,1,Key)),
        findall(E,physics_admission(W,entity_ref(Ns,Anchor,E),_,_),Entities),
        sort(Entities,Unique), length(Entities,Count), length(Unique,Count), Count > 0,
        physics_place_all(Unique,entity_ref(Ns,Anchor,W)),
        unique_solution(physics_initial_control(W,Agent,Viewpoint)),
        physics_control_agent(W,0,none,controlled(Agent,Viewpoint)),
        physics_client_control(W,_))).

physics_place_all([], _).
physics_place_all([Entity|Rest], Destination) :-
    current_ontology_identity(Ns,Anchor),
    quod:space::space_assignment(entity_ref(Ns,Anchor,Entity),0,none),
    quod:space::goal(inside(Destination,entity_ref(Ns,Anchor,Entity),transform(0,0,0,0,0,0))),
    physics_place_all(Rest,Destination).

%% One authored body description, either owned geometry or an exact live source.
%% Body identity, kind and placement belong to the admitting world; source shape
%% and density never become a second mutable fact at that destination.
physics_body_definition(_, _, _, _, _, _) :- fail.
physics_resolve_definition(_, owned(Shape, Density), Shape, Density).
physics_resolve_definition(W, live(entity_ref(Ns, Anchor, Entity), Assignment, Revision, Digest),
                           Shape, Density) :-
    physics_world_authority(W, World, Authority),
    in_ontology(Ns,Anchor,(
         physics_definition_projection(World, Authority, Entity, Revision, geometry(Shape,Density)),
         physics_definition_delegate(Entity, World, Authority, Assignment))),
    term_digest(geometry(Shape,Density), Digest).

physics_world_authority(W, world_ref(Ns, Anchor, W), agent_instance_ref(Ns, Anchor, I)) :-
    current_ontology_identity(Ns, Anchor),
    unique_solution(physics_space(W,_,Actor)), Actor = I.

physics_definition(_, _, _) :- fail.
%% A contents frame exports its authored transform, not another collider or
%% mutable geometry copy. The same source delegation owns both export kinds.
physics_definition(Space,Revision,frame(Transform,Recipe)) :-
    once((instance_of(Class,Space),isa(Class,quod:space:space))), attribute(Space,exterior,contents),
    unique_solution(attribute(Space,transform,SelectedTransform)),
    SelectedTransform = Transform, quod:space::space_transform(Transform),
    quod:space::current_ontology_identity(Ns,A),
    entity_eidolons(Space,playing,contents,[eidolon(playing,contents,Recipe)]),
    entity_eidolons(Space,edition,contents,[eidolon(edition,contents,Recipe)]),
    Recipe = recipe(Ns,A,space_contents),
    term_digest(frame(Transform,Recipe),Revision).
physics_definition_delegate(_, _, _, _) :- fail.
can_edit_physics_definition(_, _) :- fail.
can_refresh_physics_definition(_, _, _) :- fail.
can_delegate_physics_definition(_, _, _, _) :- fail.
physics_definition_allowance(_, _) :- fail.
physics_admission(_, _, _, _) :- fail.

%% This pure, source-owned export is also evaluated over retained verified state.
%% Installation delegation is not user invocation or disclosure permission.
physics_definition_projection(World, Authority, Entity, Revision, Definition) :-
    unique_solution(space_assignment_state(Entity,Assignment,Destination)), Destination \== none,
    unique_solution(physics_definition_delegate(Entity,SelectedWorld,SelectedAuthority,SelectedAssignment)),
    SelectedWorld = World, SelectedAuthority = Authority, SelectedAssignment = Assignment,
    physics_exported_definition(Entity,Revision,Definition).
physics_exported_definition(Entity,Revision,Definition) :-
    unique_solution(physics_definition(Entity,SelectedRevision,SelectedDefinition)),
    SelectedRevision = Revision, SelectedDefinition = Definition,
    physics_export(Definition).
physics_export(geometry(_,_)).
physics_export(frame(_,_)).

physics_delegate_definition(Entity, World, Authority, Assignment, Revision, Definition) :-
    term_variables([Entity,World,Authority,Assignment], []),
    transaction((current_principal(P),
        can_delegate_physics_definition(Entity,P,World,Authority),
        current_ontology_identity(Store,StoreAnchor),
        quod:space::space_assignment(entity_ref(Store,StoreAnchor,Entity),Assignment,Destination),
        Destination \== none,
        \+ physics_definition_delegate(Entity,_,_,_),
        physics_exported_definition(Entity,Revision,Definition),
        (Definition = frame(_,_) -> physics_independent_frame(Entity); true),
        assertz(physics_definition_delegate(Entity,World,Authority,Assignment)))).

physics_release_definition(Entity, World, Assignment) :-
    term_variables([Entity,World,Assignment], []),
    transaction((
        unique_solution(physics_definition_delegate(Entity,World,Authority,Assignment)),
        current_ontology_identity(Here,History),
        (Next is Assignment + 1,
         quod:space::space_assignment(entity_ref(Here,History,Entity),Next,none) -> true
        ; quod:space::space_assignment(entity_ref(Here,History,Entity),Assignment,Destination),
          Destination \== none, World = world_ref(Ns,Anchor,W),
          in_ontology(Ns,Anchor,
               \+ physics_source_binding(W,entity_ref(Here,History,Entity),Assignment))),
        retract(physics_definition_delegate(Entity,World,Authority,Assignment)))).

%% Simulated spaces compose this hook explicitly; unsimulated physical spaces
%% supply their own no-effect space_physical_change/3 and allocate no native body.
physics_space_change(W, Subject, admitted) :-
    current_ontology_identity(Here,History),
    physics_domain(W,world_ref(Ns,Anchor,Root),_,Path),
    in_ontology(Ns,Anchor,
         physics_admit_component(Root,entity_ref(Here,History,W),Path,Subject)).
physics_space_change(W, Subject, withdrawn) :-
    current_ontology_identity(Here,History),
    %% A retained root binding must still retire after classification or
    %% enablement changes. Admission continues to require physics_enabled/2.
    (physics_source_binding(W,Subject,_) ->
        physics_world_authority(W,world_ref(Ns,Anchor,Root),_), Path = []
    ; physics_domain(W,world_ref(Ns,Anchor,Root),_,Path)),
    in_ontology(Ns,Anchor,
         physics_release_component(Root,entity_ref(Here,History,W),Path,Subject)).
physics_space_change(W,Subject,represented) :-
    current_ontology_identity(Here,History),
    physics_domain(W,world_ref(Ns,A,Root),_,Path),
    in_ontology(Ns,A,
         physics_represent_component(Root,entity_ref(Here,History,W),Path,Subject)).

%% Ordinary containment remains with its original owner. Only this explicit
%% delegated frame admission selects the one simulation domain and edge path.
physics_frame_member(_,_,_,_,_) :- fail.
physics_frame_admission(_,_,_) :- fail.
physics_component_admission(_,_,_,_,_) :- fail.
physics_frame_allowance(_,_) :- fail.
physics_frame_capacity(W,Additional) :-
    (unique_solution(physics_frame_allowance(W,Limit)),integer(Limit),Limit >= 0 -> true
    ; fail_with_reason(frame_allowance_missing(W))),
    findall(S,physics_frame_member(W,S,_,_,_),Frames),length(Frames,Count),
    (Count + Additional =< Limit -> true; fail_with_reason(frame_allowance(Limit))).
physics_domain(W,World,Authority,[]) :-
    physics_enabled(W,_), physics_world_authority(W,World,Authority).
physics_domain(Space,World,Authority,Path) :-
    current_ontology_identity(Ns,A), Subject = entity_ref(Ns,A,Space),
    unique_solution(physics_definition_delegate(Space,SelectedWorld,SelectedAuthority,Assignment)),
    SelectedWorld = World, SelectedAuthority = Authority,
    physics_definition_projection(World,Authority,Space,Revision,frame(_,_)),
    World = world_ref(RootNs,RootAnchor,W),
    in_ontology(RootNs,RootAnchor,
             physics_frame_member(W,Subject,Assignment,Revision,Path)).

physics_independent_frame(Space) :-
    (\+ physics_space(Space,enabled,_), \+ physics_body_definition(Space,_,_,_,_,_),
     \+ (physics_run(Space,G,_),G > 0), \+ physics_request(Space,_),
     \+ physics_control(Space,_,_,_) -> true
    ; fail_with_reason(incompatible_physics_run(Space))),
    (\+ physics_space(Space,_,_) -> true
    ; fail_with_reason(incompatible_physics_configuration(Space))).

physics_component_path(W,Frame,[]) :-
    current_ontology_identity(Ns,A), Frame = entity_ref(Ns,A,W).
physics_component_path(W,Frame,Path) :-
    physics_frame_member(W,Frame,_,_,Path).
physics_source_binding(W,Subject,Assignment) :-
    physics_body_definition(W,_,_,_,_,live(Subject,Assignment,_,_)).
physics_source_binding(W,Subject,Assignment) :-
    physics_frame_member(W,Subject,Assignment,_,_).
physics_scene_binding(W,Path,Subject,Assignment,Binding) :-
    findall(body_pose(B,R),(physics_body_definition(W,B,R,_,Pose,live(Subject,Assignment,_,_)),
                           physics_pose_path(Pose,Path)),Bodies),
    findall(source_layout,(physics_frame_member(W,Subject,Assignment,Revision,Full),
                            append(Path,[frame(Subject,Assignment,Revision)],Full)),Frames),
    append(Bodies,Frames,Bindings),
    (Bindings = [Binding] -> true
    ; Bindings = [],physics_component_path(W,Frame,Path),
      physics_frame_admission(W,Frame,Subject),physics_inert_frame(Subject),Binding = source_layout).
physics_pose_path(framed(Path,_),Path).
physics_pose_path(Pose,[]) :- Pose \= framed(_,_).

%% A visual consumer proves ordinary source disclosure, independently of the
%% authority's installation delegation. The signed view retains every edge.
physics_view_frames(W,Path,Frames) :- physics_view_frames(Path,W,[],Frames).
physics_view_frames([],_,_,[]).
physics_view_frames([Edge|Rest],W,Before,[Transform|Frames]) :-
    Edge = frame(Subject,Assignment,Revision), Subject = entity_ref(Ns,A,Space),
    append(Before,[Edge],Path), physics_frame_member(W,Subject,Assignment,Revision,Path),
    in_ontology(Ns,A,
         client_entity_scene(Space,playing,appearance(_,contents,_,Transform,Eidolons))),
    unique_solution(member(eidolon(playing,contents,Recipe),Eidolons)),
    term_digest(frame(Transform,Recipe),Revision),
    physics_view_frames(Rest,W,Path,Frames).

physics_admit_component(W,Frame,Path,Subject) :-
    transaction((
        physics_enabled(W,_), physics_world_authority(W,World,Authority),
        physics_component_path(W,Frame,Path), Subject = entity_ref(Ns,Anchor,Entity),
        current_ontology_identity(Here,History),
        (Ns == Here, Anchor == History -> true ; physics_subscription(Ns,Anchor)),
        findall(frame,physics_frame_admission(W,Frame,Subject),Frames),
        findall(body(K,P),physics_component_body(W,Frame,Subject,K,P),Bodies),
        append(Frames,Bodies,Selections),
        (Selections = [Selection] -> true
        ; Selections = [] -> fail_with_reason(physics_admission_unavailable(Subject))
        ; fail_with_reason(ambiguous_physics_admission(Subject))),
        \+ physics_source_binding(W,Subject,_),
        quod:space::space_assignment(Subject,Assignment,Frame),
        (Selection = frame, physics_inert_frame(Subject) -> true
        ; physics_component_definition(Selection,Definition),
          in_ontology(Ns,Anchor,
               physics_delegate_definition(Entity,World,Authority,Assignment,Revision,Definition)),
          physics_install_component(Selection,W,Subject,Assignment,Revision,Definition,Path)))).
physics_component_definition(frame,frame(_,_)).
physics_component_definition(body(_,_),geometry(_,_)).

physics_inert_frame(entity_ref(Ns,A,Space)) :-
    quod:space::space_instance(entity_ref(Ns,A,Space),space),
    in_ontology(Ns,A,attribute(Space,exterior,Style)), member(Style,[solid,wireframe]).

physics_component_body(W,Frame,Subject,Kind,Pose) :-
    current_ontology_identity(Ns,A), Frame = entity_ref(Ns,A,W),
    physics_admission(W,Subject,Kind,Pose).
physics_component_body(W,Frame,Subject,Kind,Pose) :-
    Subject = entity_ref(Ns,A,Entity),
    in_ontology(Ns,A,
         unique_solution(attribute(Entity,transform,SelectedPose))),
    SelectedPose = Pose, quod:space::space_transform(Pose),
    physics_component_admission(W,Frame,Subject,Kind,Pose).

physics_install_component(body(Kind,Local),W,Subject,Assignment,Revision,geometry(Shape,Density),Path) :-
    (Path = [] -> Pose = Local; Pose = framed(Path,Local)),
    term_digest(geometry(Shape,Density),Digest),
    physics_required_allowances(W,limits(_,_,_,Coordinate,_),_,_,_),
    physics_body_capacity(W,1), physics_allocate_body(W,Body),
    physics_checked_body(Body,Kind,Pose,Shape,Density,Coordinate),
    physics_advance_structure(W,Next),
    assertz(physics_body_definition(W,Body,Next,Kind,Pose,live(Subject,Assignment,Revision,Digest))).
physics_install_component(frame,W,Subject,Assignment,Revision,frame(_,_),Before) :-
    physics_frame_capacity(W,1),
    append(Before,[frame(Subject,Assignment,Revision)],Path),
    assertz(physics_frame_member(W,Subject,Assignment,Revision,Path)),
    Subject = entity_ref(Ns,Anchor,Space),
    in_ontology(Ns,Anchor,physics_attach_contents(Space)).
physics_attach_contents(Space) :-
    findall(S,space_placement(Space,S,_),Subjects),
    physics_attach_contents(Subjects,Space).
physics_attach_contents([],_).
physics_attach_contents([Subject|Rest],Space) :-
    physics_space_change(Space,Subject,admitted), physics_attach_contents(Rest,Space).

physics_release_component(W,Frame,Path,Subject) :-
    transaction((physics_component_path(W,Frame,Path),
        (physics_frame_member(W,Subject,_,_,Branch) -> physics_remove_frame(W,Branch)
        ; physics_source_binding(W,Subject,_) -> physics_remove_live(W,Subject)
        ; physics_frame_admission(W,Frame,Subject), physics_inert_frame(Subject)))).

physics_represent_component(W,Frame,Path,Subject) :-
    transaction((physics_component_path(W,Frame,Path),current_principal(P),
        can_refresh_physics_definition(W,P,Subject),
        (physics_frame_member(W,Subject,Assignment,Before,Branch) ->
            (physics_inert_frame(Subject) -> physics_remove_frame(W,Branch)
            ; physics_world_authority(W,World,Authority), Subject = entity_ref(Ns,A,Entity),
              in_ontology(Ns,A,
                   physics_definition_projection(World,Authority,Entity,Next,Definition)),
              physics_refresh_source(W,Subject,Assignment,Before,Next,Definition))
        ; physics_admit_component(W,Frame,Path,Subject)))).
physics_remove_live(W,Subject) :-
    current_ontology_identity(Here,History), World = world_ref(Here,History,W),
    findall(body(B,R,K,P,D),
        (physics_body_definition(W,B,R,K,P,D),D = live(Subject,_,_,_)),
        [body(Body,Revision,Kind,Pose,Definition)]),
    Definition = live(Subject,Assignment,_,_), Subject = entity_ref(Ns,Anchor,Entity),
    physics_remove_body(W,Body,Revision,Kind,Pose,Definition),
    in_ontology(Ns,Anchor,physics_release_definition(Entity,World,Assignment)).
physics_remove_frame(W,Path) :-
    findall(Subject,(physics_body_definition(W,_,_,_,framed(BodyPath,_),live(Subject,_,_,_)),
                     append(Path,_,BodyPath)),Bodies),
    physics_remove_lives(Bodies,W),
    findall(frame(S,R,D,P),(physics_frame_member(W,S,R,D,P),append(Path,_,P)),Frames),
    physics_remove_frames(Frames,W).
physics_remove_lives([],_).
physics_remove_lives([Subject|Rest],W) :- physics_remove_live(W,Subject),physics_remove_lives(Rest,W).
physics_remove_frames([],_).
physics_remove_frames([frame(Subject,Assignment,Revision,Path)|Rest],W) :-
    retract(physics_frame_member(W,Subject,Assignment,Revision,Path)),
    current_ontology_identity(Here,History), Subject = entity_ref(Ns,A,Entity),
    in_ontology(Ns,A,
         physics_release_definition(Entity,world_ref(Here,History,W),Assignment)),
    physics_remove_frames(Rest,W).

%% Shared retirement consequence. Admission and source delegation belong to
%% the calling domain; body constraints, custody and cleanup belong here.
physics_remove_body(W,Body,Revision,Kind,Pose,Definition) :-
    physics_body_definition(W,Body,Revision,Kind,Pose,Definition),
    physics_removable_body(W,Body),
    physics_advance_structure(W,_),
    retract(physics_body_definition(W,Body,Revision,Kind,Pose,Definition)),
    physics_remove_rest_checkpoint(W,Body), physics_remove_rest_state(W,Body),
    physics_remove_rest_request(W,Body).

%% The subscription owner retains authored ground facts, not derived answers.
physics_subscription(Ns,Anchor) :-
    '$quod_predicate_source'(subscribes/2,Source),
    '$quod_program_source'(Clauses,Source),
    member((subscribes(S,A) :- true),Clauses), S == Ns, A == Anchor.

physics_next_body(_, _) :- fail.
physics_allocate_body(W, Body) :-
    physics_body_allocator(W,Body),
    physics_reserve_body_ids(W,[Body]).
physics_reserve_body_ids(W, Bodies) :-
    physics_body_allocator(W,Next),
    sort(Bodies,Sorted), length(Bodies,Count), length(Sorted,Count),
    physics_body_id_end(Sorted,Next,End),
    retract(physics_next_body(W,Next)), assertz(physics_next_body(W,End)).
physics_body_allocator(W,Next) :-
    (unique_solution(physics_next_body(W,Selected)), Selected = Next, integer(Next), Next >= 0 -> true
    ; fail_with_reason(body_allocator_missing(W))).
physics_body_id_end([], Next, Next).
physics_body_id_end([B|Bodies], Next, End) :-
    (integer(B), B >= Next, B < 18446744073709551616 -> true
    ; fail_with_reason(body_identity_unavailable(B))),
    Following is B + 1, physics_body_id_end(Bodies,Following,End).
physics_body_capacity(W,Additional) :-
    physics_required_allowances(W,limits(Max,_,_,_,_),_,_,_),
    findall(B,physics_body_definition(W,B,_,_,_,_),Bodies), length(Bodies,Count),
    (Count + Additional =< Max -> true ; fail_with_reason(body_allowance(Max))).
physics_advance_structure(W,Next) :-
    unique_solution(physics_structure(W,Before)), Next is Before + 1,
    retract(physics_structure(W,Before)), assertz(physics_structure(W,Next)).

%% Replacing an authority changes every live source delegation in the same
%% signed transition. Host/key assignment remains the existing agent lifecycle.
physics_assign_authority(W, Before, After) :-
    term_variables([W,Before,After], []), Before \== After,
    transaction((current_principal(P), can_edit_physics(W,P),
        unique_solution(physics_space(W,Mode,Actor)), Actor = Before,
        agent_hosted(After,_,_,_), physics_run(W,Generation,_),
        physics_custody(W,Custody), physics_previous_complete(Custody,Generation),
        current_ontology_identity(Ns,Anchor),
        findall(live(S,A,R,D),physics_body_definition(W,_,_,_,_,live(S,A,R,D)),Bodies),
        findall(live(S,A,R,frame),physics_frame_member(W,S,A,R,_),Frames), append(Bodies,Frames,References),
        retract(physics_space(W,Mode,Before)), assertz(physics_space(W,Mode,After)),
        physics_redelegate_sources(References,world_ref(Ns,Anchor,W),
            agent_instance_ref(Ns,Anchor,Before),agent_instance_ref(Ns,Anchor,After)))).

physics_redelegate_sources([],_,_,_).
physics_redelegate_sources([live(entity_ref(Ns,Anchor,Entity),Assignment,_,_)|Rest],World,Before,After) :-
    in_ontology(Ns,Anchor,
         physics_redelegate_definition(Entity,World,Before,After,Assignment)),
    physics_redelegate_sources(Rest,World,Before,After).
physics_redelegate_definition(Entity,World,Before,After,Assignment) :-
    term_variables([Entity,World,Before,After,Assignment], []),
    transaction((current_principal(P), can_delegate_physics_definition(Entity,P,World,After),
        World = world_ref(Ns,Anchor,Space),
        current_ontology_identity(Store,StoreAnchor),
        quod:space::space_assignment(entity_ref(Store,StoreAnchor,Entity),Assignment,Destination),
        Destination \== none,
        in_ontology(Ns,Anchor, physics_world_authority(Space,World,After)),
        unique_solution(physics_definition_delegate(Entity,SelectedWorld,Actor,Revision)),
        SelectedWorld = World, Actor = Before, Revision = Assignment,
        retract(physics_definition_delegate(Entity,World,Before,Assignment)),
        assertz(physics_definition_delegate(Entity,World,After,Assignment)))).

physics_edit_definition(Entity, Expected, Definition) :-
    term_variables([Entity,Expected,Definition], []),
    transaction((current_principal(P), can_edit_physics_definition(Entity,P),
        unique_solution(physics_definition(Entity,Revision,Before)), Revision = Expected,
        Definition = geometry(Shape,Density),
        unique_solution(physics_definition_allowance(Entity,Coordinate)),
        physics_checked_body(0,fixed,vector(0,0,0),Shape,Density,Coordinate),
        Next is Expected + 1,
        retract(physics_definition(Entity,Expected,Before)),
        assertz(physics_definition(Entity,Next,Definition)),
        physics_definition_consequence(Entity,Expected,Next,Definition))).

physics_definition_consequence(Entity,Before,Next,Definition) :-
    findall(grant(W,A,R),physics_definition_delegate(Entity,W,A,R),Grants),
    (Grants = [] -> true
    ; Grants = [grant(world_ref(Ns,Anchor,Space),_,Assignment)],
      current_ontology_identity(Here,History),
      quod:space::space_assignment(entity_ref(Here,History,Entity),Assignment,Destination),
      Destination \== none,
      in_ontology(Ns,Anchor,
           physics_refresh_definition(Space,entity_ref(Here,History,Entity),Assignment,Before,Next,Definition))).

physics_refresh_definition(W,Subject,Assignment,Before,Next,Definition) :-
    term_variables([W,Subject,Assignment,Before,Next,Definition], []),
    transaction((current_principal(P), can_refresh_physics_definition(W,P,Subject),
        physics_source_binding(W,Subject,Assignment),
        physics_world_authority(W,World,Authority), Subject = entity_ref(Ns,Anchor,Entity),
        in_ontology(Ns,Anchor,
             physics_definition_projection(World,Authority,Entity,Next,Definition)),
        physics_refresh_source(W,Subject,Assignment,Before,Next,Definition))).

physics_refresh_source(W,Subject,Assignment,Before,Next,Definition) :-
        Definition = geometry(Shape,Density), Next is Before + 1,
        findall(body(B,R,K,Position,D),
            (physics_body_definition(W,B,R,K,Position,D),D = live(Subject,Assignment,Before,_)),
            [body(Body,Revision,Kind,Pose,Old)]),
        term_digest(geometry(Shape,Density),Digest),
        physics_replace_body(W,Body,Revision,Kind,Pose,Old,Pose,live(Subject,Assignment,Next,Digest),Definition).
physics_refresh_source(W,Subject,Assignment,Before,Next,frame(_,_)) :-
    physics_frame_member(W,Subject,Assignment,Before,Branch),
    findall(body(B,R,K,P,D),(physics_body_definition(W,B,R,K,P,D),P = framed(Path,_),append(Branch,_,Path)),Bodies),
    physics_reframe_bodies(Bodies,W,frame(Subject,Assignment,Before),frame(Subject,Assignment,Next)),
    findall(frame(S,A,R,P),(physics_frame_member(W,S,A,R,P),append(Branch,_,P)),Frames),
    physics_reframe_members(Frames,W,frame(Subject,Assignment,Before),frame(Subject,Assignment,Next)).
physics_reframe_bodies([],_,_,_).
physics_reframe_bodies([body(B,R,K,framed(Path,Local),D)|Rest],W,Before,After) :-
    physics_removable_body(W,B), physics_advance_structure(W,Next),
    physics_replace_edge(Path,Before,After,Changed),
    retract(physics_body_definition(W,B,R,K,framed(Path,Local),D)),
    assertz(physics_body_definition(W,B,Next,K,framed(Changed,Local),D)),
    physics_remove_rest_checkpoint(W,B), physics_cancel_rest_edit(W,B),
    physics_reframe_bodies(Rest,W,Before,After).
physics_reframe_members([],_,_,_).
physics_reframe_members([frame(S,A,R,P)|Rest],W,Before,After) :-
    physics_replace_edge(P,Before,After,Changed),
    (Before = frame(S,A,R) -> After = frame(S,A,Next); Next = R),
    retract(physics_frame_member(W,S,A,R,P)),assertz(physics_frame_member(W,S,A,Next,Changed)),
    physics_reframe_members(Rest,W,Before,After).
physics_replace_edge([],_,_,[]).
physics_replace_edge([E|Rest],Before,After,[Next|Changed]) :-
    (E == Before -> Next = After; Next = E), physics_replace_edge(Rest,Before,After,Changed).

%% Shared consequence of an authorized authored-body change. The caller owns
%% admission; this helper owns validation, revision fencing and checkpoint
%% invalidation. Unrelated free-body checkpoints are retained.
physics_replace_body(W,Body,Revision,Kind,BeforePose,Before,Pose,Definition,geometry(Shape,Density)) :-
    physics_body_definition(W,Body,Revision,Kind,BeforePose,Before),
    physics_unconstrained_body(W,Body),
    physics_required_allowances(W,limits(_,_,_,Coordinate,_),_,_,_),
    physics_checked_body(Body,Kind,Pose,Shape,Density,Coordinate),
    physics_advance_structure(W,Structure),
    retract(physics_body_definition(W,Body,Revision,Kind,BeforePose,Before)),
    assertz(physics_body_definition(W,Body,Structure,Kind,Pose,Definition)),
    physics_remove_rest_checkpoint(W,Body), physics_cancel_rest_edit(W,Body).

physics_delete_definition(Entity, Expected) :-
    term_variables([Entity,Expected], []),
    transaction((current_principal(P), can_edit_physics_definition(Entity,P),
        unique_solution(physics_definition(Entity,Expected,Before)),
        current_ontology_identity(Store,StoreAnchor),
        quod:space::space_assignment(entity_ref(Store,StoreAnchor,Entity),_,Destination),
        (Destination = none -> true ; quod:space::goal(unplaced(entity_ref(Store,StoreAnchor,Entity)))),
        retract(physics_definition(Entity,Expected,Before)), Next is Expected + 1,
        assertz(physics_definition(Entity,Next,none)))).

physics_unconstrained_body(W,B) :-
    (\+ physics_joint(W,hinge(body(B,_),_,_,_,_,_,_)), \+ physics_joint(W,hinge(_,_,body(B,_),_,_,_,_)) -> true
    ; fail_with_reason(body_constraint_group(B))).
physics_removable_body(W,B) :-
    physics_unconstrained_body(W,B),
    (\+ physics_agent(W,_,_,B,_) -> true ; fail_with_reason(body_agent_binding(B))),
    physics_rest_custody(W,B,Custody),
    (Custody = none -> true
    ; Custody = request(_,_,Bytes,_),
      committed_operation_outcome(Bytes,Status), member(Status,[committed,rejected,aborted])).

%% A domain supplies one local view and its ordinary principal policy. Marks
%% name occurrences; only body_pose/2 names their physical source. Live samples
%% never validate a durable transaction.
can_view_physics(_, _) :- fail.
can_read_physics_body(_, _, _) :- fail.
can_query_physics_motion(_, _, _, _) :- fail.
physics_query_allowances(_, _, _) :- fail.

%% The live bridge enters this policy in an immutable read-only proof. The
%% returned frame names committed authority; only its installed owner can
%% supply the corresponding current pose.
physics_body_read_projection(W, Body, Frame, Revision) :-
    current_principal(Principal), can_read_physics_body(W, Principal, Body),
    physics_body_projection(W, Body, Frame, Revision).

physics_motion_read_projection(W, Body, Query, Frame, Revision,
        query_limits(Skin, Tolerance, Slides, Checks)) :-
    current_principal(Principal), can_query_physics_motion(W, Principal, Body, Query),
    physics_required_configuration(Q, physics_query_allowances(W, Principal, Q),
        query_allowances(Skin, Tolerance, Slides, Checks, Travel, Turn),
        query_allowances_missing(W)),
    integer(Skin), Skin > 0, integer(Tolerance), Tolerance >= 0, Tolerance < Skin,
    integer(Slides), Slides > 0, integer(Checks), Checks > 0,
    integer(Travel), Travel > 0, integer(Turn), Turn > 0,
    physics_required_allowances(W, limits(_, _, _, Coordinate, _), _, _, _),
    physics_query_input(Query, Coordinate, Travel, Turn),
    physics_body_projection(W, Body, Frame, Revision).

physics_required_allowances(W, Limits, Step, Gravity, Budget) :-
    physics_configuration_rows(allowances(L,S,G,B), physics_allowances(W,L,S,G,B),
        allowances_missing(W), Rows),
    (Rows = [allowances(Limits,Step,Gravity,Budget)] -> true
    ; fail_with_reason(ambiguous_physics_configuration)).

physics_required_configuration(Template, Goal, Requested, Missing) :-
    physics_configuration_rows(Template, Goal, Missing, Rows), member(Requested, Rows).

physics_configuration_rows(Template, Goal, Missing, Rows) :-
    findall(Template, Goal, Rows),
    (Rows = [] -> fail_with_reason(Missing) ; true).

physics_query_input(place(pose(Position, rotation(X,Y,Z))), _, _, Turn) :-
    physics_world_position(Position), physics_query_vector(vector(X,Y,Z), Turn).
physics_query_input(travel(Translation, angular(X,Y,Z)), _, Travel, Turn) :-
    physics_query_vector(Translation, Travel), physics_query_vector(vector(X,Y,Z), Turn).
physics_query_input(landing(Position, Reach, Drop, Up), _, Travel, _) :-
    physics_world_position(Position),
    physics_landing_parameters(Reach, Drop, Up), Reach =< Travel, Drop =< Travel.
physics_landing_parameters(Reach, Drop, Up) :-
    integer(Reach), Reach > 0, integer(Drop), Drop > 0,
    integer(Up), Up > 0, Up =< 1000.
physics_query_vector(vector(X,Y,Z), Limit) :-
    physics_coordinate(X, Limit), physics_coordinate(Y, Limit), physics_coordinate(Z, Limit).

physics_body_projection(W, Body,
        physics_frame(world_ref(Ns, Anchor, W), agent_instance_ref(Ns, Anchor, I),
                      Epoch, Generation, Token, Structure), Revision) :-
    current_ontology_identity(Ns, Anchor), physics_enabled(W, I),
    agent_hosted(I, _, Epoch, _), physics_run(W, Generation, Token), Generation > 0,
    physics_structure(W, Structure), physics_body_definition(W, Body, Revision, _, _, _).

%% Physical agents and viewpoints are domain definitions. Binding a principal
%% selects an existing agent; it never creates a body or changes the signer.
physics_agent(_, _, _, _, _) :- fail.
physics_viewpoint(_, _, _, _, _, _) :- fail.
physics_control(_, _, _, _) :- fail.
can_control_physics_agent(_, _, _) :- fail.

physics_control_state(W, Principal, Epoch, Selection) :-
    findall(control(E, S), physics_control(W, Principal, E, S), Rows),
    (Rows = [] -> Epoch = 0, Selection = none
    ; Rows = [control(E, S)] -> Epoch = E, Selection = S
    ; fail_with_reason(ambiguous_control(W))).

physics_control_agent(W, ExpectedEpoch, ExpectedSelection, Selection) :-
    term_variables([W, ExpectedEpoch, ExpectedSelection, Selection], []),
    integer(ExpectedEpoch), ExpectedEpoch >= 0,
    transaction((current_principal(Principal), physics_space(W, _, _),
        physics_control_state(W, Principal, Epoch, Current),
        (Epoch = ExpectedEpoch, Current = ExpectedSelection -> true
        ; fail_with_reason(control_conflict(Epoch))),
        physics_control_choice(W, Principal, Selection),
        (ExpectedEpoch = 0, ExpectedSelection = none,
         \+ physics_control(W, Principal, _, _) -> true
        ; retract(physics_control(W, Principal, ExpectedEpoch, ExpectedSelection))),
        Next is ExpectedEpoch + 1,
        assertz(physics_control(W, Principal, Next, Selection)))).

physics_control_choice(_, _, none).
physics_control_choice(W, Principal, controlled(Agent, Viewpoint)) :-
    physics_agent_configuration(W, Principal, Agent, Viewpoint, _),
    (\+ (physics_control(W, Other, _, controlled(Agent, _)),
        Other \== Principal) -> true ; fail_with_reason(agent_controlled(Agent))).

%% Exact singleton definitions fail closed on ambiguous authored configuration.
%% Pose/motion schema and supported mechanics are checked by the installing
%% adapter, never inferred from an Eidolon or the human's device dimensions.
physics_agent_configuration(W, Principal, Agent, Viewpoint, Configuration) :-
    Configuration = controlled_agent(Agent, _, _, _, _, viewpoint(Viewpoint, _, _)),
    can_control_physics_agent(W, Principal, Agent),
    once((instance_of(Class, Agent), isa(Class, quod:agent:agent))),
    (findall(definition(R, B, M), physics_agent(W, Agent, R, B, M),
            [definition(Revision, Body, Motion)]),
     findall(A, physics_agent(W, A, _, Body, _), [Agent]),
     findall(R, physics_body_definition(W, Body, R, _, _, _), [BodyRevision]),
     findall(mount(B, Pose, Track), physics_viewpoint(W, Agent, Viewpoint, B, Pose, Track),
            [mount(Body, LocalPose, Tracking)]) -> true
    ; fail_with_reason(ambiguous_agent(Agent))),
    integer(Revision), Revision > 0,
    term_variables([Agent, Viewpoint, Body, Motion, LocalPose, Tracking], []),
    Configuration = controlled_agent(Agent, Revision, Body, BodyRevision, Motion,
                                    viewpoint(Viewpoint, LocalPose, Tracking)).

physics_control_configuration(W, Principal, Epoch, Configuration) :-
    physics_control_state(W, Principal, Epoch, controlled(Agent, Viewpoint)),
    integer(Epoch), Epoch > 0,
    physics_agent_configuration(W, Principal, Agent, Viewpoint, Configuration).

%% This signed read describes domain selection, not native readiness. The
%% simulation endpoint still has to bind the installed run and owner.
physics_client_control(W, control(Epoch,
        controlled_agent(agent_instance_ref(Ns, Anchor, Agent), R, B, BR, Motion, View))) :-
    current_principal(Principal), can_view_physics(W, Principal),
    current_ontology_identity(Ns, Anchor),
    physics_control_configuration(W, Principal, Epoch, controlled_agent(Agent, R, B, BR, Motion, View)).

%% A signed control proof reads committed policy and stages one live input.
%% Camera/tracking offsets never enter this motion descriptor.
physics_input_projection(W, control_frame(Frame, Registration), Epoch, Sequence, Input, Control, Lease, Limits) :-
    quod:agent::agent_identifier(Registration), integer(Sequence), Sequence >= 0, current_principal(Principal),
    physics_input_control(W, Principal, Epoch, Configuration),
    physics_input_limits(W, Principal, Configuration, Frame, Input, Lease, Limits),
    Control = control(Principal, Epoch, Configuration).

physics_input_limits(W, _, Configuration, Frame, Input, Lease, Limits) :-
    Configuration = controlled_agent(_, _, Body, Revision, Motion, _),
    Motion = motion(Mode, Speed, Turn, Lease, Limits, Capabilities),
    physics_motion_mode(Mode), physics_motion_capabilities(Capabilities, []),
    integer(Speed), Speed > 0, integer(Turn), Turn > 0,
    integer(Lease), Lease > 0,
    Limits = query_limits(Skin, Tolerance, Slides, Checks),
    integer(Skin), Skin > 0, integer(Tolerance), Tolerance >= 0, Tolerance < Skin,
    integer(Slides), Slides > 0, integer(Checks), Checks > 0,
    physics_allowed_input(Input, Mode, Speed, Turn, Capabilities),
    physics_required_allowances(W, limits(_, _, _, Coordinate, _), _, _, _),
    physics_absolute_input(Input, Coordinate),
    physics_body_projection(W, Body, Frame, Revision),
    physics_body_definition(W, Body, Revision, controlled, _, _).

physics_input_control(W, Principal, Epoch, Configuration) :-
    physics_control_state(W, Principal, Current, Selection),
    (Selection = controlled(Agent, Viewpoint) -> true ; fail_with_reason(no_control(W))),
    (Epoch = Current -> true ; fail_with_reason(control_conflict(Current))),
    physics_agent_configuration(W, Principal, Agent, Viewpoint, Configuration).

can_push_physics_body(_, _, _) :- fail.
physics_push_allowances(_, _, _, _) :- fail.

physics_push_configuration(W, Principal, Body, Revision, MaxImpulse, MaxSpeed) :-
    can_push_physics_body(W, Principal, Body),
    physics_free_body(W, Body, Revision),
    physics_required_configuration(P, physics_push_allowances(W, Principal, Body, P),
        push_limits(MaxImpulse, MaxSpeed), push_allowances_missing(Body)),
    integer(MaxImpulse), MaxImpulse > 0, integer(MaxSpeed), MaxSpeed > 0.

physics_free_body(W, Body, Revision) :-
    physics_body_definition(W, Body, Revision, dynamic, _, _),
    \+ physics_joint(W, hinge(body(Body,_), _, _, _, _, _, _)),
    \+ physics_joint(W, hinge(_, _, body(Body,_), _, _, _, _)).

physics_input_limits(W, Principal, Configuration, Frame,
        push(body(Body, Revision), vector(X,Y,Z)), Lease,
        push_limits(Body, Revision, MaxImpulse, MaxSpeed)) :-
    Configuration = controlled_agent(_, _, _, _, motion(_, _, _, Lease, _, _), _),
    integer(Lease), Lease > 0,
    physics_push_configuration(W, Principal, Body, Revision, MaxImpulse, MaxSpeed),
    physics_query_vector(vector(X,Y,Z), MaxImpulse),
    X*X+Y*Y+Z*Z > 0, X*X+Y*Y+Z*Z =< MaxImpulse*MaxImpulse,
    physics_body_projection(W, Body, Frame, Revision).

physics_motion_mode(free).
physics_motion_mode(grounded(Up)) :- integer(Up), Up > 0, Up =< 1000.
physics_motion_capabilities([], _).
physics_motion_capabilities([teleport(Reach, Drop, Up) | Rest], Seen) :-
    \+ member(teleport, Seen), physics_landing_parameters(Reach, Drop, Up),
    physics_motion_capabilities(Rest, [teleport | Seen]).
physics_motion_capabilities([snap(Step) | Rest], Seen) :-
    \+ member(snap, Seen), integer(Step), Step > 0, Step =< 3141,
    physics_motion_capabilities(Rest, [snap | Seen]).
physics_motion_capabilities([jump(Speed) | Rest], Seen) :-
    \+ member(jump, Seen), physics_positive_scalar(Speed),
    physics_motion_capabilities(Rest, [jump | Seen]).
physics_motion_capabilities([reposition | Rest], Seen) :-
    \+ member(reposition, Seen), physics_motion_capabilities(Rest, [reposition | Seen]).
physics_absolute_input(reposition(Pose), Coordinate) :-
    physics_query_input(place(Pose), Coordinate, Coordinate, Coordinate).
physics_absolute_input(teleport(Position), _) :- physics_world_position(Position).
physics_absolute_input(drive(_, _), _).
physics_absolute_input(snap(_), _).
physics_absolute_input(jump(_), _).
physics_allowed_input(drive(vector(X,Y,Z), angular(Ax,Ay,Az)), Mode, Speed, Turn, _) :-
    physics_query_vector(vector(X,Y,Z), Speed),
    physics_query_vector(vector(Ax,Ay,Az), Turn),
    X*X+Y*Y+Z*Z =< Speed*Speed, Ax*Ax+Ay*Ay+Az*Az =< Turn*Turn,
    (Mode = grounded(_) -> Y = 0 ; true).
physics_allowed_input(teleport(vector(X,Y,Z)), grounded(_), _, _, Capabilities) :-
    integer(X), integer(Y), integer(Z),
    member(teleport(Reach, Drop, Up), Capabilities), physics_landing_parameters(Reach, Drop, Up).
physics_allowed_input(snap(Angle), _, _, _, Capabilities) :-
    integer(Angle), member(snap(Step), Capabilities),
    integer(Step), Step > 0, Step =< 3141, (Angle = Step ; Angle =:= -Step).
physics_allowed_input(jump(Speed), grounded(_), _, _, Capabilities) :-
    integer(Speed), Speed > 0, member(jump(Speed), Capabilities).
%% Explicit corrective relocation is a separate authored capability. It tests
%% occupancy but may leave an invalid initial placement without a travel path.
%% Like locomotion, it changes live pose; it does not rewrite a durable baseline.
physics_allowed_input(reposition(_), _, _, _, Capabilities) :- member(reposition, Capabilities).

physics_client_view(W, Marks, Selection) :-
    current_principal(P),
    physics_control_state(W, P, Binding, BindingSelection),
    physics_view_selection(W, P, Binding, BindingSelection, Marks, Selection).

physics_view_selection(W, P, Binding, BindingSelection, Marks, Selection) :-
    (can_view_physics(W, P) ->
        (unique_solution(physics_space(W,Mode,I)) ->
            (Mode = disabled -> Selection = disabled
            ; BindingSelection = controlled(Agent, _),
              \+ can_control_physics_agent(W, P, Agent) -> Selection = denied
            ; Mode = enabled, physics_enabled(W, I), physics_view_bodies(Marks, W),
              physics_selected_control(W, P, Binding, BindingSelection, Control) ->
                physics_active_selection(W, I, Control, Selection)
            ; Selection = unavailable)
        ; Selection = unavailable)
    ; Selection = denied).

physics_selected_control(_, _, _, none, none).
physics_selected_control(W, P, Binding, controlled(_, _), control(P, Binding, Configuration)) :-
    physics_control_configuration(W, P, Binding, Configuration).

physics_active_selection(W, I, Control, Selection) :-
    current_ontology_identity(Ns, Anchor),
    unique_solution(physics_structure(W,Structure)),
    findall(run(G, T), physics_run(W, G, T), Runs),
    findall(E, agent_hosted(I, _, E, _), Hosts),
    (Runs = [run(Generation, Token)], Hosts = [Epoch], Generation > 0 ->
        Selection = simulation_view(world_ref(Ns, Anchor, W),
            agent_instance_ref(Ns, Anchor, I), Epoch, Generation, Token, Structure, Control)
    ; (Runs = []; Runs = [run(0, none)]; Hosts = []) -> Selection = recovering
    ; Selection = unavailable).

physics_view_bodies([], _).
physics_view_bodies([mark(_, _, _, Pose, _, _, Depicts) | Rest], W) :-
    physics_view_body(Pose, Depicts, W), physics_view_bodies(Rest, W).

%% Decorative occurrences keep their authored frames. Only an explicit body
%% source receives native poses; its subject may live in another ontology.
physics_view_body(relative(_, Pose), Depicts, W) :- physics_view_body(Pose, Depicts, W).
physics_view_body(transform(_, _, _, _, _, _), _, _).
physics_view_body(body_pose(B, R), depicts(_, _, _), W) :- physics_body_definition(W, B, R, _, _, _).
physics_view_body(body_frame_pose(B,R),depicts(Ns,A,Entity),W) :-
    physics_body_definition(W,B,R,_,_,live(entity_ref(Ns,A,Entity),_,_,_)).

%% The admitting world already owns the exact source/assignment binding.
%% Looking up an appearance shares that binding and grants no new presence.
physics_appearance_binding(W,Subject,Binding) :-
    findall(body_pose(B,R),physics_body_definition(W,B,R,_,_,live(Subject,_,_,_)),Rows),
    (Rows = [] -> Binding = none
    ; Rows = [Binding] -> true
    ; fail_with_reason(ambiguous_physical_appearance(Subject))).

%% One immutable source-frame receipt per streamed body, shared by decorative
%% occurrences. Dynamic state stays exclusively in the native frame stream.
physics_scene_frames(W,Marks,Frames) :-
    findall(body(B,R),(member(mark(_,_,_,Pose,_,_,_),Marks),
                       physics_relative_body(Pose,B,R)),Raw), sort(Raw,Unique),
    physics_body_frames(Unique,W,Frames).
physics_body_frames([],_,[]).
physics_body_frames([body(B,R)|Rest],W,[body_frame(B,R,Id,Transforms)|Frames]) :-
    physics_body_definition(W,B,R,_,Pose,_),physics_pose_path(Pose,Path),
    physics_view_frames(W,Path,Transforms),term_hex_digest(Path,Id),
    physics_body_frames(Rest,W,Frames).
physics_relative_body(body_frame_pose(B,R),B,R).
physics_relative_body(relative(_,Pose),B,R) :- physics_relative_body(Pose,B,R).

physics_projection(Node, Rows) :-
    findall(world(W, I, Epoch, Key, Generation, RunToken, Custody, Structure,
                  Limits, StepUs, Gravity, Bodies, Budget,
                  baseline(Checkpoints, Joints, Activities, control_selection(Bindings, Controls))),
      (physics_enabled(W, I), agent_hosted(I, Node, Epoch, Key),
       physics_run(W, Generation, RunToken), physics_structure(W, Structure),
       physics_required_allowances(W, Limits, StepUs, Gravity, Budget),
       physics_custody(W, Custody),
       findall(C, physics_recovery_checkpoint(W, C), Checkpoints),
       findall(J, physics_joint(W, J), Joints),
       findall(activity(Reference,Request,Command,Saved),
               physics_activity(W,Reference,Request,Command,Saved), Activities),
       findall(binding(Principal, BindingEpoch, Selection),
               physics_control(W, Principal, BindingEpoch, Selection), Bindings),
       findall(control(Principal, ControlEpoch, Configuration),
               (physics_control(W, Principal, _, controlled(_, _)),
                physics_control_configuration(W, Principal, ControlEpoch, Configuration)), AgentControls),
       findall(push(Principal, Body, Revision, MaxImpulse, MaxSpeed),
               (physics_control(W, Principal, _, controlled(_, _)),
                physics_push_configuration(W, Principal, Body, Revision, MaxImpulse, MaxSpeed)), Pushes),
       append(AgentControls, Pushes, Controls),
       findall(body(Id, Rev, Kind, Pose, Definition),
               physics_body_definition(W, Id, Rev, Kind, Pose, Definition), Bodies)), Rows).

physics_custody(W, Custody) :-
    findall(R, physics_request(W, R), Requests),
    (Requests = [] -> Custody = none ; Requests = [Custody]),
    \+ physics_cancelled_request(W,Custody).

physics_actor(W) :-
    physics_enabled(W, I), current_ontology_identity(Ns, Anchor),
    current_principal(agent_instance_ref(Ns, Anchor, I)),
    agent_hosted(I, _, _, _).

%% The original signed activation is durable before submission. Its exact
%% request remains available after actor, runtime or host loss. This is domain
%% work in the existing ontology transaction lane, not a local outbox.
physics_store_request(W, Generation, Prior, Token, Bytes, Signature) :-
    transaction((physics_actor(W), physics_run(W, Generation, _),
        physics_custody(W, Prior), physics_previous_complete(Prior, Generation), quod:agent::agent_identifier(Token),
        signed_physics_request(physics_activate(W, Generation, Token), Bytes, Signature),
        \+ physics_cancelled_request(W, request(Token, Generation, Bytes, Signature)),
        (Prior = none -> true ; retract(physics_request(W, Prior))),
        assertz(physics_request(W, request(Token, Generation, Bytes, Signature))))).

physics_activate(W, Generation, Token) :-
    transaction((physics_actor(W), physics_run(W, Generation, Previous),
        physics_request(W, request(Token, Generation, Bytes, _Signature)),
        current_signed_request(Bytes),
        retract(physics_run(W, Generation, Previous)), Next is Generation + 1,
        assertz(physics_run(W, Next, Token)))).

%% A pending request cannot be overwritten merely because its result is late.
physics_previous_complete(none, _).
physics_previous_complete(request(_, Previous, _, _), Generation) :- Generation > Previous.

%% An explicit policy action, never inferred from elapsed time. Removing this
%% exact custody invalidates the old activation's ordinary OCC read dependency.
%% The original bytes remain available; cancelled does not assert an operation
%% outcome for a request that may still be in flight.
can_cancel_physics_activation(_, _) :- fail.
physics_cancel_activation(W, Generation, Request) :-
    term_variables([W, Generation, Request], []),
    transaction((current_principal(Principal), can_cancel_physics_activation(W, Principal),
        physics_run(W, Generation, _),
        Request = request(Token, Generation, Bytes, Signature),
        signed_physics_request(physics_activate(W,Generation,Token),Bytes,Signature),
        \+ physics_cancelled_request(W,Request),
        (physics_request(W,Request) -> retract(physics_request(W,Request)) ; true),
        assertz(physics_cancelled_request(W, Request)))).

%% The custody owner can retire only an exact request fenced by committed
%% domain state. Missing custody, elapsed time and disabled intent prove nothing.
physics_store_retired(W,Generation,Token,Authority,Epoch,Key,Bytes,Signature) :-
    physics_actor(W), current_ontology_identity(Ns,A),
    Authority = agent_instance_ref(Ns,A,I),
    signed_physics_request(physics_activate(W,Generation,Token),Bytes,Signature),
    (physics_cancelled_request(W,request(Token,Generation,Bytes,Signature))
    ; physics_run(W,Current,_), Current > Generation
    ; agent_key(I,Key,revoked), agent_host(I,_,Next,_), Next > Epoch).

%% Durable domain status is derived from the same atomic transition, not a
%% separately maintained sent flag. Pending includes never-sent and uncertain.
physics_activation_status(W, Request, pending) :-
    physics_request(W, Request), Request = request(_, Generation, _, _),
    physics_run(W, Generation, _).
physics_activation_status(W, Request, activated) :-
    physics_request(W, Request), Request = request(Token, Previous, _, _),
    Generation is Previous + 1, physics_run(W, Generation, Token).
physics_activation_status(W, Request, cancelled) :- physics_cancelled_request(W, Request).

can_edit_physics(_, _) :- fail.

%% Shared authored-body schema. Native installation still checks numeric
%% representation, hull volume, triangle area and supported joint mechanics.
%% A surface is explicit fixed collision coverage, never a moving solid.
physics_checked_body(Id, Kind, Pose, Shape, Density, Coordinate) :-
    (Pose = framed(_,_), physics_terrain_shape(Shape) ->
        fail_with_reason(unsupported_framed_terrain(Id))
    ; physics_valid_body(Id, Kind, Pose, Shape, Density, Coordinate) -> true
    ; fail_with_reason(invalid_physics_body(Id))).
physics_terrain_shape(voxel_field_v1(_,_,_)).
physics_terrain_shape(voxel_resident_v1(_,_)).
physics_valid_hinge(vector(X,Y,Z), anchors(Fixed,Moving), limits(Lower,Upper), Baseline, Coordinate) :-
    physics_milli_integer(X), physics_milli_integer(Y), physics_milli_integer(Z),
    (X =\= 0 ; Y =\= 0 ; Z =\= 0),
    physics_body_vector(Fixed,Coordinate), physics_body_vector(Moving,Coordinate),
    integer(Lower), integer(Upper), Lower >= -3141, Upper =< 3141,
    Lower =< Upper, Upper-Lower =< 3141,
    integer(Baseline), Baseline >= Lower, Baseline =< Upper.
physics_valid_joint_command(hold, _).
physics_valid_joint_command(position(Target,motor(Stiffness,Damping,Torque),stop(Tolerance,target_or_contact)),
                            limits(Lower,Upper)) :-
    integer(Target), Target >= Lower, Target =< Upper,
    physics_positive_scalar(Stiffness), physics_positive_scalar(Damping),
    physics_positive_scalar(Torque), physics_positive_scalar(Tolerance).

%% Both physical measurement schemas carry this same immutable, signed envelope.
%% Domain consumers match exact participating revisions, command and payload.
%% Reaction matching uses local run state; signed store/finish actions check
%% class eligibility and the acting authority together through physics_actor/1.
physics_valid_sample(physics_sample(
        physics_frame(world_ref(Ns,Anchor,W),agent_instance_ref(Ns,Anchor,I),Epoch,G,Token,Structure),
        activity(_,_,_),revisions(_),Tick,validity(At,Expiry),_), W) :-
    physics_space(W,enabled,I), current_ontology_identity(Ns,Anchor), agent_hosted(I,_,Epoch,_),
    physics_run(W,G,Token), integer(G), G > 0, binary_codes(Token,Bytes), length(Bytes,32),
    physics_structure(W,Structure),
    integer(Tick), Tick > 0, Tick < 18446744073709551616,
    physics_required_allowances(W,_,_,_,Budget),
    integer(At), At >= 0, integer(Expiry), Expiry > At, Expiry-At =< Budget,
    current_request_expiry(RequestExpiry), RequestExpiry > At, RequestExpiry =< Expiry.

%% New activity admission cannot discard unresolved original custody. An
%% authored cancellation plus changed physical revisions is the explicit exit.
physics_observation_replaceable(none,_,_).
physics_observation_replaceable(request(Sample,_,Bytes,_),State,References) :-
    Sample = physics_sample(_,activity(_,R,_),revisions(Before),_,_,_),
    ((State = finished(R) ; State = cancelled(R), Before \= References) -> true
    ; physics_request_rejected(Bytes)).

physics_newer_sample(none,_).
physics_newer_sample(request(Previous,_,_,_),Sample) :-
    Previous = physics_sample(physics_frame(World,_,_,OldG,_,_),_,_,OldTick,_,_),
    Sample = physics_sample(physics_frame(World,_,_,G,_,_),_,_,Tick,_,_),
    (G > OldG ; G = OldG, Tick > OldTick).

physics_remove_hinge_checkpoint(W,D) :-
    findall(C, (physics_checkpoint(W,C), C = hinge(D,_,_,_,_,_,_)), Rows),
    (Rows = [] -> true ; Rows = [Old], retract(physics_checkpoint(W,Old))).

%% A free obstacle edit advances the conservative whole-world fence. Pending
%% physical requests remain fenced; a pre-edit observation cannot finish them.
physics_move_body(W,D,Revision,Structure,Position) :-
    term_variables([W,D,Revision,Structure,Position], []),
    transaction((current_principal(P), can_edit_physics(W,P),
        physics_structure(W,Structure), physics_body_definition(W,D,Revision,Kind,Old,Definition),
        physics_resolve_definition(W,Definition,Shape,Density),
        Position = vector(_,_,_), physics_relocated_pose(Old,Position,Pose),
        physics_replace_body(W,D,Revision,Kind,Old,Definition,Pose,Definition,geometry(Shape,Density)))).

physics_relocated_pose(vector(_,_,_),Position,Position).
physics_relocated_pose(pose(_,Rotation),Position,pose(Position,Rotation)).

% Replacement custody requires exact terminal evidence captured in the proof's
% ordinary read set. Unknown or unpublished outcomes cannot prove rejection.
physics_request_rejected(Bytes) :-
    committed_operation_outcome(Bytes, Status),
    (Status = rejected ; Status = aborted).


%% Rest checkpoint requests are explicit policy actions, independent of hot
%% impulses. Their fulfilment uses the common owned observation/custody lane.
%% The author baseline is never overwritten by a sample.
physics_rest(_, _, _, _) :- fail.
can_checkpoint_physics_body(_, _, _) :- fail.
physics_rest_policy(_, _, _) :- fail.

physics_checkpoint_body(W,D,Revision,Sequence,Id) :-
    term_variables([W,D,Revision,Sequence,Id], []), quod:agent::agent_identifier(Id),
    transaction((current_principal(P), can_checkpoint_physics_body(W,D,P), physics_enabled(W,_),
        (physics_free_body(W,D,Revision) -> true ; fail_with_reason(body_not_free(D))),
        (physics_rest_policy(W,D,_) -> true ; fail_with_reason(rest_policy_missing(D))),
        physics_rest_state(W,D,Current,Before),
        (Sequence = Current -> true ; fail_with_reason(checkpoint_conflict(D))),
        (Before \= waiting(_) -> true ; fail_with_reason(checkpoint_pending(D))),
        physics_rest_custody(W,D,Prior),
        (physics_rest_replaceable(Prior,W,D) -> true
        ; fail_with_reason(checkpoint_custody_held(D))),
        physics_remove_rest_state(W,D), Next is Sequence + 1,
        assertz(physics_rest(W,D,Next,waiting(rest(Next,Id)))),
        physics_remove_rest_request(W,D))).

physics_rest_state(W,D,Sequence,State) :-
    findall(rest(S,T), physics_rest(W,D,S,T), Rows),
    (Rows = [] -> Sequence = 0, State = idle
    ; Rows = [rest(S,T)] -> Sequence = S, State = T
    ; fail_with_reason(ambiguous_checkpoint(D))).
physics_rest_custody(W,D,C) :-
    findall(R, physics_rest_request(W,D,R), Rows),
    (Rows = [] -> C = none ; Rows = [R] -> C = R
    ; fail_with_reason(ambiguous_checkpoint_custody(D))).
%% An authored cancellation retires this activity, not its backend operation.
%% The changed revision makes its exact old finish permanently ineligible.
physics_rest_replaceable(Custody,W,D) :-
    physics_rest_state(W,D,_,Before), physics_free_body(W,D,Revision),
    (Before = finished(Sample) ->
        Sample = physics_sample(_,activity(_,R,_),_,_,_,_), State = finished(R)
    ; State = Before),
    physics_observation_replaceable(Custody,State,[body(D,Revision)]).

%% Extensions contribute physical requests to this relation. Runtime owners
%% never receive the domain's waiting/finished/cancelled state vocabulary.
physics_activity(_,_,_,_,_) :- fail.
physics_activity(W,rest(D,Revision),Request,rest,Custody) :-
    physics_rest(W,D,_,State), physics_free_body(W,D,Revision),
    (State = waiting(R) -> Request = R ; Request = none),
    physics_rest_custody(W,D,Custody).

react_on(observed(Sample), physics_finish_rest(Sample)) :-
    physics_observation(Sample), physics_rest_measurement(Sample),
    prepare_signed_request(Bytes,Signature,physics_store_rest_request(Sample,Bytes,Signature)).

physics_store_rest_request(Sample,Bytes,Signature) :-
    term_variables([Sample,Bytes,Signature], []),
    transaction((physics_rest_measurement(Sample),
        Sample = physics_sample(physics_frame(world_ref(_,_,W),_,_,_,_,_),
            activity(rest(D,Revision),R,rest),_,_,_,_), physics_actor(W),
        physics_rest_custody(W,D,Prior),
        physics_observation_replaceable(Prior,waiting(R),[body(D,Revision)]),
        physics_newer_sample(Prior,Sample),
        signed_physics_request(physics_finish_rest(Sample),Bytes,Signature),
        physics_remove_rest_request(W,D),
        assertz(physics_rest_request(W,D,request(Sample,rest,Bytes,Signature))))).

physics_finish_rest(Sample) :-
    term_variables(Sample, []),
    transaction((physics_rest_measurement(Sample),
        Sample = physics_sample(physics_frame(world_ref(_,_,W),Authority,Epoch,G,Token,Structure),
            activity(rest(D,Revision),R,rest),_,Tick,_,rest_pose_mm_quaternion_million(Pose)),
        physics_actor(W), physics_rest_request(W,D,request(Sample,rest,Bytes,_Signature)),
        current_signed_request(Bytes),
        retract(physics_rest(W,D,Sequence,waiting(R))),
        assertz(physics_rest(W,D,Sequence,finished(Sample))),
        physics_remove_rest_checkpoint(W,D),
        assertz(physics_checkpoint(W,rest_v1(D,Revision,
            source(Authority,Epoch,G,Token,Structure,Tick),world_mm_quaternion_million,Pose,zero_velocity))),
        trigger_event(physics_body_checkpointed(W,D,R)))).

physics_rest_measurement(Sample) :-
    Sample = physics_sample(physics_frame(world_ref(_,_,W),_,_,G,_,_),
        activity(rest(D,Revision),R,rest),revisions([body(D,Revision)]),Tick,_,
        rest_pose_mm_quaternion_million(Pose)),
    physics_valid_sample(Sample,W),
    physics_free_body(W,D,Revision), physics_rest(W,D,_,waiting(R)),
    physics_rest_policy(W,D,recovery(Tolerance,Checks)),
    integer(Tolerance), Tolerance >= 0, integer(Checks), Checks > 0,
    Pose = pose(Position,quaternion(X,Y,Z,Q)), physics_world_position(Position),
    physics_coordinate(X,1000000), physics_coordinate(Y,1000000),
    physics_coordinate(Z,1000000), physics_coordinate(Q,1000000),
    Norm is X*X+Y*Y+Z*Z+Q*Q, Norm >= 999996000000, Norm =< 1000004000000,
    \+ (physics_checkpoint(W,rest_v1(D,_,source(_,_,OldG,_,_,OldTick),_,_,_)),
        (OldG > G ; OldG = G, OldTick >= Tick)).

physics_remove_rest_state(W,D) :-
    findall(rest(S,T),physics_rest(W,D,S,T),Rows),
    (Rows = [] -> true ; Rows = [rest(S,T)], retract(physics_rest(W,D,S,T))).
physics_cancel_rest_edit(W,D) :-
    physics_rest_state(W,D,Sequence,State),
    (State = waiting(R) -> physics_remove_rest_state(W,D),
        assertz(physics_rest(W,D,Sequence,cancelled(R))) ; true).
physics_remove_rest_request(W,D) :-
    physics_rest_custody(W,D,C), (C = none -> true ; retract(physics_rest_request(W,D,C))).
physics_remove_rest_checkpoint(W,D) :-
    findall(C,(physics_checkpoint(W,C),C = rest_v1(D,_,_,_,_,_)),Rows),
    (Rows = [] -> true ; Rows = [C], retract(physics_checkpoint(W,C))).

physics_recovery_checkpoint(W,C) :- physics_checkpoint(W,C), C \= rest_v1(_,_,_,_,_,_).
physics_recovery_checkpoint(W,rest(C,Policy)) :-
    physics_checkpoint(W,C), C = rest_v1(D,_,_,_,_,_),
    findall(P,physics_rest_policy(W,D,P),Policies),
    (Policies = [Policy] -> true ; Policy = invalid).

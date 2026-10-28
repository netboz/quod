%% Governed space vocabulary, composed into the ontologies owning its facts.
%% No ACL grants, native modules, actors or resource selectors are installed.
%% Only the shared foundation opts into public vocabulary admission. Composing
%% this implementation into private storage does not publish its instance facts.
can_invoke(Goal, _, _, _) :- space_foundation, space_query(Goal).
can_invoke((current_ontology_identity(_, _), Goal), _, _, _) :-
    space_foundation, space_query(Goal).
can_invoke(Goal, _, _, _) :- space_foundation, system_source_query(Goal).
can_invoke(_, node(Key), _, _) :- space_foundation, peer_admitted(Key, _, _, Key).
can_join(_, _, Key) :- space_foundation, peer_ready(Key).
space_query(space_template_hash(_)).
space_query(isa(_, _)).
space_query(have_attribute(_, _, _, _)).
space_query(have_part(_, _)).
space_query(class_eidolon(_, _, _, _)).
space_query(eidolon(_, _, _)).
space_query(Goal) :- public_source_query(Goal).
isa(space, thing).
isa(physical_space, space).

%% Interior lengths are independent of the exterior model and resource policy.
have_attribute(space, name, binary, default(<<"Space">>)).
have_attribute(space, dimensions, space_dimensions,
    default(box(q(100, <<"m">>), q(100, <<"m">>), q(100, <<"m">>)))).
have_attribute(space, owner, space_owner, default_from(space_creator_owner)).
%% Consumed by construction; the assignment remains the sole location record.
have_attribute(space, placement, space_initial_placement).
have_attribute(space, exterior, space_exterior, default(solid)).
have_part(space, initial_occupants).

%% The pin certifies the composed source, not a remote constructor or class alias.
space_recipe :-
    findall(recipe(N,A,D), (space_vocabulary(N,A),space_source_digest(D)), [recipe(Ns,Anchor,Digest)]),
    Ns::(current_ontology_identity(Ns,Anchor),space_template_hash(Digest)).

space_dimensions(infinite).
space_dimensions(box(Width, Height, Depth)) :-
    findall(measure(N, A), measure_vocabulary(N, A), [measure(Ns, Anchor)]),
    space_length(Ns, Anchor, Width), space_length(Ns, Anchor, Height),
    space_length(Ns, Anchor, Depth).
space_length(Ns, Anchor, q(Value, Unit)) :-
    binary(Unit),
    Ns::(current_ontology_identity(Ns, Anchor), convert(Value, Unit, <<"m">>, Metres)),
    (integer(Metres) -> Metres > 0
    ; Metres = N / D, integer(N), integer(D), N > 0, D > 0).

space_owner(agent_instance_ref(Ns, Anchor, Entity)) :-
    binary(Ns), binary(Anchor), term_variables(Entity, []).
space_creator_owner(_, Owner) :-
    current_principal(agent_instance_ref(Ns, Anchor, _)),
    Ns::(current_ontology_identity(Ns, Anchor), personal_agent_owner(Owner)).

space_initial_placement(near_agent).
space_initial_placement(unplaced).
space_initial_placement(at(entity_ref(Ns, Anchor, Entity), Transform)) :-
    binary(Ns), binary(Anchor), term_variables(Entity, []), space_transform(Transform).
space_transform(transform(X, Y, Z, RX, RY, RZ)) :-
    integer(X), integer(Y), integer(Z), integer(RX), integer(RY), integer(RZ).

constructor(space, Space, Inputs) :-
    space_recipe,
    attribute(Space, exterior, Exterior), attribute(Space, dimensions, Dimensions),
    space_exterior_available(Exterior, Dimensions),
    (retract(attribute(Space, placement, Requested)) -> true; Requested = near_agent),
    (Requested = at(Destination, Pose) -> Placement = placed(Destination, Pose)
    ; Requested = unplaced -> Placement = unplaced
    ; Requested = near_agent, current_principal(agent_instance_ref(Ns, Anchor, Agent)),
      Ns::(current_ontology_identity(Ns, Anchor), space_location(Agent, Location)),
      space_near_location(Location, Placement)),
    (Placement = unplaced -> Pose = transform(0,0,0,0,0,0)
    ; Placement = placed(Destination, Pose), space_place(Space, 0, Destination)),
    assertz(attribute(Space, transform, Pose)),
    build_plan_part(Inputs, initial_occupants, Occupants),
    space_initial_occupants(Space, Occupants).

%% These are existing entities, not child constructors. Keep admission inside
%% the destination's construction scope and the original assertion savepoint.
space_initial_occupants(_, []).
space_initial_occupants(Space, [attribute(entities, Entities)]) :-
    term_variables(Entities, []), sort(Entities, Unique),
    length(Entities, Count), length(Unique, Count),
    current_ontology_identity(Ns, Anchor),
    (space_initial_local(Entities, Ns, Anchor) -> true
    ; fail_with_reason(initial_occupants_require_local_storage)),
    space_place_initial(Entities, entity_ref(Ns, Anchor, Space)).

%% Construction authority belongs to this owner and assertion continuation.
%% A foreign source cannot lend that authority back through another scope.
space_initial_local([], _, _).
space_initial_local([entity_ref(Ns, Anchor, _) | Rest], Ns, Anchor) :-
    space_initial_local(Rest, Ns, Anchor).
space_place_initial([], _).
space_place_initial([entity_ref(Ns, Anchor, Entity) | Rest], Destination) :-
    binary(Ns), binary(Anchor),
    Ns::(current_ontology_identity(Ns, Anchor),
         space_assignment(Entity, Revision, none),
         space_place(Entity, Revision, Destination)),
    space_place_initial(Rest, Destination).

%% A successful owner read explicitly distinguishes absence from failure.
%% Missing/ambiguous pose on a placed agent refuses creation, never unplaces it.
space_location(Entity, Location) :-
    instance_of(_, Entity), space_assignment(Entity, _, Destination),
    (Destination == none -> Location = unplaced
    ; findall(Pose, attribute(Entity, transform, Pose), [Transform]),
      space_transform(Transform), Location = placed(Destination, Transform)).
space_near_location(unplaced, unplaced).
space_near_location(placed(Destination, transform(X,Y,Z,RX,RY,RZ)),
                   placed(Destination, transform(NearX,Y,Z,RX,RY,RZ))) :-
    NearX is X + 1000.

space_instance(Space, Class) :-
    once((instance_of(Direct, Space), isa(Direct, Class))).

space_subject(Entity, Subject) :-
    (instance_of(_, Entity) -> Subject = instance(Entity)
    ; isa(Entity, Entity), Subject = class(Entity)).

%% Exact references are operation inputs, supplied by the executing owner.
%% Policy stays strictly local and committed, including inherited requirements.
space_authorized(Entity, Name, Other, Mode) :-
    current_ontology_identity(Ns, Anchor), space_subject(Entity, Subject),
    Operation =.. [Name, entity_ref(Ns, Anchor, Entity), Other, Mode],
    operation_authorized(Subject, Operation).

%% Display membership is many-to-many. The destination owns this fact;
%% a class or a nested space is an anchored subject, never a copied definition.
space_contains(Space, Subject) :- space_member(Space, Subject).
space_contains(Space, Subject) :- space_placement(Space, Subject, _).

space_contain(Space, Subject) :-
    term_variables([Space, Subject], []),
    Subject = entity_ref(Ns, Anchor, Entity),
    transaction((
        space_instance(Space, space), current_principal(Principal),
        current_ontology_identity(Here, History),
        Destination = entity_ref(Here, History, Space),
        Subject \== Destination,
        space_authorized(Space, space_admit, Subject, display),
        Ns::(current_ontology_identity(Ns, Anchor),
             space_consent(Entity, Principal, Destination, display)),
        \+ space_member(Space, Subject),
        assertz(space_member(Space, Subject)))).

space_consent(Entity, Principal, Destination, Mode) :-
    current_principal(Principal),
    space_authorized(Entity, space_enter, Destination, Mode).

%% Either owner can end display membership. Revoking a future-entry
%% grant alone does not erase an existing relation: use this same transition.
space_remove(Space, Subject) :-
    term_variables([Space, Subject], []),
    transaction((
        space_removal_allowed(Space, Subject, display),
        retract(space_member(Space, Subject)))).

space_removal_allowed(Space, Subject, Mode) :-
    current_principal(Principal),
    (space_authorized(Space, space_remove, Subject, Mode) -> true
    ; Subject = entity_ref(Ns, Anchor, Entity),
      current_ontology_identity(Here, History),
      Ns::(current_ontology_identity(Ns, Anchor),
           space_withdrawal_consent(Entity, Principal,
                                    entity_ref(Here, History, Space), Mode))).

space_withdrawal_consent(Entity, Principal, Destination, Mode) :-
    current_principal(Principal),
    space_authorized(Entity, space_leave, Destination, Mode).

%% The instance ontology is the designated exclusive-assignment owner. Keep
%% the revision after withdrawal: a stale admission cannot reuse an empty slot.
space_assignment(Entity, Revision, Destination) :-
    findall(assignment(R, D), space_assignment_state(Entity, R, D), Rows),
    (Rows = [] -> R0 = 0, D0 = none
    ; Rows = [assignment(R0, D0)] -> true
    ; fail_with_reason(ambiguous_space_assignment(Entity))),
    Revision = R0, Destination = D0.

space_place(Entity, ExpectedRevision, Destination) :-
    term_variables([Entity, ExpectedRevision, Destination], []),
    Destination = entity_ref(Ns, Anchor, Space),
    transaction((
        instance_of(_, Entity),
        space_authorized(Entity, space_enter, Destination, placement),
        space_expected_assignment(Entity, ExpectedRevision, Previous),
        (Previous = none -> true ; fail_with_reason(space_already_placed(Entity))),
        current_ontology_identity(Here, History),
        Destination \== entity_ref(Here, History, Entity),
        (ExpectedRevision = 0 -> true
        ; retract(space_assignment_state(Entity, ExpectedRevision, none))),
        Revision is ExpectedRevision + 1,
        assertz(space_assignment_state(Entity, Revision, Destination)),
        Ns::(current_ontology_identity(Ns, Anchor),
             space_accept_placement(Space, entity_ref(Here, History, Entity), Revision)))).

%% This participant entry requires the assignment staged by space_place/3.
%% Calling it alone cannot allocate a slot or complete half a transition.
space_accept_placement(Space, Subject, Revision) :-
    term_variables([Space, Subject, Revision], []),
    Subject = entity_ref(Ns, Anchor, Entity),
    transaction((
        (space_instance(Space, space) -> true
        ; fail_with_reason(not_space(Space))),
        current_ontology_identity(Here, History),
        space_authorized(Space, space_admit, Subject, placement),
        Ns::(current_ontology_identity(Ns, Anchor),
             space_assignment(Entity, Revision, entity_ref(Here, History, Space))),
        (\+ space_placement(Space, Subject, _) -> true
        ; fail_with_reason(space_placement_exists(Space, Subject))),
        space_change_physics(Space, Subject, admitted),
        assertz(space_placement(Space, Subject, Revision)))).

%% A destination eviction and an instance-owner withdrawal use the same path.
%% Admission accepts that the destination may revoke it under its own policy.
space_withdraw(Entity, ExpectedRevision, Destination) :-
    term_variables([Entity, ExpectedRevision, Destination], []),
    Destination = entity_ref(Ns, Anchor, Space),
    transaction((
        space_expected_assignment(Entity, ExpectedRevision, Destination),
        retract(space_assignment_state(Entity, ExpectedRevision, Destination)),
        Revision is ExpectedRevision + 1,
        assertz(space_assignment_state(Entity, Revision, none)),
        current_ontology_identity(Here, History),
        Ns::(current_ontology_identity(Ns, Anchor),
             space_release_placement(Space, entity_ref(Here, History, Entity),
                                     ExpectedRevision, Revision)))).

space_release_placement(Space, Subject, Before, Revision) :-
    term_variables([Space, Subject, Before, Revision], []),
    Subject = entity_ref(Ns, Anchor, Entity), Revision is Before + 1,
    transaction((
        space_removal_allowed(Space, Subject, placement),
        Ns::(current_ontology_identity(Ns, Anchor),
             space_assignment(Entity, Revision, none)),
        space_change_physics(Space, Subject, withdrawn),
        retract(space_placement(Space, Subject, Before)))).

space_expected_assignment(Entity, Expected, Destination) :-
    integer(Expected), Expected >= 0,
    space_assignment(Entity, Current, Actual),
    (Current = Expected -> true
    ; fail_with_reason(space_revision_conflict(Entity, Current))),
    (Destination = Actual -> true
    ; fail_with_reason(space_destination_conflict(Entity))).

space_change_physics(Space, Subject, Change) :-
    %% Retained live bindings still require cleanup after destination type edits.
    ((space_instance(Space, physical_space)
      ; Change == withdrawn,
        physics_body_definition(Space,_,_,_,_,live(Subject,_,_,_))) ->
        (space_physical_change(Space, Subject, Change) -> true
        ; fail_with_reason(space_physical_change_refused(Space, Change)))
    ; true).

%% Composition supplies policy and the physical lifecycle consequence. No
%% missing hook silently skips constraint/checkpoint or pending-work cleanup.
space_physical_change(_, _, _) :- fail.

%% Authored Create forms. The shared GUI binder invokes the normal assertion;
%% the space constructor and committed class policy own every consequence.
class_eidolon(space, operation(class), create, recipe(Ns, A, space_create)) :-
    current_ontology_identity(Ns, A).
class_eidolon(space, operation(class), create_exact, recipe(Ns, A, space_create_exact)) :-
    current_ontology_identity(Ns, A).
class_eidolon(space, operation(class), create_infinite, recipe(Ns, A, space_create_infinite)) :-
    current_ontology_identity(Ns, A).
eidolon(space_create, subject(ontology_ref(Ns, A), class(space)), operation(space_create(finite))) :-
    current_ontology_identity(Ns, A).
eidolon(space_create_infinite, subject(ontology_ref(Ns, A), class(space)), operation(space_create(infinite))) :-
    current_ontology_identity(Ns, A).

eidolon(space_create_exact, subject(ontology_ref(Ns, A), class(space)), operation(space_create(exact))) :-
    current_ontology_identity(Ns, A).

instance_of(quod:gui:form, space_create(Extent)) :- member(Extent, [finite, exact, infinite]).
instance_of(quod:gui:text_box, space_name).
instance_of(quod:gui:selection, space_placement).
instance_of(quod:gui:number_input, space_length(Axis)) :- member(Axis, [width,height,depth]).
instance_of(quod:gui:number_input, space_divisor(Axis)) :- member(Axis, [width,height,depth]).
instance_of(quod:gui:selection, space_unit).
instance_of(quod:gui:button, space_create_submit).
attribute(space_create(finite), label, <<"Create space">>).
attribute(space_create(exact), label, <<"Create space with rational lengths">>).
attribute(space_create(infinite), label, <<"Create infinite space">>).
attribute(space_create(_), help, <<"The personal agent's human is the default owner, independently of the selected storage and placement. Creation does not enter the new space.">>).
attribute(space_name, label, <<"Name">>).
attribute(space_name, help, <<"The class default is supplied. Change it to use your own name.">>).
attribute(space_name, required, false).
attribute(space_placement, label, <<"Placement">>).
attribute(space_placement, options, Options) :-
    current_ontology_identity(Ns, A),
    findall(option(at(entity_ref(Ns,A,S),transform(0,0,0,0,0,0)), Label),
        (space_instance(S,space), attribute(S,name,Label)), Destinations),
    append([option(near_agent, <<"Near my agent, or unplaced when my agent is unplaced">>),
            option(unplaced, <<"Unplaced">>)], Destinations, Options).
instance_of(quod:gui:selection, space_exterior(Extent)) :- member(Extent,[finite,exact,infinite]).
attribute(space_exterior(_), label, <<"Exterior representation">>).
attribute(space_exterior(Extent), options,
    [option(solid,<<"Small solid cube">>),option(wireframe,<<"Full-size finite wireframe">>)]) :- member(Extent,[finite,exact]).
attribute(space_exterior(infinite), options, [option(solid,<<"Small solid cube">>) ]).
attribute(space_exterior(Extent), help, <<"Wireframe shows the exact interior dimensions without collision. Contents exteriors are not supported by this client checkpoint.">>) :- member(Extent,[finite,exact]).
attribute(space_exterior(infinite), help, <<"Infinite extent has no finite wireframe. The solid cube is available; contents exteriors are not supported by this client checkpoint.">>).
attribute(space_length(width), label, <<"Width (X)">>).
attribute(space_length(height), label, <<"Height (Y)">>).
attribute(space_length(depth), label, <<"Depth (Z)">>).
attribute(space_length(_), range, range(1,1000000,1)).
attribute(space_divisor(Axis), label, Label) :-
    member(Axis-Label,[width - <<"Width divisor">>,height - <<"Height divisor">>,depth - <<"Depth divisor">>]).
attribute(space_divisor(_), help, <<"The length is the numerator divided by this positive integer, in the selected unit.">>).
attribute(space_divisor(_), range, range(1,1000000,1)).
attribute(space_unit, label, <<"Length unit">>).
attribute(space_unit, options, [option(<<"mm">>,<<"Millimetres">>),option(<<"cm">>,<<"Centimetres">>),
    option(<<"m">>,<<"Metres">>),option(<<"km">>,<<"Kilometres">>)]).
attribute(space_create_submit, label, <<"Create">>).
gui_children(space_create(Extent), Children) :-
    space_form_lengths(Extent,Fields,_),
    findall(Role,member(field(Role,_),Fields),Lengths),
    append([space_name|Lengths], [space_placement,space_exterior(Extent),space_create_submit], Children).
gui_initial(space_create(_), space_name, Name) :- have_attribute(space,name,binary,default(Name)).
gui_initial(space_create(_), space_placement, near_agent).
gui_initial(space_create(_), space_exterior(_), solid).
gui_initial(space_create(Extent), space_unit, Unit) :-
    member(Extent,[finite,exact]),
    have_attribute(space,dimensions,space_dimensions,default(box(q(_,Unit),q(_,Unit),q(_,Unit)))).
gui_initial(space_create(Extent), space_length(Axis), Value) :-
    member(Extent,[finite,exact]),
    have_attribute(space,dimensions,space_dimensions,default(box(q(W,_),q(H,_),q(D,_)))),
    member(Axis-Value, [width-W,height-H,depth-D]).
gui_initial(space_create(exact), space_divisor(_), 1).
gui_form(space_create(Extent), Fields,
    submit(space_create_submit, (with_build_plan(Inputs, assert(instance_of(space, Space))),
        space_location(Space,Location),attribute(Space,owner,Owner)),
        operation(create(Inputs), [result(space,entity_ref(Ns,A,Space)),result(location,Location),result(owner,Owner)]))) :-
    current_ontology_identity(Ns,A),
    (space_recipe -> true; fail_with_reason(space_recipe_unavailable)),
    space_form_lengths(Extent,Lengths,Dimensions),
    append([field(space_name,Name)|Lengths], [field(space_placement,Placement),field(space_exterior(Extent),Exterior)], Fields),
    Inputs = [attribute(name,Name),attribute(dimensions,Dimensions),attribute(placement,Placement),attribute(exterior,Exterior)].
space_form_lengths(finite,
    [field(space_length(width),W),field(space_length(height),H),field(space_length(depth),D),field(space_unit,Unit)],
    box(q(W,Unit),q(H,Unit),q(D,Unit))).
space_form_lengths(exact,
    [field(space_length(width),W),field(space_divisor(width),WD),
     field(space_length(height),H),field(space_divisor(height),HD),
     field(space_length(depth),D),field(space_divisor(depth),DD),field(space_unit,Unit)],
    box(q(W/WD,Unit),q(H/HD,Unit),q(D/DD,Unit))).
space_form_lengths(infinite,[],infinite).

%% Pure space depiction, composed with the space vocabulary and ordinary
%% entity Eidolons. Membership and physical bindings stay with their owners.
entity_scene(Space, Mode, appearance(Space, Style, Space, Transform, Eidolons)) :-
    space_instance(Space, space), attribute(Space, transform, Transform),
    attribute(Space, exterior, Style),
    member(Mode, [playing, edition]), entity_eidolons(Space, Mode, Style, Eidolons).
class_eidolon(space, Mode, solid, recipe(Ns, Anchor, space)) :-
    member(Mode, [playing, edition]), current_ontology_identity(Ns, Anchor).
class_eidolon(space, Mode, wireframe, recipe(Ns, Anchor, space_wireframe)) :-
    member(Mode, [playing, edition]), current_ontology_identity(Ns, Anchor).
class_eidolon(space, Mode, contents, recipe(Ns, Anchor, space_contents)) :-
    member(Mode, [playing, edition]), current_ontology_identity(Ns, Anchor).
space_exterior(solid).
space_exterior(wireframe).
space_exterior(contents).
space_exterior_available(solid,_).
space_exterior_available(contents,_).
space_exterior_available(wireframe,box(_,_,_)).
space_exterior_available(wireframe,infinite) :- fail_with_reason(space_exterior_unavailable(wireframe,infinite)).
%% A half-metre exterior depicts even an infinite interior with finite geometry.
eidolon(space, _,
    [part(<<"space">>, box(500,500,500), transform(0,0,0,0,0,0),
          surface(<<"#6A90D9">>, 0, 700, 0, []), unlabelled, depicts_nothing)]).
eidolon(space_wireframe, Space,
    [part(<<"extent">>, wire_box(W,H,D), transform(0,0,0,0,0,0),
          surface(<<"#6A90D9">>,0,700,1000,[]),unlabelled,depicts_nothing)]) :-
    attribute(Space,dimensions,box(X,Y,Z)),
    findall(measure(N,A),measure_vocabulary(N,A),[measure(Ns,Anchor)]),
    space_millimetres(Ns,Anchor,X,W), space_millimetres(Ns,Anchor,Y,H), space_millimetres(Ns,Anchor,Z,D).
space_millimetres(Ns,Anchor,q(Value,Unit),Length) :-
    Ns::(current_ontology_identity(Ns,Anchor),convert(Value,Unit,<<"mm">>,Length)).
%% A selected contents recipe is explicit until M3 supplies recursive exposure.
%% It must never become a successful cube or wireframe substitute.
eidolon(space_contents, _, Parts) :- space_eidolon_status(<<"Contents unavailable">>,Parts).

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

space_entity_pose(Space,Subject,Layout,Pose) :-
    (space_placement(Space,Subject,Assignment), space_instance(Space,physical_space) ->
        findall(binding(B,R),physics_body_definition(Space,B,R,_,_,live(Subject,Assignment,_,_)),
                [binding(Body,Revision)]), Pose = body_pose(Body,Revision)
    ; Layout = transform(_,_,_,_,_,_), Pose = Layout).

space_entity_model([recipe(Ns,A,Recipe)],Context,Model) :-
    Ns::(current_ontology_identity(Ns,A),eidolon(Recipe,Context,Model)).
space_entity_model([],_,Parts) :- space_eidolon_status(<<"No matching eidolon">>,Parts).
space_entity_model([_,_|_],_,Parts) :- space_eidolon_status(<<"Choose an eidolon">>,Parts).
space_eidolon_status(Text,
    [part(<<"eidolon-status">>,group,transform(0,0,0,0,0,0),
          no_surface,label(Text,<<"above">>),depicts_nothing)]).

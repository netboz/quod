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
isa(physical_space, space).

%% Interior lengths are independent of the exterior model and resource policy.
have_attribute(space, name, binary, default(<<"Space">>)).
have_attribute(space, dimensions, space_dimensions,
    default(box(q(100, <<"m">>), q(100, <<"m">>), q(100, <<"m">>)))).
have_attribute(space, owner, space_owner, default_from(space_creator_owner)).
%% Consumed by construction; the assignment remains the sole location record.
have_attribute(space, placement, space_initial_placement).
have_attribute(space, exterior, space_exterior, default(solid)).
%% The same boundary recipes seen from inside: the interior frame is the
%% space's own frame, so the boundary mark at its origin is the room's walls.
have_attribute(space, interior, space_interior, default(none)).
have_part(space, initial_occupants).

%% The pin certifies the composed source, not a remote constructor or class alias.
space_recipe :-
    unique_solution((space_vocabulary(Ns,Anchor),space_source_digest(Digest))),
    in_ontology(Ns,Anchor,space_template_hash(Digest)).

space_dimensions(infinite).
space_dimensions(box(Width, Height, Depth)) :-
    unique_solution(measure_vocabulary(Ns,Anchor)),
    space_length(Ns, Anchor, Width), space_length(Ns, Anchor, Height),
    space_length(Ns, Anchor, Depth).
space_length(Ns, Anchor, q(Value, Unit)) :-
    binary(Unit),
    in_ontology(Ns,Anchor, convert(Value, Unit, <<"m">>, Metres)),
    (integer(Metres) -> Metres > 0
    ; Metres = N / D, integer(N), integer(D), N > 0, D > 0).

space_owner(agent_instance_ref(Ns, Anchor, Entity)) :-
    binary(Ns), binary(Anchor), term_variables(Entity, []).
space_creator_owner(_, Owner) :-
    current_principal(agent_instance_ref(Ns, Anchor, _)),
    in_ontology(Ns,Anchor, personal_agent_owner(Owner)).

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
      in_ontology(Ns,Anchor, space_location(Agent, Location)),
      space_near_location(Location, Dimensions, Placement)),
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
    in_ontology(Ns,Anchor,(
         space_assignment(Entity, Revision, none),
         space_place(Entity, Revision, Destination))),
    space_place_initial(Rest, Destination).

%% A successful owner read explicitly distinguishes absence from failure.
%% Missing/ambiguous pose on a placed agent refuses creation, never unplaces it.
space_location(Entity, Location) :-
    instance_of(_, Entity), space_assignment(Entity, _, Destination),
    (Destination == none -> Location = unplaced
    ; unique_solution(attribute(Entity,transform,Transform)),
      space_transform(Transform), Location = placed(Destination, Transform)).
%% A new space appears in front of the agent (towards -Z, the agent's facing
%% at rest), its near wall at arm's reach plus a step: 2 m from the agent's
%% position (Yan's choice, 2026-11-07), so nothing opens onto the human's face.
space_near_location(unplaced, _, unplaced).
space_near_location(placed(Destination, transform(X,Y,Z,RX,RY,RZ)), Dimensions,
                   placed(Destination, transform(X,Y,NearZ,RX,RY,RZ))) :-
    space_half_depth(Dimensions, HalfDepth),
    NearZ is Z - 2000 - HalfDepth.
space_half_depth(infinite, 0).
space_half_depth(box(_, _, q(Value, Unit)), HalfDepth) :-
    unique_solution(measure_vocabulary(Ns, Anchor)),
    in_ontology(Ns, Anchor, convert(Value, Unit, <<"m">>, Metres)),
    (integer(Metres) -> HalfDepth is Metres * 500
    ; Metres = N / D, HalfDepth is (N * 500) // D).


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

space_contain(Space, Subject) :-
    term_variables([Space, Subject], []),
    Subject = entity_ref(Ns, Anchor, Entity),
    transaction((
        space_instance(Space, space), current_principal(Principal),
        current_ontology_identity(Here, History),
        Destination = entity_ref(Here, History, Space),
        Subject \== Destination,
        space_authorized(Space, space_admit, Subject, display),
        in_ontology(Ns,Anchor,
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
      in_ontology(Ns,Anchor,
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
        in_ontology(Ns,Anchor,
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
        in_ontology(Ns,Anchor,
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
        in_ontology(Ns,Anchor,
             space_release_placement(Space, entity_ref(Here, History, Entity),
                                     ExpectedRevision, Revision)))).

space_release_placement(Space, Subject, Before, Revision) :-
    term_variables([Space, Subject, Before, Revision], []),
    Subject = entity_ref(Ns, Anchor, Entity), Revision is Before + 1,
    transaction((
        space_removal_allowed(Space, Subject, placement),
        in_ontology(Ns,Anchor,
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

%% Travel composes the existing withdrawal/admission in one savepoint. The
%% source slot and both destinations participate in the same atomic write.
%% The requested return is exact; storage and display do not imply a parent.
space_travel(Entity, Expected, Before, After, Revision) :-
    term_variables([Entity,Expected,Before,After], []),
    (After = unplaced -> Destination = none
    ; After = placed(Destination,Pose), space_transform(Pose)),
    (Before \== Destination -> true
    ; fail_with_reason(space_destination_unchanged(Entity))),
    transaction((
        space_expected_assignment(Entity,Expected,Before),
        (Before == none -> Empty = Expected
        ; space_authorized(Entity,space_leave,Before,placement),
          space_withdraw(Entity,Expected,Before), Empty is Expected + 1),
        (Destination == none -> Revision = Empty
        ; unique_solution(attribute(Entity,transform,PreviousPose)),
          retract(attribute(Entity,transform,PreviousPose)),
          assertz(attribute(Entity,transform,Pose)),
          space_place(Entity,Empty,Destination), Revision is Empty + 1))).

space_change_physics(Space, Subject, Change) :-
    %% Retained live bindings still require cleanup after destination type edits.
    ((space_instance(Space, physical_space)
      ; space_simulation_domain(Space,_,_,_)
      ; Change == withdrawn,
        physics_body_definition(Space,_,_,_,_,live(Subject,_,_,_))) ->
        (space_physical_change(Space, Subject, Change) -> true
        ; fail_with_reason(space_physical_change_refused(Space, Change)))
    ; true).

%% Composition supplies policy and the physical lifecycle consequence. No
%% missing hook silently skips constraint/checkpoint or pending-work cleanup.
space_physical_change(_, _, _) :- fail.

%% Representation edits compare their exact source values. A destination's
%% installed physical component changes in this same transaction, if present.
space_represent(Space,BeforeStyle,BeforePose,BeforeInterior,Style,Pose,Interior) :-
    term_variables([Space,BeforeStyle,BeforePose,BeforeInterior,Style,Pose,Interior],[]),
    transaction((space_instance(Space,space),space_transform(Pose),space_exterior(Style),space_interior(Interior),
        space_authorized_representation(Space,BeforeStyle,BeforePose,BeforeInterior,Style,Pose,Interior),
        unique_solution((attribute(Space,exterior,PriorStyle),attribute(Space,transform,PriorPose))),
        PriorStyle = BeforeStyle, PriorPose = BeforePose, space_interior_of(Space,BeforeInterior),
        attribute(Space,dimensions,Dimensions),space_exterior_available(Style,Dimensions),
        space_exterior_available(Interior,Dimensions),
        %% The interior changes only this space's own view; no parent sees it.
        (BeforeInterior == Interior -> true
        ; (BeforeInterior == none -> true; retract(attribute(Space,interior,BeforeInterior))),
          (Interior == none -> true; assertz(attribute(Space,interior,Interior)))),
        (BeforeStyle == Style, BeforePose == Pose -> true
        ; retract(attribute(Space,exterior,BeforeStyle)),assertz(attribute(Space,exterior,Style)),
        retract(attribute(Space,transform,BeforePose)),assertz(attribute(Space,transform,Pose)),
        space_assignment(Space,_,Destination),
        (Destination == none -> true
        ; Destination = entity_ref(Ns,A,Parent),current_ontology_identity(Here,History),
          in_ontology(Ns,A,
               space_representation_changed(Parent,entity_ref(Here,History,Space))))))).
space_authorized_representation(Space,BeforeStyle,BeforePose,BeforeInterior,Style,Pose,Interior) :-
    operation_authorized(instance(Space),
        space_represent(BeforeStyle,BeforePose,BeforeInterior,Style,Pose,Interior)).
%% An absent interior is the class default; two values are refused.
space_interior_of(Space,Interior) :-
    findall(I,attribute(Space,interior,I),Rows),
    (Rows = [] -> Interior = none
    ; Rows = [Interior] -> true
    ; fail_with_reason(ambiguous_space_interior(Space))).
space_interior_boundary(Space,Recipe) :-
    space_interior_of(Space,Interior), Interior \== none, space_exterior_recipe(Interior,Recipe).
space_representation_changed(Space,Subject) :-
    space_placement(Space,Subject,Assignment),current_ontology_identity(Ns,A),
    Subject = entity_ref(Source,Anchor,Entity),
    in_ontology(Source,Anchor,
              space_assignment(Entity,Assignment,entity_ref(Ns,A,Space))),
    space_change_physics(Space,Subject,represented).

%% Authored Create forms. The shared GUI binder invokes the normal assertion;
%% the space constructor and committed class policy own every consequence.
class_eidolon(space,operation(class),Name,recipe(Ns,A,Recipe)) :-
    space_creation_recipe(Name,Recipe,_), current_ontology_identity(Ns,A).
eidolon(Recipe,subject(ontology_ref(Ns,A),class(space)),operation(space_create(Extent))) :-
    space_creation_recipe(_,Recipe,Extent), current_ontology_identity(Ns,A).
space_creation_recipe(create,space_create,finite).
space_creation_recipe(create_exact,space_create_exact,exact).
space_creation_recipe(create_infinite,space_create_infinite,infinite).

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
attribute(space_create(finite), image, Icon) :- space_icon(create_finite, Icon).
attribute(space_create(exact), image, Icon) :- space_icon(create_exact, Icon).
attribute(space_create(infinite), image, Icon) :- space_icon(create_infinite, Icon).
%% The GUI vocabulary's icon catalogue, by name.
space_icon(Name, Icon) :- menu_vocabulary(Gui, GuiAnchor), in_ontology(Gui, GuiAnchor, gui_icon(Name, Icon)).
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
    [option(solid,<<"Small solid cube">>),option(wireframe,<<"Full-size finite wireframe">>),
     option(contents,<<"Permitted contents">>)]) :- member(Extent,[finite,exact]).
attribute(space_exterior(infinite), options,
    [option(solid,<<"Small solid cube">>),option(contents,<<"Permitted contents">>) ]).
attribute(space_exterior(Extent), help, <<"Wireframe shows the exact interior dimensions without collision. Contents exposes permitted sources in their authored frames.">>) :- member(Extent,[finite,exact]).
attribute(space_exterior(infinite), help, <<"Infinite extent has no finite wireframe. Solid and permitted contents representations are available.">>).
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

%% Entry is another exact-subject offered operation. Its frozen source slot
%% enters the ordinary form revision; a stale offer cannot move a newer slot.
class_eidolon(space,operation(instance),enter,recipe(Ns,A,space_enter)) :-
    current_ontology_identity(Ns,A).
class_eidolon(space,operation(instance),leave,recipe(Ns,A,space_leave)) :-
    current_ontology_identity(Ns,A).
eidolon(space_enter,subject(ontology_ref(Ns,A),instance(Space)),operation(Form)) :-
    current_ontology_identity(Ns,A),
    space_travel_context(Agent,Revision,Before),
    Destination = entity_ref(Ns,A,Space), Before \== Destination,
    Form = space_travel_form(Agent,Revision,Before,
                            placed(Destination,transform(0,0,0,0,0,0))).
eidolon(space_leave,subject(ontology_ref(Ns,A),instance(Space)),operation(Form)) :-
    current_ontology_identity(Ns,A),
    space_travel_context(Agent,Revision,entity_ref(Ns,A,Space)),
    Form = space_travel_form(Agent,Revision,entity_ref(Ns,A,Space),unplaced).
space_travel_context(Agent,Revision,Before) :-
    current_principal(agent_instance_ref(Ns,A,_)),
    in_ontology(Ns,A,space_travel_agent(Agent)),
    Agent = agent_instance_ref(Source,Anchor,Entity),
    in_ontology(Source,Anchor,space_assignment(Entity,Revision,Before)).
instance_of(quod:gui:form,space_travel_form(_,_,_,_)).
instance_of(quod:gui:button,space_travel_submit).
attribute(space_travel_form(_,_,_,placed(_,_)),label,<<"Enter space">>).
attribute(space_travel_form(_,_,_,unplaced),label,<<"Leave space">>).
attribute(space_travel_form(_,_,_,placed(_,_)),image,Icon) :- space_icon(enter,Icon).
attribute(space_travel_form(_,_,_,unplaced),image,Icon) :- space_icon(leave,Icon).
attribute(space_travel_form(_,_,_,_),help,
    <<"Move the same personal agent. Navigation follows the committed location. Leaving without a destination makes the agent unplaced.">>).
attribute(space_travel_submit,label,<<"Move">>).
gui_children(space_travel_form(_,_,_,_),[space_travel_submit]).
gui_form(space_travel_form(Agent,Expected,Before,After),[],
    submit(space_travel_submit,
        in_ontology(Source,Anchor,
                 space_travel(Entity,Expected,Before,After,Revision)),
        operation(space_visit(Agent,Destination),
            [result(agent,Agent),result(location,After),result(revision,Revision)]))) :-
    Agent = agent_instance_ref(Source,Anchor,Entity),
    (After = unplaced -> Destination = none; After = placed(Destination,_)).

%% The space's own pie overrides the default. Fixed wedges keep paths
%% learnable: Create here at the top, Show as and Inspect clockwise, Leave on
%% the bottom wedge asking for a second press. "Go to" offers this storage's
%% contained spaces, so a far child stays reachable without pointing at it.
class_eidolon(space,menu,default,recipe(Ns,A,space_menu)) :- current_ontology_identity(Ns,A).
%% The class itself is not a space: it keeps the shared default pie, whose
%% leaves are its creation forms.
eidolon(space_menu,subject(Target,space),View) :- !,
    menu_vocabulary(Gui,GuiAnchor),
    in_ontology(Gui,GuiAnchor,eidolon(default_menu,subject(Target,space),View)).
eidolon(space_menu,subject(ontology_ref(Ns,A),Space),menu(Tree)) :-
    current_ontology_identity(Ns,A), space_instance(Space,space),
    gui_menu_source(Space,menu_source(Name,Own)),
    gui_menu_source(space,menu_source(_,Class)),
    gui_menu_source(ontology_ref(Ns,A),menu_source(_,Storage)),
    findall(Item,(member(Item,Own),space_menu_shows(Item)),Shows),
    findall(Item,(member(Offered,Own),\+ space_menu_shows(Offered),space_menu_action(Offered,Item)),Actions),
    findall(Item,space_menu_destination(Space,Ns,A,Item),Destinations),
    space_icon(create_here,CreateIcon), space_icon(show_as,ShowIcon), space_icon(inspect,InspectIcon), space_icon(go_to,GoIcon),
    append([group(<<"Create here">>,[slot(1),image(CreateIcon)],[operation(class)],Class),
            group(<<"Show as">>,[slot(2),image(ShowIcon)],[operation(instance)],Shows),
            group(<<"Inspect">>,[slot(3),image(InspectIcon)],[prolog,inspection,workspace],Storage)|Actions],
           [group(<<"Go to">>,[],[operation(instance)],Destinations)],Entries),
    (binary(Name), Name \== <<"">> -> Title = Name; Title = <<"Space">>),
    menu_vocabulary(Gui,GuiAnchor),
    in_ontology(Gui,GuiAnchor,menu_tree(menu(Title,<<"">>,[],Entries),Tree)).
space_menu_shows(item(choice(_,eidolon(operation(instance),Name,_)),_,_,_,_)) :- space_show_recipe(Name,_,_).
space_menu_action(item(T,L,H,Av,_),item(T,L,H,Av,[slot(5),confirm(true)])) :-
    T = choice(_,eidolon(operation(instance),leave,_)), !.
space_menu_action(Item,Item) :- Item = item(choice(_,eidolon(operation(_),_,_)),_,_,_,_).
space_menu_destination(Space,Ns,A,item(T,Label,H,Av,[])) :-
    space_contains(Space,entity_ref(Ns,A,Child)), Child \== Space, space_instance(Child,space),
    gui_menu_source(Child,menu_source(ChildName,Items)),
    member(item(T,Offered,H,Av,_),Items), T = choice(_,eidolon(operation(instance),enter,_)),
    (binary(ChildName), ChildName \== <<"">> -> Label = ChildName; Label = Offered).

%% Show as: this space's interior choices as offered actions without input
%% fields, each through the one representation operation.
class_eidolon(space,operation(instance),Name,recipe(Ns,A,Recipe)) :-
    space_show_recipe(Name,Recipe,_), current_ontology_identity(Ns,A).
space_show_recipe(show_none,space_show_none,none).
space_show_recipe(show_wireframe,space_show_wireframe,wireframe).
space_show_recipe(show_matrix,space_show_matrix,matrix).
eidolon(Recipe,subject(ontology_ref(Ns,A),instance(Space)),operation(space_show_form(Space,Style,Pose,Before,Interior))) :-
    space_show_recipe(_,Recipe,Interior), current_ontology_identity(Ns,A), space_instance(Space,space),
    unique_solution((attribute(Space,exterior,Style),attribute(Space,transform,Pose))),
    space_interior_of(Space,Before), Before \== Interior,
    attribute(Space,dimensions,Dimensions), space_exterior_available(Interior,Dimensions).
instance_of(quod:gui:form,space_show_form(_,_,_,_,_)).
instance_of(quod:gui:button,space_show_submit).
attribute(space_show_form(_,_,_,_,none),label,<<"No walls inside">>).
attribute(space_show_form(_,_,_,_,wireframe),label,<<"Wire box walls">>).
attribute(space_show_form(_,_,_,_,matrix),label,<<"Matrix walls">>).
attribute(space_show_form(_,_,_,_,none),image,Icon) :- space_icon(show_none,Icon).
attribute(space_show_form(_,_,_,_,wireframe),image,Icon) :- space_icon(wireframe,Icon).
attribute(space_show_form(_,_,_,_,matrix),image,Icon) :- space_icon(matrix,Icon).
attribute(space_show_form(_,_,_,_,_),help,<<"Changes how this space looks from inside. Nothing moves.">>).
attribute(space_show_submit,label,<<"Show">>).
gui_children(space_show_form(_,_,_,_,_),[space_show_submit]).
gui_form(space_show_form(Space,Style,Pose,Before,After),[],
    submit(space_show_submit,space_represent(Space,Style,Pose,Before,Style,Pose,After),
        operation(space_represent(Style,Pose,Before,Style,Pose,After),[]))).

%% Pure space depiction, composed with the space vocabulary and ordinary
%% entity Eidolons. Membership and physical bindings stay with their owners.
class_eidolon(space,Mode,contents,recipe(Ns,A,space_contents)) :-
    member(Mode,[playing,edition]), current_ontology_identity(Ns,A).
class_eidolon(space,Mode,Style,recipe(Ns,Anchor,Recipe)) :-
    member(Mode,[playing,edition]), space_exterior_recipe(Style,Recipe),
    current_ontology_identity(Ns,Anchor).
space_exterior_recipe(solid,space).
space_exterior_recipe(wireframe,space_wireframe).
space_exterior_recipe(matrix,space_matrix).
space_interior(none).
space_interior(wireframe).
space_interior(matrix).
space_exterior(solid).
space_exterior(wireframe).
space_exterior(contents).
space_exterior_available(solid,_).
space_exterior_available(contents,_).
space_exterior_available(wireframe,box(_,_,_)).
space_exterior_available(wireframe,infinite) :- fail_with_reason(space_exterior_unavailable(wireframe,infinite)).
space_exterior_available(none,_).
space_exterior_available(matrix,box(_,_,_)).
space_exterior_available(matrix,infinite) :- fail_with_reason(space_exterior_unavailable(matrix,infinite)).
%% A half-metre exterior depicts even an infinite interior with finite geometry.
eidolon(space, Space,
    [part(<<"space">>, box(500,500,500), transform(0,0,0,0,0,0),
          surface(<<"#6A90D9">>, 0, 700, 0, 1000, []), Label, depicts_nothing)]) :-
    client_subject_label(Space,Label).
eidolon(space_wireframe, Space,
    [part(<<"extent">>, wire_box(W,H,D), transform(0,0,0,0,0,0),
          surface(<<"#6A90D9">>,0,700,1000,1000,[]),Label,depicts_nothing)]) :-
    client_subject_label(Space,Label),
    attribute(Space,dimensions,box(X,Y,Z)),
    unique_solution(measure_vocabulary(Ns,Anchor)),
    space_millimetres(Ns,Anchor,X,W), space_millimetres(Ns,Anchor,Y,H), space_millimetres(Ns,Anchor,Z,D).
%% Matrix walls: the exact wire box in emissive green over translucent
%% near-black faces, drawn from both sides so they read from in and out.
eidolon(space_matrix, Space,
    [part(<<"walls">>, box(WI,HI,DI), transform(0,0,0,0,0,0),
          surface(<<"#030F08">>,0,900,80,220,[]), unlabelled, depicts_nothing),
     part(<<"grid">>, wire_box(W,H,D), transform(0,0,0,0,0,0),
          surface(<<"#3CFF7A">>,0,700,1000,1000,[]), Label, depicts_nothing)]) :-
    client_subject_label(Space,Label),
    attribute(Space,dimensions,box(X,Y,Z)),
    unique_solution(measure_vocabulary(Ns,Anchor)),
    space_millimetres(Ns,Anchor,X,W), space_millimetres(Ns,Anchor,Y,H), space_millimetres(Ns,Anchor,Z,D),
    space_whole_mm(W,WI), space_whole_mm(H,HI), space_whole_mm(D,DI).
space_whole_mm(N/D,Whole) :- !, Whole is max(1,(N + D // 2) // D).
space_whole_mm(Length,Length).
space_millimetres(Ns,Anchor,q(Value,Unit),Length) :-
    in_ontology(Ns,Anchor,convert(Value,Unit,<<"mm">>,Length)).

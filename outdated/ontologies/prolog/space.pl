%% Governed space vocabulary, composed into the ontologies owning its facts.
%% No ACL grants, native modules, actors or resource selectors are installed.
isa(space, thing).
isa(physical_space, space).

%% Interior lengths are independent of the exterior model and resource policy.
have_attribute(space, name, binary, default(<<"Space">>)).
have_attribute(space, dimensions, space_dimensions,
    default(box(q(100, <<"m">>), q(100, <<"m">>), q(100, <<"m">>)))).
have_attribute(space, owner, space_owner, default_from(space_creator_owner)).
%% Consumed by construction; the assignment remains the sole location record.
have_attribute(space, placement, space_initial_placement).

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
space_initial_placement(at(entity_ref(Ns, Anchor, Entity), Transform)) :-
    binary(Ns), binary(Anchor), term_variables(Entity, []), space_transform(Transform).
space_transform(transform(X, Y, Z, RX, RY, RZ)) :-
    integer(X), integer(Y), integer(Z), integer(RX), integer(RY), integer(RZ).

constructor(space, Space, _) :-
    (retract(attribute(Space, placement, Requested)) -> true; Requested = near_agent),
    (Requested = at(Destination, Pose) -> Placement = placed(Destination, Pose)
    ; Requested = near_agent, current_principal(agent_instance_ref(Ns, Anchor, Agent)),
      Ns::(current_ontology_identity(Ns, Anchor), space_location(Agent, Location)),
      space_near_location(Location, Placement)),
    (Placement = unplaced -> Pose = transform(0,0,0,0,0,0)
    ; Placement = placed(Destination, Pose), space_place(Space, 0, Destination)),
    assertz(attribute(Space, transform, Pose)).

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

%% Governed space vocabulary, composed into the ontologies owning its facts.
%% No ACL grants, native modules, actors or resource selectors are installed.
isa(space, thing).
isa(physical_space, space).

space_instance(Space, Class) :-
    once((instance_of(Direct, Space), isa(Direct, Class))).

space_subject(Subject) :-
    once((instance_of(_, Subject); isa(Subject, Subject))).

%% Organizational membership is many-to-many. The destination owns this fact;
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
        can_admit_space_member(Space, Principal, Subject, organizational),
        Ns::(current_ontology_identity(Ns, Anchor),
             space_consent(Entity, Principal, Destination, organizational)),
        \+ space_member(Space, Subject),
        assertz(space_member(Space, Subject)))).

space_consent(Entity, Principal, Destination, Mode) :-
    current_principal(Principal), space_subject(Entity),
    can_enter_space(Entity, Principal, Destination, Mode).

%% Either owner can end organizational membership. Revoking a future-entry
%% grant alone does not erase an existing relation: use this same transition.
space_remove(Space, Subject) :-
    term_variables([Space, Subject], []),
    transaction((
        space_removal_allowed(Space, Subject, organizational),
        retract(space_member(Space, Subject)))).

space_removal_allowed(Space, Subject, Mode) :-
    current_principal(Principal),
    (can_remove_space_member(Space, Principal, Subject, Mode) -> true
    ; Subject = entity_ref(Ns, Anchor, Entity),
      current_ontology_identity(Here, History),
      Ns::(current_ontology_identity(Ns, Anchor),
           space_withdrawal_consent(Entity, Principal,
                                    entity_ref(Here, History, Space), Mode))).

space_withdrawal_consent(Entity, Principal, Destination, Mode) :-
    current_principal(Principal),
    can_leave_space(Entity, Principal, Destination, Mode).

%% The instance ontology is the designated exclusive-assignment owner. Keep
%% the revision after withdrawal: a stale admission cannot reuse an empty slot.
space_assignment(Entity, Revision, Destination) :-
    findall(assignment(R, D), physical_assignment(Entity, R, D), Rows),
    (Rows = [] -> Revision = 0, Destination = none
    ; Rows = [assignment(Revision, Destination)]).

space_place(Entity, ExpectedRevision, Destination) :-
    term_variables([Entity, ExpectedRevision, Destination], []),
    Destination = entity_ref(Ns, Anchor, Space),
    transaction((
        current_principal(Principal), instance_of(_, Entity),
        can_enter_space(Entity, Principal, Destination, physical),
        space_assignment(Entity, ExpectedRevision, none),
        space_assign(Entity, ExpectedRevision, none, Destination, Revision),
        current_ontology_identity(Here, History),
        Ns::(current_ontology_identity(Ns, Anchor),
             space_accept_placement(Space, entity_ref(Here, History, Entity), Revision)))).

%% This participant entry requires the assignment staged by space_place/3.
%% Calling it alone cannot allocate a slot or complete half a transition.
space_accept_placement(Space, Subject, Revision) :-
    term_variables([Space, Subject, Revision], []),
    Subject = entity_ref(Ns, Anchor, Entity),
    transaction((
        space_instance(Space, physical_space), current_principal(Principal),
        current_ontology_identity(Here, History),
        can_admit_space_member(Space, Principal, Subject, physical),
        Ns::(current_ontology_identity(Ns, Anchor),
             space_assignment(Entity, Revision, entity_ref(Here, History, Space))),
        \+ space_placement(Space, Subject, _),
        space_physical_change(Space, Subject, admitted),
        assertz(space_placement(Space, Subject, Revision)))).

%% A destination eviction and an instance-owner withdrawal use the same path.
%% Admission accepts that the destination may revoke it under its own policy.
space_withdraw(Entity, ExpectedRevision, Destination) :-
    term_variables([Entity, ExpectedRevision, Destination], []),
    Destination = entity_ref(Ns, Anchor, Space),
    transaction((
        space_assignment(Entity, ExpectedRevision, Destination),
        space_assign(Entity, ExpectedRevision, Destination, none, Revision),
        current_ontology_identity(Here, History),
        Ns::(current_ontology_identity(Ns, Anchor),
             space_release_placement(Space, entity_ref(Here, History, Entity),
                                     ExpectedRevision, Revision)))).

space_release_placement(Space, Subject, Before, Revision) :-
    term_variables([Space, Subject, Before, Revision], []),
    Subject = entity_ref(Ns, Anchor, Entity), Revision is Before + 1,
    transaction((
        space_removal_allowed(Space, Subject, physical),
        Ns::(current_ontology_identity(Ns, Anchor),
             space_assignment(Entity, Revision, none)),
        space_physical_change(Space, Subject, withdrawn),
        retract(space_placement(Space, Subject, Before)))).

space_assign(Entity, Before, Old, New, Revision) :-
    integer(Before), Before >= 0,
    (Before = 0, Old = none -> true
    ; retract(physical_assignment(Entity, Before, Old))),
    Revision is Before + 1,
    assertz(physical_assignment(Entity, Revision, New)).

%% Composition supplies policy and the physical lifecycle consequence. No
%% missing hook silently skips constraint/checkpoint or pending-work cleanup.
can_admit_space_member(_, _, _, _) :- fail.
can_remove_space_member(_, _, _, _) :- fail.
can_enter_space(_, _, _, _) :- fail.
can_leave_space(_, _, _, _) :- fail.
space_physical_change(_, _, _) :- fail.

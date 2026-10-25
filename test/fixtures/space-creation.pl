%% Policies composed only by the signed creation fixture.
class_permission(space, create, check(creation_permission)).
class_requirement(space, create, creation_requirement).
class_permission(space, space_enter, check(creation_entry)).
class_permission(agent, space_enter, check(creation_entry)).
class_permission(space, space_admit, check(creation_admission)).
class_permission(space, space_remove, allow).
class_permission(space, space_leave, allow).
class_permission(agent, space_leave, allow).
creation_permission(Actor, class(_), create(Inputs)) :-
    creation_actor(Actor), creation_enabled,
    (member(attribute(owner, Owner), Inputs) -> allowed_creation_owner(Owner); true).
creation_requirement(_, _, _) :- creation_requirement_enabled.
creation_entry(Actor, construction(_, _, Inputs), space_enter(_, _, placement)) :-
    creation_actor(Actor), entry_enabled, term_variables(Inputs, []).
creation_entry(Actor, instance(personal), space_enter(_, _, placement)) :- creation_actor(Actor).
creation_admission(Actor, instance(room), space_admit(_, _, placement)) :-
    creation_actor(Actor), admission_enabled.
creation_enabled.
creation_requirement_enabled.
entry_enabled.
admission_enabled.
instance_of(space, room).
instance_of(space, closed).

creation_result(Inputs, Ref, Name) :-
    with_build_plan(Inputs, assert(instance_of(space, Space))),
    current_ontology_identity(Ns, Anchor), Ref = entity_ref(Ns, Anchor, Space),
    attribute(Space, name, Name).

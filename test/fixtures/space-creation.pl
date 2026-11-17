%% The storing fixture holds instances and ACLs. Shared class behavior lives
%% only at quod:space; creation and placement compose in one transaction.
instance_of(quod:space:space, room).
instance_of(quod:space:space, closed).
instance_permission(closed, space_admit, deny).

creation_result(Inputs, Placement, Ref, Name) :-
    creation_result(Inputs, Placement, none, Ref, Name).
creation_result(Inputs, Placement, View, Ref, Name) :-
    transaction((
        with_build_plan(Inputs, assert(instance_of(quod:space:space, Space))),
        current_ontology_identity(Ns, Anchor), Ref = entity_ref(Ns, Anchor, Space),
        quod:space::space_form_placement(Ref, Placement, View, _),
        attribute(Space, name, Name))).

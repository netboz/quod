isa(test_space, quod:space:space).
creation_enabled.
class_requirement(test_space, create, creation_enabled_check).
creation_enabled_check(_, _, _) :- creation_enabled.

%% Explicit offers reuse normal Eidolon selection; action/3 is not discovery.
class_eidolon(test_space, operation(class), create, recipe(Ns, Anchor, space_create)) :-
    current_ontology_identity(Ns, Anchor).
class_eidolon(test_space, operation(instance), withdraw, recipe(Ns, Anchor, space_withdraw)) :-
    current_ontology_identity(Ns, Anchor).

eidolon(space_create, subject(ontology_ref(Ns, Anchor), class(test_space)), operation(space_create)) :-
    current_ontology_identity(Ns, Anchor).
eidolon(space_withdraw, subject(ontology_ref(Ns, Anchor), instance(Space)), operation(withdraw(Space))) :-
    current_ontology_identity(Ns, Anchor), instance_of(test_space, Space).

instance_of(quod:gui:form, space_create).
instance_of(quod:gui:text_box, example_name).
instance_of(quod:gui:selection, space_extent).
instance_of(quod:gui:button, create).
attribute(space_create, label, <<"Create space">>).
attribute(space_create, help, <<"Create in the selected ontology using its class defaults.">>).
attribute(example_name, label, <<"Name">>).
attribute(example_name, required, true).
attribute(space_extent, label, <<"Interior">>).
attribute(space_extent, options, [option(infinite, <<"Infinite">>),
    option(box(q(10, <<"m">>), q(10, <<"m">>), q(10, <<"m">>)), <<"10 metres">>)]).
attribute(create, label, <<"Create">>).
gui_children(space_create, [example_name, space_extent, create]).
gui_initial(space_create, example_name, <<"Space">>).
gui_initial(space_create, space_extent, Extent) :-
    quod:space::have_attribute(space, dimensions, space_dimensions, default(Extent)).
gui_form(space_create, [field(example_name, Name), field(space_extent, Extent)],
    submit(create, with_build_plan(Inputs, assert(instance_of(test_space, Space))),
           operation(create(Inputs), [result(space, entity_ref(Ns, Anchor, Space))]))) :-
    Inputs = [attribute(name, Name), attribute(dimensions, Extent)],
    current_ontology_identity(Ns, Anchor).

instance_of(quod:gui:form, withdraw(Space)) :- instance_of(test_space, Space).
instance_of(quod:gui:selection, destination(Space)) :- instance_of(test_space, Space).
instance_of(quod:gui:button, withdraw_button(Space)) :- instance_of(test_space, Space).
attribute(withdraw(Space), label, <<"Withdraw space">>) :- instance_of(test_space, Space).
attribute(destination(Space), label, <<"Current destination">>) :- instance_of(test_space, Space).
attribute(destination(Space), readonly, true) :- instance_of(test_space, Space).
attribute(destination(Space), options, [option(Destination, <<"Current space">>)]) :-
    current_ontology_identity(Ns, A),
    quod:space::space_assignment(entity_ref(Ns,A,Space), _, Destination), Destination \== none.
attribute(withdraw_button(Space), label, <<"Withdraw">>) :- instance_of(test_space, Space).
gui_children(withdraw(Space), [destination(Space), withdraw_button(Space)]).
gui_initial(withdraw(Space), destination(Space), Destination) :-
    current_ontology_identity(Ns, A),
    quod:space::space_assignment(entity_ref(Ns,A,Space), _, Destination), Destination \== none.
gui_form(withdraw(Space), [field(destination(Space), Destination)],
    submit(withdraw_button(Space), quod:space::goal(unplaced(Ref)),
           operation(space_leave(Ref, Destination, placement), []))) :-
    current_ontology_identity(Ns, Anchor), Ref = entity_ref(Ns, Anchor, Space),
    quod:space::space_assignment(Ref, _, Destination), Destination \== none.

action(assertz(unoffered), [], unoffered).

class_requirement(test_space, create, offered_name_allowed).
offered_name_allowed(_, _, create(Inputs)) :-
    \+ member(attribute(name, <<"Forbidden">>), Inputs).

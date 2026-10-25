%% Explicit offers reuse normal Eidolon selection; action/3 is not discovery.
class_eidolon(space, operation(class), create, recipe(Ns, Anchor, space_create)) :-
    current_ontology_identity(Ns, Anchor).
class_eidolon(space, operation(instance), withdraw, recipe(Ns, Anchor, space_withdraw)) :-
    current_ontology_identity(Ns, Anchor).

eidolon(space_create, subject(ontology_ref(Ns, Anchor), class(space)), operation(space_create)) :-
    current_ontology_identity(Ns, Anchor).
eidolon(space_withdraw, subject(ontology_ref(Ns, Anchor), instance(Space)), operation(withdraw(Space))) :-
    current_ontology_identity(Ns, Anchor), instance_of(space, Space).

instance_of(quod:gui:form, space_create).
instance_of(quod:gui:text_box, space_name).
instance_of(quod:gui:selection, space_extent).
instance_of(quod:gui:button, create).
attribute(space_create, label, <<"Create space">>).
attribute(space_create, help, <<"Create in the selected ontology using its class defaults.">>).
attribute(space_name, label, <<"Name">>).
attribute(space_name, required, true).
attribute(space_extent, label, <<"Interior">>).
attribute(space_extent, options, [option(infinite, <<"Infinite">>),
    option(box(q(100, <<"m">>), q(100, <<"m">>), q(100, <<"m">>)), <<"100 metres">>)]).
attribute(create, label, <<"Create">>).
gui_children(space_create, [space_name, space_extent, create]).
gui_initial(space_create, space_name, Name) :-
    have_attribute(space, name, binary, default(Name)).
gui_initial(space_create, space_extent, Extent) :-
    have_attribute(space, dimensions, space_dimensions, default(Extent)).
gui_form(space_create, [field(space_name, Name), field(space_extent, Extent)],
    submit(create, with_build_plan(Inputs, assert(instance_of(space, Space))),
           operation(create(Inputs), [result(space, entity_ref(Ns, Anchor, Space))]))) :-
    Inputs = [attribute(name, Name), attribute(dimensions, Extent)],
    current_ontology_identity(Ns, Anchor).

instance_of(quod:gui:form, withdraw(Space)) :- instance_of(space, Space).
instance_of(quod:gui:selection, destination(Space)) :- instance_of(space, Space).
instance_of(quod:gui:button, withdraw_button(Space)) :- instance_of(space, Space).
attribute(withdraw(Space), label, <<"Withdraw space">>) :- instance_of(space, Space).
attribute(destination(Space), label, <<"Current destination">>) :- instance_of(space, Space).
attribute(destination(Space), readonly, true) :- instance_of(space, Space).
attribute(destination(Space), options, [option(Destination, <<"Current space">>)]) :-
    space_assignment(Space, _, Destination), Destination \== none.
attribute(withdraw_button(Space), label, <<"Withdraw">>) :- instance_of(space, Space).
gui_children(withdraw(Space), [destination(Space), withdraw_button(Space)]).
gui_initial(withdraw(Space), destination(Space), Destination) :-
    space_assignment(Space, _, Destination), Destination \== none.
gui_form(withdraw(Space), [field(destination(Space), Destination)],
    submit(withdraw_button(Space), space_withdraw(Space, Revision, Destination),
           operation(space_leave(Ref, Destination, placement), []))) :-
    space_assignment(Space, Revision, Destination), Destination \== none,
    current_ontology_identity(Ns, Anchor), Ref = entity_ref(Ns, Anchor, Space).

action(assertz(unoffered), [], unoffered).

class_requirement(space, create, offered_name_allowed).
offered_name_allowed(_, _, create(Inputs)) :-
    \+ member(attribute(name, <<"Forbidden">>), Inputs).

isa(document, thing).
isa(secured, document).
isa(reviewed, document).
isa(report, secured).
isa(report, reviewed).
instance_of(report, report1).
instance_of(report, report2).
class_permission(document, edit, allow).
class_permission(document, create, allow).
class_permission(secured, edit, check(editor)).
class_requirement(secured, edit, limited).
class_requirement(reviewed, edit, reviewed_actor).
class_requirement(secured, create, valid_creation).
class_requirement(reviewed, create, reviewed_actor).
editor(Actor, _, _) :- editor_actor(Actor).
reviewed_actor(Actor, _, _) :- approved_actor(Actor).
limited(_, instance(_), edit(Value)) :- integer(Value), Value > 0, Value < 10.
valid_creation(_, class(_), create(Inputs)) :- Inputs == [attribute(name, <<"Report">>)].
edit_document(Instance, Value) :-
    operation_authorized(instance(Instance), edit(Value)),
    assertz(edited(Instance, Value)).
%% Offered-operation binding is an authored caller here; S1.8 owns GUI metadata.
offered_edit(Instance, Value) :- edit_document(Instance, Value).
constructor_order(report, [secured, reviewed]).
constructor(report, _, _) :- assertz(constructor_ran).

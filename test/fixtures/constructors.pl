%% Test-only composition of S1.4's seams with pre-bound identities. S1.5 owns
%% the assertion hook, identity allocation, authorization and whole-attempt savepoint.
test_initialize(Class, Instance) :-
    '$quod_build_plan'(Inputs),
    '$quod_constructor_plan'(Class, Instance, Inputs, _, Attributes),
    '$quod_initial_attribute_writes'(Instance, Attributes).

isa(vehicle, thing).
isa(car, vehicle).
isa(boat, vehicle).
isa(amphibious, car).
isa(amphibious, boat).
constructor_order(amphibious, [car, boat]).
have_attribute(vehicle, name, binary, default(<<"Vehicle">>)).
have_attribute(vehicle, wheels, integer, default(0)).
have_attribute(car, wheels, integer, default(4)).
isa(trailer, car).
isa(failing_child, car).
constructor(failing_child, _, _) :- fail.
isa(failing_parent, thing).
isa(parent_failure_child, failing_parent).
constructor(failing_parent, _, _) :- fail.
constructor(parent_failure_child, _, _) :- assertz(should_not_run).
isa(head, thing).
isa(eye, thing).
have_attribute(head, name, binary, default(<<"Head">>)).
have_attribute(head, color, atom, default(red)).
have_attribute(eye, name, binary, default(<<"Eye">>)).
have_attribute(eye, color, eye_color, default(blue)).
eye_color(blue).
eye_color(green).
%% The pool provider is tested against the real naming rules with a tiny pool.
isa(place, thing).
have_attribute(place, name, binary, default_from(place_name)).
place_name(I, Name) :- draw(<<"fixture">>, <<"place">>, <<"neutral">>, I, Name).
isa(unsupported_pool, thing).
have_attribute(unsupported_pool, name, binary, default_from(unsupported_name)).
unsupported_name(I, Name) :- draw(<<"fixture">>, <<"machine">>, <<"neutral">>, I, Name).

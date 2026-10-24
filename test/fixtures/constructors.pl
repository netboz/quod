%% Test-only composition of S1.4's seams with pre-bound identities. S1.5 owns
%% the assertion hook, identity allocation, authorization and whole-attempt savepoint.
test_initialize(Class, Instance) :-
    '$quod_build_plan'(Inputs),
    '$quod_constructor_plan'(Class, Instance, Inputs, Order, Attributes),
    '$quod_initial_attribute_writes'(Instance, Attributes),
    '$quod_run_constructors'(Order, Instance, Inputs).

isa(vehicle, thing).
isa(car, vehicle).
isa(boat, vehicle).
isa(amphibious, car).
isa(amphibious, boat).
constructor_order(amphibious, [car, boat]).
have_attribute(vehicle, name, binary, default(<<"Vehicle">>)).
have_attribute(vehicle, wheels, integer, default(0)).
have_attribute(car, wheels, integer, default(4)).
constructor(vehicle, I, Inputs) :-
    attribute(I, wheels, W), assertz(ran(vehicle, I, W, Inputs)).
constructor(car, I, Inputs) :-
    attribute(I, wheels, W), assertz(ran(car, I, W, Inputs)).
constructor(boat, I, Inputs) :-
    attribute(I, wheels, W), assertz(ran(boat, I, W, Inputs)).
constructor(amphibious, I, Inputs) :-
    attribute(I, wheels, W), assertz(ran(amphibious, I, W, Inputs)).
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
have_part(head, left_eye).
have_attribute(eye, name, binary, default(<<"Eye">>)).
have_attribute(eye, color, atom, default(blue)).
constructor(head, I, Inputs) :-
    '$quod_build_plan'([]),
    build_plan_part(Inputs, left_eye, Left),
    with_build_plan(Left, test_initialize(eye, left(I))),
    test_initialize(eye, right(I)),
    assertz(parts(I, left(I), right(I))).
constructor(eye, I, _) :- attribute(I, color, Color), Color \== invalid.

%% The pool provider is tested against the real naming rules with a tiny pool.
isa(place, thing).
have_attribute(place, name, binary, default_from(place_name)).
place_name(I, Name) :- draw(<<"fixture">>, <<"place">>, <<"neutral">>, I, Name).
isa(unsupported_pool, thing).
have_attribute(unsupported_pool, name, binary, default_from(unsupported_name)).
unsupported_name(I, Name) :- draw(<<"fixture">>, <<"machine">>, <<"neutral">>, I, Name).

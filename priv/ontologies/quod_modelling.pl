%% Pure model construction. Rendering policy and descriptor validation belong
%% to the exact rendering vocabulary supplied at founding.
acl_sovereign(quod:modelling).
can_invoke(Goal, _, _, _) :- modelling_query(Goal).
can_invoke((current_ontology_identity(_, _), Goal), _, _, _) :- modelling_query(Goal).
can_invoke(_, node(Key), _, _) :- peer_admitted(Key, _, _, Key).
can_join(_, _, Key) :- peer_ready(Key).

modelling_query(model(_, _)).
modelling_query(shape(_, _, _)).
modelling_query(align(_, _, _, _, _, _)).
modelling_query(place_model(_, _, _, _, _)).

%% --- reusable recipe helpers -------------------------------------------------
%% A recipe proves Parts; model/2 derives a scene without asserting anything.
%% Occurrence IDs remain independent from both recipe and subject identities.
model(Parts, Marks) :-
    term_variables(Parts, []),
    model_parts(Parts, Marks),
    rendering_vocabulary(Namespace, Anchor),
    Namespace::(current_ontology_identity(Namespace, Anchor), well_formed_scene(Marks)).

model_parts([], []).
model_parts([part(Id, Shape, At, Surface, Label, Subject) | Parts],
            [mark(Id, Kind, Size, Placed, Surface, Label, Subject) | Marks]) :-
    shape(Shape, Kind, Expressions), model_dimensions(Expressions, Size),
    model_transform(At, Placed), model_parts(Parts, Marks).

%% Source-level arithmetic is evaluated by Prolog once, not shipped as client
%% code. The final scene schema still requires bounded integer measurements.
model_dimensions([], []).
model_dimensions([f(Name, Expression) | Rest], [f(Name, Value) | Values]) :-
    Value is Expression, model_dimensions(Rest, Values).
model_transform(transform(EX, EY, EZ, ERX, ERY, ERZ), transform(X, Y, Z, RX, RY, RZ)) :-
    X is EX, Y is EY, Z is EZ, RX is ERX, RY is ERY, RZ is ERZ.
model_transform(relative(Parent, At), relative(Parent, Placed)) :-
    At = transform(_, _, _, _, _, _), model_transform(At, Placed).

shape(group, <<"group">>, []).
shape(box(W, H, D), <<"box">>,
      [f(<<"width">>, W), f(<<"height">>, H), f(<<"depth">>, D)]).
shape(sphere(D), <<"sphere">>, [f(<<"diameter">>, D)]).
shape(plane(W, H), <<"plane">>, [f(<<"width">>, W), f(<<"height">>, H)]).
shape(cylinder(D, H), <<"cylinder">>, [f(<<"diameter">>, D), f(<<"height">>, H)]).
shape(capsule(D, H), <<"capsule">>, [f(<<"diameter">>, D), f(<<"height">>, H)]).
shape(torus(D, T), <<"torus">>, [f(<<"diameter">>, D), f(<<"thickness">>, T)]).
shape(sky_sphere(D), <<"sky_sphere">>, [f(<<"diameter">>, D)]).

%% Align two axis-aligned bounding-box anchors in the target's local frame.
%% A positive gap runs outward along the target face's normal. The returned
%% transform belongs under that target, whose own rotation remains independent.
%% Require an exact whole-mm result rather than silently rounding half-mm gaps.
align(Shape, Face, TargetShape, TargetFace, Gap, transform(X, Y, Z, 0, 0, 0)) :-
    valid_shape(Shape), bounds(Shape, W, H, D),
    valid_shape(TargetShape), bounds(TargetShape, TW, TH, TD),
    face(Face, FX, FY, FZ), face(TargetFace, TX, TY, TZ), integer(Gap),
    aligned_axis(W, FX, TW, TX, Gap, X),
    aligned_axis(H, FY, TH, TY, Gap, Y),
    aligned_axis(D, FZ, TD, TZ, Gap, Z).

bounds(box(W, H, D), W, H, D).
bounds(sphere(D), D, D, D).
bounds(plane(W, H), W, H, 0).
bounds(cylinder(D, H), D, H, D).
bounds(capsule(D, H), D, H, D) :- H >= D.
bounds(torus(D, T), D, T, D) :- T < D.
bounds(sky_sphere(D), D, D, D).

face(centre, 0, 0, 0).
face(left, -1, 0, 0).
face(right, 1, 0, 0).
face(bottom, 0, -1, 0).
face(top, 0, 1, 0).
face(front, 0, 0, -1).
face(back, 0, 0, 1).

aligned_axis(Size, Side, TargetSize, TargetSide, Gap, Position) :-
    Twice is TargetSize * TargetSide - Size * Side + 2 * Gap * TargetSide,
    0 =:= Twice mod 2, Position is Twice // 2.


valid_shape(Shape) :- shape(Shape, _, Dimensions), positive_dimensions(Dimensions).
positive_dimensions([]).
positive_dimensions([f(_, N) | Rest]) :- integer(N), N > 0, positive_dimensions(Rest).

%% A named instance scopes every local part; slash separates path components.
%% Input recipes use local paths; composed subrecipes can be nested again.
place_model(Id, At, Subject, Parts,
            [part(Id, group, At, no_surface, unlabelled, Subject) | Placed]) :-
    component_name(Id), place_parts(Parts, Id, Placed).
place_parts([], _, []).
place_parts([part(Id, Shape, At, Surface, Label, Subject) | Rest], Prefix,
            [part(Scoped, Shape, Local, Surface, Label, Subject) | Placed]) :-
    scoped_id(Prefix, Id, Scoped), scoped_transform(Prefix, At, Local),
    place_parts(Rest, Prefix, Placed).
scoped_id(Prefix, Id, Scoped) :-
    local_path(Id), binary_codes(Prefix, P), binary_codes(Id, I),
    append(P, [47 | I], Codes), binary_codes(Scoped, Codes).
component_name(Id) :- binary_codes(Id, Codes), Codes = [_ | _], \+ member(47, Codes).
local_path(Id) :- binary_codes(Id, [First | Rest]), First =\= 47, path_tail(Rest).
path_tail([]).
path_tail([47, Next | Rest]) :- Next =\= 47, path_tail(Rest).
path_tail([Code | Rest]) :- Code =\= 47, path_tail(Rest).
scoped_transform(Prefix, relative(Parent, At), relative(Scoped, At)) :-
    scoped_id(Prefix, Parent, Scoped).
scoped_transform(Prefix, transform(X,Y,Z,RX,RY,RZ),
                 relative(Prefix, transform(X,Y,Z,RX,RY,RZ))).

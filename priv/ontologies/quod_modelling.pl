%% Pure model construction. Rendering policy and descriptor validation belong
%% to the exact rendering vocabulary supplied at founding.
acl_sovereign(quod:modelling).
can_invoke(Goal, _, _, _) :- modelling_query(Goal).
can_invoke((current_ontology_identity(_, _), Goal), _, _, _) :- modelling_query(Goal).
can_invoke(Goal, _, _, _) :- system_source_query(Goal).
can_invoke(_, node(Key), _, _) :- peer_admitted(Key, _, _, Key).
can_join(_, _, Key) :- peer_ready(Key).

modelling_query(model(_, _)).
modelling_query(shape(_, _, _)).
modelling_query(align(_, _, _, _, _, _)).
modelling_query(place_model(_, _, _, _, _)).
modelling_query(Goal) :- public_source_query(Goal).

public_prolog_predicate(model/2).
public_prolog_predicate(shape/3).
public_prolog_predicate(align/6).
public_prolog_predicate(place_model/5).

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
    shape(Shape, Kind, Expressions), model_geometry(Kind, Expressions, Size),
    model_transform(At, Placed), model_parts(Parts, Marks).

%% Source-level arithmetic is evaluated by Prolog once, not shipped as client
%% code. The final scene schema still requires bounded integer measurements.
model_dimensions([], []).
model_dimensions([f(Name, Expression) | Rest], [f(Name, Value) | Values]) :-
    Value is Expression, model_dimensions(Rest, Values).
model_geometry(<<"mesh">>,
               mesh_asset(Asset, Profile, scale(ES),
                          frame(aabb(EAX, EAY, EAZ, EBX, EBY, EBZ),
                                pivot(EPX, EPY, EPZ), Front), Resources),
               mesh_asset(Asset, Profile, scale(S),
                          frame(aabb(AX, AY, AZ, BX, BY, BZ),
                                pivot(PX, PY, PZ), Front), Resources)) :-
    S is ES,
    AX is EAX, AY is EAY, AZ is EAZ,
    BX is EBX, BY is EBY, BZ is EBZ,
    PX is EPX, PY is EPY, PZ is EPZ.
model_geometry(Kind, Expressions, Size) :-
    Kind \== <<"mesh">>, model_dimensions(Expressions, Size).
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
shape(mesh_asset(Asset, Profile, Scale, Frame, Resources), <<"mesh">>,
      mesh_asset(Asset, Profile, Scale, Frame, Resources)).

%% Align two axis-aligned bounding-box anchors in the target's local frame.
%% A positive gap runs outward along the target face's normal. The returned
%% transform belongs under that target, whose own rotation remains independent.
%% Require an exact whole-mm result rather than silently rounding half-mm gaps.
align(Shape, Face, TargetShape, TargetFace, Gap, transform(X, Y, Z, 0, 0, 0)) :-
    shape_bounds(Shape, bounds(XMin, XMax, YMin, YMax, ZMin, ZMax)),
    shape_bounds(TargetShape, bounds(TXMin, TXMax, TYMin, TYMax, TZMin, TZMax)),
    face(Face, FX, FY, FZ), face(TargetFace, TX, TY, TZ), integer(Gap),
    aligned_axis(XMin, XMax, FX, TXMin, TXMax, TX, Gap, X),
    aligned_axis(YMin, YMax, FY, TYMin, TYMax, TY, Gap, Y),
    aligned_axis(ZMin, ZMax, FZ, TZMin, TZMax, TZ, Gap, Z).

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

%% Bounds use units of 1/2000 mm, so half-mm primitive faces and permille
%% scaled mesh anchors remain exact until the final whole-mm placement check.
shape_bounds(Shape, bounds(XMin, XMax, YMin, YMax, ZMin, ZMax)) :-
    Shape \= mesh_asset(_, _, _, _, _),
    valid_shape(Shape), bounds(Shape, W, H, D),
    XMin is -W * 1000, XMax is W * 1000,
    YMin is -H * 1000, YMax is H * 1000,
    ZMin is -D * 1000, ZMax is D * 1000.
shape_bounds(Mesh,
             bounds(XMin, XMax, YMin, YMax, ZMin, ZMax)) :-
    Mesh = mesh_asset(_, _, _, _, _),
    model_geometry(<<"mesh">>, Mesh,
                   mesh_asset(_, _, scale(S),
                              frame(aabb(AX, AY, AZ, BX, BY, BZ),
                                    pivot(PX, PY, PZ), front(Front)), _)),
    integer(S), S > 0,
    integer(AX), integer(AY), integer(AZ),
    integer(BX), integer(BY), integer(BZ),
    integer(PX), integer(PY), integer(PZ),
    AX < BX, AY < BY, AZ < BZ,
    YMin is 2 * (AY - PY) * S, YMax is 2 * (BY - PY) * S,
    oriented_bounds(Front, AX, BX, AZ, BZ, PX, PZ, S,
                    XMin, XMax, ZMin, ZMax).

oriented_bounds(<<"-z">>, AX, BX, AZ, BZ, PX, PZ, S, X0, X1, Z0, Z1) :-
    X0 is 2 * (AX - PX) * S, X1 is 2 * (BX - PX) * S,
    Z0 is 2 * (AZ - PZ) * S, Z1 is 2 * (BZ - PZ) * S.
oriented_bounds(<<"+z">>, AX, BX, AZ, BZ, PX, PZ, S, X0, X1, Z0, Z1) :-
    X0 is -2 * (BX - PX) * S, X1 is -2 * (AX - PX) * S,
    Z0 is -2 * (BZ - PZ) * S, Z1 is -2 * (AZ - PZ) * S.
oriented_bounds(<<"+x">>, AX, BX, AZ, BZ, PX, PZ, S, X0, X1, Z0, Z1) :-
    X0 is 2 * (AZ - PZ) * S, X1 is 2 * (BZ - PZ) * S,
    Z0 is -2 * (BX - PX) * S, Z1 is -2 * (AX - PX) * S.
oriented_bounds(<<"-x">>, AX, BX, AZ, BZ, PX, PZ, S, X0, X1, Z0, Z1) :-
    X0 is -2 * (BZ - PZ) * S, X1 is -2 * (AZ - PZ) * S,
    Z0 is 2 * (AX - PX) * S, Z1 is 2 * (BX - PX) * S.

aligned_axis(Min, Max, Side, TargetMin, TargetMax, TargetSide, Gap, Position) :-
    anchor(Min, Max, Side, ShapeAt),
    anchor(TargetMin, TargetMax, TargetSide, TargetAt),
    Offset is TargetAt - ShapeAt + 4000 * Gap * TargetSide,
    0 =:= Offset mod 4000,
    Position is Offset // 4000.

anchor(Min, _Max, -1, Twice) :- Twice is 2 * Min.
anchor(Min, Max, 0, Sum) :- Sum is Min + Max.
anchor(_Min, Max, 1, Twice) :- Twice is 2 * Max.

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

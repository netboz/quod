%% Coordinates: right-handed, Y up, console front -Z. Local rotations apply
%% X, then Y, then Z, before translation and parent composition. Lengths are
%% millimetres; angles degrees; optical factors and UV repeat permille.
%% Surface texture slots: base_colour is sRGB; normal is OpenGL tangent space;
%% orm is linear R=occlusion/G=roughness/B=metallic. JPEG assets use SHA-256.
%% Beside the pictures, a surface can show a text as rain: the letters stand
%% still in columns and light falls down each one.
%% quod:gui — the marks a renderer may be asked to draw.
%%
%% A mark is a visual occurrence. It is not the thing it shows: several marks
%% may depict one entity, and a mark may depict nothing at all. Keeping the two
%% identities apart is what lets a scene tree show a domain graph that
%% is not a tree, and what lets selection resolve through the entity rather
%% than through a mesh name.
%%
%% Nothing here is a rendering command. There are no verbs, no handles, no
%% engine API: a descriptor says what is there, and applying it is the client's
%% idempotent business. Babylon is one adapter; another engine reads the same
%% descriptors without any durable truth changing.
%%
%% Lengths and offsets are millimetres; angles are whole degrees. Edge-only
%% boxes additionally carry exact positive reduced N/D lengths. Conversion to
%% engine floating point happens only at the render boundary.
%%
%% Every identifier — a kind, a field, a colour, a placement, an ontology name —
%% is a binary. Only the predicates and the descriptor functors are symbolic.
%%
%% Model:
%%   mark_kind(Kind)                    one of the supported geometries
%%   geometry_field(Kind, At, Field)    the fields that kind takes, in order
%%   placement(Placement)               where a label sits on its mark
%%
%% The descriptor:
%%   mark(Id, Kind, Size, Transform, Material, Label, Depicts)
%%     Id        a view-scoped occurrence identity, not a domain name
%%     Size      ordered mm fields (exact rational for edge-only boxes), or typed assets
%%     Transform transform(X,Y,Z,RX,RY,RZ) | body_pose(Id, Revision)
%%               | relative(Parent, transform(...)) | relative(Parent, body_pose(...))
%%     Material  surface(Colour, Metal, Rough, Emission, Opacity, Textures) |
%%               surfaces(Display, Pointed, Selected), three such surfaces |
%%               asset_surfaces for meshes | no_surface for groups.
%%               Optical factors, opacity and repeats are permille; a surface
%%               below full opacity is drawn from both sides.
%%               Textures: pictures, and at most one
%%               texture(<<"rain">>, Text, glyph(Height)).
%%     Label     label(Text, Placement) | unlabelled
%%     Depicts   depicts(Ontology, Anchor, Entity) | depicts_nothing
%%               Unanchored depicts(Ontology, Entity) is display-only.
%%
%% Asked:
%%   well_formed_mark(+Mark)            one descriptor against its schema
%%   well_formed_scene(+Marks)          a list with distinct ids
%%   depicted(+Marks, ?Id, ?Ns, ?Thing) which mark shows what
%%
%% Interactive subjects carry the exact history anchor. The client proves that
%% identity in the selected scope before reading its menu or workspace.


rendering_query(mark_kind(_)).
rendering_query(geometry_field(_, _, _)).
rendering_query(placement(_)).
rendering_query(well_formed_mark(_)).
rendering_query(well_formed_scene(_)).
rendering_query(depicted(_, _, _, _)).
rendering_query(depicted(_, _, _, _, _)).

%% --- the geometries -----------------------------------------------------------
%% Parameterized shapes, a transform group and an asset mesh.
%% Primitive fields are declared once, in order, so the client never has to
%% know that a box's three numbers happen to be width, height and depth.

mark_kind(<<"box">>).
mark_kind(<<"wire_box">>).
mark_kind(<<"corner_box">>).
mark_kind(<<"sphere">>).
mark_kind(<<"plane">>).
mark_kind(<<"cylinder">>).
mark_kind(<<"capsule">>).
mark_kind(<<"torus">>).
mark_kind(<<"sky_sphere">>).
mark_kind(<<"group">>).
mark_kind(<<"mesh">>).
mark_kind(<<"terrain">>).

geometry_field(<<"box">>, 1, <<"width">>).
geometry_field(<<"box">>, 2, <<"height">>).
geometry_field(<<"box">>, 3, <<"depth">>).
geometry_field(<<"wire_box">>, 1, <<"width">>).
geometry_field(<<"wire_box">>, 2, <<"height">>).
geometry_field(<<"wire_box">>, 3, <<"depth">>).
geometry_field(<<"corner_box">>, 1, <<"width">>).
geometry_field(<<"corner_box">>, 2, <<"height">>).
geometry_field(<<"corner_box">>, 3, <<"depth">>).
geometry_field(<<"sphere">>, 1, <<"diameter">>).
geometry_field(<<"plane">>, 1, <<"width">>).
geometry_field(<<"plane">>, 2, <<"height">>).
geometry_field(<<"cylinder">>, 1, <<"diameter">>).
geometry_field(<<"cylinder">>, 2, <<"height">>).
geometry_field(<<"capsule">>, 1, <<"diameter">>).
geometry_field(<<"capsule">>, 2, <<"height">>).
geometry_field(<<"torus">>, 1, <<"diameter">>).
geometry_field(<<"torus">>, 2, <<"thickness">>).
geometry_field(<<"sky_sphere">>, 1, <<"diameter">>).


placement(<<"above">>).
placement(<<"centre">>).
placement(<<"below">>).

%% --- a descriptor against its schema ------------------------------------------

%% well_formed_mark(+Mark): every part is present and conforms to its declared type.
well_formed_mark(mark(Id, Kind, Size, Transform, Material, Label, Depicts)) :-
    scene_text(Id),
    mark_kind(Kind),
    findall(Field, geometry_field(Kind, _, Field), Fields),
    geometry(Kind, Fields, Size),
    geometry_constraint(Kind, Size),
    placed(Transform),
    geometry_binding(Kind,Transform,Depicts),
    appearance(Kind, Material, Label),
    refers(Depicts).

%% The fields arrive in the kind's declared order and each carries one positive
%% extent. A missing field, an extra field or a reordered one has no answer.
sized([], []).
sized([Field | Fields], [f(Field, Extent) | Rest]) :-
    integer(Extent),
    Extent > 0,
    sized(Fields, Rest).

%% Edge-only boxes. A wire_box draws its twelve edges whole. A corner_box
%% draws each edge from both of its corners, opaque at the corner and fading
%% to nothing a third of the way along, so the middle of every edge is empty.
%% Twelve edges cost the same at any extent. Interior dimensions are not a
%% geometry allocation budget. Keep exact reduced fractions on the wire.
edge_box(<<"wire_box">>).
edge_box(<<"corner_box">>).
exact_sized([],[]).
exact_sized([Field|Fields],[f(Field,Extent)|Rest]) :-
    exact_length(Extent), exact_sized(Fields,Rest).
exact_length(N) :- integer(N), N > 0.
exact_length(N/D) :- integer(N), integer(D), N > 0, D > 1, exact_gcd(N,D,1).
exact_gcd(N,0,N).
exact_gcd(N,D,G) :- D > 0, R is N mod D, exact_gcd(D,R,G).

geometry(Kind,Fields,Size) :- edge_box(Kind), exact_sized(Fields,Size).

geometry(<<"mesh">>, [],
         mesh_asset(asset(Digest, <<"model/gltf-binary">>), <<"gltf2-static-v1">>,
                    scale(Scale), frame(aabb(MinX, MinY, MinZ, MaxX, MaxY, MaxZ),
                                        pivot(PX, PY, PZ), front(Front)),
                    resources(Transfer, Geometry, Vertices, Triangles, Nodes, Materials, Pixels))) :-
    binary_codes(Digest, Bytes), length(Bytes, 64), digest_hex(Bytes),
    integer(Scale), Scale > 0,
    offset(MinX), offset(MinY), offset(MinZ),
    offset(MaxX), offset(MaxY), offset(MaxZ),
    MinX < MaxX, MinY < MaxY, MinZ < MaxZ,
    offset(PX), offset(PY), offset(PZ),
    member(Front, [<<"-z">>, <<"+z">>, <<"+x">>, <<"-x">>]),
    resource(Transfer),
    resource(Geometry),
    resource(Vertices),
    resource(Triangles),
    resource(Nodes),
    resource(Materials),
    resource(Pixels).
geometry(<<"terrain">>, [], terrain_geometry(<<"qvt1">>,Palette,
         view_distance(Distance,Prefetch,Retention),resources(Transfer,Geometry,Vertices,Triangles,Chunks))) :-
    integer(Distance), Distance > 0, integer(Prefetch), Prefetch > 0,
    integer(Retention), Retention >= Prefetch,
    Palette = [_|_], length(Palette,Materials), resource(Materials),
    terrain_palette(Palette,-1),
    resource(Transfer), resource(Geometry),
    resource(Vertices), resource(Triangles),
    resource(Chunks).
geometry(Kind, Fields, Size) :- Kind \== <<"mesh">>, Kind \== <<"terrain">>, \+ edge_box(Kind), sized(Fields, Size).

terrain_palette([],_).
terrain_palette([material(Id,Surface)|Rest],Previous) :-
    integer(Id), Id > Previous, Id =< 65535, surfaced(Surface), terrain_palette(Rest,Id).

%% Generated resources are scoped to an exact installed physical body and
%% anchored ontology subject; an arbitrary static transform grants no stream.
geometry_binding(<<"terrain">>,Transform,depicts(_,Anchor,_)) :-
    binary_codes(Anchor,Bytes), length(Bytes,32), terrain_pose(Transform).
geometry_binding(Kind,_,_) :- Kind \== <<"terrain">>.
terrain_pose(body_pose(_,_)).
terrain_pose(relative(_,body_pose(_,_))).

%% Each signed appearance may supply an explicit allocation. There is no
%% second global ceiling over the resource owner's authored allowance.
resource(unlimited).
resource(Allowed) :- integer(Allowed), Allowed > 0.

%% These two shapes have relationships between their dimensions which field
%% validation alone cannot express. A capsule's total height contains both
%% rounded ends; a torus tube must fit inside its overall diameter.
geometry_constraint(<<"capsule">>, [f(<<"diameter">>, D), f(<<"height">>, H)]) :-
    H >= D.
geometry_constraint(<<"torus">>, [f(<<"diameter">>, D), f(<<"thickness">>, T)]) :-
    T < D.
geometry_constraint(Kind, _) :-
    mark_kind(Kind), Kind \== <<"capsule">>, Kind \== <<"torus">>.

placed(body_pose(Body, Revision)) :-
    integer(Body), Body >= 0, Body < 18446744073709551616,
    integer(Revision), Revision > 0, Revision < 18446744073709551616.
%% A decorative occurrence re-expresses the one streamed domain pose in the
%% body's admitted source frame before its occurrence's parent transform.
placed(body_frame_pose(Body, Revision)) :- placed(body_pose(Body,Revision)).
placed(transform(X, Y, Z, RX, RY, RZ)) :-
    offset(X), offset(Y), offset(Z),
    turn(RX), turn(RY), turn(RZ).
placed(relative(Parent, Transform)) :-
    scene_text(Parent),
    attachment_pose(Transform).
attachment_pose(transform(X,Y,Z,RX,RY,RZ)) :- placed(transform(X,Y,Z,RX,RY,RZ)).
attachment_pose(body_pose(Body, Revision)) :- placed(body_pose(Body, Revision)).
attachment_pose(body_frame_pose(Body, Revision)) :- placed(body_frame_pose(Body, Revision)).

offset(V) :- integer(V).

turn(V) :- integer(V), V >= 0, V < 360.

surfaced(surface(Colour, Metallic, Roughness, Emission, Opacity, Textures)) :-
    colour(Colour), fraction(Metallic), fraction(Roughness), fraction(Emission), fraction(Opacity),
    texture_bindings(Textures, []).

%% One binding per semantic slot. Assets are verified JPEG bytes, addressed by
%% lowercase SHA-256; references never carry a URL or executable engine code.
%%
%% Rain shows a text on the surface: Text is text(Binary), the text itself, or
%% source(ontology_ref(Namespace, Anchor)), the whole Prolog source of that
%% ontology, which the client reads once with the Source panel's read, under
%% the same source policy. Height is a letter's height in millimetres. The
%% surface's colour is the lit letters' colour, its emission their brightness,
%% its opacity how dark the surface is between them. Rain falls along the
%% mark's own up-down axis; how it moves is the client's drawing of rain.
texture_bindings([], _).
texture_bindings([texture(Slot, asset(Digest, <<"image/jpeg">>), repeat(U, V)) | Rest], Seen) :-
    texture_slot(Slot), \+ member(Slot, Seen),
    binary_codes(Digest, Bytes), length(Bytes, 64), digest_hex(Bytes),
    integer(U), U > 0, integer(V), V > 0,
    texture_bindings(Rest, [Slot | Seen]).
texture_bindings([texture(<<"rain">>, Text, glyph(Height)) | Rest], Seen) :-
    \+ member(<<"rain">>, Seen), term_variables(Text, []), rain_text(Text),
    integer(Height), Height > 0,
    texture_bindings(Rest, [<<"rain">> | Seen]).
rain_text(text(Text)) :- binary(Text), scene_text(Text).
rain_text(source(ontology_ref(Namespace, Anchor))) :-
    binary(Namespace), scene_text(Namespace),
    binary(Anchor), binary_codes(Anchor, Bytes), length(Bytes, 32).
texture_slot(<<"base_colour">>).
texture_slot(<<"normal">>).
texture_slot(<<"orm">>).
digest_hex([]).
digest_hex([C | Cs]) :- digest_digit(C), digest_hex(Cs).
digest_digit(C) :- C >= 48, C =< 57.
digest_digit(C) :- C >= 97, C =< 102.

fraction(N) :- integer(N), N >= 0, N =< 1000.

appearance(<<"group">>, no_surface, Label) :- labelled(Label).
%% Embedded accepted glTF materials are preserved; source material names never
%% acquire domain identity or permission.
appearance(<<"mesh">>, asset_surfaces, Label) :- labelled(Label).
appearance(<<"terrain">>, terrain_surfaces, unlabelled).
appearance(Kind, Material, Label) :-
    Kind \== <<"group">>, Kind \== <<"mesh">>, Kind \== <<"terrain">>, shown(Material), labelled(Label).

%% Beside its ordinary look, a mark may carry how it looks while pointed at
%% and once selected. All three travel together and the client switches
%% between them itself, so that feedback never waits for a read.
shown(Surface) :- surfaced(Surface).
shown(surfaces(Display, Pointed, Selected)) :-
    surfaced(Display), surfaced(Pointed), surfaced(Selected).

%% A colour is written the way a designer writes it: 35 is "#", and the six
%% digits are upper-case hex so one colour has one spelling.
colour(Colour) :-
    binary_codes(Colour, [Hash | Digits]),
    Hash =:= 35,
    length(Digits, 6),
    hex(Digits).

hex([]).
hex([Code | Rest]) :- hex_digit(Code), hex(Rest).

hex_digit(Code) :- Code >= 48, Code =< 57.
hex_digit(Code) :- Code >= 65, Code =< 70.

labelled(unlabelled).
labelled(label(Text, Placement)) :-
    scene_text(Text),
    placement(Placement).

%% A mark that shows a domain thing names the ontology it belongs to and the
%% ground term that identifies it there. A mark that shows nothing — a rule, a
%% ground plane — says so rather than inventing a subject.
refers(depicts_nothing).
refers(depicts(Ontology, Thing)) :-
    scene_text(Ontology),
    term_variables(Thing, []).
refers(depicts(Ontology, Anchor, Thing)) :-
    refers(depicts(Ontology, Thing)),
    binary_codes(Anchor, Bytes), length(Bytes, 32).

scene_text(Text) :- binary_codes(Text, [_|_]).

%% --- a scene ------------------------------------------------------------------

%% well_formed_scene(+Marks): a list of well-formed marks whose ids are
%% distinct. Nothing here requires the subjects to be distinct: several marks
%% depicting one entity is ordinary, and forbidding it would forbid showing the
%% same thing twice.
well_formed_scene(Marks) :-
    term_variables(Marks, []),
    length(Marks, Count),
    every_mark(Marks),
    findall(Id, member(mark(Id, _, _, _, _, _, _), Marks), Ids),
    sort(Ids, Distinct),
    length(Distinct, Count),
    parent_order(Marks, []),
    findall(View,member(mark(_,<<"terrain">>,terrain_geometry(_,_,View,_),_,_,_,_),Marks),Views),
    sort(Views,UniqueViews), length(UniqueViews,ViewCount), ViewCount =< 1.

%% Parents precede their children. This also excludes dangling references,
%% self-parenting and cycles, without a second graph traversal per occurrence.
parent_order([], _Seen).
parent_order([mark(Id, _, _, At, _, _, _) | Rest], Seen) :-
    available_parent(At, Seen), parent_order(Rest, [Id | Seen]).
available_parent(transform(_, _, _, _, _, _), _Seen).
available_parent(body_pose(_, _), _Seen).
available_parent(body_frame_pose(_, _), _Seen).
available_parent(relative(Parent, _), Seen) :- member(Parent, Seen).

every_mark([]).
every_mark([Mark | Rest]) :- well_formed_mark(Mark), every_mark(Rest).

%% depicted(+Marks, ?Id, ?Ontology, ?Thing): which mark shows what. Leave Id
%% unbound and bind Thing to enumerate every mark depicting one entity.
depicted(Marks, Id, Ontology, Thing) :-
    member(mark(Id, _, _, _, _, _, depicts(Ontology, Thing)), Marks).

%% Exact-history introspection preserves the subject anchor.
depicted(Marks, Id, Ontology, Anchor, Thing) :-
    member(mark(Id, _, _, _, _, _, depicts(Ontology, Anchor, Thing)), Marks).

%% --- the class view -----------------------------------------------------------
%% The house vocabulary of doc/outdated/content-layer-design.md, derived from the
%% relations above rather than stored beside them, so the two views cannot
%% disagree.

isa(mark, thing).
isa(geometry, thing).

instance_of(geometry, Kind) :- mark_kind(Kind).

have_attribute(geometry, field, binary).
have_attribute(mark, depicts, term).

attribute(Kind, field, Field) :- geometry_field(Kind, _, Field).

isa(model_eidolon, eidolon).
isa(surface_eidolon, eidolon).
isa(gui_eidolon, eidolon).

%% Pure model construction. Rendering policy and descriptor validation belong
%% to the exact rendering vocabulary supplied at founding.

modelling_query(model(_, _)).
modelling_query(shape(_, _, _)).
modelling_query(align(_, _, _, _, _, _)).
modelling_query(place_model(_, _, _, _, _)).
modelling_query(marker_size(_)).
%% A pose stored elsewhere is a scene pose: its owner asks this one rule.
modelling_query(placed(_)).

%% --- reusable recipe helpers -------------------------------------------------
%% A recipe proves Parts; model/2 derives a scene without asserting anything.
%% Occurrence IDs remain independent from both recipe and subject identities.
model(Parts, Marks) :-
    term_variables(Parts, []),
    model_parts(Parts, Marks),
    well_formed_scene(Marks).

model_parts([], []).
model_parts([part(Id, Shape, At, Surface, Label, Subject) | Parts],
            [mark(Id, Kind, Size, Placed, Surface, Label, Subject) | Marks]) :-
    shape(Shape, Kind, Expressions), model_geometry(Kind, Expressions, Size),
    model_transform(At, Placed), model_parts(Parts, Marks).

%% Source-level arithmetic is evaluated by Prolog once, not shipped as client
%% code. Edge-only boxes preserve their already-resolved exact rational fields.
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
model_geometry(<<"terrain">>, terrain_geometry(Profile,Palette,View,Resources),
               terrain_geometry(Profile,Palette,View,Resources)).
model_geometry(Kind,Fields,Fields) :- edge_box(Kind).
model_geometry(Kind, Expressions, Size) :-
    Kind \== <<"mesh">>, Kind \== <<"terrain">>, \+ edge_box(Kind), model_dimensions(Expressions, Size).
model_transform(transform(EX, EY, EZ, ERX, ERY, ERZ), transform(X, Y, Z, RX, RY, RZ)) :-
    X is EX, Y is EY, Z is EZ, RX is ERX, RY is ERY, RZ is ERZ.
model_transform(body_pose(Body, Revision), body_pose(Body, Revision)).
model_transform(body_frame_pose(Body, Revision), body_frame_pose(Body, Revision)).
model_transform(relative(Parent, At), relative(Parent, Placed)) :-
    (At = transform(_, _, _, _, _, _); At = body_pose(_, _); At = body_frame_pose(_,_)),
    model_transform(At, Placed).

shape(group, <<"group">>, []).
shape(box(W, H, D), <<"box">>,
      [f(<<"width">>, W), f(<<"height">>, H), f(<<"depth">>, D)]).
shape(wire_box(W,H,D),<<"wire_box">>,
      [f(<<"width">>,W),f(<<"height">>,H),f(<<"depth">>,D)]).
shape(corner_box(W,H,D),<<"corner_box">>,
      [f(<<"width">>,W),f(<<"height">>,H),f(<<"depth">>,D)]).
shape(sphere(D), <<"sphere">>, [f(<<"diameter">>, D)]).
shape(plane(W, H), <<"plane">>, [f(<<"width">>, W), f(<<"height">>, H)]).
shape(cylinder(D, H), <<"cylinder">>, [f(<<"diameter">>, D), f(<<"height">>, H)]).
shape(capsule(D, H), <<"capsule">>, [f(<<"diameter">>, D), f(<<"height">>, H)]).
shape(torus(D, T), <<"torus">>, [f(<<"diameter">>, D), f(<<"thickness">>, T)]).
shape(sky_sphere(D), <<"sky_sphere">>, [f(<<"diameter">>, D)]).
shape(mesh_asset(Asset, Profile, Scale, Frame, Resources), <<"mesh">>,
      mesh_asset(Asset, Profile, Scale, Frame, Resources)).
shape(terrain_geometry(Profile,Palette,View,Resources), <<"terrain">>,
      terrain_geometry(Profile,Palette,View,Resources)).

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
bounds(corner_box(W, H, D), W, H, D).
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
scoped_transform(Prefix, body_pose(Body,Revision), relative(Prefix,body_pose(Body,Revision))).
scoped_transform(Prefix, body_frame_pose(Body,Revision),relative(Prefix,body_frame_pose(Body,Revision))).

%% --- shared recipes -----------------------------------------------------------
%% Named looks that any class may select in class_eidolon/4 or nest through
%% place_model/5. Each reads only its subject's label, in the subject's own
%% ontology.

%% House colours, named once so recipes do not repeat their digits.
house_colour(gray, <<"#848FA5">>).
house_colour(gray_blue, <<"#C9D2DB">>).
house_colour(gold, <<"#F9C80E">>).

%% marker: the fixed-size box that stands for a thing, whatever the thing
%% measures. See-through sides and fading corner lines; gold while pointed
%% at, fuller gold once selected. Its edge is millimetres.
marker_size(500).
eidolon(marker, subject(ontology_ref(Ns, A), Entity),
        [part(<<"sides">>, box(Size, Size, Size), transform(0, 0, 0, 0, 0, 0),
              surfaces(surface(Gray, 0, 700, 0, 30, []),
                       surface(Gold, 0, 700, 0, 40, []),
                       surface(Gold, 0, 700, 0, 120, [])),
              unlabelled, depicts_nothing),
         part(<<"corners">>, corner_box(Size, Size, Size), transform(0, 0, 0, 0, 0, 0),
              Lines, Label, depicts_nothing)]) :-
    marker_size(Size), house_colour(gray, Gray), house_colour(gold, Gold),
    house_colour(gray_blue, GrayBlue), corner_lines(GrayBlue, Lines),
    in_ontology(Ns, A, client_subject_label(Entity, Label)).

%% extent: a real-size outline in the marker's corner style. The longer form
%% draws its lines in the caller's own colour.
eidolon(extent(W, H, D), Subject, Parts) :-
    house_colour(gray_blue, GrayBlue), eidolon(extent(W, H, D, GrayBlue), Subject, Parts).
eidolon(extent(W, H, D, Colour), subject(ontology_ref(Ns, A), Entity),
        [part(<<"extent">>, corner_box(W, H, D), transform(0, 0, 0, 0, 0, 0),
              Lines, Label, depicts_nothing)]) :-
    corner_lines(Colour, Lines), in_ontology(Ns, A, client_subject_label(Entity, Label)).

corner_lines(Colour, surfaces(surface(Colour, 0, 700, 1000, 1000, []), Pointed, Pointed)) :-
    house_colour(gold, Gold), Pointed = surface(Gold, 0, 700, 1000, 1000, []).

%% quod:present — the marks a renderer may be asked to draw.
%%
%% A mark is a visual occurrence. It is not the thing it shows: several marks
%% may depict one entity, and a mark may depict nothing at all. Keeping the two
%% identities apart is what lets a bounded scene tree show a domain graph that
%% is not a tree, and what lets selection resolve through the entity rather
%% than through a mesh name.
%%
%% Nothing here is a rendering command. There are no verbs, no handles, no
%% engine API: a descriptor says what is there, and applying it is the client's
%% idempotent business. Babylon is one adapter; another engine reads the same
%% descriptors without any durable truth changing.
%%
%% Every number is a whole number. Lengths and offsets are millimetres, angles
%% are whole degrees. No float and no rational appears in a descriptor: ten
%% nodes must agree bit for bit, and the renderer is free to convert at its own
%% edge where approximation is harmless.
%%
%% Every identifier — a kind, a field, a colour, a placement, an ontology name —
%% is a binary. Only the predicates and the descriptor functors are symbolic.
%%
%% Model:
%%   mark_kind(Kind)                    one of the bounded geometries
%%   geometry_field(Kind, At, Field)    the fields that kind takes, in order
%%   finish(Finish)                     how a surface takes light
%%   placement(Placement)               where a label sits on its mark
%%   limit(What, Max)                   the bound a descriptor may not exceed
%%
%% The descriptor:
%%   mark(Id, Kind, Size, Transform, Material, Label, Depicts)
%%     Id        a view-scoped occurrence identity, not a domain name
%%     Size      [f(Field, Millimetres), ...] in the kind's declared order
%%     Transform transform(X, Y, Z, RX, RY, RZ) — millimetres and degrees
%%     Material  material(<<"#RRGGBB">>, Finish)
%%     Label     label(Text, Placement) | unlabelled
%%     Depicts   depicts(Ontology, Entity) | depicts_nothing
%%
%% Asked:
%%   well_formed_mark(+Mark)            one descriptor against its schema
%%   well_formed_scene(+Marks)          a bounded list with distinct ids
%%   depicted(+Marks, ?Id, ?Ns, ?Thing) which mark shows what
%%
%% An ontology naming a mark's subject writes the ontology's flat name. Binding
%% the exact anchor as well belongs to the next slice; until then a descriptor
%% identifies the ontology, not the exact history it was read from.

acl_sovereign(quod:present).

%% Anyone may read the vocabulary and check a descriptor against it. Changing
%% the vocabulary stays with admitted nodes, as in the other system ontologies.
can_invoke(Goal, _Principal, _CallChain, _Ns) :- present_query(Goal).
can_invoke(_Goal, node(NodeKey), _CallChain, _Ns) :-
    peer_admitted(NodeKey, _, _, NodeKey).
can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).

present_query(mark_kind(_)).
present_query(geometry_field(_, _, _)).
present_query(finish(_)).
present_query(placement(_)).
present_query(limit(_, _)).
present_query(well_formed_mark(_)).
present_query(well_formed_scene(_)).
present_query(depicted(_, _, _, _)).
present_query(isa(_, _)).
present_query(instance_of(_, _)).
present_query(have_attribute(_, _, _)).
present_query(attribute(_, _, _)).

%% --- the geometries -----------------------------------------------------------
%% Four bounded parameterized shapes. A kind's fields are declared once, in
%% order, and a descriptor carries exactly those fields under those names: the
%% client never has to know that a box's three numbers happen to be width,
%% height and depth.

mark_kind(<<"box">>).
mark_kind(<<"sphere">>).
mark_kind(<<"plane">>).
mark_kind(<<"cylinder">>).

geometry_field(<<"box">>, 1, <<"width">>).
geometry_field(<<"box">>, 2, <<"height">>).
geometry_field(<<"box">>, 3, <<"depth">>).
geometry_field(<<"sphere">>, 1, <<"diameter">>).
geometry_field(<<"plane">>, 1, <<"width">>).
geometry_field(<<"plane">>, 2, <<"height">>).
geometry_field(<<"cylinder">>, 1, <<"diameter">>).
geometry_field(<<"cylinder">>, 2, <<"height">>).

finish(<<"matte">>).
finish(<<"glossy">>).
finish(<<"emissive">>).

placement(<<"above">>).
placement(<<"centre">>).
placement(<<"below">>).

%% --- the bounds ---------------------------------------------------------------
%% Every bound a descriptor is held to, in one place, readable by whoever
%% produces descriptors so no producer has to guess or keep its own copy.
%%
%% `label` is deliberately short. A label is display text, never an identity —
%% the identity is in `depicts` — so a producer may shorten one to fit. It also
%% keeps generated text away from a rendering seam that reads any 32-byte
%% binary as an Ed25519 key.

limit(<<"scene">>, 512).
limit(<<"mark_id">>, 16).
limit(<<"label">>, 24).
limit(<<"ontology">>, 64).
limit(<<"extent">>, 100000).
limit(<<"offset">>, 1000000).

%% --- a descriptor against its schema ------------------------------------------

%% well_formed_mark(+Mark): every part is present, declared, and within bounds.
well_formed_mark(mark(Id, Kind, Size, Transform, Material, Label, Depicts)) :-
    bounded_text(Id, <<"mark_id">>),
    mark_kind(Kind),
    findall(Field, geometry_field(Kind, _, Field), Fields),
    sized(Fields, Size),
    placed(Transform),
    surfaced(Material),
    labelled(Label),
    refers(Depicts).

%% The fields arrive in the kind's declared order and each carries one positive
%% extent. A missing field, an extra field or a reordered one has no answer.
sized([], []).
sized([Field | Fields], [f(Field, Extent) | Rest]) :-
    integer(Extent),
    Extent > 0,
    limit(<<"extent">>, Max),
    Extent =< Max,
    sized(Fields, Rest).

placed(transform(X, Y, Z, RX, RY, RZ)) :-
    offset(X), offset(Y), offset(Z),
    turn(RX), turn(RY), turn(RZ).

offset(V) :-
    integer(V),
    limit(<<"offset">>, Max),
    V =< Max,
    Least is 0 - Max,
    V >= Least.

turn(V) :- integer(V), V >= 0, V < 360.

surfaced(material(Colour, Finish)) :- colour(Colour), finish(Finish).

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
    bounded_text(Text, <<"label">>),
    placement(Placement).

%% A mark that shows a domain thing names the ontology it belongs to and the
%% ground term that identifies it there. A mark that shows nothing — a rule, a
%% ground plane — says so rather than inventing a subject.
refers(depicts_nothing).
refers(depicts(Ontology, Thing)) :-
    bounded_text(Ontology, <<"ontology">>),
    term_variables(Thing, []).

bounded_text(Text, What) :-
    binary_codes(Text, Codes),
    length(Codes, Count),
    Count > 0,
    limit(What, Max),
    Count =< Max.

%% --- a scene ------------------------------------------------------------------

%% well_formed_scene(+Marks): a bounded list of well-formed marks whose ids are
%% distinct. Nothing here requires the subjects to be distinct: several marks
%% depicting one entity is ordinary, and forbidding it would forbid showing the
%% same thing twice.
well_formed_scene(Marks) :-
    limit(<<"scene">>, Max),
    length(Marks, Count),
    Count =< Max,
    every_mark(Marks),
    findall(Id, member(mark(Id, _, _, _, _, _, _), Marks), Ids),
    sort(Ids, Distinct),
    length(Distinct, Count).

every_mark([]).
every_mark([Mark | Rest]) :- well_formed_mark(Mark), every_mark(Rest).

%% depicted(+Marks, ?Id, ?Ontology, ?Thing): which mark shows what. Leave Id
%% unbound and bind Thing to enumerate every mark depicting one entity.
depicted(Marks, Id, Ontology, Thing) :-
    member(mark(Id, _, _, _, _, _, depicts(Ontology, Thing)), Marks).

%% --- the class view -----------------------------------------------------------
%% The house vocabulary of doc/content-layer-design.md, derived from the
%% relations above rather than stored beside them, so the two views cannot
%% disagree.

isa(mark, thing).
isa(geometry, thing).

instance_of(geometry, Kind) :- mark_kind(Kind).

have_attribute(geometry, field, binary).
have_attribute(mark, depicts, term).

attribute(Kind, field, Field) :- geometry_field(Kind, _, Field).

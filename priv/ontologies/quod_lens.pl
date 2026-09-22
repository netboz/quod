%% quod:lens — what to look at, and how to show it. Two separate declarations.
%%
%% A LENS says what is being looked at and what for: which ontology the
%% subjects live in, how they are grouped, what is measured and on what kind of
%% scale, at what detail. An ENCODING says how that selection becomes marks:
%% which mark kind, which channel carries which measure, at what step, in which
%% layout. One lens may carry several encodings — changing the picture does not
%% change the question, and changing the question does not silently keep the
%% old picture's meaning.
%%
%% An encoding must state its preconditions, because the data does not imply
%% them. `attribute/3` need not be single-valued and `isa/2` is not a tree, so
%% an integer is not a quantity and a group is not a parent. What an encoding
%% needs is written as `requires/2`; `view/3` produces marks only when every
%% requirement holds, and `diagnosis/3` names the ones that do not. An
%% incompatible encoding therefore yields a bounded diagnostic, never a picture
%% that quietly means something else.
%%
%% Two things are deliberately not done here. Nothing selects an encoding
%% automatically: lenses are authored, and ranking compatible encodings is
%% later work. And no group is ordered by the order its facts happen to be
%% written in — `group_at/2` declares precedence explicitly, and a group with
%% none is a refused view rather than an arbitrary one.
%%
%% Descriptors are built to the schema of `quod:present`, named here by its
%% flat binary name. This ontology does not re-prove that schema on every read;
%% conformance is a tested invariant of the two sources, so one ordinary read
%% is one selection and one layout, not a validation round trip.
%%
%% Model — the lens:
%%   lens(Lens, Purpose)
%%   lens_subject(Lens, Ontology, Subject)
%%   lens_group(Lens, Group)
%%   lens_measure(Lens, Measure, Scale)     nominal | ordinal | quantitative
%%   lens_detail(Lens, Detail)
%%
%% Model — the encoding:
%%   encoding(Encoding, Lens, Presentation)
%%   encoding_mark(Encoding, Kind)
%%   encoding_layout(Encoding, Layout)
%%   encoding_channel(Encoding, Channel, Measure)
%%   encoding_step(Encoding, Channel, Base, Step)
%%   encoding_extent(Encoding, Millimetres)
%%   requires(Encoding, Requirement)
%%   absent(Encoding, Measure, Group)       where an unestablished value goes
%%
%% Authored per lens:
%%   rows(Lens, Parameters, Rows)           the selection, one row per mark
%%   group_at(Group, At)                    declared group precedence
%%   group_colour(Group, Colour)
%%
%% Asked:
%%   view(?Lens, +Parameters, ?Marks)       the descriptors, in one read
%%   diagnosis(?Lens, +Parameters, ?Unmet)  why there are none

acl_sovereign(quod:lens).

%% Anyone may look through a lens. Authoring one stays with admitted nodes.
can_invoke(Goal, _Principal, _CallChain, _Ns) :- lens_query(Goal).
can_invoke(_Goal, node(NodeKey), _CallChain, _Ns) :-
    peer_admitted(NodeKey, _, _, NodeKey).
can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).

lens_query(lens(_, _)).
lens_query(lens_subject(_, _, _)).
lens_query(lens_group(_, _)).
lens_query(lens_measure(_, _, _)).
lens_query(lens_detail(_, _)).
lens_query(encoding(_, _, _)).
lens_query(encoding_mark(_, _)).
lens_query(encoding_layout(_, _)).
lens_query(encoding_channel(_, _, _)).
lens_query(encoding_step(_, _, _, _)).
lens_query(requires(_, _)).
lens_query(group_at(_, _)).
lens_query(group_colour(_, _)).
lens_query(limit(_, _)).
lens_query(view(_, _, _)).
lens_query(diagnosis(_, _, _)).
lens_query(isa(_, _)).
lens_query(instance_of(_, _)).
lens_query(have_attribute(_, _, _)).
lens_query(attribute(_, _, _)).

%% --- the bounds ---------------------------------------------------------------
%% This ontology's own bounds on what it will produce, not a copy of anyone
%% else's. They are held below `quod:present`'s corresponding limits, which the
%% tests check against that source rather than restating here.

limit(<<"marks">>, 256).
limit(<<"label">>, 24).

%% --- looking through a lens ---------------------------------------------------

%% view(?Lens, +Parameters, ?Marks): the bounded list of descriptors this lens
%% and its encoding produce for these parameters. One selection, one layout, one
%% answer: a caller reads it like any other goal.
view(Lens, Parameters, Marks) :-
    encoding(Encoding, Lens, _Presentation),
    rows(Lens, Parameters, Rows),
    met(Encoding, Rows),
    laid_out(Encoding, Lens, Rows, Marks).

%% diagnosis(?Lens, +Parameters, ?Unmet): each requirement this encoding states
%% that the selected data does not meet. Asked when `view/3` has no answer; it
%% is the bounded diagnostic, not a second picture.
diagnosis(Lens, Parameters, Unmet) :-
    encoding(Encoding, Lens, _Presentation),
    rows(Lens, Parameters, Rows),
    requires(Encoding, Unmet),
    \+ satisfied(Unmet, Rows).

met(Encoding, Rows) :-
    \+ ( requires(Encoding, Requirement), \+ satisfied(Requirement, Rows) ).

%% --- what an encoding may require ---------------------------------------------
%% Each requirement is a property of the selected rows, checkable before a mark
%% is built. `ordinal/2` is the exception and is not listed here: that a rank
%% orders rather than counts is the author's claim about the domain, which no
%% amount of data establishes. What is checked is the band it claims to lie in,
%% and the encoding honours the claim by stepping the channel evenly and never
%% implying a ratio.

%% Every subject carries one value of the measure. A subject with two is not
%% collapsed to one and not dropped; the view is refused and named instead.
satisfied(single_valued(_Measure), Rows) :-
    \+ ( member(row(Thing, _, First, _), Rows),
         Thing \== none,
         member(row(Thing, _, Second, _), Rows),
         First \== Second ).

satisfied(ranked(_Measure, Low, High), Rows) :-
    \+ ( member(row(_, _, Rank, _), Rows), \+ within_band(Rank, Low, High) ).

%% Every group present has exactly one declared position, and no two share one,
%% so nothing is laid out in the order its facts were written.
satisfied(ordered(_Group), Rows) :-
    findall(Group, present(Rows, Group), Groups),
    findall(At, ( member(Group, Groups), group_at(Group, At) ), Positions),
    length(Groups, Count),
    length(Positions, Count),
    sort(Positions, Distinct),
    length(Distinct, Count).

%% Every group present has exactly one declared colour, and no two share one:
%% a picture whose groups are the same colour does not distinguish them.
satisfied(distinct_colours(_Group), Rows) :-
    findall(Group, present(Rows, Group), Groups),
    findall(Colour, ( member(Group, Groups), group_colour(Group, Colour) ), Colours),
    length(Groups, Count),
    length(Colours, Count),
    sort(Colours, Distinct),
    length(Distinct, Count).

satisfied(within(What), Rows) :-
    length(Rows, Count),
    limit(What, Max),
    Count =< Max.

%% An absent value is absent, not out of band. It is shown where `absent/3`
%% declares, never silently dropped and never counted as a zero.
within_band(none, _Low, _High) :- !.
within_band(Rank, Low, High) :- integer(Rank), Rank >= Low, Rank =< High.

present(Rows, Group) :-
    findall(Each, member(row(_, Each, _, _), Rows), All),
    sort(All, Distinct),
    member(Group, Distinct).

%% --- the layout ---------------------------------------------------------------
%% One shared layout: groups run back in their declared order, subjects run
%% across within a group in term order, and the measured channel lifts each
%% mark. It is the algorithm that is shared; every number it uses comes from the
%% encoding's declarations.

layout_kind(<<"grouped_columns">>, <<"box">>).

laid_out(Encoding, Lens, Rows, Marks) :-
    encoding_layout(Encoding, Layout),
    layout_kind(Layout, Kind),
    encoding_mark(Encoding, Kind),
    %% The channel that lifts a mark must carry a measure its lens calls
    %% ordinal. Height steps and does not claim a ratio, so pointing it at a
    %% nominal measure would make the picture assert an order nobody declared.
    encoding_channel(Encoding, <<"high">>, Measure),
    lens_measure(Lens, Measure, <<"ordinal">>),
    lens_subject(Lens, Ontology, _Subject),
    findall(at(At, Group), ( present(Rows, Group), group_at(Group, At) ), Pairs),
    sort(Pairs, Ordered),
    group_marks(Ordered, Rows, Encoding, Ontology, 0, 0, Marks, _Last).

group_marks([], _Rows, _Encoding, _Ontology, _Depth, Next, [], Next).
group_marks([at(_At, Group) | Rest], Rows, Encoding, Ontology, Depth, Next,
            Marks, Last) :-
    findall(row(Thing, Group, Rank, Text),
            member(row(Thing, Group, Rank, Text), Rows), Mine0),
    sort(Mine0, Mine),
    row_marks(Mine, Encoding, Ontology, Depth, 0, Next, Made, After),
    Deeper is Depth + 1,
    group_marks(Rest, Rows, Encoding, Ontology, Deeper, After, More, Last),
    append(Made, More, Marks).

row_marks([], _Encoding, _Ontology, _Depth, _Across, Next, [], Next).
row_marks([Row | Rest], Encoding, Ontology, Depth, Across, Next,
          [Mark | More], Last) :-
    one_mark(Row, Encoding, Ontology, Depth, Across, Next, Mark),
    Then is Next + 1,
    Beside is Across + 1,
    row_marks(Rest, Encoding, Ontology, Depth, Beside, Then, More, Last).

one_mark(row(Thing, Group, Rank, Text), Encoding, Ontology, Depth, Across, Next,
         mark(Id, <<"box">>,
              [f(<<"width">>, Side), f(<<"height">>, High), f(<<"depth">>, Side)],
              transform(X, Y, Z, 0, 0, 0),
              material(Colour, <<"matte">>),
              label(Short, <<"above">>),
              Depicts)) :-
    mark_id(Next, Id),
    encoding_extent(Encoding, Side),
    lifted(Encoding, Rank, High),
    encoding_step(Encoding, <<"across">>, AcrossBase, AcrossStep),
    encoding_step(Encoding, <<"back">>, BackBase, BackStep),
    X is AcrossBase + Across * AcrossStep,
    Z is BackBase + Depth * BackStep,
    Y is High // 2,
    group_colour(Group, Colour),
    shorten(Text, Short),
    subject(Ontology, Thing, Depicts).

%% The measured channel steps evenly from its base. An absent value sits at the
%% base step, which is why the base is a height of its own and not zero: a mark
%% that is there but unmeasured must still be visible.
lifted(Encoding, none, High) :- !, encoding_step(Encoding, <<"high">>, High, _Step).
lifted(Encoding, Rank, High) :-
    encoding_step(Encoding, <<"high">>, Base, Step),
    High is Base + Rank * Step.

%% A mark that stands for a domain fact names it in its ontology. A mark that
%% stands for the view's own reading of the data — that nothing carries this
%% work — depicts nothing rather than inventing a subject.
subject(_Ontology, none, depicts_nothing) :- !.
subject(Ontology, Thing, depicts(Ontology, Thing)).

%% A mark id is a view-scoped occurrence, short by construction: the subject's
%% identity is in `depicts`, so nothing here needs to carry a domain name.
mark_id(Index, Id) :-
    digits(Index, Codes),
    binary_codes(Id, [109 | Codes]).

digits(Index, [Code]) :- Index < 10, !, Code is Index + 48.
digits(Index, Codes) :-
    Quotient is Index // 10,
    Remainder is Index mod 10,
    digits(Quotient, Leading),
    Code is Remainder + 48,
    append(Leading, [Code], Codes).

%% A label is display text, not an identity, so it may be shortened to the
%% declared bound. Nothing else in a descriptor is.
shorten(Text, Short) :-
    binary_codes(Text, Codes),
    length(Codes, Count),
    limit(<<"label">>, Max),
    (   Count =< Max
    ->  Short = Text
    ;   leading(Max, Codes, Kept),
        binary_codes(Short, Kept)
    ).

leading(0, _Codes, []) :- !.
leading(Count, [Code | Rest], [Code | Kept]) :-
    Fewer is Count - 1,
    leading(Fewer, Rest, Kept).

%% --- the authored lens --------------------------------------------------------
%% What may this work ship under. The front row is the answer: one mark per
%% licence the combination admits, or one mark saying nothing carries it. The
%% rows behind are why: every component, grouped by the family of its licence,
%% lifted by how far that licence's copyleft reaches.
%%
%% Reach is ordinal. Four is not twice two: the bands are "nowhere", "the files
%% it covers", "the library", "the whole work", "the whole work including use
%% over a network". The encoding therefore steps the height evenly and the
%% picture claims no ratio between two heights.
%%
%% A component whose licence nobody has established has no reach at all. It is
%% not a zero: it appears in its own group at the base height, which is the
%% honest shape of "this is here and we do not know what it is".

lens(<<"work_licences">>, <<"what may this work ship under">>).
lens_subject(<<"work_licences">>, <<"quod:licence">>, <<"component">>).
lens_group(<<"work_licences">>, <<"family">>).
lens_measure(<<"work_licences">>, <<"reach">>, <<"ordinal">>).
lens_measure(<<"work_licences">>, <<"family">>, <<"nominal">>).
lens_detail(<<"work_licences">>, <<"component">>).

encoding(<<"reach_columns">>, <<"work_licences">>, <<"quod:present">>).
encoding_mark(<<"reach_columns">>, <<"box">>).
encoding_layout(<<"reach_columns">>, <<"grouped_columns">>).
encoding_channel(<<"reach_columns">>, <<"high">>, <<"reach">>).
encoding_channel(<<"reach_columns">>, <<"colour">>, <<"family">>).
encoding_channel(<<"reach_columns">>, <<"back">>, <<"family">>).
encoding_channel(<<"reach_columns">>, <<"label">>, <<"component">>).
encoding_step(<<"reach_columns">>, <<"high">>, 300, 300).
encoding_step(<<"reach_columns">>, <<"across">>, 0, 600).
encoding_step(<<"reach_columns">>, <<"back">>, 0, 900).
encoding_extent(<<"reach_columns">>, 400).
absent(<<"reach_columns">>, <<"reach">>, <<"unestablished">>).

requires(<<"reach_columns">>, single_valued(<<"reach">>)).
requires(<<"reach_columns">>, ranked(<<"reach">>, 0, 4)).
requires(<<"reach_columns">>, ordered(<<"family">>)).
requires(<<"reach_columns">>, distinct_colours(<<"family">>)).
requires(<<"reach_columns">>, within(<<"marks">>)).

%% rows(+Lens, +Parameters, -Rows): the selection. Four asks of `quod:licence`,
%% never one per component: the components, the licences, and what the work may
%% be released under, resolved here rather than by walking back and forth.
%%
%% A component whose licence carries several families produces one row per
%% family. That is the point: a subject with two parents is shown twice, not
%% silently placed under one of them.
rows(<<"work_licences">>, [Work], Rows) :-
    findall(part(Part, Licence),
            <<"quod:licence">> :: component(Work, Part, Licence), Parts),
    findall(known(Licence, Family, Reach),
            <<"quod:licence">> :: licence(Licence, Family, Reach), Known),
    findall(Under, <<"quod:licence">> :: ships(Work, Under), Admits),
    verdict_rows(Admits, Work, Known, Verdict),
    part_rows(Parts, Work, Known, Behind),
    append(Verdict, Behind, Rows).

%% No licence admits the combination. That is an answer, not an empty picture,
%% so it gets its own mark rather than a row nobody notices is missing.
verdict_rows([], _Work, _Known,
             [row(none, <<"blocked">>, none, <<"nothing may carry it">>)]) :-
    !.
verdict_rows(Admits, Work, Known, Rows) :- admitted_rows(Admits, Work, Known, Rows).

admitted_rows([], _Work, _Known, []).
admitted_rows([Under | Rest], Work, Known, [Row | More]) :-
    licence_row(Under, ships(Work, Under), Under, Known, <<"may_ship">>, Row),
    admitted_rows(Rest, Work, Known, More).

part_rows([], _Work, _Known, []).
part_rows([part(Part, Licence) | Rest], Work, Known, Rows) :-
    findall(row(component(Work, Part), Family, Reach, Part),
            member(known(Licence, Family, Reach), Known), Found),
    established(Found, component(Work, Part), Part, Mine),
    part_rows(Rest, Work, Known, More),
    append(Mine, More, Rows).

%% No licence fact for this part's licence: the value is absent, and it says so.
established([], Thing, Text, [row(Thing, Group, none, Text)]) :-
    !,
    absent(<<"reach_columns">>, <<"reach">>, Group).
established(Found, _Thing, _Text, Found).

%% The verdict marks take their height from the same reach the columns use, so
%% the answer and the reason are read on one scale.
licence_row(Licence, Thing, Text, Known, Group, row(Thing, Group, Reach, Text)) :-
    member(known(Licence, _Family, Reach), Known),
    !.
licence_row(_Licence, Thing, Text, _Known, Group, row(Thing, Group, none, Text)).

%% --- groups: precedence and colour, both declared -----------------------------
%% The answer sits in front, then the permissive families, then the ones whose
%% copyleft reaches further, then what is unknown. Colours are the house palette
%% and its shades; no two groups share one, which `distinct_colours/1` enforces
%% on whatever set of groups a work actually brings.

group_at(<<"may_ship">>, 1).
group_at(<<"blocked">>, 1).
group_at(<<"permissive">>, 2).
group_at(<<"mpl">>, 3).
group_at(<<"epl">>, 4).
group_at(<<"ogl">>, 5).
group_at(<<"cc">>, 6).
group_at(<<"cc-nc">>, 7).
group_at(<<"gpl">>, 8).
group_at(<<"proprietary">>, 9).
group_at(<<"unknown">>, 10).
group_at(<<"unestablished">>, 11).

group_colour(<<"may_ship">>, <<"#F9C80E">>).
group_colour(<<"blocked">>, <<"#C14953">>).
group_colour(<<"permissive">>, <<"#698F3F">>).
group_colour(<<"mpl">>, <<"#0B3954">>).
group_colour(<<"epl">>, <<"#17557A">>).
group_colour(<<"ogl">>, <<"#848FA5">>).
group_colour(<<"cc">>, <<"#C9A227">>).
group_colour(<<"cc-nc">>, <<"#8A6D1B">>).
group_colour(<<"gpl">>, <<"#B0603A">>).
group_colour(<<"proprietary">>, <<"#8A3239">>).
group_colour(<<"unknown">>, <<"#5B6273">>).
group_colour(<<"unestablished">>, <<"#2E3340">>).

%% --- the class view -----------------------------------------------------------

isa(lens, thing).
isa(encoding, thing).

instance_of(lens, Lens) :- lens(Lens, _Purpose).
instance_of(encoding, Encoding) :- encoding(Encoding, _Lens, _Presentation).

have_attribute(lens, purpose, binary).
have_attribute(lens, measure, binary).
have_attribute(encoding, lens, binary).
have_attribute(encoding, requires, term).

attribute(Lens, purpose, Purpose) :- lens(Lens, Purpose).
attribute(Lens, measure, Measure) :- lens_measure(Lens, Measure, _Scale).
attribute(Encoding, lens, Lens) :- encoding(Encoding, Lens, _Presentation).
attribute(Encoding, requires, Requirement) :- requires(Encoding, Requirement).

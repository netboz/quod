%% quod:gui — what to look at, and how to show it. Two separate declarations.
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
%% Descriptors are built to the schema of `quod:gui`, named here by its
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
%%   encoding(Encoding, Lens, Rendering)
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
lens_query(lens_limit(_, _)).
lens_query(view(_, _, _)).
lens_query(diagnosis(_, _, _)).

%% --- the bounds ---------------------------------------------------------------
%% This ontology's own bounds on what it will produce, not a copy of anyone
%% else's. They are held below `quod:gui`'s corresponding limits, which the
%% tests check against that source rather than restating here.

lens_limit(<<"marks">>, 256).
lens_limit(<<"label">>, 24).

%% --- looking through a lens ---------------------------------------------------

%% view(?Lens, +Parameters, ?Marks): the bounded list of descriptors this lens
%% and its encoding produce for these parameters. One selection, one layout, one
%% answer: a caller reads it like any other goal.
view(Lens, Parameters, Marks) :-
    encoding(Encoding, Lens, _Rendering),
    rows(Lens, Parameters, Rows),
    met(Encoding, Rows),
    laid_out(Encoding, Lens, Rows, Marks).

%% diagnosis(?Lens, +Parameters, ?Unmet): each requirement this encoding states
%% that the selected data does not meet. Asked when `view/3` has no answer; it
%% is the bounded diagnostic, not a second picture.
diagnosis(Lens, Parameters, Unmet) :-
    encoding(Encoding, Lens, _Rendering),
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
    lens_limit(What, Max),
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
              surface(Colour, 0, 900, 0, []),
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
subject(_Ontology, ontology_ref(Namespace, Anchor),
        depicts(Namespace, Anchor, ontology_ref(Namespace, Anchor))) :- !.
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
    lens_limit(<<"label">>, Max), shorten(Text, Max, Short).

%% Source is a textual encoding of current knowledge. The default selects all
%% stored clauses. A predicate lens is an explicit narrower selection, useful
%% for editing; neither lens changes the target's source-read authorization.
lens(<<"ontology_source">>, <<"complete current ontology state">>).
lens(<<"predicate_source">>, <<"one predicate definition">>).
lens(<<"ontology_policy">>, <<"ACL entry rules; actions reauthorize current state">>).
lens(<<"ontology_interfaces">>, <<"explicit interface declarations; no invocation grant">>).
lens(<<"ontology_routes">>, <<"live routes; addresses are not identities">>).
encoding(<<"source_text">>, <<"ontology_source">>, <<"quod:gui">>).
encoding(<<"source_text">>, <<"predicate_source">>, <<"quod:gui">>).
encoding(<<"source_text">>, <<"ontology_policy">>, <<"quod:gui">>).
encoding(<<"source_text">>, <<"ontology_interfaces">>, <<"quod:gui">>).
encoding(<<"source_text">>, <<"ontology_routes">>, <<"quod:gui">>).
encoding_layout(<<"source_text">>, <<"text">>).
source_chunk_bytes(16384).

rows(<<"ontology_source">>, [Target], [source(Chunk)]) :-
    source_chunk_bytes(Bytes),
    source_rows(Target, chunks(Bytes), Chunk).
rows(<<"predicate_source">>, [Target, Indicator], [source(Source)]) :-
    source_rows(Target, source(Indicator), Source).
rows(<<"ontology_policy">>, [Target], [source(Chunk)]) :-
    source_chunk_bytes(Bytes), source_rows(Target, policy_chunks(Bytes), Chunk).
rows(<<"ontology_interfaces">>, [Target], [source(Chunk)]) :-
    source_chunk_bytes(Bytes), source_rows(Target, interface_chunks(Bytes), Chunk).
rows(<<"ontology_routes">>, [Target], [source(Chunk)]) :-
    source_chunk_bytes(Bytes), source_rows(Target, route_chunks(Bytes), Chunk).
source_rows(Target, Query, Source) :-
    prolog_inspect(Target, Query, Source).

laid_out(Encoding, _Lens, [source(Source)], Source) :-
    encoding_layout(Encoding, <<"text">>).

ontology_interface(view/3, <<"authored lens selection and encoding">>).
ontology_interface(diagnosis/3, <<"unmet encoding requirements">>).

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

encoding(<<"reach_columns">>, <<"work_licences">>, <<"quod:gui">>).
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
instance_of(encoding, Encoding) :- encoding(Encoding, _Lens, _Rendering).

have_attribute(lens, purpose, binary).
have_attribute(lens, measure, binary).
have_attribute(encoding, lens, binary).
have_attribute(encoding, requires, term).

attribute(Lens, purpose, Purpose) :- lens(Lens, Purpose).
attribute(Lens, measure, Measure) :- lens_measure(Lens, Measure, _Scale).
attribute(Encoding, lens, Lens) :- encoding(Encoding, Lens, _Rendering).
attribute(Encoding, requires, Requirement) :- requires(Encoding, Requirement).

%% Code views and a pure compiler for ordinary, inspectable editing goals.
%% The owning ontology's normal can_invoke/4 policy authorizes the returned goal.

prolog_query(prolog_predicates(_, _)).
prolog_query(prolog_source(_, _, _)).
prolog_query(prolog_source(_, _)).
prolog_query(prolog_inspect(_, _, _)).
prolog_query(prolog_edit_goal(_, _, _, _, _)).
prolog_query(prolog_clauses(_, _)).
prolog_query(prolog_workbench_draft(_, _, _)).

%% Explicit interfaces describe callable operations; their declaration grants
%% no target source-read, invocation, content-edit or policy-edit permission.
ontology_interface(prolog_predicates/2, <<"current predicate catalogue">>).
ontology_interface(prolog_source/2, <<"complete current source cursor">>).
ontology_interface(prolog_source/3, <<"explicit predicate source">>).
ontology_interface(prolog_inspect/3, <<"authorized target inspection">>).
ontology_interface(prolog_edit_goal/5, <<"compile an exact-baseline content or policy edit">>).

%% The compiler transforms source and goal terms as data. Qualified names in
%% those terms never authorize implicit argument following by these helpers.
no_follow(prolog_clauses/2).
no_follow(prolog_workbench_draft/3).
no_follow(workbench_fact/1).
no_follow(workbench_symbol/1).
no_follow(workbench_change/3).
no_follow(workbench_remove/3).
no_follow(workbench_same/2).
no_follow(workbench_member/2).
no_follow(prolog_edit_goal/5).
no_follow(prolog_edit_body/6).
no_follow(prolog_ordered_clauses/2).
no_follow(prolog_keyed_entries/2).
no_follow(prolog_numbered_entries/3).
no_follow(prolog_grouped_entries/2).
no_follow(prolog_groups/2).
no_follow(prolog_group_tail/4).
no_follow(prolog_predicate_edits/3).
no_follow(prolog_predicate_edit/5).
no_follow(prolog_edit_destination/3).
no_follow(prolog_code/3).
no_follow(prolog_clause/2).
no_follow(prolog_unique_clauses/2).
no_follow(prolog_changed_suffix/4).
no_follow(prolog_edit_tail/5).
no_follow(prolog_retract_goals/3).
no_follow(prolog_assert_goals/3).
no_follow(prolog_goal_tree/4).

prolog_clauses(Source, Clauses) :-
    '$quod_program_source'(Clauses, Source).

%% A local source-draft transformation only. The existing guarded compiler and
%% explicit Preview/Accept retain the original baseline, ACLs and outcome owner.
%% These edits are raw authored facts; removal is never a cascade/domain delete.
prolog_workbench_draft(Source, Change, Chunk) :-
    term_variables([Source, Change], []),
    '$quod_program_source'(Program, Source),
    workbench_change(Change, Program, Next),
    source_chunk_bytes(Bytes), '$quod_source_chunk'(terms(Next), Bytes, Chunk).
%% The existing source-indicator primitive recognizes wire atom symbols without
%% allocating them. A not-yet-authored class/name must remain data at this step.
workbench_symbol(Symbol) :- nonvar(Symbol), '$quod_source_indicator'(Symbol, Symbol/0).
workbench_fact(isa(C, P)) :- workbench_symbol(C), workbench_symbol(P).
workbench_fact(instance_of(C, I)) :- workbench_symbol(C), term_variables(I, []).
workbench_fact(attribute(I, K, V)) :- term_variables([I, K, V], []), workbench_symbol(K).
workbench_change(add(Fact), Program, Next) :-
    workbench_fact(Fact), Fact \= instance_of(_, _),
    (workbench_member(Fact, Program) -> fail_with_reason(fact_already_present)
    ; append(Program, [Fact], Next)).
workbench_change(remove(Fact), Program, Next) :-
    workbench_fact(Fact), workbench_remove(Program, Fact, Next).
workbench_change(replace(Before, After), Program, Next) :-
    workbench_fact(Before), workbench_fact(After),
    functor(Before, Kind, Arity), functor(After, Kind, Arity),
    After \= instance_of(_, _),
    (workbench_same(Before, After) -> workbench_member(Before, Program), Next = Program
    ; workbench_remove(Program, Before, Rest),
      (workbench_member(After, Rest) -> fail_with_reason(fact_already_present)
      ; append(Rest, [After], Next))).
%% Ground wire symbols and their already-materialized atoms name the same fact.
%% Reuse the source compiler's canonical identity; never allocate input atoms.
workbench_same(A, B) :-
    term_variables([A, B], []), prolog_clause(A, CA), prolog_clause(B, CB),
    term_digest(CA, D), term_digest(CB, D).
workbench_member(Fact, Program) :- member(Current, Program), workbench_same(Fact, Current), !.
workbench_remove([Fact | Rest], Expected, Rest) :- workbench_same(Fact, Expected), !.
workbench_remove([Fact | Rest], Expected, [Fact | Next]) :-
    workbench_remove(Rest, Expected, Next).
workbench_remove([], _, _) :- fail_with_reason(fact_not_present).

%% One target inspection path. Catalogued system access is explicit and does
%% not fall back to an API subset if a retained target lacks the read wrapper.
%% Other targets retain their ordinary admission policy (including ownership).
prolog_inspect(ontology_ref(Namespace, Anchor), Query, Result) :-
    quod:root::(current_ontology_identity(<<"quod:root">>, _),
                system_source_access(ontology_ref(Namespace, Anchor), _)),
    !,
    Namespace::(current_ontology_identity(Namespace, Anchor),
                system_prolog_introspection(Query, Result)).
prolog_inspect(ontology_ref(Namespace, Anchor), Query, Result) :-
    %% Only a foreign target supplies a fresh ordinary admission boundary.
    %% Self-inspection requires the Root grant above; local asks reuse this scope.
    \+ current_ontology_identity(Namespace, Anchor),
    Namespace::(current_ontology_identity(Namespace, Anchor),
                prolog_introspection(Query, Result)).

prolog_predicates(Target, Indicators) :-
    prolog_inspect(Target, predicates, Indicators).

%% The default lens returns the entire frozen current state in bounded cursor
%% answers. Explicit predicate selection belongs to the lens ontology as well.
prolog_source(Target, Chunk) :-
    view(<<"ontology_source">>, [Target], Chunk).
prolog_source(Target, Indicator, Source) :-
    view(<<"predicate_source">>, [Target, Indicator], Source).

%% Source is data while this goal is compiled. The caller submits the explicit
%% returned assertz/retract goals through normal signed admission; new callable
%% symbols therefore use the same atom accounting as handwritten goals.
%% Source checks return no scratch bindings: the durable result must not
%% duplicate the inspected program. The ordinary transaction composes inside
%% actions and other transactions with their existing savepoint semantics.
prolog_edit_goal(Target, Selection, ExpectedSource, DraftSource, Edit) :-
    Target = ontology_ref(Namespace, Anchor),
    term_variables([Namespace, Anchor, Selection], []),
    '$quod_program_source'(ExpectedProgram, ExpectedSource),
    '$quod_program_source'(DraftProgram, DraftSource),
    prolog_code(ExpectedProgram, ExpectedClauses, ExpectedEntries),
    prolog_code(DraftProgram, DraftClauses, DraftEntries),
    prolog_unique_clauses(DraftEntries, Selection),
    prolog_edit_body(Selection, ExpectedClauses, DraftClauses,
                     ExpectedEntries, DraftEntries, Body),
    TargetEdit = Namespace::(current_ontology_identity(Namespace, Anchor),
                             transaction(Body)),
    prolog_edit_destination(Target, TargetEdit, Edit).

%% Complete text has the same canonical predicate ordering as the source lens.
%% Each changed predicate keeps its ordered common prefix. Unchanged predicates
%% (including runtime-owned and shared definitions) generate no mutations.
%% The guard reads one coherent snapshot. Ordinary predicate version tokens
%% protect every inspected and newly edited definition through Accept.
prolog_edit_body(all, _, _, ExpectedEntries, DraftEntries,
                 (Guard, Changes)) :-
    !,
    prolog_ordered_clauses(ExpectedEntries, ExpectedClauses),
    '$quod_program_source'(ExpectedClauses, CanonicalExpected),
    term_digest(CanonicalExpected, ExpectedDigest),
    binary_codes(CanonicalExpected, Bytes), length(Bytes, Length),
    (Length > 0 -> ChunkBytes = Length ; ChunkBytes = 1),
    Guard = (findall(Kind-Digest,
                    ('$quod_source_chunk'(all, ChunkBytes, source_chunk(Kind, Current)),
                     term_digest(Current, Digest)), [done-ExpectedDigest])
             -> true ; fail_with_reason(edit_conflict(all))),
    prolog_grouped_entries(ExpectedEntries, ExpectedGroups),
    prolog_grouped_entries(DraftEntries, DraftGroups),
    prolog_predicate_edits(ExpectedGroups, DraftGroups, Goals),
    (Goals = [] -> Changes = true
    ; length(Goals, Count), prolog_goal_tree(Count, Goals, [], Changes)).
prolog_edit_body(Indicator, ExpectedClauses, DraftClauses, ExpectedEntries, DraftEntries,
                 (Guard, Tail)) :-
    '$quod_program_source'(ExpectedClauses, CanonicalExpected),
    '$quod_program_source'(DraftClauses, CanonicalDraft),
    Guard = ('$quod_predicate_source'(Indicator, CanonicalExpected)
             -> true ; fail_with_reason(edit_conflict(Indicator))),
    prolog_changed_suffix(ExpectedEntries, DraftEntries, Remove, Add),
    prolog_edit_tail(Remove, Add, Indicator, CanonicalDraft, Tail).

%% Across-predicate order is presentation; within-predicate clause order is
%% semantic. Normalize both opened baselines and subsequent saved drafts alike.
prolog_ordered_clauses(Entries, Clauses) :-
    prolog_keyed_entries(Entries, Sorted),
    findall(Clause, member(_-code(_, _, Clause), Sorted), Clauses).

prolog_keyed_entries(Entries, Sorted) :-
    prolog_numbered_entries(Entries, 0, Keyed),
    sort(Keyed, Sorted).
prolog_numbered_entries([], _, []).
prolog_numbered_entries([code(Source, Clause) | Entries], Index,
                       [Indicator-code(Index, Source, Clause) | Keyed]) :-
    '$quod_source_indicator'(Clause, Indicator),
    Next is Index + 1,
    prolog_numbered_entries(Entries, Next, Keyed).

prolog_grouped_entries(Entries, Groups) :-
    prolog_keyed_entries(Entries, Sorted),
    prolog_groups(Sorted, Groups).
prolog_groups([], []).
prolog_groups([Indicator-code(_, Source, Clause) | Rest], [predicate(Indicator, [code(Source, Clause) | Entries]) | Groups]) :-
    prolog_group_tail(Rest, Indicator, Entries, Tail),
    prolog_groups(Tail, Groups).
prolog_group_tail([Indicator-code(_, Source, Clause) | Rest], Indicator, [code(Source, Clause) | Entries], Tail) :-
    !, prolog_group_tail(Rest, Indicator, Entries, Tail).
prolog_group_tail(Tail, _, [], Tail).

prolog_predicate_edits([], [], []).
prolog_predicate_edits([predicate(I, Before) | Expected], [predicate(I, After) | Draft], Goals) :-
    !,
    prolog_predicate_edits(Expected, Draft, Tail),
    prolog_predicate_edit(I, Before, After, Tail, Goals).
prolog_predicate_edits([predicate(I, Before) | Expected], Draft, Goals) :-
    (Draft = [] ; Draft = [predicate(J, _) | _], I @< J),
    !,
    prolog_predicate_edits(Expected, Draft, Tail),
    prolog_predicate_edit(I, Before, [], Tail, Goals).
prolog_predicate_edits(Expected, [predicate(I, After) | Draft], Goals) :-
    prolog_predicate_edits(Expected, Draft, Tail),
    prolog_predicate_edit(I, [], After, Tail, Goals).

prolog_predicate_edit(Indicator, Before, After, Tail, Goals) :-
    prolog_changed_suffix(Before, After, Remove, Add),
    (Remove = [], Add = [] -> Goals = Tail
    ; findall(Clause, member(code(_, Clause), After), Clauses),
      '$quod_program_source'(Clauses, CanonicalDraft),
      prolog_edit_tail(Remove, Add, Indicator, CanonicalDraft, Goal),
      Goals = [Goal | Tail]).

%% Root already authorizes its administrator's exact direct transaction. Keep
%% that existing path rather than adding a second root self-edit wrapper.
prolog_edit_destination(
        ontology_ref(<<"quod:root">>, _), TargetEdit, TargetEdit) :- !.
prolog_edit_destination(
        ontology_ref(Namespace, Anchor),
        Namespace::(current_ontology_identity(Namespace, Anchor),
                    transaction(Body)),
        Namespace::(current_ontology_identity(Namespace, Anchor),
                    system_prolog_edit,
                    transaction(Body))) :-
    %% Unit-local and other unanchored compiler uses have no scope in which to
    %% ask root. They retain the ordinary direct target edit; signed requests
    %% have a principal and may select this administrator wrapper.
    current_principal(_),
    quod:root::(current_ontology_identity(<<"quod:root">>, _),
                system_source_access(
                    ontology_ref(Namespace, Anchor), editable)),
    !.
prolog_edit_destination(_, TargetEdit, TargetEdit).

%% Compare ground source keys, never unify two clauses to test equality.
%% The bridge numbers variables independently for each printed clause.
prolog_code([], [], []).
prolog_code([Term | Terms], [Clause | Clauses], [code(Source, Clause) | Entries]) :-
    prolog_clause(Term, Clause),
    '$quod_program_source'([Clause], Source),
    prolog_code(Terms, Clauses, Entries).

prolog_clause((Head :- Body), (Head :- Body)) :- !.
prolog_clause(Head, (Head :- true)).

prolog_unique_clauses(Entries, Indicator) :-
    findall(Source, member(code(Source, _), Entries), Sources),
    sort(Sources, Unique), length(Sources, Count),
    (length(Unique, Count) -> true ; fail_with_reason(duplicate_clause(Indicator))).

prolog_changed_suffix([code(Source, _) | Expected], [code(Source, _) | Draft], Remove, Add) :-
    !, prolog_changed_suffix(Expected, Draft, Remove, Add).
prolog_changed_suffix(Expected, Draft, Expected, Draft).

prolog_edit_tail([], [], _, _, true) :- !.
prolog_edit_tail(Remove, Add, Indicator, CanonicalDraft, Goal) :-
    Check = ('$quod_predicate_source'(Indicator, CanonicalDraft) -> true ; fail_with_reason(edit_not_representable(Indicator))),
    prolog_assert_goals(Add, [Check], Assertions),
    prolog_retract_goals(Remove, Assertions, Goals),
    length(Goals, Count), prolog_goal_tree(Count, Goals, [], Goal).

prolog_retract_goals([], Tail, Tail).
prolog_retract_goals([code(_, Clause) | Clauses], Tail,
                     ['$quod_retract_exact'(Clause) | Rest]) :-
    prolog_retract_goals(Clauses, Tail, Rest).

prolog_assert_goals([], Tail, Tail).
prolog_assert_goals([code(_, Clause) | Clauses], Tail, [assertz(Clause) | Rest]) :-
    prolog_assert_goals(Clauses, Tail, Rest).

%% Association changes no execution order. Balanced ordinary conjunctions keep
%% clause count from consuming the shared structural-depth allowance linearly.
prolog_goal_tree(1, [Goal | Rest], Rest, Goal) :- !.
prolog_goal_tree(Count, Goals, Rest, (Left, Right)) :-
    LeftCount is Count // 2, RightCount is Count - LeftCount,
    prolog_goal_tree(LeftCount, Goals, Middle, Left),
    prolog_goal_tree(RightCount, Middle, Rest, Right).

%% Generic source and inspection eidolons. Their target remains the owning ontology;
%% no source or class definitions are copied into this recipe ontology.


isa(prolog_editor, eidolon).

eidolon(prolog_editor, Subject, View) :- eidolon(prolog_editor(all), Subject, View).
eidolon(prolog_editor(Selection), subject(Target, Entity),
        workspace(prolog_editor(Selection), Target, Entity, ontology_ref(Tools, ToolsAnchor), View)) :-
    (Selection == all -> true
    ; prolog_predicates(Target,Indicators), member(Selection,Indicators)),
    Target = ontology_ref(_, _), term_variables(Target-Entity, []),
    current_ontology_identity(Tools, ToolsAnchor),
    prolog_inspect(Target, presentation, Mode),
    prolog_access_view(Mode, ViewId),
    gui_view(ViewId, View).

eidolon(Style, subject(Target, Target),
        lens_view(Target, Target, ontology_ref(Lens, Anchor), View, [Target])) :-
    Target = ontology_ref(_, _), term_variables(Target, []),
    inspection_lens(Style, View),
    current_ontology_identity(Lens, Anchor),
    prolog_inspect(Target, identity, Target).

inspection_lens(policy, <<"ontology_policy">>).
inspection_lens(interfaces, <<"ontology_interfaces">>).
inspection_lens(routes, <<"ontology_routes">>).

prolog_access_view(editable, prolog_editor).
prolog_access_view(read_only, prolog_source).

%% A bounded graphical encoding of the same inspected ontology. No namespace,
%% instance or predicate identity is invented by a node or layout occurrence.
lens(<<"ontology_graph">>, <<"authored classes, memberships and attributes">>).
encoding(<<"ontology_graph">>, <<"ontology_graph">>, <<"quod:gui">>).
encoding_layout(<<"ontology_graph">>, <<"ontology_graph">>).
rows(<<"ontology_graph">>, [Target], [graph(Target, Content)]) :-
    prolog_inspect(Target, workbench, Content).
laid_out(Encoding, _, [graph(Target, Content)], Graph) :-
    encoding_layout(Encoding, <<"ontology_graph">>),
    workbench_graph(Target, Content, Graph).

eidolon(workbench, subject(Target, Target),
        workbench(Target, Target, ontology_ref(Tools, Anchor), Graph, Controls, Workspace)) :-
    current_ontology_identity(Tools, Anchor),
    prolog_inspect(Target, presentation, Mode), prolog_access_view(Mode, View),
    gui_view(View, Workspace), view(<<"ontology_graph">>, [Target], Graph),
    gui_workspace(<<"Ontology workbench">>,
        [catalogue_selection(node, <<"Class or instance">>),
         catalogue_selection(fact, <<"Relations and attributes">>),
         button(new_class, <<"New class">>), button(new_attribute, <<"Add text attribute">>),
         button(edit_fact, <<"Edit selected fact">>),
         button(remove_fact, <<"Prepare fact removal (no cascade)">>),
         button(open_subject, <<"View selected subject / actions">>),
         text_box(class_name, <<"Class name">>), catalogue_selection(parent, <<"Parent class">>),
         text_box(attribute_name, <<"Attribute name">>), text_box(attribute_value, <<"Text value">>),
         button(add_class, <<"Prepare class">>),
         button(add_attribute, <<"Prepare text attribute">>),
         button(replace_fact, <<"Prepare replacement">>), button(cancel_edit, <<"Back to inspection">>),
         button(show_source, <<"Source draft / Preview / Save">>),
         button(exact_details, <<"Exact selected data / limits">>)], Controls).

workbench_graph(ontology_ref(Ns, A), content(Parents, Members, Attributes),
                graph(Nodes, Facts, Marks)) :-
    findall(C, (member(isa(C, _), Parents); member(isa(_, C), Parents);
                member(instance_of(C, _), Members)), C0), sort(C0, Classes),
    findall(I, member(instance_of(_, I), Members), I0), sort(I0, Instances),
    findall(node(class, class_ref(Ns, A, C)), member(C, Classes), CN),
    findall(node(instance, entity_ref(Ns, A, I)), member(I, Instances), IN),
    append(CN, IN, Nodes), length(Nodes, Count), lens_limit(<<"marks">>, Limit),
    (Count =< Limit -> true ; fail_with_reason(workbench_limit(marks, Count, Limit))),
    append(Parents, Members, PM), append(PM, Attributes, Facts),
    workbench_marks(Nodes, Ns, A, 0, NodeMarks),
    workbench_links(PM, Nodes, Ns, A, 0, Links), append(NodeMarks, Links, Marks),
    length(Marks, MarkCount),
    (MarkCount =< Limit -> true ; fail_with_reason(workbench_limit(marks, MarkCount, Limit))).
workbench_marks([], _, _, _, []).
workbench_marks([node(Kind, Ref) | Rest], Ns, A, Index, [Mark | Marks]) :-
    workbench_position(Index, X, Y),
    mark_id(Index, Id),
    (Kind == class -> Shape = <<"box">>, Colour = <<"#F9C80E">>,
       Sizes = [f(<<"width">>, 800), f(<<"height">>, 500), f(<<"depth">>, 200)], Depicted = Ref
    ; Shape = <<"sphere">>, Colour = <<"#6A90D9">>,
      Sizes = [f(<<"diameter">>, 500)], Ref = entity_ref(Ns, A, Depicted)),
    Ref =.. [_ | RefParts], append(_, [Local], RefParts),
    '$quod_program_source'([Local], Text), shorten(Text, Label),
    Mark = mark(Id, Shape, Sizes, transform(X, Y, 0, 0, 0, 0),
                surface(Colour, 0, 900, 0, []), label(Label, <<"above">>), depicts(Ns, A, Depicted)),
    Next is Index + 1, workbench_marks(Rest, Ns, A, Next, Marks).
workbench_links([], _, _, _, _, []).
workbench_links([Fact | Rest], Nodes, Ns, A, Index, Marks) :-
    (Fact = isa(C, P) -> Left = class_ref(Ns, A, C), Right = class_ref(Ns, A, P), Colour = <<"#F9C80E">>
    ; Fact = instance_of(C, I), Left = entity_ref(Ns, A, I), Right = class_ref(Ns, A, C), Colour = <<"#6A90D9">>),
    workbench_index(Nodes, Left, 0, L), workbench_index(Nodes, Right, 0, R),
    workbench_position(L, X1, Y1), workbench_position(R, X2, Y2),
    Width is abs(X2 - X1) + 20, Height is abs(Y2 - Y1) + 20,
    X is (X1 + X2) // 2, Y is (Y1 + Y2) // 2, Z is -200,
    mark_id(Index, Base), binary_codes(Base, Codes),
    binary_codes(H, [104 | Codes]), binary_codes(V, [118 | Codes]),
    Surface = surface(Colour, 0, 900, 0, []),
    Horizontal = mark(H, <<"box">>, [f(<<"width">>, Width), f(<<"height">>, 20), f(<<"depth">>, 20)],
                      transform(X, Y1, Z, 0, 0, 0), Surface, unlabelled, depicts_nothing),
    Vertical = mark(V, <<"box">>, [f(<<"width">>, 20), f(<<"height">>, Height), f(<<"depth">>, 20)],
                    transform(X2, Y, Z, 0, 0, 0), Surface, unlabelled, depicts_nothing),
    Next is Index + 1, workbench_links(Rest, Nodes, Ns, A, Next, More),
    Marks = [Horizontal, Vertical | More].
workbench_index([node(_, Ref) | _], Ref, Index, Index) :- !.
workbench_index([_ | Rest], Ref, Index, Result) :-
    Next is Index + 1, workbench_index(Rest, Ref, Next, Result).
%% Presentation spacing accommodates the existing bounded native captions.
workbench_position(Index, X, Y) :-
    X is (Index mod 6) * 3000, Y is -(Index // 6) * 1200.

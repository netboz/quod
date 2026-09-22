%% quod:licence — what a combined work may be released under, and what it must
%% carry when it is.
%%
%% Licence compatibility is a relation with exceptions, and the obligations that
%% come with it propagate differently for each licence. Both are rules, so the
%% answer to "may I ship this?" is a proof: it names the licence you may use, or
%% the exact pair that forbids it and why.
%%
%% Every identifier — a licence id, a family, an obligation, a component name —
%% is a binary. Only the predicates are symbolic. Licence ids follow SPDX.
%%
%% Model:
%%   licence(Id, Family, Strength)   a known licence; Strength orders copyleft
%%                                   within a family (0 = no copyleft)
%%   permits(Outer, Inner)           an allowance across families
%%   refuses(Outer, Inner, Why)      a known incompatibility, with its reason
%%   obligation(Licence, What)       what a work carrying it must do
%%   component(Work, Part, Licence)  a part of a work, and its licence
%%
%% Asked:
%%   may_include(?Outer, ?Inner)       may a work under Outer include Inner
%%   effective(+Licences, ?Under)      a licence the combination may carry
%%   blocks(+Licences, ?A, ?B, ?Why)   why no licence carries the combination
%%   must_carry(+Licences, ?L, ?What)  the obligations that come with it
%%   ships(?Work, ?Under)              effective/2 over a work's components
%%   notice(?Work, ?Part, ?L, ?What)   one line of the notice file
%%
%% The ledger answers "as the rules stood": a read at an earlier height proves
%% the decision that was correct then, so an old release can be re-checked
%% without reconstructing anything.

acl_sovereign(quod:licence).

%% Anyone may ask what may be shipped. Changing the rules stays with admitted
%% nodes, as in the other system ontologies.
can_invoke(Goal, _Principal, _CallChain, _Ns) :- licence_query(Goal).
can_invoke(_Goal, node(NodeKey), _CallChain, _Ns) :-
    peer_admitted(NodeKey, _, _, NodeKey).
can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).

licence_query(licence(_, _, _)).
licence_query(may_include(_, _)).
licence_query(refuses(_, _, _)).
licence_query(obligation(_, _)).
licence_query(effective(_, _)).
licence_query(blocks(_, _, _, _)).
licence_query(must_carry(_, _, _)).
licence_query(component(_, _, _)).
licence_query(ships(_, _)).
licence_query(notice(_, _, _, _)).
licence_query(unresolved(_, _)).
licence_query(family(_)).
licence_query(isa(_, _)).
licence_query(instance_of(_, _)).
licence_query(have_attribute(_, _, _)).
licence_query(attribute(_, _, _)).

%% --- what may include what ---------------------------------------------------

%% may_include(?Outer, ?Inner): a work released under Outer may include a part
%% released under Inner.
%%
%% What decides it is how far the part's copyleft reaches. A licence whose
%% copyleft stops at the file or the library leaves the rest of the work alone:
%% those files stay under it, you carry its obligations, and the work is
%% released under whatever you like. Only copyleft that reaches the whole work
%% dictates the work's own licence, and then the outer licence must be the same
%% family at that strength or stronger, or hold a stated allowance.
may_include(Outer, Inner) :-
    licence(Outer, OuterFamily, OuterStrength),
    licence(Inner, InnerFamily, InnerStrength),
    \+ refuses(Outer, Inner, _),
    (   InnerStrength < 3
    ;   InnerFamily = OuterFamily, OuterStrength >= InnerStrength
    ;   permits(Outer, Inner)
    ).

%% effective(+Licences, ?Under): a licence the combined work may be released
%% under. Enumerates every one that admits all the parts.
effective(Licences, Under) :-
    licence(Under, _, _),
    \+ ( member(Licence, Licences), \+ may_include(Under, Licence) ).

%% blocks(+Licences, ?A, ?B, ?Why): the pair that stops any licence carrying the
%% combination, and the reason. Asked when effective/2 has no answer.
blocks(Licences, A, B, Why) :-
    member(A, Licences),
    member(B, Licences),
    A @< B,
    \+ may_include(A, B),
    \+ may_include(B, A),
    reason(A, B, Why).

reason(A, B, Why) :- refuses(A, B, Why).
reason(A, B, Why) :- refuses(B, A, Why).
reason(A, B, <<"neither may include the other">>) :-
    \+ refuses(A, B, _),
    \+ refuses(B, A, _).

%% must_carry(+Licences, ?Licence, ?What): an obligation the combined work
%% inherits, and the part's licence it comes from.
must_carry(Licences, Licence, What) :-
    member(Licence, Licences),
    obligation(Licence, What).

%% --- a work and its parts -----------------------------------------------------

%% ships(?Work, ?Under): a licence this work's parts admit.
ships(Work, Under) :-
    findall(Licence, component(Work, _, Licence), Licences),
    effective(Licences, Under).

%% unresolved(?Work, ?Part): a part whose licence nobody has established. A
%% work holding one has nothing it may honestly be released under, which is
%% why NOASSERTION is treated as reaching the whole work.
unresolved(Work, Part) :-
    component(Work, Part, <<"NOASSERTION">>).

%% notice(?Work, ?Part, ?Licence, ?What): one line of the notice a release must
%% carry — the part, its licence, and what that licence asks of you.
notice(Work, Part, Licence, What) :-
    component(Work, Part, Licence),
    obligation(Licence, What).

%% --- the class view -----------------------------------------------------------
%% The house vocabulary of doc/inter-ontology.md and doc/content-layer-design.md,
%% derived from the relations below rather than stored beside them. A family is
%% a class of licences, a licence is one of its instances, and what a licence
%% is and asks of you are its attributes. Nothing here holds knowledge of its
%% own, so the two views cannot disagree.

isa(licence, thing).
isa(work, thing).
isa(Family, licence) :- family(Family).

instance_of(licence, Id) :- licence(Id, _, _).
instance_of(Family, Id) :- licence(Id, Family, _).
instance_of(work, Work) :-
    findall(W, component(W, _, _), Works),
    sort(Works, Unique),
    member(Work, Unique).

have_attribute(licence, family, binary).
have_attribute(licence, reach, integer).
have_attribute(licence, obligation, binary).
have_attribute(work, part, binary).

attribute(Id, family, Family) :- licence(Id, Family, _).
attribute(Id, reach, Reach) :- licence(Id, _, Reach).
attribute(Id, obligation, What) :- obligation(Id, What).
attribute(Work, part, Part) :- component(Work, Part, _).

%% The families, declared rather than scraped, so each is named once and a test
%% can hold every licence to using one that exists.
family(<<"permissive">>).
family(<<"mpl">>).
family(<<"epl">>).
family(<<"gpl">>).
family(<<"cc">>).
family(<<"cc-nc">>).
family(<<"ogl">>).
family(<<"proprietary">>).
family(<<"unknown">>).

%% --- the licences -------------------------------------------------------------
%% Strength is how far the copyleft reaches: 0 nowhere, 1 the files it covers,
%% 2 the library, 3 the whole work, 4 the whole work including use over a
%% network. Only 3 and upwards decide what the combined work may be released
%% under; 1 and 2 travel with their own files and leave obligations behind.

licence(<<"MIT">>, <<"permissive">>, 0).
licence(<<"ISC">>, <<"permissive">>, 0).
licence(<<"BSD-2-Clause">>, <<"permissive">>, 0).
licence(<<"BSD-3-Clause">>, <<"permissive">>, 0).
licence(<<"Apache-2.0">>, <<"permissive">>, 0).
licence(<<"Zlib">>, <<"permissive">>, 0).
licence(<<"Unlicense">>, <<"permissive">>, 0).
licence(<<"CC0-1.0">>, <<"permissive">>, 0).
licence(<<"MPL-2.0">>, <<"mpl">>, 1).
licence(<<"EPL-2.0">>, <<"epl">>, 1).
licence(<<"LGPL-2.1-only">>, <<"gpl">>, 2).
licence(<<"LGPL-3.0-only">>, <<"gpl">>, 2).
licence(<<"GPL-2.0-only">>, <<"gpl">>, 3).
licence(<<"GPL-3.0-only">>, <<"gpl">>, 3).
licence(<<"AGPL-3.0-only">>, <<"gpl">>, 4).
licence(<<"CC-BY-4.0">>, <<"cc">>, 0).
licence(<<"CC-BY-SA-4.0">>, <<"cc">>, 3).
licence(<<"CC-BY-NC-4.0">>, <<"cc-nc">>, 3).
licence(<<"OGL-1.0a">>, <<"ogl">>, 1).
licence(<<"Proprietary">>, <<"proprietary">>, 4).
%% SPDX's own marker for a part whose licence nobody has established. Treated
%% as reaching the whole work, so a work containing one has no licence it may
%% be released under until somebody resolves it. That refusal is the point.
licence(<<"NOASSERTION">>, <<"unknown">>, 4).

%% Allowances across families, each one a deliberate reading of the licences.
permits(<<"GPL-3.0-only">>, <<"MPL-2.0">>).
permits(<<"AGPL-3.0-only">>, <<"MPL-2.0">>).
permits(<<"GPL-2.0-only">>, <<"MPL-2.0">>).
permits(<<"GPL-3.0-only">>, <<"LGPL-2.1-only">>).
permits(<<"GPL-3.0-only">>, <<"LGPL-3.0-only">>).
permits(<<"GPL-2.0-only">>, <<"LGPL-2.1-only">>).
permits(<<"AGPL-3.0-only">>, <<"GPL-3.0-only">>).
permits(<<"AGPL-3.0-only">>, <<"LGPL-3.0-only">>).
permits(<<"GPL-3.0-only">>, <<"CC-BY-SA-4.0">>).
permits(<<"Proprietary">>, <<"CC-BY-NC-4.0">>).
permits(<<"Proprietary">>, <<"OGL-1.0a">>).

%% Known incompatibilities. The reason travels with the refusal because a bare
%% "incompatible" is useless in an argument.
refuses(<<"GPL-2.0-only">>, <<"Apache-2.0">>,
        <<"Apache-2.0 adds patent terms GPL-2.0 treats as a further restriction">>).
refuses(<<"GPL-2.0-only">>, <<"GPL-3.0-only">>,
        <<"GPL-2.0-only cannot take in work that must stay under GPL-3.0">>).
refuses(<<"GPL-3.0-only">>, <<"GPL-2.0-only">>,
        <<"GPL-2.0-only forbids relicensing to GPL-3.0, so the two never meet">>).
refuses(<<"AGPL-3.0-only">>, <<"GPL-2.0-only">>,
        <<"GPL-2.0-only forbids relicensing to AGPL-3.0">>).
refuses(<<"GPL-2.0-only">>, <<"LGPL-3.0-only">>,
        <<"LGPL-3.0 relicenses to GPL-3.0, which GPL-2.0-only cannot accept">>).
refuses(<<"GPL-3.0-only">>, <<"AGPL-3.0-only">>,
        <<"the network-use condition would be dropped">>).
refuses(<<"MIT">>, <<"CC-BY-NC-4.0">>,
        <<"a non-commercial condition cannot be carried by a permissive licence">>).
refuses(<<"Apache-2.0">>, <<"CC-BY-NC-4.0">>,
        <<"a non-commercial condition cannot be carried by a permissive licence">>).

%% --- what each licence asks of you --------------------------------------------

obligation(<<"MIT">>, <<"keep the copyright notice and licence text">>).
obligation(<<"ISC">>, <<"keep the copyright notice and licence text">>).
obligation(<<"BSD-2-Clause">>, <<"keep the copyright notice and licence text">>).
obligation(<<"BSD-3-Clause">>, <<"keep the copyright notice and licence text">>).
obligation(<<"BSD-3-Clause">>, <<"do not use the authors' names to endorse">>).
obligation(<<"Apache-2.0">>, <<"keep the copyright notice and licence text">>).
obligation(<<"Apache-2.0">>, <<"carry the NOTICE file if the work has one">>).
obligation(<<"Apache-2.0">>, <<"state the changes you made">>).
obligation(<<"Zlib">>, <<"do not misrepresent the origin">>).
obligation(<<"MPL-2.0">>, <<"publish the source of the files you changed">>).
obligation(<<"EPL-2.0">>, <<"publish the source of the files you changed">>).
obligation(<<"LGPL-2.1-only">>, <<"allow the library to be replaced">>).
obligation(<<"LGPL-3.0-only">>, <<"allow the library to be replaced">>).
obligation(<<"GPL-2.0-only">>, <<"publish the source of the whole work">>).
obligation(<<"GPL-3.0-only">>, <<"publish the source of the whole work">>).
obligation(<<"AGPL-3.0-only">>, <<"publish the source of the whole work">>).
obligation(<<"AGPL-3.0-only">>, <<"offer the source to anyone using it over a network">>).
obligation(<<"CC-BY-4.0">>, <<"credit the author and say if you changed it">>).
obligation(<<"CC-BY-SA-4.0">>, <<"credit the author and say if you changed it">>).
obligation(<<"CC-BY-SA-4.0">>, <<"license your version the same way">>).
obligation(<<"CC-BY-NC-4.0">>, <<"do not use it commercially">>).
obligation(<<"OGL-1.0a">>, <<"carry the section 15 copyright notice">>).
obligation(<<"OGL-1.0a">>, <<"name the Open Game Content you use">>).
obligation(<<"NOASSERTION">>, <<"establish this part's licence before shipping">>).
obligation(<<"Unlicense">>, <<"nothing; it is dedicated to the public domain">>).

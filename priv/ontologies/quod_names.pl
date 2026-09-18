%% quod:names — fantasy personal names, generated and recognised from one set
%% of tables. A system ontology (doc/ontology-actor-architecture.md §2):
%% founded through the ordinary lifecycle, then listed in root as
%% system_ontology(quod:names, Anchor) so every node carries it. Agents get
%% their display labels from it.
%%
%% Ask it with `::`; names are binaries:
%%   quod:names::name(Name, orc, personal, male)     every male orc name
%%   quod:names::name(Class, <<"Ugbash">>)           the pool(s) a name is in
%%   quod:names::draw(orc, personal, male, salt, N)  one name of the selection
%%   quod:names::draw(salt, N)                       one name from any pool
%% Unbound arguments are wildcards. A wider culture (vile, doughty, fantastic)
%% selects every culture under it in the isa tree. draw/5 and draw/2 are fixed
%% by the running proof and the salt (proof_draw/3, a common primitive): same
%% proof, same salt, same name; different agents use different salts.
%%
%% Data: the element tables and listed names below are Open Game Content used
%% under the Open Game License v1.0a — see OGL-1.0a.txt beside this file for
%% the licence and the required Section 15 notice: "The Extraordinary Book of
%% Names, Copyright 2004, Trigee Enterprises Company, Author Malcolm Bowers."
%% Only the pages that source designates as Open Game Content are used (its
%% tables 5-3 to 5-7 and the myth lists on pp. 184-187); its title is Product
%% Identity and appears only in that notice. The source repeats some entries
%% to weight dice; here each element counts once, and the few diaereses are
%% dropped (roel, Kallirrhoe).
%%
%% Model, in the house vocabulary:
%%   name_class(Class, Culture, Kind, Gender)   a pool of names
%%   instance_of(Class, Name)                   pool listed name by name
%%   recipe(Class, Recipe)                      pool described by a recipe
%%   isa(Culture, Wider)                        culture tree, rooted at thing
%%
%% Recipes:
%%   element(Table)         one element of Table/1
%%   concat(Recipes)        the recipes glued together
%%   join(Sep, Recipes)     the recipes with Sep between the parts
%%   one_of(Recipes)        any one of the recipes
%%   rep(Min, Max, Recipe)  inside concat/join: Min to Max parts from Recipe
%% Elements are lowercase atoms. A built name is capitalised at its start and
%% after every separator (Ugbash, Bul-Suhi-Yih). Recognition runs the same
%% recipe backwards over the name's bytes, so a name in several pools is
%% reported once per pool (Dain is both a listed Norse dwarf and da+in).
%% Names never become atoms: binary_codes/2 (common primitive) turns the byte
%% list into the binary and back.

acl_sovereign(quod:names).

%% Anyone may ask the naming questions. Changing tables, recipes or rules stays
%% with admitted nodes, as in the other system ontologies.
can_invoke(Goal, _Principal, _CallChain, _Ns) :- naming_query(Goal).
can_invoke(_Goal, node(NodeKey), _CallChain, _Ns) :-
    peer_admitted(NodeKey, _, _, NodeKey).
can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).

naming_query(name(_, _)).
naming_query(name(_, _, _, _)).
naming_query(count(_, _, _, _)).
naming_query(name_nth(_, _, _, _, _)).
naming_query(draw(_, _, _, _, _)).
naming_query(draw(_, _)).

%% --- public predicates -------------------------------------------------------

%% name(?Class, ?Name): Name belongs to the pool Class.
name(Class, Name) :-
    name_class(Class, _, _, _),
    (   nonvar(Name) -> recognise(Class, Name)
    ;   generate(Class, Name)
    ).

%% name(?Name, ?Culture, ?Kind, ?Gender): Name belongs to a pool of the
%% selection. Names are enumerated pool by pool, in pool order.
name(Name, Culture, Kind, Gender) :-
    pool(Class, Culture, Kind, Gender),
    name(Class, Name).

%% count(?Culture, ?Kind, ?Gender, -N): how many names the selection holds.
count(Culture, Kind, Gender, N) :-
    findall(Size, (pool(Class, Culture, Kind, Gender), pool_size(Class, Size)),
            Sizes),
    sum(Sizes, N).

%% name_nth(?Culture, ?Kind, ?Gender, +I, -Name): the I-th name (from 0) of the
%% selection, in name/4 order, computed without listing the others.
name_nth(Culture, Kind, Gender, I, Name) :-
    integer(I), I >= 0,
    findall(Class, pool(Class, Culture, Kind, Gender), Classes),
    pools_nth(Classes, I, Name).

%% draw(?Culture, ?Kind, ?Gender, +Salt, -Name): one name of the selection,
%% every name equally likely.
draw(Culture, Kind, Gender, Salt, Name) :-
    count(Culture, Kind, Gender, N),
    N > 0,
    proof_draw(Salt, N, I),
    name_nth(Culture, Kind, Gender, I, Name).

%% draw(+Salt, -Name): one name from any pool — every pool equally likely,
%% then every name of that pool equally likely (so small cultures are not
%% drowned by the million cave-man names).
draw(Salt, Name) :-
    findall(Class, name_class(Class, _, _, _), Classes),
    length(Classes, Pools),
    proof_draw(pool(Salt), Pools, K),
    nth_(K, Classes, Class),
    pool_size(Class, Size),
    proof_draw(Salt, Size, I),
    pool_nth(Class, I, Name).

%% --- selection ---------------------------------------------------------------

%% pool(?Class, ?Culture, ?Kind, ?Gender): Class is a pool of the selection.
%% An unbound Culture is bound to the pool's own culture; a bound one may be
%% the pool's culture or any wider one.
pool(Class, Culture, Kind, Gender) :-
    name_class(Class, Own, Kind, Gender),
    (   var(Culture) -> Culture = Own
    ;   isa_star(Own, Culture)
    ).

isa_star(Culture, Culture).
isa_star(Culture, Wider) :- isa(Culture, Between), isa_star(Between, Wider).

pool_size(Class, N) :-
    (   recipe(Class, Recipe) -> size(Recipe, N)
    ;   findall(Name, instance_of(Class, Name), Names), length(Names, N)
    ).

pools_nth([Class | Classes], I, Name) :-
    pool_size(Class, Size),
    (   I < Size -> pool_nth(Class, I, Name)
    ;   J is I - Size, pools_nth(Classes, J, Name)
    ).

pool_nth(Class, I, Name) :-
    (   recipe(Class, Recipe) ->
        nth(Recipe, I, Lower, []),
        title(Lower, Codes),
        binary_codes(Name, Codes)
    ;   findall(Listed, instance_of(Class, Listed), Names),
        nth_(I, Names, Name)
    ).

generate(Class, Name) :- instance_of(Class, Name).
generate(Class, Name) :-
    recipe(Class, Recipe),
    build(Recipe, Lower, []),
    title(Lower, Codes),
    binary_codes(Name, Codes).

%% binary_codes/2 fails plainly for anything that is not a binary.
recognise(Class, Name) :- instance_of(Class, Name).
recognise(Class, Name) :-
    recipe(Class, Recipe),
    binary_codes(Name, Codes),
    title(Lower, Codes),
    build(Recipe, Lower, []).

%% --- recipes: build (both ways), size, nth ------------------------------------
%% build/3 and nth/4 walk a recipe over a difference list of byte codes. With
%% the codes unbound build/3 enumerates names; with them bound it parses.
%% nth/4 picks the I-th name in build/3's order: in a sequence the first part
%% is the most significant digit, so the last part varies fastest.

build(element(Table), Cs0, Cs) :-
    table(Table),
    Goal =.. [Table, Element],
    call(Goal),
    emit(Element, Cs0, Cs).
build(one_of(Recipes), Cs0, Cs) :-
    member(Recipe, Recipes),
    build(Recipe, Cs0, Cs).
build(concat(Recipes), Cs0, Cs) :-
    seq(Recipes, [], [], Cs0, Cs).
build(join(Sep, Recipes), Cs0, Cs) :-
    atom_codes(Sep, SepCodes),
    seq(Recipes, [], SepCodes, Cs0, Cs).

%% seq(Parts, Lead, Sep, Cs0, Cs): Lead goes before the next part, Sep before
%% every part after it.
seq([], _, _, Cs, Cs).
seq([Part | Parts], Lead, Sep, Cs0, Cs) :-
    append(Lead, Cs1, Cs0),
    part(Part, Sep, Cs1, Cs2),
    seq(Parts, Sep, Sep, Cs2, Cs).

part(rep(Min, Max, Recipe), Sep, Cs0, Cs) :- !,
    between_(Min, Max, N),
    copies(N, Recipe, Copies),
    seq(Copies, [], Sep, Cs0, Cs).
part(Recipe, _, Cs0, Cs) :-
    build(Recipe, Cs0, Cs).

emit(Element, Cs0, Cs) :-
    atom_codes(Element, ElementCodes),
    append(ElementCodes, Cs, Cs0).

size(element(Table), N) :- elements(Table, Elements), length(Elements, N).
size(one_of(Recipes), N) :- sizes(Recipes, Sizes), sum(Sizes, N).
size(concat(Recipes), N) :- seq_size(Recipes, N).
size(join(_, Recipes), N) :- seq_size(Recipes, N).

sizes([], []).
sizes([Recipe | Recipes], [Size | Sizes]) :-
    size(Recipe, Size),
    sizes(Recipes, Sizes).

seq_size([], 1).
seq_size([Part | Parts], N) :-
    part_size(Part, Size),
    seq_size(Parts, Rest),
    N is Size * Rest.

part_size(rep(Min, Max, Recipe), N) :- !,
    size(Recipe, Size),
    rep_size(Min, Max, Size, N).
part_size(Recipe, N) :-
    size(Recipe, N).

%% rep_size(Min, Max, Size, N): Size^Min + ... + Size^Max.
rep_size(Min, Max, _, 0) :- Min > Max, !.
rep_size(Min, Max, Size, N) :-
    power(Size, Min, P),
    Next is Min + 1,
    rep_size(Next, Max, Size, Rest),
    N is P + Rest.

nth(element(Table), I, Cs0, Cs) :-
    elements(Table, Elements),
    nth_(I, Elements, Element),
    emit(Element, Cs0, Cs).
nth(one_of(Recipes), I, Cs0, Cs) :-
    one_of_nth(Recipes, I, Cs0, Cs).
nth(concat(Recipes), I, Cs0, Cs) :-
    seq_nth(Recipes, I, [], [], Cs0, Cs).
nth(join(Sep, Recipes), I, Cs0, Cs) :-
    atom_codes(Sep, SepCodes),
    seq_nth(Recipes, I, [], SepCodes, Cs0, Cs).

one_of_nth([Recipe | Recipes], I, Cs0, Cs) :-
    size(Recipe, Size),
    (   I < Size -> nth(Recipe, I, Cs0, Cs)
    ;   J is I - Size, one_of_nth(Recipes, J, Cs0, Cs)
    ).

seq_nth([], 0, _, _, Cs, Cs).
seq_nth([Part | Parts], I, Lead, Sep, Cs0, Cs) :-
    seq_size(Parts, Rest),
    Own is I // Rest,
    Next is I mod Rest,
    append(Lead, Cs1, Cs0),
    part_nth(Part, Own, Sep, Cs1, Cs2),
    seq_nth(Parts, Next, Sep, Sep, Cs2, Cs).

part_nth(rep(Min, Max, Recipe), I, Sep, Cs0, Cs) :- !,
    size(Recipe, Size),
    rep_nth(Min, Max, Size, I, N, J),
    copies(N, Recipe, Copies),
    seq_nth(Copies, J, [], Sep, Cs0, Cs).
part_nth(Recipe, I, _, Cs0, Cs) :-
    nth(Recipe, I, Cs0, Cs).

%% rep_nth(Min, Max, Size, I, N, J): the I-th repetition is the J-th among
%% those with N parts.
rep_nth(Min, Max, Size, I, N, J) :-
    Min =< Max,
    power(Size, Min, P),
    (   I < P -> N = Min, J = I
    ;   K is I - P, Next is Min + 1, rep_nth(Next, Max, Size, K, N, J)
    ).

elements(Table, Elements) :-
    table(Table),
    Goal =.. [Table, Element],
    findall(Element, Goal, Elements).

%% --- bytes --------------------------------------------------------------------

%% title(?Lower, ?Title): Title is Lower capitalised at the start and after
%% every separator; either side may be the bound one. Going backwards, a
%% lowercase start is refused, so only the capitalised form names anything.
title([Lower | Lowers], [Upper | Uppers]) :-
    upcase(Lower, Upper),
    title_rest(Lowers, Uppers).

title_rest([], []).
title_rest([Code | Lowers], [Code | Uppers]) :-
    separator(Code), !,
    title(Lowers, Uppers).
title_rest([Code | Lowers], [Code | Uppers]) :-
    title_rest(Lowers, Uppers).

separator(0'-).
separator(32).                  % space

upcase(Lower, Upper) :-
    nonvar(Lower), !,
    (   lower(Lower) -> Upper is Lower - 32
    ;   Upper = Lower
    ).
upcase(Lower, Upper) :-
    \+ lower(Upper),
    (   upper(Upper) -> Lower is Upper + 32
    ;   Lower = Upper
    ).

lower(Code) :- Code >= 0'a, Code =< 0'z.
upper(Code) :- Code >= 0'A, Code =< 0'Z.

%% --- small helpers (erlog has no between/3, nth0/3 or sum_list/2) -------------

between_(Min, Max, Min) :- Min =< Max.
between_(Min, Max, N) :- Min < Max, Next is Min + 1, between_(Next, Max, N).

copies(0, _, []) :- !.
copies(N, Recipe, [Recipe | Copies]) :- N > 0, M is N - 1, copies(M, Recipe, Copies).

nth_(0, [X | _], X) :- !.
nth_(I, [_ | Xs], X) :- I > 0, J is I - 1, nth_(J, Xs, X).

sum([], 0).
sum([X | Xs], N) :- sum(Xs, M), N is X + M.

power(_, 0, 1) :- !.
power(Base, K, P) :- K > 0, J is K - 1, power(Base, J, Q), P is Base * Q.

%% --- the culture tree ---------------------------------------------------------
isa(culture, thing).
isa(fantastic, culture).
isa(vile, fantastic).           % Vile & Crude: table 5-3, by size
isa(goblin, vile).
isa(orc, vile).
isa(ogre, vile).
isa(primitive, fantastic).      % Primitive: table 5-4
isa(doughty, fantastic).        % Doughty & Homely: table 5-5
isa(dwarf, doughty).
isa(gnome, doughty).
isa(halfling, doughty).
isa(fair, fantastic).           % Fair & Noble: table 5-6
isa(elf, fair).
isa(faerie, fantastic).         % Faerykind: table 5-7
isa(spirit, fantastic).         % Nymphs and Sirens: myth lists
isa(nymph, spirit).
isa(siren, spirit).

%% --- the pools ----------------------------------------------------------------
%% name_class(Class, Culture, Kind, Gender). Kind is `personal` throughout
%% this book; epithets, places and taverns are later kinds.
name_class(goblin_male,      goblin,    personal, male).
name_class(goblin_female,    goblin,    personal, female).
name_class(orc_male,         orc,       personal, male).
name_class(orc_female,       orc,       personal, female).
name_class(ogre_male,        ogre,      personal, male).
name_class(ogre_female,      ogre,      personal, female).
name_class(primitive_male,   primitive, personal, male).
name_class(primitive_female, primitive, personal, female).
name_class(dwarf_male,       dwarf,     personal, male).
name_class(dwarf_female,     dwarf,     personal, female).
name_class(norse_dwarf,      dwarf,     personal, male).
name_class(gnome_male,       gnome,     personal, male).
name_class(gnome_female,     gnome,     personal, female).
name_class(halfling_male,    halfling,  personal, male).
name_class(halfling_female,  halfling,  personal, female).
name_class(elf_male,         elf,       personal, male).
name_class(elf_female,       elf,       personal, female).
name_class(faerie_male,      faerie,    personal, male).
name_class(faerie_female,    faerie,    personal, female).
name_class(greek_nymph,      nymph,     personal, female).
name_class(greek_siren,      siren,     personal, female).

%% Vile & Crude: two elements of the size table; females add an ending.
recipe(goblin_male,   concat([element(vile_small), element(vile_small)])).
recipe(goblin_female, concat([element(vile_small), element(vile_small),
                              element(vile_female_ending)])).
recipe(orc_male,      concat([element(vile_medium), element(vile_medium)])).
recipe(orc_female,    concat([element(vile_medium), element(vile_medium),
                              element(vile_female_ending)])).
recipe(ogre_male,     concat([element(vile_large), element(vile_large)])).
recipe(ogre_female,   concat([element(vile_large), element(vile_large),
                              element(vile_female_ending)])).

%% Primitive: one to three hyphenated parts (one or two for females, who
%% carry a sung element at either end).
recipe(primitive_male,   join('-', [rep(1, 3, element(primitive))])).
recipe(primitive_female,
       one_of([join('-', [rep(1, 2, element(primitive)), element(primitive_song)]),
               join('-', [element(primitive_song), rep(1, 2, element(primitive))])])).

%% Doughty & Homely: prefix + gendered suffix; gnomes mix the two tables.
recipe(dwarf_male,      concat([element(doughty_prefix), element(doughty_male)])).
recipe(dwarf_female,    concat([element(doughty_prefix), element(doughty_female)])).
recipe(gnome_male,      concat([element(doughty_prefix), element(homely_male)])).
recipe(gnome_female,    concat([element(doughty_prefix), element(homely_female)])).
recipe(halfling_male,   concat([element(homely_prefix), element(homely_male)])).
recipe(halfling_female, concat([element(homely_prefix), element(homely_female)])).

%% Fair & Noble: prefix + middle + gendered suffix, or prefix + suffix.
recipe(elf_male,
       one_of([concat([element(fair_prefix), element(fair_middle), element(fair_male)]),
               concat([element(fair_prefix), element(fair_male)])])).
recipe(elf_female,
       one_of([concat([element(fair_prefix), element(fair_middle), element(fair_female)]),
               concat([element(fair_prefix), element(fair_female)])])).

%% Faerykind: prefix + gendered suffix.
recipe(faerie_male,   concat([element(spry_prefix), element(spry_male)])).
recipe(faerie_female, concat([element(spry_prefix), element(spry_female)])).

%% --- the element tables ------------------------------------------------------
table(vile_small).       table(vile_medium).      table(vile_large).
table(vile_female_ending).
table(primitive).        table(primitive_song).
table(doughty_prefix).   table(doughty_male).     table(doughty_female).
table(homely_prefix).    table(homely_male).      table(homely_female).
table(fair_prefix).      table(fair_middle).      table(fair_male).
table(fair_female).
table(spry_prefix).      table(spry_male).        table(spry_female).

%% vile_small/1: 100 elements.
vile_small(ach). vile_small(adz). vile_small(ak). vile_small(ark).
vile_small(az). vile_small(balg). vile_small(bilg). vile_small(blid).
vile_small(blig). vile_small(blok). vile_small(blot). vile_small(bolg).
vile_small(bot). vile_small(bug). vile_small(burk). vile_small(dokh).
vile_small(drik). vile_small(driz). vile_small(duf). vile_small(flug).
vile_small(ga). vile_small(gad). vile_small(gag). vile_small(gah).
vile_small(gak). vile_small(gar). vile_small(gat). vile_small(gaz).
vile_small(ghag). vile_small(ghak). vile_small(git). vile_small(glag).
vile_small(glak). vile_small(glat). vile_small(glig). vile_small(gliz).
vile_small(glok). vile_small(gnat). vile_small(gog). vile_small(grak).
vile_small(grat). vile_small(guk). vile_small(hig). vile_small(irk).
vile_small(kak). vile_small(khad). vile_small(krig). vile_small(lag).
vile_small(lak). vile_small(lig). vile_small(likk). vile_small(loz).
vile_small(luk). vile_small(mak). vile_small(maz). vile_small(miz).
vile_small(mub). vile_small(nad). vile_small(nag). vile_small(naz).
vile_small(nig). vile_small(nikk). vile_small(nogg). vile_small(nok).
vile_small(nukk). vile_small(rag). vile_small(rak). vile_small(rat).
vile_small(rok). vile_small(shrig). vile_small(shuk). vile_small(skrag).
vile_small(skug). vile_small(slai). vile_small(slig). vile_small(slog).
vile_small(sna). vile_small(snag). vile_small(snark). vile_small(snat).
vile_small(snig). vile_small(snik). vile_small(snit). vile_small(sog).
vile_small(spik). vile_small(stogg). vile_small(tog). vile_small(urf).
vile_small(vark). vile_small(yad). vile_small(yagg). vile_small(yak).
vile_small(yark). vile_small(yarp). vile_small(yig). vile_small(yip).
vile_small(zat). vile_small(zib). vile_small(zit). vile_small(ziz).

%% vile_medium/1: 100 elements.
vile_medium(ag). vile_medium(aug). vile_medium(bad). vile_medium(bag).
vile_medium(bakh). vile_medium(bash). vile_medium(baz). vile_medium(blag).
vile_medium(brag). vile_medium(brog). vile_medium(bruz). vile_medium(dag).
vile_medium(dakk). vile_medium(darg). vile_medium(dob). vile_medium(dog).
vile_medium(drab). vile_medium(dug). vile_medium(dur). vile_medium(gash).
vile_medium(ghaz). vile_medium(glakh). vile_medium(glaz). vile_medium(glob).
vile_medium(glol). vile_medium(gluf). vile_medium(glur). vile_medium(gnarl).
vile_medium(gnash). vile_medium(gnub). vile_medium(gob). vile_medium(gokh).
vile_medium(gol). vile_medium(golk). vile_medium(gor). vile_medium(grakh).
vile_medium(grash). vile_medium(grath). vile_medium(graz). vile_medium(grot).
vile_medium(grub). vile_medium(grud). vile_medium(gud). vile_medium(gut).
vile_medium(hag). vile_medium(hakk). vile_medium(hrat). vile_medium(hrog).
vile_medium(hrug). vile_medium(khag). vile_medium(khar). vile_medium(krag).
vile_medium(krud). vile_medium(lakh). vile_medium(lash). vile_medium(lob).
vile_medium(lub). vile_medium(lud). vile_medium(luf). vile_medium(luk).
vile_medium(molk). vile_medium(muk). vile_medium(muz). vile_medium(nar).
vile_medium(ogg). vile_medium(olg). vile_medium(rag). vile_medium(rash).
vile_medium(rogg). vile_medium(rorg). vile_medium(rot). vile_medium(rud).
vile_medium(ruft). vile_medium(rug). vile_medium(rut). vile_medium(shad).
vile_medium(shag). vile_medium(shak). vile_medium(shaz). vile_medium(shog).
vile_medium(skar). vile_medium(skulg). vile_medium(slur). vile_medium(snar).
vile_medium(snorl). vile_medium(snub). vile_medium(snurr). vile_medium(sod).
vile_medium(stulg). vile_medium(thak). vile_medium(trog). vile_medium(ug).
vile_medium(umsh). vile_medium(ung). vile_medium(uth). vile_medium(yakh).
vile_medium(yash). vile_medium(yob). vile_medium(zahk). vile_medium(zog).

%% vile_large/1: 100 elements.
vile_large(argh). vile_large(barsh). vile_large(bog). vile_large(burz).
vile_large(dof). vile_large(drok). vile_large(drub). vile_large(drug).
vile_large(dub). vile_large(dug). vile_large(dul). vile_large(dursh).
vile_large(dush). vile_large(duz). vile_large(faug). vile_large(fug).
vile_large(ghakh). vile_large(ghar). vile_large(ghash). vile_large(ghol).
vile_large(ghor). vile_large(ghukk). vile_large(ghul). vile_large(glub).
vile_large(glud). vile_large(glug). vile_large(gluz). vile_large(gom).
vile_large(grad). vile_large(grash). vile_large(grob). vile_large(grogg).
vile_large(grok). vile_large(grol). vile_large(gru). vile_large(gruf).
vile_large(gruk). vile_large(grul). vile_large(grum). vile_large(grumf).
vile_large(grut). vile_large(gruz). vile_large(guhl). vile_large(gulv).
vile_large(hai). vile_large(hrung). vile_large(hur). vile_large(hurg).
vile_large(kai). vile_large(klob). vile_large(krod). vile_large(kug).
vile_large(kulk). vile_large(kur). vile_large(lorg). vile_large(lug).
vile_large(lukh). vile_large(lum). vile_large(lurz). vile_large(lush).
vile_large(luz). vile_large(makh). vile_large(maug). vile_large(molg).
vile_large(mud). vile_large(mug). vile_large(mul). vile_large(murk).
vile_large(muzd). vile_large(nakh). vile_large(narg). vile_large(obb).
vile_large(rolb). vile_large(rukh). vile_large(ruz). vile_large(sharg).
vile_large(shruf). vile_large(shud). vile_large(shug). vile_large(shur).
vile_large(shuz). vile_large(slub). vile_large(slud). vile_large(slug).
vile_large(snad). vile_large(snog). vile_large(thrag). vile_large(thulk).
vile_large(thurk). vile_large(trug). vile_large(ulg). vile_large(ur).
vile_large(urd). vile_large(urgh). vile_large(urkh). vile_large(uz).
vile_large(yug). vile_large(yur). vile_large(zud). vile_large(zug).

%% vile_female_ending/1: 6 elements.
vile_female_ending(ah). vile_female_ending(ay). vile_female_ending(gah).
vile_female_ending(ghy). vile_female_ending(y). vile_female_ending(ya).

%% primitive/1: 100 elements.
primitive(ahg). primitive(baod). primitive(beegh). primitive(bohr).
primitive(bul). primitive(buli). primitive(burh). primitive(buri).
primitive(chah). primitive(dhak). primitive(digri). primitive(dum).
primitive(eghi). primitive(ehm). primitive(faogh). primitive(feehm).
primitive(ghad). primitive(ghah). primitive(gham). primitive(ghan).
primitive(ghat). primitive(ghaw). primitive(ghee). primitive(ghish).
primitive(ghug). primitive(giree). primitive(gonkh). primitive(goun).
primitive(goush). primitive(guh). primitive(gunri). primitive(hah).
primitive(hani). primitive(haogh). primitive(hatoo). primitive(heghi).
primitive(heh). primitive(hoo). primitive(houm). primitive(hree).
primitive(ig). primitive(kham). primitive(khan). primitive(khaz).
primitive(khee). primitive(khem). primitive(khuri). primitive(logh).
primitive(lugh). primitive(maoh). primitive(meh). primitive(mogh).
primitive(mouh). primitive(mugh). primitive(naoh). primitive(naroo).
primitive(nham). primitive(nuh). primitive(ob). primitive(oli).
primitive(orf). primitive(ough). primitive(ouh). primitive(peh).
primitive(pogh). primitive(pugh). primitive(puh). primitive(quagi).
primitive(rahoo). primitive(rhoo). primitive(rifoo). primitive(ronkh).
primitive(rouk). primitive(saom). primitive(saori). primitive(shehi).
primitive(shlo). primitive(shom). primitive(shour). primitive(shul).
primitive(snaoh). primitive(suhi). primitive(suth). primitive(teb).
primitive(thom). primitive(toudh). primitive(tregh). primitive(tuhli).
primitive(ub). primitive(urush). primitive(ush). primitive(vuh).
primitive(wah). primitive(wuh). primitive(yaum). primitive(yauth).
primitive(yeeh). primitive(yih). primitive(yuh). primitive(zham).

%% primitive_song/1: 8 elements.
primitive_song(doh). primitive_song(rei). primitive_song(mih).
primitive_song(fah). primitive_song(soh). primitive_song(lah).
primitive_song(tih). primitive_song(daoh).

%% doughty_prefix/1: 60 elements.
doughty_prefix(bal). doughty_prefix(durn). doughty_prefix(na).
doughty_prefix(bord). doughty_prefix(from). doughty_prefix(nor).
doughty_prefix(born). doughty_prefix(fror). doughty_prefix(nord).
doughty_prefix(brim). doughty_prefix(fuld). doughty_prefix(orm).
doughty_prefix(brod). doughty_prefix(fund). doughty_prefix(skand).
doughty_prefix(brokk). doughty_prefix(gim). doughty_prefix(skond).
doughty_prefix(brom). doughty_prefix(glo). doughty_prefix(storn).
doughty_prefix(bru). doughty_prefix(gond). doughty_prefix(strom).
doughty_prefix(bur). doughty_prefix(gord). doughty_prefix(stur).
doughty_prefix(burl). doughty_prefix(gorm). doughty_prefix(sturl).
doughty_prefix(da). doughty_prefix(grad). doughty_prefix(sund).
doughty_prefix(dal). doughty_prefix(grim). doughty_prefix(thor).
doughty_prefix(dolg). doughty_prefix(grod). doughty_prefix(thorn).
doughty_prefix(dor). doughty_prefix(grom). doughty_prefix(thra).
doughty_prefix(dorm). doughty_prefix(guld). doughty_prefix(thro).
doughty_prefix(dral). doughty_prefix(gund). doughty_prefix(throl).
doughty_prefix(drim). doughty_prefix(gur). doughty_prefix(thror).
doughty_prefix(drom). doughty_prefix(hord). doughty_prefix(thru).
doughty_prefix(dur). doughty_prefix(horn). doughty_prefix(thrur).
doughty_prefix(durm). doughty_prefix(hra). doughty_prefix(thund).

%% doughty_male/1: 16 elements.
doughty_male(bor). doughty_male(din). doughty_male(in). doughty_male(ir).
doughty_male(li). doughty_male(lin). doughty_male(nir). doughty_male(or).
doughty_male(ri). doughty_male(rin). doughty_male(rok). doughty_male(ror).
doughty_male(rur). doughty_male(vi). doughty_male(vir). doughty_male(vor).

%% doughty_female/1: 15 elements.
doughty_female(bis). doughty_female(da). doughty_female(dis).
doughty_female(ga). doughty_female(hild). doughty_female(is).
doughty_female(lif). doughty_female(lind). doughty_female(lis).
doughty_female(na). doughty_female(nis). doughty_female(ris).
doughty_female(rith). doughty_female(run). doughty_female(vis).

%% homely_prefix/1: 48 elements.
homely_prefix(ad). homely_prefix(blanc). homely_prefix(falc).
homely_prefix(mil). homely_prefix(adel). homely_prefix(boff).
homely_prefix(ferd). homely_prefix(mung). homely_prefix(adr).
homely_prefix(bomb). homely_prefix(frob). homely_prefix(od).
homely_prefix(ail). homely_prefix(bram). homely_prefix(fulb).
homely_prefix(oth). homely_prefix(alb). homely_prefix(bung).
homely_prefix(gam). homely_prefix(sab). homely_prefix(alm).
homely_prefix(droc). homely_prefix(hald). homely_prefix(sam).
homely_prefix(amb). homely_prefix(drog). homely_prefix(ham).
homely_prefix(seg). homely_prefix(band). homely_prefix(durl).
homely_prefix(hasc). homely_prefix(serl). homely_prefix(bard).
homely_prefix(emm). homely_prefix(hod). homely_prefix(tob).
homely_prefix(ben). homely_prefix(erd). homely_prefix(hug).
homely_prefix(wan). homely_prefix(biff). homely_prefix(ern).
homely_prefix(iv). homely_prefix(wig). homely_prefix(bild).
homely_prefix(ever). homely_prefix(mark). homely_prefix(wyd).

%% homely_male/1: 8 elements.
homely_male(ald). homely_male(ard). homely_male(ert). homely_male(fast).
homely_male(o). homely_male(old). homely_male(win). homely_male(wise).

%% homely_female/1: 7 elements.
homely_female(a). homely_female(ia). homely_female(ice). homely_female(ily).
homely_female(ina). homely_female(wina). homely_female(wisa).

%% fair_prefix/1: 80 elements.
fair_prefix(an). fair_prefix(im). fair_prefix(aeg). fair_prefix(lith).
fair_prefix(ar). fair_prefix(in). fair_prefix(ael). fair_prefix(maeg).
fair_prefix(cal). fair_prefix(ir). fair_prefix(aer). fair_prefix(mind).
fair_prefix(car). fair_prefix(ist). fair_prefix(aes). fair_prefix(mith).
fair_prefix(cel). fair_prefix(lar). fair_prefix(aeth). fair_prefix(nith).
fair_prefix(cir). fair_prefix(lir). fair_prefix(bel). fair_prefix(rael).
fair_prefix(clar). fair_prefix(lor). fair_prefix(ber). fair_prefix(rind).
fair_prefix(el). fair_prefix(mar). fair_prefix(cael). fair_prefix(saer).
fair_prefix(elb). fair_prefix(mel). fair_prefix(caer). fair_prefix(sar).
fair_prefix(er). fair_prefix(mer). fair_prefix(cris). fair_prefix(seld).
fair_prefix(erl). fair_prefix(mir). fair_prefix(ear). fair_prefix(ser).
fair_prefix(est). fair_prefix(nim). fair_prefix(elth). fair_prefix(sil).
fair_prefix(far). fair_prefix(nin). fair_prefix(eol). fair_prefix(silm).
fair_prefix(fin). fair_prefix(nir). fair_prefix(faer). fair_prefix(sind).
fair_prefix(gal). fair_prefix(ral). fair_prefix(fean). fair_prefix(thael).
fair_prefix(gan). fair_prefix(ran). fair_prefix(find). fair_prefix(thaer).
fair_prefix(gar). fair_prefix(rel). fair_prefix(ith). fair_prefix(thal).
fair_prefix(gel). fair_prefix(ril). fair_prefix(laeg). fair_prefix(thel).
fair_prefix(gil). fair_prefix(rin). fair_prefix(lend). fair_prefix(ther).
fair_prefix(ilm). fair_prefix(rim). fair_prefix(lind). fair_prefix(thir).

%% fair_middle/1: 20 elements.
fair_middle(ad). fair_middle(al). fair_middle(am). fair_middle(an).
fair_middle(ar). fair_middle(as). fair_middle(eb). fair_middle(ed).
fair_middle(el). fair_middle(em). fair_middle(en). fair_middle(er).
fair_middle(es). fair_middle(ev). fair_middle(il). fair_middle(in).
fair_middle(ir). fair_middle(ol). fair_middle(thal). fair_middle(thon).

%% fair_male/1: 19 elements.
fair_male(ad). fair_male(dan). fair_male(del). fair_male(dil).
fair_male(dir). fair_male(fal). fair_male(ion). fair_male(lad).
fair_male(las). fair_male(lin). fair_male(nar). fair_male(or).
fair_male(orn). fair_male(ras). fair_male(rior). fair_male(rod).
fair_male(rond). fair_male(ros). fair_male(thir).

%% fair_female/1: 17 elements.
fair_female(edel). fair_female(el). fair_female(eth). fair_female(ian).
fair_female(iel). fair_female(ien). fair_female(loth). fair_female(mir).
fair_female(rial). fair_female(rian). fair_female(riel). fair_female(rien).
fair_female(ril). fair_female(roel). fair_female(sil). fair_female(we).
fair_female(wen).

%% spry_prefix/1: 72 elements.
spry_prefix(dex). spry_prefix(gliss). spry_prefix(tink). spry_prefix(flax).
spry_prefix(goss). spry_prefix(tiss). spry_prefix(flim). spry_prefix(hex).
spry_prefix(trill). spry_prefix(fliss). spry_prefix(liss).
spry_prefix(trist). spry_prefix(flix). spry_prefix(min). spry_prefix(twill).
spry_prefix(foss). spry_prefix(misk). spry_prefix(twiss). spry_prefix(frisk).
spry_prefix(raff). spry_prefix(twisp). spry_prefix(friss). spry_prefix(ress).
spry_prefix(twix). spry_prefix(gess). spry_prefix(riff). spry_prefix(weft).
spry_prefix(glan). spry_prefix(rill). spry_prefix(wesk). spry_prefix(glax).
spry_prefix(saff). spry_prefix(winn). spry_prefix(glim). spry_prefix(shim).
spry_prefix(wisp). spry_prefix(bris). spry_prefix(iphil). spry_prefix(opal).
spry_prefix(cryl). spry_prefix(ispel). spry_prefix(oris). spry_prefix(elsi).
spry_prefix(istle). spry_prefix(orif). spry_prefix(ember). spry_prefix(jat).
spry_prefix(peri). spry_prefix(esk). spry_prefix(jost). spry_prefix(sarm).
spry_prefix(feris). spry_prefix(jus). spry_prefix(sprin). spry_prefix(frimi).
spry_prefix(lirra). spry_prefix(stith). spry_prefix(gan). spry_prefix(mali).
spry_prefix(tansi). spry_prefix(glink). spry_prefix(mink).
spry_prefix(tirra). spry_prefix(hal). spry_prefix(mirra). spry_prefix(trump).
spry_prefix(hel). spry_prefix(mistle). spry_prefix(whis). spry_prefix(hist).
spry_prefix(ninka). spry_prefix(zando).

%% spry_male/1: 24 elements.
spry_male(aldo). spry_male(allo). spry_male(amo). spry_male(ando).
spry_male(aroll). spry_male(aron). spry_male(asto). spry_male(endo).
spry_male(eroll). spry_male(eron). spry_male(esto). spry_male(ondo).
spry_male(bik). spry_male(brix). spry_male(frell). spry_male(fret).
spry_male(kin). spry_male(mist). spry_male(mit). spry_male(rix).
spry_male(tross). spry_male(twik). spry_male(win). spry_male(zisk).

%% spry_female/1: 24 elements.
spry_female(afer). spry_female(amer). spry_female(anel). spry_female(arel).
spry_female(asti). spry_female(efer). spry_female(enti). spry_female(erel).
spry_female(ifer). spry_female(imer). spry_female(inel). spry_female(irel).
spry_female(dee). spry_female(kiss). spry_female(la). spry_female(liss).
spry_female(mee). spry_female(niss). spry_female(nyx). spry_female(ree).
spry_female(riss). spry_female(sa). spry_female(tiss). spry_female(ynx).

%% --- the listed names ----------------------------------------------------------
%% instance_of(Class, Name): names the book lists as such (Norse and Greek myth).

%% norse_dwarf: 71 names.
instance_of(norse_dwarf, <<"Ai">>). instance_of(norse_dwarf, <<"An">>).
instance_of(norse_dwarf, <<"Andvari">>). instance_of(norse_dwarf, <<"Annar">>).
instance_of(norse_dwarf, <<"Austi">>). instance_of(norse_dwarf, <<"Austri">>).
instance_of(norse_dwarf, <<"Bafur">>). instance_of(norse_dwarf, <<"Berling">>).
instance_of(norse_dwarf, <<"Bifur">>). instance_of(norse_dwarf, <<"Bombor">>).
instance_of(norse_dwarf, <<"Brokk">>). instance_of(norse_dwarf, <<"Dain">>).
instance_of(norse_dwarf, <<"Delling">>). instance_of(norse_dwarf, <<"Dolgthvari">>).
instance_of(norse_dwarf, <<"Dori">>). instance_of(norse_dwarf, <<"Draupnir">>).
instance_of(norse_dwarf, <<"Dufr">>). instance_of(norse_dwarf, <<"Duneyr">>).
instance_of(norse_dwarf, <<"Durathror">>). instance_of(norse_dwarf, <<"Durin">>).
instance_of(norse_dwarf, <<"Dvalin">>). instance_of(norse_dwarf, <<"Eikinskjaudi">>).
instance_of(norse_dwarf, <<"Eitri">>). instance_of(norse_dwarf, <<"Fal">>).
instance_of(norse_dwarf, <<"Fili">>). instance_of(norse_dwarf, <<"Fith">>).
instance_of(norse_dwarf, <<"Fjalar">>). instance_of(norse_dwarf, <<"Frosti">>).
instance_of(norse_dwarf, <<"Fundin">>). instance_of(norse_dwarf, <<"Ginnar">>).
instance_of(norse_dwarf, <<"Gloin">>). instance_of(norse_dwarf, <<"Grerr">>).
instance_of(norse_dwarf, <<"Har">>). instance_of(norse_dwarf, <<"Haur">>).
instance_of(norse_dwarf, <<"Hornbori">>). instance_of(norse_dwarf, <<"Ingi">>).
instance_of(norse_dwarf, <<"Jari">>). instance_of(norse_dwarf, <<"Kili">>).
instance_of(norse_dwarf, <<"Lit">>). instance_of(norse_dwarf, <<"Loni">>).
instance_of(norse_dwarf, <<"Mjodvitnir">>). instance_of(norse_dwarf, <<"Moin">>).
instance_of(norse_dwarf, <<"Nain">>). instance_of(norse_dwarf, <<"Nali">>).
instance_of(norse_dwarf, <<"Nar">>). instance_of(norse_dwarf, <<"Nibelung">>).
instance_of(norse_dwarf, <<"Nidi">>). instance_of(norse_dwarf, <<"Nipingr">>).
instance_of(norse_dwarf, <<"Nordri">>). instance_of(norse_dwarf, <<"Nyi">>).
instance_of(norse_dwarf, <<"Nyr">>). instance_of(norse_dwarf, <<"Oinn">>).
instance_of(norse_dwarf, <<"Ori">>). instance_of(norse_dwarf, <<"Radsuithr">>).
instance_of(norse_dwarf, <<"Radsvid">>). instance_of(norse_dwarf, <<"Regin">>).
instance_of(norse_dwarf, <<"Rekk">>). instance_of(norse_dwarf, <<"Sjarr">>).
instance_of(norse_dwarf, <<"Skandar">>). instance_of(norse_dwarf, <<"Skirfir">>).
instance_of(norse_dwarf, <<"Sudri">>). instance_of(norse_dwarf, <<"Thekkr">>).
instance_of(norse_dwarf, <<"Thorin">>). instance_of(norse_dwarf, <<"Thror">>).
instance_of(norse_dwarf, <<"Thrurinn">>). instance_of(norse_dwarf, <<"Veigur">>).
instance_of(norse_dwarf, <<"Vestri">>). instance_of(norse_dwarf, <<"Vig">>).
instance_of(norse_dwarf, <<"Virvir">>). instance_of(norse_dwarf, <<"Vithur">>).
instance_of(norse_dwarf, <<"Yingi">>).

%% greek_nymph: 29 names.
instance_of(greek_nymph, <<"Adrasteia">>). instance_of(greek_nymph, <<"Aegina">>).
instance_of(greek_nymph, <<"Amaltheia">>). instance_of(greek_nymph, <<"Ankhiale">>).
instance_of(greek_nymph, <<"Arethusa">>). instance_of(greek_nymph, <<"Asterodeia">>).
instance_of(greek_nymph, <<"Bakkhe">>). instance_of(greek_nymph, <<"Bromie">>).
instance_of(greek_nymph, <<"Daphne">>). instance_of(greek_nymph, <<"Doris">>).
instance_of(greek_nymph, <<"Dryope">>). instance_of(greek_nymph, <<"Dynamene">>).
instance_of(greek_nymph, <<"Ekho">>). instance_of(greek_nymph, <<"Elektra">>).
instance_of(greek_nymph, <<"Erato">>). instance_of(greek_nymph, <<"Euryanassa">>).
instance_of(greek_nymph, <<"Eurythemista">>). instance_of(greek_nymph, <<"Idaea">>).
instance_of(greek_nymph, <<"Io">>). instance_of(greek_nymph, <<"Iynx">>).
instance_of(greek_nymph, <<"Kallirrhoe">>). instance_of(greek_nymph, <<"Kallisto">>).
instance_of(greek_nymph, <<"Kalyke">>). instance_of(greek_nymph, <<"Kalypso">>).
instance_of(greek_nymph, <<"Klytia">>). instance_of(greek_nymph, <<"Kreusa">>).
instance_of(greek_nymph, <<"Linos">>). instance_of(greek_nymph, <<"Makris">>).
instance_of(greek_nymph, <<"Nysa">>).

%% greek_siren: 11 names.
instance_of(greek_siren, <<"Aglaope">>). instance_of(greek_siren, <<"Aglaophonos">>).
instance_of(greek_siren, <<"Leukosia">>). instance_of(greek_siren, <<"Ligeia">>).
instance_of(greek_siren, <<"Molpe">>). instance_of(greek_siren, <<"Parthenope">>).
instance_of(greek_siren, <<"Peisinoe">>). instance_of(greek_siren, <<"Raidne">>).
instance_of(greek_siren, <<"Teles">>). instance_of(greek_siren, <<"Thelxepeia">>).
instance_of(greek_siren, <<"Thelxiope">>).


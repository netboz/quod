%% quod:names — fantasy personal names, generated and recognised from one set
%% of tables. A system ontology (doc/ontology-actor-architecture.md §2):
%% founded through the ordinary lifecycle, then listed in root as
%% system_ontology(quod:names, Anchor) so every node carries it. Agents get
%% their display labels from it.
%%
%% Ask it with `::`; names are binaries:
%%   quod:names::name(Name, orc, personal, male)     every male orc name
%%   quod:names::name(<<"Ugbash">>, C, K, G)         the selection(s) a name is in
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
%% Vocabulary: a genesis may introduce at most 64 new symbols to a node that
%% never saw this source (quod_vm_limits), so every piece of data — table
%% names, syllables, names — is a binary, never an atom. Only the structure
%% (predicates, cultures, kinds, genders, recipe functors) is symbolic.
%%
%% Model, in the house vocabulary:
%%   isa(Culture, Wider)                        culture tree, rooted at thing
%%   pool(Culture, Kind, Gender, Source)        a pool of names; Source is
%%                                              recipe(Recipe) or listed
%%   listed(Culture, Kind, Gender, Names)       the names of a listed pool
%%   elements(Table, Fragments)                 the syllables of a table
%% Tables and listed pools are one fact each with a list of binaries: a
%% genesis is one envelope, and every repeated clause costs bytes in it.
%%
%% Recipes:
%%   element(Table)         one element of Table
%%   concat(Recipes)        the recipes glued together
%%   join(Sep, Recipes)     the recipes with Sep between the parts
%%   one_of(Recipes)        any one of the recipes
%%   rep(Min, Max, Recipe)  inside concat/join: Min to Max parts from Recipe
%% Elements are lowercase. A built name is capitalised at its start and after
%% every separator (Ugbash, Bul-Suhi-Yih). Recognition runs the same recipe
%% backwards over the name's bytes, so a name in several pools is reported
%% once per pool (Dain is both a listed Norse dwarf and da+in).

acl_sovereign(quod:names).

%% Anyone may ask the naming questions. Changing tables, recipes or rules stays
%% with admitted nodes, as in the other system ontologies.
can_invoke(Goal, _Principal, _CallChain, _Ns) :- naming_query(Goal).
can_invoke(_Goal, node(NodeKey), _CallChain, _Ns) :-
    peer_admitted(NodeKey, _, _, NodeKey).
can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).

naming_query(name(_, _, _, _)).
naming_query(count(_, _, _, _)).
naming_query(name_nth(_, _, _, _, _)).
naming_query(draw(_, _, _, _, _)).
naming_query(draw(_, _)).

%% --- public predicates -------------------------------------------------------

%% name(?Name, ?Culture, ?Kind, ?Gender): Name belongs to a pool of the
%% selection. With Name bound this recognises it and reports each pool it
%% is in; otherwise names are enumerated pool by pool, in pool order.
name(Name, Culture, Kind, Gender) :-
    select(Culture, Kind, Gender, Own, Source),
    (   nonvar(Name) -> recognise(Source, Own, Kind, Gender, Name)
    ;   generate(Source, Own, Kind, Gender, Name)
    ).

%% count(?Culture, ?Kind, ?Gender, -N): how many names the selection holds.
count(Culture, Kind, Gender, N) :-
    findall(Size,
            (select(Culture, Kind, Gender, Own, Source),
             pool_size(Own, Kind, Gender, Source, Size)),
            Sizes),
    sum(Sizes, N).

%% name_nth(?Culture, ?Kind, ?Gender, +I, -Name): the I-th name (from 0) of the
%% selection, in name/4 order, computed without listing the others.
name_nth(Culture, Kind, Gender, I, Name) :-
    integer(I), I >= 0,
    findall(pool(Own, Kind, Gender, Source),
            select(Culture, Kind, Gender, Own, Source), Pools),
    pools_nth(Pools, I, Name).

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
    findall(pool(Culture, Kind, Gender, Source),
            pool(Culture, Kind, Gender, Source), Pools),
    length(Pools, Count),
    proof_draw(pool(Salt), Count, K),
    nth_(K, Pools, pool(Culture, Kind, Gender, Source)),
    pool_size(Culture, Kind, Gender, Source, Size),
    proof_draw(Salt, Size, I),
    pool_nth(Culture, Kind, Gender, Source, I, Name).

%% --- selection ---------------------------------------------------------------

%% select(?Culture, ?Kind, ?Gender, -Own, -Source): a pool of the selection.
%% An unbound Culture is bound to the pool's own culture; a bound one may be
%% the pool's culture or any wider one.
select(Culture, Kind, Gender, Own, Source) :-
    pool(Own, Kind, Gender, Source),
    (   var(Culture) -> Culture = Own
    ;   isa_star(Own, Culture)
    ).

isa_star(Culture, Culture).
isa_star(Culture, Wider) :- isa(Culture, Between), isa_star(Between, Wider).

pool_size(_, _, _, recipe(Recipe), N) :- size(Recipe, N).
pool_size(Culture, Kind, Gender, listed, N) :-
    listed(Culture, Kind, Gender, Names),
    length(Names, N).

pools_nth([pool(Culture, Kind, Gender, Source) | Pools], I, Name) :-
    pool_size(Culture, Kind, Gender, Source, Size),
    (   I < Size -> pool_nth(Culture, Kind, Gender, Source, I, Name)
    ;   J is I - Size, pools_nth(Pools, J, Name)
    ).

pool_nth(_, _, _, recipe(Recipe), I, Name) :-
    nth(Recipe, I, Lower, []),
    title(Lower, Codes),
    binary_codes(Name, Codes).
pool_nth(Culture, Kind, Gender, listed, I, Name) :-
    listed(Culture, Kind, Gender, Names),
    nth_(I, Names, Name).

generate(recipe(Recipe), _, _, _, Name) :-
    build(Recipe, Lower, []),
    title(Lower, Codes),
    binary_codes(Name, Codes).
generate(listed, Culture, Kind, Gender, Name) :-
    listed(Culture, Kind, Gender, Names),
    member(Name, Names).

%% binary_codes/2 fails plainly for anything that is not a binary.
recognise(recipe(Recipe), _, _, _, Name) :-
    binary_codes(Name, Codes),
    title(Lower, Codes),
    build(Recipe, Lower, []).
recognise(listed, Culture, Kind, Gender, Name) :-
    listed(Culture, Kind, Gender, Names),
    member(Name, Names).

%% --- recipes: build (both ways), size, nth ------------------------------------
%% build/3 and nth/4 walk a recipe over a difference list of byte codes. With
%% the codes unbound build/3 enumerates names; with them bound it parses.
%% nth/4 picks the I-th name in build/3's order: in a sequence the first part
%% is the most significant digit, so the last part varies fastest.

build(element(Table), Cs0, Cs) :-
    elements(Table, Fragments),
    member(Fragment, Fragments),
    emit(Fragment, Cs0, Cs).
build(one_of(Recipes), Cs0, Cs) :-
    member(Recipe, Recipes),
    build(Recipe, Cs0, Cs).
build(concat(Recipes), Cs0, Cs) :-
    seq(Recipes, [], [], Cs0, Cs).
build(join(Sep, Recipes), Cs0, Cs) :-
    binary_codes(Sep, SepCodes),
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

emit(Fragment, Cs0, Cs) :-
    binary_codes(Fragment, FragmentCodes),
    append(FragmentCodes, Cs, Cs0).

size(element(Table), N) :- elements(Table, Fragments), length(Fragments, N).
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
    elements(Table, Fragments),
    nth_(I, Fragments, Fragment),
    emit(Fragment, Cs0, Cs).
nth(one_of(Recipes), I, Cs0, Cs) :-
    one_of_nth(Recipes, I, Cs0, Cs).
nth(concat(Recipes), I, Cs0, Cs) :-
    seq_nth(Recipes, I, [], [], Cs0, Cs).
nth(join(Sep, Recipes), I, Cs0, Cs) :-
    binary_codes(Sep, SepCodes),
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
%% pool(Culture, Kind, Gender, Source). Kind is `personal` throughout this
%% book; epithets, places and taverns are later kinds.

%% Vile & Crude: two elements of the size table; females add an ending.
pool(goblin, personal, male,
     recipe(concat([element(<<"vile_small">>), element(<<"vile_small">>)]))).
pool(goblin, personal, female,
     recipe(concat([element(<<"vile_small">>), element(<<"vile_small">>),
                    element(<<"vile_female_ending">>)]))).
pool(orc, personal, male,
     recipe(concat([element(<<"vile_medium">>), element(<<"vile_medium">>)]))).
pool(orc, personal, female,
     recipe(concat([element(<<"vile_medium">>), element(<<"vile_medium">>),
                    element(<<"vile_female_ending">>)]))).
pool(ogre, personal, male,
     recipe(concat([element(<<"vile_large">>), element(<<"vile_large">>)]))).
pool(ogre, personal, female,
     recipe(concat([element(<<"vile_large">>), element(<<"vile_large">>),
                    element(<<"vile_female_ending">>)]))).

%% Primitive: one to three hyphenated parts (one or two for females, who
%% carry a sung element at either end).
pool(primitive, personal, male,
     recipe(join(<<"-">>, [rep(1, 3, element(<<"primitive">>))]))).
pool(primitive, personal, female,
     recipe(one_of([join(<<"-">>, [rep(1, 2, element(<<"primitive">>)),
                                   element(<<"primitive_song">>)]),
                    join(<<"-">>, [element(<<"primitive_song">>),
                                   rep(1, 2, element(<<"primitive">>))])]))).

%% Doughty & Homely: prefix + gendered suffix; gnomes mix the two tables.
%% Dwarves also have the listed Norse myth names (a second, listed pool).
pool(dwarf, personal, male,
     recipe(concat([element(<<"doughty_prefix">>), element(<<"doughty_male">>)]))).
pool(dwarf, personal, male, listed).
pool(dwarf, personal, female,
     recipe(concat([element(<<"doughty_prefix">>), element(<<"doughty_female">>)]))).
pool(gnome, personal, male,
     recipe(concat([element(<<"doughty_prefix">>), element(<<"homely_male">>)]))).
pool(gnome, personal, female,
     recipe(concat([element(<<"doughty_prefix">>), element(<<"homely_female">>)]))).
pool(halfling, personal, male,
     recipe(concat([element(<<"homely_prefix">>), element(<<"homely_male">>)]))).
pool(halfling, personal, female,
     recipe(concat([element(<<"homely_prefix">>), element(<<"homely_female">>)]))).

%% Fair & Noble: prefix + middle + gendered suffix, or prefix + suffix.
pool(elf, personal, male,
     recipe(one_of([concat([element(<<"fair_prefix">>), element(<<"fair_middle">>),
                            element(<<"fair_male">>)]),
                    concat([element(<<"fair_prefix">>), element(<<"fair_male">>)])]))).
pool(elf, personal, female,
     recipe(one_of([concat([element(<<"fair_prefix">>), element(<<"fair_middle">>),
                            element(<<"fair_female">>)]),
                    concat([element(<<"fair_prefix">>), element(<<"fair_female">>)])]))).

%% Faerykind: prefix + gendered suffix.
pool(faerie, personal, male,
     recipe(concat([element(<<"spry_prefix">>), element(<<"spry_male">>)]))).
pool(faerie, personal, female,
     recipe(concat([element(<<"spry_prefix">>), element(<<"spry_female">>)]))).

%% Nymphs and Sirens: listed Greek myth names.
pool(nymph, personal, female, listed).
pool(siren, personal, female, listed).

%% --- the element tables ------------------------------------------------------
%% elements(Table, Fragments): vile_small 100, vile_medium 100, vile_large 100, vile_female_ending 6, primitive 100, primitive_song 8, doughty_prefix 60, doughty_male 16, doughty_female 15, homely_prefix 48, homely_male 8, homely_female 7, fair_prefix 80, fair_middle 20, fair_male 19, fair_female 17, spry_prefix 72, spry_male 24, spry_female 24.

elements(<<"vile_small">>,
         [<<"ach">>, <<"adz">>, <<"ak">>, <<"ark">>, <<"az">>, <<"balg">>,
         <<"bilg">>, <<"blid">>, <<"blig">>, <<"blok">>, <<"blot">>,
         <<"bolg">>, <<"bot">>, <<"bug">>, <<"burk">>, <<"dokh">>,
         <<"drik">>, <<"driz">>, <<"duf">>, <<"flug">>, <<"ga">>, <<"gad">>,
         <<"gag">>, <<"gah">>, <<"gak">>, <<"gar">>, <<"gat">>, <<"gaz">>,
         <<"ghag">>, <<"ghak">>, <<"git">>, <<"glag">>, <<"glak">>,
         <<"glat">>, <<"glig">>, <<"gliz">>, <<"glok">>, <<"gnat">>,
         <<"gog">>, <<"grak">>, <<"grat">>, <<"guk">>, <<"hig">>, <<"irk">>,
         <<"kak">>, <<"khad">>, <<"krig">>, <<"lag">>, <<"lak">>, <<"lig">>,
         <<"likk">>, <<"loz">>, <<"luk">>, <<"mak">>, <<"maz">>, <<"miz">>,
         <<"mub">>, <<"nad">>, <<"nag">>, <<"naz">>, <<"nig">>, <<"nikk">>,
         <<"nogg">>, <<"nok">>, <<"nukk">>, <<"rag">>, <<"rak">>, <<"rat">>,
         <<"rok">>, <<"shrig">>, <<"shuk">>, <<"skrag">>, <<"skug">>,
         <<"slai">>, <<"slig">>, <<"slog">>, <<"sna">>, <<"snag">>,
         <<"snark">>, <<"snat">>, <<"snig">>, <<"snik">>, <<"snit">>,
         <<"sog">>, <<"spik">>, <<"stogg">>, <<"tog">>, <<"urf">>,
         <<"vark">>, <<"yad">>, <<"yagg">>, <<"yak">>, <<"yark">>,
         <<"yarp">>, <<"yig">>, <<"yip">>, <<"zat">>, <<"zib">>, <<"zit">>,
         <<"ziz">>]).
elements(<<"vile_medium">>,
         [<<"ag">>, <<"aug">>, <<"bad">>, <<"bag">>, <<"bakh">>, <<"bash">>,
         <<"baz">>, <<"blag">>, <<"brag">>, <<"brog">>, <<"bruz">>,
         <<"dag">>, <<"dakk">>, <<"darg">>, <<"dob">>, <<"dog">>, <<"drab">>,
         <<"dug">>, <<"dur">>, <<"gash">>, <<"ghaz">>, <<"glakh">>,
         <<"glaz">>, <<"glob">>, <<"glol">>, <<"gluf">>, <<"glur">>,
         <<"gnarl">>, <<"gnash">>, <<"gnub">>, <<"gob">>, <<"gokh">>,
         <<"gol">>, <<"golk">>, <<"gor">>, <<"grakh">>, <<"grash">>,
         <<"grath">>, <<"graz">>, <<"grot">>, <<"grub">>, <<"grud">>,
         <<"gud">>, <<"gut">>, <<"hag">>, <<"hakk">>, <<"hrat">>, <<"hrog">>,
         <<"hrug">>, <<"khag">>, <<"khar">>, <<"krag">>, <<"krud">>,
         <<"lakh">>, <<"lash">>, <<"lob">>, <<"lub">>, <<"lud">>, <<"luf">>,
         <<"luk">>, <<"molk">>, <<"muk">>, <<"muz">>, <<"nar">>, <<"ogg">>,
         <<"olg">>, <<"rag">>, <<"rash">>, <<"rogg">>, <<"rorg">>, <<"rot">>,
         <<"rud">>, <<"ruft">>, <<"rug">>, <<"rut">>, <<"shad">>, <<"shag">>,
         <<"shak">>, <<"shaz">>, <<"shog">>, <<"skar">>, <<"skulg">>,
         <<"slur">>, <<"snar">>, <<"snorl">>, <<"snub">>, <<"snurr">>,
         <<"sod">>, <<"stulg">>, <<"thak">>, <<"trog">>, <<"ug">>,
         <<"umsh">>, <<"ung">>, <<"uth">>, <<"yakh">>, <<"yash">>, <<"yob">>,
         <<"zahk">>, <<"zog">>]).
elements(<<"vile_large">>,
         [<<"argh">>, <<"barsh">>, <<"bog">>, <<"burz">>, <<"dof">>,
         <<"drok">>, <<"drub">>, <<"drug">>, <<"dub">>, <<"dug">>, <<"dul">>,
         <<"dursh">>, <<"dush">>, <<"duz">>, <<"faug">>, <<"fug">>,
         <<"ghakh">>, <<"ghar">>, <<"ghash">>, <<"ghol">>, <<"ghor">>,
         <<"ghukk">>, <<"ghul">>, <<"glub">>, <<"glud">>, <<"glug">>,
         <<"gluz">>, <<"gom">>, <<"grad">>, <<"grash">>, <<"grob">>,
         <<"grogg">>, <<"grok">>, <<"grol">>, <<"gru">>, <<"gruf">>,
         <<"gruk">>, <<"grul">>, <<"grum">>, <<"grumf">>, <<"grut">>,
         <<"gruz">>, <<"guhl">>, <<"gulv">>, <<"hai">>, <<"hrung">>,
         <<"hur">>, <<"hurg">>, <<"kai">>, <<"klob">>, <<"krod">>, <<"kug">>,
         <<"kulk">>, <<"kur">>, <<"lorg">>, <<"lug">>, <<"lukh">>, <<"lum">>,
         <<"lurz">>, <<"lush">>, <<"luz">>, <<"makh">>, <<"maug">>,
         <<"molg">>, <<"mud">>, <<"mug">>, <<"mul">>, <<"murk">>, <<"muzd">>,
         <<"nakh">>, <<"narg">>, <<"obb">>, <<"rolb">>, <<"rukh">>,
         <<"ruz">>, <<"sharg">>, <<"shruf">>, <<"shud">>, <<"shug">>,
         <<"shur">>, <<"shuz">>, <<"slub">>, <<"slud">>, <<"slug">>,
         <<"snad">>, <<"snog">>, <<"thrag">>, <<"thulk">>, <<"thurk">>,
         <<"trug">>, <<"ulg">>, <<"ur">>, <<"urd">>, <<"urgh">>, <<"urkh">>,
         <<"uz">>, <<"yug">>, <<"yur">>, <<"zud">>, <<"zug">>]).
elements(<<"vile_female_ending">>,
         [<<"ah">>, <<"ay">>, <<"gah">>, <<"ghy">>, <<"y">>, <<"ya">>]).
elements(<<"primitive">>,
         [<<"ahg">>, <<"baod">>, <<"beegh">>, <<"bohr">>, <<"bul">>,
         <<"buli">>, <<"burh">>, <<"buri">>, <<"chah">>, <<"dhak">>,
         <<"digri">>, <<"dum">>, <<"eghi">>, <<"ehm">>, <<"faogh">>,
         <<"feehm">>, <<"ghad">>, <<"ghah">>, <<"gham">>, <<"ghan">>,
         <<"ghat">>, <<"ghaw">>, <<"ghee">>, <<"ghish">>, <<"ghug">>,
         <<"giree">>, <<"gonkh">>, <<"goun">>, <<"goush">>, <<"guh">>,
         <<"gunri">>, <<"hah">>, <<"hani">>, <<"haogh">>, <<"hatoo">>,
         <<"heghi">>, <<"heh">>, <<"hoo">>, <<"houm">>, <<"hree">>, <<"ig">>,
         <<"kham">>, <<"khan">>, <<"khaz">>, <<"khee">>, <<"khem">>,
         <<"khuri">>, <<"logh">>, <<"lugh">>, <<"maoh">>, <<"meh">>,
         <<"mogh">>, <<"mouh">>, <<"mugh">>, <<"naoh">>, <<"naroo">>,
         <<"nham">>, <<"nuh">>, <<"ob">>, <<"oli">>, <<"orf">>, <<"ough">>,
         <<"ouh">>, <<"peh">>, <<"pogh">>, <<"pugh">>, <<"puh">>,
         <<"quagi">>, <<"rahoo">>, <<"rhoo">>, <<"rifoo">>, <<"ronkh">>,
         <<"rouk">>, <<"saom">>, <<"saori">>, <<"shehi">>, <<"shlo">>,
         <<"shom">>, <<"shour">>, <<"shul">>, <<"snaoh">>, <<"suhi">>,
         <<"suth">>, <<"teb">>, <<"thom">>, <<"toudh">>, <<"tregh">>,
         <<"tuhli">>, <<"ub">>, <<"urush">>, <<"ush">>, <<"vuh">>, <<"wah">>,
         <<"wuh">>, <<"yaum">>, <<"yauth">>, <<"yeeh">>, <<"yih">>,
         <<"yuh">>, <<"zham">>]).
elements(<<"primitive_song">>,
         [<<"doh">>, <<"rei">>, <<"mih">>, <<"fah">>, <<"soh">>, <<"lah">>,
         <<"tih">>, <<"daoh">>]).
elements(<<"doughty_prefix">>,
         [<<"bal">>, <<"durn">>, <<"na">>, <<"bord">>, <<"from">>, <<"nor">>,
         <<"born">>, <<"fror">>, <<"nord">>, <<"brim">>, <<"fuld">>,
         <<"orm">>, <<"brod">>, <<"fund">>, <<"skand">>, <<"brokk">>,
         <<"gim">>, <<"skond">>, <<"brom">>, <<"glo">>, <<"storn">>,
         <<"bru">>, <<"gond">>, <<"strom">>, <<"bur">>, <<"gord">>,
         <<"stur">>, <<"burl">>, <<"gorm">>, <<"sturl">>, <<"da">>,
         <<"grad">>, <<"sund">>, <<"dal">>, <<"grim">>, <<"thor">>,
         <<"dolg">>, <<"grod">>, <<"thorn">>, <<"dor">>, <<"grom">>,
         <<"thra">>, <<"dorm">>, <<"guld">>, <<"thro">>, <<"dral">>,
         <<"gund">>, <<"throl">>, <<"drim">>, <<"gur">>, <<"thror">>,
         <<"drom">>, <<"hord">>, <<"thru">>, <<"dur">>, <<"horn">>,
         <<"thrur">>, <<"durm">>, <<"hra">>, <<"thund">>]).
elements(<<"doughty_male">>,
         [<<"bor">>, <<"din">>, <<"in">>, <<"ir">>, <<"li">>, <<"lin">>,
         <<"nir">>, <<"or">>, <<"ri">>, <<"rin">>, <<"rok">>, <<"ror">>,
         <<"rur">>, <<"vi">>, <<"vir">>, <<"vor">>]).
elements(<<"doughty_female">>,
         [<<"bis">>, <<"da">>, <<"dis">>, <<"ga">>, <<"hild">>, <<"is">>,
         <<"lif">>, <<"lind">>, <<"lis">>, <<"na">>, <<"nis">>, <<"ris">>,
         <<"rith">>, <<"run">>, <<"vis">>]).
elements(<<"homely_prefix">>,
         [<<"ad">>, <<"blanc">>, <<"falc">>, <<"mil">>, <<"adel">>,
         <<"boff">>, <<"ferd">>, <<"mung">>, <<"adr">>, <<"bomb">>,
         <<"frob">>, <<"od">>, <<"ail">>, <<"bram">>, <<"fulb">>, <<"oth">>,
         <<"alb">>, <<"bung">>, <<"gam">>, <<"sab">>, <<"alm">>, <<"droc">>,
         <<"hald">>, <<"sam">>, <<"amb">>, <<"drog">>, <<"ham">>, <<"seg">>,
         <<"band">>, <<"durl">>, <<"hasc">>, <<"serl">>, <<"bard">>,
         <<"emm">>, <<"hod">>, <<"tob">>, <<"ben">>, <<"erd">>, <<"hug">>,
         <<"wan">>, <<"biff">>, <<"ern">>, <<"iv">>, <<"wig">>, <<"bild">>,
         <<"ever">>, <<"mark">>, <<"wyd">>]).
elements(<<"homely_male">>,
         [<<"ald">>, <<"ard">>, <<"ert">>, <<"fast">>, <<"o">>, <<"old">>,
         <<"win">>, <<"wise">>]).
elements(<<"homely_female">>,
         [<<"a">>, <<"ia">>, <<"ice">>, <<"ily">>, <<"ina">>, <<"wina">>,
         <<"wisa">>]).
elements(<<"fair_prefix">>,
         [<<"an">>, <<"im">>, <<"aeg">>, <<"lith">>, <<"ar">>, <<"in">>,
         <<"ael">>, <<"maeg">>, <<"cal">>, <<"ir">>, <<"aer">>, <<"mind">>,
         <<"car">>, <<"ist">>, <<"aes">>, <<"mith">>, <<"cel">>, <<"lar">>,
         <<"aeth">>, <<"nith">>, <<"cir">>, <<"lir">>, <<"bel">>, <<"rael">>,
         <<"clar">>, <<"lor">>, <<"ber">>, <<"rind">>, <<"el">>, <<"mar">>,
         <<"cael">>, <<"saer">>, <<"elb">>, <<"mel">>, <<"caer">>, <<"sar">>,
         <<"er">>, <<"mer">>, <<"cris">>, <<"seld">>, <<"erl">>, <<"mir">>,
         <<"ear">>, <<"ser">>, <<"est">>, <<"nim">>, <<"elth">>, <<"sil">>,
         <<"far">>, <<"nin">>, <<"eol">>, <<"silm">>, <<"fin">>, <<"nir">>,
         <<"faer">>, <<"sind">>, <<"gal">>, <<"ral">>, <<"fean">>,
         <<"thael">>, <<"gan">>, <<"ran">>, <<"find">>, <<"thaer">>,
         <<"gar">>, <<"rel">>, <<"ith">>, <<"thal">>, <<"gel">>, <<"ril">>,
         <<"laeg">>, <<"thel">>, <<"gil">>, <<"rin">>, <<"lend">>,
         <<"ther">>, <<"ilm">>, <<"rim">>, <<"lind">>, <<"thir">>]).
elements(<<"fair_middle">>,
         [<<"ad">>, <<"al">>, <<"am">>, <<"an">>, <<"ar">>, <<"as">>,
         <<"eb">>, <<"ed">>, <<"el">>, <<"em">>, <<"en">>, <<"er">>,
         <<"es">>, <<"ev">>, <<"il">>, <<"in">>, <<"ir">>, <<"ol">>,
         <<"thal">>, <<"thon">>]).
elements(<<"fair_male">>,
         [<<"ad">>, <<"dan">>, <<"del">>, <<"dil">>, <<"dir">>, <<"fal">>,
         <<"ion">>, <<"lad">>, <<"las">>, <<"lin">>, <<"nar">>, <<"or">>,
         <<"orn">>, <<"ras">>, <<"rior">>, <<"rod">>, <<"rond">>, <<"ros">>,
         <<"thir">>]).
elements(<<"fair_female">>,
         [<<"edel">>, <<"el">>, <<"eth">>, <<"ian">>, <<"iel">>, <<"ien">>,
         <<"loth">>, <<"mir">>, <<"rial">>, <<"rian">>, <<"riel">>,
         <<"rien">>, <<"ril">>, <<"roel">>, <<"sil">>, <<"we">>, <<"wen">>]).
elements(<<"spry_prefix">>,
         [<<"dex">>, <<"gliss">>, <<"tink">>, <<"flax">>, <<"goss">>,
         <<"tiss">>, <<"flim">>, <<"hex">>, <<"trill">>, <<"fliss">>,
         <<"liss">>, <<"trist">>, <<"flix">>, <<"min">>, <<"twill">>,
         <<"foss">>, <<"misk">>, <<"twiss">>, <<"frisk">>, <<"raff">>,
         <<"twisp">>, <<"friss">>, <<"ress">>, <<"twix">>, <<"gess">>,
         <<"riff">>, <<"weft">>, <<"glan">>, <<"rill">>, <<"wesk">>,
         <<"glax">>, <<"saff">>, <<"winn">>, <<"glim">>, <<"shim">>,
         <<"wisp">>, <<"bris">>, <<"iphil">>, <<"opal">>, <<"cryl">>,
         <<"ispel">>, <<"oris">>, <<"elsi">>, <<"istle">>, <<"orif">>,
         <<"ember">>, <<"jat">>, <<"peri">>, <<"esk">>, <<"jost">>,
         <<"sarm">>, <<"feris">>, <<"jus">>, <<"sprin">>, <<"frimi">>,
         <<"lirra">>, <<"stith">>, <<"gan">>, <<"mali">>, <<"tansi">>,
         <<"glink">>, <<"mink">>, <<"tirra">>, <<"hal">>, <<"mirra">>,
         <<"trump">>, <<"hel">>, <<"mistle">>, <<"whis">>, <<"hist">>,
         <<"ninka">>, <<"zando">>]).
elements(<<"spry_male">>,
         [<<"aldo">>, <<"allo">>, <<"amo">>, <<"ando">>, <<"aroll">>,
         <<"aron">>, <<"asto">>, <<"endo">>, <<"eroll">>, <<"eron">>,
         <<"esto">>, <<"ondo">>, <<"bik">>, <<"brix">>, <<"frell">>,
         <<"fret">>, <<"kin">>, <<"mist">>, <<"mit">>, <<"rix">>,
         <<"tross">>, <<"twik">>, <<"win">>, <<"zisk">>]).
elements(<<"spry_female">>,
         [<<"afer">>, <<"amer">>, <<"anel">>, <<"arel">>, <<"asti">>,
         <<"efer">>, <<"enti">>, <<"erel">>, <<"ifer">>, <<"imer">>,
         <<"inel">>, <<"irel">>, <<"dee">>, <<"kiss">>, <<"la">>, <<"liss">>,
         <<"mee">>, <<"niss">>, <<"nyx">>, <<"ree">>, <<"riss">>, <<"sa">>,
         <<"tiss">>, <<"ynx">>]).

%% --- the listed names ----------------------------------------------------------
%% listed(Culture, Kind, Gender, Names): names the book lists as such (Norse and
%% Greek myth).

listed(dwarf, personal, male,
       [<<"Ai">>, <<"An">>, <<"Andvari">>, <<"Annar">>, <<"Austi">>,
       <<"Austri">>, <<"Bafur">>, <<"Berling">>, <<"Bifur">>, <<"Bombor">>,
       <<"Brokk">>, <<"Dain">>, <<"Delling">>, <<"Dolgthvari">>, <<"Dori">>,
       <<"Draupnir">>, <<"Dufr">>, <<"Duneyr">>, <<"Durathror">>,
       <<"Durin">>, <<"Dvalin">>, <<"Eikinskjaudi">>, <<"Eitri">>, <<"Fal">>,
       <<"Fili">>, <<"Fith">>, <<"Fjalar">>, <<"Frosti">>, <<"Fundin">>,
       <<"Ginnar">>, <<"Gloin">>, <<"Grerr">>, <<"Har">>, <<"Haur">>,
       <<"Hornbori">>, <<"Ingi">>, <<"Jari">>, <<"Kili">>, <<"Lit">>,
       <<"Loni">>, <<"Mjodvitnir">>, <<"Moin">>, <<"Nain">>, <<"Nali">>,
       <<"Nar">>, <<"Nibelung">>, <<"Nidi">>, <<"Nipingr">>, <<"Nordri">>,
       <<"Nyi">>, <<"Nyr">>, <<"Oinn">>, <<"Ori">>, <<"Radsuithr">>,
       <<"Radsvid">>, <<"Regin">>, <<"Rekk">>, <<"Sjarr">>, <<"Skandar">>,
       <<"Skirfir">>, <<"Sudri">>, <<"Thekkr">>, <<"Thorin">>, <<"Thror">>,
       <<"Thrurinn">>, <<"Veigur">>, <<"Vestri">>, <<"Vig">>, <<"Virvir">>,
       <<"Vithur">>, <<"Yingi">>]).
listed(nymph, personal, female,
       [<<"Adrasteia">>, <<"Aegina">>, <<"Amaltheia">>, <<"Ankhiale">>,
       <<"Arethusa">>, <<"Asterodeia">>, <<"Bakkhe">>, <<"Bromie">>,
       <<"Daphne">>, <<"Doris">>, <<"Dryope">>, <<"Dynamene">>, <<"Ekho">>,
       <<"Elektra">>, <<"Erato">>, <<"Euryanassa">>, <<"Eurythemista">>,
       <<"Idaea">>, <<"Io">>, <<"Iynx">>, <<"Kallirrhoe">>, <<"Kallisto">>,
       <<"Kalyke">>, <<"Kalypso">>, <<"Klytia">>, <<"Kreusa">>, <<"Linos">>,
       <<"Makris">>, <<"Nysa">>]).
listed(siren, personal, female,
       [<<"Aglaope">>, <<"Aglaophonos">>, <<"Leukosia">>, <<"Ligeia">>,
       <<"Molpe">>, <<"Parthenope">>, <<"Peisinoe">>, <<"Raidne">>,
       <<"Teles">>, <<"Thelxepeia">>, <<"Thelxiope">>]).

%% quod:measure — quantities, exactly.
%%
%% Every other ontology eventually holds a number with a unit. This one says
%% whether two units measure the same thing, converts between them, and refuses
%% a sum across dimensions. It is meant to be asked by other ontologies rather
%% than read: `quod:measure::convert(5, <<"mi">>, <<"km">>, D)`.
%%
%% Nothing here uses a floating point number. Ten nodes must agree bit for bit
%% on the result of a proof, and a float is a liability in that setting, so a
%% conversion factor is a pair of integers: a foot is 1143/3750, not 0.3048.
%% Values are integers or `Num/Den` terms, and results come back in lowest
%% terms.
%%
%% Model:
%%   dimension(D)                     a base dimension, in canonical order
%%   unit(Symbol, Over, Under, N, D)  Over/Under are base dimensions, N/D is the
%%                                    exact ratio of this unit to the base one
%%   prefix(P, N, D)                  a multiplier that composes with any unit
%%
%% Asked:
%%   signature(?Unit, ?Sig)           the canonical dimension vector
%%   commensurable(?A, ?B)            same dimensions, however they are written
%%   convert(+Value, +From, +To, ?Out)
%%   sum(+Quantities, +Unit, ?Total)  q(Value, Unit) terms, one dimension only
%%
%% The class and instance vocabulary at the end is a VIEW over these relations,
%% not a second copy of the data: two rules give generic tooling and other
%% ontologies the `isa`/`instance_of`/`attribute` handles they follow, while the
%% relations keep the arity that makes the arithmetic readable.

acl_sovereign(quod:measure).

can_invoke(Goal, _Principal, _CallChain, _Ns) :- measure_query(Goal).
can_invoke(_Goal, node(NodeKey), _CallChain, _Ns) :-
    peer_admitted(NodeKey, _, _, NodeKey).
can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).

measure_query(dimension(_)).
measure_query(unit(_, _, _, _, _)).
measure_query(prefix(_, _, _)).
measure_query(signature(_, _)).
measure_query(commensurable(_, _)).
measure_query(convert(_, _, _, _)).
measure_query(sum(_, _, _)).
measure_query(isa(_, _)).
measure_query(instance_of(_, _)).
measure_query(have_attribute(_, _, _)).
measure_query(attribute(_, _, _)).

%% --- dimensions ---------------------------------------------------------------
%% The seven SI base dimensions, plus the two everybody needs and SI leaves out.
%% This order is the canonical order of a signature.

dimension(<<"length">>).
dimension(<<"mass">>).
dimension(<<"time">>).
dimension(<<"current">>).
dimension(<<"temperature">>).
dimension(<<"amount">>).
dimension(<<"luminous">>).
dimension(<<"angle">>).
dimension(<<"information">>).

%% --- what a unit measures, and how big it is ----------------------------------

%% signature(?Unit, ?Sig): the unit's dimensions as one canonical list of
%% d(Dimension, Power), in dimension/1 order, with the zero powers dropped. Two
%% units measure the same thing exactly when their signatures are equal.
signature(Unit, Sig) :-
    scaled(Unit, Over, Under, _, _),
    findall(d(D, P),
            (dimension(D), power_of(D, Over, Under, P), P =\= 0),
            Sig).

power_of(D, Over, Under, P) :-
    occurrences(D, Over, A),
    occurrences(D, Under, B),
    P is A - B.

occurrences(_, [], 0).
occurrences(D, [D | Rest], N) :- !, occurrences(D, Rest, M), N is M + 1.
occurrences(_D, [_Other | Rest], N) :- occurrences(_D, Rest, N).

%% commensurable(?A, ?B): A and B measure the same thing.
commensurable(A, B) :-
    signature(A, Sig),
    signature(B, Sig).

%% scaled(?Symbol, ?Over, ?Under, ?Num, ?Den): a unit, or a prefixed one. A
%% prefix is parsed off the front rather than enumerated, so every prefix
%% composes with every unit and `km`, `us` and `MiB` need no facts of their own.
scaled(Symbol, Over, Under, Num, Den) :-
    unit(Symbol, Over, Under, Num, Den).
scaled(Symbol, Over, Under, Num, Den) :-
    \+ unit(Symbol, _, _, _, _),
    binary_codes(Symbol, Codes),
    prefix(Prefix, PrefixNum, PrefixDen),
    binary_codes(Prefix, PrefixCodes),
    append(PrefixCodes, BaseCodes, Codes),
    BaseCodes \= [],
    binary_codes(Base, BaseCodes),
    unit(Base, Over, Under, BaseNum, BaseDen),
    Num is PrefixNum * BaseNum,
    Den is PrefixDen * BaseDen.

%% --- exact conversion ---------------------------------------------------------

%% convert(+Value, +From, +To, ?Out): Value in From is Out in To. Both units
%% must measure the same thing. Value and Out are integers or Num/Den terms in
%% lowest terms; no floating point is involved at any step.
convert(Value, From, To, Out) :-
    rational(Value, ValueNum, ValueDen),
    scaled(From, Over, Under, FromNum, FromDen),
    scaled(To, Over2, Under2, ToNum, ToDen),
    signature_of(Over, Under, Sig),
    signature_of(Over2, Under2, Sig),
    Num is ValueNum * FromNum * ToDen,
    Den is ValueDen * FromDen * ToNum,
    reduced(Num, Den, Out).

signature_of(Over, Under, Sig) :-
    findall(d(D, P),
            (dimension(D), power_of(D, Over, Under, P), P =\= 0),
            Sig).

%% sum(+Quantities, +Unit, ?Total): the total of q(Value, Unit) terms, in Unit.
%% A quantity of another dimension has no answer here, which is the point: the
%% mistake is refused rather than silently added.
sum([], _Unit, 0).
sum([q(Value, From) | Rest], Unit, Total) :-
    convert(Value, From, Unit, Converted),
    sum(Rest, Unit, RestTotal),
    rational(Converted, AN, AD),
    rational(RestTotal, BN, BD),
    Num is AN * BD + BN * AD,
    Den is AD * BD,
    reduced(Num, Den, Total).

%% --- exact rational arithmetic ------------------------------------------------

rational(Value, Value, 1) :- integer(Value).
rational(Num / Den, Num, Den) :- integer(Num), integer(Den), Den =\= 0.

reduced(Num, Den, Out) :-
    Den > 0,
    gcd(Num, Den, G),
    N is Num // G,
    D is Den // G,
    (   D =:= 1 -> Out = N
    ;   Out = N / D
    ).

%% erlog evaluates `mod`, not `rem`, and its `/` is float division, so every
%% step here stays in integers: `//` for the quotient and `mod` for the rest.
gcd(A, 0, G) :- !, absolute(A, G).
gcd(A, B, G) :- R is A mod B, gcd(B, R, G).

absolute(A, A) :- A >= 0, !.
absolute(A, G) :- G is 0 - A.

%% --- the units ----------------------------------------------------------------
%% unit(Symbol, Over, Under, Num, Den): Num/Den is the exact ratio of one of
%% this unit to one of the base unit of the same dimensions.

%% SI base
unit(<<"m">>, [<<"length">>], [], 1, 1).
unit(<<"kg">>, [<<"mass">>], [], 1, 1).
unit(<<"s">>, [<<"time">>], [], 1, 1).
unit(<<"A">>, [<<"current">>], [], 1, 1).
unit(<<"K">>, [<<"temperature">>], [], 1, 1).
unit(<<"mol">>, [<<"amount">>], [], 1, 1).
unit(<<"cd">>, [<<"luminous">>], [], 1, 1).
unit(<<"rad">>, [<<"angle">>], [], 1, 1).
unit(<<"bit">>, [<<"information">>], [], 1, 1).

%% mass, where the base unit already carries a prefix
unit(<<"g">>, [<<"mass">>], [], 1, 1000).
unit(<<"t">>, [<<"mass">>], [], 1000, 1).
unit(<<"lb">>, [<<"mass">>], [], 45359237, 100000000).
unit(<<"oz">>, [<<"mass">>], [], 45359237, 1600000000).
unit(<<"st">>, [<<"mass">>], [], 635029318, 100000000).

%% length
unit(<<"in">>, [<<"length">>], [], 254, 10000).
unit(<<"ft">>, [<<"length">>], [], 1143, 3750).
unit(<<"yd">>, [<<"length">>], [], 3429, 3750).
unit(<<"mi">>, [<<"length">>], [], 201168, 125).
unit(<<"nmi">>, [<<"length">>], [], 1852, 1).
unit(<<"fathom">>, [<<"length">>], [], 4572, 2500).
unit(<<"furlong">>, [<<"length">>], [], 25146, 125).
unit(<<"pt">>, [<<"length">>], [], 254, 720000).
unit(<<"pica">>, [<<"length">>], [], 254, 60000).
unit(<<"au">>, [<<"length">>], [], 149597870700, 1).

%% time
unit(<<"min">>, [<<"time">>], [], 60, 1).
unit(<<"h">>, [<<"time">>], [], 3600, 1).
unit(<<"d">>, [<<"time">>], [], 86400, 1).
unit(<<"wk">>, [<<"time">>], [], 604800, 1).
unit(<<"yr">>, [<<"time">>], [], 31557600, 1).

%% angle
unit(<<"deg">>, [<<"angle">>], [], 31415926535897932, 1800000000000000000).
unit(<<"grad">>, [<<"angle">>], [], 31415926535897932, 2000000000000000000).
unit(<<"turn">>, [<<"angle">>], [], 31415926535897932, 5000000000000000).

%% information, decimal and binary alike
unit(<<"B">>, [<<"information">>], [], 8, 1).
unit(<<"KiB">>, [<<"information">>], [], 8192, 1).
unit(<<"MiB">>, [<<"information">>], [], 8388608, 1).
unit(<<"GiB">>, [<<"information">>], [], 8589934592, 1).
unit(<<"TiB">>, [<<"information">>], [], 8796093022208, 1).

%% area and volume
unit(<<"ha">>, [<<"length">>, <<"length">>], [], 10000, 1).
unit(<<"acre">>, [<<"length">>, <<"length">>], [], 316160658, 78125).
unit(<<"L">>, [<<"length">>, <<"length">>, <<"length">>], [], 1, 1000).
unit(<<"gal">>, [<<"length">>, <<"length">>, <<"length">>], [], 454609, 100000000).
unit(<<"galUS">>, [<<"length">>, <<"length">>, <<"length">>], [], 3785411784, 1000000000000).
unit(<<"tsp">>, [<<"length">>, <<"length">>, <<"length">>], [], 5, 1000000).
unit(<<"tbsp">>, [<<"length">>, <<"length">>, <<"length">>], [], 15, 1000000).
unit(<<"cup">>, [<<"length">>, <<"length">>, <<"length">>], [], 25, 100000).

%% derived, where the dimensions are the whole point
unit(<<"Hz">>, [], [<<"time">>], 1, 1).
unit(<<"N">>, [<<"mass">>, <<"length">>], [<<"time">>, <<"time">>], 1, 1).
unit(<<"Pa">>, [<<"mass">>], [<<"length">>, <<"time">>, <<"time">>], 1, 1).
unit(<<"J">>, [<<"mass">>, <<"length">>, <<"length">>], [<<"time">>, <<"time">>], 1, 1).
unit(<<"W">>, [<<"mass">>, <<"length">>, <<"length">>],
     [<<"time">>, <<"time">>, <<"time">>], 1, 1).
unit(<<"C">>, [<<"current">>, <<"time">>], [], 1, 1).
unit(<<"Wh">>, [<<"mass">>, <<"length">>, <<"length">>], [<<"time">>, <<"time">>], 3600, 1).
unit(<<"cal">>, [<<"mass">>, <<"length">>, <<"length">>], [<<"time">>, <<"time">>], 4184, 1000).
unit(<<"eV">>, [<<"mass">>, <<"length">>, <<"length">>], [<<"time">>, <<"time">>],
     1602176634, 10000000000000000000000000000).
unit(<<"kn">>, [<<"length">>], [<<"time">>], 1852, 3600).
unit(<<"mps">>, [<<"length">>], [<<"time">>], 1, 1).
unit(<<"kph">>, [<<"length">>], [<<"time">>], 1000, 3600).
unit(<<"mph">>, [<<"length">>], [<<"time">>], 201168, 450000).

%% --- prefixes -----------------------------------------------------------------
prefix(<<"da">>, 10, 1).
prefix(<<"h">>, 100, 1).
prefix(<<"k">>, 1000, 1).
prefix(<<"M">>, 1000000, 1).
prefix(<<"G">>, 1000000000, 1).
prefix(<<"T">>, 1000000000000, 1).
prefix(<<"P">>, 1000000000000000, 1).
prefix(<<"d">>, 1, 10).
prefix(<<"c">>, 1, 100).
prefix(<<"m">>, 1, 1000).
prefix(<<"u">>, 1, 1000000).
prefix(<<"n">>, 1, 1000000000).
prefix(<<"p">>, 1, 1000000000000).

%% --- the class view -----------------------------------------------------------
%% The house vocabulary of doc/content-layer-design.md, derived from the
%% relations above rather than stored beside them. This is what lets generic
%% tooling enumerate what is here without knowing unit/5, and lets another
%% ontology write isa(my_unit, quod:measure::unit) and have the link followed.

isa(unit, thing).
isa(dimension, thing).

instance_of(dimension, D) :- dimension(D).
instance_of(unit, U) :- unit(U, _, _, _, _).

have_attribute(unit, signature, list).
have_attribute(unit, ratio, term).

attribute(U, signature, Sig) :- unit(U, _, _, _, _), signature(U, Sig).
attribute(U, ratio, Num / Den) :- unit(U, _, _, Num, Den).

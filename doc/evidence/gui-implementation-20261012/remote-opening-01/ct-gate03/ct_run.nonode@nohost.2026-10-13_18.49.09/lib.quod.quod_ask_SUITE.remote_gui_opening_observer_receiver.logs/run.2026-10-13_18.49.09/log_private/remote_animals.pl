can_invoke(_Goal, agent_instance_ref(<<"pets">>, _, human_user(test_agent)), _Chain, _Ns).
%% animals — a demo knowledge ontology (doc/proofs.md). NOT a system
%% ontology — plain user-level content; the test bed for inter-ontology asks.
%%
%% Real content: a small class hierarchy with attributes and diets, following the
%% house vocabulary — isa(Sub, Super), instance_of(Class, Instance) (class first),
%% have_attribute(Class, Name, Type[, default(V)]), attribute(Instance, Name, Value),
%% rooted at `thing`. Other ontologies link into it with `:` names
%% (e.g. pets' `isa(my_dog, animals:dog)`) and ask it questions with `::`
%% (e.g. `animals::diet(dog, D)`).

%% Invocation is open through the broad can_invoke/4 clause below; see doc/proofs.md.
can_invoke(_Goal, _Principal, _CallChain, _Ns).
can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).

%% --- the class hierarchy ----------------------------------------------------
isa(animal, thing).
isa(mammal, animal).
isa(dog, mammal).
isa(cat, mammal).
isa(bird, animal).
isa(parrot, bird).

%% --- class attributes (typed, with defaults) ---------------------------------
have_attribute(animal, legs, integer, default(4)).
have_attribute(bird,   legs, integer, default(2)).
have_attribute(animal, sound, atom).

%% --- plain facts about the classes -------------------------------------------
diet(dog, kibble).
diet(dog, meat).
diet(cat, fish).
diet(parrot, seeds).

sound(dog, woof).
sound(cat, meow).
sound(parrot, squawk).

echo(X).
quod_r4_target_only_D1D118EBCD70585E(opaque).
blocked(X) :- fail_with_reason(impossible_to_link(X)).
via_third_failure :- third::third_blocked.
via_fourth(X) :- third::via_fourth(X).
dtx_write_chain(X) :- assertz(dtx_animals_mark(X)), third::dtx_write(X).
dtx_disjoint_write_chain_1(X) :- assertz(dtx_animals_mark_1(X)), third::dtx_third_write_1(X).
dtx_disjoint_write_chain_2(X) :- assertz(dtx_animals_mark_2(X)), third::dtx_third_write_2(X).
dtx_disjoint_write_chain_3(X) :- assertz(dtx_animals_mark_3(X)), third::dtx_third_write_3(X).
dtx_disjoint_write_chain_4(X) :- assertz(dtx_animals_mark_4(X)), third::dtx_third_write_4(X).
dtx_disjoint_write_chain_5(X) :- assertz(dtx_animals_mark_5(X)), third::dtx_third_write_5(X).
dtx_disjoint_write_chain_6(X) :- assertz(dtx_animals_mark_6(X)), third::dtx_third_write_6(X).
dtx_disjoint_write_chain_7(X) :- assertz(dtx_animals_mark_7(X)), third::dtx_third_write_7(X).
dtx_disjoint_write_chain_8(X) :- assertz(dtx_animals_mark_8(X)), third::dtx_third_write_8(X).
conflict_version(0).
dtx_conflicting_write(X) :- conflict_version(_), retract(conflict_version(0)), assertz(conflict_version(X)), assertz(dtx_conflict_mark(X)), third::dtx_write(X).
deep_failure(70) :- deep_failure(69).
deep_failure(69) :- deep_failure(68).
deep_failure(68) :- deep_failure(67).
deep_failure(67) :- deep_failure(66).
deep_failure(66) :- deep_failure(65).
deep_failure(65) :- deep_failure(64).
deep_failure(64) :- deep_failure(63).
deep_failure(63) :- deep_failure(62).
deep_failure(62) :- deep_failure(61).
deep_failure(61) :- deep_failure(60).
deep_failure(60) :- deep_failure(59).
deep_failure(59) :- deep_failure(58).
deep_failure(58) :- deep_failure(57).
deep_failure(57) :- deep_failure(56).
deep_failure(56) :- deep_failure(55).
deep_failure(55) :- deep_failure(54).
deep_failure(54) :- deep_failure(53).
deep_failure(53) :- deep_failure(52).
deep_failure(52) :- deep_failure(51).
deep_failure(51) :- deep_failure(50).
deep_failure(50) :- deep_failure(49).
deep_failure(49) :- deep_failure(48).
deep_failure(48) :- deep_failure(47).
deep_failure(47) :- deep_failure(46).
deep_failure(46) :- deep_failure(45).
deep_failure(45) :- deep_failure(44).
deep_failure(44) :- deep_failure(43).
deep_failure(43) :- deep_failure(42).
deep_failure(42) :- deep_failure(41).
deep_failure(41) :- deep_failure(40).
deep_failure(40) :- deep_failure(39).
deep_failure(39) :- deep_failure(38).
deep_failure(38) :- deep_failure(37).
deep_failure(37) :- deep_failure(36).
deep_failure(36) :- deep_failure(35).
deep_failure(35) :- deep_failure(34).
deep_failure(34) :- deep_failure(33).
deep_failure(33) :- deep_failure(32).
deep_failure(32) :- deep_failure(31).
deep_failure(31) :- deep_failure(30).
deep_failure(30) :- deep_failure(29).
deep_failure(29) :- deep_failure(28).
deep_failure(28) :- deep_failure(27).
deep_failure(27) :- deep_failure(26).
deep_failure(26) :- deep_failure(25).
deep_failure(25) :- deep_failure(24).
deep_failure(24) :- deep_failure(23).
deep_failure(23) :- deep_failure(22).
deep_failure(22) :- deep_failure(21).
deep_failure(21) :- deep_failure(20).
deep_failure(20) :- deep_failure(19).
deep_failure(19) :- deep_failure(18).
deep_failure(18) :- deep_failure(17).
deep_failure(17) :- deep_failure(16).
deep_failure(16) :- deep_failure(15).
deep_failure(15) :- deep_failure(14).
deep_failure(14) :- deep_failure(13).
deep_failure(13) :- deep_failure(12).
deep_failure(12) :- deep_failure(11).
deep_failure(11) :- deep_failure(10).
deep_failure(10) :- deep_failure(9).
deep_failure(9) :- deep_failure(8).
deep_failure(8) :- deep_failure(7).
deep_failure(7) :- deep_failure(6).
deep_failure(6) :- deep_failure(5).
deep_failure(5) :- deep_failure(4).
deep_failure(4) :- deep_failure(3).
deep_failure(3) :- deep_failure(2).
deep_failure(2) :- deep_failure(1).
deep_failure(1) :- deep_failure(0).
deep_failure(0) :- fail_with_reason(deep_bottom).
bounded_reason :- deep_reason_value(63, deep_bottom, Reason), !, fail_with_reason(Reason).
deep_reason :- deep_reason_value(70, deep_bottom, Reason), !, fail_with_reason(Reason).
deep_reason_value(0, Acc, Acc).
deep_reason_value(N, Acc, Out) :- N > 0, Next is N - 1, deep_reason_value(Next, [Acc], Out).
loop :- loop.

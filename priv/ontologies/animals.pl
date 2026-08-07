%% animals — a demo knowledge ontology (doc/inter-ontology.md). NOT a system
%% ontology — plain user-level content; the test bed for inter-ontology asks.
%%
%% Real content: a small class hierarchy with attributes and diets, following the
%% house vocabulary — isa(Sub, Super), instance_of(Class, Instance) (class first),
%% have_attribute(Class, Name, Type[, default(V)]), attribute(Instance, Name, Value),
%% rooted at `thing`. Other ontologies link into it with `:` names
%% (e.g. pets' `isa(my_dog, animals:dog)`) and ask it questions with `::`
%% (e.g. `animals::diet(dog, D)`).

%% Invocation is open (same default-open rule as quod:root; see doc/inter-ontology.md §6).
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

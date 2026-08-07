%% pets — a demo ontology of individuals that LINKS INTO animals (doc/inter-ontology.md).
%%
%% The cross-ontology links are ordinary facts whose arguments carry `:` names:
%% `isa(my_dog, animals:dog)` says my_dog is a kind of the `dog` that lives in the
%% `animals` ontology. Storing the link costs nothing; a question that needs what is
%% over there (e.g. "what does my_dog eat?") follows it as an `animals::...` ask.
%% `no_follow(pedigree_ref/2)` keeps that one relation's foreign names inert data.

%% Invocation is open (same default-open rule as quod:root; see doc/inter-ontology.md §6).
can_invoke(_Goal, _Principal, _CallChain, _Ns).
can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).

%% --- individuals -------------------------------------------------------------
isa(pet, thing).
instance_of(pet, my_dog).
instance_of(pet, my_cat).

%% --- links into the animals ontology (facts ARE the web) ---------------------
isa(my_dog, animals:dog).
isa(my_cat, animals:cat).

%% A custom relation crossing the boundary — no special treatment needed.
attached_to(my_dog, animals:dog).

%% --- local facts -------------------------------------------------------------
attribute(my_dog, name, rex).
attribute(my_cat, name, mimi).

%% A relation whose foreign names must stay inert data (never followed):
%% a pedigree reference is a record locator, not a question to ask.
no_follow(pedigree_ref/2).
pedigree_ref(my_dog, animals:dog).

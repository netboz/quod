agent_key(human_user(test_agent), <<"\xB8\\x31\\x86\\x3A\\x17\\x5A\\x9A\\x07\\x77\\x99\\x01\\x95\\xE2\\x0E\\x25\\xB7\\x6E\\x4D\\xBF\\x91\\x78\\x69\\x76\\xAC\\xE7\\x1F\\x6F\\xC6\\xF5\\x2D\\x66\\xBF\">>, active).
can_invoke((assertz(signed_pets_mark(_)), _), agent_instance_ref(<<"pets">>, _, human_user(test_agent)), _Chain, _Ns).
can_invoke((instance_of(pet, my_dog), _), agent_instance_ref(<<"pets">>, _, human_user(test_agent)), _Chain, _Ns).
can_invoke(independent(_), agent_instance_ref(<<"pets">>, _, human_user(test_agent)), _Chain, _Ns).
can_invoke((_;_), agent_instance_ref(<<"pets">>, _, human_user(test_agent)), _Chain, _Ns).
%% pets — a demo ontology of individuals that LINKS INTO animals (doc/proofs.md).
%%
%% The cross-ontology links are ordinary facts whose arguments carry `:` names:
%% `isa(my_dog, animals:dog)` says my_dog is a kind of the `dog` that lives in the
%% `animals` ontology. Storing the link costs nothing; a question that needs what is
%% over there (e.g. "what does my_dog eat?") follows it as an `animals::...` ask.
%% `no_follow(pedigree_ref/2)` keeps that one relation's foreign names inert data.

%% Invocation is open through the broad can_invoke/4 clause below; see doc/proofs.md.
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

recover_third_failure :- animals::via_third_failure ; get_fail_reasons([_, _, _, _, third_declined]).

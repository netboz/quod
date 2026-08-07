%% Source side of the opt-in cross-ontology benchmark topology.
%%
%% The load driver submits an explicit Target::Goal from this namespace. Keeping
%% its own content minimal makes measured work remote routing/answering rather
%% than local proof search.

can_invoke(_Goal, _Principal, _CallChain, _Ns).
can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).

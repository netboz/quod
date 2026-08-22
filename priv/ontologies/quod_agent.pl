%% quod:agent — shared vocabulary for ontologies which can act.
acl_sovereign(quod:agent).
can_invoke(_Goal, node(NodeKey), _CallChain, _Ns) :-
    peer_admitted(NodeKey, _, _, NodeKey).
can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).

isa(agent, thing).

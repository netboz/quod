%% quod:human_user — human-facing agent vocabulary, never a global user table.
acl_sovereign(quod:human_user).
can_invoke(_Goal, node(NodeKey), _CallChain, _Ns) :-
    peer_admitted(NodeKey, _, _, NodeKey).
can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).

isa(human_user, agent).

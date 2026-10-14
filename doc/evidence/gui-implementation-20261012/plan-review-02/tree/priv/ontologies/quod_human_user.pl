%% quod:human_user — human-facing agent vocabulary, never a global user table.
acl_sovereign(quod:human_user).
can_invoke(Goal, _, _, _) :- human_user_query(Goal).
can_invoke((current_ontology_identity(_, _), Goal), _, _, _) :- human_user_query(Goal).
can_invoke(Goal, _, _, _) :- system_source_query(Goal).
can_invoke(_Goal, node(NodeKey), _CallChain, _Ns) :-
    peer_admitted(NodeKey, _, _, NodeKey).
can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).

human_user_query(isa(_, _)).
human_user_query(Goal) :- public_source_query(Goal).

isa(human_user, agent).

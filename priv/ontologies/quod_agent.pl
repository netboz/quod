%% quod:agent — shared vocabulary for ontologies which can act.
acl_sovereign(quod:agent).
can_invoke(Goal, _, _, _) :- agent_query(Goal).
can_invoke((current_ontology_identity(_, _), Goal), _, _, _) :- agent_query(Goal).
can_invoke(Goal, _, _, _) :- system_source_query(Goal).
can_invoke(_Goal, node(NodeKey), _CallChain, _Ns) :-
    peer_admitted(NodeKey, _, _, NodeKey).
can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).

agent_query(isa(_, _)).
agent_query(Goal) :- public_source_query(Goal).

public_prolog_predicate(isa/2).

isa(agent, thing).

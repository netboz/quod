%% quod:node — node class and node-hosting policy vocabulary.
acl_sovereign(quod:node).
can_invoke(_Goal, node(NodeKey), _CallChain, _Ns) :-
    peer_admitted(NodeKey, _, _, NodeKey).
can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).

isa(node, agent).

%% Node-local ontology hosting is an ordinary action. The public bridge binds
%% an opaque Handle; only the common action relation can reach the internal
%% staging continuation after these declared prerequisites succeed.
ontology_hosted(Name) :- ontology_join_state(Name, starting).
ontology_hosted(Name) :- ontology_join_state(Name, joining).
ontology_hosted(Name) :- ontology_join_state(Name, ready).

ontology_joined(Name, GenesisHash) :-
    ontology_hosted(Name),
    ontology_genesis_anchor(Name, GenesisHash).

action('$quod_stage_ontology'(Handle,
                              create_ontology(Name, Options),
                              ontology_hosted(Name)),
       [current_principal(Agent),
        can_create_ontology(Agent, Name, Options),
        ontology_join_state(Name, not_hosted)],
       ontology_hosted(Name)).

action('$quod_stage_ontology'(Handle,
                              join_ontology(Name, GenesisHash, Seeds),
                              ontology_joined(Name, GenesisHash)),
       [current_principal(Agent),
        can_join_ontology(Agent, Name, GenesisHash, Seeds),
        ontology_join_state(Name, not_hosted)],
       ontology_joined(Name, GenesisHash)).

%% First-slice authority: an admitted node may change its own hosting state.
%% Later policy may delegate these goals to stable agent references without
%% changing the Erlang bridge or action machinery.
can_create_ontology(node(NodeKey), _Name, _Options) :-
    peer_admitted(NodeKey, _, _, NodeKey).

can_join_ontology(node(NodeKey), _Name, _GenesisHash, _Seeds) :-
    peer_admitted(NodeKey, _, _, NodeKey).

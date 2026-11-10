%% The two storing-ontology derivations used by installed hosting selection.
%% Hosting actions and recovery behavior belong to quod:agent.
agent_hosted(Instance, NodeRef, Epoch, PublicKey) :-
    findall(host(N,E,K),agent_host(Instance,N,E,K),[host(NodeRef,Epoch,PublicKey)]),
    findall(K,agent_key(Instance,K,active),[PublicKey]).
agent_hosting_projection(Requested, Node, Scope, Hosts) :-
    (Requested = agent(Instance) -> Scope = keys([Instance]), Instances = [Instance]
    ; Requested = all, Scope = all,
      findall(I,agent_host(I,Node,_,_),Raw),sort(Raw,Instances)),
    (Node \= none ->
        findall(host(I,Node,E,K),
            (member(I,Instances),agent_hosted(I,Node,E,K),\+ agent_hosting_suspended(I)),Hosts)
    ; Hosts = []).

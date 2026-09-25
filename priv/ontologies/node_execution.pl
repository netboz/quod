%% Explicit delegation by this node's own ontology. The runtime supplies the
%% requesting ontology's installed identity; a hosting declaration alone grants
%% no node signing authority. Grant and consequence belong to one signed proof.
node_authorized_goal(Source, Anchor, Goal) :-
    can_execute_for(Source, Anchor, Goal),
    Source::(current_ontology_identity(Source, Anchor), call(Goal)).

%% The node identity and hosting policy live in its own ontology. Founding
%% supplies node_ontology/1 and the node instance/key. The signed-request
%% boundary verifies the principal's exact anchor before this entry policy.
node_instance_reference(agent_instance_ref(Namespace, _, Instance)) :-
    node_ontology(Namespace),
    instance_of(node, Instance).

can_invoke(_, Principal, _, Namespace) :-
    node_ontology(Namespace), node_instance_reference(Principal).
can_invoke(host_ontology(Node, Namespace, Anchor, Visibility), Principal, _, _) :-
    can_host_ontology(Principal, Node, Namespace, Anchor, Visibility).

%% Applications may add narrower can_host_ontology/5 rules to this node's
%% policy. A user login or a hosting declaration alone grants no authority.
can_host_ontology(Node, Node, _, _, _) :- node_instance_reference(Node).

action(host_ontology(Node, Namespace, Anchor, Visibility),
       [ontology_hosting_request(Node, Namespace, Anchor, Visibility)],
       hosts_ontology(Node, Namespace, Anchor, Visibility)).

%% Entry policy applies even when the desired fact already exists. A changed
%% identity or visibility requires an explicit policy change, not an overwrite.
host_ontology(Node, Namespace, Anchor, Visibility) :-
    ontology_hosting_request(Node, Namespace, Anchor, Visibility),
    (hosts_ontology(Node, Namespace, Anchor, Visibility) -> true
    ; \+ hosts_ontology(Node, Namespace, _, _),
      assertz(hosts_ontology(Node, Namespace, Anchor, Visibility))).

ontology_hosting_request(Node, Namespace, Anchor, Visibility) :-
    term_variables(host(Node, Namespace, Anchor, Visibility), []),
    node_instance_reference(Node),
    binary_codes(Namespace, [_|_]),
    binary_codes(Anchor, Bytes), length(Bytes, 32),
    (Visibility = private ; Visibility = discoverable).

state_handler(node_ontology_hosting,
              [hosts_ontology/4, knows_ontology_host/4], [],
              reconcile_node_ontology_hosting).

reconcile_node_ontology_hosting(Scope) :-
    findall(host(NodeRef, Namespace, Anchor, Visibility),
            hosts_ontology(NodeRef, Namespace, Anchor, Visibility), Hosts),
    findall(contact(NodeRef, Namespace, Anchor, HostNodeRef),
            knows_ontology_host(NodeRef, Namespace, Anchor, HostNodeRef), Contacts),
    '$quod_project_node_ontology_hosting'(Hosts, Contacts, Scope).

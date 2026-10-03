%% Explicit delegation constructed by this node's own trusted handler. Source
%% identity and permission are checked in the consequence's signed proof; a
%% hosting declaration alone grants no node signing authority.
node_authorized_goal(Source, Anchor, Goal) :-
    can_execute_for(Source, Anchor, Goal),
    Source::(current_ontology_identity(Source, Anchor), call(Goal)).

%% The node identity and hosting policy live in its own ontology. Founding
%% supplies node_ontology/1 and the node instance/key. The signed-request
%% boundary verifies the principal's exact anchor before this entry policy.
node_instance_reference(agent_instance_ref(Namespace, _, Instance)) :-
    node_ontology(Namespace),
    instance_of(node, Instance).

can_invoke(_, Principal, [Namespace], Namespace) :-
    node_ontology(Namespace), node_instance_reference(Principal).
can_invoke(host_ontology(Node, Namespace, Anchor, Visibility), Principal, Chain, Target) :-
    node_hosting_context(Principal, Chain, Target),
    can_host_ontology(Principal, Node, Namespace, Anchor, Visibility).
can_invoke(request_ontology_hosting(Principal, _, _, _, _), Principal, Chain, Target) :-
    node_hosting_context(Principal, Chain, Target).

%% Every hosting entry shares the self-authority restriction. A foreign helper
%% still acting as this node cannot recover its privileges through an alternate
%% grant; independent callers retain their ordinary hosting policy checks.
node_hosting_context(Principal, Chain, Namespace) :-
    (node_instance_reference(Principal) ->
        node_ontology(Namespace), Chain = [Namespace]
    ; true).

%% Applications may add narrower can_host_ontology/5 rules to this node's
%% policy. A user login or a hosting declaration alone grants no authority.
can_host_ontology(Node, Node, _, _, _) :- node_instance_reference(Node).
%% Entry binds the requester to the authenticated principal. Foreign policy
%% belongs in the ordinary proof, not the strictly local admission predicate.
request_ontology_hosting(Principal, Node, Namespace, Anchor, Visibility) :-
    can_host_ontology(Principal, Node, Namespace, Anchor, Visibility),
    host_ontology(Node, Namespace, Anchor, Visibility).
request_ontology_hosting(Principal, Node, Namespace, Anchor, Visibility) :-
    ontology_hosting_policy(Policy, PolicyAnchor),
    Policy::(current_ontology_identity(Policy, PolicyAnchor),
             ontology_hosting_allowed(Principal, Node, Namespace, Anchor, Visibility)),
    host_ontology(Node, Namespace, Anchor, Visibility).

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

node_ontology_hosting_projection(Hosts, Contacts) :-
    findall(host(NodeRef, Namespace, Anchor, Visibility),
            hosts_ontology(NodeRef, Namespace, Anchor, Visibility), Hosts),
    findall(contact(NodeRef, Namespace, Anchor, HostNodeRef),
            knows_ontology_host(NodeRef, Namespace, Anchor, HostNodeRef), Contacts).

%% Only this node's behavior constructs a goal to execute with its identity.
%% Runtime supplies validated data from the affected ontology and retains the
%% original observation in private match metadata for custody validation.
react_on(observed(agent_recovery_ready(Observer, Target, Host, Epoch, Expected,
                                      Round, Report, Kind, Preparation)), Goal) :-
    recovery_observation(agent_recovery_ready(Observer, Target, Host, Epoch, Expected,
                                               Round, Report, Kind, Preparation)),
    me(Observer),
    Report = observation(_, _, Expiry),
    limit_reaction_expiry(Expiry),
    node_recovery_goal(Target, Host, Epoch, Expected, Round, Report, Kind, Preparation, Goal).

node_recovery_goal(Target, Host, Epoch, Expected, Round, Report, Kind, required,
                   node_authorized_goal(Source, Anchor, Operation)) :-
    Target = agent_instance_ref(Source, Anchor, Instance),
    prepare_agent_custody(Target, Epoch, Prepared),
    Operation = report_agent_observation_with_custody(Instance, Host, Epoch,
                                                     Expected, Round, Report, Kind, Prepared).
node_recovery_goal(agent_instance_ref(Source, Anchor, Instance), Host, Epoch,
                   Expected, Round, Report, Kind, none,
                   node_authorized_goal(Source, Anchor,
                     report_agent_observation(Instance, Host, Epoch, Expected, Round, Report, Kind))).

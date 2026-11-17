%% quod:node — node class and node-hosting policy vocabulary.
acl_sovereign(quod:node).
can_invoke(Goal, _, _, _) :- node_query(Goal).
can_invoke((current_ontology_identity(_, _), Goal), _, _, _) :- node_query(Goal).
can_invoke(Goal, _, _, _) :- system_source_query(Goal).
can_invoke(_Goal, node(NodeKey), _CallChain, _Ns) :-
    peer_admitted(NodeKey, _, _, NodeKey).
can_join(_Ns, _Addr, Pk) :- peer_ready(Pk).

node_query(isa(_, _)).
node_query(Goal) :- public_source_query(Goal).

isa(node, agent).

%% The applicant owns only this key-bound enrollment identity. Completed
%% identities are ordinary ontologies, not instances stored in this class.
open_node_enrollment.
instance_of(agent, enrolling(Key)) :- node_enrollment_key(Key).
agent_key(enrolling(Key), Key, active) :-
    open_node_enrollment, node_enrollment_key(Key).

node_enrollment_key(Key) :- binary_codes(Key, Bytes), length(Bytes, 32).
node_applicant(agent_instance_ref(Namespace, Anchor, enrolling(Key)), Key) :-
    current_ontology_identity(Namespace, Anchor), node_enrollment_key(Key).

can_invoke(enroll_node(_), Principal, _, _) :- node_applicant(Principal, _).
can_invoke(node_identity_status(_), Principal, _, _) :- node_applicant(Principal, _).
node_query(ontology_creation_allowed(_, _, _)).
node_query(ontology_hosting_allowed(_, _, _, _, _)).
node_query(node_enrollment_parameters(_)).
node_enrollment_window_ms(30000).
node_enrollment_parameters(Window) :-
    open_node_enrollment, node_identity_template(_),
    node_enrollment_window_ms(Window), integer(Window), Window > 0.

%% Allocation is permanent. In particular, acknowledgment must not erase the
%% key-to-history binding and allow a second anchor on another executor.
node_identity_status(Reference) :-
    current_principal(Principal), node_applicant(Principal, Key),
    node_identity_allocation(Key, Reference, _).

enroll_node(Reference) :-
    current_principal(Principal), node_applicant(Principal, Key),
    node_identity_allocation(Key, Reference, _), !.
enroll_node(Reference) :-
    open_node_enrollment,
    current_principal(Principal), node_applicant(Principal, Key),
    transaction((
        \+ node_identity_allocation(Key, _, _),
        node_identity_options(Principal, Name, Options),
        quod:root::(current_executor_key(Executor),
                    create_ontology(Name, Options, Anchor)),
        Reference = agent_instance_ref(Name, Anchor, me),
        (Executor = Key -> Host = Reference ; node_identity_allocation(Executor, Host, _)),
        assertz(node_identity_allocation(Key, Reference, Host)),
        node_initial_host(Host, Reference, Principal, Name, Anchor))).

%% Self-creation is recovered by the applicant's retained exact operation and
%% the existing local effect journal. Other executors need a durable ordinary
%% hosting fact in their own node ontology in this same atomic transition.
node_initial_host(Reference, Reference, _, _, _).
node_initial_host(Host, Reference, Principal, Name, Anchor) :-
    Host \= Reference,
    Host = agent_instance_ref(HostNamespace, _, _),
    HostNamespace::request_ontology_hosting(Principal, Host, Name, Anchor, discoverable).

ontology_hosting_allowed(Principal, Host, Name, Anchor, discoverable) :-
    current_principal(Principal), node_applicant(Principal, Key),
    node_identity_allocation(Key, agent_instance_ref(Name, Anchor, me), Host).

ontology_creation_allowed(Principal, Name, Options) :-
    open_node_enrollment,
    node_applicant(Principal, Key),
    \+ node_identity_allocation(Key, _, _),
    node_identity_options(Principal, Name, Options).

%% The source bytes and exact class anchor are committed policy inputs. An
%% applicant cannot choose a filename, modules, ACL, instance, or another key.
node_identity_options(Principal, Name,
    [terms([node_ontology(Name), instance_of(node, me), agent_key(me, Key, active),
            ontology_hosting_policy(Namespace, Anchor)]),
     source(Source), external_predicate_modules([quod_ontology_predicates])]) :-
    node_applicant(Principal, Key),
    node_identity_name(Key, Name),
    current_ontology_identity(Namespace, Anchor),
    node_identity_template(Source).

node_identity_name(Key, Name) :-
    node_enrollment_key(Key), binary_codes(Key, Bytes),
    node_key_hex(Bytes, Hex), append([110,111,100,101,58], Hex, Codes),
    binary_codes(Name, Codes).
node_key_hex([], []).
node_key_hex([Byte|Rest], [High,Low|Hex]) :-
    H is Byte // 16, L is Byte mod 16,
    node_hex_digit(H, High), node_hex_digit(L, Low), node_key_hex(Rest, Hex).
node_hex_digit(N, Digit) :- (N < 10 -> Digit is N + 48 ; Digit is N + 87).

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
                              join_ontology(Name, GenesisHash, Seeds),
                              ontology_joined(Name, GenesisHash)),
       [current_principal(Agent),
        can_join_ontology(Agent, Name, GenesisHash, Seeds),
        ontology_join_state(Name, not_hosted)],
       ontology_joined(Name, GenesisHash)).

%% First-slice authority: an admitted node may change its own hosting state.
%% Root separately governs creation of a new ontology identity. Later policy
%% may delegate joining to stable agent references without changing the Erlang
%% bridge or action machinery.
can_join_ontology(node(NodeKey), _Name, _GenesisHash, _Seeds) :-
    peer_admitted(NodeKey, _, _, NodeKey).

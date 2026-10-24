%% Composed with human_user_instance.pl and agent_instance.pl. The human and
%% personal actor share an ontology, never an identity or a private key.
instance_of(agent, personal).

personal_agent(Agent, Key) :-
    current_principal(Owner), human_user_owner(Owner),
    current_ontology_identity(Ns, Anchor),
    Agent = agent_instance_ref(Ns, Anchor, personal),
    hosting_node(Node), agent_hosted(personal, Node, _, Key).

personal_agent_preparation(Preparation) :-
    current_principal(Owner), human_user_owner(Owner),
    hosting_node(Node),
    (agent_hosted(personal, Node, _, _) -> Preparation = ready
    ; current_ontology_identity(Ns, Anchor),
      prepare_agent_key_custody(agent_instance_ref(Ns, Anchor, personal), none, 0, Node, Key),
      Preparation = prepared(Node, Key)).

personal_agent_initialize(Node, Key) :-
    goal(agent_hosted(personal, Node, 1, Key)).

can_prepare_agent_key(Owner, personal, none, 0, Node) :-
    Owner = agent_instance_ref(_, _, Human), instance_of(human_user, Human), hosting_node(Node).
can_assign_agent_host(Owner, personal, none, 0, Node, _) :-
    Owner = agent_instance_ref(_, _, Human), instance_of(human_user, Human), hosting_node(Node).

%% Admission is a committed read, not a stored task. The instruction endpoint
%% attempts it only in an already installed, idle hosted incarnation.
personal_instruction_accept(Bytes, Signature) :-
    current_principal(Owner),
    agent_request_bytes(Typed, Bytes),
    can_instruct_personal_agent(Owner, Typed),
    Typed = agent_goal_v1(_, _, _, _, _, Expiry, _, _, _),
    current_request_expiry(Deadline), Expiry =< Deadline,
    sign_agent_request(Typed, Signature).

can_instruct_personal_agent(Owner,
    agent_goal_v1(_, agent_instance_ref(Ns, Anchor, personal), _, Key, _, _, execute, 3, _)) :-
    Owner = agent_instance_ref(Ns, Anchor, Human), instance_of(human_user, Human),
    hosting_node(Node), agent_hosted(personal, Node, _, Key),
    \+ agent_hosting_suspended(personal).

%% Signature verification supplies data only. The committed human key and
%% current hosting/signing policy provide authority, including revocation.
personal_instruction_authorized(UBytes, USignature, Typed, Owner, UKey) :-
    signed_agent_request(UBytes, USignature,
        agent_goal_v1(Network, Owner, _, UKey, _, Expiry, read, 3, Text)),
    Owner = agent_instance_ref(_, _, Human), instance_of(human_user, Human),
    agent_key(Human, UKey, active),
    '$quod_program_source'([personal_instruction_accept(Bytes, _)], Text),
    agent_request_bytes(Typed, Bytes),
    Typed = agent_goal_v1(Network, _, _, _, _, TargetExpiry, execute, 3, _),
    TargetExpiry =< Expiry,
    can_instruct_personal_agent(Owner, Typed).

can_invoke((agent_hosted(personal, Node, Epoch, Key), sign_agent_request(_, _)), Node, _, _) :-
    hosting_node(Node), agent_hosted(personal, Node, Epoch, Key).

can_sign_agent_request(Owner, Node, Typed) :-
    hosting_node(Node), can_instruct_personal_agent(Owner, Typed).

can_request_agent_signature(Node, personal,
    agent_goal_v1(Network, Actor, _, Key, _, Expiry, execute, 3, Text)) :-
    hosting_node(Node),
    '$quod_program_source'([retain_personal_instruction(UBytes, USignature, Signature)], Text),
    personal_instruction_authorized(UBytes, USignature, Requested, _, _),
    Requested = agent_goal_v1(Network, Actor, _, Key, _, Expiry, execute, 3, _),
    agent_request_bytes(Requested, Bytes),
    signed_agent_request(Bytes, Signature, Requested).

can_invoke(retain_personal_instruction(_, _, _), Actor, _, Ns) :-
    Actor = agent_instance_ref(Ns, _, personal).
can_invoke(personal_instruction_retained(_, _), Node, _, _) :- hosting_node(Node).
%% Custody verified these fields once. Match the goal before consulting current
%% authority; authorization never reparses or reverifies historical signatures.
can_invoke(Goal, Actor, _, Ns) :-
    Actor = agent_instance_ref(Ns, _, personal),
    variant_digest(Goal, Digest),
    personal_instruction(Owner, _, authority(UKey, Key, Digest), _, _, _, _),
    Owner = agent_instance_ref(_, _, Human), agent_key(Human, UKey, active),
    can_instruct_personal_agent(Owner,
        agent_goal_v1(_, Actor, _, Key, _, _, execute, 3, _)).

%% Only the authenticated association is stored here. Outcomes and returned
%% bindings remain in the original transaction/outcome owners. No reaction or
%% recovery selector dispatches these records.
retain_personal_instruction(UBytes, USignature, Signature) :-
    personal_instruction_authorized(UBytes, USignature, Typed, Owner, UKey),
    agent_request_bytes(Typed, Bytes),
    signed_agent_request(Bytes, Signature, Typed),
    Typed = agent_goal_v1(_, Actor, _, Key, Id, _, execute, 3, Text),
    '$quod_program_source'([Requested], Text), variant_digest(Requested, Digest),
    current_principal(Actor),
    transaction((\+ personal_instruction(_, Id, _, _, _, _, _),
                 assertz(personal_instruction(Owner, Id, authority(UKey, Key, Digest),
                                              UBytes, USignature, Bytes, Signature)))).

%% The hosted worker asks only after a definite refusal, while it still owns
%% the actor slot. An older association keeps the original operation uncertain.
personal_instruction_retained(Bytes, Retained) :-
    agent_request_bytes(agent_goal_v1(_, _, _, _, Id, _, execute, 3, _), Bytes),
    (personal_instruction(_, Id, _, _, _, _, _) -> Retained = true; Retained = false).

personal_instruction_lookup(Id, Bytes, Signature) :-
    current_principal(Owner), human_user_owner(Owner),
    (personal_instruction(Owner, Id, _, _, _, Bytes, Signature) -> true
    ; Bytes = none, Signature = none).

personal_instructions(Instructions) :-
    current_principal(Owner), human_user_owner(Owner),
    findall(instruction(Id, Bytes, Signature),
            personal_instruction(Owner, Id, _, _, _, Bytes, Signature), Instructions).

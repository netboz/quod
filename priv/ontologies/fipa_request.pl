%% Internal Request conversation transitions, composed with agent_instance.pl.
%% The containing ontology supplies its entry ACL, fipa_request_allowed/3 and
%% fipa_request_goal/3. This is not an ACL wire codec or an implicit grant.
%% A conversation is current domain state, not an asserted message history:
%% fipa_conversation(Instance, Id, Role, Peer, Action, State).

fipa_local_agent(Instance, agent_instance_ref(Namespace, Anchor, Instance)) :-
    current_ontology_identity(Namespace, Anchor).

%% A's waiting state and B's accepted request form one atomic transition.
%% Receiver identity is checked inside the selected scope, never by namespace
%% alone. The authenticated principal crosses :: unchanged.
fipa_request(Instance, Id, Receiver, Action) :-
    term_variables(request(Instance, Id, Receiver, Action), []),
    agent_identifier(Id),
    fipa_local_agent(Instance, Sender),
    current_principal(Sender),
    Receiver = agent_instance_ref(Namespace, Anchor, ReceiverInstance),
    transaction((
        \+ fipa_conversation(Instance, Id, _, _, _, _),
        assertz(fipa_conversation(Instance, Id, initiator, Receiver, Action, waiting)),
        Namespace::(current_ontology_identity(Namespace, Anchor),
                    fipa_receive_request(ReceiverInstance, Id, Action))
    )).

%% Permission to receive a request is domain policy. It is not permission to
%% execute arbitrary message content as a Prolog goal.
fipa_receive_request(Instance, Id, Action) :-
    term_variables(request(Instance, Id, Action), []),
    agent_identifier(Id),
    current_principal(Sender),
    fipa_request_allowed(Instance, Sender, Action),
    \+ fipa_conversation(Instance, Id, _, _, _, _),
    assertz(fipa_conversation(Instance, Id, participant, Sender, Action, pending)),
    trigger_event(fipa_request_received(Instance, Id, Sender, Action)).

%% The domain maps the requested action to a desired state; the existing goal/1
%% mechanism establishes it. B's consequence and A's inform-done acceptance
%% commit together. Failure at A rolls back B's staged consequence too.
fipa_fulfil_request(Instance, Id) :-
    term_variables(request(Instance, Id), []),
    fipa_local_agent(Instance, Receiver),
    current_principal(Receiver),
    fipa_conversation(Instance, Id, participant, Sender, Action, pending),
    fipa_request_goal(Instance, Action, DesiredState),
    term_variables(DesiredState, []),
    Sender = agent_instance_ref(Namespace, Anchor, SenderInstance),
    transaction((
        goal(DesiredState),
        retract(fipa_conversation(Instance, Id, participant, Sender, Action, pending)),
        assertz(fipa_conversation(Instance, Id, participant, Sender, Action, done)),
        Namespace::(current_ontology_identity(Namespace, Anchor),
                    fipa_receive_done(SenderInstance, Id, Action))
    )).

%% The peer and action must match the outstanding request. Receipt changes
%% current state and emits an occurrence; the occurrence is never asserted.
fipa_receive_done(Instance, Id, Action) :-
    term_variables(request(Instance, Id, Action), []),
    current_principal(Receiver),
    retract(fipa_conversation(Instance, Id, initiator, Receiver, Action, waiting)),
    assertz(fipa_conversation(Instance, Id, initiator, Receiver, Action, done)),
    trigger_event(fipa_request_completed(Instance, Id, Receiver, Action)).

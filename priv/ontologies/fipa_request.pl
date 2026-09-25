%% Internal Request conversation transitions, composed with agent_instance.pl.
%% The containing ontology supplies its entry ACL, fipa_request_allowed/3 and
%% fipa_request_goal/3. This is not an ACL wire codec or an implicit grant.
%% Automatic continuation additionally pins quod_agent_work_predicates at founding.
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

%% Automatic continuation requires explicit policy from the containing ontology:
%% fipa_request_continuation(Instance, BudgetMs), entry ACL and signing grants.
%% These rules explicitly allow a distinct attempt despite an earlier unknown
%% outcome; the shared pending-state transaction guard permits one completion.

state_handler(fipa_pending_requests,
              [fipa_conversation/6, fipa_request_continuation/2],
              [current(agent_hosting)], reconcile_fipa_pending_requests).

reconcile_fipa_pending_requests(Changed) :-
    fipa_pending_scope(Changed, Instances, Wake),
    fipa_project_pending(Instances, Wake).

fipa_project_pending([], _).
fipa_project_pending([Instance|Instances], Wake) :-
    (fipa_request_continuation(Instance, Budget) ->
        project_next_agent_goal(Instance, Wake, fipa_pending_step(Instance), Budget)
    ; true),
    fipa_project_pending(Instances, Wake).

fipa_pending_scope(agent_work(Instance), [Instance], continue) :- !.
fipa_pending_scope(keys(Heads), Instances, changed) :-
    findall(I, (member(Head, Heads), fipa_pending_head(Head, I)), Changed),
    term_variables(Changed, []), !,
    sort(Changed, Instances).
fipa_pending_scope(_, Instances, changed) :-
    findall(I, fipa_request_continuation(I, _), Enabled),
    sort(Enabled, Instances).

fipa_pending_head(fipa_conversation(I, _, _, _, _, _), I).
fipa_pending_head(fipa_request_continuation(I, _), I).
fipa_pending_head(agent_host(I, _, _, _), I).
fipa_pending_head(agent_key(I, _, _), I).

fipa_pending_step(Instance, Cursor, Id, fipa_fulfil_request(Instance, Id)) :-
    findall(Key, (fipa_conversation(Instance, Key, participant, _, _, pending),
                  agent_work_after(Cursor, Key)), Keys),
    sort(Keys, [Id|_]).

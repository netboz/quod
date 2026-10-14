%% Current question state, composed into the responsible actor's ontology.
%% Opening supplies an accepted row and the human's HUD reference atomically.
%% These rules do not create questions or establish presentation acceptance.
%% gui_question(Id, form_ref(Ns, Anchor, Form), Human, Actor, Revision, State).

no_follow(gui_submit/4).
no_follow(gui_complete/1).
no_follow(gui_consume/1).
no_follow(gui_cancel/1).
no_follow(gui_answer/6).
no_follow(gui_question_view/4).
no_follow(gui_question_form/2).
no_follow(gui_retirement/2).
no_follow(gui_question_entry/3).
no_follow(gui_consumption_entry/4).
no_follow(gui_question/6).
no_follow(gui_question_reference/2).
no_follow(gui_question_actor/2).
no_follow(gui_remove_hud/2).
no_follow(gui_retiring/2).
no_follow(gui_completion_request/4).
no_follow(gui_visible_state/2).
no_follow(gui_cancelable/1).
no_follow(gui_question_status/2).

instance_of(quod:gui:question, Q) :- gui_question(Q, _, _, _, _, _).

%% Entry grants use committed local state. They never query another ontology
%% or consult a process while a validator checks authorization.
can_invoke(Goal, Principal, _, Ns) :- gui_question_entry(Goal, Principal, Ns).
can_invoke(Goal, Principal, Chain, Ns) :- gui_consumption_entry(Goal, Principal, Chain, Ns).
gui_consumption_entry((current_ontology_identity(_, _), Goal), Principal, Chain, Ns) :-
    gui_consumption_entry(Goal, Principal, Chain, Ns).
gui_consumption_entry(gui_consume(Q), agent_instance_ref(Ns, _, Actor), [SourceNs|_], Ns) :-
    SourceNs \= Ns,
    gui_question(Q, form_ref(SourceNs, _, _), _, Actor, _, submitted(_, _, _, _)).
gui_question_entry((current_ontology_identity(_, _), Goal), Principal, Ns) :-
    gui_question_entry(Goal, Principal, Ns).
gui_question_entry(gui_submit(Q, _, _, _), Human, _) :-
    gui_question(Q, _, Human, _, _, awaiting).
gui_question_entry(gui_cancel(Q), Human, _) :-
    gui_question(Q, _, Human, _, _, _).
gui_question_entry(gui_question_status(Q, _), Human, _) :-
    gui_question(Q, _, Human, _, _, _).
gui_question_entry(gui_question_view(Q, _, _, _), Human, _) :-
    gui_question(Q, _, Human, _, _, _).
gui_question_entry(gui_question_form(Q, _), Human, _) :-
    gui_question(Q, _, Human, _, _, _).
gui_question_entry(gui_complete(Q), agent_instance_ref(Ns, _, Actor), Ns) :-
    gui_question(Q, _, _, Actor, _, submitted(_, _, _, _)).
gui_question_entry(gui_answer(Q, _, _, _, _, _), agent_instance_ref(Ns, _, Actor), Ns) :-
    gui_question(Q, _, _, Actor, _, submitted(_, _, _, _)).
gui_question_entry(gui_retirement(Q, Human), Human, _) :-
    gui_question(Q, _, Human, _, _, _).
gui_question_entry(gui_retirement(Q, Human), agent_instance_ref(Ns, _, Actor), Ns) :-
    gui_question(Q, _, Human, Actor, _, submitted(_, _, _, _)).

gui_question_reference(Q, question_ref(Ns, Anchor, Q)) :-
    current_ontology_identity(Ns, Anchor).

gui_question_actor(Actor, agent_instance_ref(Ns, Anchor, Actor)) :-
    current_ontology_identity(Ns, Anchor).

%% A HUD reads the authoritative row under its human's identity. The source
%% reference and revision let any client obtain the ordinary component view;
%% accepted fields are returned only to the human who supplied them.
gui_question_view(Q, Source, Revision, State) :-
    term_variables(Q, []), current_principal(Human),
    gui_question(Q, Source, Human, _, Revision, Stored),
    gui_visible_state(Stored, State).

%% Reading a selected form follows its exact source under the human's identity.
%% Keep the accepted revision separate from the current form revision so clients
%% cannot silently apply a draft to a changed schema.
gui_question_form(Q, question_form(Source, Responsible, Revision, State, View)) :-
    term_variables(Q, []), current_principal(Human),
    gui_question(Q, Source, Human, Actor, Revision, Stored),
    gui_visible_state(Stored, State),
    gui_question_actor(Actor, Responsible),
    Source = form_ref(Ns, Anchor, Form),
    Ns::(current_ontology_identity(Ns, Anchor),
         gui_form_projection(Form, Human, Responsible, View)).

%% The submitted operation is authenticated context, never a client sequence.
%% Invalid values and source-policy changes leave the entire row unchanged.
gui_submit(Q, Revision, Control, Fields) :-
    term_variables([Q, Revision, Control, Fields], []),
    transaction((
        current_principal(Human), current_request_operation(Submission),
        gui_question(Q, Source, Human, Actor, Revision, awaiting),
        Source = form_ref(Ns, Anchor, Form),
        gui_question_actor(Actor, Responsible),
        Ns::(current_ontology_identity(Ns, Anchor),
             gui_validate_submission(Form, Human, Responsible, Revision, Control, Fields)),
        gui_completion_request(Q, Submission, Actor, Bytes),
        retract(gui_question(Q, Source, Human, Actor, Revision, awaiting)),
        assertz(gui_question(Q, Source, Human, Actor, Revision,
                             submitted(Submission, Control, Fields, Bytes))))).

%% This read grants no continuation from an event payload. The originating
%% application retrieves the exact accepted fields under the actor's identity.
gui_answer(Q, Source, Human, Revision, Control, Fields) :-
    term_variables(Q, []),
    gui_question(Q, Source, Human, Actor, Revision, submitted(_, Control, Fields, _)),
    gui_question_actor(Actor, Responsible), current_principal(Responsible).

gui_complete(Q) :-
    term_variables(Q, []),
    transaction((
        gui_question(Q, form_ref(Ns, Anchor, _), _, Actor, _, submitted(_, _, _, Bytes)),
        current_signed_request(Bytes),
        gui_question_actor(Actor, Responsible), current_principal(Responsible),
        gui_question_reference(Q, Reference),
        Ns::(current_ontology_identity(Ns, Anchor), gui_continue(Reference)))).

gui_consume(Q) :-
    term_variables(Q, []),
    transaction((
        gui_question(Q, Source, Human, Actor, Revision, Submitted),
        Submitted = submitted(_, _, _, Bytes),
        current_signed_request(Bytes),
        gui_question_actor(Actor, Responsible), current_principal(Responsible),
        gui_question_reference(Q, Reference),
        Source = form_ref(SourceNs, SourceAnchor, _),
        SourceNs::(current_ontology_identity(SourceNs, SourceAnchor),
                   gui_application_active(Reference)),
        assertz(gui_retiring(Q, Human)),
        gui_remove_hud(Human, Reference),
        retract(gui_question(Q, Source, Human, Actor, Revision, Submitted)),
        retract(gui_retiring(Q, Human)))).

gui_cancel(Q) :-
    term_variables(Q, []),
    transaction((
        current_principal(Human),
        gui_question(Q, Source, Human, Actor, Revision, State),
        gui_cancelable(State),
        gui_question_reference(Q, Reference),
        assertz(gui_retiring(Q, Human)),
        gui_remove_hud(Human, Reference),
        retract(gui_question(Q, Source, Human, Actor, Revision, State)),
        retract(gui_retiring(Q, Human)))).

gui_remove_hud(agent_instance_ref(Ns, Anchor, Instance), Reference) :-
    Ns::(current_ontology_identity(Ns, Anchor), gui_unlink(Instance, Reference)).

gui_retirement(Q, Human) :-
    gui_retiring(Q, Human),
    current_principal(Principal),
    (gui_question(Q, _, Human, _, _, _), Principal = Human
    ; gui_question(Q, _, Human, Actor, _, submitted(_, _, _, _)),
      gui_question_actor(Actor, Principal)).

%% Completion allowance is authored once for the responsible actor. Ambiguous
%% keys or policy refuse submission before any question state is replaced.
gui_completion_request(Q, Submission, Actor, Bytes) :-
    findall(K, agent_key(Actor, K, active), [Key]),
    findall(Ms, gui_completion_allowance(Actor, Ms), [Allowance]),
    integer(Allowance), Allowance > 0,
    current_request_expiry(SubmissionExpiry), Expiry is SubmissionExpiry + Allowance,
    gui_question_reference(Q, Reference),
    term_digest(gui_completion(Reference, Submission), Operation),
    gui_question_actor(Actor, Responsible),
    <<"quod:root">>::(current_ontology_identity(<<"quod:root">>, Network),
                       acl_sovereign(quod:root)),
    '$quod_program_source'([Actor], InstanceText),
    '$quod_program_source'([gui_complete(Q)], GoalText),
    agent_request_bytes(agent_goal_v1(Network, Responsible, InstanceText, Key,
                                     Operation, Expiry, execute, 3, GoalText), Bytes).

%% Only a real committed local assertion schedules the retained request. The
%% existing event owner suppresses duplicate source delivery; replay is inert.
react_on(assert(gui_question(Q, Source, Human, Actor, Revision, Submitted)), gui_complete(Q)) :-
    Submitted = submitted(_, _, _, Bytes),
    me(agent_instance_ref(_, _, Actor)),
    gui_question(Q, Source, Human, Actor, Revision, Submitted),
    use_agent_request(Bytes).

gui_visible_state(awaiting, awaiting).
gui_visible_state(submitted(Submission, Control, Fields, _), submitted(Submission, Control, Fields)).

gui_question_status(Q, Status) :-
    term_variables(Q, []), current_principal(Human),
    gui_question(Q, _, Human, _, _, State),
    (State = awaiting -> Status = awaiting
    ; State = submitted(_, _, _, Bytes), committed_operation_outcome(Bytes, Status)).

gui_cancelable(awaiting).
gui_cancelable(submitted(_, _, _, Bytes)) :-
    committed_operation_outcome(Bytes, Status), member(Status, [rejected, aborted, expired]).

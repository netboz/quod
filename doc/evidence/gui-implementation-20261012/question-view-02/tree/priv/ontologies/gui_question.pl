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

instance_of(quod:gui:question, Q) :- gui_question(Q, _, _, _, _, _).

%% Entry grants use committed local state. They never query another ontology
%% or consult a process while a validator checks authorization.
can_invoke(Goal, Principal, _, Ns) :- gui_question_entry(Goal, Principal, Ns).
can_invoke(Goal, Principal, Chain, Ns) :- gui_consumption_entry(Goal, Principal, Chain, Ns).
gui_consumption_entry((current_ontology_identity(_, _), Goal), Principal, Chain, Ns) :-
    gui_consumption_entry(Goal, Principal, Chain, Ns).
gui_consumption_entry(gui_consume(Q), agent_instance_ref(Ns, _, Actor), [SourceNs|_], Ns) :-
    SourceNs \= Ns,
    gui_question(Q, form_ref(SourceNs, _, _), _, Actor, _, submitted(_, _, _)).
gui_question_entry((current_ontology_identity(_, _), Goal), Principal, Ns) :-
    gui_question_entry(Goal, Principal, Ns).
gui_question_entry(gui_submit(Q, _, _, _), Human, _) :-
    gui_question(Q, _, Human, _, _, awaiting).
gui_question_entry(gui_cancel(Q), Human, _) :-
    gui_question(Q, _, Human, _, _, awaiting).
gui_question_entry(gui_question_view(Q, _, _, _), Human, _) :-
    gui_question(Q, _, Human, _, _, _).
gui_question_entry(gui_question_form(Q, _), Human, _) :-
    gui_question(Q, _, Human, _, _, _).
gui_question_entry(gui_complete(Q), agent_instance_ref(Ns, _, Actor), Ns) :-
    gui_question(Q, _, _, Actor, _, submitted(_, _, _)).
gui_question_entry(gui_answer(Q, _, _, _, _, _), agent_instance_ref(Ns, _, Actor), Ns) :-
    gui_question(Q, _, _, Actor, _, submitted(_, _, _)).
gui_question_entry(gui_retirement(Q, Human), Human, _) :-
    gui_question(Q, _, Human, _, _, awaiting).
gui_question_entry(gui_retirement(Q, Human), agent_instance_ref(Ns, _, Actor), Ns) :-
    gui_question(Q, _, Human, Actor, _, submitted(_, _, _)).

gui_question_reference(Q, question_ref(Ns, Anchor, Q)) :-
    current_ontology_identity(Ns, Anchor).

gui_question_actor(Actor, agent_instance_ref(Ns, Anchor, Actor)) :-
    current_ontology_identity(Ns, Anchor).

%% A HUD reads the authoritative row under its human's identity. The source
%% reference and revision let any client obtain the ordinary component view;
%% accepted fields are returned only to the human who supplied them.
gui_question_view(Q, Source, Revision, State) :-
    term_variables(Q, []), current_principal(Human),
    gui_question(Q, Source, Human, _, Revision, State).

%% Reading a selected form follows its exact source under the human's identity.
%% Keep the accepted revision separate from the current form revision so clients
%% cannot silently apply a draft to a changed schema.
gui_question_form(Q, question_form(Source, Responsible, Revision, State, View)) :-
    term_variables(Q, []), current_principal(Human),
    gui_question(Q, Source, Human, Actor, Revision, State),
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
        retract(gui_question(Q, Source, Human, Actor, Revision, awaiting)),
        assertz(gui_question(Q, Source, Human, Actor, Revision,
                             submitted(Submission, Control, Fields))),
        trigger_event(gui_submitted(Q, Submission)))).

%% This read grants no continuation from an event payload. The originating
%% application retrieves the exact accepted fields under the actor's identity.
gui_answer(Q, Source, Human, Revision, Control, Fields) :-
    term_variables(Q, []),
    gui_question(Q, Source, Human, Actor, Revision, submitted(_, Control, Fields)),
    gui_question_actor(Actor, Responsible), current_principal(Responsible).

gui_complete(Q) :-
    term_variables(Q, []),
    transaction((
        gui_question(Q, form_ref(Ns, Anchor, _), _, Actor, _, submitted(_, _, _)),
        gui_question_actor(Actor, Responsible), current_principal(Responsible),
        gui_question_reference(Q, Reference),
        Ns::(current_ontology_identity(Ns, Anchor), gui_continue(Reference)))).

gui_consume(Q) :-
    term_variables(Q, []),
    transaction((
        gui_question(Q, Source, Human, Actor, Revision, Submitted),
        Submitted = submitted(_, _, _),
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
        gui_question(Q, Source, Human, Actor, Revision, awaiting),
        gui_question_reference(Q, Reference),
        assertz(gui_retiring(Q, Human)),
        gui_remove_hud(Human, Reference),
        retract(gui_question(Q, Source, Human, Actor, Revision, awaiting)),
        retract(gui_retiring(Q, Human)))).

gui_remove_hud(agent_instance_ref(Ns, Anchor, Instance), Reference) :-
    Ns::(current_ontology_identity(Ns, Anchor), gui_unlink(Instance, Reference)).

gui_retirement(Q, Human) :-
    gui_retiring(Q, Human),
    current_principal(Principal),
    (gui_question(Q, _, Human, _, _, awaiting), Principal = Human
    ; gui_question(Q, _, Human, Actor, _, submitted(_, _, _)),
      gui_question_actor(Actor, Principal)).

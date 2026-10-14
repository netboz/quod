%% A human's HUD stores references only. Status and accepted fields stay in
%% the responsible ontology. Compose with the human's ordinary identity rules.
no_follow(gui_unlink/2).
no_follow(gui_hud_entry/4).
no_follow(gui_pending/2).
no_follow(gui_pending_questions/1).
no_follow(gui_select_receiver/3).
no_follow(gui_selected_receiver/3).
no_follow(gui_receiver_for/2).
no_follow(gui_forget_receivers/1).

can_invoke(Goal, Principal, Chain, Ns) :- gui_hud_entry(Goal, Principal, Chain, Ns).
gui_hud_entry((current_ontology_identity(_, _), Goal), Principal, Chain, Ns) :-
    gui_hud_entry(Goal, Principal, Chain, Ns).
gui_hud_entry(gui_pending_questions(_), agent_instance_ref(Ns, _, Instance), _, Ns) :-
    instance_of(human_user, Instance).
gui_hud_entry(gui_select_receiver(Instance, _, _), agent_instance_ref(Ns, _, Instance), _, Ns) :-
    instance_of(human_user, Instance).
gui_hud_entry(gui_receiver_for(Instance, _), Principal, _, Ns) :-
    instance_of(human_user, Instance),
    (Principal = agent_instance_ref(Ns, _, Instance); gui_receiver_policy(Instance, Principal)).
gui_hud_entry(gui_unlink(Instance, question_ref(Ns, Anchor, Q)), _, [Ns|_], _) :-
    instance_of(human_user, Instance),
    gui_pending(Instance, question_ref(Ns, Anchor, Q)).

%% Discovery returns references from the authenticated human's own ontology.
%% It neither scans applications nor copies their status or accepted answers.
gui_pending_questions(References) :-
    current_ontology_identity(Ns, Anchor),
    current_principal(agent_instance_ref(Ns, Anchor, Instance)),
    instance_of(human_user, Instance),
    findall(Reference, gui_pending(Instance, Reference), Pending),
    sort(Pending, References).

%% The human chooses one receiving scope, including when several tabs exist.
%% This durable route is never treated as evidence that a client is still live.
gui_select_receiver(Instance, Node, Token) :-
    term_variables([Instance, Node, Token], []),
    current_ontology_identity(Ns, Anchor),
    current_principal(agent_instance_ref(Ns, Anchor, Instance)),
    instance_of(human_user, Instance),
    binary_codes(Node, NodeBytes), length(NodeBytes, 32),
    binary_codes(Token, TokenBytes), length(TokenBytes, 32),
    transaction((
        findall(gui_selected_receiver(Instance, N, T), gui_selected_receiver(Instance, N, T), Previous),
        (Previous = [gui_selected_receiver(Instance, Node, Token)] -> true
        ; gui_forget_receivers(Previous), assertz(gui_selected_receiver(Instance, Node, Token))))).

gui_forget_receivers([]).
gui_forget_receivers([Row|Rows]) :- retract(Row), gui_forget_receivers(Rows).

gui_receiver_for(Instance, receiver(Node, Token)) :-
    term_variables(Instance, []), instance_of(human_user, Instance),
    current_ontology_identity(Ns, Anchor), current_principal(Principal),
    (Principal = agent_instance_ref(Ns, Anchor, Instance); gui_receiver_policy(Instance, Principal)),
    findall(receiver(N, T), gui_selected_receiver(Instance, N, T), [receiver(Node, Token)]).

%% The exact responder must authorize retirement from its still-current row.
%% Call-chain admission restricts this mutation to the responder's shared
%% completion/cancellation transition, whose outer transaction owns rollback.
gui_unlink(Instance, Reference) :-
    term_variables([Instance, Reference], []),
    instance_of(human_user, Instance),
    current_ontology_identity(HumanNs, HumanAnchor),
    Human = agent_instance_ref(HumanNs, HumanAnchor, Instance),
    Reference = question_ref(Ns, Anchor, Q),
    Ns::(current_ontology_identity(Ns, Anchor), gui_retirement(Q, Human)),
    retract(gui_pending(Instance, Reference)).

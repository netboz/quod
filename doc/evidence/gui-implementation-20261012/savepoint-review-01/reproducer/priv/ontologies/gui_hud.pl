%% A human's HUD stores references only. Status and accepted fields stay in
%% the responsible ontology. Compose with the human's ordinary identity rules.
no_follow(gui_unlink/2).
no_follow(gui_hud_entry/3).

can_invoke(Goal, Principal, Chain, _) :- gui_hud_entry(Goal, Principal, Chain).
gui_hud_entry((current_ontology_identity(_, _), Goal), Principal, Chain) :-
    gui_hud_entry(Goal, Principal, Chain).
gui_hud_entry(gui_unlink(Instance, question_ref(Ns, Anchor, Q)), _, [Ns|_]) :-
    instance_of(human_user, Instance),
    gui_pending(Instance, question_ref(Ns, Anchor, Q)).

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

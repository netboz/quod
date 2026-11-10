%% Application ACL and the hosted actor's reaction. Question transitions and
%% presentation behavior live at quod:gui; application forms stay with their class.
can_invoke(_, Caller, [<<"quod:gui">>|_], Ns) :-
    gui_question(_, _, Human, Actor, _, _),
    (Caller = Human; Caller = agent_instance_ref(Ns, _, Actor)).
can_invoke(_, Node, [Owner|_], _) :-
    member(Owner, [<<"quod:gui">>, <<"quod:agent">>]),
    agent_host(Actor, Node, _, _), agent_hosted(Actor, Node, _, _).
can_invoke(_, Caller, [<<"quod:gui">>|_], _) :-
    gui_question_policy(_, Human, Actor), (Caller = Human; Caller = Actor).
can_invoke(_, Caller, [<<"quod:gui">>|_], Ns) :-
    gui_responder_policy(Instance, _, Human),
    (Caller = Human; Caller = agent_instance_ref(Ns, _, Instance)).
can_invoke(<<"quod:gui">>::gui_open(form_ref(Ns, _, Form), _), Caller, _, Ns) :-
    gui_question_policy(Form, Human, Actor), (Caller = Human; Caller = Actor).
can_invoke(<<"quod:gui">>::gui_complete(question_ref(Ns, Anchor, Q)),
           agent_instance_ref(Ns, Anchor, Actor), _, Ns) :-
    gui_question(Q, _, _, Actor, _, submitted(_, _, _, _)).
can_invoke(Goal, Caller, _, Ns) :-
    Read = <<"quod:gui">>::gui_native_handler(agent_instance_ref(Ns, _, Instance), Source, Human, _, _),
    member(Goal, [Read, (current_ontology_identity(Ns, _), Read)]),
    gui_responder_policy(Instance, Source, Human),
    (Caller = Human; Caller = agent_instance_ref(Ns, _, Instance)).
can_invoke(Goal, Human, _, Ns) :-
    gui_question(Q, _, Human, _, _, _), Reference = question_ref(Ns, _, Q),
    member(Query, [gui_submit(Reference, _, _, _), gui_cancel(Reference),
                   gui_question_status(Reference, _), gui_question_view(Reference, _, _, _),
                   gui_question_form(Reference, _)]),
    Read = <<"quod:gui">>::Query,
    member(Goal, [Read, (current_ontology_identity(Ns, _), Read)]).
can_invoke(Goal, Node, _, Ns) :-
    Typed = agent_goal_v1(_, agent_instance_ref(Ns, _, Actor), _, Key, _, _, execute, 3, _),
    agent_hosted(Actor, Node, Epoch, Key),
    Read = (agent_hosted(Actor, Node, Epoch, Key), sign_agent_request(Typed, _)),
    member(Goal, [Read, (current_ontology_identity(Ns, _), Read)]).


can_request_agent_signature(Node, Actor, Typed) :-
    current_ontology_identity(Ns, Anchor),
    <<"quod:gui">>::gui_completion_signing(Node, agent_instance_ref(Ns, Anchor, Actor), Typed).

%% Only a matching committed local assertion schedules these retained bytes.
%% The existing event owner suppresses duplicates and never replays this work.
react_on(assert(gui_question(Q, Source, Human, Actor, Revision, Submitted)),
         <<"quod:gui">>::gui_complete(question_ref(Ns, Anchor, Q))) :-
    Submitted = submitted(_, _, _, Bytes),
    me(agent_instance_ref(Ns, Anchor, Actor)),
    gui_question(Q, Source, Human, Actor, Revision, Submitted),
    use_agent_request(Bytes).

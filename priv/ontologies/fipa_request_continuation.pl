%% Optional founding policy for transactionally guarded Request continuation.
%% Compose with agent_instance.pl and fipa_request.pl. The ontology must supply
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

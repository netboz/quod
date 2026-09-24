state_handler(test_work, [work_pending/1], [current(agent_hosting)], reconcile_test_work).

reconcile_test_work(agent_work(actor)) :- !, schedule_test_work(continue).
reconcile_test_work(_) :- schedule_test_work(changed).

schedule_test_work(Wake) :-
    project_next_agent_goal(actor, Wake, test_work_step, 5000),
    test_work_status.

test_work_step(Cursor, Key, finish_work(Key)) :-
    findall(K, (work_pending(K), agent_work_after(Cursor, K)), Keys),
    sort(Keys, [Key|_]).

finish_work(Key) :-
    transaction((
        work_pending(Key),
        \+ work_rejected(Key),
        retract(work_pending(Key)),
        assertz(work_done(Key))
    )).

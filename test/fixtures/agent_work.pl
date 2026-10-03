agent_work_goal(actor, Cursor, Key, finish_work(Key), 5000) :-
    findall(K, (work_pending(K), agent_work_after(Cursor, K)), Keys),
    sort(Keys, [Key|_]).

finish_work(Key) :-
    transaction((
        work_pending(Key),
        \+ work_rejected(Key),
        retract(work_pending(Key)),
        assertz(work_done(Key))
    )).

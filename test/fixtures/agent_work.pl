agent_work_goal(actor, Cursor, Key, finish_work(Key), 5000) :-
    findall(K, (work_pending(K), (Cursor = start ; Cursor = after(Previous), K @> Previous)), Keys),
    sort(Keys, [Key|_]).

finish_work(Key) :-
    transaction((
        work_pending(Key),
        \+ work_rejected(Key),
        retract(work_pending(Key)),
        assertz(work_done(Key))
    )).

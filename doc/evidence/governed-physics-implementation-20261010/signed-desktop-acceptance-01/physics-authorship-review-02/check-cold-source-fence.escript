#!/usr/bin/env escript
%%! +S 4:4
-mode(compile).
-include("/home/yan/src/quod/_build/test/lib/erlog/src/erlog_int.hrl").
main([]) ->
    lists:foreach(fun code:add_patha/1,
        filelib:wildcard("/home/yan/src/quod/_build/test/lib/*/ebin")),
    true = code:add_patha("/home/yan/src/quod/_build/test/lib/quod/test"),
    Committed = quod_ct:commit_kb(quod_committed_projection:new_est()),
    St = quod_erlog_db_local_prove:wrap_state(Committed, #{read_set => true}),
    Cold = <<"cold_guard_", (binary:encode_hex(crypto:strong_rand_bytes(8)))/binary>>,
    {'EXIT', _} = (catch binary_to_existing_atom(Cold, utf8)),
    Goal = {'$quod_predicate_source', {'/', {'$quod_symbol', Cold}, 3}, <<>>},
    {succeed, #est{db = #db{ref = Ref}}} = erlog_int:prove_goal(Goal, St),
    Reads = quod_erlog_db_local_prove:get_read_set(Ref),
    io:format("~p~n", [#{guard_succeeded => true, reads => maps:keys(Reads),
                         cold_name_became_atom => is_atom(catch binary_to_existing_atom(Cold, utf8))}]),
    quod_erlog_db_local_prove:cleanup_read_set(St),
    #est{db = #db{ref = CommittedRef}} = Committed,
    quod_erlog_db_mvcc:delete(CommittedRef).

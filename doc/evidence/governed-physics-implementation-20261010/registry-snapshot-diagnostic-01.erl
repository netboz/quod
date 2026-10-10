#!/usr/bin/env escript
%%! -pa _build/test/lib/quod/ebin
main(_) ->
    Old = quod_erlog_db_mvcc:publish_base(quod_erlog_db_mvcc:new([])),
    Functor = {capability_snapshot_diagnostic, 0},
    try
        undefined = quod_erlog_db_mvcc:get_procedure(Old, Functor),
        Current = quod_erlog_db_mvcc:commit(Old, 1, 0),
        {ok, _} = quod_erlog_db_mvcc:add_compiled_proc(
                    Current, Functor, quod_predicates, dispatch),
        {code, {quod_predicates, dispatch}} =
            quod_erlog_db_mvcc:get_procedure(Old, Functor),
        io:format("A compiled registration at height 1 is visible through the retained height-0 handle.~n")
    after quod_erlog_db_mvcc:delete(Old) end.

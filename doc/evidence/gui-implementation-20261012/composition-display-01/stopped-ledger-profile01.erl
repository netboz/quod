-module('stopped-ledger-profile').
-export([run/0]).
run() ->
    Base = "/tmp/quod-gui-examples-A9A1FE2896D03645516F4F46",
    Scopes = [{<<"lobby-test-user">>,"lobby-test-user"},
              {<<"lobby-test-personal">>,"lobby-test-personal"},
              {<<"gui:examples-responder">>,"responder"},
              {<<"gui:examples-instrument">>,"instrument"},
              {<<"quod:gui">>,"quod:gui"}],
    lists:foreach(fun({Ns, Sub}) ->
        {ok, Store} = quod_ledger_store:open_ro(Ns, filename:join(Base, Sub)),
        try
            Rows = quod_ledger_store:fold(Store, 1, quod_ledger_store:last(Store),
                fun(Entry, Acc) ->
                    Block = quod_explorer_http:block_json(Ns, Entry),
                    Acc ++ [maps:merge(maps:with([slot,time], Block),
                             maps:with([kind,group_id,vote,verdict,reasons,vote_deadline_ms], Control))
                            || Control <- maps:get(controls,Block,[])]
                end, []),
            io:format("STOPPED_LEDGER ~p ~p~n", [Ns,Rows])
        after quod_ledger_store:close(Store) end
    end, Scopes).

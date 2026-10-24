#!/usr/bin/env escript
%%! +S 4:4 -pa _build/test/lib/quod/ebin _build/test/lib/erlog/ebin
-mode(compile).
-include("../../../include/quod_ledger.hrl").
main([Dir]) ->
    code:add_paths(filelib:wildcard("_build/test/lib/*/ebin")),
    ok = application:load(quod),
    {ok, Modules} = application:get_key(quod, modules),
    ok = code:ensure_modules_loaded(Modules),
    {ok, Store} = quod_ledger_store:open_ro(<<"quod:names">>, Dir, wrapped),
    try
        {ok, Entries} = quod_ledger_store:read_range(Store, 2, quod_ledger_store:last(Store), all),
        lists:foreach(fun(Entry) ->
            #entry{index = I, data = Payload} = quod_ledger:entry_view(Entry),
            io:format("~p ~p~n", [I, summarize(Payload)])
        end, Entries)
    after quod_ledger_store:close(Store)
    end.
summarize({batch, Items}) -> [summarize(Item) || Item <- Items];
summarize(#transaction{diff = Diff}) -> {transaction, length(Diff)};
summarize({dtx, Control}) ->
    {dtx, quod_atomic:control_kind(Control)};
summarize(Term) when is_tuple(Term) -> {tuple, element(1, Term), tuple_size(Term)};
summarize(Term) -> Term.

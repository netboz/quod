-module(quod_observation).
-moduledoc """
Worker-local collection of interpreter and committed-database observations.

The consumer classifies each observation as compact dependency keys. The
collector neither decides invalidation nor changes proof semantics. Reads
survive failure, cuts and rollback; the private table dies on every exit.
""".
-include_lib("erlog/src/erlog_int.hrl").
-export([capture/3, note/2]).

-spec capture(tuple(), fun((term()) -> [term()]), fun((tuple()) -> T)) ->
          {T, #{term() => true}}.
capture(Est = #est{db = Db = #db{mod = quod_erlog_db_mvcc, ref = Ref}},
        Classify, Evaluate) ->
    Observations = ets:new(quod_observations, [set, private]),
    Sink = fun(Event) ->
        true = ets:insert(Observations, [{Key} || Key <- Classify(Event)]), ok
    end,
    Observed = erlog_int:set_observation_sink(Sink,
                 Est#est{db = Db#db{ref = quod_erlog_db_mvcc:observe(Sink, Ref)}}),
    try
        Result = Evaluate(Observed),
        {Result, maps:from_list([{Key, true} || {Key} <- ets:tab2list(Observations)])}
    after ets:delete(Observations) end.

-doc "Record an input at its existing read boundary without retaining its value.".
-spec note(term(), tuple()) -> ok.
note(_, #est{observation_sink = none}) -> ok;
note(Event, #est{observation_sink = Sink}) -> ok = Sink(Event).

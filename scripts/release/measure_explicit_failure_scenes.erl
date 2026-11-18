-module(measure_explicit_failure_scenes).
-export([run/2, run/4, contract/0]).
-include("erlog_int.hrl").

%% The retained host API reserves this atom. Pin the actual behavior rather
%% than promising ordinary duplicate-preservation for its special marker.
contract() ->
    {ok, St0} = erlog_int:new(erlog_db_dict, null),
    St = St0#est{db=erlog_bips:load(St0#est.db)},
    Repeated = fun(Reason) ->
        {';', {fail_with_reason, Reason},
         {';', {fail_with_reason, Reason}, {get_fail_reasons, {'Reasons'}}}}
    end,
    {succeed, Marked} = erlog_int:prove_goal(Repeated(fail_reasons_truncated), St),
    [fail_reasons_truncated] = Marked#est.fail_reasons,
    true = Marked#est.fail_reasons_truncated,
    {succeed, Ordinary} = erlog_int:prove_goal(Repeated(stated_reason), St),
    [stated_reason,stated_reason] = Ordinary#est.fail_reasons,
    {ok, Merged} = erlog_int:merge_failure_reasons(
        [fail_reasons_truncated,fail_reasons_truncated], St),
    [fail_reasons_truncated] = Merged#est.fail_reasons,
    io:format("CONTRACT ordinary_duplicates=preserved reserved_marker=once remote_marker=once~n"),
    ok.

%% One fresh VM/process per case. Match the rendering test's scene and real
%% committed-MVCC/local-proof seam. Keep the full result alive while sampling.
run(Count, Mode) -> run(Count, Mode, 1, timing).

run(Count, Mode, Repeats, Measurement) ->
    io:format("engine=~p otp=~p schedulers=~p~n",
              [code:which(erlog_int), erlang:system_info(otp_release),
               erlang:system_info(schedulers_online)]),
    Base = quod_committed_projection:new_est(),
    #est{db=Db0} = Base,
    Db = lists:foldl(fun erlog_int:assertz_clause/2, Db0, quod_ct:gui_terms()),
    Committed = quod_ct:commit_kb(Base#est{db=Db}),
    St = quod_erlog_db_local_prove:wrap_state(Committed, #{read_set => true}),
    Marks = [box(integer_to_binary(N)) || N <- lists:seq(1, Count)],
    Input = case Mode of valid -> Marks; refused -> [hd(Marks)|Marks] end,
    case Measurement of
        allocation ->
            {ok, _} = tprof:start(#{type => call_memory}),
            tprof:set_pattern('_', '_', '_');
        timing -> ok
    end,
    try samples(1, Repeats, Count, Mode, Measurement, Input, St)
    after
        case Measurement of allocation -> tprof:stop(); timing -> ok end,
        erase(measured_result),
        #est{db=#db{ref=Ref}} = Committed,
        quod_erlog_db_mvcc:delete(Ref)
    end.

samples(N, Repeats, _Count, _Mode, _Measurement, _Input, _St) when N > Repeats -> ok;
samples(N, Repeats, Count, Mode, Measurement, Input, St) ->
    erase(measured_result),
    erlang:garbage_collect(),
    case Measurement of
        allocation -> tprof:restart(), tprof:enable_trace(self());
        timing -> ok
    end,
    {reductions, BeforeReductions} = process_info(self(), reductions),
    {Micros, Result} = timer:tc(erlog_int, prove_goal, [{well_formed_scene,Input}, St]),
    {reductions, AfterReductions} = process_info(self(), reductions),
    Allocations = case Measurement of
        allocation ->
            tprof:disable_trace(self()),
            {call_memory, Rows} = tprof:collect(),
            lists:sum([Words || {_,_,_,PerProcess} <- Rows,
                               {Pid,_,Words} <- PerProcess, Pid =:= self()]);
        timing -> unmeasured
    end,
    {Verdict, Final} = Result,
    Expected = case Mode of valid -> succeed; refused -> fail end,
    Expected = Verdict,
    %% Reachability through the dictionary prevents GC dropping the result.
    put(measured_result, Result),
    {memory, BeforeGC} = process_info(self(), memory),
    erlang:garbage_collect(),
    {memory, AfterGC} = process_info(self(), memory),
    io:format("SCENE ~s~n", [json:encode(#{marks => Count, mode => Mode,
        sample => N, measurement => Measurement, seconds => Micros/1000000,
        before_gc_bytes => BeforeGC, held_process_bytes => AfterGC,
        reductions => AfterReductions - BeforeReductions,
        allocated_words => Allocations, reasons => length(Final#est.fail_reasons)})]),
    samples(N+1, Repeats, Count, Mode, Measurement, Input, St).

box(Id) ->
    {mark, Id, <<"box">>,
     [{f, <<"width">>, 400}, {f, <<"height">>, 400}, {f, <<"depth">>, 400}],
     {transform, 0, 200, 0, 0, 0, 0},
     {surface, <<"#0B3954">>, 0, 900, 0, 1000, []},
     {label, <<"part">>, <<"above">>}, depicts_nothing}.

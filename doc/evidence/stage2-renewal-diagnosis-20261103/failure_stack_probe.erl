-module(failure_stack_probe).
-export([run/0]).
-include("erlog_int.hrl").
run() ->
    {module,erlog_int}=code:ensure_loaded(erlog_int),
    {module,quod_wire_term}=code:ensure_loaded(quod_wire_term),
    Rows=[measure(N,Policy)||Policy<-[native,{quod_wire_term,valid_failure_reason_stack}],N<-[64,128,256]],
    io:format("FAILURE_STACK_SCALING ~p~n",[Rows]),ok.
measure(N,Policy) ->
    {ok,St0}=erlog_int:new(erlog_db_dict,not_used),
    St=erlog_int:set_failure_reason_policy(Policy,St0),
    Trace=trace:session_create(failure_stack_probe,self(),[]),
    MFA={erlog_int,valid_failure_reason,1},
    trace:function(Trace,MFA,true,[local,call_count]),
    {reductions,R0}=process_info(self(),reductions),Start=erlang:monotonic_time(microsecond),
    Final=lists:foldl(fun(I,Acc)->erlog_int:add_failure_reason({diagnostic,I},Acc) end,St,lists:seq(1,N)),
    Us=erlang:monotonic_time(microsecond)-Start,{reductions,R1}=process_info(self(),reductions),
    {call_count,Count}=trace:info(Trace,MFA,call_count),trace:session_destroy(Trace),
    %% Record shape is the pinned coordinated owner, not a numeric tuple offset.
    Reasons=Final#est.fail_reasons,
    N=length(Reasons),
    #{reasons=>N,policy=>Policy,time_us=>Us,reductions=>R1-R0,reason_validations=>Count,retained=>length(Reasons)}.

-module('open-sequence-profile').
-export([run/0]).
run() ->
    Parent = self(),
    Collector = spawn_link(fun() -> collect(Parent) end),
    Trace = trace:session_create(gui_open_diagnostic, Collector, []),
    Functions = [{quod_gui_presentation, prepare, 3}, {quod_gui_presentation, release, 2},
                 {quod_client_goal_ingress, submit, 2}],
    [begin code:ensure_loaded(M),
           trace:function(Trace, {M,F,A}, [{'_',[],[{return_trace}]}], [local])
     end || {M,F,A} <- Functions],
    trace:process(Trace, all, true, [call]),
    Result = try eunit:test([quod_gui_components_tests,quod_gui_question_tests,quod_gui_examples_tests], [verbose])
        after
            Ref = trace:delivered(Trace, all),
            receive {trace_delivered, all, Ref} -> ok end,
            trace:session_destroy(Trace),
            Collector ! done,
            receive flushed -> ok end
        end,
    case Result of ok -> ok; _ -> error({diagnostic_test_failed, Result}) end.
collect(Parent) ->
    receive
        {trace, Pid, call, {M,F,Args}} ->
            io:format("OWNER_CALL ~p ~p ~p ~p~n", [erlang:monotonic_time(microsecond),Pid,{M,F,length(Args)},enter]),
            collect(Parent);
        {trace, Pid, return_from, MFA, _} ->
            io:format("OWNER_CALL ~p ~p ~p ~p~n", [erlang:monotonic_time(microsecond),Pid,MFA,leave]),
            collect(Parent);
        done -> Parent ! flushed;
        _ -> collect(Parent)
    end.

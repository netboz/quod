#!/usr/bin/env escript
main(_) ->
    Parent = self(),
    Collector = spawn_link(fun() -> collect(Parent,[]) end),
    Trace = trace:session_create(physics_trace_negative_control,Collector,[]),
    Path = "/tmp/quod-geometry-trace-negative-control-" ++ integer_to_list(erlang:unique_integer([positive])),
    try
        Match = [{'_',[],[{message,{caller}}]}],
        trace:function(Trace,{file,datasync,1},Match,[local]),
        trace:process(Trace,self(),true,[call]),
        {ok,Fd} = file:open(Path,[raw,binary,write]),
        try ok = file:write(Fd,<<"trace control">>), ok = file:datasync(Fd)
        after file:close(Fd) end,
        Delivered = trace:delivered(Trace,all),
        receive {trace_delivered,all,Delivered} -> ok
        after 3000 -> erlang:error(trace_delivery_timeout) end,
        Collector ! finish,
        receive
            {calls,[{Pid,{file,datasync,1},Caller}]} when Pid =:= self() ->
                io:format("~p~n",[#{calls => 1,call => {file,datasync,1},caller => Caller}]);
            {calls,Other} -> erlang:error({unexpected_trace,Other})
        after 3000 -> erlang:error(trace_collection_timeout) end
    after trace:session_destroy(Trace), file:delete(Path), unlink(Collector), exit(Collector,kill) end.
collect(Parent,Acc) ->
    receive
        {trace,Pid,call,{M,F,Args},Caller} -> collect(Parent,[{Pid,{M,F,length(Args)},Caller}|Acc]);
        finish -> Parent ! {calls,lists:reverse(Acc)}
    end.

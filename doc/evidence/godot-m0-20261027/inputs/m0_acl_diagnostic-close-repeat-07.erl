-module(m0_acl_diagnostic).
-export([run/0]).

run() ->
    {module,cowboy_http}=code:ensure_loaded(cowboy_http),
    Collector=spawn(fun()->collect([]) end),
    Trace=trace:session_create(m0_http,Collector,[]),
    trace:function(Trace,{cowboy_http,terminate,2},true,[local]),
    trace:process(Trace,all,true,[call,set_on_spawn,monotonic_timestamp]),
    Result=try
               {timeout,180,Case}=quod_ontology_acl_acceptance_tests:two_independent_users_over_https_test_(),
               Count=list_to_integer(os:getenv("M0_ACL_REPEAT","1")),
               lists:foreach(fun(I)->io:format("case_begin=~p utc_ms=~p~n",[I,erlang:system_time(millisecond)]),Case(),io:format("case_pass=~p~n",[I]) end,lists:seq(1,Count)),0
           catch C:R:S->io:format("case_failure=~p:~p stack=~p~n",[C,R,S]),1 end,
    Barrier=trace:delivered(Trace,all),
    receive {trace_delivered,all,Barrier}->ok after 2000->error(trace_barrier) end,
    Collector!{get,self()},
    receive {events,Rows}->io:format("http_terminations=~p~n",[Rows])
    after 2000->error(collector) end,
    trace:session_destroy(Trace),Collector!stop,halt(Result).

collect(Rows) ->
    receive
        {trace_ts,P,call,{cowboy_http,terminate,[_State,Reason]},T} ->
            %% Discard the entire connection state; keep only fixed reason tags.
            Tag=case Reason of
                    {connection_error,timeout,"No request-line received before timeout."}->timeout_no_request_line;
                    {connection_error,timeout,"Request headers not received before timeout."}->timeout_request_headers;
                    {connection_error,timeout,_}->connection_timeout;
                    {connection_error,protocol_error,_}->protocol_error;
                    {socket_error,closed,_}->socket_closed;
                    {socket_error,_,_}->socket_error;
                    {stop,_,_}->parent_stopped;
                    _->other
                end,
            Utc=erlang:convert_time_unit(T,native,millisecond)+erlang:time_offset(millisecond),
            collect(lists:sublist([{Utc,P,Tag}|Rows],512));
        {get,From}->From!{events,lists:reverse(Rows)},collect(Rows);
        stop->ok;
        _->collect(Rows)
    end.

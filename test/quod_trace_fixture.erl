-module(quod_trace_fixture).

%% Vocabulary-neutral peer helper: loading a whole integration-test suite on a
%% target would allocate its intentionally caller-only ontology symbols. Calls
%% enter through peer:call, so no distribution to the controlling CT VM is
%% needed. All pid messaging and monitors below are local to this peer.
-export([start/0, take_span/3, stop/1, prove/2]).

start() ->
    Owner = self(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        quod_trace_tests:with_tracer(fun() ->
            Owner ! {trace_fixture_ready, self()},
            loop()
        end)
    end),
    receive
        {trace_fixture_ready, Pid} ->
            demonitor(Monitor, [flush]),
            Pid;
        {'DOWN', Monitor, process, Pid, Reason} ->
            error({trace_fixture_start_failed, Reason})
    after 5000 ->
        exit(Pid, kill),
        demonitor(Monitor, [flush]),
        error(trace_fixture_start_timeout)
    end.

take_span(Pid, Name, TraceId) ->
    gen_server:call(Pid, {take_span, Name, TraceId}, 5000).

stop(Pid) ->
    Monitor = monitor(process, Pid),
    Pid ! stop,
    receive
        {'DOWN', Monitor, process, Pid, normal} -> ok;
        {'DOWN', Monitor, process, Pid, Reason} ->
            error({trace_fixture_stopped, Reason})
    after 5000 ->
        exit(Pid, kill),
        demonitor(Monitor, [flush]),
        error(trace_fixture_stop_timeout)
    end.

loop() ->
    receive
        {'$gen_call', From, {take_span, Name, TraceId}} ->
            gen_server:reply(From, quod_trace_tests:take_span(Name, TraceId)),
            loop();
        stop -> ok
    end.

prove(Namespace, Goal) ->
    quod_trace_tests:with_tracer(fun() ->
        %% Pick the request identity before dispatch: even public_proof can
        %% have unrelated namesakes in this application-wide exporter.
        quod_trace:with_span(otel_ctx:new(), <<"fixture.remote_scope">>, internal, #{},
          fun(Parent) ->
            TraceId = otel_span:trace_id(Parent),
            Take = fun(Name) -> quod_trace_tests:take_span(Name, TraceId) end,
            Result = quod_prolog:prove(Namespace, Goal),
            {Result,
             Take(<<"quod.prolog.public_proof">>),
             Take(<<"quod.ask.open">>),
             Take(<<"quod.ask.directory_resolve">>),
             Take(<<"quod.ask.remote_scope_open">>),
             Take(<<"quod.ask.invoke_open_request">>)}
          end)
    end).

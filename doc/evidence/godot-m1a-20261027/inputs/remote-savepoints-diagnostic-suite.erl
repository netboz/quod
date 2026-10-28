-module(quod_m1a_savepoint_diag_SUITE).
-include_lib("common_test/include/ct.hrl").
-export([all/0, init_per_suite/1, end_per_suite/1, savepoints/1,
         start_capture/0, finish_capture/1]).

all() -> [savepoints].
init_per_suite(Config) -> quod_ask_SUITE:init_per_suite(Config).
end_per_suite(Config) -> quod_ask_SUITE:end_per_suite(Config).

savepoints(Config) ->
    Peers = [{Role, ?config(Role, Config)} || Role <- [asker, target, third]],
    Captures = [{Role, Peer, peer:call(Peer, ?MODULE, start_capture, [])}
                || {Role, Peer} <- Peers],
    try quod_ask_SUITE:remote_signed_transaction_savepoints(Config)
    after
        [ct:pal("M1a savepoint diagnostic ~p: ~p", [Role,
             peer:call(Peer, ?MODULE, finish_capture, [Capture])])
         || {Role, Peer, Capture} <- Captures]
    end.

patterns() ->
    [{quod_client_result, normalize_error, 1}, {quod_ask, ask_error, 1},
     {quod_scope_wire, protocol_error, 1},
     {quod_client_goal_endpoint, protocol_error, 1},
     {quod_transaction_scope, request, 2}].

start_capture() ->
    Pid = spawn(fun() -> collect(#{}, #{}, [], none) end),
    [begin code:ensure_loaded(M),
           erlang:trace_pattern({M,F,A}, [{'_',[],[{return_trace}]}], [local])
     end || {M,F,A} <- patterns()],
    erlang:trace(all, true, [call, set_on_spawn, monotonic_timestamp, {tracer,Pid}]),
    {Pid, erlang:monotonic_time(microsecond), erlang:statistics(runtime)}.

finish_capture({Pid, Start, {Runtime, _}}) ->
    erlang:trace(all, false, [call, set_on_spawn, monotonic_timestamp]),
    [erlang:trace_pattern(MFA, false, [local]) || MFA <- patterns()],
    Ref=make_ref(), Pid!{finish,self(),Ref},
    receive {Ref, Data} ->
        {Now,_}=erlang:statistics(runtime),
        Data#{wall_us=>erlang:monotonic_time(microsecond)-Start,
              runtime_ms=>Now-Runtime}
    after 5000 -> error(diagnostic_delivery_timeout) end.

collect(Stats, Starts, Errors, Closing) ->
    receive
        {trace_ts, Pid, call, {quod_transaction_scope,request,[_State,Operation]},Time} ->
            Tag=element(1,Operation),
            collect(Stats,Starts#{Pid=>[{Tag,Time}|maps:get(Pid,Starts,[])]},Errors,Closing);
        {trace_ts, Pid, return_from, {quod_transaction_scope,request,2},Result,Time} ->
            [{Tag,Start}|Rest]=maps:get(Pid,Starts),
            Duration=erlang:convert_time_unit(Time-Start,native,microsecond),
            Old=maps:get(Tag,Stats,#{count=>0,total_us=>0,max_us=>0}),
            New=Old#{count=>maps:get(count,Old)+1,
                     total_us=>maps:get(total_us,Old)+Duration,
                     max_us=>max(maps:get(max_us,Old),Duration)},
            NextErrors=case Result of {error,R}->retain({request,Tag,R},Errors); _->Errors end,
            collect(Stats#{Tag=>New},Starts#{Pid=>Rest},NextErrors,Closing);
        {trace_ts, _, call, {M,F,[Reason]},_}
          when F=:=normalize_error; F=:=ask_error; F=:=protocol_error ->
            collect(Stats,Starts,retain({M,F,Reason},Errors),Closing);
        {finish,Caller,Ref} ->
            Delivery=erlang:trace_delivered(all),
            collect(Stats,Starts,Errors,{Caller,Ref,Delivery});
        {trace_delivered,all,Delivery} ->
            {Caller,Ref,Delivery}=Closing,
            Caller!{Ref,#{requests=>Stats,errors=>lists:reverse(Errors)}};
        _ -> collect(Stats,Starts,Errors,Closing)
    end.

retain(Reason, Errors) when length(Errors)<32 -> [redact(Reason,5)|Errors];
retain(_,Errors) -> Errors.
redact(_,0) -> bounded;
redact(B,_) when is_binary(B) -> {binary,byte_size(B)};
redact(T,N) when is_tuple(T) -> list_to_tuple([redact(X,N-1)||X<-tuple_to_list(T)]);
redact(L,N) when is_list(L) -> [redact(X,N-1)||X<-lists:sublist(L,5)];
redact(M,_) when is_map(M) -> {map,map_size(M)};
redact(P,_) when is_pid(P);is_reference(P);is_function(P) -> opaque;
redact(V,_) -> V.

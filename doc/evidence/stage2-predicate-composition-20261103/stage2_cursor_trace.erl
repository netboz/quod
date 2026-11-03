-module(stage2_cursor_trace).
-export([start/0,stop/1]).

%% Removable bounded software-fixture observation. Never installed in product.
start() ->
    {module,quod_wire_term}=code:ensure_loaded(quod_wire_term),
    {module,quod_client_view}=code:ensure_loaded(quod_client_view),
    io:format(standard_error,"STAGE2_MODULE_OWNER ~p~n",[{code:which(quod_wire_term),quod_wire_term:module_info(md5)}]),
    Collector=spawn_link(fun()->collect(#{}) end),
    Trace=trace:session_create(stage2_cursor_diagnostic,Collector,[]),
    [trace:function(Trace,MFA,[{'_',[],[{return_trace}]}],[local]) || MFA <-
        [{quod_client_cursor,finish_cursor,4},{quod_client_result,normalize,2}]],
    trace:function(Trace,{quod_client_view,open_subject,7},true,[local]),
    trace:function(Trace,{quod_client_result,normalize_error,1},true,[local]),
    trace:process(Trace,all,true,[call]),{Trace,Collector}.
stop({Trace,Collector}) ->
    trace:session_destroy(Trace),Ref=make_ref(),Collector!{stop,self(),Ref},
    receive {Ref,stopped}->ok after 5000->error(cursor_trace_cleanup_timeout) end.
collect(Pending) -> receive
    {trace,_,call,{quod_client_result,normalize_error,[Reason]}} -> io:format(standard_error,"COMPOSITION_OWNER_ERROR ~p~n",[Reason]),collect(Pending);
    {trace,_,call,{quod_client_view,open_subject,[Returned,_,_,_,_,_,#{kind:=eidolon_scene,instance:=Requested}]}} ->
        case maps:get(subject_seen,Pending,false) of
            false -> io:format(standard_error,"STAGE2_SUBJECT_ENCODING ~s~n",[json:encode(#{raw_equal=>Returned=:=Requested,
                canonical_equal=>quod_wire_term:encode_canonical(Returned)=:=quod_wire_term:encode_canonical(Requested),
                request_opaque=>is_tuple(Requested) andalso element(1,Requested)=:='$quod_symbol',returned_atom=>is_atom(Returned)})]);
            true -> ok
        end,collect(Pending#{subject_seen=>true});
    {trace,Pid,call,{quod_client_result,normalize,[_Evidence,Raw]}} -> collect(Pending#{Pid=>Raw});
    {trace,Pid,return_from,{quod_client_result,normalize,2},Result} ->
        case Result of {error,_}->io:format(standard_error,"STAGE2_CURSOR_NORMALIZE ~p~n",[{Result,maps:get(Pid,Pending,missing)}]);_->ok end,
        collect(maps:remove(Pid,Pending));
    {trace,_,call,{quod_client_cursor,finish_cursor,[_Key,_Cursor,Reply,_State]}} ->
        case Reply of {error,_}->io:format(standard_error,"STAGE2_CURSOR_ERROR ~p~n",[Reply]);{fail,_}->io:format(standard_error,"STAGE2_CURSOR_FAIL ~p~n",[Reply]);_->ok end,collect(Pending);
    {stop,From,Ref}->From!{Ref,stopped};
    _->collect(Pending)
end.

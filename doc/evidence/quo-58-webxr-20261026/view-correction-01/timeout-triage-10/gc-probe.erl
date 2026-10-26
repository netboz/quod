-module(quod_editor_gc).
-export([start/0,stop/0]).
start() ->
    Owner=self(), Path=os:getenv("QUOD_GC_LOG"),
    {binary,Binaries}=process_info(self(),binary),
    {messages,Messages}=process_info(self(),messages),
    Initial=#{binary_bytes=>lists:sum([S || {_,S,_}<-Binaries]),binary_count=>length(Binaries),
              mailbox_words=>erts_debug:flat_size(Messages)},
    Collector=spawn(fun()-> M=monitor(process,Owner), collect(Owner,M,Path,Initial,[],0) end),
    Session=trace:session_create(editor_gc,Collector,[]),
    trace:process(Session,self(),true,[garbage_collection,monotonic_timestamp]),
    put(?MODULE,{Session,Collector}).
stop() ->
    {Session,Collector}=erase(?MODULE),
    trace:process(Session,self(),false,[garbage_collection]),
    Ref=trace:delivered(Session,self()),
    receive {trace_delivered,_,Ref}->ok end,
    Monitor=monitor(process,Collector),Collector!finish,
    receive {'DOWN',Monitor,process,Collector,normal}->ok end,
    trace:session_destroy(Session).
collect(Owner,Monitor,Path,Initial,Events,Count) ->
    receive
        {trace_ts,Owner,Kind,Info,At} when Count<10000 ->
            collect(Owner,Monitor,Path,Initial,[{Kind,erlang:convert_time_unit(At,native,microsecond),Info}|Events],Count+1);
        {trace_ts,Owner,_,_,_} -> collect(Owner,Monitor,Path,Initial,Events,Count+1);
        finish -> save(Path,Initial,Events,Count,completed);
        {'DOWN',Monitor,process,Owner,_} -> save(Path,Initial,Events,Count,owner_down)
    end.
save(Path,Initial,Events,Count,Status) ->
    file:write_file(Path,io_lib:format("~p.~n",[#{initial=>Initial,status=>Status,count=>Count,events=>lists:reverse(Events)}])).

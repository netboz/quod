%% External, finite diagnostic only. Load explicitly for an observer-on run.
%% Rare allocation metadata plus the unchanged independent start counter only.
%% No hot-boundary counter, descendant tracing, owner pause or shutdown change.
-module(quod_c4_phase1_capture).
-export([start/2, status/1, stop/1, release/1, match_spec/0]).
-define(MFA, {quod_simplex,start_dtx_coordinator_worker,7}).
-define(RPC_MS, 5000).
-define(RECORD, {quod_c4_attempt,record,1}).
-define(FLAGS, [call,arity,monotonic_timestamp]).

match_spec() ->
    [{['$1','_','_','_','_','_','_'],
      [{is_binary,'$1'},{'=:=',{byte_size,'$1'},32}],
      [{message,{{producer_start,'$1'}}}]},
     {['_','_','_','_','_','_','_'],[],[{message,invalid_group}]}].

start(Namespaces, Options) ->
    case whereis(?MODULE) of
        undefined ->
            Parent=self(), Ref=make_ref(),
            {Pid,M}=spawn_monitor(fun()->init(Parent,Ref,Namespaces,Options) end),
            receive
                {Ref,Reply} -> demonitor(M,[flush]), Reply;
                {'DOWN',M,process,Pid,_} -> {error,capture_start_failed}
            after ?RPC_MS -> exit(Pid,kill), {error,capture_start_timeout} end;
        _ -> {error,capture_already_present}
    end.
status(Token) -> request(Token,status).
stop(Token) -> request(Token,stop).
release(Token) -> request(Token,release).
request(Token,Op) ->
    case whereis(?MODULE) of
        undefined -> {error,capture_observer_lost};
        Pid ->
            M=monitor(process,Pid), R=make_ref(), Pid!{request,self(),R,Token,Op},
            receive
                {R,Reply} -> demonitor(M,[flush]),Reply;
                {'DOWN',M,process,Pid,_} -> {error,capture_observer_lost}
            after ?RPC_MS -> demonitor(M,[flush]),{error,capture_observer_unresponsive} end
    end.

init(Parent,Ref,Namespaces,Options) ->
    try
        true=register(?MODULE,self()),
        O=options(Namespaces,Options),
        {module,quod_simplex}=code:ensure_loaded(quod_simplex),
        {module,quod_c4_attempt}=code:ensure_loaded(quod_c4_attempt),
        Pins=pin(Namespaces),
        true=length(lists:usort([P || {_,P,_,_}<-Pins]))=:=length(Pins),
        Me=self(),
        {Collector,CM}=spawn_opt(fun()->collect(Me,maps:from_list(
          [{P,N} || {N,P,_,_}<-Pins]),O,#{},0,[],[]) end,
          [monitor,{message_queue_data,on_heap},
           {max_heap_size,#{size=>maps:get(max_heap_words,O),kill=>true,error_logger=>false}}]),
        Session=trace:session_create(c4_phase1_capture,Collector,[]),
        try
            lists:foreach(fun({_,P,_,_})->1=trace:process(Session,P,true,?FLAGS) end,Pins),
            Started=erlang:monotonic_time(millisecond),
            1=trace:function(Session,?MFA,match_spec(),[local,call_count]),
            1=trace:function(Session,?RECORD,record_match_spec(),[local]),
            ok=quod_c4_attempt:enable(maps:get(label,O),Namespaces),
            Token=binary:encode_hex(crypto:strong_rand_bytes(16),lowercase),
            S=#{options=>O,pins=>Pins,session=>Session,collector=>Collector,collector_monitor=>CM,
                token=>Token,started=>Started,deadline=>Started+maps:get(window_ms,O),
                issues=>[],module_md5=>quod_simplex:module_info(md5),state=>active,
                sdk_config_before=>quod_c4_sdk_config:snapshot()},
            Checked=drain_changes(add_issues(health(S),S)),
            case maps:get(issues,Checked) of
                [] -> Armed=Checked#{arm_ack=>erlang:monotonic_time(millisecond)},
                      Parent!{Ref,{ok,public(Armed)}},active(Armed);
                _ -> Parent!{Ref,{error,capture_start_not_clean}},finish(Checked,start_failed)
            end
        catch Class:Reason:Stack ->
            %% No accepted report survives an exceptional setup/teardown. The
            %% manager exit also releases any partial public-name monitors.
            catch trace:session_destroy(Session),
            catch quod_c4_attempt:disable(maps:get(label,O)),
            exit(Collector,kill),
            erlang:raise(Class,Reason,Stack)
        end
    catch _:_ -> Parent!{Ref,{error,capture_start_failed}} end.

options(Ns,O) ->
    true=is_list(Ns) andalso Ns=/=[] andalso length(Ns)=<64,
    true=length(lists:usort(Ns))=:=length(Ns),
    true=lists:all(fun(N)->is_binary(N) andalso byte_size(N)>0 andalso byte_size(N)=<256 end,Ns),
    true=is_map(O),
    Defaults=#{label=><<"C4-phase1-observer-on">>,window_ms=>120000,
      max_events=>5000,max_groups=>1000,max_queue=>2048,max_heap_words=>262144},
    true=lists:all(fun(K)->maps:is_key(K,Defaults) orelse K=:=allocation end,maps:keys(O)),
    R=maps:merge(Defaults,O),
    true=bounded_binary(maps:get(allocation,R),256),
    true=bounded_binary(maps:get(label,R),128),
    true=bounded(maps:get(window_ms,R),100,900000),
    true=bounded(maps:get(max_events,R),1,20000),
    true=bounded(maps:get(max_groups,R),1,4096),
    true=bounded(maps:get(max_queue,R),1,8192),
    true=bounded(maps:get(max_heap_words,R),16384,1048576), R.
bounded(N,A,B)->is_integer(N) andalso N>=A andalso N=<B.
bounded_binary(B,Max)->is_binary(B) andalso byte_size(B)>0 andalso byte_size(B)=<Max.

pin(Ns) ->
    [begin
        P=quod_reg:where({quod_simplex,N}),
        true=is_pid(P) andalso node(P)=:=node(),
        M=monitor(process,P), R=quod_reg:monitor_name({quod_simplex,N},info),
        P=quod_reg:where({quod_simplex,N}),
        {N,P,M,R}
     end || N<-Ns].
unpin(Pins)->lists:flatmap(fun({N,_,M,R})->
    demonitor(M,[flush]),
    try ok=quod_reg:demonitor_name({quod_simplex,N},R),[]
    catch _:_ -> [owner_monitor_removal_failed] end
  end,Pins).

public(S)->#{capture_id=>maps:get(token,S),status=>maps:get(state,S),capture_state=>running,
    boundary=>start_dtx_coordinator_worker,includes_tentative_starts=>true,includes_failed_starts=>true,
    excludes_history_loader_only_rows=>true,collector_revision=>binary:encode_hex(?MODULE:module_info(md5),lowercase),
    collector_pid=>pid_bin(maps:get(collector,S)),observer_pid=>pid_bin(self()),
    start_monotonic_ms=>maps:get(started,S),deadline_monotonic_ms=>maps:get(deadline,S),
    arm_ack_monotonic_ms=>maps:get(arm_ack,S,undefined),
    timestamp_meaning=><<"setup/teardown brackets, not exact trace activation; admit only after arm ACK">>,
    bounds=>#{event_and_group_storage=>hard_limits,
      queue=>sampled_detection_threshold,heap=>gc_enforced_kill_threshold,
      transient_overshoot_possible=>true,every_queue_excursion_detected=>false},
    owner_map=>[#{namespace=>N,owner_pid=>pid_bin(P)} || {N,P,_,_}<-maps:get(pins,S)],
    issues=>maps:get(issues,S),scope_complete=>false,
    label=>maps:get(label,maps:get(options,S))}.
pid_bin(P)->list_to_binary(pid_to_list(P)).
add_issues(I,S)->S#{issues:=lists:usort(I++maps:get(issues,S))}.

health(S) ->
    try
        C=maps:get(collector,S), Ses=maps:get(session,S),
        Queue=case process_info(C,message_queue_len) of {message_queue_len,Q}->Q; _->lost end,
        lists:flatten([
          [collector_lost || Queue=:=lost],
          [queue_overflow || is_integer(Queue),Queue>maps:get(max_queue,maps:get(options,S))],
          [owner_changed || {N,P,_,_}<-maps:get(pins,S),
             not is_process_alive(P) orelse quod_reg:where({quod_simplex,N})=/=P],
          [trace_flags_changed || {_,P,_,_}<-maps:get(pins,S),
             not flags_match(Ses,P)],
          [trace_pattern_changed || trace:info(Ses,?MFA,match_spec)=/={match_spec,match_spec()}],
          [trace_pattern_changed || trace:info(Ses,?RECORD,match_spec)=/={match_spec,record_match_spec()}],
          [module_changed || quod_simplex:module_info(md5)=/=maps:get(module_md5,S)]])
    catch _:_ -> [capture_health_failed] end.

active(S) ->
    Remaining=maps:get(deadline,S)-erlang:monotonic_time(millisecond),
    case Remaining=<0 of
      true -> finish(add_issues([window_expired],S),window_expired);
      false -> receive
        {request,From,R,T,Op} ->
            case T=:=maps:get(token,S) of
              false -> From!{R,{error,stale_capture_token}},active(S);
              true when Op=:=status ->
                Checked=drain_changes(add_issues(health(S),S)),
                case maps:get(issues,Checked) of
                  []->From!{R,{ok,public(Checked)}},active(Checked);
                  _->finish(Checked#{reply_to=>{From,R}},failed)
                end;
              true when Op=:=stop -> finish(S#{reply_to=>{From,R}},manual_stop);
              true -> From!{R,{error,capture_still_active}},active(S)
            end;
        {collector_failed,C,Class} when C=:=map_get(collector,S) -> finish(add_issues([Class],S),failed);
        {'DOWN',M,process,_,_} ->
            Class=case M=:=maps:get(collector_monitor,S) of true->collector_lost; false->owner_lost end,
            finish(add_issues([Class],S),failed);
        {gproc,_,_,_} -> finish(add_issues([owner_registration_changed],S),failed)
      after min(50,Remaining) ->
        case health(S) of []->active(S); Problems->finish(add_issues(Problems,S),failed) end
      end
    end.

finish(S,Why) ->
    Ses=maps:get(session,S), C=maps:get(collector,S),
    Guard=teardown_guard(S),
    %% Disable message tracing first, then pause the independent VM counter.
    %% A start between these operations increases only native count and fails
    %% this boundary conservatively; it never becomes silent undercounting.
    Pre=health(S),
    ok=quod_c4_attempt:disable(maps:get(label,maps:get(options,S))),
    Removed=try 1=trace:function(Ses,?MFA,false,[local]),
                1=trace:function(Ses,?RECORD,false,[local]),
                1=trace:function(Ses,?MFA,pause,[call_count]),
                {call_count,N}=trace:info(Ses,?MFA,call_count),{ok,N}
            catch _:_ -> {error,trace_cleanup_failed} end,
    TraceClosed=erlang:monotonic_time(millisecond),
    %% Explicit local PIDs include dead owners: `all` only covers processes
    %% currently traced. Keep our PID flags through delivery as well. OTP 28
    %% delivered/2 delegates to the node-wide per-PID delivery primitive.
    {Barrier,S1}=cohort_barrier(add_issues(Pre,S)),
    FlagsRemoved=lists:flatmap(fun({_,P,_,_})->
      try _=trace:process(Ses,P,false,?FLAGS),[]
      catch _:_ -> [trace_flags_removal_failed] end end,maps:get(pins,S)),
    R=make_ref(), C!{snapshot,self(),R},
    Snapshot=receive {snapshot,R,V}->V after 1500->unavailable end,
    %% Name-monitor removal is synchronous with gproc. Drain already queued
    %% change/death signals before claiming the pinned registration boundary.
    FinalPins=[owner_changed || {N,P,_,_}<-maps:get(pins,S),
      not is_process_alive(P) orelse quod_reg:where({quod_simplex,N})=/=P],
    UnpinIssues=unpin(maps:get(pins,S)),
    S2=drain_changes(add_issues(FinalPins++UnpinIssues++FlagsRemoved,S1)),
    Destroyed=catch trace:session_destroy(Ses),
    {CollectorDead,ShutdownIssues}=shutdown_collector(C),
    End=erlang:monotonic_time(millisecond),
    {Counts,Seen,CollectIssues,Records}=case Snapshot of
      #{counts:=Cs,seen:=K,issues:=I,records:=Rs}->{Cs,K,I,Rs}; _->{#{},undefined,[collector_snapshot_lost],[]} end,
    Native=case Removed of {ok,VN}->VN; _->undefined end,
    Problems=lists:usort(maps:get(issues,S2)++CollectIssues++ShutdownIssues++
      [delivery_barrier_failed || not Barrier]++[trace_cleanup_failed || Destroyed=/=true]++
      [trace_cleanup_failed || not is_tuple(Removed) orelse element(1,Removed)=/=ok]++
      [native_count_mismatch || not is_integer(Native) orelse Native=/=Seen]),
    Complete=Why=:=manual_stop andalso Problems=:=[],
    O=maps:get(options,S),
    Rows=[#{allocation=>maps:get(allocation,O),namespace=>N,owner_pid=>pid_bin(P),
            group_id=>binary:encode_hex(G,lowercase),duration_scope=><<"owner_observed_attempt">>,
            expected_attempts=>K} || {{P,N,G},K}<-lists:sort(maps:to_list(Counts))],
    Assigned=lists:sum(maps:values(Counts)),
    Report=(public(S2))#{status=>finished,capture_state=>finished,scope_complete=>Complete,issues=>Problems,
      finish_reason=>Why,end_monotonic_ms=>End,trace_delivered=>Barrier,session_removed=>Destroyed=:=true,
      delivery_scope=>exact_pinned_pids_including_dead,collector_dead=>CollectorDead,
      owner_monitors_removed=>UnpinIssues=:=[],trace_flags_removed=>FlagsRemoved=:=[],
      trace_closed_monotonic_ms=>TraceClosed,
      native_start_count=>Native,received_start_count=>Seen,assigned_start_count=>Assigned,
      unassigned_native_starts=>case is_integer(Native) of true->max(0,Native-Assigned);false->unknown end,
      native_count_scope=>all_vm_calls_to_start_mfa,rows=>Rows,records=>Records,
      vm=>maps:get(token,S),sdk_config_before=>maps:get(sdk_config_before,S),
      sdk_config_after=>quod_c4_sdk_config:snapshot(),
      allocation=>maps:get(allocation,O),
      metadata_completeness=><<"not a second counter: each missing or ambiguous allocation remains unknown">>,
      inventory=>#{schema=><<"quod.coordinator-attempt-inventory/v1">>,
        provenance=>#{kind=><<"external_producer">>,reference=>maps:get(token,S)},
        scope=>#{label=>maps:get(label,O),complete=>Complete},rows=>Rows},
      observation_mode=><<"external-trace-and-native-count; observer-on; not zero overhead">>},
    GuardMonitor=monitor(process,Guard),Guard!{teardown_complete,self()},
    receive {'DOWN',GuardMonitor,process,Guard,normal}->ok
    after 200->error(teardown_guard_unresponsive) end,
    case maps:find(reply_to,S) of {ok,{From,Req}}->From!{Req,{ok,Report}};error->ok end,
    finished(maps:get(token,S),Report,erlang:monotonic_time(millisecond)+600000).

teardown_guard(S)->
    %% Public gproc demonitor can block (its own timeout is 5s per call).
    %% Bound the WHOLE teardown, without private gproc protocol or owner work.
    %% Timeout invalidates capture; only our two observation actors are killed.
    Me=self(),C=maps:get(collector,S),Reply=maps:get(reply_to,S,none),
    spawn(fun()->M=monitor(process,Me),receive
      {teardown_complete,Me}->demonitor(M,[flush]);
      {'DOWN',M,process,Me,_}->exit(C,kill)
    after 4000->
      case Reply of {From,R}->From!{R,{error,capture_teardown_timeout}};none->ok end,
      exit(C,kill),exit(Me,kill)
    end end).
shutdown_collector(C)->
    M=monitor(process,C),C!shutdown,
    receive {'DOWN',M,process,C,_}->{true,[]}
    after 500->exit(C,kill),
      receive {'DOWN',M,process,C,_}->{true,[collector_shutdown_timeout]}
      after 250->demonitor(M,[flush]),{false,[collector_death_unconfirmed]} end
    end.
cohort_barrier(S)->
    Ses=maps:get(session,S),
    try
      Pending=maps:from_list([{trace:delivered(Ses,P),P} || {_,P,_,_}<-maps:get(pins,S)]),
      barrier(Pending,S,erlang:monotonic_time(millisecond)+1500)
    catch _:_ -> {false,add_issues([delivery_barrier_request_failed],S)} end.
barrier(Pending,S,_Deadline) when map_size(Pending)=:=0->{true,S};
barrier(Pending,S,Deadline)->
    Remaining=max(0,Deadline-erlang:monotonic_time(millisecond)),
    receive
      {trace_delivered,P,B} when is_map_key(B,Pending),map_get(B,Pending)=:=P ->
        barrier(maps:remove(B,Pending),S,Deadline);
      {'DOWN',_,process,_,_}->barrier(Pending,add_issues([observed_process_lost],S),Deadline);
      {gproc,_,_,_}->barrier(Pending,add_issues([owner_registration_changed],S),Deadline);
      {collector_failed,_,Class}->barrier(Pending,add_issues([Class],S),Deadline)
    after Remaining->{false,S} end.
drain_changes(S)->receive
    {'DOWN',_,process,_,_}->drain_changes(add_issues([observed_process_lost],S));
    {gproc,_,_,_}->drain_changes(add_issues([owner_registration_changed],S));
    {collector_failed,_,Class}->drain_changes(add_issues([Class],S))
after 0->S end.
finished(T,Report,Deadline)->
    receive
      {request,From,R,T,release}->From!{R,ok},ok;
      {request,From,R,T,_}->From!{R,{ok,Report}},finished(T,Report,Deadline);
      {request,From,R,_,_}->From!{R,{error,stale_capture_token}},finished(T,Report,Deadline)
    after max(0,Deadline-erlang:monotonic_time(millisecond))->ok end.

flags_match(Session, Pid) ->
    case trace:info(Session, Pid, flags) of
        {flags, Flags} -> lists:sort(Flags) =:= lists:sort(?FLAGS);
        _ -> false
    end.
record_match_spec() ->
    [{['$1'],[{is_map,'$1'},{'=:=',{map_size,'$1'},7}],
      [{message,{{attempt_metadata,'$1'}}}]}].

collect(Manager,Pins,O,Counts,Seen,Issues,Records)->
    %% Arity tracing prevents SDK/Begin/state/keys from entering the stream.
    receive
      {trace_ts,P,call,?MFA,{producer_start,G},Time}
        when is_binary(G),byte_size(G)=:=32 ->
        N=maps:get(P,Pins,unknown), Key={P,N,G}, Next=Seen+1,
        More=[unmapped_owner || N=:=unknown]++
          [event_overflow || Next>maps:get(max_events,O)]++
          [group_overflow || not maps:is_key(Key,Counts),map_size(Counts)>=maps:get(max_groups,O)]++
          queue_issues(O),
        I=lists:usort(Issues++More), notify_issues(Manager,Issues,I),
        Ordinal=maps:get(Key,Counts,0)+1,
        Cs=case I of []->Counts#{Key=>Ordinal};_->Counts end,
        Row=#{stage=>native_start,group=>binary:encode_hex(G,lowercase),
          namespace=>N,owner=>pid_bin(P),ordinal=>integer_to_binary(Ordinal),
          monotonic_ns=>integer_to_binary(erlang:convert_time_unit(Time,native,nanosecond))},
        Rs=case I of []->[Row|Records];_->Records end,
        collect(Manager,Pins,O,Cs,Next,I,Rs);
      {trace_ts,P,call,?RECORD,{attempt_metadata,Record},_Time} ->
        I=lists:usort(Issues++queue_issues(O)++
          [metadata_overflow || length(Records)>=2*maps:get(max_events,O)]++
          [unmapped_metadata_owner || not maps:is_key(P,Pins)]),
        notify_issues(Manager,Issues,I),
        Rs=case I of []->[Record#{stage=>allocation,trace_owner=>pid_bin(P)}|Records];_->Records end,
        collect(Manager,Pins,O,Counts,Seen,I,Rs);
      {trace_ts,_,call,?MFA,invalid_group,_} ->
        Manager!{collector_failed,self(),invalid_group},
        collect(Manager,Pins,O,Counts,Seen+1,lists:usort([invalid_group|Issues]),Records);
      {snapshot,From,R}->
        From!{snapshot,R,#{counts=>Counts,seen=>Seen,issues=>Issues,records=>lists:reverse(Records)}},
        collect(Manager,Pins,O,Counts,Seen,Issues,Records);
      shutdown->ok;
      _ -> Manager!{collector_failed,self(),unexpected_trace_shape},
        collect(Manager,Pins,O,Counts,Seen,lists:usort([unexpected_trace_shape|Issues]),Records)
    after 100->case is_process_alive(Manager) of
      true->collect(Manager,Pins,O,Counts,Seen,Issues,Records);false->ok end
    end.
queue_issues(O) ->
    case process_info(self(),message_queue_len) of
      {message_queue_len,Q} when Q>map_get(max_queue,O)->[queue_overflow];_->[]
    end.
notify_issues(Manager,[],[_|_]=Issues)->Manager!{collector_failed,self(),hd(Issues)};
notify_issues(_,_,_)->ok.

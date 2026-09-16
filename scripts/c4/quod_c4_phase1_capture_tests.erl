-module(quod_c4_phase1_capture_tests).
-include_lib("eunit/include/eunit.hrl").

%% Real durable unsigned source admission / real Simplex start / real SDK
%% allocation. The owner parks before Vote selection/signing or committed-read
%% readiness; this is neither a consensus-admission nor a latency witness.
real_owner_rare_capture_and_exact_session_cleanup_test() ->
    %% The lab exporter addresses its enclosing test process. Isolate this
    %% fixture so exported ordinary spans cannot contaminate the next test's
    %% name-matched receives. Do not drain somebody else's mailbox.
    {Pid,Monitor}=spawn_monitor(fun real_owner_rare_capture_and_exact_session_cleanup/0),
    receive
        {'DOWN',Monitor,process,Pid,normal}->ok;
        {'DOWN',Monitor,process,Pid,Reason}->error({capture_fixture_failed,Reason})
    after 5000 ->
        exit(Pid,kill),
        receive {'DOWN',Monitor,process,Pid,_}->ok end,
        error(capture_fixture_timeout)
    end.

real_owner_rare_capture_and_exact_session_cleanup() ->
    quod_trace_tests:with_tracer(fun() ->
      quod_dtx_group_trace_tests:with_live_admission(fun(F, Engine, Owner, Ref) ->
        {Ns,_}=maps:get(target,F),
        Other=trace:session_create(c4_phase1_unrelated,self(),[]),
        1=trace:process(Other,Owner,true,[call,arity]),
        %% Test-only receipt barrier for the Engine -> Owner activation cast.
        %% This is separate from both named sessions and adds no capture hook.
        1=erlang:trace(Owner,true,['receive',{tracer,self()}]),
        try
            {ok,Armed}=quod_c4_phase1_capture:start([Ns],
              #{label=><<"C4-phase1-lab-v1">>,allocation=><<"lab-not-fleet">>,window_ms=>10000}),
            Token=maps:get(capture_id,Armed),
            Material=quod_atomic:control_material(maps:get(vote_control,F)),
            {ok,GroupRef}=quod_atomic:source_group_ref(Material),
            ?assertEqual(ok,gen_server:call(Engine,{reserve_dtx_vote,Ref,Material,GroupRef,otel_ctx:new()})),
            ?assertEqual(ok,gen_server:call(Engine,{activate_dtx_vote,Ref,GroupRef})),
            receive {trace,Owner,'receive',{'$gen_cast',{activate_dtx_vote,Engine,_}}}->ok
            after 1000 -> error(vote_activation_not_received)
            end,
            {running,S}=sys:get_state(Owner),
            ?assertMatch(#{active:=1,reserved:=0},quod_simplex:test_dtx_admission_state(S)),
            ?assertMatch(#{retained:=0},quod_simplex:test_retained_dtx_state(S)),
            {group,_,_,_,_,G}=GroupRef,
            #{G:=#{pid:=Worker}}=quod_simplex:test_dtx_coordinator_state(S),
            ?assertMatch(#{execution_ready:=false,wave:=none},quod_dtx_coordinator:test_state(Worker)),
            Delivered=erlang:trace_delivered(Owner),
            receive {trace_delivered,Owner,Delivered}->ok
            after 1000 -> error(endpoint_trace_not_delivered)
            end,
            receive {trace,Owner,'receive',{'$gen_call',_,{dtx_endpoint_local,_,_,_,_}}}->
                error(endpoint_dispatched_while_unready)
            after 0 -> ok
            end,
            {ok,Report}=quod_c4_phase1_capture:stop(Token),
            ?assertEqual([],maps:get(issues,Report)),
            ?assertEqual(true,maps:get(scope_complete,Report)),
            ?assertEqual(1,maps:get(native_start_count,Report)),
            ?assertEqual(1,maps:get(received_start_count,Report)),
            [Start]=[R || R=#{stage:=native_start}<-maps:get(records,Report)],
            [Allocation]=[R || R=#{stage:=allocation}<-maps:get(records,Report)],
            ?assertEqual(maps:get(owner,Start),maps:get(owner,Allocation)),
            ?assertEqual(maps:get(group,Start),maps:get(group,Allocation)),
            ?assertEqual(returned,maps:get(edge,Allocation)),
            ?assertMatch(#{allocation_kind:=new_identity,span:=#{sampled:=true,recording:=true}},
                         maps:get(metadata,Allocation)),
            ?assertEqual(2,length(maps:get(records,Report))),
            ?assertEqual({flags,[arity,call]},trace:info(Other,Owner,flags)),
            ?assertEqual(true,maps:get(collector_dead,Report)),
            ?assertEqual(true,maps:get(session_removed,Report)),
            ?assert(is_binary(iolist_to_binary(json:encode(Report)))),
            ?assertEqual(ok,quod_c4_phase1_capture:release(Token))
        after
            _=catch erlang:trace(Owner,false,['receive']),
            _=catch trace:session_destroy(Other),
            _=catch gen_statem:stop(Owner)
        end
      end)
    end).

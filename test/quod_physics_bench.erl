-module(quod_physics_bench).
-export([run/0]).

run() ->
    io:format("OTP=~s schedulers=~p dirty_cpu=~p~n", [erlang:system_info(otp_release),
        erlang:system_info(schedulers_online), erlang:system_info(dirty_cpu_schedulers_online)]),
    lists:foreach(fun measure/1, [2,64,256]),
    surface_motion(),
    dense(64),
    owner_death(256),
    Parent = self(),
    Echo = spawn(fun echo/0),
    Workers = [spawn_monitor(fun() -> receive go -> Parent ! {bench, self(), work(64, 500)} end end)
               || _ <- lists:seq(1,4)],
    [Pid ! go || {Pid,_} <- Workers],
    Echo ! {ping,self()},
    Heartbeat = probe(Echo,length(Workers),erlang:monotonic_time(microsecond),[],0),
    [receive {'DOWN', M, process, Pid, normal} -> ok end || {Pid,M} <- Workers],
    Echo ! stop,
    io:format("normal_scheduler_ping_us ~p samples=~p~n", [percentiles(Heartbeat),length(Heartbeat)]).

surface_motion() ->
    %% The ordinary 16-body/256-vertex/256-triangle policy, with an explicit
    %% surface and controlled capsule. No visual geometry or second query world.
    Vertices = [{float(X)-5.0,0.0,float(Z)-5.0} || Z <- lists:seq(0,11), X <- lists:seq(0,11)],
    Triangles = lists:append([[{I,I+12,I+1},{I+1,I+12,I+13}]
        || Z <- lists:seq(0,10), X <- lists:seq(0,10), I <- [Z*12+X]]),
    Rows = [{1,1,fixed,{{0.0,0.0,0.0},{0.0,0.0,0.0}},{surface,Vertices,Triangles},1.0},
            {2,1,controlled,{{2.0,0.752,2.0},{0.0,0.0,0.0}},{solid,{capsule,0.5,0.25}},1.0} |
            [{I,1,fixed,{{float(I)+20.0,0.5,0.0},{0.0,0.0,0.0}},{solid,{ball,0.25}},1.0}
                || I <- lists:seq(3,16)]],
    {ok,R} = quod_physics_native:new_world({16,16,128,1000.0,32,256,256},0.016667,-9.81),
    {Install,{ok,16}} = timer:tc(fun() -> quod_physics_native:install(R,Rows) end),
    {ok,_} = quod_physics_native:step(R,false),
    Samples = [begin
        X = case I rem 2 of 0 -> 0.033334; 1 -> -0.033334 end,
        {Us,{ok,Answer}} = timer:tc(fun() -> quod_physics_native:move_body(R,2,1,
            {travel,{X,-0.002725109,0.0},{0.0,0.0,0.0}},{0.002,0.0,8,128}) end),
        true = element(1,Answer) =:= clipped orelse element(1,Answer) =:= clear,
        {ok,_} = quod_physics_native:step(R,false), Us
    end || I <- lists:seq(1,2000)],
    Rss = rss_kb(),
    {Unchanged,{ok,0}} = timer:tc(fun() -> quod_physics_native:install(R,Rows) end),
    {Retire,ok} = timer:tc(fun() -> quod_physics_native:retire(R) end),
    io:format("surface_motion bodies=16 vertices=144 triangles=242 install_us=~p query_us=~p unchanged_us=~p retire_us=~p rss_kb_after=~p~n",
        [Install,percentiles(Samples),Unchanged,Retire,Rss]).

dense(N) ->
    {ok,R} = quod_physics_native:new_world({N,N,N*N,1000.0,256,4096,4096},1/60,-9.81),
    Rows = [{I,1,dynamic,{{0.0,3.0,0.0},{0.0,0.0,0.0}},{solid,{box,0.5,0.5,0.5}},1.0} || I <- lists:seq(1,N)],
    {ok,N} = quod_physics_native:install(R,Rows),
    {Times,Contacts} = lists:unzip([begin
        {Us,{ok,{_,_,C}}} = timer:tc(fun() -> quod_physics_native:step(R,false) end),
        {Us,length(C)}
    end || _ <- lists:seq(1,20)]),
    ok = quod_physics_native:retire(R),
    io:format("dense_world bodies=~p step_us=~p max_contacts=~p~n",[N,percentiles(Times),lists:max(Contacts)]).

owner_death(N) ->
    Parent = self(),
    {Pid,M} = spawn_monitor(fun() ->
        {ok,R} = quod_physics_native:new_world({N,N,N*N,1000.0,256,4096,4096},1/60,-9.81),
        {ok,N} = quod_physics_native:install(R,bodies(N)),
        {ok,_} = quod_physics_native:step(R,false),
        Parent ! native_ready,
        %% Keep the only resource reference on the heap until external kill.
        receive inspect -> Parent ! quod_physics_native:sample(R) end
    end),
    receive native_ready -> ok end,
    Start = erlang:monotonic_time(microsecond),
    exit(Pid,kill),
    receive {'DOWN',M,process,Pid,killed} -> ok end,
    io:format("owner_kill_through_down_us bodies=~p elapsed=~p~n",[N,erlang:monotonic_time(microsecond)-Start]).

probe(_,0,_,Samples,_) -> Samples;
probe(Echo,Pending,Sent,Samples,Count) ->
    receive
        {bench,_,Result} ->
            io:format("concurrent_world ~p~n",[Result]),
            probe(Echo,Pending-1,Sent,Samples,Count);
        pong ->
            Now = erlang:monotonic_time(microsecond),
            Kept = case Count < 100000 of true -> [Now-Sent|Samples]; false -> Samples end,
            Echo ! {ping,self()},
            probe(Echo,Pending,Now,Kept,Count+1)
    end.

echo() -> receive {ping, From} -> From ! pong, echo(); stop -> ok end.
measure(N) -> io:format("world ~p~n", [work(N, 500)]).
work(N, Steps) ->
    {Create, {ok, Resource}} = timer:tc(fun() -> quod_physics_native:new_world({N,N,N*N,1000.0,256,4096,4096},1/60,-9.81) end),
    {Install, {ok, N}} = timer:tc(fun() -> quod_physics_native:install(Resource, bodies(N)) end),
    {ActiveTimes, IdleTimes, QueryTimes, MaxContacts} = fold(Resource, Steps, true, [], [], [], 0),
    Rss = rss_kb(),
    {Unchanged, {ok,0}} = timer:tc(fun() -> quod_physics_native:install(Resource,bodies(N)) end),
    {Retire, ok} = timer:tc(fun() -> quod_physics_native:retire(Resource) end),
    #{bodies => N, joints => 0, chunks => 0, steps => Steps, active_calls => length(ActiveTimes), rss_kb_after => Rss,
      max_contacts => MaxContacts, create_us => Create, install_us => Install,
      unchanged_us => Unchanged, retire_us => Retire,
      step_including_sample_us => percentiles(ActiveTimes), idle_call_us => percentiles(IdleTimes),
      query_us => percentiles(QueryTimes)}.
fold(_, 0, _, ST, IT, QT, C) -> {ST,IT,QT,C};
fold(R, N, WasActive, ST, IT, QT, C) ->
    {Step, {ok, {Awake, _, Contacts}}} = timer:tc(fun() -> quod_physics_native:step(R,false) end),
    {Query, {ok, _}} = timer:tc(fun() -> quod_physics_native:sample(R) end),
    case WasActive of
        true -> fold(R,N-1,Awake,[Step|ST],IT,[Query|QT],max(C,length(Contacts)));
        false -> fold(R,N-1,Awake,ST,[Step|IT],[Query|QT],max(C,length(Contacts)))
    end.
rss_kb() ->
    {ok,Status} = file:read_file("/proc/self/status"),
    {match,[Kb]} = re:run(Status,<<"VmRSS:\\s+(\\d+)">>,[{capture,[1],binary}]),
    binary_to_integer(Kb).
percentiles([]) -> none;
percentiles(Times) ->
    Sorted = lists:sort(Times), N = length(Sorted),
    #{p50 => lists:nth(ceil(N*0.50),Sorted),p95 => lists:nth(ceil(N*0.95),Sorted),
      p99 => lists:nth(ceil(N*0.99),Sorted),max => lists:last(Sorted)}.
bodies(N) ->
    [{0,1,fixed,{{0.0,-0.5,0.0},{0.0,0.0,0.0}},{solid,{box,30.0,0.5,30.0}},1.0} |
     [{I,1,dynamic,{{float((I-1) rem 8)-3.5,0.5+float((I-1) div 64),
                 float(((I-1) div 8) rem 8)-3.5},{0.0,0.0,0.0}},{solid,{box,0.49,0.49,0.49}},1.0}
      || I <- lists:seq(1,N-1)]].

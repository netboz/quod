-module(godot_m3b_physics_fixture).
-export([start/0]).
-define(P,quod_physics_tests).

%% Test-only authoring reuses the existing shared-domain and signed-view factory.
%% All source edits, native resources, contacts and lifecycle work are real owners.
start() -> ?P:with_live_source(<<"m3b-physical">>,fun(F=#{namespace:=Ns,source:=Source,node:=Node}) ->
    {S0,S1,S2,T1,T2,_}=?P:m3a_component_policy(F),
    {Human,Grant}=?P:m3a_scene_policy(F),
    Rendering= <<"physics-test-rendering">>,RA=quod_simplex:genesis_hash(Rendering),
    SourceAnchor=quod_simplex:genesis_hash(Source),
    ?P:commit(Source,{',',{assertz,{rendering_vocabulary,Rendering,RA}},
        {assertz,{can_invoke,{',',{current_ontology_identity,Source,SourceAnchor},{client_world_view,nested,playing,{'_'},{'_'}}},Human,{'_'},Source}}}),
    {Pid,World}=?P:enable(F),
    ?P:m3a_component_commit(Ns,{space_place,inner,0,S0}),
    ?P:m3a_component_commit(Source,{space_place,nested,0,S1}),
    ?P:m3a_component_commit(Source,{space_place,obstacle,0,S2}),
    ?P:await_structure(Ns,Pid,World,2),
    ?P:commit(Ns,{',',{assertz,{space_member,room,S2}},{assertz,{space_member,inner,maps:get(subject,F)}}}),
    {Independent,IndependentWorld}=?P:independent_world(Ns,Node),
    %% Select the existing controlled body for this exact signed viewer.
    {_,_,_,Watch,_}=?P:install_test_control(F#{node=>Human},Pid,World,
        {motion,free,2000,1600,1000,{query_limits,2,0,8,128},[]}),
    quod_physics:unwatch(Pid,Watch),
    ViewPose={pose,{vector,0,100,0},{rotation,0,0,0}},
    ?P:commit(Ns,{transaction,{',',{retract,{physics_viewpoint,room,pilot,eye,2,ViewPose,view_only}},
        {assertz,{physics_viewpoint,room,pilot,eye,2,{pose,{vector,0,100,0},{rotation,0,3142,0}},view_only}}}}),
    endpoint(F#{s0=>S0,s1=>S1,s2=>S2,t1=>T1,t2=>T2,viewer=>Human,
        world=>World,pid=>Pid,independent=>Independent,independent_world=>IndependentWorld,grant=>Grant})
end).

endpoint(F=#{directory:=Dir,identity:=Identity,viewer:=Human}) ->
    {ok,_}=application:ensure_all_started(ssl),{ok,_}=application:ensure_all_started(cowboy),
    {ok,Cursors}=quod_client_cursor:start_link(),unlink(Cursors),
    {ok,Tls}=quod_client_tls:ensure(Dir),
    ok=application:set_env(quod,identity_dir,Dir),
    ok=application:set_env(quod,client_enabled,true),ok=application:set_env(quod,client_ip,{127,0,0,1}),ok=application:set_env(quod,client_port,0),
    {ok,Client}=quod_client:start_link(),unlink(Client),
    Private=os:getenv("QUOD_M3B_PRIVATE"),
    ok=file:write_file(filename:join(Private,"backend-ca.pem"),public_key:pem_encode([{'Certificate',maps:get(cert,Tls),not_encrypted}])),
    Seed=element(3,maps:get(key,Identity)),
    Secret=#{private_jwk=>#{kty=><<"OKP">>,crv=><<"Ed25519">>,x=>b64(maps:get(pubkey,Identity)),d=>b64(Seed)}},
    ok=quod_file:write_atomic(filename:join(Private,"viewer.json"),json:encode(Secret),8#600),
    Metadata=#{viewer=>text(Human),s0=>text(maps:get(s0,F)),s1=>text(maps:get(s1,F)),s2=>text(maps:get(s2,F)),leaf=>text(maps:get(subject,F))},
    ok=file:write_file(filename:join(Private,"physics.json"),json:encode(Metadata)),
    {ok,Listener}=gen_tcp:listen(0,[binary,{packet,line},{active,false},{ip,{127,0,0,1}},{reuseaddr,true}]),
    {ok,{_,Port}}=inet:sockname(Listener),
    Worker=spawn_link(fun()->control(Listener,F) end),
    io:format("M1B_READY ~s~n",[json:encode(#{port=>ranch:get_port(quod_client_listener),control_port=>Port,network=>b64(<<42:256>>),physics=>true})]),
    try commands()
    after exit(Worker,shutdown),gen_tcp:close(Listener),catch gen_server:stop(Client),catch gen_server:stop(Cursors) end.

commands() -> case io:get_line("") of eof->ok;"stop\n"->ok;_->commands() end.
control(Listener,F) ->
    case gen_tcp:accept(Listener) of
        {ok,Socket}->
            {ok,Line}=gen_tcp:recv(Socket,0,30000),Command=json:decode(Line),
            Result=case Command of
                #{<<"measure">>:=true}->
                    Work=?P:observe_live_geometry_work(fun()->
                        ok=gen_tcp:send(Socket,<<"{\"ready\":true}\n">>),
                        {ok,<<"finish\n">>}=gen_tcp:recv(Socket,0,30000)
                    end),#{work=>?P:m3a_public_json(Work)};
                _->command(Command,F)
            end,
            ok=gen_tcp:send(Socket,[json:encode(Result),<<"\n">>]),gen_tcp:close(Socket),control(Listener,F);
        {error,closed}->ok
    end.
command(#{<<"sample">>:=true},F=#{namespace:=Ns,world:=World}) ->
    #{World:=#{pid:=Pid,spec:=Spec}}=?P:worlds(Ns),
    {ok,Frame,_}=quod_physics:snapshot(Pid,#{fence=>quod_physics:fence(Spec),structure=>maps:get(structure,Spec),incarnation=>maps:get(run_token,Spec),tick=>-1}),
    #{sample=>?P:m3a_public_json(maps:without([inputs,registration],Frame)),independent=>healthy(F)};
command(#{<<"mutate">>:=Change},F=#{namespace:=Ns,source:=Source,t1:=T1,t2:=T2,grant:=Grant}) ->
    {Target,Goal}=case Change of
        <<"source">>->{Source,{physics_edit_definition,obstacle,1,{geometry,{ball,600},1}}};
        <<"frame_update">>->{Source,{space_represent,nested,contents,T2,contents,{transform,-2100,3600,2500,53,71,127}}};
        <<"revoke">>->{Source,{'$quod_retract_exact',Grant}};
        <<"restore">>->{Source,{assertz,Grant}};
        <<"frame_fail">>->{Ns,{retract,{attribute,inner,transform,T1}}};
        <<"frame_repair">>->{Ns,{assertz,{attribute,inner,transform,T1}}}
    end,
    ?P:m3a_component_commit(Target,Goal),#{committed=>Change,independent=>healthy(F)};
command(#{<<"restart">>:=true},F=#{namespace:=Ns,world:=World}) ->
    true=quod_reg:subscribe({physics,Ns}),
    try
    #{World:=#{pid:=Pid,spec:=Prior}}=?P:worlds(Ns),Before=maps:get(generation,Prior),
    M=monitor(process,Pid),exit(Pid,kill),receive {'DOWN',M,process,Pid,_}->ok after 5000->error(owner_survived) end,
    {Next,World}=?P:installed_world(World),
    #{World:=#{spec:=Spec}}=?P:worlds(Ns),
    true=maps:get(generation,Spec)=:=Before+1,
    #{restarted=>true,independent=>healthy(F),pid=>list_to_binary(pid_to_list(Next))}
    after quod_reg:unsubscribe({physics,Ns}) end.
healthy(#{independent:=Pid,independent_world:=World,namespace:=Ns}) ->
    #{World:=#{pid:=Pid,spec:=Spec}}=?P:worlds(Ns),S=gen_server:call(Pid,status),
    #{pid=>list_to_binary(pid_to_list(Pid)),incarnation=>b64(maps:get(run_token,Spec)),installs=>maps:get(installs,S),steps=>maps:get(steps,S),tick=>maps:get(tick,S)}.
text(T)->quod_client_goal_parser:value_text(T).
b64(B)->base64:encode(B,#{mode=>urlsafe,padding=>false}).

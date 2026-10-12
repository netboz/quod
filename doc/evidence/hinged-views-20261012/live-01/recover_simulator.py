import sys,json,owner
ns,world,body,label=sys.argv[1:]
q='''Ns= <<"NAMESPACE">>,W=WORLD,B=BODY,World={world_ref,Ns,quod_simplex:genesis_hash(Ns),W},
true=quod_reg:subscribe({physics,Ns}),{Runtime,_}=quod_runtime:agents(Ns),
#{World:=#{pid:=Old,spec:=Before,stopping:=false}}=gen_server:call(Runtime,physics_worlds),
{ok,[#{'Cs':=Cs}],_}=quod_prolog:prove_ro(Ns,{findall,{'C'},{physics_checkpoint,W,{'C'}},{'Cs'}}),
{ok,[#{'Rs':=Rs}],_}=quod_prolog:prove_ro(Ns,{findall,{hinged_result,{'Result'},{'Request'}},{hinged_result,{'Result'},{'Request'}},{'Rs'}}),
Monitor=monitor(process,Old),exit(Old,kill),D=quod_time:mono_ms()+30000,
receive {'DOWN',Monitor,process,Old,killed}->ok after max(0,D-quod_time:mono_ms())->error(simulator_stop_deadline) end,
Wait=fun Again()->Current=gen_server:call(Runtime,physics_worlds),
 case maps:find(World,Current) of
 {ok,#{pid:=Pid,spec:=Spec,stopping:=false}} when Pid=/=Old ->
 case gen_server:call(Pid,status) of #{phase:=active,navigation_ready:=true}=Status->{Pid,Spec,Status};
 #{phase:={failed,Reason}}->error({recovery_failed,Reason});
 _->receive {physics_status,Runtime,_,World,_,_}->Again() after max(0,D-quod_time:mono_ms())->error(recovery_deadline) end end;
 _->receive {physics_status,Runtime,_,World,_,_}->Again() after max(0,D-quod_time:mono_ms())->error(recovery_deadline) end end end,
{Pid,Spec,Status}=Wait(),{ok,[#{'Cs':=Cs}],_}=quod_prolog:prove_ro(Ns,{findall,{'C'},{physics_checkpoint,W,{'C'}},{'Cs'}}),
{ok,[#{'Rs':=Rs}],_}=quod_prolog:prove_ro(Ns,{findall,{hinged_result,{'Result'},{'Request'}},{hinged_result,{'Result'},{'Request'}},{'Rs'}}),
{ok,Frame,Counters}=quod_physics:snapshot(Pid,#{fence=>quod_physics:fence(Spec),structure=>maps:get(structure,Spec),tick=> -1}),
Fmt=fun(T)->iolist_to_binary(io_lib:format("~0p",[T])) end,
#{height=>quod_prolog:applied(Ns),old_pid=>Fmt(Old),new_pid=>Fmt(Pid),before=>Fmt(Before),spec=>Fmt(Spec),status=>Fmt(Status),frame=>Fmt(Frame),counters=>Counters,checkpoints=>Fmt(Cs),consequences=>Fmt(Rs),checkpoint_unchanged=>true,consequences_unchanged=>true,recovered=>true}
'''.replace('NAMESPACE',ns).replace('WORLD',world).replace('BODY',body)
r=owner.read(label,q,read_only=False);print(json.dumps({k:r[k] for k in ['height','old_pid','new_pid','counters','checkpoints','consequences','recovered']}))

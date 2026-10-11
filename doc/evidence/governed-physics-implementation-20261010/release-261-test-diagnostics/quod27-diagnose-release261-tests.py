from pathlib import Path
import subprocess,os,json,hashlib,time
r=Path('/home/yan/src/quod');out=r/'_build/quod27-release-261/diagnostics-01';out.mkdir()
tree=r/'_build/quod27-release-261/gates-03/tree'
paths=[str(tree/'_build/test/lib/quod/test'),*[str(p) for p in sorted((tree/'_build/test/lib').glob('*/ebin'))]]
s=(r/'test/quod_e2e_tests.erl').read_text().replace('-module(quod_e2e_tests).','-module(quod_e2e_tests).\n-compile(export_all).')
(out/'quod_e2e_tests.erl').write_text(s)
s=(r/'test/quod_physics_tests.erl').read_text()
s=s.replace("receive {'DOWN',M,process,Worker,killed} -> ok after 5000 -> error(opening_not_cancelled) end,", "receive {'DOWN',M,process,Worker,Why} ->\n                io:format(user,\"OPENING_EXIT ~p~n\",[#{reason=>Why,worker=>Worker,state=>simulation_state(Socket)}]),\n                ?assertEqual(killed,Why)\n            after 5000 -> error({opening_not_cancelled,process_info(Worker,[status,current_function,messages]),process_info(self(),messages),simulation_state(Socket)}) end,")
(out/'quod_physics_tests.erl').write_text(s)
(out/'source-sha256.json').write_text(json.dumps({p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in out.glob('*.erl')},indent=2))
env=dict(os.environ,PATH='/home/yan/.asdf/shims:'+os.environ['PATH'],ERL_FLAGS='+S 4:4 +SDio 2 +SDcpu 2')
args=['erlc','-DTEST','-I',str(r/'include'),'-o',str(out),*[v for p in paths for v in ['-pa',p]],str(out/'quod_e2e_tests.erl'),str(out/'quod_physics_tests.erl')]
with (out/'compile.log').open('xb') as log:q=subprocess.run(args,env=env,stdout=log,stderr=subprocess.STDOUT)
assert q.returncode==0
expressions=[('foreign-stop', '''Ctx={Dir,Ns,Cfg}=quod_e2e_tests:setup(),Parent=self(),
{Owner,OM}=spawn_monitor(fun()->Pid=quod_e2e_tests:start_ns(Ns,Cfg),Parent!{started,Pid},receive done->ok end end),
receive {started,Pid}->
 T=erlang:monotonic_time(millisecond),quod_e2e_tests:stop_ns(Pid),
 Alive=is_process_alive(Pid),io:format("FOREIGN_STOP ~p~n",[#{alive_after_stop=>Alive,elapsed=>erlang:monotonic_time(millisecond)-T,registered=>quod_reg:where({quod_ns,Ns})=:=Pid}]),
 gen_server:stop(Pid,shutdown,5000),false=is_process_alive(Pid),Owner!done,
 receive {'DOWN',OM,process,Owner,normal}->ok end,quod_e2e_tests:cleanup(Ctx),
 case Alive of true->halt(0);false->halt(2) end
end.'''),('opening-cancellation', "case eunit:test([quod_physics_tests:opening_worker_cancellation_test_() || _ <- lists:seq(1,20)],[verbose]) of ok -> halt(0); _ -> halt(1) end.")]
for name,expr in expressions:
 start=time.monotonic()
 with (out/(name+'.log')).open('xb') as log:q=subprocess.run(['erl','-noshell','-pa',*paths,'-pa',str(out),'-eval',expr],env=env,stdout=log,stderr=subprocess.STDOUT)
 rec={'exit':q.returncode,'seconds':time.monotonic()-start,'diagnostic':name};(out/(name+'.json')).write_text(json.dumps(rec,indent=2));print(json.dumps(rec),flush=True)

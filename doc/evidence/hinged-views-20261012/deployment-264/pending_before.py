from pathlib import Path
import json,base64,subprocess
p=Path(__file__).resolve().parent;a=next(a for a in json.loads((p/'allocations-before.json').read_text()) if a['Name'].endswith('[0]') and a['DesiredStatus']=='run')
expr="""
Fmt=fun(T)->iolist_to_binary(io_lib:format("~0p",[T])) end,
Rows=[begin
 {ok,[#{'W':=W,'C':=Custody,'G':=G}],_}=quod_prolog:prove_ro(Ns,
   {',',{physics_space,{'W'},enabled,{'_'}},{',',{physics_custody,{'W'},{'C'}},{physics_run,{'W'},{'G'},{'_'}}}}),
 {Runtime,_}=quod_runtime:agents(Ns),World={world_ref,Ns,quod_simplex:genesis_hash(Ns),W},
 #{World:=#{pid:=Pid,spec:=Spec,stopping:=false}}=gen_server:call(Runtime,physics_worlds),
 Status=gen_server:call(Pid,status),active=maps:get(phase,Status),
 []=maps:get(hinges,Spec),[]=maps:get(restores,Spec),
 {request,_,Before,Bytes,Sig}=Custody,G=Before+1,
 Outcome=quod_client_goal_ingress:resolve_operation(Bytes,Sig),
 #{namespace=>Ns,world=>Fmt(World),generation=>G,phase=>active,
   original_operation_sha256=>binary:encode_hex(crypto:hash(sha256,Bytes)),original_outcome=>Fmt(Outcome),
   status=>Fmt(Status),spec=>Fmt(Spec),runtime_stats=>quod_runtime:stats(Ns),
   no_hinge_or_rest_checkpoint_inputs=>true}
 end || Ns <- [<<"human:5pU3X8evhfH09g1ctl0LRRP80zmhd6M7g8OQ7DyOeaE/lobby">>,<<"acceptance:physics:259:04:gallery">>]],
#{rows=>Rows,read_only=>true}
"""
command=['nomad','alloc','exec','-i=false','-t=false','-address=http://192.168.1.10:4646','-task','quod',a['ID'],'/opt/quod/bin/quod','eval','binary_to_list(base64:encode(iolist_to_binary(json:encode(try begin '+expr+' end catch C:R -> #{error=>iolist_to_binary(io_lib:format("~0p",[{C,R}]))} end)))).']
r=subprocess.run(command,capture_output=True,text=True,timeout=90)
for suffix,text in [('stdout',r.stdout),('stderr',r.stderr)]: (p/('pending-before.'+suffix)).write_text(text)
(p/'pending-before.exit.json').write_text(json.dumps({'exit':r.returncode,'expression':expr,'read_only':True})+'\n');assert r.returncode==0
wire=json.loads(r.stdout);wire=bytes(wire).decode() if isinstance(wire,list) else wire
answer=json.loads(base64.b64decode(wire));(p/'pending-before.json').write_text(json.dumps(answer,indent=2)+'\n');assert answer.get('read_only'),answer
for row in answer['rows']:
 assert 'operation_outcome' in row['original_outcome'] and 'committed' in row['original_outcome'],row
 print(json.dumps({k:row[k] for k in ['namespace','generation','phase','no_hinge_or_rest_checkpoint_inputs']}))

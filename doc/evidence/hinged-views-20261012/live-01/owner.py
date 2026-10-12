from pathlib import Path
import base64,json,subprocess,datetime
p=Path(__file__).resolve().parent;dep=p.parent/'release-264/deployment'
fleet=json.loads((dep/'fleet-probe.json').read_text());allocation=next(r['allocation'] for r in fleet['allocations'] if r['name'].endswith('[0]'))
def read(label,expression,read_only=True):
 q='binary_to_list(base64:encode(iolist_to_binary(json:encode(try begin '+expression+' end catch EvidenceClass:EvidenceReason -> #{error=>iolist_to_binary(io_lib:format("~0p",[{EvidenceClass,EvidenceReason}]))} end)))).'
 with (p/(label+'.owner-intent.json')).open('x') as f:json.dump({'expression':expression,'read_only':read_only,'started':datetime.datetime.now(datetime.timezone.utc).isoformat()},f,indent=2)
 r=subprocess.run(['nomad','alloc','exec','-i=false','-t=false','-address=http://192.168.1.10:4646','-task','quod',allocation,'/opt/quod/bin/quod','eval',q],capture_output=True,text=True,timeout=90)
 for ext,value in [('stdout',r.stdout),('stderr',r.stderr)]:
  with (p/(label+'.owner-'+ext)).open('x') as f:f.write(value)
 with (p/(label+'.owner-exit.json')).open('x') as f:json.dump({'exit':r.returncode},f)
 assert r.returncode==0,r.stderr
 w=json.loads(r.stdout)
 if isinstance(w,list):w=bytes(w).decode()
 a=json.loads(base64.b64decode(w))
 with (p/(label+'.owner.json')).open('x') as f:json.dump(a,f,indent=2)
 assert 'error' not in a,a
 return a
def inactive(label,ns):
 return read(label,'Ns= <<"'+ns+'">>,H=quod_prolog:applied(Ns),D=quod_time:mono_ms()+15000,ok=quod_runtime:reconcile_resource(Ns,H,agent_hosts,all,D),ok=quod_runtime:reconcile_resource(Ns,H,physics_worlds,all,D),{Owner,[]}=quod_runtime:agents(Ns),0=map_size(gen_server:call(Owner,physics_worlds)),Fmt=fun(T)->iolist_to_binary(io_lib:format("~0p",[T])) end,{ok,[#{\'Bs\':=Bs}],_}=quod_prolog:prove_ro(Ns,{findall,{physics_body_definition,{\'_W\'},{\'_B\'},{\'_R\'},{\'_K\'},{\'_P\'},{\'_D\'}},{physics_body_definition,{\'_W\'},{\'_B\'},{\'_R\'},{\'_K\'},{\'_P\'},{\'_D\'}},{\'Bs\'}}),#{height=>H,anchor=>binary:encode_hex(quod_simplex:genesis_hash(Ns)),bodies=>Fmt(Bs),inactive=>true,stats=>quod_runtime:stats(Ns)}')

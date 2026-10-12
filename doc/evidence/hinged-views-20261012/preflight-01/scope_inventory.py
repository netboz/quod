from pathlib import Path
import json,base64,subprocess,datetime
p=Path(__file__).resolve().parent
allocs=json.loads((p/'allocations.json').read_text());rows=[]
expression="""
F=fun(T)->iolist_to_binary(io_lib:format("~0p",[T])) end,
Query={',',{findall,{space,{'W'},{'M'},{'I'}},{physics_space,{'W'},{'M'},{'I'}},{'Spaces'}},
 {',',{findall,{door,{'W'},{'D'},{'S'},{'T'}},{physics_door,{'W'},{'D'},{'S'},{'T'}},{'Doors'}},
 {',',{findall,{rest,{'W'},{'D'},{'S'},{'T'}},{physics_rest,{'W'},{'D'},{'S'},{'T'}},{'Rests'}},
 {',',{findall,{'C'},{physics_checkpoint,{'W'},{'C'}},{'Checkpoints'}},
 {findall,{'J'},{physics_joint,{'W'},{'J'}},{'Joints'}}}}},
Scopes=[begin {ok,[Result],_}=quod_prolog:prove_ro(Ns,Query),
  #{namespace=>Ns,height=>quod_prolog:applied(Ns),anchor=>binary:encode_hex(quod_simplex:genesis_hash(Ns)),
    spaces=>F(maps:get('Spaces',Result)),doors=>F(maps:get('Doors',Result)),rests=>F(maps:get('Rests',Result)),
    checkpoints=>F(maps:get('Checkpoints',Result)),joints=>F(maps:get('Joints',Result))}
 end || Ns <- lists:sort(quod_simplex:namespaces())],
#{version=>list_to_binary(element(2,application:get_key(quod,vsn))),scopes=>Scopes}
"""
for a in sorted([a for a in allocs if a['DesiredStatus']=='run' and a['ClientStatus']=='running'],key=lambda a:a['Name']):
 label=a['Name'].rsplit('[',1)[1].rstrip(']')
 command=['nomad','alloc','exec','-i=false','-t=false','-address=http://192.168.1.10:4646','-task','quod',a['ID'],'/opt/quod/bin/quod','eval','binary_to_list(base64:encode(iolist_to_binary(json:encode(begin '+expression+' end)))).']
 r=subprocess.run(command,capture_output=True,text=True,timeout=90)
 for suffix,content in [('stdout',r.stdout),('stderr',r.stderr)]:
  (p/('scope-'+label+'.'+suffix)).write_text(content)
 (p/('scope-'+label+'.exit.json')).write_text(json.dumps({'child_exit':r.returncode,'read_only':True,'expression':expression})+'\n')
 assert r.returncode==0,(label,r.stderr)
 wire=json.loads(r.stdout);wire=bytes(wire).decode() if isinstance(wire,list) else wire
 answer=json.loads(base64.b64decode(wire));(p/('scope-'+label+'.json')).write_text(json.dumps(answer,indent=2)+'\n')
 physical=[s for s in answer['scopes'] if s['spaces']!='[]']
 print(label,[(s['namespace'],s['spaces'],s['doors'],s['rests'],s['checkpoints'],s['joints']) for s in physical],flush=True)
 rows.append({'allocation':a['ID'],'node':a['Name'],'physical':physical})
(p/'scope-inventory.json').write_text(json.dumps({'captured':datetime.datetime.now(datetime.timezone.utc).isoformat(),'rows':rows,'read_only':True},indent=2)+'\n')

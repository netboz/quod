from pathlib import Path
import base64, datetime, json, subprocess

p=Path(__file__).resolve().parent
base=json.loads((p.parents[1]/'quod27-personal-259-01/baseline.json').read_text())
fleet=json.loads((p/'fleet-probe.json').read_text())
assert fleet['passed']
allocation=next(r['allocation'] for r in fleet['allocations'] if r['name'].endswith('[0]'))
world=base['dependencies'][1]
ns=world['ns']; anchor=world['anchor_hex']
expression='''
Ns = <<"NAMESPACE">>, Anchor=binary:decode_hex(<<"ANCHOR">>),
World={world_ref,Ns,Anchor,personal_lobby},
true=quod_reg:subscribe({physics,Ns}),
D=quod_time:mono_ms()+15000,
{Owner,_}=quod_runtime:agents(Ns),
Wait=fun Again() ->
  Current=gen_server:call(Owner,physics_worlds),
  case maps:find(World,Current) of
    {ok,#{pid:=Pid,stopping:=false,spec:=Spec}} ->
      Status=gen_server:call(Pid,status),
      case Status of
        #{phase:=active,navigation_ready:=true} -> {Pid,Spec,Status};
        #{phase:={failed,R}} -> error({installation_failed,R});
        _ ->
          Remaining=max(0,D-quod_time:mono_ms()),
          receive {physics_status,Owner,_,World,_,_} -> Again()
          after Remaining -> error({installation_deadline,Status}) end
      end;
    _ ->
      Remaining=max(0,D-quod_time:mono_ms()),
      receive {physics_status,Owner,_,World,_,_} -> Again()
      after Remaining -> error({installation_deadline,Current}) end
  end
end,
{Pid,Spec,Status}=Wait(),
F=quod_physics:fence(Spec), Structure=maps:get(structure,Spec),
{ok,Frame,Counters}=quod_physics:snapshot(Pid,#{fence=>F,structure=>Structure,tick=>-1}),
Fmt=fun(T)->iolist_to_binary(io_lib:format("~0p",[T])) end,
#{world=>Fmt(World),runtime_owner=>Fmt(Owner),physics_owner=>Fmt(Pid),
  height=>quod_prolog:applied(Ns),phase=>active,navigation_ready=>true,
  structure=>Structure,fence=>Fmt(F),spec=>Fmt(Spec),status=>Fmt(Status),
  frame=>Fmt(Frame),counters=>Counters,runtime_stats=>quod_runtime:stats(Ns)}
'''.replace('NAMESPACE',ns).replace('ANCHOR',anchor)

command=['nomad','alloc','exec','-i=false','-t=false','-address=http://scheduler.internal:4646','-task','quod',
 allocation,'/opt/quod/bin/quod','eval',
 'binary_to_list(base64:encode(iolist_to_binary(json:encode(try begin '+expression+
 ' end catch C:R -> #{error=>iolist_to_binary(io_lib:format("~0p",[{C,R}]))} end)))).']
start=datetime.datetime.now(datetime.timezone.utc).isoformat()
with (p/'personal-owner-after.intent.json').open('x') as f:
 json.dump({'started':start,'expression':expression,'read_only':True},f,indent=2)
r=subprocess.run(command,capture_output=True,text=True)
for suffix,text in [('stdout',r.stdout),('stderr',r.stderr)]:
 with (p/('personal-owner-after.'+suffix)).open('x') as f:f.write(text)
with (p/'personal-owner-after.exit.json').open('x') as f:json.dump({'exit':r.returncode},f)
assert r.returncode==0,r.stderr
wire=json.loads(r.stdout)
if isinstance(wire,list):wire=bytes(wire).decode()
answer=json.loads(base64.b64decode(wire))
with (p/'personal-owner-after.json').open('x') as f:json.dump(answer,f,indent=2)
assert answer.get('phase')=='active' and answer.get('navigation_ready'),answer
print(json.dumps({k:answer[k] for k in ['height','phase','navigation_ready','structure','physics_owner','counters']}))

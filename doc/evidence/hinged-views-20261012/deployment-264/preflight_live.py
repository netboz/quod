from pathlib import Path
import datetime,json,ssl,urllib.request,urllib.parse,hashlib
p=Path(__file__).resolve().parent;ctx=ssl._create_unverified_context();address='http://192.168.1.10:4646';origin='https://192.168.1.10:30519';job='quod-finality-candidate-v6-20260926'
def get(base,path):
 with urllib.request.urlopen(base+path,context=ctx,timeout=30) as r:return json.load(r)
def save(name,value):
 with (p/name).open('x') as f:json.dump(value,f,indent=2);f.write('\n')
candidate=get(address,'/v1/job/'+job);main=get(address,'/v1/job/quod');ingress=get(address,'/v1/job/quod27-client-30519');allocs=get(address,'/v1/job/'+job+'/allocations')
assert (candidate['Version'],candidate['JobModifyIndex'])==(71,847862)
assert (main['Version'],main['JobModifyIndex'])==(246,826727)
assert (ingress['Version'],ingress['JobModifyIndex'])==(1,846370)
prior=Path('/home/yan/src/quod/_build/quod27-release-263/deployment')
fleet=json.loads((prior/'fleet-probe.json').read_text());active=[a for a in allocs if a['DesiredStatus']=='run' and a['ClientStatus']=='running']
assert len(active)==8 and {a['ID'] for a in active}=={a['allocation'] for a in fleet['allocations']}
assert all(a['TaskStates']['quod']['Restarts']==0 for a in active)
family=candidate['TaskGroups'][0]['Volumes']['quod-data']['Source'];vols=[v for v in get(address,'/v1/volumes?type=host') if v['Name'].startswith(family+'[')]
oldvols=json.loads((prior/'volume-placement-before.json').read_text());assert {(v['ID'],v['Name'],v['NodeID']) for v in vols}=={(v['ID'],v['Name'],v['NodeID']) for v in oldvols}
for name,value in [('candidate-before.json',candidate),('main-before.json',main),('ingress-before.json',ingress),('allocations-before.json',allocs),('volume-placement-before.json',vols)]:save(name,value)
summary=get(origin,'/explorer/api/summary');save('history-summary-before.json',summary);checks=[]
ns='human:5pU3X8evhfH09g1ctl0LRRP80zmhd6M7g8OQ7DyOeaE'
for label,namespace,expected_anchor,prefix in [('human',ns,'758f8aa13d54cf626ba493a6bfbec24548ac96b49dd0feda3bc0843e0838cbf2',350),('world',ns+'/lobby','7082c150269e5b82754c06cb7928f6e55ffbcedabd25e642c2ccf874a3a6f77f',176)]:
 row=next(r for r in summary['namespaces'] if r['ns']==namespace);assert row['genesis']==expected_anchor and not row['syncing'];height=row['applied']
 for suffix,slot in [('tip',height),('retained-prefix',prefix)]:
  name=label+'-'+suffix+'-before.json';block=get(origin,'/explorer/api/block/'+urllib.parse.quote(namespace,safe='')+'/'+str(slot));save(name,block)
  if slot==prefix:assert block==json.loads((prior/name).read_text())
  checks.append({'file':name,'namespace':namespace,'height':slot,'anchor':expected_anchor,'sha256':hashlib.sha256((p/name).read_bytes()).hexdigest()})
save('history-before.json',{'captured':datetime.datetime.now(datetime.timezone.utc).isoformat(),'origin':origin,'blocks':checks,'read_only':True})
save('preflight-live.json',{'captured':datetime.datetime.now(datetime.timezone.utc).isoformat(),'version':71,'index':847862,'healthy':8,'zero_restarts':True,'same_volumes':True,'read_only':True})
print(json.dumps({'version':71,'index':847862,'allocations':8,'history':[(c['namespace'],c['height']) for c in checks]}))

"""Freeze the exact candidate maintenance/release/rollback bodies; no network writes."""
from pathlib import Path
import copy,hashlib,json
b=Path(__file__).resolve().parent
before=json.loads((b/'candidate-before.json').read_text())
image=json.loads((b/'verified-image.json').read_text())['pinned_image']
assert before['ID']=='candidate-job'
assert before['Version']==65 and before['JobModifyIndex']==846336
assert image.startswith('registry.internal:5000/quod:0.7.261@sha256:')
old='registry.internal:5000/quod:0.7.260@sha256:OLD_IMAGE_DIGEST'
maintenance=copy.deepcopy(before);release=copy.deepcopy(before)
for g in maintenance['TaskGroups']:g['Count']=0
changes=[]
for gi,g in enumerate(release['TaskGroups']):
 for ti,t in enumerate(g['Tasks']):
  if t.get('Config',{}).get('image','').startswith('registry.internal:5000/quod:'):
   assert t['Config']['image']==old
   t['Config']['image']=image;changes.append(f'/TaskGroups/{gi}/Tasks/{ti}/Config/image')
assert len(changes)==5
assert {g['Name']:g['Count'] for g in release['TaskGroups']}=={'quod-node':8,'quod-cloud':0}
def diff(a,c,path=''):
 if type(a)!=type(c):return [{'path':path,'before':a,'after':c}]
 if isinstance(a,dict):
  assert a.keys()==c.keys(),path
  return [d for k in a for d in diff(a[k],c[k],path+'/'+k)]
 if isinstance(a,list):
  assert len(a)==len(c),path
  return [d for i in range(len(a)) for d in diff(a[i],c[i],path+'/'+str(i))]
 return [] if a==c else [{'path':path,'before':a,'after':c}]
for name,job in [('candidate-maintenance',maintenance),('candidate-release',release),('candidate-rollback',before)]:
 with (b/(name+'.json')).open('x') as out:json.dump(job,out,indent=2);out.write('\n')
record={'maintenance_from_v65':diff(before,maintenance),'release_from_v65':diff(before,release),'release_from_maintenance':diff(maintenance,release)}
assert record['maintenance_from_v65']==[{'path':'/TaskGroups/0/Count','before':8,'after':0}]
assert [x['path'] for x in record['release_from_v65']]==changes
(b/'candidate-exact-diff.json').write_text(json.dumps(record,indent=2)+'\n')
files=['candidate-before.json','candidate-maintenance.json','candidate-release.json','candidate-rollback.json','ingress-before.json','candidate-exact-diff.json','verified-image.json',
       'prepare_candidate.py','mutate_once.py','fleet_probe.py','fleet-expression.txt',
       'personal_owner_after.py','history_after.py','allocations-before.json','volume-placement-before.json',
       'client-certificate-before.json','history-before.json','human-tip-before.json','world-tip-before.json','history_before.py','human-retained-prefix-before.json','world-retained-prefix-before.json','history-summary-before.json']
(b/'mutation-inputs.json').write_text(json.dumps({n:hashlib.sha256((b/n).read_bytes()).hexdigest() for n in files},indent=2)+'\n')
print(json.dumps(record,indent=2))

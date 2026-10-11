"""Read the deployed candidate through its real owners and retained identities."""
from pathlib import Path
import base64,json,subprocess,time,urllib.request
b=Path(__file__).resolve().parent
address='http://192.168.1.10:4646';job='quod-finality-candidate-v6-20260926'
def get(path):
 with urllib.request.urlopen(address+path,timeout=30) as response:return json.load(response)
release=json.loads((b/'release/PASSED.json').read_text())
assert release['passed']
before=json.loads((b/'candidate-before.json').read_text())
old=json.loads((b.parents[1]/'quod27-release-261/deployment/fleet-probe.json').read_text())
old_by_name={r['name']:r for r in old['allocations']}
image=json.loads((b/'verified-image.json').read_text())['pinned_image']
candidate=get('/v1/job/'+job);main=get('/v1/job/quod')
assert candidate['Version']==release['job_version'] and candidate['JobModifyIndex']==release['job_modify_index']
assert main['Version']==246 and main['JobModifyIndex']==826727
allocs=[a for a in get('/v1/job/'+job+'/allocations') if a['ClientStatus']=='running' and a['DesiredStatus']=='run']
assert len(allocs)==8 and {a['Name'] for a in allocs}==set(old_by_name)
assert all(a['JobVersion']==candidate['Version'] for a in allocs)
for previous,current in zip(before['TaskGroups'],candidate['TaskGroups']):
 assert previous['Name']==current['Name'] and previous['Volumes']==current['Volumes']
volumes=json.loads((b/'volume-placement-before.json').read_text())
by_name={v['Name']:v for v in volumes}
for a in allocs:
 index=a['Name'].rsplit('[',1)[1]
 expected=by_name[before['TaskGroups'][0]['Volumes']['quod-data']['Source']+'['+index]
 assert a['NodeID']==expected['NodeID']
expression=(b/'fleet-expression.txt').read_text().strip()
encoded='binary_to_list(base64:encode(iolist_to_binary(json:encode(begin '+expression+' end)))).'
rows=[];started=time.monotonic()
for a in sorted(allocs,key=lambda a:a['Name']):
 command=['nomad','alloc','exec','-i=false','-t=false','-address='+address,'-task','quod',a['ID'],'/opt/quod/bin/quod','eval',encoded]
 result=subprocess.run(command,capture_output=True,text=True,timeout=90)
 row={'allocation':a['ID'],'name':a['Name'],'node':a['NodeName'],'node_id':a['NodeID'],'restarts':a['TaskStates']['quod']['Restarts'],'exit':result.returncode}
 if result.returncode:row['stderr']=result.stderr
 else:
  wire=json.loads(result.stdout)
  if isinstance(wire,list):wire=bytes(wire).decode('ascii')
  row['probe']=json.loads(base64.b64decode(wire,validate=True))
 rows.append(row);print(json.dumps(row),flush=True)
document={'passed':False,'job':job,'job_version':candidate['Version'],'job_modify_index':candidate['JobModifyIndex'],'image':image,'allocations':rows,'seconds':time.monotonic()-started,'main_job':{'version':main['Version'],'job_modify_index':main['JobModifyIndex']}}
with (b/'fleet-probe.json').open('x') as out:json.dump(document,out,indent=2);out.write('\n')
for row in rows:
 assert row['exit']==0 and row['restarts']==0
 p=row['probe'];prior=old_by_name[row['name']]['probe']
 assert p['version']=='0.7.262' and p['root_anchor']==prior['root_anchor']
 assert p['custody_limits']=={'count':64,'prepared_bytes':'unlimited'}
 assert p['root_state']=='ready' and p['root_committed']==p['root_applied']
 assert p['root_committee_size']==1
 assert p['catalogue_count']==18 and p['rejected_count']==0 and p['not_ready']==[]
 assert p['vault_ready'] and p['vault_provider_disabled']
 assert p['manager']['node_enrollment']=='complete'
 assert p['principal']==prior['principal'],(row['name'],p['principal'],prior['principal'])
document['passed']=True
(b/'fleet-probe.json').write_text(json.dumps(document,indent=2)+'\n')

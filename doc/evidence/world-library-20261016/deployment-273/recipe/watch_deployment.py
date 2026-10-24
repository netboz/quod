from pathlib import Path
import json,time,urllib.request
out=Path('/home/yan/src/quod/_build/world-library-20261016/deployment-02/refound')
scope=json.loads((out/'scope.json').read_text())
address='http://192.168.1.10:4646'
def get(path):
 with urllib.request.urlopen(address+path,timeout=40) as response:
  return json.load(response),response.headers.get('X-Nomad-Index','0')
deployments,_=get('/v1/job/'+scope['job']+'/deployments')
latest=[d for d in deployments if d['JobVersion']==scope['candidate_version']+2]
assert len(latest)==1,latest
deployment_id=latest[0]['ID'];index='0';deadline=time.monotonic()+1200
events=[]
while time.monotonic()<deadline:
 d,index=get('/v1/deployment/'+deployment_id+'?index='+index+'&wait=30s')
 events.append(d);(out/'deployment-events.json').write_text(json.dumps(events,indent=2)+'\n')
 print(json.dumps({'id':deployment_id,'status':d['Status'],'groups':d['TaskGroups']}),flush=True)
 if d['Status']=='successful':
  assert d['TaskGroups']['quod-node']['HealthyAllocs']==8
  (out/'deployment-success.json').write_text(json.dumps(d,indent=2)+'\n')
  break
 if d['Status'] in ('failed','cancelled','blocked'):
  raise RuntimeError('Deployment stopped: '+d['StatusDescription'])
else: raise RuntimeError('Deployment did not become successful by its deadline')

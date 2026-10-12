"""One reviewed Nomad CAS mutation, then indexed observation; never resubmit."""
from pathlib import Path
import datetime,hashlib,json,socket,sys,time,urllib.error,urllib.request
b=Path(__file__).resolve().parent
address='http://192.168.1.10:4646'; candidate='quod-finality-candidate-v6-20260926'
phase=sys.argv[1]
phases={'maintenance':('candidate-maintenance.json','candidate-before.json',{'quod-node':{'Stop':8}}),
 'release':('candidate-release.json','maintenance/job-after.json',{'quod-node':{'Place':8}})}
assert phase in phases
clearance=json.loads((b/'review-clearance.json').read_text())
assert clearance['approved'] and clearance['mutation_manifest_sha256']==hashlib.sha256((b/'mutation-inputs.json').read_bytes()).hexdigest()
for name,digest in json.loads((b/'mutation-inputs.json').read_text()).items():
 assert hashlib.sha256((b/name).read_bytes()).hexdigest()==digest,name
assert json.loads((b.parent/'gates-01/PASSED.json').read_text())['passed']
assert json.loads((b/'committed-inputs.json').read_text())['all_inputs_match']
name,predecessor,expected_updates=phases[phase];desired=json.loads((b/name).read_text()); jobid=desired['ID']
expected=json.loads((b/predecessor).read_text()) if predecessor else None
if phase=='release':assert json.loads((b/'maintenance/PASSED.json').read_text())['passed']
out=b/phase;out.mkdir()
def save(name,value):
 with (out/name).open('x') as f:json.dump(value,f,indent=2);f.write('\n')
def request(path,data=None,timeout=40):
 req=urllib.request.Request(address+path,data=None if data is None else json.dumps(data).encode(),headers={'Content-Type':'application/json'})
 with urllib.request.urlopen(req,timeout=timeout) as response:return json.load(response),response.headers.get('X-Nomad-Index','0')
def get_job(jid):
 try:return request('/v1/job/'+jid)[0]
 except urllib.error.HTTPError as e:
  if e.code==404:return None
  raise
def unchanged_main():
 main=get_job('quod');assert main['Version']==246 and main['JobModifyIndex']==826727
 ingress=get_job('quod27-client-30519'); prior=json.loads((b/'ingress-before.json').read_text())
 assert ingress==prior, 'Stable ingress changed'
 return {'version':main['Version'],'job_modify_index':main['JobModifyIndex'],'ingress_unchanged':True}
server_fields={'CreateIndex','ModifyIndex','JobModifyIndex','Version','SubmitTime','Status','StatusDescription','Stable'}
def semantic(j):return {k:v for k,v in j.items() if k not in server_fields}
def confirms_desired(current,filename):
 if current is None:return False
 confirmation,_=request('/v1/job/'+jobid+'/plan',{'Job':desired,'Diff':True})
 save(filename,confirmation)
 return (confirmation['JobModifyIndex']==current['JobModifyIndex']
         and confirmation['Diff']['Type']=='None'
         and not confirmation.get('FailedTGAllocs') and not confirmation.get('Warnings'))
def check_before():
 current=get_job(jobid)
 if expected is None:assert current is None
 else:
  assert current['JobModifyIndex']==expected['JobModifyIndex']
  assert semantic(current)==semantic(expected)
 unchanged_main()
 return current
before=check_before();index=0 if before is None else before['JobModifyIndex'];version=0 if before is None else before['Version']+1
plan,_=request('/v1/job/'+jobid+'/plan',{'Job':desired,'Diff':True});save('plan.json',plan)
assert plan['JobModifyIndex']==index and not plan.get('FailedTGAllocs'),plan.get('FailedTGAllocs')
assert not plan.get('Warnings'),plan.get('Warnings')
updates=plan['Annotations']['DesiredTGUpdates']
for group,counts in updates.items():
 actual={k:v for k,v in counts.items() if v and k!='Ignore'}
 assert actual==expected_updates.get(group,{}),(group,actual,expected_updates)
assert all(g in updates for g in expected_updates)
check_before()
payload={'Job':desired,'EnforceIndex':True,'JobModifyIndex':index}
save('request.json',payload)
save('intent.json',{'at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'phase':phase,'job':jobid,'expected_index':index,'expected_version':version,'request_sha256':hashlib.sha256((out/'request.json').read_bytes()).hexdigest()})
try:
 response,_=request('/v1/jobs',payload);save('submission.json',response)
except Exception as e:
 # A lost response leaves an unknown operation. Inspect only this original
 # job/index; continuation requires recording its exact accepted identity.
 uncertain={'error_type':type(e).__name__}
 try:
  current=get_job(jobid)
  uncertain.update({'job_version':None if current is None else current['Version'],'job_modify_index':None if current is None else current['JobModifyIndex']})
  uncertain['matches_submitted']=confirms_desired(current,'uncertain-plan.json')
 except Exception as observation_error:
  uncertain['observation_error_type']=type(observation_error).__name__
 save('uncertain.json',uncertain)
 raise
current=get_job(jobid);save('job-after.json',current)
assert current['Version']==version and current['JobModifyIndex']==response['JobModifyIndex']
assert confirms_desired(current,'plan-after.json')
print(json.dumps({'phase':phase,'version':version,'evaluation':response['EvalID']}),flush=True)
# Every observation follows Nomad's blocking index and one absolute deadline.
deadline=time.monotonic()+1200;watch='0';events=[]
path='/v1/job/'+jobid+('/allocations?all=true' if phase=='maintenance' else '/deployments?all=true')
while time.monotonic()<deadline:
 rows,watch=request(path+'&index='+watch+'&wait=30s',timeout=min(40,max(1,deadline-time.monotonic())))
 if phase=='maintenance':
  required={a['ID'] for a in json.loads((b/'allocations-before.json').read_text()) if a['DesiredStatus']=='run' and a['ClientStatus']=='running'}
  selected=[a for a in rows if a['ID'] in required]
  assert len(required)==8 and len(selected)==8
  active=[a for a in selected if a['ClientStatus']!='complete' or a['DesiredStatus']!='stop']
  state={'remaining':[{'id':a['ID'],'desired':a['DesiredStatus'],'client':a['ClientStatus']} for a in active]}
  done=not active
 else:
  matches=[d for d in rows if d['JobVersion']==version]
  assert len(matches)<=1
  state=matches[0] if matches else {'awaiting_job_version':version}
  assert state.get('Status') not in ('failed','cancelled','blocked'),state
  done=state.get('Status')=='successful'
 events.append(state);(out/'events.json').write_text(json.dumps(events,indent=2)+'\n')
 print(json.dumps({'phase':phase,'status':state.get('Status'),'remaining':len(state.get('remaining',[]))}),flush=True)
 if done:
  save('PASSED.json',{'passed':True,'job_version':version,'job_modify_index':current['JobModifyIndex'],'state':state,'main_job':unchanged_main()})
  break
else:raise RuntimeError('Original deployment did not finish within its absolute deadline')

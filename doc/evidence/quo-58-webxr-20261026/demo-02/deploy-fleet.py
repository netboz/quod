"""Campaign-specific candidate refounding, with write-once intents and Nomad CAS.

Each mutation phase is invoked once. Lost replies stop for observation of the
original operation; no phase retries a write. Only the eight explicitly inventoried current candidate volumes are deleted after quiescence.
"""
from pathlib import Path
import datetime, hashlib, json, re, subprocess, sys, time, urllib.request

ROOT = Path('/home/yan/src/quod')
OUT = ROOT/'_build/quo-58-webxr-20261026/demo-02/deployment'
EVIDENCE = Path(__file__).resolve().parent
ADDR = 'http://192.168.1.10:4646'
SCOPE = json.loads((OUT/'prepared-scope.json').read_text())
JOB = SCOPE['job']
PROTECTED = ['quod', 'quod27-client-30519', 'quod-candidate-browser-ingress']

def save(name, value):
    with (OUT/name).open('x') as stream:
        json.dump(value, stream, indent=2); stream.write('\n')

def request(path, value=None, timeout=40):
    data = None if value is None else json.dumps(value).encode()
    req = urllib.request.Request(ADDR+path, data=data, headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.load(response), response.headers.get('X-Nomad-Index', '0')

def get(path): return request(path)[0]
def read(name): return json.loads((OUT/name).read_text())

def run(label, args):
    save(label+'.intent.json', {'command':args})
    started = time.monotonic()
    with (OUT/(label+'.stdout')).open('xb') as stdout, (OUT/(label+'.stderr')).open('xb') as stderr:
        result = subprocess.run(args, stdout=stdout, stderr=stderr)
    receipt = {'exit':result.returncode, 'seconds':time.monotonic()-started}
    save(label+'.exit.json', receipt)
    assert result.returncode == 0, (label, receipt)
    return (OUT/(label+'.stdout')).read_text()

def protected_jobs():
    initial = read('live-before.json')
    for name in PROTECTED:
        assert get('/v1/job/'+name) == initial[name], ('protected job changed', name)
    return initial

def volume_list():
    return json.loads(subprocess.check_output([
        'nomad','volume','status','-address='+ADDR,'-type=host','-json']))

def retained_volumes():
    volumes = {v['ID']:v for v in volume_list()}
    assert all(identity in volumes for identity in SCOPE['protected_volume_ids']), 'Unrelated volume disappeared'
    if (OUT/'volumes-deleted.json').exists():
        assert all(r['old_id'] not in volumes for r in SCOPE['volumes'])
    return volumes

def ready_volumes():
    volumes = retained_volumes()
    new = [v for v in volumes.values() if v['Name'].startswith(SCOPE['new_family']+'[')]
    assert len(new) == 8 and all(v['State'] == 'ready' for v in new)
    assert {v['Name']:v['NodeID'] for v in new} == {r['new_name']:r['node'] for r in SCOPE['volumes']}
    return new

def verified_image():
    passed = json.loads((Path('/home/yan/src/quod/doc/evidence/quo-58-webxr-20261026/demo-02/release-gates-01/PASSED.json')).read_text())
    assert passed['passed'] and len(passed['results']) == 12
    assert all(r['exit'] == 0 and r['sources_unchanged'] for r in passed['results'])
    verified = read('verified-image.json')
    assert verified['registry_digest_matches'] and verified['packaged_priv_matches']
    assert '@sha256:' in verified['pinned_image']
    return verified['pinned_image']

def render(phase):
    initial = protected_jobs()
    current = get('/v1/job/'+JOB)
    if phase == 'bootstrap':
        assert current['JobModifyIndex'] == read('stopped-job.json')['JobModifyIndex'] and all(g['Count']==0 for g in current['TaskGroups'])
        root = ''
    else:
        prior = read('bootstrap-submission.json')
        assert current['JobModifyIndex'] == prior['JobModifyIndex']
        assert read('final-gate.json')['all_ready'] and read('final-gate.json')['rejected'] == 0
        root = read('root-info.json')['root_anchor']
        assert re.fullmatch('[0-9A-F]{64}', root)
        assert root != read('live-scope.json')['old_root']
    image = verified_image()
    ready_volumes()
    args = ['nomad','job','run','-output','-address='+ADDR,
            '-var=image_tag='+image.split('/quod:',1)[1],
            '-var=node_count=8','-var=cloud_node_count=0',
            '-var=bootstrap='+str(phase=='bootstrap').lower(),
            '-var=genesis_hash='+root,str(OUT/'candidate-refound.nomad')]
    desired = json.loads(run(phase+'-render', args))['Job']
    assert desired['ID'] == JOB
    groups = {g['Name']:g for g in desired['TaskGroups']}
    assert groups['quod-node']['Count'] == (1 if phase=='bootstrap' else 8)
    assert groups['quod-cloud']['Count'] == 0
    assert groups['quod-node']['Volumes']['quod-data']['Source'] == SCOPE['new_family']
    images = [t['Config'].get('image','') for g in groups.values() for t in g['Tasks']]
    assert {i for i in images if '/quod:' in i} == {image}
    if phase == 'bootstrap':
        # Enrollment uses the normal client owners. Keep those owners running,
        # while withholding the external ingress route until founding is ready.
        removed = []
        for group in groups.values():
            for holder in [group, *group['Tasks']]:
                services = holder.get('Services') or []
                removed.extend(s['Name'] for s in services if s['Name']==JOB+'-client')
                holder['Services'] = [s for s in services if s['Name']!=JOB+'-client'] or None
        assert removed and set(removed) == {JOB+'-client'}
        save('bootstrap-withheld-services.json', removed)
    save(phase+'-expected.json', current)
    save(phase+'-desired.json', desired)
    plan = request('/v1/job/'+JOB+'/plan', {'Job':desired,'Diff':True})[0]
    save(phase+'-plan.json', plan)
    assert plan['JobModifyIndex'] == current['JobModifyIndex']
    assert not plan.get('FailedTGAllocs') and not plan.get('Warnings')
    print(json.dumps({'phase':phase,'plan':plan.get('Annotations'),'diff':plan.get('Diff',{}).get('Type')}), flush=True)

def submit(phase):
    verified_image(); protected_jobs(); ready_volumes()
    desired = read(phase+'-desired.json'); expected = read(phase+'-expected.json')
    assert get('/v1/job/'+JOB) == expected
    plan = request('/v1/job/'+JOB+'/plan', {'Job':desired,'Diff':True})[0]
    save(phase+'-immediate-plan.json', plan)
    assert plan['JobModifyIndex'] == expected['JobModifyIndex']
    assert not plan.get('FailedTGAllocs') and not plan.get('Warnings')
    assert plan['Annotations'] == read(phase+'-plan.json')['Annotations']
    payload = {'Job':desired,'EnforceIndex':True,'JobModifyIndex':expected['JobModifyIndex']}
    save(phase+'-request.json', payload)
    save(phase+'-intent.json', {'time':datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'request_sha256':hashlib.sha256((OUT/(phase+'-request.json')).read_bytes()).hexdigest()})
    try:
        result = request('/v1/jobs', payload)[0]
    except Exception as error:
        save(phase+'-uncertain.json', {'error_type':type(error).__name__, 'resubmit':False})
        raise
    save(phase+'-submission.json', result)
    current = get('/v1/job/'+JOB); save(phase+'-job-after.json', current)
    assert current['Version'] == expected['Version']+1
    assert current['JobModifyIndex'] == result['JobModifyIndex']
    print(json.dumps({'phase':phase,'version':current['Version'],'evaluation':result['EvalID']}), flush=True)

def observe(phase):
    accepted = read(phase+'-submission.json')
    version = read(phase+'-expected.json')['Version']+1
    deadline = time.monotonic()+1200; index='0'
    with (OUT/(phase+'-deployment-events.jsonl')).open('x') as log:
        while time.monotonic() < deadline:
            rows,index = request('/v1/job/'+JOB+'/deployments?all=true&index='+index+'&wait=30s',
                                 timeout=min(40,max(1,deadline-time.monotonic())))
            matches = [r for r in rows if r['JobVersion']==version]
            assert len(matches)<=1
            state = matches[0] if matches else {'Status':'awaiting-deployment'}
            log.write(json.dumps(state)+'\n'); log.flush()
            print(json.dumps({'phase':phase,'status':state['Status']}), flush=True)
            assert state['Status'] not in ['failed','cancelled','blocked'], state
            if state['Status']=='successful': break
        else: raise RuntimeError('Original deployment exceeded its absolute observation deadline')
    current = get('/v1/job/'+JOB)
    assert current['JobModifyIndex'] == accepted['JobModifyIndex']
    rows = get('/v1/job/'+JOB+'/allocations?all=true')
    live = [r for r in rows if r['DesiredStatus']=='run' and r['ClientStatus']=='running']
    assert len(live)==(1 if phase=='bootstrap' else 8)
    assert all(r['JobVersion']==version and r['TaskGroup']=='quod-node' and
               r['TaskStates']['quod']['State']=='running' and r['TaskStates']['quod']['Restarts']==0 for r in live)
    if phase=='bootstrap': save('founder-allocation.json', live[0])
    save(phase+'-live.json', live)
    protected_jobs(); ready_volumes()
    save(phase+'-observed.json', {'job_version':version,'allocations':len(live),'protected_jobs_unchanged':True})
    print(json.dumps({'phase':phase,'healthy_allocations':len(live)}), flush=True)


def stop_candidate():
    verified_image(); initial=protected_jobs(); current=get('/v1/job/'+JOB)
    assert current==initial[JOB]
    desired=json.loads(json.dumps(current))
    for group in desired['TaskGroups']: group['Count']=0
    plan=request('/v1/job/'+JOB+'/plan',{'Job':desired,'Diff':True})[0]
    save('stop-plan.json',plan)
    assert plan['JobModifyIndex']==current['JobModifyIndex'] and not plan.get('FailedTGAllocs') and not plan.get('Warnings')
    payload={'Job':desired,'EnforceIndex':True,'JobModifyIndex':current['JobModifyIndex']}
    save('stop-request.json',payload); save('stop-intent.json',{'old_volume_ids':[r['old_id'] for r in SCOPE['volumes']]})
    result=request('/v1/jobs',payload)[0];save('stop-submission.json',result)
    deadline=time.monotonic()+600; index='0'
    with (OUT/'stop-allocation-events.jsonl').open('x') as log:
        while time.monotonic()<deadline:
            rows,index=request('/v1/job/'+JOB+'/allocations?all=true&index='+index+'&wait=30s',timeout=40)
            active=[r for r in rows if r['ClientStatus'] in ['pending','running']]
            log.write(json.dumps({'active':[r['ID'] for r in active]})+'\n');log.flush()
            if not active:break
        else:raise RuntimeError('Candidate stop deadline exceeded; no volume deletion')
    current=get('/v1/job/'+JOB)
    assert current['JobModifyIndex']==result['JobModifyIndex'] and all(g['Count']==0 for g in current['TaskGroups'])
    save('stopped-job.json',current);protected_jobs()
    print('Candidate stopped; no active allocations',flush=True)

def delete_volumes():
    verified_image();protected_jobs()
    assert get('/v1/job/'+JOB)['JobModifyIndex']==read('stopped-job.json')['JobModifyIndex']
    assert not any(a['ClientStatus'] in ['running','pending'] for a in get('/v1/job/'+JOB+'/allocations?all=true'))
    for row in SCOPE['volumes']:
        detail=get('/v1/volume/host/'+row['old_id'])
        assert detail['Name']==row['old_name'] and detail['NodeID']==row['node'] and detail['HostPath']==row['old_path'] and detail['PluginID']=='mkdir'
        claims=detail.get('Allocations') or []
        assert not any(a.get('ClientStatus') in ['running','pending'] for a in claims), claims
        save('volume-before-delete-'+str(row['index'])+'.json',detail)
        run('volume-delete-'+str(row['index']),['nomad','volume','delete','-address='+ADDR,'-type=host',row['old_id']])
    remaining={v['ID'] for v in volume_list()}
    assert all(r['old_id'] not in remaining for r in SCOPE['volumes'])
    assert all(v in remaining for v in SCOPE['protected_volume_ids'])
    save('volumes-deleted.json',{'deleted':[r['old_id'] for r in SCOPE['volumes']],'protected_preserved':True})
    protected_jobs();print('Eight scoped candidate volumes deleted; unrelated volumes preserved',flush=True)

phase = sys.argv[1]
if phase=='capture':
    image=verified_image()
    actual={name:get('/v1/job/'+name) for name in [JOB,*PROTECTED]}
    prior=ROOT/'_build/quo-58-webxr-20261026/demo-02/inventory'
    names={JOB:'candidate','quod':'main','quod27-client-30519':'legacy-ingress','quod-candidate-browser-ingress':'ingress'}
    assert all(actual[name]==json.loads((prior/(names[name]+'.json')).read_text()) for name in actual)
    retained_volumes()
    assert not any(v['Name'].startswith(SCOPE['new_family']+'[') for v in volume_list())
    save('live-before.json', actual)
    allocations=get('/v1/job/'+JOB+'/allocations?all=true')
    live=[a for a in allocations if a['DesiredStatus']=='run' and a['ClientStatus']=='running']
    assert len(live)==8 and all(a['TaskGroup']=='quod-node' for a in live)
    save('allocations-before.json',live)
    roots=set()
    for group in actual[JOB]['TaskGroups']:
        for task in group['Tasks']:
            for template in task.get('Templates') or []:
                text=template.get('EmbeddedTmpl','')
                if 'namespace = "quod:root"' in text:
                    roots.update(re.findall(r'genesis_hash\s*=\s*"([0-9A-F]{64})"',text))
    assert len(roots)==1
    scope={**SCOPE,'new_image':image,'candidate_version':actual[JOB]['Version'],
           'candidate_modify_index':actual[JOB]['JobModifyIndex'],
           'old_root':roots.pop(),
           'old_allocations':[{'id':a['ID'],'name':a['Name'],'node_id':a['NodeID']} for a in live]}
    save('live-scope.json',scope)
    with (EVIDENCE/'reset-scope.json').open('x') as f:json.dump(scope,f,indent=2)
    print(json.dumps({'captured':True,'job':JOB,'candidate_version':scope['candidate_version']}))
elif phase=='stop-candidate': stop_candidate()
elif phase=='delete-volumes': delete_volumes()
elif phase=='create-volumes':
    verified_image(); initial=protected_jobs()
    assert get('/v1/job/'+JOB)['JobModifyIndex']==read('stopped-job.json')['JobModifyIndex']
    assert not any(v['Name'].startswith(SCOPE['new_family']+'[') for v in volume_list())
    for row in SCOPE['volumes']:
        run('volume-create-'+str(row['index']), ['nomad','volume','create','-address='+ADDR,
            str(OUT/'volumes'/(str(row['index'])+'.hcl'))])
    save('volumes-created.json',ready_volumes()); protected_jobs()
    print(json.dumps({'created':8,'old_candidate_volumes_deleted':8}))
elif phase in ['prepare-bootstrap','prepare-scale']: render(phase.removeprefix('prepare-'))
elif phase in ['submit-bootstrap','submit-scale']: submit(phase.removeprefix('submit-'))
elif phase in ['observe-bootstrap','observe-scale']: observe(phase.removeprefix('observe-'))
else: raise SystemExit('Unknown phase')

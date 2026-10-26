"""Image-only candidate rollout; existing roots, volumes and jobs are preserved.

Preparation is read-only. Submission has one write-once intent and Nomad CAS.
An uncertain submission is observed, never repeated. No bootstrap/reset path.
"""
from pathlib import Path
import copy, datetime, hashlib, json, subprocess, sys, time, urllib.request

ROOT = Path('/home/yan/src/quod')
EVIDENCE = Path(__file__).resolve().parent
OUT = ROOT / '_build/quo-58-webxr-20261026/view-correction-01/deployment'
ADDR = 'http://192.168.1.10:4646'
JOB = 'quod-finality-candidate-v6-20260926'
PROTECTED = ['quod', 'quod27-client-30519', 'quod-candidate-browser-ingress']

def save(name, value):
    with (OUT / name).open('x') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')

def read(name):
    return json.loads((OUT / name).read_text())

def request(path, value=None, timeout=40):
    data = None if value is None else json.dumps(value).encode()
    req = urllib.request.Request(ADDR + path, data=data, headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.load(response), response.headers.get('X-Nomad-Index', '0')

def get(path):
    return request(path)[0]

def volumes():
    return json.loads(subprocess.check_output([
        'nomad', 'volume', 'status', '-address=' + ADDR, '-type=host', '-json']))

def protected():
    for name, initial in read('protected-jobs.json').items():
        assert get('/v1/job/' + name) == initial, ('protected job changed', name)
    present = {v['ID']: v for v in volumes()}
    for before in read('volumes-before.json'):
        assert before['ID'] in present, ('existing volume disappeared', before['ID'])
        assert present[before['ID']]['Name'] == before['Name']

def image():
    passed = json.loads((EVIDENCE / 'release-gates-04/PASSED.json').read_text())
    assert passed['passed'] and len(passed['results']) == 12
    assert all(r['exit'] == 0 and r['sources_unchanged'] for r in passed['results'])
    verified = read('verified-image.json')
    assert verified['registry_digest_matches'] and verified['packaged_priv_matches']
    assert '@sha256:' in verified['pinned_image']
    return verified['pinned_image']

def prepare():
    desired_image = image()
    current = get('/v1/job/' + JOB)
    assert current['Version'] == 110
    save('roll-expected.json', current)
    save('protected-jobs.json', {name: get('/v1/job/' + name) for name in PROTECTED})
    save('volumes-before.json', volumes())
    groups = {g['Name']: g for g in current['TaskGroups']}
    assert groups['quod-node']['Count'] == 8 and groups['quod-cloud']['Count'] == 0
    assert groups['quod-node']['Volumes']['quod-data']['Source'] == 'quod-finality-candidate-v6-20260926-refound-20261026-xr-demo02'
    previous = json.loads((ROOT / 'doc/evidence/quo-58-webxr-20261026/demo-02/verified-image.json').read_text())['pinned_image']
    desired = copy.deepcopy(current)
    changes = []
    for group in desired['TaskGroups']:
        for task in group['Tasks']:
            old = task['Config'].get('image', '')
            if '/quod:' in old:
                assert old == previous
                task['Config']['image'] = desired_image
                changes.append({'group': group['Name'], 'task': task['Name'], 'before': old, 'after': desired_image})
    assert len(changes) == 5
    assert desired['Update']['MaxParallel'] == 1 and not desired['Update']['AutoRevert']
    save('roll-desired.json', desired)
    save('roll-image-changes.json', changes)
    plan = request('/v1/job/' + JOB + '/plan', {'Job': desired, 'Diff': True})[0]
    save('roll-plan.json', plan)
    assert plan['JobModifyIndex'] == current['JobModifyIndex']
    assert not plan.get('FailedTGAllocs') and not plan.get('Warnings')
    protected()
    print(json.dumps({'prepared': True, 'image_changes': len(changes), 'ledger_changes': False,
                      'annotations': plan.get('Annotations')}), flush=True)

def submit():
    image()
    protected()
    expected, desired = read('roll-expected.json'), read('roll-desired.json')
    assert get('/v1/job/' + JOB) == expected
    plan = request('/v1/job/' + JOB + '/plan', {'Job': desired, 'Diff': True})[0]
    save('roll-immediate-plan.json', plan)
    assert plan['JobModifyIndex'] == expected['JobModifyIndex']
    assert not plan.get('FailedTGAllocs') and not plan.get('Warnings')
    assert plan['Annotations'] == read('roll-plan.json')['Annotations']
    payload = {'Job': desired, 'EnforceIndex': True, 'JobModifyIndex': expected['JobModifyIndex']}
    save('roll-request.json', payload)
    save('roll-intent.json', {'time': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                            'request_sha256': hashlib.sha256((OUT / 'roll-request.json').read_bytes()).hexdigest()})
    try:
        result = request('/v1/jobs', payload)[0]
    except Exception as error:
        save('roll-uncertain.json', {'error_type': type(error).__name__, 'resubmit': False})
        raise
    save('roll-submission.json', result)
    current = get('/v1/job/' + JOB)
    save('roll-job-after.json', current)
    assert current['Version'] == expected['Version'] + 1
    assert current['JobModifyIndex'] == result['JobModifyIndex']
    print(json.dumps({'submitted': True, 'version': current['Version'], 'evaluation': result['EvalID']}), flush=True)

def observe():
    accepted = read('roll-submission.json')
    version = read('roll-expected.json')['Version'] + 1
    deadline, index = time.monotonic() + 1200, '0'
    with (OUT / 'roll-deployment-events.jsonl').open('x') as log:
        while time.monotonic() < deadline:
            rows, index = request('/v1/job/' + JOB + '/deployments?all=true&index=' + index + '&wait=30s',
                                  timeout=min(40, max(1, deadline - time.monotonic())))
            matches = [r for r in rows if r['JobVersion'] == version]
            assert len(matches) <= 1
            state = matches[0] if matches else {'Status': 'awaiting-deployment'}
            log.write(json.dumps(state) + '\n')
            log.flush()
            print(json.dumps({'status': state['Status']}), flush=True)
            assert state['Status'] not in ['failed', 'cancelled', 'blocked'], state
            if state['Status'] == 'successful':
                break
        else:
            raise RuntimeError('Original deployment exceeded its absolute observation deadline')
    current = get('/v1/job/' + JOB)
    assert current['JobModifyIndex'] == accepted['JobModifyIndex']
    rows = get('/v1/job/' + JOB + '/allocations?all=true')
    live = [r for r in rows if r['DesiredStatus'] == 'run' and r['ClientStatus'] == 'running']
    assert len(live) == 8
    assert all(r['JobVersion'] == version and r['TaskGroup'] == 'quod-node' and
               r['TaskStates']['quod']['State'] == 'running' and r['TaskStates']['quod']['Restarts'] == 0 for r in live)
    save('roll-live.json', live)
    protected()
    save('roll-observed.json', {'job_version': version, 'allocations': len(live),
                              'protected_jobs_unchanged': True, 'existing_volumes_retained': True})

{'prepare': prepare, 'submit': submit, 'observe': observe}[sys.argv[1]]()

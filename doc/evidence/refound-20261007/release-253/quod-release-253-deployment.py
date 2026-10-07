from pathlib import Path
import copy
import json
import re
import subprocess
import sys
import time
import urllib.request

out = Path('/tmp/quod-release-253-20261007')
address = 'http://192.168.1.10:4646'
job_id = 'quod-finality-candidate-v6-20260926'

def get(path, index=None):
    query = f'?index={index}&wait=30s' if index is not None else ''
    with urllib.request.urlopen(address+path+query, timeout=40) as response:
        return json.load(response), response.headers.get('X-Nomad-Index', '0')

def save(name, value):
    with (out / name).open('x') as dest:
        json.dump(value, dest, indent=2)
        dest.write('\n')

mode = sys.argv[1]
if mode == 'prepare':
    verified = json.loads((out / 'verified-image.json').read_text())
    image = verified['pinned_image']
    assert re.fullmatch(r'192\.168\.1\.11:5000/quod:0\.7\.253@sha256:[0-9a-f]{64}', image)
    job, _ = get('/v1/job/'+job_id)
    main, _ = get('/v1/job/quod')
    save('main-before-upgrade.json', main)
    save('candidate-before-upgrade.json', job)
    assert job['Version'] == 50
    assert {g['Name']: g['Count'] for g in job['TaskGroups']} == {'quod-node':8, 'quod-cloud':0}
    expected = '192.168.1.11:5000/quod:0.7.252@sha256:2d7ed2e31d9b38eb88501501b8b7b39a2dc189a5438013d05ba97524839b441d'
    updated = copy.deepcopy(job)
    changes = []
    for group in updated['TaskGroups']:
        for task in group['Tasks']:
            if task.get('Config', {}).get('image') == expected:
                task['Config']['image'] = image
                changes.append([group['Name'], task['Name']])
    assert changes == [['quod-node','wait-for-peer'], ['quod-node','quod'], ['quod-cloud','quod']]
    save('candidate-image-upgrade.json', {'Job':updated})
    save('image-only-changes.json', {'paths':changes, 'check_index':job['JobModifyIndex'], 'old_version':job['Version'], 'image':image})
    print(json.dumps({'changes':changes, 'check_index':job['JobModifyIndex']}))
elif mode in ('plan', 'run'):
    intent = json.loads((out / 'image-only-changes.json').read_text())
    args = ['nomad','job',mode,'-address='+address,'-json','-no-color']
    if mode == 'run':
        args.append('-check-index='+str(intent['check_index']))
    args.append(str(out / 'candidate-image-upgrade.json'))
    save(f'upgrade-{mode}.intent.json', {'command':args})
    result = subprocess.run(args, capture_output=True, text=True)
    (out / f'upgrade-{mode}.stdout').write_text(result.stdout)
    (out / f'upgrade-{mode}.stderr').write_text(result.stderr)
    save(f'upgrade-{mode}.exit.json', {'exit':result.returncode})
    print(result.stdout, end='')
    print(result.stderr, end='', file=sys.stderr)
    # Nomad plan exit 1 means allocations change. Other exits are errors.
    assert result.returncode in ([0,1] if mode=='plan' else [0])
elif mode == 'watch':
    log = (out / 'upgrade-run.stdout').read_text()
    evaluation = re.search(r'Evaluation ID: ([0-9a-f-]+)',log).group(1)
    deadline = time.monotonic()+1200
    index = '0'
    deployment = None
    with (out / 'upgrade-evaluation-events.jsonl').open('x') as dest:
        while time.monotonic()<deadline:
            event,index = get('/v1/evaluation/'+evaluation,index)
            dest.write(json.dumps(event)+'\n'); dest.flush()
            deployment=event.get('DeploymentID')
            if deployment: break
            assert event['Status'] not in ['failed','cancelled']
    assert deployment
    save('upgrade-deployment-id.json', {'evaluation':evaluation,'deployment':deployment})
    index='0'
    with (out / 'upgrade-deployment-events.jsonl').open('x') as dest:
        while time.monotonic()<deadline:
            event,index=get('/v1/deployment/'+deployment,index)
            dest.write(json.dumps(event)+'\n'); dest.flush()
            print(event['Status'], {k:(v['PlacedAllocs'],v['HealthyAllocs'],v['UnhealthyAllocs']) for k,v in event['TaskGroups'].items()},flush=True)
            if event['Status']=='successful': sys.exit(0)
            if event['Status']!='running': sys.exit(1)
    sys.exit(2)
else:
    raise ValueError(mode)

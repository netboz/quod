#!/usr/bin/env python3
from pathlib import Path
import json
import subprocess
import sys
import time
import urllib.request

out = Path('/home/yan/src/quod/_build/world-library-20261016/deployment-02/refound')
address = 'http://192.168.1.10:4646'
scope = json.loads((out / 'scope.json').read_text())
root = json.loads((out / 'root-info.json').read_text())['root_anchor']
assert json.loads((out / 'final-gate.json').read_text()) == {
    **json.loads((out / 'final-gate.json').read_text()),
    'system_ontologies': 18, 'rejected': 0, 'all_ready': True}

def get(path):
    with urllib.request.urlopen(address + path, timeout=40) as response:
        return json.load(response)

watch_index = '0'
def await_allocations():
    global watch_index
    path = '/v1/job/' + scope['job'] + '/allocations?all=true&index=' + watch_index + '&wait=30s'
    with urllib.request.urlopen(address + path, timeout=40) as response:
        result = json.load(response)
        watch_index = response.headers.get('X-Nomad-Index','0')
        return result

def run(label, command, allowed=(0,)):
    start = time.monotonic()
    result = subprocess.run(command, capture_output=True, text=True)
    (out / f'{label}.stdout').write_text(result.stdout)
    (out / f'{label}.stderr').write_text(result.stderr)
    (out / f'{label}.exit.json').write_text(json.dumps(
        {'command': command, 'exit': result.returncode,
         'seconds': time.monotonic() - start}, indent=2) + '\n')
    if result.returncode not in allowed:
        print(result.stdout, end='')
        print(result.stderr, end='', file=sys.stderr)
        raise SystemExit(result.returncode)
    return result

job = get('/v1/job/' + scope['job'])
main = get('/v1/job/quod')
assert job['Version'] == scope['candidate_version'] + 1
assert {g['Name']: g['Count'] for g in job['TaskGroups']} == {'quod-node': 1, 'quod-cloud': 0}
assert main['Version'] == scope['main_version'] and main['JobModifyIndex'] == scope['main_modify_index']
common = ['-address=' + address, '-no-color',
          '-var=image_tag=' + scope['new_image'].split('/quod:', 1)[1],
          '-var=node_count=8', '-var=cloud_node_count=0',
          '-var=genesis_hash=' + root,
          str(out / 'candidate-refound.nomad')]
run('scale-plan', ['nomad', 'job', 'plan', '-verbose', *common], allowed=(1,))
run('scale-submit', ['nomad', 'job', 'run', '-detach',
                     '-check-index=' + str(job['JobModifyIndex']), *common])

deadline = time.monotonic() + 1200
events = []
while time.monotonic() < deadline:
    current = get('/v1/job/' + scope['job'])
    allocations = await_allocations()
    live = [a for a in allocations if a['DesiredStatus'] == 'run'
            and a['ClientStatus'] == 'running' and a['TaskGroup'] == 'quod-node']
    row = {'time': time.time(), 'version': current['Version'],
           'live': [{'id': a['ID'], 'name': a['Name'], 'node': a['NodeName'],
                     'state': a.get('TaskStates', {}).get('quod', {}).get('State'),
                     'restarts': a.get('TaskStates', {}).get('quod', {}).get('Restarts')}
                    for a in live]}
    events.append(row)
    (out / 'scale-events.json').write_text(json.dumps(events, indent=2) + '\n')
    print(json.dumps({'version': row['version'], 'live': len(live),
                      'running_tasks': sum(a['state'] == 'running' for a in row['live'])}), flush=True)
    groups = {g['Name']: g for g in current['TaskGroups']}
    if (current['Version'] == job['Version'] + 1
            and groups['quod-node']['Count'] == 8
            and groups['quod-node']['Volumes']['quod-data']['Source'] == scope['new_family']
            and len(live) == 8
            and all(a['state'] == 'running' and a['restarts'] == 0 for a in row['live'])):
        (out / 'scale-live.json').write_text(json.dumps(row, indent=2) + '\n')
        break
else:
    raise SystemExit('scale-out did not reach eight running zero-restart tasks')
main_after = get('/v1/job/quod')
assert main_after['Version'] == scope['main_version']
assert main_after['JobModifyIndex'] == scope['main_modify_index']
print(json.dumps({'job_version': current['Version'], 'allocations': len(live),
                  'main_job_unchanged': True}, indent=2))

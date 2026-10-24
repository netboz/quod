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
job_id = scope['job']

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

candidate = get('/v1/job/' + job_id)
main = get('/v1/job/quod')
assert candidate['Version'] == scope['candidate_version']
assert candidate['JobModifyIndex'] == scope['candidate_modify_index']
assert main['Version'] == scope['main_version']
assert main['JobModifyIndex'] == scope['main_modify_index']
frontend = get('/v1/job/quod27-client-30519')
assert frontend['Version'] == 1 and frontend['JobModifyIndex'] == 846370
volumes = json.loads(subprocess.check_output(
    ['nomad', 'volume', 'status', '-address=' + address, '-type=host', '-json'],
    text=True))
old_ids = {row['id'] for row in scope['volumes']}
assert {v['ID'] for v in volumes if v['ID'] in old_ids} == old_ids
new = [v for v in volumes if v['Name'].startswith(scope['new_family'] + '[')]
assert len(new) == 8 and all(v['State'] == 'ready' for v in new)

common = ['-address=' + address, '-no-color',
          '-var=image_tag=' + scope['new_image'].split('/quod:', 1)[1],
          '-var=bootstrap=true', '-var=node_count=8', '-var=cloud_node_count=0',
          str(out / 'candidate-refound.nomad')]
run('bootstrap-plan-01', ['nomad', 'job', 'plan', '-verbose', *common], allowed=(1,))
run('bootstrap-submit', ['nomad', 'job', 'run', '-detach',
                         '-check-index=' + str(scope['candidate_modify_index']), *common])

deadline = time.monotonic() + 900
events = []
founder = None
while time.monotonic() < deadline:
    job = get('/v1/job/' + job_id)
    allocations = await_allocations()
    live = [a for a in allocations if a['DesiredStatus'] == 'run'
            and a['ClientStatus'] == 'running' and a['TaskGroup'] == 'quod-node']
    event = {'time': time.time(), 'job_version': job['Version'],
             'job_modify_index': job['JobModifyIndex'],
             'live': [{'id': a['ID'], 'name': a['Name'],
                       'node': a['NodeName'],
                       'quod_state': a.get('TaskStates', {}).get('quod', {}).get('State'),
                       'restarts': a.get('TaskStates', {}).get('quod', {}).get('Restarts')}
                      for a in live]}
    if not events or event != {**events[-1], 'time': event['time']}:
        events.append(event)
        (out / 'bootstrap-events.json').write_text(json.dumps(events, indent=2) + '\n')
        print(json.dumps(event), flush=True)
    groups = {g['Name']: g for g in job['TaskGroups']}
    images = [task.get('Config', {}).get('image') for task in groups['quod-node']['Tasks']
              if task.get('Config', {}).get('image', '').startswith('192.168.1.11:5000/quod:')]
    if (job['Version'] == scope['candidate_version'] + 1
            and groups['quod-node']['Count'] == 1
            and groups['quod-node']['Volumes']['quod-data']['Source'] == scope['new_family']
            and set(images) == {scope['new_image']}
            and len(live) == 1
            and live[0].get('TaskStates', {}).get('quod', {}).get('State') == 'running'):
        founder = live[0]
        break
assert founder is not None, 'founder did not become running'
(out / 'founder-allocation.json').write_text(json.dumps(founder, indent=2) + '\n')

# The job no longer references the old family and all prior allocations have
# stopped before their volumes are deleted.
deadline = time.monotonic() + 300
while time.monotonic() < deadline:
    allocations = await_allocations()
    old_running = [a for a in allocations
                   if a['ID'] != founder['ID'] and a['ClientStatus'] == 'running']
    if not old_running:
        break
assert not old_running, old_running

main_after = get('/v1/job/quod')
assert main_after['Version'] == scope['main_version']
assert main_after['JobModifyIndex'] == scope['main_modify_index']
(out / 'main-after-bootstrap.json').write_text(json.dumps(main_after, indent=2) + '\n')
print(json.dumps({'founder': founder['ID'], 'node': founder['NodeName'],
                  'old_volumes_retained_until_acceptance': len(scope['volumes']),
                  'main_job_unchanged': True}, indent=2))

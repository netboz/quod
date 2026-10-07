#!/usr/bin/env python3
from pathlib import Path
import json, os, subprocess

out = Path('/tmp/quod-candidate-refound-252-20261007-v2')
address = 'http://192.168.1.10:4646'

def nomad(*args):
    env = os.environ.copy()
    env['NOMAD_ADDR'] = address
    return json.loads(subprocess.run(
        ['nomad', *args], env=env, capture_output=True, text=True, check=True).stdout)

def job(name):
    value = nomad('job', 'inspect', '-json', name)
    return value.get('Job', value)

def image(job_value, group):
    target = next(g for g in job_value['TaskGroups'] if g['Name'] == group)
    task = next(t for t in target['Tasks'] if t['Name'] == 'quod')
    return task['Config']['image']

candidate = job('quod-finality-candidate-v6-20260926')
allocs = nomad('job', 'allocs', '-json', 'quod-finality-candidate-v6-20260926')
running = sorted([{k: a[k] for k in ('ID','Name','NodeID','NodeName','ClientStatus','DesiredStatus')}
                  | {'Restarts': a['TaskStates']['quod']['Restarts']}
                  for a in allocs if a['ClientStatus'] == 'running' and a['DesiredStatus'] == 'run'],
                 key=lambda a: a['Name'])
candidate_summary = {
    'id': candidate['ID'], 'version': candidate['Version'],
    'job_modify_index': candidate['JobModifyIndex'], 'status': candidate['Status'],
    'image': image(candidate, 'quod-node'),
    'counts': {g['Name']: g['Count'] for g in candidate['TaskGroups']},
    'running_allocations': running,
}
(out/'candidate-final-state.json').write_text(json.dumps(candidate_summary, indent=2)+'\n')

before_wrapper = json.loads(Path('/tmp/quod-candidate-refound-252-20261007/main-job-before.json').read_text())
before = before_wrapper.get('Job', before_wrapper)
after = job('quod')
main_summary = {
    'before': {'version': before['Version'], 'job_modify_index': before['JobModifyIndex'],
               'image': image(before, 'quod-node'),
               'counts': {g['Name']: g['Count'] for g in before['TaskGroups']}},
    'after': {'version': after['Version'], 'job_modify_index': after['JobModifyIndex'],
              'image': image(after, 'quod-node'),
              'counts': {g['Name']: g['Count'] for g in after['TaskGroups']}},
}
main_summary['unchanged'] = main_summary['before'] == main_summary['after']
(out/'main-job-unchanged.json').write_text(json.dumps(main_summary, indent=2)+'\n')
print(json.dumps({'candidate':candidate_summary,'main':main_summary}, indent=2))
assert len(running) == 8 and all(row['Restarts'] == 0 for row in running)
assert main_summary['unchanged']

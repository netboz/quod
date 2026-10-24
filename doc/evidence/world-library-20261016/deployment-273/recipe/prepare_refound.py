#!/usr/bin/env python3
from pathlib import Path
import json
import re
import subprocess
import urllib.request

repo = Path('/home/yan/src/quod')
out = Path('/home/yan/src/quod/_build/world-library-20261016/deployment-02/refound')
assert out.is_dir()
address = 'http://192.168.1.10:4646'
job_id = 'quod-finality-candidate-v6-20260926'
old_family = job_id + '-refound-20261017-v10'
new_family = job_id + '-refound-20261017-v11'
old_image = '192.168.1.11:5000/quod:0.7.273@sha256:4fa80d816a4d7583b988d63b6ff4d530c74b3df2ef0379d5bb7b40ff763a33c5'
verified = json.loads((Path('/home/yan/src/quod/_build/world-library-20261016/deployment-02') / 'verified-image.json').read_text())
new_image = verified['pinned_image']

def get(path):
    with urllib.request.urlopen(address + path, timeout=30) as response:
        return json.load(response)

candidate = get('/v1/job/' + job_id)
main = get('/v1/job/quod')
frontend = get('/v1/job/quod27-client-30519')
assert frontend['Version'] == 1 and frontend['JobModifyIndex'] == 846370
allocations = get('/v1/job/' + job_id + '/allocations?all=true')
volumes = json.loads(subprocess.check_output(
    ['nomad', 'volume', 'status', '-address=' + address, '-type=host', '-json'],
    text=True))
groups = {group['Name']: group for group in candidate['TaskGroups']}
assert candidate['Version'] == 93 and candidate['JobModifyIndex'] == 868831
assert {name: group['Count'] for name, group in groups.items()} == {'quod-node': 8, 'quod-cloud': 0}
assert groups['quod-node']['Volumes']['quod-data']['Source'] == old_family
assert groups['quod-cloud']['Volumes']['quod-data']['Source'] == old_family + '-cloud'
images = {(group['Name'], task['Name']): task.get('Config', {}).get('image')
          for group in candidate['TaskGroups'] for task in group['Tasks']
          if task.get('Config', {}).get('image', '').startswith('192.168.1.11:5000/quod:')}
assert set(images.values()) == {old_image}, images

pattern = re.compile(re.escape(old_family) + r'\[([0-7])\]$')
selected = []
for volume in volumes:
    match = pattern.fullmatch(volume['Name'])
    if match:
        selected.append({**volume, 'index': int(match.group(1))})
selected.sort(key=lambda row: row['index'])
assert [row['index'] for row in selected] == list(range(8)), selected
assert all(row['State'] == 'ready' for row in selected)
assert not [row for row in volumes if row['Name'].startswith(new_family)]

(out / 'candidate-before.json').write_text(json.dumps(candidate, indent=2) + '\n')
(out / 'main-before.json').write_text(json.dumps(main, indent=2) + '\n')
(out / 'frontend-before.json').write_text(json.dumps(frontend, indent=2) + '\n')
(out / 'allocations-before.json').write_text(json.dumps(allocations, indent=2) + '\n')
(out / 'volumes-before.json').write_text(json.dumps(selected, indent=2) + '\n')

tree = Path('/home/yan/src/quod/_build/world-library-20261016/clean-integration-07/tree')
text = (tree/'deploy/quod.nomad').read_text()
replacements = [
    ('job "quod" {', f'job "{job_id}" {{', 1),
    ('source    = "quod-node-local"', f'source    = "{new_family}"', 1),
    ('source    = "quod-node-cloud"', f'source    = "{new_family}-cloud"', 1),
    ('range service "quod-metrics|any"', f'range service "{job_id}-quod-metrics|any"', 2),
    ('range service "quod"', f'range service "{job_id}-quod"', 2),
    ('        name = "quod"', f'        name = "{job_id}-quod"', 2),
    ('        name = "quod-metrics"', f'        name = "{job_id}-quod-metrics"', 2),
    ('        name = "explorer"', f'        name = "{job_id}-explorer"', 2),
    ('        name = "client"', f'        name = "{job_id}-client"', 2),
    ('        tags = ["quod", "client", "web"]',
     '        tags = ["quod", "client", "web", "candidate-quod-node-${NOMAD_ALLOC_INDEX}"]', 1),
    ('        tags = ["quod", "client", "web", "cloud"]',
     '        tags = ["quod", "client", "web", "cloud", "candidate-quod-cloud-${NOMAD_ALLOC_INDEX}"]', 1),
    ('service.namespace=quod,deployment.environment=nomad',
     f'service.namespace={job_id},deployment.environment=nomad', 2),
]
for old, new, expected in replacements:
    assert text.count(old) == expected, (old, text.count(old), expected)
    text = text.replace(old, new)
(out / 'candidate-refound.nomad').write_text(text)

template = (tree/'deploy/volumes/quod-node-local.hcl').read_text()
(out / 'volumes').mkdir()
for row in selected:
    body = template.replace('quod-node-local[0]', f'{new_family}[{row["index"]}]')
    body = body.replace('__COMPUTE_NODE_ID__', row['NodeID'])
    assert '__COMPUTE_NODE_ID__' not in body
    (out / 'volumes' / f'{row["index"]}.hcl').write_text(body)

scope = {'job': job_id, 'old_family': old_family, 'new_family': new_family,
         'old_image': old_image, 'new_image': new_image,
         'candidate_version': candidate['Version'],
         'candidate_modify_index': candidate['JobModifyIndex'],
         'main_version': main['Version'], 'main_modify_index': main['JobModifyIndex'],
         'volumes': [{'id': row['ID'], 'name': row['Name'],
                      'node_id': row['NodeID'], 'index': row['index']}
                     for row in selected]}
(out / 'scope.json').write_text(json.dumps(scope, indent=2) + '\n')
print(json.dumps(scope, indent=2))

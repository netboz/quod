#!/usr/bin/env python3
from pathlib import Path
import json
import subprocess
import time
import urllib.request

out = Path('/home/yan/src/quod/_build/world-library-20261016/deployment-02/refound')
address = 'http://192.168.1.10:4646'
scope = json.loads((out / 'scope.json').read_text())

def get(path):
    with urllib.request.urlopen(address + path, timeout=30) as response:
        return json.load(response)

candidate = get('/v1/job/' + scope['job'])
main = get('/v1/job/quod')
assert candidate['Version'] == scope['candidate_version']
assert candidate['JobModifyIndex'] == scope['candidate_modify_index']
assert main['Version'] == scope['main_version']
assert main['JobModifyIndex'] == scope['main_modify_index']

rows = []
for index in range(8):
    command = ['nomad', 'volume', 'create', '-address=' + address,
               str(out / 'volumes' / f'{index}.hcl')]
    start = time.monotonic()
    result = subprocess.run(command, capture_output=True, text=True)
    row = {'index': index, 'command': command, 'exit': result.returncode,
           'seconds': time.monotonic() - start,
           'stdout': result.stdout, 'stderr': result.stderr}
    rows.append(row)
    (out / 'volume-create-results-01.json').write_text(json.dumps(rows, indent=2) + '\n')
    if result.returncode:
        raise SystemExit(result.returncode)

volumes = json.loads(subprocess.check_output(
    ['nomad', 'volume', 'status', '-address=' + address, '-type=host', '-json'],
    text=True))
selected = sorted((v for v in volumes if v['Name'].startswith(scope['new_family'] + '[')),
                  key=lambda v: v['Name'])
assert len(selected) == 8, selected
assert all(v['State'] == 'ready' for v in selected)
(out / 'volumes-created.json').write_text(json.dumps(selected, indent=2) + '\n')
print(json.dumps([{'id': v['ID'], 'name': v['Name'], 'node': v['NodeID']}
                  for v in selected], indent=2))

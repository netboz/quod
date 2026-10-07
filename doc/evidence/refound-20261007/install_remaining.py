#!/usr/bin/env python3
from pathlib import Path
import json, subprocess, sys, time

out = Path('/tmp/quod-candidate-refound-252-20261007-v2')
operator = out / 'fresh_system_operator.py'
names = [
    'agent', 'environment', 'environment:eidolons', 'gui', 'human_user',
    'lens', 'licence', 'measure', 'material', 'material:eidolons',
    'rendering', 'modelling', 'names', 'prolog', 'prolog:eidolons',
    'lobby', 'signup',
]
(out / 'install-remaining.intent.json').write_text(json.dumps(
    {'ontologies': names, 'phases': ['found', 'publish'], 'retries': 0}, indent=2) + '\n')
started = time.monotonic()
completed = []
for name in names:
    for phase in ('found', 'publish'):
        print(f'{phase} {name}', flush=True)
        result = subprocess.run([sys.executable, str(operator), phase, name])
        if result.returncode:
            (out / 'install-remaining.stop.json').write_text(json.dumps(
                {'failed_phase': phase, 'failed_ontology': name,
                 'exit': result.returncode, 'completed': completed,
                 'seconds': time.monotonic() - started}, indent=2) + '\n')
            raise SystemExit(result.returncode)
        completed.append([phase, name])
(out / 'install-remaining.complete.json').write_text(json.dumps(
    {'completed': completed, 'seconds': time.monotonic() - started}, indent=2) + '\n')

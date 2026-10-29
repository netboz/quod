#!/usr/bin/env python3
"""Run final native campaigns serially so only one window owns test input."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

client=sys.argv[1]
root=Path.cwd();evidence=Path(__file__).resolve().parent
manifest=json.loads((evidence/'inputs'/('client-'+client+'-manifest.json')).read_text())
assert manifest['passed']
results=[];output=evidence/('serial-'+client+'-result.json');assert not output.exists()
try:
    for journey in ['navigation','gui','spaces']:
        for name,expected in manifest['authored_inputs'].items():
            assert hashlib.sha256((root/name).read_bytes()).hexdigest()==expected,name
        command=['python3',str(evidence/'campaign.py'),'final-'+journey+'-'+client,
            '--client',client,'--stage','/tmp/quod-m3b-8b352c53/m3b-gates01/source',
            '--profile','prod','--journey',journey,'--desktop']
        print('START_FINAL '+journey,flush=True)
        done=subprocess.run(command,cwd=root)
        results.append(dict(journey=journey,command=command,child_exit=done.returncode))
        if done.returncode:break
finally:
    passed=len(results)==3 and all(row['child_exit']==0 for row in results)
    output.write_text(json.dumps(dict(client=client,passed=passed,results=results),indent=2)+'\n')
if not passed:sys.exit(1)

#!/usr/bin/env python3
from pathlib import Path
import json, subprocess, time

out = Path('/tmp/quod-candidate-refound-252-20261007-v2')
command = [
    'nomad', 'job', 'run', '-address=http://192.168.1.10:4646',
    '-check-index=827337',
    '-var=image_tag=0.7.252@sha256:2d7ed2e31d9b38eb88501501b8b7b39a2dc189a5438013d05ba97524839b441d',
    '-var=node_count=8', '-var=cloud_node_count=0',
    '-var=genesis_hash=C9A6B83F8F91505F23EBACF1BF0DF92692AA890AA1060E6D5F5356D642DDA34E',
    str(out / 'candidate-refound.nomad'),
]
(out / 'scale-out.intent.json').write_text(json.dumps({'command_argv': command}, indent=2) + '\n')
started = time.monotonic()
result = subprocess.run(command, capture_output=True, text=True)
(out / 'scale-out.stdout').write_text(result.stdout)
(out / 'scale-out.stderr').write_text(result.stderr)
(out / 'scale-out.exit.json').write_text(json.dumps(
    {'exit': result.returncode, 'seconds': time.monotonic() - started}, indent=2) + '\n')
print(result.stdout, end='')
print(result.stderr, end='', file=__import__('sys').stderr)
raise SystemExit(result.returncode)

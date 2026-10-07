#!/usr/bin/env python3
from pathlib import Path
import json, subprocess, time

out = Path('/tmp/quod-candidate-refound-252-20261007-v2')
created = []
for index in range(8):
    source = out / 'volumes' / f'{index}.hcl'
    command = ['nomad', 'volume', 'create', '-address=http://192.168.1.10:4646', str(source)]
    (out / f'volume-{index}.intent.json').write_text(json.dumps({'command_argv': command}, indent=2) + '\n')
    started = time.monotonic()
    result = subprocess.run(command, capture_output=True, text=True)
    (out / f'volume-{index}.stdout').write_text(result.stdout)
    (out / f'volume-{index}.stderr').write_text(result.stderr)
    (out / f'volume-{index}.exit.json').write_text(json.dumps(
        {'exit': result.returncode, 'seconds': time.monotonic() - started}, indent=2) + '\n')
    if result.returncode:
        raise SystemExit(result.returncode)
    created.append(result.stdout.strip())
(out / 'volumes-created.txt').write_text('\n'.join(created) + '\n')

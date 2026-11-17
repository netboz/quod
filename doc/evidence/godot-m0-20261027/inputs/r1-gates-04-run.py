#!/usr/bin/env python3
"""Bounded M0 evidence runner: preserve output and the actual child status."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time

p = argparse.ArgumentParser()
p.add_argument('label')
p.add_argument('--cwd', default=str(Path(__file__).resolve().parents[3]))
p.add_argument('--timeout', type=int, default=300)
p.add_argument('command', nargs=argparse.REMAINDER)
a = p.parse_args()
command = a.command[1:] if a.command[:1] == ['--'] else a.command
base = Path(__file__).resolve().parent / 'logs' / a.label
if base.with_suffix('.json').exists() or base.with_suffix('.log').exists():
    sys.exit('Label already exists; retain failed evidence and choose a new label')
started = time.time()
env = dict(os.environ)
env.pop('LD_LIBRARY_PATH', None)
env.pop('LD_PRELOAD', None)
with base.with_suffix('.log').open('wb') as out:
    child = subprocess.Popen(command, cwd=a.cwd, env=env, stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
    timed_out = False
    try:
        status = child.wait(timeout=a.timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        import signal
        os.killpg(child.pid, signal.SIGTERM)
        try:
            status = child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            status = child.wait()
record = dict(command=command, cwd=a.cwd, start_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(started)),
              elapsed_seconds=time.time()-started, child_exit=status, timed_out=timed_out)
record['error_diagnostics'] = sum('ERROR:' in s for s in base.with_suffix('.log').read_text(errors='replace').splitlines())
base.with_suffix('.json').write_text(json.dumps(record, indent=2)+'\n')
print(json.dumps(record))
sys.exit(status if status >= 0 else 128-status)

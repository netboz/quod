#!/usr/bin/env python3
"""Bounded M4 evidence runner: preserve output and the actual child status."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import hashlib
import re
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
env['PYTHONDONTWRITEBYTECODE'] = '1'
rawdir=Path('/home/yan/.cache/quod-m4-r1-artifacts/private/logs')
rawdir.mkdir(mode=0o700,parents=True,exist_ok=True)
env['XDG_DATA_HOME']=str(rawdir.parent/'data')
raw=rawdir/(a.label+'.log')
with raw.open('xb') as out:
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
raw.chmod(0o600)
count=[0]
def redact(match):
    numbers=re.findall(rb'\d+',match[0])
    if len(numbers) in (32,64) and all(int(v)<256 for v in numbers):
        count[0]+=1; return b'<<REDACTED_'+str(len(numbers)).encode()+b'_BYTE_BINARY>>'
    return match[0]
data=raw.read_bytes()
sanitized=re.sub(rb'<<\s*(?:\d+\s*,\s*)*\d+\s*>>',redact,data)
base.with_suffix('.log').write_bytes(sanitized)
record.update(private_raw_log=str(raw),raw_sha256=hashlib.sha256(data).hexdigest(),sanitized_sha256=hashlib.sha256(sanitized).hexdigest(),redactions=count[0])
record['error_diagnostics'] = sum('ERROR:' in s for s in base.with_suffix('.log').read_text(errors='replace').splitlines())
base.with_suffix('.json').write_text(json.dumps(record, indent=2)+'\n')
print(json.dumps(record))
sys.exit((status if status >= 0 else 128-status) or (1 if record['error_diagnostics'] else 0))

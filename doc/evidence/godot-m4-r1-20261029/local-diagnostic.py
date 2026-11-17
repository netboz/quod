#!/usr/bin/env python3
"""Run actual exported key UI or externally kill its real store at a boundary."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import threading
import ctypes
import time
import re
from desktop_input import deliver

p = argparse.ArgumentParser()
p.add_argument('--export', type=Path, required=True)
p.add_argument('--phase', choices=['menu', 'crypto', 'backup-import', 'backup-cancel', 'crash'], required=True)
p.add_argument('--evidence', type=Path, required=True)
p.add_argument('--private', type=Path, required=True)
p.add_argument('--journey-private', type=Path)
p.add_argument('--node', default='https://localhost:14570')
p.add_argument('--ca', default='')
p.add_argument('--desktop', action='store_true')
a = p.parse_args()
a.evidence = a.evidence.resolve(); a.private = a.private.resolve()
a.evidence.mkdir(parents=True, exist_ok=False); a.private.mkdir(mode=0o700, parents=True, exist_ok=False)
records = []
native_inputs = []
def run(phase, profile, extra=None, kill=False, label=None):
    label = label or phase
    env = dict(os.environ, M1B_PHASE=phase,
        M1B_CORPUS=str(Path('client/test/fixtures/native-contract/contracts.json').resolve()),
        M1B_BROWSER_BACKUP=str(a.private / 'browser-backup.json'), M1B_EXPORTED_BACKUP=str(a.private / 'exported-backup.json'),
        M1B_RESULT=str(a.evidence / (label + '-result.json')), M1B_PROTOCOL_FIXTURES=str(Path('doc/evidence/godot-m0-20261027').resolve()), DOTNET_ROOT=str(a.private / 'no-installed-runtime'),
        XDG_DATA_HOME=str(a.private / 'data'), XDG_CONFIG_HOME=str(a.private / 'config'))
    if a.journey_private:
        env.update(M1B_ACCOUNT_BACKUP=str(a.journey_private / 'account-backup.json'), M1B_ORIGINAL=str(a.journey_private / 'original.json'))
    env.update(extra or {})
    display = ['--display-driver', 'wayland'] if a.desktop else ['--headless']
    command = [str(a.export)] + display + ['--', '--qualification', '--profile', str(profile), '--node', a.node, '--ca', a.ca]
    def allow_owned_trace():
        # Only this qualification process and its descendants may inspect the
        # owned child if the unchanged watchdog detects a real shutdown hang.
        if ctypes.CDLL(None).prctl(0x59616d61,os.getppid(),0,0,0)!=0:os._exit(125)
    child = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,preexec_fn=allow_owned_trace)
    lines = queue.Queue()
    def receive():
        for line in child.stdout: lines.put(line)
        lines.put(None)
    threading.Thread(target=receive, daemon=True).start()
    killed = False; text = ''; diagnostic_timer=None;diagnostic_result={}
    def capture_owned_stall():
     if child is None or child.poll() is not None:return
     diagnostics=a.private/'diagnostics';diagnostics.mkdir(mode=0o700,exist_ok=False)
     trace=diagnostics/'native-stacks.log'
     command=['gdb','-q','-batch','-p',str(child.pid),'-ex','set print frame-arguments none','-ex','set print entry-values no','-ex','thread apply all bt 20','-ex','detach']
     detail={'command':command,'owned_child_pid':child.pid,'started_monotonic':time.monotonic(),'after_completion_seconds':20,'capture_timeout_seconds':15,'memory_dump':False,'arguments':False}
     tasks=[]
     for task in sorted((Path('/proc')/str(child.pid)/'task').iterdir()):
      try:tasks.append({'tid':int(task.name),'comm':(task/'comm').read_text().strip(),'wchan':(task/'wchan').read_text().strip()})
      except FileNotFoundError:pass
     (diagnostics/'thread-waits.json').write_text(json.dumps(tasks,indent=2)+'\n')
     try:
      with trace.open('x') as stream:
       trace.chmod(0o600);probe=subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,timeout=15)
      detail['child_exit']=probe.returncode
     except Exception as error:detail['error']=type(error).__name__+': '+str(error)
     detail['elapsed_seconds']=time.monotonic()-detail['started_monotonic'];detail['private_trace']=str(trace)
     (diagnostics/'capture.json').write_text(json.dumps(detail,indent=2)+'\n');diagnostic_result.update(detail)
    with (a.private / (label + '-raw.log')).open('x') as log:
        while True:
            try: line = lines.get(timeout=60)
            except queue.Empty:
                child.kill();child.wait()
                records.append({'command':command,'child_exit':child.returncode,'watchdog':True,'diagnostic':diagnostic_result}); raise RuntimeError('No progress before original watchdog')
            if line is None: break
            log.write(line); log.flush(); text += line; print(line.rstrip(), flush=True)
            if line.startswith('M4_R1_SHUTDOWN ') and '"phase":"close-enter"' in line:
                diagnostic_timer=threading.Timer(20,capture_owned_stall);diagnostic_timer.start()
            try: deliver(line,child.pid,a.desktop,native_inputs)
            except Exception:
                child.kill();child.wait();records.append({'phase':phase,'command':command,'child_exit':child.returncode,'passed':False,'native_input_failed':True});raise
            if line.startswith('M1B_CRASH_SEAM ') and kill: child.kill(); killed = True
    if diagnostic_timer is not None:diagnostic_timer.cancel();diagnostic_timer.join(timeout=16)
    raw=a.private/(label+'-raw.log');raw.chmod(0o600)
    def redact(match):
        values=re.findall(rb'\d+',match[0]);return b'<<REDACTED_BYTE_BINARY>>' if len(values) in (32,64) and all(int(v)<256 for v in values) else match[0]
    (a.evidence/(label+'.log')).write_bytes(re.sub(rb'<<\s*(?:\d+\s*,\s*)*\d+\s*>>',redact,raw.read_bytes()))
    child.wait()
    passed = child.returncode == (-9 if kill else 0) and 'ERROR:' not in text and (killed if kill else ('M1B_LOCAL_PASS' in text or phase == 'crash-recover' or (phase == 'menu' and 'M2_MENU_PASS' in text)))
    records.append({'phase': phase, 'case': label, 'command': command, 'child_exit': child.returncode, 'external_sigkill_at_observed_seam': killed, 'passed': passed})
    if not passed: raise RuntimeError('Exported phase failed: ' + phase)
try:
    if a.phase != 'crash': run(a.phase, a.private / 'identity')
    else:
        source = a.journey_private / 'fresh-store'
        state = json.loads((source / 'active.json').read_text())
        if not state['Pending']: raise RuntimeError('Crash check requires actual original signed Save in source outbox')
        for boundary in ('before-rename', 'after-rename'):
            profile = a.private / boundary; shutil.copytree(source, profile)
            before_hash = hashlib.sha256((profile / 'active.json').read_bytes()).hexdigest()
            original = a.private / (boundary + '-original.json')
            run('crash-' + boundary, profile, {'M1B_CRASH_ORIGINAL': str(original)}, kill=True)
            expected = state['Endpoint'] if boundary == 'before-rename' else 'https://atomic-boundary.example:14570'
            run('crash-recover', profile, {'M1B_CRASH_ORIGINAL': str(original), 'M1B_EXPECT_ENDPOINT': expected}, label='crash-recover-' + boundary)
            records.append({'boundary': boundary, 'source_active_sha256': before_hash, 'recovered_active_sha256': hashlib.sha256((profile / 'active.json').read_bytes()).hexdigest(), 'original_signed_outbox_count': len(state['Pending'])})
finally:
    (a.evidence / 'result.json').write_text(json.dumps(records, indent=2) + '\n')
    (a.evidence / 'native-input.json').write_text(json.dumps(native_inputs, indent=2) + '\n')

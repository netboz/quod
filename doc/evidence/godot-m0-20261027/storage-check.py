#!/usr/bin/env python3
"""Process-crash qualification of the exported probe; only public fixture keys."""
import hashlib
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import tempfile

root=Path(__file__).resolve().parents[3]
out=Path(__file__).resolve().parent/'logs'/os.environ.get('M0_STORAGE_RUN','storage-detail-02')
out.mkdir(exist_ok=False)
exe='/tmp/quod-godot-m0-export/m0.x86_64'
env=dict(os.environ,XDG_DATA_HOME='/tmp/quod-m0-godot-data',XDG_CONFIG_HOME='/tmp/quod-m0-godot-config',M0_CORPUS=str(root/'client/test/fixtures/native-contract/contracts.json'))
env.pop('LD_LIBRARY_PATH',None);env.pop('LD_PRELOAD',None)
results=[]
with tempfile.TemporaryDirectory(prefix='quod-m0-identity-') as directory:
    env['M0_STORE']=str(Path(directory)/'identity')
    def run(label,mode,expected=0,trace=False,**values):
        e=dict(env,M0_MODE=mode,**values)
        command=[exe,'--headless']
        if trace:command=['strace','-f','-qq','-e','trace=openat,write,fsync,fdatasync,rename,renameat,renameat2','-o',str(out/(label+'.strace')),*command]
        if mode.startswith('crash-'):
            child=subprocess.Popen(command,env=e,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True)
            captured=b''
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(child.stdout,selectors.EVENT_READ)
                    while b'CRASH_SEAM ' not in captured:
                        assert selector.select(15),'fault seam did not become ready'
                        block=os.read(child.stdout.fileno(),4096);assert block,'process exited before fault seam';captured+=block
                os.killpg(child.pid,signal.SIGKILL)
                remaining,_=child.communicate(timeout=10);captured+=remaining
            finally:
                if child.poll() is None:os.killpg(child.pid,signal.SIGKILL);child.wait()
            r=subprocess.CompletedProcess(command,child.returncode,captured,b'')
        else:r=subprocess.run(command,env=e,capture_output=True,timeout=25)
        text=(r.stdout+r.stderr).decode(errors='replace');(out/(label+'.log')).write_text(text)
        results.append(dict(label=label,command=command,mode=mode,child_exit=r.returncode,expected_exit=expected))
        assert r.returncode==expected,(label,r.returncode,text)
        if expected==0:assert 'M0_PROBE_PASS' in text and 'ERROR:' not in text,(label,text)
    run('storage-initial-01','save',M0_VALUE='original-U-A-S0',trace=True)
    active=Path(env['M0_STORE'])/'active.json'
    assert active.stat().st_mode&0o777==0o600
    assert active.parent.stat().st_mode&0o777==0o700
    before=(active.stat().st_ino,active.stat().st_mtime_ns,hashlib.sha256(active.read_bytes()).hexdigest())
    for n in [1,2]:run('storage-read-0'+str(n),'read',M0_EXPECT='original-U-A-S0',trace=True)
    after=(active.stat().st_ino,active.stat().st_mtime_ns,hashlib.sha256(active.read_bytes()).hexdigest())
    assert before==after,'unchanged recovery wrote active identity'
    run('storage-crash-before-01','crash-before-rename',-9,M0_VALUE='updated-account',trace=True)
    run('storage-before-recovery-01','read',M0_EXPECT='original-U-A-S0')
    run('storage-crash-after-01','crash-after-rename',-9,M0_VALUE='updated-account',trace=True)
    run('storage-after-recovery-01','read',M0_EXPECT='updated-account')
    run('storage-update-01','save',M0_VALUE='durable-update',trace=True)
    run('storage-update-recovery-01','read',M0_EXPECT='durable-update')
    hold=subprocess.Popen([exe,'--headless'],env=dict(env,M0_MODE='hold'),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(hold.stdout,selectors.EVENT_READ)
            received=b''
            while b'LOCK_HELD' not in received:
                assert selector.select(15),'lock holder did not become ready'
                block=os.read(hold.stdout.fileno(),4096)
                assert block,'lock holder exited before readiness'
                received+=block
        run('storage-second-writer-01','save',1,M0_VALUE='must-not-replace')
    finally:
        hold.communicate(b'\n',timeout=10)
        results.append(dict(label='storage-lock-owner',child_exit=hold.returncode))
    active.chmod(0o644);run('storage-permissions-01','read',1,M0_EXPECT='durable-update');active.chmod(0o600)
    saved=active.read_bytes();active.write_text('{corrupt');run('storage-corrupt-01','read',1,M0_EXPECT='durable-update');assert active.read_text()=='{corrupt';active.write_bytes(saved)
    active.rename(active.with_suffix('.original'));active.symlink_to(active.with_suffix('.original'))
    run('storage-symlink-01','read',1,M0_EXPECT='durable-update')
    # Scope the syscall assertions to this application's own state paths and durability calls.
    for label in ['storage-read-01','storage-read-02']:
        trace=(out/(label+'.strace')).read_text();assert 'fsync(' not in trace and 'fdatasync(' not in trace
        assert not any('active.json' in line and ('O_WRONLY' in line or 'O_RDWR' in line) for line in trace.splitlines())
    for label in ['storage-initial-01','storage-update-01']:
        trace=(out/(label+'.strace')).read_text();assert trace.count('fsync(')>=2,label
result=dict(pass_=True,unchanged_active_identity=True,unchanged_read_sync_calls=0,actual_update_durable=True,crash_model='external SIGKILL after explicit fsync/rename seam notification; no graceful shutdown or power-cut claim',children=results)
(out/'storage-result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))

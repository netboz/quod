#!/usr/bin/env python3
"""Probe actual Vive devices with private Valve-driver state and true exit."""
import argparse,hashlib,json,os,re,shutil,subprocess,time
from pathlib import Path
from private_vive import prepare,unchanged,active_runtime_processes

evidence=Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('label');p.add_argument('--diagnose',action='store_true');p.add_argument('--runtime-prefix',type=Path);p.add_argument('--debug-interfaces',action='store_true');a=p.parse_args()
label=a.label;out=evidence/label;out.mkdir(exist_ok=False)
private=Path('/home/yan/.cache/quod-m4-r2-artifacts/private')/label;private.mkdir(mode=0o700)
for name in ['runtime','config','data']:(private/name).mkdir(mode=0o700)
shutil.copy2(__file__,out/'hardware-probe-driver.py');shutil.copy2(evidence/'private_vive.py',out/'private_vive.py')
running=active_runtime_processes();record={'preexisting_runtime_processes':running,'physical_acceptance':False}
if running:raise RuntimeError('An existing runtime is active; do not interfere')
prefix,extra,before=prepare(private)
libs='' if a.runtime_prefix else json.loads((evidence/'inputs/private-library-path.json').read_text())['LD_LIBRARY_PATH']
env=dict(os.environ,LD_LIBRARY_PATH=libs,XDG_RUNTIME_DIR=str(private/'runtime'),XDG_CONFIG_HOME=str(private/'config'),XDG_DATA_HOME=str(private/'data'),**extra)
env.pop('LD_PRELOAD',None)
if a.debug_interfaces:env['LIGHTHOUSE_LOG']='debug'
runtime=a.runtime_prefix or Path('/home/yan/.cache/quod-m4-r2-artifacts/runtime/monado-system')
probe=[str(runtime/'bin/monado-cli'),'probe']
diagnostic=['gdb','-q','-nx','-batch','-ex','set auto-load off','-ex','set print frame-arguments none','-ex','set print entry-values no','-ex','run','-ex','thread apply all bt 20','--args'] if a.diagnose else []
command=prefix+diagnostic+probe
record['command']=command;record['configuration_isolation']='read-only root; private writable case and private Steam configuration bind; HOME unchanged'
with (private/'raw.log').open('xb') as log:
 start=time.monotonic();child=subprocess.Popen(command,env=env,stdout=log,stderr=subprocess.STDOUT)
 try:record['child_exit']=child.wait(timeout=30);record['timed_out']=False
 except subprocess.TimeoutExpired:child.kill();record['child_exit']=child.wait();record['timed_out']=True
record['elapsed_seconds']=time.monotonic()-start;record['original_lighthouse_unchanged']=unchanged(before)
raw=(private/'raw.log').read_bytes();(private/'raw.log').chmod(0o600)
public=re.sub(rb'(?i)LHR-[A-Za-z0-9]+',b'<device-serial-redacted>',raw)
(record.update(inferior_crashed=True) if b'received signal' in raw else None)
(out/'probe.log').write_bytes(public);record['raw_sha256']=hashlib.sha256(raw).hexdigest();record['sanitized_sha256']=hashlib.sha256(public).hexdigest()
record['private_calibration_files']=len(before)
(out/'result.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record))
raise SystemExit(0 if record['child_exit']==0 and not record['timed_out'] and not record.get('inferior_crashed') and record['original_lighthouse_unchanged'] else 1)

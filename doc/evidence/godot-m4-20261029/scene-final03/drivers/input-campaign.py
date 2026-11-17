#!/usr/bin/env python3
"""Run the real engine's shared input/render consumers without a server fixture."""
import argparse,hashlib,json,os,queue,shutil,subprocess,sys,threading
from pathlib import Path
sys.dont_write_bytecode=True
p=argparse.ArgumentParser();p.add_argument('label');p.add_argument('--engine',required=True);p.add_argument('--project');p.add_argument('--desktop',action='store_true');p.add_argument('--phase',default='controller-input');a=p.parse_args()
root=Path.cwd();evidence=Path(__file__).resolve().parent;out=evidence/a.label;out.mkdir(exist_ok=False)
drivers=out/'drivers';drivers.mkdir()
for path in [Path(__file__).resolve(),root/'client/godot-tests/desktop_input.py']:shutil.copy2(path,drivers/path.name)
sys.path.insert(0,str(drivers));from desktop_input import deliver
private=Path('/tmp/quod-m4-ca84d4f8/private')/a.label;private.mkdir(parents=True,mode=0o700,exist_ok=False)
command=[a.engine]+(['--display-driver','wayland'] if a.desktop else ['--headless'])
if a.project:command+=['--path',a.project]
command+=['--','--qualification','--profile',str(private/'identity')]
env=dict(os.environ,M1B_PHASE=a.phase,M1B_RESULT=str(out/'client-result.json'),M4_MODEL=str(root/'priv/explorer/assets/models/bd201855c8114b9b0e9cdd465d6f08413d18604894c839fb78d54d890c2adc94.glb'),M4_MAPPING=str(evidence/'inputs/injected-mapping.term'),XDG_DATA_HOME=str(private/'data'),XDG_CONFIG_HOME=str(private/'config'))
record=dict(command=command,desktop=a.desktop,physical_acceptance=False,driver_hashes={x.name:hashlib.sha256(x.read_bytes()).hexdigest() for x in drivers.iterdir()},native_input=[])
child=subprocess.Popen(command,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);lines=queue.Queue()
def receive():
 for line in child.stdout:lines.put(line)
 lines.put(None)
threading.Thread(target=receive,daemon=True).start()
try:
 with (out/'client.log').open('x') as log:
  while True:
   line=lines.get(timeout=60)
   if line is None:break
   log.write(line);log.flush();deliver(line,child.pid,a.desktop,record['native_input'])
 record['child_exit']=child.wait(timeout=10)
 record['passed']=record['child_exit']==0 and (out/'client-result.json').exists() and 'ERROR:' not in (out/'client.log').read_text()
except Exception as error:record['error']=str(error);record['passed']=False
finally:
 if child.poll() is None:child.kill();record['child_exit']=child.wait(timeout=10)
 (out/'result.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record))
sys.exit(0 if record['passed'] else 1)

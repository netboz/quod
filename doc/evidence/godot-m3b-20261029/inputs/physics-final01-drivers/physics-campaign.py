#!/usr/bin/env python3
"""Own real shared-domain HTTPS/WSS, native input and the exported renderer."""
import argparse,hashlib,json,os,queue,shutil,subprocess,sys,threading
from pathlib import Path
sys.dont_write_bytecode=True
p=argparse.ArgumentParser();p.add_argument('label');p.add_argument('--client',required=True);p.add_argument('--stage',required=True);p.add_argument('--profile',default='test');a=p.parse_args()
root=Path.cwd();evidence=Path(__file__).resolve().parent;out=evidence/a.label;out.mkdir(exist_ok=False)
drivers=evidence/'inputs'/(a.label+'-drivers');drivers.mkdir(exist_ok=False)
driver_inputs={}
for source in [Path(__file__).resolve(),root/'client/godot-tests/desktop_input.py']:
 retained=drivers/source.name;shutil.copy2(source,retained);driver_inputs[str(source.relative_to(root))]=hashlib.sha256(retained.read_bytes()).hexdigest()
sys.path.insert(0,str(drivers))
from desktop_input import deliver
private=Path('/home/yan/.cache/quod-m3b-artifacts/private');profile=private/a.label;profile.mkdir(mode=0o700,parents=True,exist_ok=False)
server_label=a.label+'-server';server_private=private/('quod-m3b-live-'+server_label)
command=['python3',str(evidence/'serve.py'),server_label,'--stage',a.stage,'--profile',a.profile,'--qualified','--physics']
server=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
lines=queue.Queue()
def receive(process,target):
 for line in process.stdout:target.put(line)
 target.put(None)
threading.Thread(target=receive,args=(server,lines),daemon=True).start()
record=dict(server_command=command,passed=False,native_input=[],driver_inputs=driver_inputs,retained_drivers=str(drivers));child=None
try:
 while True:
  line=lines.get(timeout=60)
  if line is None:raise RuntimeError('Physics fixture ended before readiness')
  print(line.rstrip(),flush=True)
  if line.startswith('M1B_READY '):ready=json.loads(line[len('M1B_READY '):]);break
 record['endpoint']=ready
 transfer=['docker','cp','quod-m3b-live-'+server_label+':/m1b/viewer.json',str(profile/'viewer.json')]
 copied=subprocess.run(transfer,capture_output=True,text=True);record['private_key_transfer']={'command':transfer,'child_exit':copied.returncode}
 if copied.returncode:raise RuntimeError('Private disposable viewer key transfer failed: '+copied.stderr)
 (profile/'viewer.json').chmod(0o600)
 env=dict(os.environ,M1B_PHASE='physics',M1B_RESULT=str(out/'client-result.json'),M3_PHYSICS_META=str(server_private/'physics.json'),M3_PHYSICS_KEY=str(profile/'viewer.json'),M1B_CONTROL_PORT=str(ready['control_port']),M3_NODE='https://127.0.0.1:'+str(ready['port']),M3_CA=str(server_private/'backend-ca.pem'),M3_SCENE_CAPTURE=str(out/'physics.png'),DOTNET_ROOT=str(profile/'no-installed-runtime'),XDG_DATA_HOME=str(profile/'data'),XDG_CONFIG_HOME=str(profile/'config'))
 command=[str(Path('/home/yan/.cache/quod-m3b-artifacts')/('quod-m3b-client-'+a.client)/'source/client/godot/dist/quod.x86_64'),'--display-driver','wayland','--','--qualification','--profile',str(profile/'identity')]
 record['client_command']=command
 child=subprocess.Popen(command,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
 output=queue.Queue();threading.Thread(target=receive,args=(child,output),daemon=True).start();text=''
 with (out/'client.log').open('x') as log:
  while True:
   line=output.get(timeout=60)
   if line is None:break
   log.write(line);log.flush();text+=line;print(line.rstrip(),flush=True);deliver(line,child.pid,True,record['native_input'])
 record['client_child_exit']=child.wait(timeout=10);record['passed']=record['client_child_exit']==0 and 'M3_PHYSICS_PASS' in text and 'ERROR:' not in text
 if not record['passed']:raise RuntimeError('Exported physics journey did not complete')
except Exception as error:record['failure']=type(error).__name__+': '+str(error)
finally:
 if child is not None and child.poll() is None:child.kill();record['client_child_exit']=child.wait(timeout=10)
 if any(r['command']==['ydotool','key','17:1'] for r in record['native_input']):
  env=dict(os.environ,YDOTOOL_SOCKET=str(Path('/run/user')/str(os.getuid())/'.ydotool_socket'))
  released=subprocess.run(['ydotool','key','17:0'],env=env,capture_output=True,text=True);record['final_input_release_exit']=released.returncode
 try:server.stdin.write('stop\n');server.stdin.flush();server.stdin.close();record['server_child_exit']=server.wait(timeout=30)
 except Exception as error:record['stop_error']=str(error);server.terminate();record['server_child_exit']=server.wait(timeout=10)
 raw=server_private/'server-raw.log'
 if raw.exists():subprocess.run(['python3',str(evidence/'run.py'),a.label+'-server-log','--','cat',str(raw)])
 (out/'campaign.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record),flush=True)
if not record['passed'] or record.get('server_child_exit')!=0:sys.exit(1)

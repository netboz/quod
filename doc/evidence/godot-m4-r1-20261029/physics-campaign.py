#!/usr/bin/env python3
"""Own real shared-domain HTTPS/WSS, native input and the exported renderer."""
import argparse,hashlib,json,os,queue,shutil,subprocess,sys,threading,ctypes,time,re
from pathlib import Path
sys.dont_write_bytecode=True
p=argparse.ArgumentParser();p.add_argument('label');p.add_argument('--export',type=Path,required=True);p.add_argument('--stage',required=True);p.add_argument('--profile',default='test');a=p.parse_args()
root=Path.cwd();evidence=Path(__file__).resolve().parent;out=evidence/a.label;out.mkdir(exist_ok=False)
drivers=evidence/'inputs'/(a.label+'-drivers');drivers.mkdir(exist_ok=False)
driver_inputs={}
for source in [Path(__file__).resolve(),root/'client/godot-tests/desktop_input.py']:
 retained=drivers/source.name;shutil.copy2(source,retained);driver_inputs[str(source.relative_to(root))]=hashlib.sha256(retained.read_bytes()).hexdigest()
sys.path.insert(0,str(drivers))
from desktop_input import deliver
private=Path('/home/yan/.cache/quod-m4-r1-artifacts/artifacts/private');profile=private/a.label;profile.mkdir(mode=0o700,parents=True,exist_ok=False)
server_label=a.label+'-server';server_private=private/('quod-m4-live-'+server_label)
command=['python3',str(evidence/'serve.py'),server_label,'--stage',a.stage,'--profile',a.profile,'--qualified','--physics']
server=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
lines=queue.Queue()
def receive(process,target):
 for line in process.stdout:target.put(line)
 target.put(None)
threading.Thread(target=receive,args=(server,lines),daemon=True).start()
record=dict(server_command=command,passed=False,native_input=[],driver_inputs=driver_inputs,retained_drivers=str(drivers));child=None
diagnostic_timer=None
def capture_owned_stall():
 if child is None or child.poll() is not None:return
 diagnostics=profile/'diagnostics';diagnostics.mkdir(mode=0o700,exist_ok=False)
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
 (diagnostics/'capture.json').write_text(json.dumps(detail,indent=2)+'\n');record['diagnostic']=detail

try:
 while True:
  line=lines.get(timeout=60)
  if line is None:raise RuntimeError('Physics fixture ended before readiness')
  print(line.rstrip(),flush=True)
  if line.startswith('M1B_READY '):ready=json.loads(line[len('M1B_READY '):]);break
 record['endpoint']=ready
 transfer=['docker','cp','quod-m4-live-'+server_label+':/m1b/viewer.json',str(profile/'viewer.json')]
 copied=subprocess.run(transfer,capture_output=True,text=True);record['private_key_transfer']={'command':transfer,'child_exit':copied.returncode}
 if copied.returncode:raise RuntimeError('Private disposable viewer key transfer failed: '+copied.stderr)
 (profile/'viewer.json').chmod(0o600)
 env=dict(os.environ,M1B_PHASE='physics',M1B_RESULT=str(out/'client-result.json'),M3_PHYSICS_META=str(server_private/'physics.json'),M3_PHYSICS_KEY=str(profile/'viewer.json'),M1B_CONTROL_PORT=str(ready['control_port']),M3_NODE='https://127.0.0.1:'+str(ready['port']),M3_CA=str(server_private/'backend-ca.pem'),M3_SCENE_CAPTURE=str(out/'physics.png'),DOTNET_ROOT=str(profile/'no-installed-runtime'),XDG_DATA_HOME=str(profile/'data'),XDG_CONFIG_HOME=str(profile/'config'))
 env['M4_MAPPING']=str(root/'doc/evidence/godot-m4-20261029/inputs/injected-mapping.term')
 command=[str(a.export),'--display-driver','wayland','--','--qualification','--profile',str(profile/'identity')]
 record['client_command']=command;record['executable_sha256']=hashlib.sha256(a.export.read_bytes()).hexdigest()
 def allow_owned_trace():
  if ctypes.CDLL(None).prctl(0x59616d61,os.getppid(),0,0,0)!=0:os._exit(125)
 child=subprocess.Popen(command,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,preexec_fn=allow_owned_trace)
 output=queue.Queue();threading.Thread(target=receive,args=(child,output),daemon=True).start();text=''
 with (profile/'client-raw.log').open('x') as log:
  while True:
   line=output.get(timeout=60)
   if line is None:break
   log.write(line);log.flush();text+=line;print(line.rstrip(),flush=True);deliver(line,child.pid,True,record['native_input'])
   if line.startswith('M3_PHYSICS_PASS'):
    diagnostic_timer=threading.Timer(20,capture_owned_stall);diagnostic_timer.start()
 record['client_child_exit']=child.wait(timeout=10);record['passed']=record['client_child_exit']==0 and 'M3_PHYSICS_PASS' in text and 'ERROR:' not in text
 if not record['passed']:raise RuntimeError('Exported physics journey did not complete')
except Exception as error:
 record['failure']=type(error).__name__+': '+str(error)

finally:
 if diagnostic_timer is not None:
  diagnostic_timer.cancel();diagnostic_timer.join(timeout=16)
 raw_client=profile/'client-raw.log'
 if raw_client.exists():
  raw_client.chmod(0o600)
  def redact(match):
   values=re.findall(rb'\d+',match[0])
   return b'<<REDACTED_BYTE_BINARY>>' if len(values) in (32,64) and all(int(v)<256 for v in values) else match[0]
  data=raw_client.read_bytes();(out/'client.log').write_bytes(re.sub(rb'<<\s*(?:\d+\s*,\s*)*\d+\s*>>',redact,data))
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

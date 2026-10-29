#!/usr/bin/env python3
"""Own the disposable endpoint until its installed-client campaign completes."""
import argparse,hashlib,json,queue,shutil,subprocess,sys,threading
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('label');p.add_argument('--client',required=True);p.add_argument('--stage',required=True);p.add_argument('--profile',default='test');p.add_argument('--journey',default='navigation');p.add_argument('--desktop',action='store_true');a=p.parse_args()
root=Path.cwd();evidence=Path(__file__).resolve().parent
private=Path('/home/yan/.cache/quod-m3b-artifacts/private');export=Path('/home/yan/.cache/quod-m3b-artifacts')/('quod-m3b-client-'+a.client)/'source/client/godot/dist/quod.x86_64'
label=a.label;server_label=label+'-server';result_path=evidence/(label+'-campaign.json');assert not result_path.exists()
drivers=evidence/'inputs'/(label+'-drivers');drivers.mkdir(exist_ok=False)
driver_inputs={}
for source in [Path(__file__).resolve(),root/'client/godot-tests/journey.py',root/'client/godot-tests/local.py',root/'client/godot-tests/desktop_input.py']:
 retained=drivers/source.name;shutil.copy2(source,retained);driver_inputs[str(source.relative_to(root))]=hashlib.sha256(retained.read_bytes()).hexdigest()
command=['python3',str(evidence/'serve.py'),server_label,'--stage',a.stage,'--profile',a.profile,'--qualified']
server=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
lines=queue.Queue()
def receive():
 for line in server.stdout:lines.put(line)
 lines.put(None)
threading.Thread(target=receive,daemon=True).start()
result=dict(server_command=command,client=a.client,passed=False,commands=[],driver_inputs=driver_inputs,retained_drivers=str(drivers))
runner=['python3',str(evidence/'run.py')]
def run(name,args):
 command=runner+['--timeout','900',name,'--']+args
 child=subprocess.run(command);result['commands'].append(dict(command=command,child_exit=child.returncode))
 if child.returncode:raise RuntimeError('Failed '+name)
try:
 while True:
  line=lines.get(timeout=60)
  if line is None:raise RuntimeError('Endpoint ended before readiness')
  print(line.rstrip(),flush=True)
  if line.startswith('M1B_READY '):ready=json.loads(line[len('M1B_READY '):]);break
 result['endpoint']=ready
 ca=str(private/('quod-m3b-live-'+server_label)/'backend-ca.pem')
 args=['python3',str(drivers/'journey.py'),'--journey',a.journey,'--export',str(export),'--backend-port',str(ready['port']),'--backend-ca',ca,'--control-port',str(ready['control_port']),'--network',ready['network'],'--evidence',str(evidence/label),'--private',str(private/label)]
 if a.desktop:args+=['--desktop']
 run(label+'-journey',args)
 if a.journey in ('navigation','gui'):
  args=['env','M3_ROUTE='+str(private/label/'route.json')] if a.journey=='navigation' else []
  args+=['python3',str(drivers/'local.py'),'--phase','backup-import','--export',str(export),'--journey-private',str(private/label),'--node','https://127.0.0.1:'+str(ready['port']),'--ca',ca,'--evidence',str(evidence/(label+'-backup-import')),'--private',str(private/(label+'-backup-import'))]
  if a.desktop:args+=['--desktop']
  run(label+'-backup-import',args)
 result['passed']=True
except Exception as error:result['failure']=str(error)
finally:
 try:
  server.stdin.write('stop\n');server.stdin.flush();server.stdin.close();result['server_child_exit']=server.wait(timeout=30)
 except Exception as error:
  result['stop_error']=str(error);server.terminate();result['server_child_exit']=server.wait(timeout=10)
 raw=private/('quod-m3b-live-'+server_label)/'server-raw.log'
 if raw.exists():subprocess.run(runner+[label+'-server-log','--','cat',str(raw)])
 result_path.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result),flush=True)
if not result['passed'] or result.get('server_child_exit')!=0:sys.exit(1)

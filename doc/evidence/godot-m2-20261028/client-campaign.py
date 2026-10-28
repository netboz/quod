#!/usr/bin/env python3
"""Own a disposable qualified endpoint through the complete client campaign."""
import json,os,queue,subprocess,sys,threading,time
from pathlib import Path
root=Path.cwd(); evidence=root/'doc/evidence/godot-m2-20261028'
label,client_label=sys.argv[1:]
result_path=evidence/(label+'-campaign.json'); assert not result_path.exists()
server_label=label+'-server'; private=Path('/home/yan/.cache/quod-m2-artifacts/private')
export=Path('/home/yan/.cache/quod-m2-artifacts')/('quod-m2-client-'+client_label)/'source/client/godot/dist/quod.x86_64'
command=['python3',str(evidence/'serve.py'),server_label,'--stage','/home/yan/.cache/quod-m2-artifacts/quod-m2-gates02/source','--profile','prod','--qualified']
server=subprocess.Popen(command,cwd=root,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
lines=queue.Queue()
def receive():
 for line in server.stdout: lines.put(line)
 lines.put(None)
threading.Thread(target=receive,daemon=True).start()
result=dict(label=label,client=client_label,server_command=command,commands=[],passed=False)
runner=['python3',str(evidence/'run.py')]
def run(name,args):
 command=runner+[name+'-command','--']+args;started=time.monotonic()
 status=subprocess.run(command,cwd=root).returncode
 result['commands'].append(dict(label=name,command=command,child_exit=status,elapsed_seconds=time.monotonic()-started))
 if status: raise RuntimeError('Failed '+name)
try:
 while True:
  line=lines.get(timeout=60)
  if line is None:raise RuntimeError('Fixture ended before readiness')
  print(line.rstrip(),flush=True)
  if line.startswith('M1B_READY '):ready=json.loads(line[len('M1B_READY '):]);break
 result['endpoint']=ready
 ca=str(private/('quod-m2-live-'+server_label)/'backend-ca.pem')
 for journey in ['spaces','gui']:
  name=label+('-m2' if journey=='spaces' else '-m1')
  args=['python3','client/godot-tests/journey.py','--journey',journey,'--desktop','--export',str(export),'--backend-port',str(ready['port']),'--backend-ca',ca,'--control-port',str(ready['control_port']),'--network',ready['network'],'--evidence',str(evidence/name),'--private',str(private/name)]
  try:run(name,args)
  except Exception:
   profile=private/name/'identity/active.json'
   if profile.exists():
    probe=['dotnet','run','--no-build','--project',str(private/'operation-read-probe01/probe.csproj'),'--',str(profile),str(private/(name+'-read-probe')),'https://127.0.0.1:'+str(ready['port']),ca]
    try:run(name+'-read-probe',probe)
    except Exception as error:result['probe_error']=str(error)
   raise
 run(label+'-backup-import',['python3','client/godot-tests/local.py','--phase','backup-import','--desktop','--export',str(export),
  '--journey-private',str(private/(label+'-m1')),'--node','https://127.0.0.1:'+str(ready['port']),'--ca',ca,
  '--evidence',str(evidence/(label+'-backup-import')),'--private',str(private/(label+'-backup-import'))])
 result['passed']=True
except Exception as error:
 result['failure']=str(error)
finally:
 try:
  server.stdin.write('stop\n');server.stdin.flush();server.stdin.close()
  result['server_child_exit']=server.wait(timeout=30)
 except Exception as error:
  result['server_stop_error']=str(error);server.terminate();result['server_child_exit']=server.wait(timeout=10)
 subprocess.run(runner+[label+'-server-log','--','cat',str(private/('quod-m2-live-'+server_label)/'server-raw.log')],cwd=root)
 result_path.write_text(json.dumps(result,indent=2)+'\n')
 print(json.dumps({k:v for k,v in result.items() if k!='commands'}),flush=True)
if not result['passed'] or result.get('server_child_exit')!=0:sys.exit(1)

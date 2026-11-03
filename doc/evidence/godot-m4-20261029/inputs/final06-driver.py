#!/usr/bin/env python3
"""Sequential exported seams on one immutable client input set."""
import hashlib,json,subprocess,sys,shutil
from pathlib import Path
root=Path.cwd();evidence=Path(__file__).resolve().parent
client=json.loads((evidence/'inputs/client-candidate09-manifest.json').read_text());assert client['passed']
source=Path(client['source']);exe=client['export_executable'];stage='/tmp/quod-m3b-8b352c53/m3b-gates01/source'
result=evidence/'final06-result.json';assert not result.exists()
retained=evidence/'inputs/final06-driver.py';assert not retained.exists();shutil.copy2(Path(__file__),retained)
shutil.copy2(root/'client/godot-tests/local.py',evidence/'inputs/final06-local.py');shutil.copy2(root/'client/godot-tests/desktop_input.py',evidence/'inputs/desktop_input.py')
record=dict(client='candidate09',source=str(source),commands=[],passed=False,unchanged_server_gates_reused=True,retained_driver=str(retained),driver_sha256=hashlib.sha256(retained.read_bytes()).hexdigest())
def verify():
 for name,h in client['authored_inputs'].items():
  assert hashlib.sha256((root/name).read_bytes()).hexdigest()==h,name
  assert hashlib.sha256((source/name).read_bytes()).hexdigest()==h,name
def python(name):return ['python3',str(evidence/name)]
commands=[('input-final07',python('input-campaign.py')+['input-final07','--engine',exe,'--desktop']),
          ('scene-final07',python('input-campaign.py')+['scene-final07','--engine',exe,'--desktop','--phase','scene'])]
for label,journey in [('gui-final06','gui'),('spaces-final06','spaces'),('navigation-final06','navigation')]:
 commands.append((label,python('campaign.py')+[label,'--client','candidate09','--stage',stage,'--profile','prod','--journey',journey,'--desktop']+(['--controllers'] if journey=='gui' else [])))
commands.append(('physics-final08',python('physics-campaign.py')+['physics-final08','--client','candidate09','--stage',stage,'--profile','prod']))
try:
 for label,command in commands:
  verify();full=python('run.py')+['--timeout','900',label,'--']+command
  child=subprocess.run(full);record['commands'].append(dict(label=label,command=full,child_exit=child.returncode))
  result.write_text(json.dumps(record,indent=2)+'\n')
  if child.returncode:raise RuntimeError('Failed '+label)
 for iteration in range(1,6):
  label='shutdown-final06-'+str(iteration)
  verify();full=python('run.py')+['--timeout','300',label,'--','python3',str(evidence/'inputs/final06-local.py'),'--phase','crypto','--export',exe,'--evidence',str(evidence/label),'--private','/tmp/quod-m4-ca84d4f8/artifacts/private/'+label,'--desktop']
  child=subprocess.run(full);record['commands'].append(dict(label=label,command=full,child_exit=child.returncode));result.write_text(json.dumps(record,indent=2)+'\n')
  if child.returncode:raise RuntimeError('Failed '+label)
 verify();record.update(passed=True,source_unchanged=True,all_true_child_exits_zero=True)
except Exception as error:record['failure']=str(error)
finally:result.write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record),flush=True)
sys.exit(0 if record['passed'] else 1)

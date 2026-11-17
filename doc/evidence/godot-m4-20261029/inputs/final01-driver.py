#!/usr/bin/env python3
"""Sequential exported seams on one immutable client input set."""
import hashlib,json,subprocess,sys
from pathlib import Path
root=Path.cwd();evidence=Path(__file__).resolve().parent
client=json.loads((evidence/'inputs/client-final01-manifest.json').read_text());assert client['passed']
source=Path(client['source']);exe=client['export_executable'];stage='/tmp/quod-m3b-8b352c53/m3b-gates01/source'
result=evidence/'final01-result.json';assert not result.exists()
record=dict(client='final01',source=str(source),commands=[],passed=False,unchanged_server_gates_reused=True)
def verify():
 for name,h in client['authored_inputs'].items():
  assert hashlib.sha256((root/name).read_bytes()).hexdigest()==h,name
  assert hashlib.sha256((source/name).read_bytes()).hexdigest()==h,name
def python(name):return ['python3',str(evidence/name)]
commands=[('input-final02',python('input-campaign.py')+['input-final02','--engine',exe,'--desktop']),
          ('scene-final02',python('input-campaign.py')+['scene-final02','--engine',exe,'--desktop','--phase','scene'])]
for label,journey in [('gui-final01','gui'),('spaces-final01','spaces'),('navigation-final01','navigation')]:
 commands.append((label,python('campaign.py')+[label,'--client','final01','--stage',stage,'--profile','prod','--journey',journey,'--desktop']+(['--controllers'] if journey=='gui' else [])))
commands.append(('physics-final03',python('physics-campaign.py')+['physics-final03','--client','final01','--stage',stage,'--profile','prod']))
try:
 for label,command in commands:
  verify();full=python('run.py')+['--timeout','900',label,'--']+command
  child=subprocess.run(full);record['commands'].append(dict(label=label,command=full,child_exit=child.returncode))
  result.write_text(json.dumps(record,indent=2)+'\n')
  if child.returncode:raise RuntimeError('Failed '+label)
 verify();record.update(passed=True,source_unchanged=True,all_true_child_exits_zero=True)
except Exception as error:record['failure']=str(error)
finally:result.write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record),flush=True)
sys.exit(0 if record['passed'] else 1)

#!/usr/bin/env python3
"""Index retained command receipts without equating process exits with acceptance."""
import json,hashlib,sys
from pathlib import Path
root=Path(__file__).resolve().parent
label=sys.argv[1]
records=[]
for path in sorted(root.rglob('*.json')):
 if path.name.startswith('run-index-'): continue
 try: data=json.loads(path.read_text())
 except (ValueError,UnicodeError): continue
 for position,row in enumerate(data if isinstance(data,list) else [data]):
  if not isinstance(row,dict): continue
  command=row.get('command',row.get('argv'))
  status=row.get('child_exit',row.get('exit'))
  if not isinstance(command,list) or status is None: continue
  expected=row.get('expected_exit',-9 if row.get('external_sigkill_at_observed_seam') else 0)
  diagnostic=bool(row.get('error_diagnostics') or row.get('godot_error_diagnostics') or row.get('diagnostic_failure'))
  records.append(dict(receipt=str(path.relative_to(root)),position=position,command=command,
   child_exit=status,expected_exit=expected,timed_out=bool(row.get('timed_out') or row.get('watchdog')),
   diagnostic_failure=diagnostic,recorded_pass=row.get('passed'),
   expected_exit_observed=status==expected and not diagnostic and not row.get('timed_out') and not row.get('watchdog') and row.get('passed') is not False,
   receipt_sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
result=dict(label=label,commands=len(records),expected_exits=sum(r['expected_exit_observed'] for r in records),
 retained_failed_or_incomplete=sum(not r['expected_exit_observed'] for r in records),records=records,
 note='An exit index is not milestone credit. Expected SIGKILL is checked separately. Failed campaigns, diagnostic probes and stop markers remain authoritative; final source/behavior qualification is recorded in the evidence index.')
with (root/'inputs'/('run-index-'+label+'.json')).open('x') as file:json.dump(result,file,indent=2);file.write('\n')
print(json.dumps({k:v for k,v in result.items() if k!='records'}))

"""Bind the narrow bootstrap correction without repeating prior parser cases."""
import hashlib,json,shutil,sys
from pathlib import Path
sys.dont_write_bytecode=True
ev=Path(__file__).resolve().parent;task=Path('/data/quod-m4-vr-ca84d4f8-20261029')
def load(p):return json.loads(Path(p).read_text())
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
source=task/'private/metadata-inputs/case10-deadline-checks01/focus_events.py'
assert source.read_bytes()==(ev/'focus_events.py').read_bytes()
result=load(ev/'deadline-checks-result.json');assert result['passed'] and result['count']==6 and result['exact_parser_class_unchanged']
assert load(ev/'deadline-checks01/result.json')['exit']==0 and not result['actual_listener_armed']
saved=ev/'qualification-before-bootstrap-fix.json';assert not saved.exists();shutil.copy2(ev/'qualification.json',saved)
q=load(saved);q['prepared_event_listener'].update(sha256=sha(source),exact_preexecution_source=str(source),
 bootstrap_deadline_checks=6,bootstrap_deadline_receipt='deadline-checks01/result.json',prior14_parser_checks_repeated=False,
 exact_parser_class_unchanged=True,parser_class_sha256=result['parser_class_sha256'],
 final_cli_delta='Each blocking bootstrap query/connect uses the same remaining absolute budget capped by the existing5s. Expired budget refuses the next operation; no new timer or live qualification.')
q['independent_case10_verification']={'path':'_build/godot-m4-r2-coordinator-20261029/case10-closure-check-84.json',
 'sha256':'4358704c5daf77d61efd424724ce299506cdbffb02286a52842258aac76a8767','scope':'Actual case10 closure/new API/published-redaction source checks, not future listener qualification or full M4.'}
(ev/'qualification.json').write_text(json.dumps(q,indent=2)+'\n')
print(json.dumps({'passed':True,'prior_parser_checks_reused':14,'new_deadline_checks':6,'no_live_listener':True,'final_source_sha256':sha(source)}))

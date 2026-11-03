"""Bind the final prepared-only CLI after its explicit selector cleanup delta."""
import hashlib,json,shutil,sys
from pathlib import Path
sys.dont_write_bytecode=True
ev=Path(__file__).resolve().parent;task=Path('/data/quod-m4-vr-ca84d4f8-20261029')
def load(p):return json.loads(Path(p).read_text())
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
first=task/'private/metadata-inputs/case10-focus-checks01/focus_events.py'
final=task/'private/metadata-inputs/case10-focus-checks02/focus_events.py'
assert (ev/'focus_events.py').read_bytes()==final.read_bytes()
assert first.read_text().split('def run():')[0]==final.read_text().split('def run():')[0]
assert load(ev/'focus-checks02/result.json')['exit']==0
assert load(ev/'focus-checks-result.json')['count']==14 and not load(ev/'focus-checks-result.json')['actual_listener_armed']
saved=ev/'qualification-before-final-cli.json';assert not saved.exists();shutil.copy2(ev/'qualification.json',saved)
q=load(saved);q['prepared_event_listener'].update(sha256=sha(final),exact_preexecution_source=str(final),pure_checks_receipt='focus-checks02/result.json',
 final_cli_delta='Selector resource now closes in finally on exceptional paths as well as normal completion; pure algorithm bytes unchanged. Prepared-only live execution remains UNRUN.')
(ev/'qualification.json').write_text(json.dumps(q,indent=2)+'\n')
print(json.dumps({'passed':True,'final_helper_sha256':sha(final),'final_pure_checks':14,'pure_algorithm_unchanged':True,'actual_listener_armed':False}))

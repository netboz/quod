"""Preserve completed test logs privately; redact only generated private keys."""
from pathlib import Path
import hashlib, json, re, shutil
base=Path(__file__).resolve().parent
gate=base/'release-gates-04'
private=Path('/home/yan/src/quod/_build/quo-58-webxr-20261026/view-correction-01/raw-gates-04')
private.mkdir(mode=0o700,exist_ok=False)
records=[]
for label in ['eunit','ct']:
    assert json.loads((gate/(label+'.exit.json')).read_text())['exit']==0
    path=gate/(label+'.log');raw=path.read_bytes()
    public,count=re.subn(rb"(\{'ECPrivateKey',\s*\d+,\s*)<<[\d,\s]+>>",rb'\1<<REDACTED_GENERATED_TEST_PRIVATE_KEY>>',raw)
    if count:
        target=private/path.name;shutil.copy2(path,target);target.chmod(0o600)
        path.write_bytes(public)
        records.append({'file':path.name,'redactions':count,'raw_sha256':hashlib.sha256(raw).hexdigest(),'public_sha256':hashlib.sha256(public).hexdigest()})
(gate/'log-redactions.json').write_text(json.dumps({'private_originals':str(private),'files':records},indent=2)+'\n')
print(json.dumps({'files':len(records),'redactions':sum(r['redactions'] for r in records)}))

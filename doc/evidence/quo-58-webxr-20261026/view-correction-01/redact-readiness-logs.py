"""Keep completed readiness diagnostics privately before redacting generated keys."""
from pathlib import Path
import hashlib, json, re, shutil
base = Path(__file__).resolve().parent
private = Path('/home/yan/src/quod/_build/quo-58-webxr-20261026/view-correction-01/raw-readiness-logs')
assert (base/'readiness-triage-04/verified-rebuilt.json').exists()
private.mkdir(mode=0o700, exist_ok=False)
records=[]
for number in range(1,5):
    scope=base/f'readiness-triage-{number:02d}'
    for path in sorted(scope.glob('*.log')):
        assert path.with_suffix('.exit.json').exists(), path
        raw=path.read_bytes()
        public,count=re.subn(rb"(\{'ECPrivateKey',\s*\d+,\s*)<<[\d,\s]+>>",rb'\1<<REDACTED_GENERATED_TEST_PRIVATE_KEY>>',raw)
        if count:
            target=private/path.relative_to(base);target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(path,target);target.chmod(0o600);path.write_bytes(public)
            records.append({'file':str(path.relative_to(base)),'redactions':count,'raw_sha256':hashlib.sha256(raw).hexdigest(),'public_sha256':hashlib.sha256(public).hexdigest()})
(base/'readiness-log-redactions.json').write_text(json.dumps({'private_originals':str(private),'files':records},indent=2)+'\n')
print(json.dumps({'files':len(records),'redactions':sum(r['redactions'] for r in records)}))

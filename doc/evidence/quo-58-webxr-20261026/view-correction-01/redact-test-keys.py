"""Preserve raw test logs privately; redact generated private-key byte strings."""
from pathlib import Path
import hashlib, json, re, shutil

root = Path('/home/yan/src/quod')
evidence = Path(__file__).resolve().parent
private = root / '_build/quo-58-webxr-20261026/view-correction-01/raw-test-logs'
private.mkdir(mode=0o700, exist_ok=False)
assert (evidence / 'release-gates-02/STOP.json').is_file() or (evidence / 'release-gates-02/PASSED.json').is_file()
pattern = re.compile(rb"(\{'ECPrivateKey',\s*\d+,\s*)<<[\d,\s]+>>")
records = []
for path in sorted(evidence.rglob('*.log')):
    original = path.read_bytes()
    public, count = pattern.subn(rb'\1<<REDACTED_GENERATED_TEST_PRIVATE_KEY>>', original)
    if not count:
        continue
    target = private / path.relative_to(evidence)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, target)
    target.chmod(0o600)
    path.write_bytes(public)
    records.append({'file': str(path.relative_to(evidence)), 'redactions': count,
                    'raw_sha256': hashlib.sha256(original).hexdigest(),
                    'public_sha256': hashlib.sha256(public).hexdigest()})
(evidence / 'test-log-redactions.json').write_text(json.dumps({
    'scope': 'Private key bytes emitted by supervised test-process failure reports; all test outcomes and other log content retained.',
    'private_originals': str(private), 'files': records,
}, indent=2) + '\n')
print(json.dumps({'redacted_files': len(records), 'private_key_occurrences': sum(r['redactions'] for r in records)}))

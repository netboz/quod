"""Preserve finished diagnostic logs privately before redacting test key bytes."""
from pathlib import Path
import hashlib
import json
import re
import shutil

evidence = Path(__file__).resolve().parent
private = Path('/home/yan/src/quod/_build/quo-58-webxr-20261026/view-correction-01/raw-diagnostic-logs')
private.mkdir(mode=0o700, exist_ok=False)
pattern = re.compile(rb"(\{'ECPrivateKey',\s*\d+,\s*)<<[\d,\s]+>>")
records = []
for number in range(2, 15):
    scope = evidence / f'timeout-triage-{number:02d}'
    assert list(scope.glob('*.exit.json')) or (scope / 'exit.json').exists()
    for path in sorted(scope.glob('*.log')):
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
(evidence / 'diagnostic-log-redactions.json').write_text(json.dumps({
    'scope': 'Completed diagnostic sequences 02–14; only generated test private-key bytes are redacted. All outcomes and failed runs remain.',
    'private_originals': str(private), 'files': records,
}, indent=2) + '\n')
print(json.dumps({'redacted_files': len(records),
                  'private_key_occurrences': sum(r['redactions'] for r in records)}))

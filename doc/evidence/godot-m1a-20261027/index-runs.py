#!/usr/bin/env python3
"""Index retained commands without equating exit zero with valid test evidence."""
import json
from pathlib import Path
import sys

evidence = Path(__file__).resolve().parent
campaign = sys.argv[1]
rows = []
for receipt in sorted((evidence / 'logs').glob('*.json')):
    data = json.loads(receipt.read_text())
    if 'command' not in data:
        continue
    label = receipt.stem
    validity = 'command receipt; inspect its scope and original log'
    if data.get('child_started') is False:
        validity = 'launch failure; no test ran'
    elif label == 'focused-foundations-12':
        validity = 'interrupted with Docker SIGTERM; exit zero is not a passing test'
    elif label == 'focused-foundations-14':
        validity = 'stale beam; invalid evidence for the new assertions'
    elif data.get('child_exit') != 0 or data.get('timed_out'):
        validity = 'failed or timed out; retained, not qualification'
    elif label.startswith(campaign + '-'):
        validity = 'final clean gate; combined campaign result is authoritative'
    rows.append(dict(label=label, receipt=str(receipt.relative_to(evidence)),
        log=str(receipt.with_suffix('.log').relative_to(evidence)),
        command=data['command'], child_exit=data.get('child_exit'),
        timed_out=data.get('timed_out'), child_started=data.get('child_started', True),
        start_utc=data.get('start_utc'), elapsed_seconds=data.get('elapsed_seconds'),
        validity=validity))
data = dict(commands=rows,
    no_child_preparation_failures='Development copier and focused-foundations-15 host permission failures are retained in development-notes.md and their incremental inputs; no test receipt is invented.',
    historical_failures='gates-01-result.json, gates-02-result.json and gates-03-result.json retain their failures and explicitly unrun later gates.',
    log_redaction='See the redaction manifests for restricted full raw originals and sanitized-log hashes.')
(evidence / 'run-index.json').write_text(json.dumps(data, indent=2) + '\n')
print(json.dumps(dict(command_receipts=len(rows))))

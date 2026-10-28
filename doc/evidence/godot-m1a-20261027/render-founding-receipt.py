#!/usr/bin/env python3
"""Render public identities from one actual qualified production journey."""
import hashlib
import json
from pathlib import Path
import sys

evidence = Path(__file__).resolve().parent
label = sys.argv[1]
receipt = json.loads((evidence / (label + '-founding.json')).read_text())
identity = json.loads((evidence / (label + '-public-identity.json')).read_text())
inputs = json.loads((evidence / 'inputs' / (label + '-source-manifest.json')).read_text())
assert hashlib.sha256((evidence / (label + '-founding.json')).read_bytes()).hexdigest().upper() == identity['input_sha256']
assert identity['verification_is_offline_read_only']
rows = {row['namespace']:row['anchor'] for row in receipt['catalogue']}
slots = [('R','quod:root',receipt['network'])] + [(slot,ns,rows[ns]) for slot,ns in [
    ('N','quod:node'),('AClass','quod:agent'),('G','quod:gui'),
    ('C','quod:controllers'),('S','quod:space'),('UClass','quod:user')]]
lines = ['# Actual M1a founding receipt', '',
    f'These bytes come from `{label}`’s signed production journey. They identify a disposable local network. Complete sequential qualification is recorded separately in the campaign result.', '',
    f'[Canonical receipt]({label}-founding.json), [public identity verification]({label}-public-identity.json), [HTTPS operations]({label}-founding.json.https.json), [endpoint/trust]({label}-founding.json.trust.json).', '',
    '| Slot | Exact namespace | Genesis anchor (hex) |', '| --- | --- | --- |']
lines += [f'| {slot} | {ns} | `{anchor}` |' for slot,ns,anchor in slots]
lines += ['', 'Root is not a catalogue row. Six catalogue identities plus root make seven foundations. One enrolled node history, two human histories and an unrelated agent history bring the total to eleven. Personal A and S0 are instances, not extra histories.', '',
    '## Node and account identities', '',
    f"Enrolled node public key: `{identity['executor_public_key']}`.",
    f"Node namespace: `{identity['node_identity']['namespace']}`; anchor: `{identity['node_identity']['anchor']}`; instance: `{identity['node_identity']['local_id']}`."]
for number, account in enumerate(identity['accounts'],1):
    assert account['exact_receipt_verified'] and account['altered_message_refused']
    human, agent, space, storage = [account[k] for k in ['human','agent','initial_space','selected_storage']]
    lines += ['',f'### Account {number}','',f"Namespace: `{human['namespace']}`.",
        f"History anchor: `{human['anchor']}`.",
        f"Human U: `{human['local_id']}`; personal A: `{agent['local_id']}`; S0: `{space['local_id']}`.",
        f"Explicit selected storage: `ontology_ref({storage['namespace']}, {storage['anchor']})`.",
        f"Human public key: `{account['human_public_key']}`.",
        f"Personal-agent public key: `{account['personal_agent_public_key']}`.", '',
        'The original setup operation names this exact U. Its immutable custody signature verifies against the enrolled executor for this exact A, none/0 prior assignment, destination and key. U and A keys differ. S0 is U-owned and parentless; its local space class belongs to this storage identity. The shared S anchor and pinned source hash are recorded in the canonical receipt.']
lines += ['', '## Ordered composition and source hashes', '',
    'The production recipe founds root, then node and its enrollment, then agent, GUI, controllers, space and user. These per-owner lists preserve the source composition order. Node-instance source is frozen in the node foundation’s template; private components are frozen in the user foundation.', '']
for owner in ['root','node','agent','gui','controllers','space','user','private_account']:
    lines.append('- ' + owner + ': ' + ', '.join('`' + name + '`' for name in receipt['source_order'][owner]) + '.')
lines += ['', '| Source file | SHA-256 |', '| --- | --- |']
lines += [f"| {row['file']} | `{row['sha256']}` |" for row in receipt['sources']]
lines += ['', 'Generic common/construction/material policy remains single-owned. Its source hashes are:', '']
for name in ['common_predicates.pl','construction.pl','material_policy.pl']:
    lines.append(f"- `{name}`: `{inputs['files']['priv/ontologies/'+name]}`.")
compiled = evidence / 'inputs' / (label + '-compiled-manifest.json')
compiled_reference = f'[compiled manifest](inputs/{compiled.name})' if compiled.exists() else 'compiled manifest (pending completion of all gates)'
lines += ['', '## Compiled predicate profiles', '',
    f'All eleven profiles and module hashes are in the canonical receipt. The {compiled_reference} relates them to actual test beams and separately records production release beams, runtime/common sources, locks, generated parser sources and derived Rebar metadata.', '',
    '| History | Declared compiled modules |', '| --- | --- |']
lines += [f"| {row['namespace']} | " + ', '.join(module['module'] for module in row['modules']) + ' |' for row in receipt['predicate_profiles']]
lines += ['', 'No private seed, unlock bytes or raw credential is part of this receipt. These public disposable identities are recorded for verification. M1b Godot interaction, later S0 admission/entry policy and M2/M3 delivery remain open.', '']
(evidence / 'founding-receipt.md').write_text('\n'.join(lines))
print(json.dumps(dict(label=label,foundations=len(slots),accounts=len(identity['accounts']),profiles=len(receipt['predicate_profiles']))))

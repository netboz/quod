#!/usr/bin/env python3
"""Audit new R1 public artifacts against actual owned private seed encodings."""
import base64, hashlib, json
from pathlib import Path

evidence=Path(__file__).resolve().parent
private=Path('/home/yan/.cache/quod-m4-r1-artifacts/artifacts/private')
seeds=set(); readable=[]; unreadable=[]
def observe(value):
    if isinstance(value,dict):
        jwk=value.get('private_jwk')
        if isinstance(jwk,dict) and isinstance(jwk.get('d'),str):
            encoded=jwk['d']; seed=base64.urlsafe_b64decode(encoded+'='*((-len(encoded))%4))
            assert len(seed)==32; seeds.add(seed)
        for part in value.values():observe(part)
    elif isinstance(value,list):
        for part in value:observe(part)
    elif isinstance(value,str) and value.startswith('{'):
        try:observe(json.loads(value))
        except ValueError:pass
for path in sorted(private.rglob('*.json')):
    try:
        data=path.read_bytes();observe(json.loads(data));readable.append(str(path))
    except PermissionError as error:unreadable.append({'path':str(path),'errno':error.errno})
variants=set()
for seed in seeds:
    variants.update([base64.urlsafe_b64encode(seed).rstrip(b'='),base64.b64encode(seed),
                     seed.hex().encode(),seed.hex().upper().encode(),
                     json.dumps(list(seed)).encode(),json.dumps(list(seed),separators=(',',':')).encode(),
                     b'<<'+b','.join(str(n).encode() for n in seed)+b'>>'])
matches=[];files=[p for p in evidence.rglob('*') if p.is_file()]
files.append(Path('nimbalyst-local/handoffs/godot-m4-r1-result.md'))
for path in files:
    data=path.read_bytes()
    if any(value in data for value in variants):matches.append(str(path))
record={'public_files_checked':len(files),'actual_new_private_seeds_observed':len(seeds),
        'seed_encodings_checked':len(variants),'private_json_files_readable':len(readable),
        'unreadable_private_json':unreadable,'private_seed_matches':matches,
        'method':'Observed actual R1 private_jwk seeds, seven textual encodings; no seed values published.',
        'prior_public_audit':'doc/evidence/godot-m4-20261029/inputs/public-artifact-audit-final01.json',
        'prior_frozen_source_preserved':True,
        'limit':'Root-owned unreadable originals are listed; owned viewer copies cover these three actual credentials. No raw secret-bearing/private store is a snapshot input.'}
target=evidence/'inputs/public-artifact-audit.json';assert not target.exists()
target.write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(record));assert not matches

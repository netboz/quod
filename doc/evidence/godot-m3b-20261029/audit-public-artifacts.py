#!/usr/bin/env python3
"""Check public M3b evidence against disposable private JSON key material."""
import base64
import hashlib
import json
from pathlib import Path
import re

evidence=Path(__file__).resolve().parent
private=Path('/home/yan/.cache/quod-m3b-artifacts/private')
secrets=set();private_files=0;unreadable=[]
def inspect(value):
    if isinstance(value,dict):
        if value.get('kty')=='OKP' and value.get('crv')=='Ed25519' and isinstance(value.get('d'),str):
            encoded=value['d'];raw=base64.urlsafe_b64decode(encoded+'='*((-len(encoded))%4));assert len(raw)==32
            secrets.add((encoded.encode(),raw))
        for key,item in value.items():
            if key=='Payload' and isinstance(item,str):
                try:inspect(json.loads(item))
                except json.JSONDecodeError:pass
            else:inspect(item)
    elif isinstance(value,list):
        for item in value:inspect(item)
for path in private.rglob('*.json'):
    if path.is_symlink():continue
    try:inspect(json.loads(path.read_text()));private_files+=1
    except (json.JSONDecodeError,UnicodeDecodeError):pass
    except PermissionError as error:unreadable.append(dict(path=str(path),errno=error.errno,error=str(error)))
assert secrets,'Audit must observe actual disposable private keys'
patterns=[(encoded,raw,re.compile(rb'<<\s*'+rb'\s*,\s*'.join(str(n).encode() for n in raw)+rb'\s*>>')) for encoded,raw in secrets]
files=0;matches=[];manifest={}
for path in sorted(evidence.rglob('*')):
    if not path.is_file() or path.is_symlink():continue
    if path.name=='public-artifact-audit.json':continue
    data=path.read_bytes();files+=1
    for encoded,raw,decimal in patterns:
        if encoded in data or raw in data or decimal.search(data):matches.append(str(path.relative_to(evidence)));break
    manifest[str(path.relative_to(evidence))]=hashlib.sha256(data).hexdigest()
receipt=dict(public_files_checked=files,private_json_files_observed=private_files,
    actual_private_seed_variants=len(secrets),private_seed_matches=sorted(set(matches)),
    unreadable_private_json=unreadable,private_material_not_published=True,public_file_hashes=manifest,
    scope='Readable disposable JSON Ed25519 keys, including owned viewer copies: base64url, raw bytes and numeric Erlang binary forms. Root-owned unreadable originals are recorded, not bypassed. All private stores and log_private are excluded from snapshot inputs.')
(evidence/'inputs/public-artifact-audit.json').write_text(json.dumps(receipt,indent=2)+'\n')
assert not matches,'Private seed found; paths recorded without printing any secret'
print(json.dumps({k:v for k,v in receipt.items() if k!='public_file_hashes'}))

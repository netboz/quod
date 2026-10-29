#!/usr/bin/env python3
"""Verify unchanged client/package inputs and actual unpacked native sources."""
import hashlib
import json
from pathlib import Path
import sys

evidence=Path(__file__).resolve().parent
root=evidence.parents[2]
label=sys.argv[1]
inputs=json.loads((evidence/'inputs'/(label+'-source-manifest.json')).read_text())
work=Path(inputs['stage'])/'source'
prior=Path('/home/yan/.cache/quod-m2-artifacts/quod-godot-m2-handoff-8db34a85-20261028-01')

def digest(path):
    with path.open('rb') as stream: return hashlib.file_digest(stream,'sha256').hexdigest()

client=json.loads((prior/'client-qualification.json').read_text())
for name,expected in client['authored_inputs'].items(): assert digest(root/name)==expected,name
cargo=json.loads((prior/'cargo-inputs.json').read_text())
for name,row in cargo['packages'].items(): assert digest(work/name)==row['sha256'],name
expected_sources=cargo['unpacked_authored_sources']
for name,row in expected_sources.items(): assert digest(work/name)==row['sha256'],name
registry=work/'.cache/cargo/registry/src'
actual={str(p.relative_to(work)) for p in registry.rglob('*') if p.is_file() and
        p.name not in ['.cargo-ok','.cargo-checksum.json']}
assert actual==set(expected_sources),'Native package source path set differs'
generated={str(p.relative_to(work)):dict(bytes=p.stat().st_size,sha256=digest(p))
    for p in registry.rglob('*') if p.is_file() and p.name in ['.cargo-ok','.cargo-checksum.json']}
snapshot=json.loads((prior/'snapshot.json').read_text())
artifacts={}
for name in ['cargo-package-inputs.tar.gz','cargo-index-metadata.tar.gz','dependency-inputs.tar.gz',
    'client-package-inputs.tar.gz','godot-toolchain-inputs.tar','dotnet-toolchain.tar.gz',
    'native-desktop-host-inputs.tar.gz','client-export.tar.gz']:
    artifacts[name]=digest(prior/name)
    assert artifacts[name]==snapshot['artifacts'][name],name
result=dict(client_authored_inputs_verified=len(client['authored_inputs']),
    cargo_archives_verified=len(cargo['packages']),unpacked_native_authored_sources_verified=len(actual),
    exact_native_package_source_path_set=True,generated_extraction_metadata=generated,
    unchanged_archive_hashes=artifacts,
    claim='Unchanged inputs/accepted client evidence only; no M3b product or installed-client acceptance')
output=evidence/'inputs'/(label+'-reused-inputs.json')
assert not output.exists()
output.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:v for k,v in result.items() if k!='generated_extraction_metadata'}))

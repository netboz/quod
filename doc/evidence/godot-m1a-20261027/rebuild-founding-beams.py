#!/usr/bin/env python3
"""Reconstruct EUnit-provider objects after CT replaced them; never gate inputs."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

evidence = Path(__file__).resolve().parent
root = evidence.parents[2]
campaign, label = sys.argv[1:]
inputs = json.loads((evidence / 'inputs' / (campaign + '-source-manifest.json')).read_text())
assert json.loads((evidence / (campaign + '-result.json')).read_text())['all_true_exits_zero']
frozen = Path(inputs['stage']) / 'source'
stage = Path('/tmp') / ('quod-m1a-' + label)
stage.mkdir(mode=0o700, exist_ok=False)
work = stage / 'source'
work.mkdir()
for name, digest in inputs['files'].items():
    src, dst = frozen / name, work / name
    assert hashlib.sha256(src.read_bytes()).hexdigest() == digest, name
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
for name, expected in inputs['dependency_sources'].items():
    src, dst = Path('/tmp/quod-m1a-dev-01') / name, work / name
    dst.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(expected, dict):
        assert src.is_symlink() and str(src.readlink()) == expected['symlink'], name
        dst.symlink_to(src.readlink())
        assert dst.resolve().is_relative_to(work), name
    else:
        assert hashlib.sha256(src.read_bytes()).hexdigest() == expected, name
        shutil.copy2(src, dst)
record = dict(campaign=campaign, stage=str(stage), source_manifest=str(evidence / 'inputs' / (campaign + '-source-manifest.json')),
              compiled_inputs_copied=False, purpose='EUnit-provider artifact reconstruction, not replacement qualification')
(evidence / 'inputs' / (label + '-inputs.json')).write_text(json.dumps(record, indent=2) + '\n')
docker = ['docker','run','--rm','--init','-v',str(work)+':/work','-w','/work',
          '-e','ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2',
          '-e','REBAR_CACHE_DIR=/work/.cache/rebar3','-e','CARGO_HOME=/work/.cache/cargo',
          '--entrypoint','/usr/bin/env',inputs['image'],
          'rebar3','as','test','eunit','--test=quod_identity_tests:generate_shape_test']
done = subprocess.run(['python3',str(evidence/'run.py'),'--timeout','900',label,'--']+docker,cwd=root)
if done.returncode:
    raise SystemExit(done.returncode)
receipt = json.loads((evidence / (campaign + '-founding.json')).read_text())
expected = {m['module']:m['sha256'] for p in receipt['predicate_profiles'] for m in p['modules']}
artifacts = evidence / 'artifacts' / 'founding-eunit'
artifacts.mkdir(parents=True, exist_ok=False)
objects = {}
for name, digest in expected.items():
    src = work / '_build/test/lib/quod/ebin' / (name+'.beam')
    assert hashlib.sha256(src.read_bytes()).hexdigest().upper() == digest, name
    dst = artifacts / src.name
    shutil.copy2(src,dst)
    objects[name] = dict(path=str(dst.relative_to(root)),sha256=digest,reconstructed=True)
record.update(objects=objects, all_recorded_founding_digests_match=True,
              no_object_copied_into_clean_gate_stage=True)
(evidence / 'inputs' / (label + '-result.json')).write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(dict(label=label, matched_founding_objects=len(objects))))

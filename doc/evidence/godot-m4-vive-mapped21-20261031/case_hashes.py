"""Accepted current payload digest custody; no output/history recount."""
import importlib.util,json
from pathlib import Path
p=Path('/home/yan/src/quod_worktrees/pearl-stone/doc/evidence/godot-m4-vive-workspace-cue-20261031/cue_hashes.py')
spec=importlib.util.spec_from_file_location('runtime17_digest_owner',p);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
Digests,TASK,key,raw,SOURCES=m.Digests,m.TASK,m.key,m.raw,m.SOURCES
manifest=p.parent/'inputs/client-workspace-cue01-manifest.json'
assert raw(manifest)=='4e6bcf7daf995305e004eb8a9164cb862f7aa84dd257404f37c089aa672ff884'
cache=json.loads(manifest.read_text())['digest_cache'];SOURCES.append((Path(cache['path']),cache['sha256']))

"""Accepted current payload digest custody; no output/history recount."""
import importlib.util,json
from pathlib import Path
p=Path('/home/yan/src/quod_worktrees/pearl-stone/doc/evidence/godot-m4-vive-runtime-cue-20261030/cue_hashes.py')
spec=importlib.util.spec_from_file_location('runtime17_digest_owner',p);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
Digests,TASK,key,raw,SOURCES=m.Digests,m.TASK,m.key,m.raw,m.SOURCES
manifest=p.parent/'inputs/client-runtime-cue01-manifest.json'
assert raw(manifest)=='9073b314599bd64531792acd63cbcd2e21ef54b73a41b25cd041260a4433fb08'
cache=json.loads(manifest.read_text())['digest_cache'];SOURCES.append((Path(cache['path']),cache['sha256']))

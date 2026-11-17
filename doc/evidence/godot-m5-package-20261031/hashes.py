"""Reuse qualified payload/source custody only at exact current stat identities."""
import importlib.util,json
from pathlib import Path
p=Path(__file__).resolve().parent.parent/'godot-space-stage2-20261031/hashes.py'
s=importlib.util.spec_from_file_location('stage2_hash_owner',p);prior=importlib.util.module_from_spec(s);s.loader.exec_module(prior)
TASK,key,raw=prior.TASK,prior.key,prior.raw
class Digests(prior.Digests):
    def __init__(self):
        super().__init__()
        for name,digest in [('stage2-selected-hashes-166.json','4b036bccad015319ed3b2d0b8290dd4b7996536b6e66860ed6aeadb64a664fbf'),('stage2-seal-hashes-167.json','61aca65b5cb5b4f31a93286e9310eb1adab5124b4012f8b18d1eceb8dac6467f'),('m5-package-hashes-171.json','30307fb60feec9283b5b2d4a20f4f8d275377c687915bd16b46be9af9475112f')]:
            p=Path.cwd()/'_build/godot-m4-r2-coordinator-20261029'/name;assert raw(p)==digest
            rows=json.loads(p.read_text())['records']
            for r in rows.values() if isinstance(rows,dict) else rows:
                k=tuple(r['stat_key']);assert k not in self.values or self.values[k]==r['sha256'];self.values[k]=r['sha256']

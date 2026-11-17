"""Existing digest owner plus authenticated current morning/case23 custody."""
import importlib.util,json
from pathlib import Path
p=Path(__file__).resolve().parent.parent/'godot-m4-morning-journey-20261031/cue_hashes.py'
spec=importlib.util.spec_from_file_location('menu_digest_owner',p);prior=importlib.util.module_from_spec(spec);spec.loader.exec_module(prior)
TASK,key,raw=prior.TASK,prior.key,prior.raw
coordinator=Path.cwd()/'_build/godot-m4-r2-coordinator-20261029'
CURRENT=[
    (coordinator/'morning-final-hashes-143.json','bc6ae4bf713101104c93fe88a73cafe1eb93db4702bb12db298d42037d9abbf8'),
    (coordinator/'morning-seal-hashes-144-corrected.json','41a1830a49eaf1ffc3e05ab03ac770872966e8dc79b68127fa5d6e2a8ec09f08'),
]
class Digests(prior.Digests):
    def __init__(self):
        super().__init__()
        for path,digest in CURRENT:
            assert raw(path)==digest,('trusted cache identity',str(path))
            rows=json.loads(path.read_text())['records']
            for row in rows.values() if isinstance(rows,dict) else rows:
                k=tuple(row['stat_key']);v=row['sha256']
                assert k not in self.values or self.values[k]==v
                self.values[k]=v

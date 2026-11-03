"""Accepted preparation280 exact-stat custody; preserve all pathless rows."""
import importlib.util
from pathlib import Path
p=Path(__file__).resolve().parent.parent/"godot-m4-presentation-20261030/digests.py"
s=importlib.util.spec_from_file_location("occurrence_package_digest_owner",p);prior=importlib.util.module_from_spec(s);s.loader.exec_module(prior)
prior.SOURCES=[(Path('/data/quod-m4-vr-ca84d4f8-20261029/cache/attention-vr-preparation280-hashes.json'),'c2e6004b9ee79b103c359be8e06be19be1ce351b60bcc4b15160a9e6f51fb151')]
TASK,key,raw,Digests=prior.TASK,prior.key,prior.raw,prior.Digests

# Preserve every authenticated stat row, including rows without a display path.
import json
class Digests(prior.Digests):
    def write(self,p):
        Path(p).write_text(json.dumps({"records":[{"stat_key":k,"sha256":v} for k,v in self.values.items()]})+"\n")

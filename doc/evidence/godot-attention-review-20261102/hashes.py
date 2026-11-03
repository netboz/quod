"""Accepted attention277 boundary exact-stat custody; preserve all pathless rows."""
import importlib.util
from pathlib import Path
p=Path(__file__).resolve().parent.parent/"godot-m4-presentation-20261030/digests.py"
s=importlib.util.spec_from_file_location("occurrence_package_digest_owner",p);prior=importlib.util.module_from_spec(s);s.loader.exec_module(prior)
prior.SOURCES=[(Path('/data/quod-m4-vr-ca84d4f8-20261029/cache/attention-qualified02-hashes.json'),'51273af56331b609943e814aa1109659f53d6b923b046cc4b7c6e9c95de28c03')]
TASK,key,raw,Digests=prior.TASK,prior.key,prior.raw,prior.Digests

# Preserve every authenticated stat row, including rows without a display path.
import json
class Digests(prior.Digests):
    def write(self,p):
        Path(p).write_text(json.dumps({"records":[{"stat_key":k,"sha256":v} for k,v in self.values.items()]})+"\n")

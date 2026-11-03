"""Accepted attention279 boundary exact-stat custody; preserve all pathless rows."""
import importlib.util
from pathlib import Path
p=Path(__file__).resolve().parent.parent/"godot-m4-presentation-20261030/digests.py"
s=importlib.util.spec_from_file_location("occurrence_package_digest_owner",p);prior=importlib.util.module_from_spec(s);s.loader.exec_module(prior)
prior.SOURCES=[(Path('/data/quod-m4-vr-ca84d4f8-20261029/artifacts/quod-attention-client-package-handoff-ca84d4f8-20261102-01/used-stat-digests.json'),'af5b8498e5294514333cf2d6746a01ea77c2f64cd6d43a6c39ae35e0af3aa1ab')]
TASK,key,raw,Digests=prior.TASK,prior.key,prior.raw,prior.Digests

# Preserve every authenticated stat row, including rows without a display path.
import json
class Digests(prior.Digests):
    def write(self,p):
        Path(p).write_text(json.dumps({"records":[{"stat_key":k,"sha256":v} for k,v in self.values.items()]})+"\n")

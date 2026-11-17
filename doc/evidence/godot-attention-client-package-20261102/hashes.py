"""Accepted attention278 boundary exact-stat custody; preserve all pathless rows."""
import importlib.util
from pathlib import Path
p=Path(__file__).resolve().parent.parent/"godot-m4-presentation-20261030/digests.py"
s=importlib.util.spec_from_file_location("occurrence_package_digest_owner",p);prior=importlib.util.module_from_spec(s);s.loader.exec_module(prior)
prior.SOURCES=[(Path('/data/quod-m4-vr-ca84d4f8-20261029/artifacts/quod-attention-review-handoff-ca84d4f8-20261102-01/used-stat-digests.json'),'9b4892efd0cef901c35ec6740b2b9468cfcf01c570b9add2a762cb22625d231a')]
TASK,key,raw,Digests=prior.TASK,prior.key,prior.raw,prior.Digests

# Preserve every authenticated stat row, including rows without a display path.
import json
class Digests(prior.Digests):
    def write(self,p):
        Path(p).write_text(json.dumps({"records":[{"stat_key":k,"sha256":v} for k,v in self.values.items()]})+"\n")

"""Authenticated exact-stat custody from the prepared281 observer; no old payload audit."""
import importlib.util
import json
from pathlib import Path

p=Path(__file__).resolve().parent.parent/'godot-m4-presentation-20261030/digests.py'
s=importlib.util.spec_from_file_location('visual_preparation_digest_owner',p)
prior=importlib.util.module_from_spec(s);s.loader.exec_module(prior)
prior.SOURCES=[(Path('/data/quod-m4-vr-ca84d4f8-20261029/cache/visual-readiness-preparation02-hashes.json'),
                'c80950896ea69e57cd2cf70824a9c6d72fc870f70d25fd9a1a18ff2b9f0457ff')]
TASK,key,raw=prior.TASK,prior.key,prior.raw

class Digests(prior.Digests):
    def write(self,path):
        Path(path).write_text(json.dumps({'records':[{'stat_key':k,'sha256':v}
            for k,v in self.values.items()]})+'\n')

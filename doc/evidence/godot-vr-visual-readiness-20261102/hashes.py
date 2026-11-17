"""Authenticated exact-stat custody from the prepared281 observer; no old payload audit."""
import importlib.util
import json
from pathlib import Path

p=Path(__file__).resolve().parent.parent/'godot-m4-presentation-20261030/digests.py'
s=importlib.util.spec_from_file_location('visual_preparation_digest_owner',p)
prior=importlib.util.module_from_spec(s);s.loader.exec_module(prior)
prior.SOURCES=[(Path('/data/quod-m4-vr-ca84d4f8-20261029/cache/frame-observation-preparation01-hashes.json'),
                '62688a685dd4644ead0e227440dc44c596dc9da017ca2cca6773f941dd912adc')]
TASK,key,raw=prior.TASK,prior.key,prior.raw

class Digests(prior.Digests):
    def write(self,path):
        Path(path).write_text(json.dumps({'records':[{'stat_key':k,'sha256':v}
            for k,v in self.values.items()]})+'\n')

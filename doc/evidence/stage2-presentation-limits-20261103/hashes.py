"""Authenticated260/253 exact-stat custody, including every pathless row."""
import importlib.util
from pathlib import Path
p=Path(__file__).resolve().parent.parent/'godot-m4-presentation-20261030/digests.py'
s=importlib.util.spec_from_file_location('retirement_digest_owner',p);prior=importlib.util.module_from_spec(s);s.loader.exec_module(prior)
prior.SOURCES=[(Path('/data/quod-m4-vr-ca84d4f8-20261029/cache/coordinator-space-current-native-260-hashes.json'),'4b16fb24c5a4ae1e4767d7f53876988195a860b598d26658da1e7aa2929f5ac5')]
TASK,key,raw,Digests=prior.TASK,prior.key,prior.raw,prior.Digests

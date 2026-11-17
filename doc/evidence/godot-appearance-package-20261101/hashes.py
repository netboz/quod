"""Accepted245 exact-stat custody, reused without touching inherited inodes."""
import importlib.util
from pathlib import Path
p=Path(__file__).resolve().parent.parent/'godot-m4-presentation-20261030/digests.py'
s=importlib.util.spec_from_file_location('appearance_package_digest_owner',p);prior=importlib.util.module_from_spec(s);s.loader.exec_module(prior)
prior.SOURCES=[(Path('/data/quod-m4-vr-ca84d4f8-20261029/cache/coordinator-appearance-boundary-245-corrected03-hashes.json'),'329010e710681c492d426626783a380b0e21a479157e7f5cb84a229ff0e5d771')]
TASK,key,raw,Digests=prior.TASK,prior.key,prior.raw,prior.Digests

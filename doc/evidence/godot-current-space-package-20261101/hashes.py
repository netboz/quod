"""Accepted261 exact-stat custody, reused without touching inherited inodes."""
import importlib.util
from pathlib import Path
p=Path(__file__).resolve().parent.parent/'godot-m4-presentation-20261030/digests.py'
s=importlib.util.spec_from_file_location('appearance_package_digest_owner',p);prior=importlib.util.module_from_spec(s);s.loader.exec_module(prior)
prior.SOURCES=[(Path('/data/quod-m4-vr-ca84d4f8-20261029/cache/coordinator-space-boundary-261-hashes.json'),'521362799df476d93b9c0ecdd626a5d2864a384d162163dec7711f249a7a2394')]
TASK,key,raw,Digests=prior.TASK,prior.key,prior.raw,prior.Digests

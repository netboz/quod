"""Accepted262 exact-stat custody, reused without touching inherited inodes."""
import importlib.util
from pathlib import Path
p=Path(__file__).resolve().parent.parent/'godot-m4-presentation-20261030/digests.py'
s=importlib.util.spec_from_file_location('appearance_package_digest_owner',p);prior=importlib.util.module_from_spec(s);s.loader.exec_module(prior)
prior.SOURCES=[(Path('/data/quod-m4-vr-ca84d4f8-20261029/cache/coordinator-current-space-package-boundary-262-hashes.json'),'08c9c8cbcbafc6b655b4ad51cbc1cf4078f9fd3630c552d922c7777741543d1d')]
TASK,key,raw,Digests=prior.TASK,prior.key,prior.raw,prior.Digests

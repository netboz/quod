"""Accepted226 exact-stat custody, reused without touching inherited inodes."""
import importlib.util
from pathlib import Path
p=Path(__file__).resolve().parent.parent/'godot-m4-presentation-20261030/digests.py'
s=importlib.util.spec_from_file_location('morning_digest_owner',p);prior=importlib.util.module_from_spec(s);s.loader.exec_module(prior)
prior.SOURCES=[(Path('/data/quod-m4-vr-ca84d4f8-20261029/cache/coordinator-workbench-boundary-226-corrected02-hashes.json'),'10f4ffe2d936f63f1923cc0606af57ebda7df0eaa41d329e6c3f71ce8fc7588f')]
TASK,key,raw,Digests=prior.TASK,prior.key,prior.raw,prior.Digests

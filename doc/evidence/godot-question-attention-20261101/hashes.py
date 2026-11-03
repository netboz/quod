"""Accepted occurrence boundary exact-stat custody; preserve all pathless rows."""
import importlib.util
from pathlib import Path
p=Path(__file__).resolve().parent.parent/"godot-m4-presentation-20261030/digests.py"
s=importlib.util.spec_from_file_location("occurrence_package_digest_owner",p);prior=importlib.util.module_from_spec(s);s.loader.exec_module(prior)
prior.SOURCES=[(Path('/data/quod-m4-vr-ca84d4f8-20261029/cache/occurrence-package-qualified01-hashes.json'),'6f5722471423196c4ef840be1d596168f28fdb14a01732e5443bfc31d22c7e1c')]
TASK,key,raw,Digests=prior.TASK,prior.key,prior.raw,prior.Digests

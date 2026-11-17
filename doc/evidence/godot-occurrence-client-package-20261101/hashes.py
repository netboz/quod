"""Accepted occurrence boundary exact-stat custody; preserve all pathless rows."""
import importlib.util
from pathlib import Path
p=Path(__file__).resolve().parent.parent/"godot-m4-presentation-20261030/digests.py"
s=importlib.util.spec_from_file_location("occurrence_package_digest_owner",p);prior=importlib.util.module_from_spec(s);s.loader.exec_module(prior)
prior.SOURCES=[(Path('/data/quod-m4-vr-ca84d4f8-20261029/artifacts/quod-occurrence-form-handoff-ca84d4f8-20261101-01/used-stat-digests.json'),'53123ff7592cd641cb51f404b9c3122e4135fefd79bf2bbb812583647d00a38a')]
TASK,key,raw,Digests=prior.TASK,prior.key,prior.raw,prior.Digests

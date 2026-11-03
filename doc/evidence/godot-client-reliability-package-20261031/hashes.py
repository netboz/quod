"""Reuse accepted workbench custody with the existing exact-stat digest owner."""
import importlib.util,json
from pathlib import Path
p=Path(__file__).resolve().parent.parent/'godot-ontology-workbench-20261031/hashes.py'
s=importlib.util.spec_from_file_location('workbench_digest_owner',p)
prior=importlib.util.module_from_spec(s);s.loader.exec_module(prior)
TASK,key,raw=prior.TASK,prior.key,prior.raw
class Digests(prior.Digests):
    def __init__(self):
        super().__init__()
        for name,digest in [('workbench-selected-hashes-194.json','cc5f73adb7a7202b50cd3d15df232db87290c8c10c04579159dba759b3ea8d15'),('workbench-seal-hashes-195.json','806a8f7fe24ea47fa98eaf0e1613a85c542af642c8919696da8aeab80514d2d7'),('client-package-hashes-197.json','fa4cc53a11c62a78cf0082cca54149222fffe95858dab75bd8f2b02ae59d2a72')]:
            p=Path.cwd()/'_build/godot-m4-r2-coordinator-20261029'/name
            assert raw(p)==digest
            rows=json.loads(p.read_text())['records']
            for r in rows.values() if isinstance(rows,dict) else rows:
                k=tuple(r['stat_key']);assert k not in self.values or self.values[k]==r['sha256']
                self.values[k]=r['sha256']

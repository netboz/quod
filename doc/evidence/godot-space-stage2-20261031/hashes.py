"""Existing digest owner plus authenticated current morning/case23 custody."""
import importlib.util,json
from pathlib import Path
p=Path(__file__).resolve().parent.parent/'godot-m4-menu-20261031/hashes.py'
spec=importlib.util.spec_from_file_location('menu_digest_owner',p);prior=importlib.util.module_from_spec(spec);spec.loader.exec_module(prior)
TASK,key,raw=prior.TASK,prior.key,prior.raw
coordinator=Path.cwd()/'_build/godot-m4-r2-coordinator-20261029'
CURRENT=[
 (TASK/'cache/coordinator-stage2-custody-165.json','d76a53790e39648e5d399736f819fb0b7c20d0a00a22ffa9111d9a5cd835e046'),
 (coordinator/'stage2-reconnect-hashes-162.json','12b547c7a8bad8848de786726b9e13253c838752740c71e53835d26417b8d057'),
 (coordinator/'stage2-owner-hashes-158.json','8bf6917b694c11f6a5ac6abd456e83f17107594fa745a202c51939d0077cbe6b'),
 (TASK/'cache/coordinator-retest85-hashes.json','3e8d661ce99c7af6a311bddb38ba3ea092b95586409a37b9b2db7486e1e04354'),
 (coordinator/'menu-final-hashes-150.json','ba544be23574509ac5a0f5b2ca49ed399d825ad8c329b8c2beef93f0f8576ed2'),
 (coordinator/'menu-seal-hashes-151.json','faf790b00dae6dd637c080b4971e64660bfc8f859b8a72c442cf21cb636e9bd7'),
]
class Digests(prior.Digests):
    def __init__(self):
        super().__init__()
        for path,digest in CURRENT:
            assert raw(path)==digest,('trusted cache identity',str(path))
            rows=json.loads(path.read_text())['records']
            for row in rows.values() if isinstance(rows,dict) else rows:
                k=tuple(row['stat_key']);v=row['sha256']
                assert k not in self.values or self.values[k]==v
                self.values[k]=v

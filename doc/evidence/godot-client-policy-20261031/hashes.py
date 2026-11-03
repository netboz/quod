"""Reuse accepted workbench custody with the existing exact-stat digest owner."""
import importlib.util,json
from pathlib import Path
p=Path(__file__).resolve().parent.parent/'godot-client-reliability-package-20261031/hashes.py'
s=importlib.util.spec_from_file_location('workbench_digest_owner',p)
prior=importlib.util.module_from_spec(s);s.loader.exec_module(prior)
TASK,key,raw=prior.TASK,prior.key,prior.raw
class Digests(prior.Digests):
    def __init__(self):
        super().__init__()
        for name,digest in [('client-current-selected-hashes-198.json','bac78a579c9f1f325eb6a91968c999141d5a678693998a3ce490beb0fcdcb628'),('client-current-seal-hashes-199.json','4ec0e1cef38565b57cc3ae5ede20b3d6c696b91a1038819b94e7b2b4fb61ea1c'),('answer-policy-baseline-hashes-203.json','ef2880cc050183241d84cefe0bd471266892bc31f49af3bc27abffa84e3d0420'),('answer-policy-selected-hashes-204.json','1081a6b8ac9fe4e80cb797c0643752c3ff7c892072c076d8910bba5e4b4ec1b1')]:
            p=Path.cwd()/'_build/godot-m4-r2-coordinator-20261029'/name
            assert raw(p)==digest
            rows=json.loads(p.read_text())['records']
            for r in rows.values() if isinstance(rows,dict) else rows:
                k=tuple(r['stat_key']);assert k not in self.values or self.values[k]==r['sha256']
                self.values[k]=r['sha256']
        for name,digest in [
            ('policy-remote-shutdown-hashes-205-corrected.json','c331a83481e7375c5728614575e81a8486cc8004de5050ff09e83f225f4a5710'),
            ('client-resource-package-hashes-206.json','8b5e64202c7b7f10a0e48967285a7120b089681d78947007986284ebe076f5c0'),
            ('current-journey-launch-hashes-207.json','b6c068d612051d2074f56c6804eec16b94f4ede47d2860442d50fde1ffa69a40'),
            ('release-input-native-hashes-208.json','40003807ea356264f1813d38834f3b5fd53120118c58b252cc0e632ca253554f'),
            ('archive-custody-hashes-209.json','f6e94a1c123f46d7f57911708793835db9383bca5b93925e9eb8f195477a35e3'),
            ('targeted-ct-hashes-210.json','7a2324349b0375e8a12858d572e8160927da2acad79041a73c60cfce6bed8754')]:
            p=Path.cwd()/'_build/godot-m4-r2-coordinator-20261029'/name
            assert raw(p)==digest
            rows=json.loads(p.read_text())['records']
            for r in rows.values() if isinstance(rows,dict) else rows:
                k=tuple(r['stat_key']);assert k not in self.values or self.values[k]==r['sha256']
                self.values[k]=r['sha256']
        # The clean source builder measured these archived inputs, but its
        # per-campaign cache was not previously inherited by subsequent labels.
        # Retain that cost honestly and reuse the actual bound records now.
        p=TASK/'builds/answer-policy-clean-focused06/computed-hashes.json'
        assert raw(p)=='914306ff49da8c1d7d2f0893614922a84bf25fa4de6d86fef6a3681fa6aa9e3f'
        for r in json.loads(p.read_text())['records']:
            k=tuple(r['stat_key']);assert k not in self.values or self.values[k]==r['sha256']
            self.values[k]=r['sha256']

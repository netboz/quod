"""Reuse the authenticated Stage2/package lineage at exact stat identities."""
import importlib.util,json
from pathlib import Path
p=Path(__file__).resolve().parent.parent/'godot-m5-package-20261031/hashes.py'
s=importlib.util.spec_from_file_location('package_digest_owner',p);prior=importlib.util.module_from_spec(s);s.loader.exec_module(prior)
TASK,key,raw=prior.TASK,prior.key,prior.raw
class Digests(prior.Digests):
    def __init__(self):
        super().__init__()
        for name,digest in [('m5-seal-hashes-174.json','0960a8594eb5ffe48bbde504408a05fa982c8e1be09ca05e2fd6b5cb2b747b84'),('m5-final-hashes-173-corrected02.json','90d8c9d1415b8f9f833bc1be231ce8bc0206dbcc24945d18fa4de0fdaaa6294e'),
            ('workbench-initial-hashes-176-remaining02.json','d410db931e9be72c9c5fd3e93835b1f38289f8c5e89ffd117316f1e28ec4339a'),
            ('workbench-continuation-hashes-177.json','45ab1ac76dad764d1be1600f600b416e88bc1dbb2569e97e59dacb52e9a4f2ca'),
            ('workbench-chunks-hashes-178.json','f7b20dbc27328ef899ae293499f27080caa9a83ef859d7caca3646a15f7064ce'),
            ('workbench-owner-results-hashes-180-corrected02.json','b5449254a25c983fae0cb6ccfbe5f0d0bf51f587418ab660d9068fd0413ee95f'),
            ('workbench-controls-hashes-181.json','0241110cca447b1cd4f40e1ce8e33c3501f3c019b4a39a3e585fe846f9ffbda5')]:
            p=Path.cwd()/'_build/godot-m4-r2-coordinator-20261029'/name;assert raw(p)==digest
            rows=json.loads(p.read_text())['records']
            for r in rows.values() if isinstance(rows,dict) else rows:
                k=tuple(r['stat_key']);assert k not in self.values or self.values[k]==r['sha256'];self.values[k]=r['sha256']
        for name,digest in [
            ('workbench-identity-check-182-corrected02.json','6e32e63ceb9e20d027223e4d8b50d89c6625e1c3d978ed8a4cf86c84f4f11a20'),
            ('workbench-saved-fact-check-183.json','c3006c2c9c15adfa3c3a0f410919a498ffc660f44c517e3a182edc85b268efc2'),
            ('workbench-signed-edit-check-184.json','05cef3e911cdf580e85881994404d99c07e178e0a5a213825a3b6bb271929fd7'),
            ('workbench-editor-choice-check-185.json','1565b637b43d11a7aacf8a9a8961edffae440b62e11f61441f59ffe9e6e88a68'),
            ('workbench-crud-prefix-check-186.json','a48a93a2e2cce4942b18444459a2dc4e04b4aa78965bb6ad3a271bfbd9dae3d3'),
            ('workbench-layout-owner-check-187.json','9d8dc6ed113e2636be34097bb2aa0934267538ad30adca3a82ac056e721568a1'),
            ('workbench-popup-cancellation-check-188.json','b4cf9d03876d84de8a48efe4cd9f00f324d86f802bfece22cd40c5f71f6b63e2'),
            ('workbench-layout-main-check-189-corrected02.json','bb2c791a9560ac28279adf45fc39aac4c50155fb7de681aafef895bfe250befd'),
            ('workbench-complete-framing-check-190.json','3d11cbcc55f9663076ac77f91fcea44de6f6630c6e3e31b6fffec52204af5f86'),
            ('workbench-framing-results-check-191-corrected02.json','44f416ab26ac980d593e93c301cd4339baeb0310a785d7af4ae44c63bd519576'),
            ('workbench-render-labels-check-192.json','3ee0d6bad0ec96923807acc9fcbdd0b992101a567c9de96441eea94f16d62cef'),
            ('workbench-frontal-spacing-check-193.json','7f74a43fd0c56db31ea0eaaf5a9688a80d10cac61f0badeb3de35bde4e9098f9')]:
            proof=Path.cwd()/'_build/godot-m4-r2-coordinator-20261029'/name;assert raw(proof)==digest
            ref=json.loads(proof.read_text())['cache'];p=Path(ref['path']);assert raw(p)==ref['sha256']
            rows=json.loads(p.read_text())['records']
            for r in rows.values() if isinstance(rows,dict) else rows:
                k=tuple(r['stat_key']);assert k not in self.values or self.values[k]==r['sha256'];self.values[k]=r['sha256']

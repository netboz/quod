"""Two independent constructions through the unchanged package owner."""
import json,subprocess
from pathlib import Path
from hashes import TASK,raw
root=Path.cwd();ev=Path(__file__).resolve().parent
p=json.loads((ev/'inputs/preparation-visibility-package-inputs01.json').read_text())
assert raw(Path(p['manifest']))==p['manifest_sha256']
assert raw(Path(p['extras_manifest']))==p['extras_manifest_sha256']
receipts=[]
for suffix in ['private01','repro02']:
    label='visibility-package-'+suffix
    archive=TASK/'artifacts'/('quod-visibility-linux-x86_64-'+suffix+'.tar.gz')
    receipt=ev/'inputs'/(label+'.json')
    command=['python3','-B',str(root/'client/godot-tools/package.py'),'--manifest',p['manifest'],'--manifest-sha256',p['manifest_sha256'],'--extras',p['extras_manifest'],'--output',str(archive),'--receipt',str(receipt)]
    r=subprocess.run(['python3','-B',str(ev/'run.py'),'--timeout','180',label,'--',*command])
    assert r.returncode==0;receipts.append(json.loads(receipt.read_text()))
assert receipts[0]['archive_sha256']==receipts[1]['archive_sha256']
assert receipts[0]['files']==receipts[1]['files']
print(json.dumps({'reproducible':True,'archive_sha256':receipts[0]['archive_sha256'],'bytes':receipts[0]['archive_bytes']}))

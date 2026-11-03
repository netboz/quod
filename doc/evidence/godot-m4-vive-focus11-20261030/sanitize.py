"""Preserve original new publication, explicitly redact LHB identifiers only."""
import hashlib,json,os,re,shutil
from pathlib import Path
os.umask(0o077);ev=Path(__file__).resolve().parent
case=ev.parent/'godot-m4-vive-retest-20261030/native-vive-product11'
private=Path('/data/quod-m4-vr-ca84d4f8-20261029/private/native-vive-product11/publication-originals')
private.mkdir(mode=0o700,exist_ok=False)
original=json.loads((case/'result.json').read_text());rows=[]
def sha(data):return hashlib.sha256(data).hexdigest()
for p in sorted(case.glob('*.log')):
    before=p.read_bytes();after,count=re.subn(rb'\bLHB-[A-Za-z0-9]+',b'<base-station-serial-redacted>',before)
    if not count:continue
    assert sha(before)==original['streams'][p.stem]['sanitized_sha256']
    saved=private/p.name;shutil.copyfile(p,saved);saved.chmod(0o600);p.write_bytes(after)
    rows.append({'published_path':str(p),'producer_published_sha256':sha(before),
        'current_published_sha256':sha(after),'replacements':count,'preserved_original':str(saved),
        'original_mode':384,'raw_source_sha256':original['streams'][p.stem]['sha256']})
receipt={'scope':'New case11 publication correction only; producer result/raw bytes and sealed history unchanged.',
    'producer_result_preserved':True,'rule':'LHB identifier -> base-station-serial-redacted','changes':rows}
(ev/'publication-redaction.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps({'passed':True,'files_redacted':len(rows),'identifier_occurrences':sum(r['replacements'] for r in rows)}))

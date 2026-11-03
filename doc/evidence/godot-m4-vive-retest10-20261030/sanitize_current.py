"""Redact missed base-station identifiers in new publication, preserving receipts."""
import hashlib,json,os,re,shutil,sys
from pathlib import Path
sys.dont_write_bytecode=True
os.umask(0o077);ev=Path(__file__).resolve().parent
case=ev.parent/'godot-m4-vive-retest-20261030/native-vive-product10'
private=Path('/data/quod-m4-vr-ca84d4f8-20261029/private/native-vive-product10/publication-originals')
private.mkdir(mode=0o700,exist_ok=False)
original=json.loads((case/'result.json').read_text());rows=[]
def sha(data):return hashlib.sha256(data).hexdigest()
for p in sorted(case.glob('*.log')):
    before=p.read_bytes();after,count=re.subn(rb'\bLHB-[A-Za-z0-9]+',b'<base-station-serial-redacted>',before)
    if not count:continue
    stream=p.stem;assert sha(before)==original['streams'][stream]['sanitized_sha256']
    saved=private/p.name;shutil.copyfile(p,saved);saved.chmod(0o600)
    p.write_bytes(after)
    rows.append({'published_path':str(p),'producer_published_sha256':sha(before),
      'current_published_sha256':sha(after),'replacements':count,'preserved_original':str(saved),
      'original_mode':384,'raw_source_sha256':original['streams'][stream]['sha256']})
assert sum(r['replacements'] for r in rows)==4
receipt={'scope':'New case10 publication correction only; prior sealed evidence and actual driver result are untouched.',
 'producer_result_preserved':True,'rule':'LHB hardware identifier -> base-station-serial-redacted',
 'changes':rows,'credentials_or_stores_copied':False}
(ev/'publication-redaction.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps({'passed':True,'files_redacted':len(rows),'identifier_occurrences':sum(r['replacements'] for r in rows),'producer_result_unchanged':True}))

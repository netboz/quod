"""Keep raw redirect queries/private serials restricted; preserve prior bytes."""
import hashlib,json,re,shutil,urllib.parse
from pathlib import Path
from environment import TASK
ev=Path(__file__).resolve().parent;private=TASK/'private/public-redaction01';private.mkdir(mode=0o700,exist_ok=False)
monitors=json.loads((TASK/'private/inventory01/1-stdout.raw').read_text())
serials=[m['serial'].encode() for m in monitors if isinstance(m.get('serial'),str) and len(m['serial'])>=7]
def redact(data):
    data=re.sub(rb'(https://release-assets\.githubusercontent\.com/[^"\s?]+)\?[^"\s]+',rb'\1?<signed-redirect-query-redacted>',data)
    for serial in serials:data=data.replace(serial,b'<monitor-serial-redacted>')
    return data
changes=[]
for path in sorted(ev.rglob('*')):
    if not path.is_file() or path.suffix not in ['.log','.json']:continue
    before=path.read_bytes();after=redact(before)
    if before!=after:
        saved=private/path.relative_to(ev);saved.parent.mkdir(mode=0o700,parents=True,exist_ok=True);shutil.copy2(path,saved);saved.chmod(0o600)
        path.write_bytes(after);changes.append({'path':str(path.relative_to(ev)),'before_sha256':hashlib.sha256(before).hexdigest(),'after_sha256':hashlib.sha256(after).hexdigest(),'prior_bytes_retained_privately':str(saved)})
for receipt in sorted((ev/'logs').glob('*.json')):
    row=json.loads(receipt.read_text())
    for stream in row.get('sanitized_streams',{}).values():
        path=Path(stream['path']);data=path.read_bytes();stream['sha256']=hashlib.sha256(data).hexdigest();stream['bytes']=len(data)
    receipt.write_text(json.dumps(row,indent=2)+'\n')
out=TASK/'artifacts/download-provenance';out.mkdir(mode=0o700,exist_ok=False)
for path in (TASK/'downloads').glob('*.receipt.json'):
    row=json.loads(redact(path.read_bytes()));row['raw_receipt_sha256']=hashlib.sha256(path.read_bytes()).hexdigest()
    (out/path.name).write_text(json.dumps(row,indent=2)+'\n')
result={'changes':changes,'scope':'Only current unfrozen sanitized logs/provenance; all raw streams, original receipts and previous public bytes preserved privately. No prior immutable evidence changed.'}
(ev/'inputs/public-redaction01.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({'redacted_files':len(changes),'preserved_private_root':str(private)}))

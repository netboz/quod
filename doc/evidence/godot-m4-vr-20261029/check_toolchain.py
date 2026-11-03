"""Compare current compiler/provider bytes with the retained exact capture."""
import hashlib,json,os
from pathlib import Path
from environment import TASK
provider=TASK/'artifacts/toolchain-inputs01';rows=json.loads((provider/'files.json').read_text())
changes=[];counts={}
for name,row in rows.items():
    path=Path(name);kind=row['kind'];counts[kind]=counts.get(kind,0)+1
    if not path.exists() and not path.is_symlink():changes.append({'path':name,'difference':'missing'});continue
    if path.lstat().st_mode&0o7777!=row['mode']:changes.append({'path':name,'difference':'mode'})
    if kind=='symlink':
        if not path.is_symlink() or os.readlink(path)!=row['target']:changes.append({'path':name,'difference':'symlink'})
    elif kind=='file':
        with path.open('rb') as stream:digest=hashlib.file_digest(stream,'sha256').hexdigest()
        if digest!=row['sha256']:changes.append({'path':name,'difference':'content','actual_sha256':digest,'captured_sha256':row['sha256']})
    elif not path.is_dir():changes.append({'path':name,'difference':'directory'})
result={'passed':not changes,'provider':str(provider),'captured_paths':len(rows),'path_kinds':counts,'differences':changes,
    'scope':'Actual live compiler/tools/dependency/include bytes and recorded modes match the captured provider during the clean build. Conservative include collection, not a claim every captured header is compiled; no OS image or software test rerun.'}
out=TASK/'artifacts/toolchain-live-check02.json';assert not out.exists();out.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result));raise SystemExit(0 if result['passed'] else 1)

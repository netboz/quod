#!/usr/bin/env python3
"""Source-only M2 server stage, preserving every prior campaign."""
import hashlib,json,shutil,subprocess,sys,tarfile
from pathlib import Path
root=Path(__file__).resolve().parents[3]
stage=Path(sys.argv[1]); evidence=Path(__file__).resolve().parent
work=stage/'source'; work.mkdir(parents=True,exist_ok=True)
names=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','-z'],cwd=root).decode().split('\0')
files={}
for name in sorted(set(names)):
 if name.startswith(('client/godot/','client/godot-tests/','client/godot-tools/')): continue
 if not (name.startswith(('src/','include/','priv/','test/','config/','scripts/','client/','ui/','assets/','native/')) or name in ['rebar.config','rebar.lock','README.md','Dockerfile','.forgejo/workflows/gates.yml','deploy/ci/Dockerfile']): continue
 src=root/name
 if not src.is_file(): continue
 dst=work/name; dst.parent.mkdir(parents=True,exist_ok=True)
 digest=hashlib.sha256(src.read_bytes()).hexdigest()
 if not dst.exists() or hashlib.sha256(dst.read_bytes()).hexdigest()!=digest: shutil.copy2(src,dst)
 files[name]=digest
snapshot=Path('/home/yan/.cache/quod-m1b-artifacts/quod-godot-m1b-handoff-1e4ef676-20261028-02')
deps=json.loads((snapshot/'dependency-inputs.json').read_text())
if not (stage/'dependencies-installed.json').exists():
 with tarfile.open(snapshot/'dependency-inputs.tar.gz') as archive: archive.extractall(work,filter='data')
 (stage/'dependencies-installed.json').write_text(json.dumps(deps,indent=2)+'\n')
record={'worker_session':'8db34a85-ead5-4f20-b761-28a4a96a20c6','stage':str(stage),'source_inputs':files,'dependency_manifest_sha256':hashlib.sha256((snapshot/'dependency-inputs.json').read_bytes()).hexdigest(),'compiled_inputs_copied':False}
label=sys.argv[2]; target=evidence/'inputs'/(label+'-source-manifest.json')
with target.open('x') as f: json.dump(record,f,indent=2); f.write('\n')
archive=stage/(label+'-authored-inputs.tar.gz')
with tarfile.open(archive,'x:gz') as output:
 for name in files: output.add(work/name,arcname=name,recursive=False)
archive.chmod(0o444)
print(json.dumps({'archive':str(archive),'archive_sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'stage':str(stage),'inputs':len(files),'manifest':str(target)}))

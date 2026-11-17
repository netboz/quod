"""One current-manifest contract check; no app or unchanged payload read."""
import importlib.util,json,os,sys
from pathlib import Path
from hashes import TASK,raw
os.umask(0o077);ev=Path(__file__).resolve().parent;label=sys.argv[1]
work=TASK/'private'/label;work.mkdir(mode=0o700,exist_ok=False)
dist=work/'dist';dist.mkdir();f=dist/'quod.x86_64';f.write_bytes(b'finite fixture');f.chmod(0o755)
m=work/'manifest.json';m.write_text(json.dumps({'passed':True,'trace_free':True,'diagnostic_overrides':{},'export_executable':str(f),'export_outputs':{f.name:{'bytes':f.stat().st_size,'sha256':raw(f)}}}))
e=work/'extras.json';e.write_text('{}')
p=Path.cwd()/'client/godot-tools/package.py';s=importlib.util.spec_from_file_location('packaging_owner',p);owner=importlib.util.module_from_spec(s);s.loader.exec_module(owner)
r=owner.package(m,raw(m),e,work/'current.tar.gz')
assert r['export_files']==1 and r['package_files']==2
print('PASS current accepted trace_free manifest is usable without rewriting its identity')

"""Finite package tampering/path/mode/argument fixtures, with no real application."""
import hashlib,importlib.util,json,os,shutil,subprocess,sys
from pathlib import Path
from hashes import TASK,raw
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent
p=root/'client/godot-tools/package.py';spec=importlib.util.spec_from_file_location('packaging_owner',p);owner=importlib.util.module_from_spec(spec);spec.loader.exec_module(owner)
work=TASK/'private/current-package-checks01';work.mkdir(mode=0o700,exist_ok=False);checks=[]
def check(v,name):assert v,name;checks.append(name);print('PASS '+name)
for name in ['/escape','../escape','a/../b','a//b']:
    try:owner.relative(name);raise AssertionError('unsafe path accepted')
    except ValueError:check(True,'reject unsafe member '+name)
dist=work/'inputs';dist.mkdir();f=dist/'quod.x86_64';f.write_bytes(b'fixture');f.chmod(0o755)
m={'passed':True,'trace_free':True,'diagnostic_overrides':{},'export_executable':str(f),'export_outputs':{f.name:{'sha256':raw(f),'bytes':f.stat().st_size}}}
manifest=work/'manifest.json';manifest.write_text(json.dumps(m));extras=work/'extras.json';extras.write_text('{}')
try:owner.package(manifest,'0'*64,extras,work/'bad-identity.tar.gz');raise AssertionError('wrong manifest identity accepted')
except ValueError:check(True,'reject an incorrect supplied export-manifest identity')
f.write_bytes(b'altered')
try:owner.package(manifest,raw(manifest),extras,work/'tampered.tar.gz');raise AssertionError('changed payload accepted')
except ValueError:check(True,'reject changed actual export bytes')
f.write_bytes(b'fixture');extras.write_text(json.dumps({f.name:{'source':'inputs/'+f.name,'sha256':raw(f),'mode':0o755}}))
try:owner.package(manifest,raw(manifest),extras,work/'collision.tar.gz');raise AssertionError('override accepted')
except ValueError:check(True,'extra notices cannot replace an export')
space=work/'a path with spaces';space.mkdir();shutil.copy2(root/'client/godot-tools/package/quod',space/'quod');(space/'quod').chmod(0o755)
fake=space/'quod.x86_64';fake.write_text('#!/bin/sh\nprintf "%s\\000" "$@"\nexit 37\n');fake.chmod(0o755)
args=['a b','$(false)','a"b',"a'b",'--','--profile','/private/path with spaces']
r=subprocess.run([str(space/'quod'),*args],cwd=work,capture_output=True)
check(r.returncode==37 and r.stdout.split(b'\0')[:-1]==[a.encode() for a in args] and not r.stderr,'launcher preserves cwd independence, literal argument boundaries and true child exit')
result={'passed':True,'checks':checks,'count':len(checks),'native_client_or_server_launched':False,'source_sha256':raw(p)};(ev/'inputs/current-package-checks01.json').write_text(json.dumps(result,indent=2)+'\n')

"""Bind one accepted trace-free export and its exact required notices."""
import hashlib,json,os,shutil,subprocess,sys,zipfile
from pathlib import Path
sys.dont_write_bytecode=True
from hashes import Digests,TASK,raw
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent
label=sys.argv[1];out=TASK/'artifacts'/label;out.mkdir(mode=0o700,exist_ok=False)
(out/'notices').mkdir();(ev/'inputs').mkdir(exist_ok=True)
d=Digests();manifest=root/'doc/evidence/godot-space-stage2-20261031/inputs/client-stage2-product01-manifest.json'
assert raw(manifest)=='18816e66c5fae94c282cb0025ff8968dca97e08a5f4eb3c4ee8a71d26b8fd8a3'
m=json.loads(manifest.read_text());assert m['passed'] and m['tracefree_product_composition'] and not m['diagnostic_overrides']
assert len(m['supplied_inputs'])==95 and len(m['export_outputs'])==196
assert all(d.h(root/n)==v for n,v in m['live_source_inputs'].items())
dist=Path(m['export_executable']).parent
assert all(d.h(dist/n)==r['sha256'] and (dist/n).stat().st_size==r['bytes'] for n,r in m['export_outputs'].items())
extras={};origins={}
def extra(name,data,origin,mode=0o644):
    p=out/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data);p.chmod(mode)
    extras[name]={'source':name,'sha256':raw(p),'mode':mode};origins[name]=origin
for name in ['quod','README.txt']:
    p=root/'client/godot-tools/package'/name;extra(name,p.read_bytes(),{'source':str(p.relative_to(root)),'sha256':raw(p)},0o755 if name=='quod' else 0o644)
engine=json.loads((TASK/'artifacts/engine/clean02/receipt.json').read_text());source=Path(engine['source'])
for name in ['LICENSE.txt','COPYRIGHT.txt','AUTHORS.md']:
    p=source/name;extra('notices/Godot-'+name,p.read_bytes(),{'qualified_engine_source':str(p),'sha256':d.h(p)})
for archive,names in [('microsoft.netcore.app.runtime.linux-x64.10.0.12.nupkg',['LICENSE.TXT','THIRD-PARTY-NOTICES.TXT']),('bouncycastle.cryptography.2.7.0.nupkg',['LICENSE.md'])]:
    row=m['dependency_archives'][archive];p=Path(row['referenced_path']);assert d.h(p)==row['sha256']
    with zipfile.ZipFile(p) as z:
        for name in names:extra('notices/'+('dotnet-' if archive.startswith('microsoft') else 'BouncyCastle-')+name,z.read(name),{'archive':archive,'archive_sha256':row['sha256'],'member':name})
reconstruction=json.loads((source.parent/'source-reconstruction.json').read_text())
patch=Path(reconstruction['actual_patch_apply_command'][-1])
assert raw(patch)==engine['patch_sha256']
extra('notices/private-engine.patch',patch.read_bytes(),{'qualified_patch_sha256':engine['patch_sha256']})
extra('notices/engine-provenance.json',(json.dumps({'upstream':'Godot 4.7.2 stable .NET Linux x86-64','engine_sha256':m['template']['sha256'],'source_only_build':True,'patch_sha256':engine['patch_sha256'],'modified_files':['modules/openxr/openxr_interface.cpp','modules/openxr/extensions/spatial_entities/openxr_spatial_marker_tracking.cpp'],'private_evaluation_only':True},indent=2)+'\n').encode(),{'source':'accepted clean02 receipt and two-file patch'})
(out/'extras.json').write_text(json.dumps(extras,indent=2)+'\n')
d.write(out/'used-stat-digests.json')
record={'passed':True,'manifest':str(manifest),'manifest_sha256':raw(manifest),'source_inputs':m['live_source_inputs'],'export_files':196,'export_bytes':sum(r['bytes'] for r in m['export_outputs'].values()),'extras':origins,'extras_manifest':str(out/'extras.json'),'extras_manifest_sha256':raw(out/'extras.json'),'cache':{'path':str(out/'used-stat-digests.json'),'sha256':raw(out/'used-stat-digests.json')},'compiled_application_inputs_copied':False,'product_changed':False}
(ev/'inputs'/('preparation-'+label+'.json')).write_text(json.dumps(record,indent=2)+'\n');print(json.dumps({'passed':True,'extras':len(extras),'product_inputs':95}))

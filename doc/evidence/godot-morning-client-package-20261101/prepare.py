"""Bind the accepted current product and reuse its qualified notice owner."""
import json,os,shutil,sys
from pathlib import Path
from hashes import Digests,TASK,raw
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent
label=sys.argv[1];out=TASK/'artifacts'/label;out.mkdir(mode=0o700,exist_ok=False)
d=Digests();manifest=root/'doc/evidence/godot-workbench-usability-20261101/inputs/client-workbench-ux-product01-manifest.json'
m=json.loads(manifest.read_text());assert m['passed'] and m['trace_free'] and not m['diagnostic_overrides']
cache=Path(m['digest_cache']['path']);assert raw(cache)==m['digest_cache']['sha256']
for row in json.loads(cache.read_text())['records']:d.values[tuple(row['stat_key'])]=row['sha256']
assert m['supplied_inputs']==m['live_source_inputs'] and len(m['supplied_inputs'])==98 and len(m['export_outputs'])==196
assert all(d.h(root/n)==v for n,v in m['live_source_inputs'].items())
dist=Path(m['export_executable']).parent
assert all(d.h(dist/n)==r['sha256'] and (dist/n).stat().st_size==r['bytes'] for n,r in m['export_outputs'].items())
prior=root/'doc/evidence/godot-m5-package-20261031/inputs/preparation-m5-package-inputs04.json'
prior_record=json.loads(prior.read_text());prior_spec=Path(prior_record['extras_manifest'])
assert d.h(prior_spec)==prior_record['extras_manifest_sha256']
extras={};origins={}
for name,row in json.loads(prior_spec.read_text()).items():
    source=(root/'client/godot-tools/package'/name) if name in ['quod','README.txt'] else prior_spec.parent/row['source']
    if name not in ['quod','README.txt']:assert d.h(source)==row['sha256']
    target=out/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,target);target.chmod(row['mode'])
    extras[name]={'source':name,'sha256':raw(target),'mode':row['mode']}
    origins[name]={'path':str(source),'sha256':d.h(source)}
(out/'extras.json').write_text(json.dumps(extras,indent=2)+'\n')
d.write(out/'stat-digests.json')
record={'passed':True,'manifest':str(manifest),'manifest_sha256':raw(manifest),'source_inputs':m['live_source_inputs'],'export_files':196,'export_bytes':sum(r['bytes'] for r in m['export_outputs'].values()),'extras':origins,'extras_manifest':str(out/'extras.json'),'extras_manifest_sha256':raw(out/'extras.json'),'cache':{'path':str(out/'stat-digests.json'),'sha256':raw(out/'stat-digests.json')},'compiled_application_inputs_copied':False,'product_changed':True,'dependency_floor':'GLIBC_2.44, unchanged accepted16ELFs'}
(ev/'inputs'/('preparation-'+label+'.json')).write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'passed':True,'extras':len(extras),'product_inputs':len(m['supplied_inputs']),'exports':196}))

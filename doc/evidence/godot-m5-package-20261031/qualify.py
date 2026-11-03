"""Bind completed new package/software evidence; no tests or old APIs replayed."""
import json,os,stat
from pathlib import Path
from hashes import Digests,TASK,key,raw
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
def load(p):return json.loads(p.read_text())
def cache(path,sha):
    assert raw(path)==sha
    rows=load(path)['records']
    for r in rows.values() if isinstance(rows,dict) else rows:d.values[tuple(r['stat_key'])]=r['sha256']
product_path=root/'doc/evidence/godot-space-stage2-20261031/inputs/client-stage2-product01-manifest.json';assert raw(product_path)=='18816e66c5fae94c282cb0025ff8968dca97e08a5f4eb3c4ee8a71d26b8fd8a3';product=load(product_path)
assert len(product['live_source_inputs'])==95 and all(d.h(root/n)==v for n,v in product['live_source_inputs'].items())
builds={}
for label in ['m5-companion01','m5-companion02','m5-companion03','m5-companion04','m5-companion05']:
    p=ev/'inputs'/('client-'+label+'-manifest.json');m=load(p);assert m['passed'] and m['live_source_inputs']==product['live_source_inputs'] and len(m['supplied_inputs'])==96 and not m['compiled_application_inputs_copied'] and not m['distributable']
    cache(Path(m['digest_cache']['path']),m['digest_cache']['sha256']);stage=Path(m['stage'])
    assert all(d.h(stage/'source'/n)==sha for n,sha in m['supplied_inputs'].items())
    assert len(m['commands'])==5
    for c in m['commands']:
        receipt=ev/(label+'-'+c['phase'])/'result.json';r=load(receipt);assert r['exit']==c['true_exit']==0 and not r['diagnostic_failure']
    dist=Path(m['export_executable']).parent;assert len(m['export_outputs'])==196
    assert all(d.h(dist/n)==r['sha256'] and (dist/n).stat().st_size==r['bytes'] for n,r in m['export_outputs'].items())
    builds[label]={'manifest_sha256':raw(p),'commands':5,'exports':196,'actual_live_product_inputs_equal':True,'changed_exports':{n:r for n,r in m['export_outputs'].items() if r!=product['export_outputs'][n]}}
selected=load(ev/'inputs/m5-journey05.json');assert selected['passed'] and not selected['reader_errors'] and len(selected['eof'])==6 and all(selected['eof'].values())
assert len(selected['children'])==3 and all(c['true_exit']==0 for c in selected['children'].values())
assert all(selected['children'][n]['explicit_completion'] for n in ['client-initial','client-reopen'])
for r in selected['streams'].values():
    p=Path(r['path']);assert d.h(p)==r['sha256'] and p.stat().st_size==r['bytes'] and stat.S_IMODE(p.stat().st_mode)==0o600
ordinary=load(ev/'inputs/m5-ordinary03.json');assert ordinary['passed'] and ordinary['true_exit']==ordinary['normal_close_exit']==0 and ordinary['packaged_coreclr_loaded'] and not ordinary['qualification_flag']
assert load(ev/'inputs/isolation-probe01.json')['passed'] and load(ev/'inputs/package-checks01.json')['passed']
inspection=load(ev/'inputs/package-final-inspection04.json');assert inspection['passed'] and inspection['symbol_versions']['GLIBC']=='2.44'
base=load(TASK/'artifacts/m5-package-inputs04/package04.json');repro=load(TASK/'artifacts/m5-package-inputs04/package05-repro.json');assert base==repro
first=load(TASK/'artifacts/m5-package-inputs02/package01.json')
assert {n:r for n,r in base['files'].items() if n!='README.txt'}=={n:r for n,r in first['files'].items() if n!='README.txt'}
assert inspection['files']==207 and base['export_files']==196
retirement=load(ev/'inputs/retirement-inventory.json');assert retirement['read_only'] and not retirement['moves_deletions_deployment']
run_rows={}
for p in sorted((ev/'logs').glob('*.json')):
    r=load(p)
    for field in ['private_streams','sanitized_streams']:
        for row in r[field].values():
            f=Path(row['path']);assert d.h(f)==row['sha256'] and f.stat().st_size==row['bytes']
    run_rows[p.stem]={'true_exit':r['child_exit'],'timed_out':r['timed_out'],'receipt_sha256':raw(p)}
assert not any(r['timed_out'] for r in run_rows.values())
profile=TASK/'private/m5-journey05/sandbox/home/profile/active.json';assert stat.S_IMODE(profile.stat().st_mode)==0o600 and stat.S_IMODE(profile.parent.stat().st_mode)==0o700
server=load(ev/'inputs/server-m5-journey05-server.json');assert server['child_exit']==0 and server['runtime_recompiled']
for name,row in server['executed_current_sources'].items():assert d.h(root/name)==row['sha256']
counts={n:len(selected['children'][n]['checks']) for n in ['client-initial','client-reopen']}
result={'passed':True,'checkpoint':'private Linux package/software first-journey; full M5 remains open','selected_archive':str(TASK/'artifacts/quod-stage2-linux-x86_64-private04.tar.gz'),'archive_sha256':base['archive_sha256'],'archive_bytes':base['archive_bytes'],'extracted_launch':inspection['extracted']+'/quod','files':207,'product_input_manifest_sha256':raw(product_path),'product_inputs':95,'product_outputs':196,'product_DLL':product['export_outputs']['data_Quod_linuxbsd_x86_64/Quod.dll']['sha256'],'product_PCK':product['export_outputs']['quod.pck']['sha256'],'engine':product['template'],'product_input_changes':0,'production_domain_or_UI_changes':0,'ordinary_uninstrumented_launch':{'actual_client_exit':0,'normal_guarded_close':0,'developer_tree_and_build_tools_absent':True,'own_CoreCLR_loaded':True,'reused_for_final_notice_only_delta':'all payload/launcher bytes equal; README-only difference proved'},'diagnostic_companion':'m5-companion05; identical95 live product inputs plus one removable partial/dispatch; never distributed','companion_builds':builds,'native_journey':{'checks':counts,'native_input_records':selected['native_input_count'],'children':{n:r['true_exit'] for n,r in selected['children'].items()},'eof':6,'reader_errors':[],'original_identities_and_no_replay':True,'signed_control_source_bindings':server['executed_current_sources']},'package_finite_checks':load(ev/'inputs/package-checks01.json')['count'],'reproducible_archive_bytes':True,'ELF_objects':16,'GLIBC_floor':'2.44','cold_other_host':False,'headset_hardware_runtime_started':False,'full_M4_or_M5':False,'retirement_or_cutover':False,'commit_or_push':False,'source_delta':'additive package tooling/docs/evidence only; inherited product inputs unchanged','retirement_counts':retirement['counts'],'runs':run_rows,'failures_retained':['m5-prepare01','m5-ordinary01','m5-ordinary02','m5-journey01','m5-journey02','m5-journey03','m5-journey04'],'limits':['ordinary production package launch plus separately instrumented native-keyboard journey; no claim the uninstrumented product was itself driven through the whole journey','mouse guard failure remains retained; no pointer/hardware pass inferred','GLIBC2.44 pinned private engine; no older-distribution claim','full integrated-server release gates, hardware/comfort/old desktop stalls and irreversible retirement/cutover remain open'],'tracker_body_publication':'blocked; no retry or bypass; metadata-only link returned linkedCount0, not visible/publication proof'}
cache_path=TASK/'cache/m5-package-qualified01.json';d.write(cache_path);result['digest_cache']={'path':str(cache_path),'sha256':raw(cache_path)}
(ev/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({'passed':True,'checks':counts,'archive_sha256':base['archive_sha256'],'product_changes':0}))

"""Bind this bounded correction to retained inputs, outcomes and private captures.

Old export/archive bytes are not read. Builder-authenticated exact stat records
bind the already measured exports; new source and receipts retain full digests.
"""
import difflib,json,os,stat
from pathlib import Path
from hashes import Digests,TASK,key,raw

os.umask(0o077)
root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests();artifacts={}
def bind(path,expected=None):
    p=Path(path);digest=d.h(p);s=p.lstat()
    assert stat.S_ISREG(s.st_mode),p
    if expected:assert digest==expected,(p,digest,expected)
    artifacts[str(p)]={'sha256':digest,'bytes':s.st_size,'mode':s.st_mode,'stat_key':key(p)}
    return digest
def cached(path,expected):
    p=Path(path);assert d.values.get(key(p))==expected,('exact-stat custody',p)
def read(path):
    bind(path);return json.loads(Path(path).read_text())

manifests={}
for p in sorted((ev/'inputs').glob('client-*-manifest.json')):
    m=read(p);assert m['passed'] and len(m['live_source_inputs'])==98 and len(m['export_outputs'])==196
    cache=Path(m['digest_cache']['path']);assert raw(cache)==m['digest_cache']['sha256']
    for row in json.loads(cache.read_text())['records']:
        k=tuple(row['stat_key']);assert k not in d.values or d.values[k]==row['sha256'];d.values[k]=row['sha256']
    assert len(m['commands'])==5 and all(c['true_exit']==0 for c in m['commands'])
    source=Path(m['stage'])/'source'
    for name,digest in m['supplied_inputs'].items():bind(source/name,digest)
    dist=Path(m['export_executable']).parent
    for name,row in m['export_outputs'].items():
        cached(dist/name,row['sha256']);assert (dist/name).stat().st_size==row['bytes']
    manifests[p.name.removeprefix('client-').removesuffix('-manifest.json')]=m

product=manifests['visibility-product01'];assert product['trace_free'] and not product['distributable'] and not product['diagnostic_overrides']
assert product['supplied_inputs']==product['live_source_inputs']
for name,digest in product['live_source_inputs'].items():bind(root/name,digest)
before=read(ev/'inputs/before.json');delta={}
for name,row in before.items():
    prior=root/row['before'];current=root/name;bind(prior,row['sha256']);bind(current)
    lines=list(difflib.unified_diff(prior.read_text().splitlines(),current.read_text().splitlines(),n=0))
    delta[name]={'before_sha256':row['sha256'],'after_sha256':artifacts[str(current)]['sha256'],
                 'added':sum(s.startswith('+') and not s.startswith('+++') for s in lines),
                 'removed':sum(s.startswith('-') and not s.startswith('---') for s in lines)}

gates={};server_vector=None
for p in sorted((ev/'logs').glob('*-run.json')):
    wrapper=read(p);label=p.name.removesuffix('-run.json');record=read(TASK/'private'/label/'result.raw.json')
    public=read(ev/'inputs'/(label+'.json'))
    assert public['passed']==record['passed'] and record['reader_errors']==[] and len(record['eof'])==4 and all(record['eof'].values())
    assert record['native_input_count']==0 and not record['host_input_or_focus_action'] and record['no_headset_or_runtime']
    for group in ['private_streams','sanitized_streams']:
        for row in wrapper[group].values():bind(row['path'],row['sha256'])
    for name,digest in wrapper['driver_inputs'].items():bind(TASK/'private/runs'/(label+'-run')/'driver-inputs'/name,digest)
    for row in record['driver_inputs'].values():bind(row['copy'],row['sha256'])
    for name,row in record['streams'].items():
        bind(row['path'],row['sha256']);assert Path(row['path']).stat().st_mode&0o777==0o600
        data=Path(row['path']).read_bytes();sanitized=b''.join(line if line.startswith((b'PASS ',b'OCCURRENCE_PASS')) else b'<private fixture/client diagnostic>\n' for line in data.splitlines(keepends=True))
        target=ev/'logs'/(label+'-'+Path(name).stem+'.log');assert target.read_bytes()==sanitized;bind(target)
    client_name=next(n for n in record['children'] if n.startswith('client-'));child=record['children'][client_name]
    phase=client_name.removeprefix('client-');value_path=TASK/'private'/label/'sandbox/work'/(phase+'.json')
    behavior=read(value_path) if value_path.exists() else None
    for captured in sorted((TASK/'private'/label/'sandbox/work').iterdir()):
        if captured.is_file() and captured.suffix in ['.png','.json','.jsonl']:bind(captured)
    supplied=Path(wrapper['command'][4]);assert raw(supplied)==record['manifest_sha256']
    m=json.loads(supplied.read_text());runtime_differences=[n for n,v in m['live_source_inputs'].items() if product['live_source_inputs'][n]!=v]
    server=read(root/'doc/evidence/godot-space-experience-20261101/inputs'/('server-'+label+'-server.json'))
    vector={n:r['sha256'] for n,r in server['executed_current_sources'].items()};assert len(vector)==14
    if server_vector is None:server_vector=vector
    assert vector==server_vector
    for name,row in server['executed_current_sources'].items():
        bind(row['saved_source'],row['sha256']);bind(root/name,row['sha256'])
        if 'compiled_object' in row:cached(row['compiled_object']['path'],row['compiled_object']['sha256'])
        if 'presentation_overlay' in row:bind(row['presentation_overlay']['copy'],row['sha256'])
    for row in server['driver_sources'].values():bind(row['path'],row['sha256'])
    gates[label]={'whole_passed':record['passed'],'wrapper_exit':wrapper['child_exit'],
        'children':{n:c['true_exit'] for n,c in record['children'].items()},'eof':record['eof'],'reader_errors':record['reader_errors'],
        'explicit_completion':child.get('explicit_completion',False),'functional_checks':len(behavior['checks']) if behavior else None,
        'functional_result_passed':behavior.get('passed') if behavior else None,'failure':record.get('failure'),
        'unretired_failure':record.get('unretired_failure',False),'product_input_differences':runtime_differences,
        'manifest':str(supplied),'manifest_sha256':record['manifest_sha256'],'raw_record':str(TASK/'private'/label/'result.raw.json')}

selected=['visibility-hierarchy09','visibility-interaction-observe07','visibility-question08']
assert all(gates[n]['whole_passed'] and gates[n]['explicit_completion'] for n in selected)
assert all(set(gates[n]['product_input_differences'])<= {'client/godot/README.md'} for n in selected+['visibility-layout06','visibility-preview06'])
assert not gates['visibility-preview06']['whole_passed'] and gates['visibility-preview06']['functional_result_passed']
assert not gates['visibility-interaction06']['whole_passed']
for p in sorted((ev/'logs').glob('*-build.json')):
    w=read(p);assert w['child_exit']==0 and not w['timed_out']
    for group in ['private_streams','sanitized_streams']:
        for row in w[group].values():bind(row['path'],row['sha256'])
    for name,digest in w['driver_inputs'].items():bind(TASK/'private/runs'/p.stem/'driver-inputs'/name,digest)

proof=TASK/'cache/occurrence-visibility-evidence01.json';proof.write_text(json.dumps({'artifacts':artifacts},indent=2)+'\n')
cache=TASK/'cache/occurrence-visibility-hashes01.json';d.write(cache)
result={'evidence_verified':True,'bounded_correction_selected_gates_passed':True,'all_affected_runs_passed':False,
 'preview_normal_retirement_qualified':False,'interaction06_cause_established':False,'human_hmd_accepted':False,
 'production_delta':delta,'product':{'manifest':str(ev/'inputs/client-visibility-product01-manifest.json'),
 'manifest_sha256':raw(ev/'inputs/client-visibility-product01-manifest.json'),'inputs':98,'exports':196,
 'export_bytes':sum(r['bytes'] for r in product['export_outputs'].values()),'trace_free':True,'distributable':False,
 'executable':product['export_executable']},'gates':gates,'selected_gates':selected,'server_sources':server_vector,
 'builds':{n:{'phases':[c['true_exit'] for c in m['commands']],'supplied':len(m['supplied_inputs']),'trace_free':m['trace_free']} for n,m in manifests.items()},
 'observer05':'built, never run','evidence_index':{'path':str(proof),'sha256':raw(proof),'records':len(artifacts)},
 'cache':{'path':str(cache),'sha256':raw(cache),'records':len(d.values)},
 'old_export_archive_bytes_read':0,'host_input_native_xr':0,'package_created':False}
(ev/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'evidence_verified':True,'selected':[gates[n]['functional_checks'] for n in selected],
                  'preview_whole_passed':False,'artifacts':len(artifacts),'product':result['product']}))

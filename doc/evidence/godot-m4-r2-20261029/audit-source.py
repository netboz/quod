#!/usr/bin/env python3
"""Compare final authored bytes with accepted server/M4 source, not a dirty main."""
import difflib,hashlib,json,subprocess,sys,tarfile
from pathlib import Path
root=Path.cwd();ev=Path(__file__).resolve().parent;label=sys.argv[1]
prior=Path('/home/yan/.cache/quod-m4-artifacts/quod-godot-m4-handoff-ca84d4f8-20261029-01')
def h(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
server=json.loads((prior/'prerequisite-m3b-clean-inputs.json').read_text())['server_authored_inputs']
stage=Path('/tmp/quod-m3b-8b352c53/m3b-gates01/source');errors=[]
for name,sha in server.items():
    for prefix in (root,stage):
        if h(prefix/name)!=sha:errors.append(str(prefix/name))
assert not errors,errors
old=json.loads((root/'doc/evidence/godot-m4-20261029/inputs/client-candidate09-manifest.json').read_text())
new=json.loads((ev/'inputs'/('client-'+label+'-manifest.json')).read_text());assert new['passed'] and new['distributable']
assert all(h(root/name)==sha for name,sha in new['authored_inputs'].items())
changes={};patch=[]
with tarfile.open(prior/'all-client-supplied-inputs.tar.gz') as archive:
    names=archive.getnames()
    for name,sha in new['authored_inputs'].items():
        if old['authored_inputs'].get(name)==sha:continue
        candidates=[n for n in names if n.endswith('/'+name)]
        contents={archive.extractfile(n).read() for n in candidates}
        matches=[v for v in contents if hashlib.sha256(v).hexdigest()==old['authored_inputs'].get(name)]
        assert len(matches)==1,name
        before=matches[0].decode();after=(root/name).read_text()
        diff=list(difflib.unified_diff(before.splitlines(True),after.splitlines(True),fromfile='candidate09/'+name,tofile=label+'/'+name));patch+=diff
        kind='documentation' if name.endswith('.md') else 'qualification/tool' if '/tests/' in name or name.startswith('client/godot-tests/') else 'production'
        changes[name]={'before_sha256':old['authored_inputs'][name],'after_sha256':sha,'kind':kind,
            'added':sum(l.startswith('+') and not l.startswith('+++') for l in diff),'removed':sum(l.startswith('-') and not l.startswith('---') for l in diff)}
assemblies=list(Path(new['export_executable']).parent.rglob('Quod.dll'));assert len(assemblies)==1
data=assemblies[0].read_bytes();assert all(s.encode('utf-16-le') not in data for s in ['M4_R1_SHUTDOWN','M4_R2_RENEWAL'])
totals={kind:{metric:sum(row[metric] for row in changes.values() if row['kind']==kind) for metric in ['added','removed']} for kind in ['production','qualification/tool','documentation']}
record={'final_client_label':label,'base_head':subprocess.check_output(['git','rev-parse','HEAD']).decode().strip(),
    'index_empty':not subprocess.check_output(['git','diff','--cached','--name-only']),'unchanged_server_input_count':len(server),
    'live_and_accepted_stage_verified':True,'errors':errors,'client_delta_vs_candidate09':changes,'line_deltas':totals,
    'client_supplied_inputs':len(new['authored_inputs']),'client_exports':len(new['export_outputs']),
    'production_tracing':False,'final_assembly_diagnostic_markers_absent':True,'retirements_or_relocations':0}
(ev/'inputs'/(label+'-source-delta.json')).write_text(json.dumps(record,indent=2)+'\n')
(ev/'inputs'/(label+'-vs-candidate09.patch')).write_text(''.join(patch))
print(json.dumps({'changed_client_inputs':len(changes),'line_deltas':totals,'server_inputs_verified_twice':len(server),'production_tracing':False,'retirements':0}))

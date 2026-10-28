#!/usr/bin/env python3
"""Verify preserved prerequisites and exact evidence reuse without editing them."""
import hashlib,json,sys
from pathlib import Path
root=Path.cwd()
evidence=root/'doc/evidence/godot-m2-20261028'
client_label=sys.argv[1]
prior=Path('/home/yan/.cache/quod-m1b-artifacts/quod-godot-m1b-handoff-1e4ef676-20261028-02')
rows=json.loads((prior/'source-manifest.json').read_text())
groups={
 'm0_evidence':'doc/evidence/godot-m0-20261027/',
 'm1a_evidence':'doc/evidence/godot-m1a-20261027/',
 'm1b_evidence':'doc/evidence/godot-m1b-20261028/',
 'archived_originals':'outdated/ontologies/prolog/',
 'erlang_runtime':'src/', 'erlang_headers':'include/'}
verified={k:{} for k in groups}
unchanged_client=['Core/Accounts.cs','Core/Identity.cs','Core/LocalStore.cs','Core/Transport.cs','Core/SignedView.cs','Core/Forms.cs','Core/Term.cs','QuestionHub.cs','SourcePanel.cs','Quod.csproj','packages.Debug.linux-x64.lock.json','packages.ExportRelease.linux-x64.lock.json']
# Resolve real existing files from the source manifest, avoiding invented paths.
client_names={r['path'] for r in rows if r['path'].startswith('client/godot/')}
required={n for n in client_names if any(n.endswith('/'+s) for s in unchanged_client)}
required|={r['path'] for r in rows if r['path'].startswith('client/godot-tools/')}
verified['reused_client_owners_and_tools']={}
for row in rows:
 name=row['path']; buckets=[k for k,prefix in groups.items() if name.startswith(prefix)]
 if name in required: buckets.append('reused_client_owners_and_tools')
 if not buckets: continue
 path=root/name
 if row['kind']=='symlink':
  assert path.is_symlink() and str(path.readlink())==row['target'],name
  actual={'symlink':str(path.readlink())}
 else:
  actual=hashlib.sha256(path.read_bytes()).hexdigest();assert actual==row['sha256'],name
 for k in buckets: verified[k][name]=actual
client=json.loads((evidence/'inputs'/('client-'+client_label+'-manifest.json')).read_text())
old_client=json.loads((prior/'client-qualification.json').read_text())
assert client['dependency_archives']==old_client['dependency_archives']
assert client['engine_archives']==old_client['engine_archives']
fixture='client/godot/tests/ExportLifecycle.cs'
def crash_section(text):
 return text.split('        if (phase.StartsWith("crash-")) {',1)[1].split('        var corpus =',1)[0]
crash_current=crash_section((root/fixture).read_text())
assert crash_current==crash_section((prior/'source-tree'/fixture).read_text())
result=dict(client_campaign=client_label,prior_snapshot=str(prior),prior_snapshot_sha256=hashlib.sha256((prior/'snapshot.json').read_bytes()).hexdigest(),
 verified_unchanged=verified,counts={k:len(v) for k,v in verified.items()},
 exact_nuget_archives_unchanged=len(client['dependency_archives']),exact_engine_archives_unchanged=len(client['engine_archives']),
 reused_obligations=['OS entropy strength: unchanged Identity/SDK/runtime; M1b syscall evidence retained',
 'Atomic active-store rename/directory-sync crash boundaries: unchanged LocalStore and exact crash fixture section; M1b child exits retained'],
 reused_fixture_sections={fixture+'#crash-phases':hashlib.sha256(crash_current.encode()).hexdigest()},
 limitation='Reuse applies only to unchanged inputs/obligations. New Main/form/operation/scene behavior and changed Prolog composition receive M2 qualification.')
with (evidence/'inputs'/('prerequisite-reuse-'+client_label+'.json')).open('x') as file:
 file.write(json.dumps(result,indent=2)+'\n')
print(json.dumps(result['counts']))

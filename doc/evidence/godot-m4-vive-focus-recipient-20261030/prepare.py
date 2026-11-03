"""Filesystem-only source/prerequisite custody; no process/window/device queries."""
import json,os,shutil,subprocess,sys
from pathlib import Path
sys.dont_write_bytecode=True
from freeze_hashes import Digests,TASK,key,raw
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
prior=TASK/'artifacts/quod-godot-m4-vive-focus12-handoff-ca84d4f8-20261030-01'
old=json.loads((prior/'source-manifest.json').read_text())
destination=TASK/'private/metadata-inputs/focus-recipient-base01'
destination.mkdir(mode=0o700,exist_ok=False)
assert subprocess.check_output(['git','branch','--show-current']).decode().strip()=='worktree/pearl-stone'
assert subprocess.check_output(['git','rev-parse','HEAD']).decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
assert subprocess.check_output(['git','rev-parse','HEAD^']).decode().strip()=='f716ddf5e578df957a5b18421a0727a32c634f87'
assert not subprocess.check_output(['git','diff','--cached','--name-only'])
misses=[];checked=0
for n,r in old.items():
    p=root/n
    if r['kind']=='symlink':assert p.is_symlink() and str(p.readlink())==r['target'];continue
    assert p.is_file() and not p.is_symlink() and p.stat().st_size==r['bytes'] and p.stat().st_mode&0o7777==r['mode']
    if key(p) not in d.values:misses.append(n)
    else:assert d.h(p)==r['sha256'];checked+=1
assert not misses,('unchanged prior source needs current custody before reuse',misses)
helper=root/'doc/evidence/godot-m4-vive-retest10-20261030/focus_events.py'
assert d.h(helper)=='bb63ff9db8f3aef231f22043e8336c263afcf52b553c908419ff3e0abdd584e2'
sources={}
for p in [helper,helper.with_name('focus_checks.py'),helper.with_name('focus-fixtures.json'),
          root/'nimbalyst-local/handoffs/godot-m4-vive-focus-recipient-offline-93.md']:
    q=destination/p.name;shutil.copy2(p,q)
    assert raw(q)==d.h(p) and q.stat().st_mode&0o7777==p.stat().st_mode&0o7777
    sources[str(p.relative_to(root))]={'sha256':d.h(p),'mode':p.stat().st_mode&0o7777,'bytes':p.stat().st_size,'copy':str(q)}
assert sources['nimbalyst-local/handoffs/godot-m4-vive-focus-recipient-offline-93.md']['sha256']=='053b545039064c219d8b90e7cf48f2b657c78af8cfd5848a2ee1c5eb8153f1ff'
bindings={}
for name,expected in {
 'focus12-final-verification-92.json':'9348146f03a29c00bdabb7dee3984f64942f815da4eef1d47f23e4118d444a78',
 'fable-focus-report-92.md':'4de25adae3a9bbb0c50648a3a331ba89e271787008e45b9686111c164071dbea',
 'fable-focus-disposition-92.json':'3b1df667853af60aa87dc5bea0dcb5ef7106f715236e7e0fe88a0e0909bef9a7',
 'focus-diagnostic-mapping-check-92.json':'4f5127a03de9f8871efde30f06128b74af0397ce8887a25270790a8db4802f0c',
 }.items():
    p=root/'_build/godot-m4-r2-coordinator-20261029'/name;assert d.h(p)==expected
    bindings[name]={'path':str(p),'sha256':expected}
record={'passed':True,'previous_snapshot_sha256':d.h(prior/'snapshot.json'),
 'prior_source_paths_checked':len(old),'prior_file_exact_stat_cache_hits':checked,'bulk_prior_source_rehash':False,
 'root_actual_complete_source':str(TASK/'builds/coordinator-focus12-source-reconstruction-92'),
 'preserved_before_inputs':sources,'independent_prerequisites':bindings,'capacity_free_bytes':shutil.disk_usage(TASK).free,
 'new_application_build_runtime_fixture_device_display_or_socket_actions':False,
 'earlier_inspection_failure':'rg exit2: guessed inputs/model-session.json absent; actual existing inputs/launcher-metadata.json read. Inspection-only; no product action/failure.',
 'tracker':'OwnUUID explicit-project work_radar0/nestedisErrorfalse/0threads/0signals; no mutation/publication.',
 'model':'Actual own session summary openai-codex:gpt-6.1-sol; retained launcher metadata requested/returnedmax; effective backend effort unexposed.'}
(ev/'baseline.json').write_text(json.dumps(record,indent=2)+'\n');d.write(ev/'baseline-used-digests.json')
print(json.dumps({'passed':True,'prior_source_paths':len(old),'exact_stat_file_hits':checked,'saved_before_inputs':len(sources),'no_live_queries':True}))

"""Metadata/custody and syntax preflight only; never starts a live observer."""
import ast,json,os,subprocess,sys
from pathlib import Path
sys.dont_write_bytecode=True
from freeze_hashes import Digests,TASK,key,raw
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
prior=TASK/'artifacts/quod-godot-m4-vive-focus12-handoff-ca84d4f8-20261030-01'
source=json.loads((prior/'source-manifest.json').read_text());original=TASK/'builds/coordinator-focus12-source-reconstruction-92'
missing=[]
for n,r in source.items():
    p=original/n
    if r['kind']=='symlink':assert p.is_symlink() and str(p.readlink())==r['target'];continue
    assert p.is_file() and not p.is_symlink() and p.stat().st_mode&0o7777==r['mode'] and p.stat().st_size==r['bytes']
    if key(p) not in d.values:missing.append(n)
    else:assert d.values[key(p)]==r['sha256']
assert not missing,('no old-source bulk hash authorized',missing)
helper=root/'doc/evidence/godot-m4-vive-retest10-20261030/focus_events.py'
for p in [*ev.glob('*.py'),helper]:ast.parse(p.read_bytes(),filename=str(p))
assert raw(helper)=='a7b584c8b137b5617b89a98e57f6f42e895d3247278b4c3de52b595ecbea5889'
for suffix in ['source','delta','group']:
    assert not (TASK/'builds'/('vive-focus-recipient-'+suffix+'-reconstruction01')).exists()
assert not (TASK/'artifacts/quod-godot-m4-vive-focus-recipient-handoff-ca84d4f8-20261030-01').exists()
assert not (TASK/'artifacts/vive-focus-recipient-freeze-runs01').exists()
assert subprocess.check_output(['git','diff','--check'])==b'' and not subprocess.check_output(['git','diff','--cached','--name-only'])
record={'passed':True,'actual_parent_complete_source':str(original),'parent_source_paths':len(source),
 'missing_exact_stat_custody':missing,'old_source_bytes_rehashed':0,'new_helpers_syntax_checked':True,
 'one_changed_inherited_file':str(helper.relative_to(root)),'new_full_materialization_labels_unused':True,
 'no_live_commands_or_subscription':True,'capacity_free_bytes':__import__('shutil').disk_usage(TASK).free}
(ev/'freeze-preflight.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record))

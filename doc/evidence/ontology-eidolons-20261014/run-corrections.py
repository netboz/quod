import datetime, hashlib, json, os, pathlib, subprocess, sys, time

base = pathlib.Path('/home/yan/src/quod/_build/ontology-eidolons-20261014/corrections-02')
tree = base/'tree'; logs = base/'logs'; logs.mkdir()
manifest = json.loads((base/'source-manifest.json').read_text())
def unchanged():
    return all(hashlib.sha256((tree/p).read_bytes()).hexdigest() == h for p,h in manifest.items())
commands = [('client',['npm','--prefix','client','test']),
    ('ui-build',['npm','--prefix','ui','run','build']),
    ('ui-lint',['npm','--prefix','ui','run','lint']),
    ('eunit',['rebar3','as','test','eunit','--module=quod_class_semantics_tests,quod_common_primitives_tests,quod_prolog_ontology_tests,quod_lens_tests,quod_agent_predicates_tests','--generator=quod_lobby_tests:presentation_modes_and_ground_lens_targets_use_authorized_owner_reads_test_+ontology_instances_share_selection_and_authorized_inspection_test_+non_system_read_only_source_uses_the_same_recipe_test_+scoped_routes_reuse_the_directory_and_preserve_private_admission_test_+system_ontology_editing_uses_universal_scope_identity_test_+public_system_ontology_source_is_readable_but_not_mutable_test_+complete_source_cursor_retains_current_snapshot_test_']),
    ('xref',['rebar3','xref']), ('dialyzer',['rebar3','dialyzer'])]
env = dict(os.environ, ERL_FLAGS='+S 4:4 +SDcpu 2 +SDio 2', CARGO_NET_OFFLINE='true')
for key in ['LD_LIBRARY_PATH','LD_PRELOAD']: env.pop(key,None)
results = []
for name,args in commands:
    assert unchanged(), 'frozen source changed before '+name
    start = datetime.datetime.now(datetime.timezone.utc).isoformat(); clock = time.monotonic()
    print('Starting '+name, flush=True)
    with (logs/(name+'.log')).open('xb') as out:
        result = subprocess.run(args,cwd=tree,env=env,stdout=out,stderr=subprocess.STDOUT)
    row = {'name':name,'command':args,'started':start,'exit':result.returncode,
           'seconds':round(time.monotonic()-clock,2),'sources_unchanged':unchanged()}
    results.append(row); (base/'results.json').write_text(json.dumps(results,indent=2)+'\n')
    print(json.dumps(row),flush=True)
    if result.returncode or not row['sources_unchanged']:
        (base/'STOP.json').write_text(json.dumps(row,indent=2)+'\n');sys.exit(result.returncode or 1)
(base/'PASSED.json').write_text(json.dumps({'passed':True,'results':results},indent=2)+'\n')

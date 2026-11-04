from pathlib import Path
import hashlib,json,subprocess,tempfile,time,sys
ROOT=Path(__file__).resolve().parents[3]
E=Path(__file__).resolve().parent
receipt=ROOT/'doc/evidence/stage2-predicate-removal-20261103/inputs/source-long-fixed01.json'
m=json.loads(receipt.read_text())
cmd=m['command'][:m['command'].index('-eval')]
paths=cmd[cmd.index('-pa')+1:]
# Reuse recorded production beams only after verifying their exact bytes.
beam_checks={p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for d in paths for p in map(str,Path(d).glob('*.beam'))}
assert all(m['runtime_beams'].get(p)==h for p,h in beam_checks.items())
owner_sources=['src/quod_client_view.erl','src/quod_client_goal.erl','src/quod_client_goal_parser.erl','src/quod_wire_term.erl','src/quod_time.erl']
source_hashes={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in owner_sources}
assert all(m['source_inputs'][p]==h for p,h in source_hashes.items())
label=sys.argv[1]
assert not (E/(label+'.json')).exists(), 'Use a new label; never overwrite a run'
out=Path(tempfile.mkdtemp(prefix='quod-limit-audit-'))
probe=E/'source_view_probe_fixed.erl'
expr='{ok,source_view_probe_fixed}=compile:file('+json.dumps(str(probe))+',[debug_info,report_errors,report_warnings,{outdir,'+json.dumps(str(out))+'}]),true=code:add_patha('+json.dumps(str(out))+'),source_view_probe_fixed:run(),halt(0).'
cmd+=['-eval',expr]
t=time.monotonic();p=subprocess.run(cmd,cwd=out,capture_output=True)
(E/(label+'-stdout.log')).write_bytes(p.stdout);(E/(label+'-stderr.log')).write_bytes(p.stderr)
r={'purpose':'Observe existing source-access shape gap through production WebSocket callback; expiry prevents auth workers and store access. Not end-to-end signed acceptance.','true_exit':p.returncode,'stdout_eof':True,'stderr_eof':True,'elapsed_seconds':time.monotonic()-t,'command':cmd,'cwd':str(out),'owner_source_sha256':source_hashes,'probe_sha256':hashlib.sha256(probe.read_bytes()).hexdigest(),'driver_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'production_receipt_sha256':hashlib.sha256(receipt.read_bytes()).hexdigest(),'verified_runtime_beams':beam_checks}
(E/(label+'.json')).write_text(json.dumps(r,indent=2)+'\n')
print(p.stdout.decode());print(p.stderr.decode());print('TRUE_EXIT',p.returncode);sys.exit(p.returncode)

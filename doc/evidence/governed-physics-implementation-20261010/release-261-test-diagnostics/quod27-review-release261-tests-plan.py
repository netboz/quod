from pathlib import Path
import hashlib,json,shutil
r=Path('/home/yan/src/quod');b=r/'_build/quod27-release261-test-plan-review-01';b.mkdir()
intro='''Yan explicitly requested Claude Fable reviews of plans and implementations for QUD.27. Review this bounded test-only correction plan. Tools and hooks are disabled; use only supplied local-source excerpts and synthetic fixture evidence. No private browser, identity key or network job configuration is supplied. Advice remains consultative.

Release261 adds one native f32 floor-slide arithmetic correction, already reviewed by Fable with22 native tests passed. Full clean sequential gate03 stopped at EUnit:3879tests,2failures. (1) opening_worker_cancellation_test expected monitor DOWN reason killed but timed out after5seconds; it retained no other DOWN reasons. (2) unchanged-source-read test traced file:pwrite/datasync from quod_signing_journal:persist_mutation, on a Simplex process registered for unrelated e2e:6322. The strict zero-I/O assertion is unchanged. A prior260 campaign saw the same MFAs without attribution; do not retroactively claim this proves that old cause.

Concrete diagnosis for2: e2e tests use foreach setup/cleanup, namespace is started by the test process, unlinked; cleanup executes elsewhere. stop_ns sends exit(Pid,shutdown) then silently returns after5seconds. Supervisors trap exit and ignore a shutdown signal from a non-parent. A deterministic diagnostic starts an actual namespace under a different live parent, invokes the exact existing stop_ns from the observer and measures registered=true, alive_after_stop=true,elapsed5001ms; normal gen_server:stop(Pid,shutdown,5000) then retires it. Propose replace stop_ns with that synchronous existing OTP stop, preserving timeout and surfacing failure. Cover non-parent teardown through actual namespace, verify no named children survive; no production behavior or durability weakening.

Failure1 is still unproven:20 repetitions of unchanged cancellation obligations with improved diagnostic reporting all passed. Proposed test-only diagnostic retains strict killed assertion but captures any alternative DOWN reason and worker/socket/mailbox state when missing. Next run full physics module to look for order dependence, then whole clean sequential release gates after corrected test cleanup. Do not lengthen deadlines, accept normal exits blindly, filter the I/O assertion, change physics permissions or claim the first failure explained. Does source reveal a more precise cancellation defect or necessary deterministic synchronization? Review blockers versus optional suggestions clearly. Assess whether planned scoped test correction and explicit residual record are adequate, and identify minimal further evidence required.
'''
parts=[intro];manifest={}
files=[('AGENTS.md',1,111),('test/quod_e2e_tests.erl',1,175),('src/quod_ns.erl',1,90),('test/quod_physics_tests.erl',1655,1690),('test/quod_physics_tests.erl',1933,1997),('test/quod_agent_hosting_tests.erl',1,33),('src/quod_client_simulation.erl',40,90),('src/quod_client_simulation.erl',350,382),('src/quod_client_simulation.erl',480,525),('src/quod_process.erl',1,200),('test/quod_lobby_tests.erl',708,752),('test/quod_lobby_tests.erl',1090,1104)]
for name,lo,hi in files:
 data=(r/name).read_bytes();manifest[name]=hashlib.sha256(data).hexdigest();parts+=['\n=== '+name+':'+str(lo)+'-'+str(hi)+' ===\n','\n'.join(data.decode().splitlines()[lo-1:hi])+'\n']
for name in ['foreign-stop.log','foreign-stop.json','opening-cancellation.log','opening-cancellation.json']:
 p=r/'_build/quod27-release-261/diagnostics-01'/name;parts+=['\n=== SYNTHETIC '+name+' ===\n',p.read_text()]
packet=''.join(parts).encode();(b/'review-request.txt').write_bytes(packet)
(b/'source-manifest.json').write_text(json.dumps(manifest,indent=2))
(b/'payload.json').write_text(json.dumps({'sha256':hashlib.sha256(packet).hexdigest(),'bytes':len(packet),'scope':'Test fixture teardown and cancellation diagnostic plan; fixed public-source excerpts and synthetic test logs only'},indent=2))
shutil.copy2(r/'_build/quod27-floor-slide-implementation-review-01/run-review.py',b/'run-review.py')
print(json.dumps({'bytes':len(packet),'sha256':hashlib.sha256(packet).hexdigest()}))

from pathlib import Path
import hashlib,json,shutil,subprocess
r=Path('/home/yan/src/quod');b=r/'_build/quod27-release261-test-implementation-review-01'
focused=r/'_build/quod27-release-261/diagnostics-06'
result=json.loads((focused/'result.json').read_text());assert result['exit']==0
b.mkdir()
intro='''Yan explicitly requested Claude Fable plan and implementation reviews for QUD.27. Review this implemented test-only correction. Tools/hooks disabled; only bounded repository source and synthetic fixture evidence. Advice is consultative. Native floor-slide correction already reviewed separately; this packet concerns release-test reliability, not new production behavior.

Gate03 stopped at two EUnit failures: (1) a cancellation monitor did not match DOWN killed within five seconds, with no alternative reason retained; (2) the strict unchanged-source zero-I/O assertion captured actual signing-journal writes from a Simplex owner named e2e:6322. Deterministic non-parent teardown reproduction measured old e2e stop helper returning after5001ms with namespace still alive/registered. Regression failed with old helper, passed after existing OTP gen_server:stop replacement. Your plan review accepted that diagnosis and requested an audit, child death checks and cancellation diagnostics.

Audit: create-root has the identical foreach/test-body startup and foreign cleanup pattern. Its original module passes8 tests while two namespaces survive; captured using documented gproc:select and explicitly stopped afterward. A preceding audit used the wrong raw ETS tuple shape, returned an invalid empty inventory and exited1; it is retained and explicitly invalidated. The earlier scratch fixed-e2e empty-inventory report has no retained query expression and is not relied on as registry evidence. The present focused run uses correct gproc:select, plus production-test-helper monitors every supervisor/child. All other searched shutdown helpers use parent-owned startup/cleanup and/or fail loudly, including agent_hosting stop_ontology. No demonstrated leak there is claimed or patched. Gate03 has no unexpected-message log: OTP28 supervisor handle_info EXIT routes to restart_child, whose unknown-PID branch returns unchanged state without logging. Thus your plan's predicted log line does not occur; retained process attribution and deterministic reproduction support the diagnosis directly.

Implemented: replace two copies of stop_ns with a shared quod_ct:stop_ns helper using synchronous existing OTP stop, preserving5000ms and monitoring all direct owners under one absolute deadline. E2E adds a real namespace regression with a live different parent. Existing I/O assertion unchanged/unfiltered; no sleeps or masking. Cancellation test now records alternative DOWN reasons while still requiring killed, retains the actual proof PID and checks its death, and dumps worker/proof/socket process state plus mailbox/current socket state only on timeout. The original cancellation failure is UNEXPLAINED. Passing focused/module tests cannot establish its cause. Full fresh clean sequential gates must pass before deployment; no deadlines, authorization or production semantics changed for the tests.

Please review exact implementation for correctness, teardown races, unnecessary abstractions or weakened obligations. Give blockers separately from optional observations. Does it satisfy the plan requirements while retaining the unexplained-cancellation record? Do not infer release-gate success from these focused results.
'''
parts=[intro];manifest={}
for name,lo,hi in [('AGENTS.md',1,111),('test/quod_ct.erl',700,735),('test/quod_e2e_tests.erl',1,116),('test/quod_create_root_tests.erl',1,97),('test/quod_agent_hosting_tests.erl',1430,1540),('test/quod_physics_tests.erl',1655,1708),('test/quod_physics_tests.erl',1970,2010),('src/quod_ns.erl',1,66),('src/quod_client_simulation.erl',68,88),('src/quod_client_simulation.erl',485,515)]:
 data=(r/name).read_bytes();manifest[name]=hashlib.sha256(data).hexdigest()
 parts+=['\n=== '+name+':'+str(lo)+'-'+str(hi)+' ===\n','\n'.join(data.decode().splitlines()[lo-1:hi])+'\n']
diff=subprocess.check_output(['git','diff','--','test/quod_ct.erl','test/quod_e2e_tests.erl','test/quod_create_root_tests.erl','test/quod_physics_tests.erl'],cwd=r,text=True)
parts+=['\n=== EXACT TEST PATCH ===\n',diff,'\n=== FOCUSED RESULT ===\n',json.dumps(result,indent=2)]
log=(focused/'focused.log').read_text();parts+=['\n=== FOCUSED TEST END ===\n','\n'.join(log.splitlines()[-12:])+'\n']
for name in ['diagnostics-01/foreign-stop.json','diagnostics-02/before-fix.log','diagnostics-05/result.json']:
 p=r/'_build/quod27-release-261'/name
 parts+=['\n=== '+name+' ===\n',p.read_text()]
packet=''.join(parts).encode();(b/'review-request.txt').write_bytes(packet)
(b/'source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
(b/'payload.json').write_text(json.dumps({'sha256':hashlib.sha256(packet).hexdigest(),'bytes':len(packet),'scope':'Test-only cleanup correction and cancellation diagnostics; bounded public source and synthetic fixture evidence'},indent=2)+'\n')
shutil.copy2(r/'_build/quod27-floor-slide-implementation-review-01/run-review.py',b/'run-review.py')
print(json.dumps({'bytes':len(packet),'sha256':hashlib.sha256(packet).hexdigest()}))

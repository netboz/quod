from pathlib import Path
import hashlib,json,subprocess
root=Path('/home/yan/src/quod'); base=Path(__file__).resolve().parent
assert json.loads((root/'_build/quod27-renewal-tests-03/physics-exit.json').read_text())['exit_code']==0
assert json.loads((root/'_build/quod27-renewal-tests-02/client-exit.json').read_text())['exit_code']==0
pieces=['''Review this implementation as Claude Fable. Yan explicitly requested review of both the plan and implementation. You reviewed the plan; this is the separate implementation review. No tools are enabled. Do not edit, deploy, run commands, or claim runtime testing. Return a clear GO/NO-GO with concrete current blockers, file/line references, and smallest owner-preserving fixes. Distinguish blockers from suggestions and already covered obligations. Check against repository architecture rather than automatically enforcing earlier advice.

Problem: signed normal desktop view expires every 30 seconds. The real 261-07 recording held forward through expiry; RAF remained near 60fps while horizontal movement stopped ~517ms. The expiry-to-replacement projection gap was ~302ms. This establishes a renewal-correlated pause, not every observed micro-cut. Preserve generic physics: no lobby special case, backward compatibility, new broker, second control owner or new domain engine. Native geometry/floor fix already shipped separately. The user is gaming; no new desktop input or acceptance run is authorized until coordinated.

Review the current replacement watch/3 and signed-open renewal path. Old view expiry stays armed while one existing proof worker handles the candidate. Exact request scope includes session, signing principal, actor, world and full goal. Exact local and foreign dependency triples and owner incarnations must remain current. Equal dependencies retain follows and monitors, with a fresh asynchronous local snapshot. Native watch replacement requires same calling socket, previous reference and full physical selection; it changes delivery reference/registration/credit without resetting admitted input sequences or original deadlines. The socket is the sole owner of view expiry. Failed candidates stop the view conservatively, rather than adding another error/availability protocol. Browser sequence, command epoch and pending discrete obligations survive successful renewal; failed/uncertain commands still stop normally. Existing controlled navigation keeps held keys and camera calibration on the same binding.

Focus on stale results, cancellation, expiry before/during attachment, unknown local call outcomes, revocation, owner/geometry changes, credit, registration/sequence races, retained remote follows, cleanup and repeated-work cost. Is any new state unnecessary? Are any old APIs/callers left? Do the tests establish the claimed boundaries? Review the exact code, not just the narrative.

Current evidence: 134 client tests passed and the latest physics/control modules passed (see receipt and terminal count below). Includes two ordinary world identities, disabled/nonphysical/active renewals, native moving input continuity and original deadline/sequence, wrong caller/ref/fence, old ack/detach fencing, actual cancellation/expiry/revocation, in-flight uncertain/refused discrete commands, late digest fencing, exact subscription retention and zero traced storage/history/native install calls for unchanged renewals. The foreign dependency regression enters at the trusted proof-completion seam using the real certified foreign-log progress owner; it does not claim a new signed remote end-to-end acceptance. An earlier run exposed invalid-deadline cleanup before subscription creation; fixed by existing timer/subscription lifetime. The foreign regression then demonstrated refresh/durable_gap before the local+foreign dependency comparison correction. Logs/STOP markers retained, including two rejected fixture/setup attempts. Full clean release gates and a real desktop renewal recording remain outstanding. No release/deployment success is claimed here.
''']
hashes={}
def source(name,spans=None):
    data=(root/name).read_bytes();hashes[name]=hashlib.sha256(data).hexdigest()
    rows=data.decode().splitlines()
    if spans is None: spans=[(1,len(rows))]
    for start,end in spans:
        pieces.append('\n### '+name+':'+str(start)+'\n'+ '\n'.join(f'{i+1}: {rows[i]}' for i in range(start-1,min(end,len(rows)))))
source('AGENTS.md')
source('doc/evidence/governed-physics-implementation-20261010/renewal-plan-resolution.md')
source('src/quod_client_simulation.erl')
source('src/quod_physics.erl')
source('client/src/simulation.js')
source('client/src/controlled-navigation.js')
source('client/src/signed-client.js')
source('ui/src/World.tsx',[(100,185)])
source('doc/physics-native.md',[(646,764)])
source('client/test/simulation.test.js')
source('client/test/controlled-navigation.test.js')
rows=(root/'test/quod_physics_tests.erl').read_text().splitlines()
spans=[]
for start,end in [('install_test_control(', 'grounded_reinstall_and_wedge_settling_test_'),
                  ('renewed_control_preserves_input_and_fences_registration_test_', 'navigation_dependencies_fence_view_test_'),
                  ('opening_worker_cancellation_test_', 'assert_view_selection('),
                  ('signed_client_view_lifecycle_test_', 'with_world(Fun)'),
                  ('assert_no_physics_io(', 'same_host_restart_and_runtime_retirement_test_')]:
    a=next(i for i,s in enumerate(rows) if s.startswith(start));b=next(i for i in range(a+1,len(rows)) if rows[i].startswith(end));spans.append((a+1,b))
source('test/quod_physics_tests.erl',spans)
source('src/quod_client_result.erl',[(425,443)])
paths=['client/src/simulation.js','client/test/simulation.test.js','client/test/controlled-navigation.test.js',
       'src/quod_client_simulation.erl','src/quod_physics.erl','test/quod_physics_tests.erl','doc/physics-native.md']
pieces.append('\n### Exact diff against HEAD\n'+subprocess.check_output(['git','diff','--']+paths,cwd=root,text=True))
for name in ['_build/quod27-renewal-tests-02/client-exit.json','_build/quod27-renewal-tests-03/physics-exit.json']:
    pieces.append('\n### '+name+'\n'+(root/name).read_text())
pieces.append('\n### Physics test terminal count\n'+(root/'_build/quod27-renewal-tests-03/physics.log').read_text(errors='replace')[-180:])
packet='\n'.join(pieces).encode();(base/'review-request.txt').write_bytes(packet)
(base/'source-hashes.json').write_text(json.dumps(hashes,indent=2)+'\n')
metadata={'scope':'QUD.27 signed normal view renewal implementation review','sha256':hashlib.sha256(packet).hexdigest(),'bytes':len(packet),'sources':len(hashes)}
(base/'payload.json').write_text(json.dumps(metadata,indent=2)+'\n');print(json.dumps(metadata))

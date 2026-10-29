#!/usr/bin/env python3
"""Write the R1 handoff only after actual clean qualification and input checks."""
import hashlib
import json
from pathlib import Path
import re
import subprocess

evidence = Path(__file__).resolve().parent
root = evidence.parents[2]
label = 'gates01'
boundary = '/home/yan/.cache/quod-m3a-artifacts/quod-godot-m3a-r1-handoff-8d55a3f3-20261029-01'
gates = json.loads((evidence/(label+'-result.json')).read_text())
assert gates['all_true_exits_zero'] and gates['source_unchanged'] and not gates['unrun']
assert not gates['explicitly_stopped'] and len(gates['results']) == 6
inputs = json.loads((evidence/'inputs'/f'{label}-source-manifest.json').read_text())
compiled = json.loads((evidence/'inputs'/f'{label}-compiled-manifest.json').read_text())
scope = json.loads((evidence/'scope-delta-r1.json').read_text())
for name, row in scope['files'].items():
    assert hashlib.sha256((root/name).read_bytes()).hexdigest() == row['after_sha256']
counts = {}
for gate in ['native','eunit','ct']:
    text = (evidence/'logs'/f'{label}-{gate}.log').read_text(errors='replace')
    pattern = r'test result: ok\. ([1-9][0-9]*) passed; 0 failed' if gate == 'native' else r'All ([0-9]+) tests passed'
    counts[gate] = int(re.findall(pattern,text)[-1])
assert counts == {'native':56,'eunit':4266,'ct':149}, counts
cases = {}
for kind in ['export','member']:
    row = json.loads((evidence/f'{label}-frame-{kind}-acceptance.json').read_text())
    assert row['independent_native_before'] == row['independent_native_after']
    assert not row['unchanged_failed_work']['calls'] and not row['unchanged_recovered_work']['calls']
    for key in ['notification_recovery','affected_signed_control_refused','old_registration_refused',
                'fresh_signed_control_recovered','independent_native_identity_preserved']:
        assert row[key], (kind,key)
    cases[kind] = row
route = json.loads((evidence/f'{label}-same-agent-route.json').read_text())
assert route['final_assignment_revision'] == 11
assert route['original_outcome_after_owner_restart'] and route['exact_state_after_owner_restart']
reused = json.loads((evidence/'inputs'/f'{label}-reused-inputs.json').read_text())
assert reused['client_authored_inputs_verified'] == 59 and reused['cargo_archives_verified'] == 65
assert reused['unpacked_native_authored_sources_verified'] == 3555
providers = {p.name:len(json.loads(p.read_text())) for p in (evidence/'inputs').glob('*-objects.json')}
head = subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
branch = subprocess.check_output(['git','branch','--show-current'],cwd=root,text=True).strip()
assert head == '69196a36caeeb06e6ee07982f1ab1988d7c16b43' and branch == 'worktree/pearl-stone'
qualification = dict(schema='m3a-r1-server-correction-v1',head=head,branch=branch,
    worker_session='8d55a3f3-e558-46e2-afbb-2e028558f371',model='openai-codex:gpt-6.1-sol',
    requested_effort='xhigh',effective_effort='Not exposed by installed API',
    clean_sequential_gates=counts|{'xref':True,'dialyzer':True,'local_release':True},
    true_child_exits=[r['child_exit'] for r in gates['results']],source_unchanged=True,
    explicit_completion=True,compiled_input_reused=False,frame_failure_cases=list(cases),
    authored_server_inputs=len(inputs['files']),compiled_counts=compiled['counts'],
    provider_originals=sum(providers.values()),provider_sets=providers,reused_inputs=reused,
    original_route_revision=11,snapshot_path=boundary,committed=False,m3b_complete=False,
    shared_tracker_body_publication_confirmed=False,tracker_body_write_attempted=False)

handoff = f'''# M3a-R1 result

The retained-frame isolation defect is corrected and server qualification passed.
The implementation remains uncommitted and in review under [QUO-64](nimbalyst://QUO-64).
Full M3/M3b and broader Stage 2/D5/D6/D7 remain open.

Yan directly authorized this existing writer to fix the defect. Root and coordinator
were idle and no other M3 implementation session existed before edits. Root
922c7c06-1acb-4c2b-9141-fccf4ab4c947 retains serial launch ownership. No new writer,
Claude consultation or M3b launch occurred.

Actual session 8d55a3f3-e558-46e2-afbb-2e028558f371 runs openai-codex:gpt-6.1-sol.
The existing launcher requested xhigh; effective runtime effort is not exposed
by the installed API. No model/effort switch was attempted. Branch {branch};
HEAD {head}, parent d027f9f65bbce2f484f906c92bf07ebaa4669c38; original branch base
f6c29fe925e666dd68ee7fa68c0e03f5d03391a2. No reset, stash, checkout, commit,
push, deployment, app restart or existing-network change occurred.

## Correction and causal proof

One existing selector now returns explicit results to body/frame consumers.
Expected geometry, delegation and exact frame member/export failures become
world-local unavailable results. The existing fold still installs healthy worlds.
Unexpected evaluator faults retain their original class/reason/stack at the
existing owner boundary. All missing/read observations, retained foreign readers,
incarnation/source fences, absolute deadlines and disposal checks remain.

An affected local edit may advance the runtime's existing navigation guards.
Healthy worlds refresh those guards using the same native resources. There is
no static pose fallback, frame-specific exception, second selector/domain/KB,
new policy budget or permission bypass. Reason-bearing physical reconciliation
uses the existing physics_materialization result after healthy rows install;
the two existing negative geometry tests now assert their exact failure reason.

The original frozen runtime was rebuilt cleanly with the new real-owner regression.
Both signed local export removal (retaining the member) and required-member removal
reproduced the independent world's unavailable snapshot. That failed attempt is
retained as preflight01-original. After correction, both cases preserve the
independent PID/spec/body state and native incarnation; install/step/tick counts
stay 1/1/1 through failure and repair. Affected snapshots and signed controls
refuse. A real committed repair restores the affected world through notification;
the retired registration stays refused and a fresh signed control works.
Three unchanged failed and three recovered repeats have zero watched
reader/history/native-install/ledger/write/sync calls in each case.

## Source quality and exact scope

R1 changes three existing files: [quod_runtime.erl](/home/yan/src/quod_worktrees/pearl-stone/src/quod_runtime.erl) (+42/-22, net+20 production),
[quod_physics_tests.erl](/home/yan/src/quod_worktrees/pearl-stone/test/quod_physics_tests.erl) (+119/-17, net+102 tests), and [physics-native.md](/home/yan/src/quod_worktrees/pearl-stone/doc/physics-native.md)
(+6/-1, net+5 specification). There are no new active production files or R1
production relocations. All 20,749 original source entries were checked; every
other original source/evidence byte is preserved. The initial boundary and
review/coordination additions remain unchanged.

Accumulated production against HEAD is +1,246/-551, net+695 physical lines,
including all three M3a new production files. Tests net+874, specifications+174;
the original five archived lines and 356 relocated existing framework lines are
reported separately, with relocation already included in active counts. R1 growth
supplies the shared result/failure boundary. No further concrete quality defect
was identified in this bounded inspection. See [source-quality.md](/home/yan/src/quod_worktrees/pearl-stone/doc/evidence/godot-m3a-r1-20261029/source-quality.md) and both scope
manifests for exact hashes, caller reasoning and unresolved broader scope.

## Qualification and retained failures

Focused final preflight04 passed all8 cases. Full clean gates01 passed sequentially:
native56, EUnit4266, CT149, xref, Dialyzer and local release, all actual child0,
explicit completion, no timeout/stop and unchanged frozen source. The local
builder is sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55,
with OTP28.5.0.2/rebar3.26/Rust1.90.0. Its image ID is not a published digest.
The production release is assembled locally, not deployed.

Current founding/HTTPS/privacy/GUI/source/creation/physics journeys ran in full
EUnit. The original same A route reaches revision11 and preserves original Enter
outcome/exact state after owner restart. Shared component/projection/root appearance,
geometry revocation/stale-install and physical startup fixtures remain covered.
The new receipts contain actual owner processing/work, not a latency inference.

All four focused input variants, complete logs, true exits, provider objects and
failed fixture stores are retained. Preflight02 exposed two invalid test snapshot
requests and an old silent-ok expectation; preflight03 passed293/failed3 while
exposing the required registration renewal and the other geometry expectation.
Final tests preserve those guards and strengthen the requests/assertions. The
evidence-only rejected reconstruction attempt is also retained; its corrected
verification runs outside any checkout. No assertions, workload, caps, deadlines
or timeouts were weakened. See [failure-dispositions.md](/home/yan/src/quod_worktrees/pearl-stone/doc/evidence/godot-m3a-r1-20261029/failure-dispositions.md).

## Snapshot and remaining boundary

Snapshot path: {boundary}. Consult snapshot.json for actual hashes and the
content/reconstruction receipts. The source/base/binary patch/full-untracked
payloads and actual dependency/package/toolchain/provider/output contents are
retained. A separate verifier materializes the complete source outside every
checkout and verifies the exact path set, bytes, symlinks, executable bits and
recorded modes. Earlier immutable M3a artifacts are retained as actual read-only
predecessor bytes, never silently amended.

The clean input has {len(inputs['files'])} authored server/spec files and1094
dependency inputs; generated parser sources and Rebar/PLT outputs are distinct.
All65 Cargo archives/3555 unpacked authored sources and59 unchanged client inputs
were checked. Eight reused client/crypto/toolchain archive hashes are verified.
Actual final compiled outputs, entire local release and {sum(providers.values())}
R1 provider originals are indexed separately. Raw/private fixture data and
credentials stay outside public snapshots; sanitized full CT text is retained.

Native Godot entry/rendering/navigation/picking and installed reconnect remain
M3b. No interactive XR/Vive/controller, power-cut or non-Linux claim is made.
Unchanged M2 desktop/GPU/crypto evidence retains its documented compatible-host
limits. Framed terrain, independent active-run migration, broader ontology editing
and other Stage2/D5/D6/D7 obligations remain open. The rejected decorative fallback
and second root authoring route were not added.

Tracker metadata remains bounded to the existing server subset: QUO-64 in-review13%,
Stage2 in-review25%, parent50%. Metadata/session evidence is local/receipt-backed;
linkedCount0 is not shared-publication proof. Collaborative body publication remains
blocked by prior automatic approval review; no body retry or workaround occurred.
Original checklist bodies may be stale. No duplicate plan or phase item was created.

Stop at this frozen server correction. Coordinator verification precedes refreshing
M3b's prerequisite; this result does not launch it.
'''
readme = '''# M3a-R1 retained-frame isolation evidence

The correction and all six clean gates are qualified on one unchanged source.
See [the R1 handoff](../../../nimbalyst-local/handoffs/godot-m3a-r1-result.md),
[qualification.json](qualification.json), [source inspection](source-quality.md),
[exact R1 delta](scope-delta-r1.json), [complete HEAD delta](scope-delta-head.json)
and [retained failures](failure-dispositions.md).

The original defect is reproduced in logs/preflight01-original-eunit.log and
the two preflight01-original-frame-*-selection.json receipts. The final
gates01-frame-export-acceptance.json and gates01-frame-member-acceptance.json
prove per-world failure isolation, actual native counters/identity, signed-control
refusal, retired-registration refusal, real notification recovery and zero watched
work on unchanged failed/recovered repeats. preflight04-final passed all8 focused
checks; gates01-native/eunit/ct/xref/dialyzer/release logs and JSON receipts preserve
the six true exits and explicit completion evidence.

gates01-same-agent-route.json, gates01-recursive-projection.json,
gates01-shared-physics.json and gates01-founding.json/HTTPS receipts requalify the
affected existing server journeys. These are portable server receipts; M3b's
installed Godot product and hardware obligations remain open.

inputs/ contains exact authored variants and committed-base reconstruction,
dependency/generated/parser/output/provider manifests, current model metadata,
the preservation audit and unchanged client/package checks. Private raw logs and
fixture stores stay in the isolated /tmp campaign area. The external immutable
snapshot carries actual source and artifact bytes, reconstruction instructions
and independent complete source verification; hashes alone are not the payload.

The original M3a source/evidence/review boundary is preserved. Tracker bodies remain
unpublished/stale under the existing automatic-review rejection; no body write was
retried, and metadata does not claim full M3 or broader Stage2 completion.
'''
outputs = {evidence/'qualification.json':json.dumps(qualification,indent=2)+'\n',
           root/'nimbalyst-local/handoffs/godot-m3a-r1-result.md':handoff,
           evidence/'README.md':readme}
assert not any(p.exists() for p in outputs), 'Retain any previous finalization attempt'
for path, text in outputs.items():
    with path.open('x') as stream:
        stream.write(text)
print(json.dumps({'handoff':str(root/'nimbalyst-local/handoffs/godot-m3a-r1-result.md'),
                  'counts':counts,'provider_originals':sum(providers.values()),'boundary':boundary}))

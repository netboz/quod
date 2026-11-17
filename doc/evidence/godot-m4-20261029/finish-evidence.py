#!/usr/bin/env python3
"""Summarize the exact final receipts; never turn a failed campaign into a pass."""
import hashlib,json,subprocess
from pathlib import Path
root=Path.cwd();evidence=Path(__file__).resolve().parent
def read(path):return json.loads((evidence/path).read_text())
def write(name,value):(evidence/name).write_text(json.dumps(value,indent=2)+'\n')
final=read('final06-result.json');assert final['passed'] and final['source_unchanged']
client=read('inputs/client-candidate09-manifest.json');assert client['passed']
inputs=read('input-final07/client-result.json');scene=read('scene-final07/client-result.json')
physics=read('physics-final08/client-result.json');prefs=read('gui-final06/export-result.json.m4.json')
assert inputs['passed'] and scene['passed'] and physics['passed'] and prefs['passed']
assert not prefs['work']['work']['calls']
for key in ['sources','appearances','Subscriptions','captures']:assert inputs['metrics'][key]==0,key
for key in ['LiveTemplates','LiveLeases']:assert inputs['metrics']['resources'][key]==0,key
receipts={}
for row in final['commands']:
 p=evidence/'logs'/(row['label']+'.json');record=json.loads(p.read_text())
 assert row['child_exit']==record['child_exit']==0 and not record['timed_out'] and not record['error_diagnostics'],row['label']
 receipts[row['label']]=record
head=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip();assert head=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
branch=subprocess.check_output(['git','branch','--show-current'],text=True).strip();assert branch=='worktree/pearl-stone'
paths=set(subprocess.check_output(['git','diff','--name-only','HEAD'],text=True).splitlines())|set(subprocess.check_output(['git','ls-files','--others','--exclude-standard'],text=True).splitlines())
deltas=[]
for n in sorted(paths):
 if not n.startswith(('client/godot/','client/godot-tests/','client/godot-tools/')):continue
 path=root/n;old=subprocess.run(['git','show','HEAD:'+n],capture_output=True).stdout;new=path.read_bytes() if path.is_file() else b''
 category='generated-uid' if n.endswith('.uid') else 'docs' if n.endswith('.md') else 'test' if n.startswith('client/godot-tests/') or '/tests/' in n else 'production'
 deltas.append(dict(path=n,category=category,before_lines=len(old.splitlines()),after_lines=len(new.splitlines()),delta=len(new.splitlines())-len(old.splitlines())))
totals={c:sum(r['delta'] for r in deltas if r['category']==c) for c in sorted(set(r['category'] for r in deltas))}
write('inputs/source-deltas-final.json',dict(files=deltas,totals=totals,relocations=[],server_production_changes=[],prior_evidence_changes=[]))
checks=dict(core=189,injected_engine_and_desktop=len(inputs['checks']),scene=len(scene['checks']),signed_preferences=len(prefs['checks']),native_physics=len(physics['checks']),additional_normal_close_cycles=5)
qualification=dict(checkpoint='QUO-65 / M4',worker_session='ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f',model='openai-codex:gpt-6.1-sol',launcher_requested_effort='max',launcher_returned_effort='max',effective_backend_effort='Not exposed by installed API',head=head,branch=branch,committed=False,client='candidate09',final_campaign='final06',software_campaign_passed=True,full_m4_accepted=False,checks=checks,command_receipts=receipts,client_inputs=len(client['authored_inputs']),input_classes={k:len(v) for k,v in client['input_classes'].items()},client_exports=len(client['export_outputs']),dependency_archives=client['dependency_archives'],engine_archives=client['engine_archives'],resource_metrics=inputs['metrics'],unchanged_signed_preference_work=prefs['work'],production_test_doc_deltas=totals,server_inputs_unchanged=1432,unchanged_server_gates_reused='M3b committed gates01: native56 EUnit4266 CT149 xref Dialyzer local release',native_runtime='Blocked before client launch: installed Monado exits127 for absent OpenCV4.13 ABI libraries',physical_vive='Unrun: headset pixels, real tracking, two-wand gestures, comfort and platform exit require observations',quest='Outside M4 / unrun',retained_exit_limitation='gui-final03-backup-import and physics-final06 hung after assertions and were killed by unchanged watchdogs. Fresh unchanged-binary reproductions passed, without resolving their native cause. Do not infer a teardown fix.',body_publication=False,parent_m4_credit=False)
write('qualification.json',qualification)
acceptance=[
 dict(id=1,scope='Signed mapping, strict profiles/components, explicit roles/choices and one adapter contract',result='Software qualified',evidence=['input-final07/client-result.json','gui-final06/export-result.json.m4.json']),
 dict(id=2,scope='Desktop/pointing/generic GUI and fenced private preferences including invalid-row repair',result='Software qualified; unchanged policy/privacy obligations also reuse committed server evidence',evidence=['gui-final06','gui-final06-backup-import','spaces-final06','navigation-final06']),
 dict(id=3,scope='Lifecycle, neutral rearm, source identity, cancellation and pointer/travel/menu arbitration',result='Injected real engine and actual desktop qualified; physical behavior unrun',evidence=['input-final07/client-result.json']),
 dict(id=4,scope='Current signed movement association, native snap/teleport, sequences/truncation/fences/uncertainty',result='Real signed native owner qualified with injected controller frames; no physical claim',evidence=['physics-final08','navigation-final06']),
 dict(id=5,scope='Licensed class-selected representation and retained resources',result='Real asset transfer/admission/decode and unchanged work qualified',evidence=['input-final07','gui-final06/export-result.json.m4.json']),
 dict(id=6,scope='OpenXR native start/stop, teardown and hardware',result='Partial: injected lifecycles and normal desktop closes qualified; installed runtime blocked; retained native process-exit stalls unresolved; hardware unrun',evidence=['native-xr-development01','inputs/native-discovery.json','engine-ownership.md','failure-dispositions.md'])]
write('acceptance.json',acceptance)
(evidence/'source-quality.md').write_text(f'''# M4 source and qualification boundary

HEAD `{head}`, branch `{branch}`. The index is unchanged and no commit was
created. The original branch base f6c29fe9 is provenance; M4 starts at the
committed M3b HEAD293cf6115. The old M3b patch is never applied over it.

Current client deltas: production **{totals['production']:+}** lines, tests
**{totals['test']:+}**, client documentation **{totals['docs']:+}**, and
**{totals['generated-uid']:+}** newly generated UID lines. Detailed per-file
before/after counts are in inputs/source-deltas-final.json. Erlang/Prolog
production changes and relocations are zero. No previous evidence was rewritten.

Growth supplies the previously absent native mapping interpreter, static GLB
admission, retained model owner, platform adapter and shared GUI surface. It
does not add a domain engine, broker, hardware ledger, executor or physical
simulation. The former root GUI routing and mouse-up-only picker were replaced
in the shared consumers. The unbound jump prototype was removed; existing
native jump guarantees retain their committed physics coverage. Broad browser/
ontology retirement remains M5.

All {len(client['authored_inputs'])} supplied client inputs are individually
hashed. The legacy authored_inputs map includes generated UID seeds;
input_classes separates {len(client['input_classes']['client_source'])} client
source files, {len(client['input_classes']['generated_uid_seeds'])} persistent
engine-generated UID seeds and {len(client['input_classes']['protocol_model_provider_fixtures'])}
protocol/model/provider fixtures. No compiled Quod input entered the clean
build. Eight exact package archives and pinned Godot engine/template archives
were cold restored and verified, including signed-package content hashes.
The complete self-contained Linux export has {len(client['export_outputs'])}
entries, including the pinned model MIT notice.

The final campaign uses one unchanged candidate09 tree. Its full commands,
sanitized logs, explicit completion and true exits are separate from failed
development/final labels. All 1,432 unchanged server inputs and the 31 inherited
generated .agents files plus coordinator prompt were checked against their
recorded hashes/modes. The six already accepted server gates are reused,
without an unchanged server rerun. Full output/provider objects and original
helper/driver sources are frozen separately from source inputs and private data.

The immutable handoff includes an actual HEAD archive, binary tracked patch,
complete untracked contents and a complete independent reconstruction outside
every checkout, checking paths, bytes, symlinks, executable bits and full modes.
Read-only M3b predecessor bytes share dependency/toolchain and unchanged server
output archives by hardlink. Hashes alone are not the source boundary.

Native runtime/hardware and the retained intermittent native exit issue remain
explicit limitations. A later successful process does not erase an earlier hang.
''')
print(json.dumps(dict(checks=checks,deltas=totals,commands=len(receipts),client_inputs=len(client['authored_inputs']),exports=len(client['export_outputs']))))
boundary='/home/yan/.cache/quod-m4-artifacts/quod-godot-m4-handoff-ca84d4f8-20261029-01'
(evidence/'README.md').write_text(f'''# Godot M4 qualification — final06

The clean desktop/controller adapter software is implemented and uncommitted.
The final frozen candidate09 passed its source-only build/core checks and
{len(receipts)} sequential exported campaigns. M4 remains partial/in-review:
the installed OpenXR runtime cannot load, physical acceptance is unrun, and two
earlier intermittent native process-exit stalls remain unresolved.

[Worker handoff](../../../nimbalyst-local/handoffs/godot-m4-result.md)

[Qualification and actual command/exit receipts](qualification.json)

[Scoped acceptance mapping](acceptance.json)

[Source/input/output discipline and exact deltas](source-quality.md)

[All failure dispositions and unrun cases](failure-dispositions.md)

[Pinned engine ownership analysis](engine-ownership.md)

Core {checks['core']}; injected XRServer/native GUI/desktop controller
{checks['injected_engine_and_desktop']}; GPU scene {checks['scene']}; real signed
preference integration {checks['signed_preferences']}; native physics
{checks['native_physics']}; five additional normal-close crypto cycles.
GUI, selected-storage, complete navigation/unknown-barrier and mapped native
physics campaigns use one unchanged source tree. Actual intended SIGKILL
children remain -9 at observed seams; all final campaign/normal children exit0
with completion markers, no runner timeout and no engine error diagnostics.

The 1,432 unchanged server inputs reuse the committed M3b sequential gates:
native56 / EUnit4266 / CT149 / xref / Dialyzer / local release. M4 changes no
server/foundation production source, and does not repeat those suites.

Model/effort: current worker API reports openai-codex:gpt-6.1-sol. The actual
launcher request and returned effortLevel are max. Effective backend effort is
not exposed. No model switch, consultation or delegated writer was used.

The immutable external boundary is `{boundary}`. Its actual HEAD archive,
binary patch, full untracked contents, output/provider archives, shared actual
dependency/toolchain bytes and complete independent reconstruction are separate
from the live checkout. snapshot.json is the artifact index. The source includes
31 preexisting generated .agents files and the coordinator prompt, unchanged.
Private stores, credentials and raw secret-bearing logs remain outside it.

The tracker body is stale and was not retried/published. Metadata-only status
and exact acceptance receipts do not imply shared body publication or visible
session attribution. Parent M4 credit and next-ticket decisions remain with
the coordinator behind this actual partial acceptance boundary.
''')
handoff=root/'nimbalyst-local/handoffs/godot-m4-result.md'
handoff.write_text(f'''# Godot M4 result — software review boundary, hardware/native limits retained

Implemented, uncommitted, for [QUO-65](nimbalyst://QUO-65). The final candidate09 /
final06 source-only build and software campaign passed. Full M4 acceptance is
not claimed. Native OpenXR availability, retained process-exit uncertainty and
physical Vive participation remain external/unresolved qualification limits.

## Identity, authority and source

Sole writer/current worker `ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f`.
API model `openai-codex:gpt-6.1-sol`; actual launcher requested and returned
`effortLevel=max`. Effective backend effort is unexposed. The own-session
summary and launch receipts are retained; prompt text did not change a model.
No consultation, delegated writer or demonstrated requirement to exceed
Sol/max was used.

Branch `{branch}`, starting/current HEAD `{head}`, parent
`f716ddf5e578df957a5b18421a0727a32c634f87`. Original base
`f6c29fe925e666dd68ee7fa68c0e03f5d03391a2` is provenance. No branch/worktree
reset/switch/create, commit, push, deployment, network cutover, main-checkout
change, Nimbalyst rebuild/restart or general data cleanup occurred. The index
remains empty. All 31 preexisting generated .agents files and the coordinator
prompt match their initial bytes/modes. Historical M3b precommit labels remain
unchanged; coordinator acceptance and commit293cf6115 supersede those labels.

## Implementation and acceptance

The existing Prolog controller foundation supplies roles, descriptions,
defaults/overrides, validation, signed mapping and licensed class appearance.
Private preferences stay with U and durable operations retain U→A, exact
revision/value/digest fences, existing transactions/recovery and uncertainty.
Live trackers, poses and source choices remain session-only.

One source-scoped interpreter feeds the existing Godot scene picker, native GUI
controls and signed PhysicsInput owner. It visibly refuses unknown profiles,
facilities, mappings and unsupported tracking. It does not create a body/grant,
change principal, guess buttons/hands or introduce a fallback movement lane.
Desktop and XR share one native Control tree; source choices use the existing
local presentation path. Generic reader availability is advisory to the real
executing personal agent, preserving the binder and uncertainty fences.

Focus/visibility and current identity changes cancel before dispatch. Neutral
rearm, competing sources, menu/trigger overlap, same-frame travel suppression,
stale poses/frames, source loss, late components and disposal are exercised.
Tracker notices reconcile against Godot's installed identity after its callback;
duplicates retain resources and captures. Native resource invalidation is
explicitly unavailable. Resource retirement completes before observer notices.
Current camera transforms drive the existing selected, fenced native lane.
Mapped snap/teleport retain native support/path/collision and feedback authority;
the experimental unbound jump API was removed, with native obligations retained
in the unchanged committed physics tests.

Verified static GLB bytes/templates are shared, actual source appearances are
independent, and invalidated authorization hides inert resources for their real
source lifetime. Reauthorization of the same appearance does no reacquisition,
decode or node/texture work. Source/session removal releases them. The pinned
model's MIT notice and declared costs are preserved in the complete export.

The detailed six-part [acceptance map](../../doc/evidence/godot-m4-20261029/acceptance.json)
separates software, injected frames, native runtime discovery and physical cases.

## Qualification and costs

Pinned Godot4.7.2, SDK10.0.112, runtime10.0.12 and BouncyCastle2.7.0.
{len(client['authored_inputs'])} supplied client inputs are split into authored
client source, persistent generated UID seeds and protocol/model/provider
fixtures. Eight exact package archives and exact engine/template archives were
verified; no compiled Quod input entered the clean build. The actual export
has {len(client['export_outputs'])} entries. Full build commands, package/content
hashes and outputs are retained.

Core **{checks['core']}**, injected/desktop controller **{checks['injected_engine_and_desktop']}**,
GPU scene **{checks['scene']}**, live signed preference **{checks['signed_preferences']}**,
native physics **{checks['native_physics']}**, plus **five** actual normal-close
crypto cycles. All {len(receipts)} final sequential campaign commands returned
true child0, explicit completion, no runner timeout and no engine errors on the
same unchanged candidate09 source. Original lost Save/Reset/creation/Enter/Leave
replies, observed SIGKILL seams, fresh-device backup, selected storage,
unplaced recovery, recursive appearances, full native position/quaternion
agreement, contact, revocation/repair, independent-world isolation and the
unknown-association barrier retain their actual journeys.

Unchanged signed preference renewals observed **zero** watched history/reader/
install/write/sync calls and zero acquisition/decode/node/texture/release work.
The injected render lifetime measured two acquisitions/two releases, one decode,
two instances/two releases, 114 built nodes and one decoded texture; all final
sources, subscriptions, captures, appearances, templates and leases are zero.
The real invalid-row notification/ordinary Reset retains its original signed
subscription and unchanged model resources. These measurements establish their
specific software seams, not physical headset behavior.

All 1,432 server/foundation inputs match accepted M3b bytes. Reused gates are
native56, EUnit4266, CT149, xref, Dialyzer and local release, qualified sequentially
at the unchanged source. A client correction did not trigger an unchanged server
campaign. Earlier [M3b coordinator evidence](godot-m3b-coordinator-verification.md)
and its corrected hash-only-index verifier run remain separate provenance.

Net deltas: production **{totals['production']:+}** lines, tests **{totals['test']:+}**,
client docs **{totals['docs']:+}**, generated UID lines **{totals['generated-uid']:+}**.
Erlang/Prolog production changes and relocations: **zero**. Growth supplies the
new platform interpreter/admission/resource/GUI adapters; it does not hide code,
delete valid coverage or retain another domain executor. Broad retirement is M5.
Per-file counts are in [source quality](../../doc/evidence/godot-m4-20261029/source-quality.md).

## Retained failures and unrun obligations

Installed Monado exits127 before session/client startup: OpenCV4.13 imgcodecs,
video, calib3d, features2d, imgproc and core libraries are absent; available
OpenCV5.0 libraries have another ABI. Vive USB components/dongles were observed,
which establishes neither live OpenXR devices nor pixels/poses/gestures. No
user runtime/config/socket/display-session change or ABI substitute was made.

Native session/swapchain/input-profile RID teardown, QUO-27 SESSION_NOT_STOPPING
and spatial-discovery diagnostics remain unqualified. Original Vive/two-wand
pixels, real tracking, gestures, comfort and platform exit need direct physical
observations. Quest and Android-as-headset qualification are unrun/outside M4.
Injected source and engine-resource tests are not physical acceptance.

Two earlier native process-exit stalls remain unresolved:
gui-final03-backup-import after the direct test quit, and physics-final06 after
normal application close. Both completed assertions, then required watchdog
SIGKILL. An unchanged-binary GUI reproduction and six unchanged-binary physics
repetitions passed; that does not identify their native cause or erase them.
The final normal-close evidence is bounded accordingly. Bounded argument-free
native-stack capture is retained for a reproduced stall; no stack was obtained
from those already terminated failures. No claim of a universal teardown fix.

All earlier compiler, viewport/focus/picking, binary-proxy, exact-retract probe,
source ordering/reentrancy/invalidation and storage failures remain separately
labelled in [failure dispositions](../../doc/evidence/godot-m4-20261029/failure-dispositions.md).
The unsupported retractall/proof_unavailable request and its private store were
not cleared or resubmitted. Original M1 negative/question and M3b unclaimed
denial uncertainties remain explicit; HTTP fail plus pending is not rejection.

## Frozen handoff and coordinator boundary

Immutable boundary: `{boundary}`. It contains the actual HEAD base archive,
binary tracked patch, complete untracked payload, every source path/hash/mode,
all source-only client input sets and generated build outputs, complete final
export, actual test-factory/provider objects and inspected pinned engine source.
Actual read-only M3b dependency/toolchain/server outputs are shared by hardlink.
The new base archive SHA256 is
`6993224aab274671a44e7c4a95c0766ddce22769af14657c8db9d02bcf24ef82`.
Do not apply the old M3b patch over the current committed HEAD.

The included verifier independently materializes the complete source outside
every checkout, applies the real binary patch, checks every path/content/
symlink/executable bit and restores/checks full recorded modes. Its receipt
and the artifact index live in the immutable boundary. Credentials, private
stores and raw secret-bearing logs are excluded; public audit limits and
unreadable originals are recorded honestly. Cache storage was used when /tmp
filled; no old snapshot/data was deleted or generally compressed.

The only implementation writer is frozen after the final source manifest; no
correction is pending. Full inbox batches were read. consume_session_inbox is
unavailable, so list_queued_prompts was used without claiming consumption.
The existing tracker remains the status authority; no duplicate item/frontmatter
plan was created, no shared body/description/checklist publication was attempted,
and linkedCount0 is not visible-attribution evidence. Metadata-only final status
receipts are retained. Full M4/parent/Stage2/QUO-59/QUO-27 completion is unclaimed.

Coordinator `ed9cd520-b2a4-4607-a8f5-ff99d08f3e46` owns independent acceptance,
the actual commit and the next-ticket decision. No commit/push/deployment or
next checkpoint was launched. Compatible runtime availability, physical
participation and causal native-exit diagnosis are the precise remaining
dependencies; they must not be hidden to unlock M5.
''')

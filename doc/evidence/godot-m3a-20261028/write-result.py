#!/usr/bin/env python3
"""Write the checkpoint report only from a completed, unchanged clean campaign."""
import hashlib
import json
from pathlib import Path
import re
import sys

evidence=Path(__file__).resolve().parent
root=evidence.parents[2]
campaign,label=sys.argv[1:]
gates=json.loads((evidence/(campaign+'-result.json')).read_text())
assert gates['all_true_exits_zero'] and gates['source_unchanged'] and not gates['unrun']
inputs=json.loads((evidence/'inputs'/(campaign+'-source-manifest.json')).read_text())
compiled=json.loads((evidence/'inputs'/(campaign+'-compiled-manifest.json')).read_text())
delta=json.loads((evidence/('scope-delta-'+campaign+'.json')).read_text())
physics=json.loads((evidence/(campaign+'-shared-physics.json')).read_text())
route=json.loads((evidence/(campaign+'-same-agent-route.json')).read_text())
assert route['final_assignment_revision']==11
assert route['original_outcome_after_owner_restart'] and route['exact_state_after_owner_restart']
assert physics['native_install_counts']==[2,3,4]
assert physics['unrelated_native_installs']==[1,1] and physics['generations']==[1,2]
assert 'signed_nested_body_push' in physics and 'nested_body_rest' in physics
for name,expected in inputs['files'].items():
    assert hashlib.sha256((root/name).read_bytes()).hexdigest()==expected,name
eunit=(evidence/'logs'/(campaign+'-eunit.log')).read_text(errors='replace')
count=re.search(r'All (\d+) tests passed',eunit)
assert count,'Retain the complete EUnit result'
ct=(evidence/'logs'/(campaign+'-ct.log')).read_text(errors='replace')
ct_lines=[s.strip() for s in ct.splitlines() if 'TEST COMPLETE' in s or 'All ' in s and 'passed' in s]
assert ct_lines and any('All 149 tests passed' in s for s in ct_lines),ct_lines
base=json.loads((evidence/'inputs/source-base.json').read_text())
patch=json.loads((evidence/'inputs'/(campaign+'-head.json')).read_text())
metadata=json.loads((evidence/'tracker-metadata-outcomes.json').read_text())
qualification=dict(campaign=campaign,eunit_passes=int(count[1]),ct_results=ct_lines,
    all_gates_true_zero=True,source_unchanged=True,counts=compiled['counts'],
    native_install_counts=physics['native_install_counts'],unrelated_native_installs=physics['unrelated_native_installs'],
    native_generations=physics['generations'],original_A_final_revision=11,
    original_outcome_after_owner_restart=True,source_delta=delta,
    collaborative_body_publication=False,metadata_receipts='tracker-metadata-outcomes.json')
(evidence/'qualification.json').write_text(json.dumps(qualification,indent=2)+'\n')
gate_rows='\n'.join('| '+name+' | '+str(r['child_exit'])+' | '+format(r['elapsed_seconds'],'.2f')+' |'
    for name,r in zip(['native','EUnit','CT','xref','Dialyzer','local release'],gates['results'],strict=True))
boundary='/home/yan/.cache/quod-m3a-artifacts/'+label
production=delta['groups']['production']; tests=delta['groups']['tests']; specs=delta['groups']['specifications']
body=f'''# M3a server checkpoint result

Uncommitted server implementation is in review. This is the M3a checkpoint; full [QUO-64](nimbalyst://QUO-64)/M3 completion remains open. M3b and the deferred Stage 2 obligations remain
open. No commit, push, deployment, existing-network change or Godot product edit
was made. Root `922c7c06-1acb-4c2b-9141-fccf4ab4c947` retains serial launch ownership.

Implementation session: `8d55a3f3-e558-46e2-afbb-2e028558f371`.
Launcher model visibility: `openai-codex:gpt-6.1-sol`; requested effort `xhigh`.
The installed API does not expose effective runtime effort. Prompt text was not
used to switch a running model. The qualified M2 writer was observed idle before
implementation; the read-only Claude Fable consultation changed no files and ran
no commands, builds or tests.

Branch `worktree/pearl-stone`, HEAD `{inputs['head']}`, parent
`d027f9f65bbce2f484f906c92bf07ebaa4669c38`. Original branch base
`f6c29fe925e666dd68ee7fa68c0e03f5d03391a2`. All work stayed in this worktree.
The pre-existing coordination prompt edit and `.agents/` were preserved.
M1/M2 remain accepted at this committed HEAD; historical pre-commit labels are
not current blockers. The accepted M2 external boundary remains unchanged.

## Delivered server subset

- The original personal A travels S0 → S1 → S2 → S1 → S0 through existing signed
  U→A instructions, the ordinary offered GUI binder and committed assignment,
  withdrawal and receiver admission. S2 uses M2's ordinary construction route.
  Leave is genuinely unplaced and return names exact S0; final revision is 11.
  Owner/storage/location/display references stay distinct. Navigation is read
  from committed assignment. Original S0/setup results and A's identity persist.
- Signed stale, denied and checkpoint-conflicting entry leaves no partial move.
  The final foreign receiver refusal rolls back every participating owner. A
  fresh authenticated client resolves the original Enter outcome before and
  after runtime/outcome owner restart; exact spaces/attributes/assignments remain
  equal, with no constructor or reaction replay. Existing generic outcome gates
  retain lost-reply and uncertainty protections.
- Existing recipes/view owners expose recursive exact-subject contents, stable
  complete anchored occurrence paths, selected recipe/revision, source frame,
  permitted subjects and local-to-parent transforms. Placement/display duplicates
  deduplicate; independent appearances remain independent. Solid/wireframe stop
  that occurrence; denied/lost contents is unavailable. Cycles report their exact
  occurrence without suppressing independent branches. Resource refusal is Prolog
  policy. The explicit M2 temporary contents-unavailable recipe is replaced.
- Retained dependencies let the outer space receive C's real source update without
  entering B or C. Permission withdrawal removes source marks rather than showing
  an empty-success scene. Existing source readers/projections and subscriptions
  retain identity/incarnation, deadline, cancellation and stale-notice guards.
- Explicit source delegation and destination physical admission select one
  authoritative existing native world for a continuous component. The root owns
  one body per exact source/assignment; ordinary containment is unchanged.
  Parent-first quaternion/matrix composition converts once to the existing native
  XYZ-radian boundary and preserves integer origin anchors plus residual offsets.
  No Euler component addition, implicit scale, second engine or client collision
  authority is introduced. Independent decorative appearances share the same body
  stream through portable source-frame receipts.
- The native S0/S1/S2 fixture uses asymmetric nonidentity frames, traversal/contact,
  exact source geometry/frame updates, viewer revocation, branch withdrawal,
  stale control refusal and owner restart without duplicate bodies. A separate
  actually installed native run refuses joining and preserves its bodies, PID,
  run/configuration and installation count. Its navigation guard remains owned
  and may advance monotonically with source policy.

Actual repeated-owner trace: zero reader creation/history apply/native install/
ledger open/fold/write/pwrite/sync/datasync calls across unchanged repeats.
Native installation counts for real geometry/frame updates are
`{physics['native_install_counts']}`; unrelated native counts remain
`{physics['unrelated_native_installs']}`. Shared-world generation changes
`{physics['generations']}` only at its tested owner restart. Signed view renewals
retain readers/resources; real source updates keep occurrence identities and
change geometry. These are owner/processing measurements, not latency claims.

## Qualification and retained failures

Clean `{campaign}` uses one frozen source: {len(inputs['files'])} authored server/spec
inputs, {len(inputs['dependency_sources'])} dependency entries and
{len(inputs['cargo_package_inputs'])} locked Cargo package archives, with no stale
compiled inputs. Native56, EUnit{count[1]}, full CT, xref, Dialyzer and local release
all completed sequentially with true child exit0 and no timeout. Full logs retain expected injected-owner-stop diagnostics.
CT result: {'; '.join(ct_lines).rstrip('.')}.

| Gate | Child exit | Seconds |
|---|---:|---:|
{gate_rows}

The clean gates cover affected foundation/privacy/GUI/creation/source/physics
journeys. Focused attempts and all failed/cancelled campaigns remain in the
[evidence index](../../doc/evidence/godot-m3a-20261028/README.md). gates01's native
pass, two withdrawal regressions, oversized compiled genesis and unrun later gates
are retained. gates02 had native56 passes and EUnit4,240 passes /21 failures;
later gates were unrun. Its stage stayed frozen while subsequent root diagnostic
test edits made the root comparison false. Stale occurrence IDs, offer/grant
fixture filters, inert source-hook baselines and the full physical preset were
corrected through their owners. gates03 kept its source unchanged and passed
native56/EUnit4,261 checks, with one real HTTPS source-edit failure. A bounded
trace measured91,134-byte answers echoing90,242 bytes of unchanged source inputs.
The shared proof runner now projects new bindings through ordinary retained-call
unification, without changing the wire format, caps or source editing API. The
focused124 checks passed, including that signed HTTPS journey, output aliases
and rejection of genuinely oversized new outputs. gates04 then exposed a native
feasibility adapter that returned raw projected answers while its callers expect
the fully resolved call. It now shares the same answer unifier as ordinary proof
callers; all native presentation paths retain their existing interface. The
failed campaign was explicitly canceled with its stop marker and actual zero
Erlang stop exit retained, without crediting a pass. A partial CT launch is
separately retained with unobserved child exit; xref/Dialyzer/release were unrun.
The final runner requires completion banners as well as true child exits and
refuses an explicitly stopped campaign. gates05 passed native56,
full EUnit4,264, CT149 and xref on unchanged source, then Dialyzer found one
unreachable frame-resolver branch and release stayed unrun. The resolver now
returns its pose directly, preserving source failure ownership and removing
three production lines. Four affected physical fixtures and focused Dialyzer
passed after this cleanup. The launch-only preflight60 command error remains
retained separately from the successful preflight61 analysis. Receipt-format and native-rest synchronization
failures remain recorded. Assertions, full-source workloads, encoding caps and
protocol deadlines were not weakened or extended.

Active production: +{production['added']}/−{production['removed']}, net+{production['net']} lines,
including the new pure frame-math module and both shared framework sources.
Tests/helpers:
+{tests['added']}/−{tests['removed']}, net+{tests['net']}. Specifications:
+{specs['added']}/−{specs['removed']}, net+{specs['net']}. Archived original:5 lines.
Shared-framework relocation:356 existing lines, already included in the active
+/- counts, with34 additional documentation/data-only metadata lines. Relocation
is not a reduction. Generated material, retained archives and evidence are separate.
The [source-quality inspection](../../doc/evidence/godot-m3a-20261028/source-quality-{campaign}.md)
records removed duplicated delegation checks, the rejected static fallback,
retired callers, editability/pinning implications and the shared-base footprint.
No unresolved finding remains within the inspected M3a delta; broader source
normalization remains open. Growth
implements recursive occurrence policy and the missing shared physical binding
and the shared computed-answer projection through existing owners; one new mutable relation is the root's frame membership,
with zero new server process types. Common anchored scope/singleton/digest
mechanics and recipe tables remove repeated source declarations without dropping
factory code or splitting domain transactions to evade the encoding envelope.
The complete physical preset changed from912 operations/495,486 compiled bytes
to801/450,826 in the final production preflight52. The common base now includes
pure form and body-schema clauses even in owners that do not use them; no
startup-memory reduction is claimed. Application state, policy, interfaces and
atomic consequences stay composed. Complete source reads and authorized local
edits include base clauses. Recovery requires exact base/runtime hashes; the
changed base is qualified with fresh foundations, without upgrading an existing
network. The temporary genesis tracer was removed before the clean gates. Later bounded
ACL tracing remained test-only in the isolated focused stage and retained evidence;
no diagnostic module entered the root source or clean campaigns.

## Boundary, bookkeeping and remaining scope

The immutable external boundary is `{boundary}`. Its `snapshot.json` indexes the
actual base/binary patch/full-untracked/dependency/toolchain/provider/output
contents and hashes; `RECONSTRUCT.md` and `reconstruction-verification.json`
describe the complete path-set/byte verification. Base SHA-256
`{base['sha256']}`; tracked patch SHA-256 `{patch['patch_sha256']}`.
The patch includes the preserved pre-existing coordination prompt edit.
Private fixture stores, credentials and raw logs remain outside public snapshots.
Closed native intermediates are losslessly retained with exact path/hash manifests.
No previous checkpoint artifact or stop marker was discarded. Existing legacy
lifecycle fixtures delete their ephemeral stores during cleanup; those stores
cannot be claimed retained. Full source/logs/child outcomes remain, and new
with_host failure stores remain private outside this snapshot.

All59 unchanged M2 client authored inputs and reused client/crypto/toolchain archive
hashes are checked. Their accepted evidence is reused only for unchanged scope.
The local builder image identity is not a published digest; desktop/GPU reproduction
still needs the compatible host documented by M2.

The [existing Stage 2 subset mapping](../../doc/evidence/godot-m3a-20261028/stage2-subset.md)
keeps D6 ontology editing/founding, other D5 duties and D7 terrain/embodiment/pilot
replacement open. This implementation accepts unconfigured ordinary shared frames
with the root's scale/gravity/timestep. Configured independent frames and active-run
joining refuse; broad simulation migration and framed terrain are not implemented.
Current terrain/material/licence/physical-pilot, custody, transfer, rest, hinge,
checkpoint, source/GUI and uncertainty protections remain active.

M3b must implement and qualify native Godot Enter/Leave UI, live recursive rendering,
portable frame/body-appearance interpretation, minimal desktop navigation/picking
and installed reconnect/recovery. No interactive Vive/XR, M4 controller, power-cut
or non-Linux claim is made. Full [QUO-64](nimbalyst://QUO-64)/M3 and parent completion are not credited
from server evidence alone. The original Stage 2 item is not closed. Metadata credits only the server M3a
subset: QUO-64 is in-review/13% (one of eight full-M3 checks); Stage2 is
in-review/25% (same-agent server entry). The parent remains50%; M3b/full-M3 and
broader Stage2 duties stay open.

Collaborative body publication remains blocked after automatic approval review;
no blocked body write was retried or routed around. Separately authorized metadata
outcomes are retained in `tracker-metadata-outcomes.json`. Local tracker reads and
linkedCount0 are not shared-publication or visible-attribution proof. Existing
checklist bodies may remain stale. No duplicate plan/phase ticket was created.
'''
handoff=root/'nimbalyst-local/handoffs/godot-m3a-result.md'
handoff.write_text(body)
index=f'''# M3a evidence

The [checkpoint result](../../../nimbalyst-local/handoffs/godot-m3a-result.md)
records the uncommitted server subset, exact remaining scope and publication limit.
[Source quality](source-quality-{campaign}.md) records ownership/refactoring decisions and
accounts separately for active growth, framework relocation and the archived helper.

Final campaign: `{campaign}`. Native56/EUnit{count[1]}/full CT/xref/Dialyzer/local
release: all true child0 sequentially, frozen source unchanged. Complete sanitized
logs and command/exit/hash receipts are in `logs/`. Detailed sanitized CT text
outputs and their raw/sanitized hashes are indexed in
`inputs/{campaign}-ct-log-outputs.json`; private fixture subtrees are excluded. Full raw logs and private failed
fixture stores remain outside this public boundary.

- [Qualification summary](qualification.json), [source scope/delta](scope-delta-{campaign}.json).
- [Frozen inputs](inputs/{campaign}-source-manifest.json),
  [source/generated/output classification](inputs/{campaign}-compiled-manifest.json).
- [Original same-A route/restart receipt]({campaign}-same-agent-route.json),
  [native shared-domain receipt]({campaign}-shared-physics.json),
  [signed recursive projection/source revocation]({campaign}-recursive-projection.json).
- [Stage 2 subset](stage2-subset.md), [retained failure dispositions](failure-dispositions.md).
- [Pure matrix reference](matrix-reference.json); consultative read-only Fable
  advice is retained in `claude-*-review.md`. The child ran no commands or tests.

`run.py` retains true child status, timeout state and complete sanitized output.
`gate-campaign.py` creates a new clean stage from authored source and preserved
dependency/package archives, then runs the six gates sequentially. It retains
each provider's original beams/native object before another provider replaces it.
`qualification-manifest.py` separates source, generated parser annotations,
derived Rebar/PLT indexes, native packages and compiled outputs.

Focused preflights use one incremental isolated build, not clean campaigns.
Earlier source archives remain intact. Later `*-delta.json` records reconstruct
their complete source from the retained full authored archive, replacement blobs
and exact path-set manifest. The preflight57/58 source supplements also record
an unused earlier diagnostic module retained in the incremental stage; it was not
selected for execution and is absent from the fresh clean campaign. Cancelled
preflight27 and every failed/unrun attempt
remain explicitly labelled. Packaging failures and lossless output retention have
separate receipts and do not masquerade as semantic gate passes.

The external immutable boundary is `{boundary}`; its snapshot descriptor carries
the final artifact hashes. Base `{base['sha256']}`, binary patch
`{patch['patch_sha256']}`. Reconstruction streams every archived source byte and
materializes all changed tracked files for a real binary patch application. No
extra branch, worktree, deployment or commit is created. The new untracked
archive uses XZ compression so retained source campaigns fit without discarding
any original bytes. `inputs/gatesNN-authored-delta.json` and its actual replacement
blobs reconstruct every closed campaign from the committed base and exact selected
path manifest; `*-closed-profile-objects.json` also pins the retained compiled
profile outputs. Closed identical source/provider blobs may share an inode;
`closed-artifact-deduplication.json` verifies all paths/hashes and retains original
timestamps. Previous checkpoint boundaries and live source were excluded.

Unchanged client/crypto/toolchain evidence is reused by exact hashes from the
accepted M2 boundary, with no new installed-client/M3b or hardware claim.
Collaborative body publication remains blocked; metadata/local evidence is not
shared-publication or visible-attribution proof. Full M3/Stage 2 remains open.
'''
(evidence/'README.md').write_text(index)
print(json.dumps(dict(handoff=str(handoff),eunit_passes=int(count[1]),ct_results=ct_lines,
    metadata_outcomes_retained=bool(metadata),boundary=boundary)))

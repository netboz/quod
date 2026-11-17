from pathlib import Path
import json,hashlib,subprocess
R=Path('/home/yan/src/quod_worktrees/pearl-stone');E=Path(__file__).resolve().parent
p=E/'APPLIED-RESULTS.md';s=p.read_text().replace('# Consolidated02 application — validation in progress','# Consolidated02 application — affected validation complete, delivery pending',1)
s+='''

## Final applied source and affected verification

Current source label **applied-consolidated02-final01**. The exact three authorized
patches were applied first; subsequent production corrections remove two missed
duplicate certificate-size checks and refresh auth/Simplex comments. No interpreter
optimization, new execution path, fallback registry or numeric replacement quota
was introduced. The coordinated Erlog source has not changed from its reviewed
three-file patch. Runtime tests used isolated fixture storage, never user stores.

Actual delta against the saved consolidated02 preimages (the prior applied-carrier02
source): **repository production +499/−635, net−136,43 paths**; dependency production
**+23/−51, net−28,2 paths**. Combined production net−164. Repository tests
+663/−345 (60 paths), dependency tests+16/−23, specs+43/−9. Counts include TEST-only
owner seams in production files and exclude inherited changes. Namespace guards
and actual complete-frame accounting account for necessary additions; quota
validation, duplicated arithmetic and obsolete diagnostic state were retired.
`application01/current-delta.json` binds every before/after hash and separately
identifies follow-up changes. No number is a whole-worktree delta.

All listed runtime and compile receipts retain true child exits and both EOF:

| Campaign | Literal result | Disposition |
|---|---|---|
| applied-codecs01 |348pass/2fail,exit1| Auth helper explicitly supplied4; scope expected removed1025 rejection. Corrected two checks pass in codecs02,exit0. All seven Erlog EUnit modules pass in codecs01. |
| applied-history01 |389pass/37fail,exit1| Missing debug_info/static fixture input, old storage paths, local-stream pagination assumption and fresh-peer setup; no failures overwritten. |
| applied-history02 |47pass/2fail,exit1| Retains identical Grant/Next bad_frame and mixed old/new Erlog-record peer loading. Corrected history03 passes2/2,exit0. |
| applied-owners01 |499pass/3fail,exit1| Custody helper sorts by submission ID, lower placement had2 attempts; two obsolete committee-limit assertions. |
| applied-owners02 |11pass/1fail,exit1| Corrected priority/refusal and nine committee-authority checks pass. Added wrong-domain fixture supplied13 bytes instead of actual32-byte domain. |
| applied-owners03 |1pass,exit0| Corrected valid-width wrong-domain refusal,65-member signature acceptance and insufficient-quorum refusal. |
| applied-integration01 |254pass/4fail,exit1| Deep-term and dependency-name quota expectations; omitted existing model asset in isolated fixture; initial projection expected two opens from old256-entry page split. |
| applied-integration02 |4pass,exit0| Exact signed deep-term roundtrip plus PID refusal; large dependency roundtrip plus malformed anchor; existing HTTPS asset/security headers;258-entry snapshot→259 real update→unchanged zero opens. |
| applied-client01 |all3steps exit0| Native build and10 admission/namespace checks; affected browser agent-reference and signed-client suites. |
| applied-production02 |exit0| Every current Quod/Erlog production module compiles without TEST/export_all and with the same10-field est record. |

Build01's missed certificate macros and unavailable optional `eqc` test remain
literal. Build04's accidentally launched old inputs and build05's unsafe fixture
variable remain failures. Earlier proposal compilation with mismatched include_lib
resolution is not relabelled; parent preprocessing receipts remain included.
The incremental compiler now explicitly binds the isolated Erlog application.
The edited record-consuming predicate-failure and foreign-projection fixtures
were rebuilt against that same family. Final production compilation is separate
from TEST/export_all execution and source-hash coverage is recorded.

### Current-source guarantee coverage

- Current real signed-operation verdicts recheck parent policy after revocation,
  reject stale authorization transcripts, enforce source-material ACLs, and retain
  network-identity custody/recovery. These are real production-owner tests with
  signed material; they are not a new end-to-end Godot campaign.
-513 distinct legitimately signed submissions cross the Simplex relay handler and
  remain exact/FIFO with no repeated drain wake. This demonstrates retained queue
  custody, not513 completed consensus commits. Ready lower author sequence stays
  ahead of later unsigned ingress; exact submission/deadline and retarget attempt
  count are preserved. Membership same-event fixed-point test remains intact.
-65 simultaneous real proof workers acknowledge their owned barrier and release
  through finish_proof; subsequent work is admitted. Explicit finite proof/scope,
  authentication/rate, material and diagnostic callback policies remain tested.
- Catchup exercises real cursor/readers, complete finality groups, terminal-marker
  lookahead, stale/foreign continuation tokens, cancellation and original expiry.
  The small test capacity exercises complete framing without allocating multi-GB
  payloads. Canonical signatures, CRC/torn-tail and persisted recovery remain.
- Namespace tests refuse before either configured root is written, preserve old
  journal/foreign manifests and projection markers, reject stopped-old-outcome
  lookup and reopen exact long names without alias. No migration/cutover occurred.
- Residency/foreign projection tests verify real advancement, retained cursor
  recovery, no unchanged history replay/rebuild/write work and no repeated snapshot
  open. Native/browser signing preserves exact UTF-8 namespaces and actual widths.

### Retained evidence and remaining limits of this result

Earlier signed native full-catalogue/long-label/picking, cycle, editor, revocation,
stale selection, reconnect and unchanged-I/O results remain pinned to their own
source. They were not rerun or silently called current whole-tree acceptance.
Current affected owner checks cover changed admission/record/storage behavior.
The original **three renewals within aggregate30s remain failed**; split-window
lifecycle diagnostics cannot close it. No deadline changed and no uncertain
operation was replayed. This is not Stage2 or release acceptance.

Actual32-bit framing and16-bit signed namespace/encoded link-channel fields remain
representation checks. VM atom names/capacity remain real VM constraints; the
atom_count precheck is not an atomic reservation against unrelated allocators.
Unlimited defaults remain unlimited. Explicit finite resource policy is preserved;
heap_bytes shared-offheap accounting was not tightened, and its GC enforcement
is not a claim of general memory safety. Optional accounting semantics, durable
abolish lifecycle and Stage3/D7 remain outside this slice.

The remaining delivery blocker is the required editor commit proposal's repository
attachment scope: it rejected the three exact pearl-stone Erlog paths as outside
this session's attached git repositories, before a widget or commit. This is **not**
a new automatic approval review refusal. Parent handles attachment and the already
authorized Erlog-only commit/publication/exact dependency pin. No CLI bypass,
commit, push or pin change has occurred. A fresh checkout is not yet delivered
with the new Erlog record family; publication/pin requires a separate exact evidence
supplement. The unchanged pin is not represented as completed dependency delivery.

Namespace format code is authorized/applied/tested; preservation/cutover and
deployment remain separately unauthorized. No user-store access, hardware/human
test, shutdown retry, cleanup, Quod commit or Claude review occurred. Prior
freezes and rejection records remain immutable.
'''
p.write_text(s)
p=R/'nimbalyst-local/plans/space-conceptual-architecture-review.md';s=p.read_text().replace('Current Stage2 blocker: the remaining-owner correction is a compiled, unapplied','At the consolidated02 proposal freeze, the Stage2 blocker was a compiled, unapplied')
s+='''

Consolidated02 applied validation completed on `applied-consolidated02-final01`:
[actual source, failures and owner evidence](../../doc/evidence/stage2-remaining-admission-20261103/APPLIED-RESULTS.md).
The three frozen patches are applied under cell378 authority. Repository production
+499/−635 (net−136), Erlog production+23/−51 (net−28), separately from inherited
changes. Affected software owner checks and normal production compilation pass
after separately preserved failed fixture/build attempts; exact labels are in the
results. Denial/revocation, signed custody, history continuation/recovery, namespace
no-write refusal, finite overrides,65-worker release and update/unchanged work are
covered by current owners. Prior native D5/D6 evidence remains source-qualified.
Original aggregate30s renewal acceptance is still failed; no Stage2 completion
checkbox is closed. Dependency publication/pin remains blocked by the editor's
repository attachment scope; parent owns its authorized commit proposal and
publication. Namespace code approval is settled; no user-store cutover/migration
or deployment was authorized/performed. The applied freeze is recorded separately
as `stage2-remaining-admission-applied01`; earlier proposal/carrier freezes remain
immutable. No new D6 domain decision or startup flow is needed for this work.
''';p.write_text(s)
p=R/'nimbalyst-local/handoffs/stage2-d5-reconciliation-20261103.md';s=p.read_text();s+='''

### Authorized consolidated02 application — affected verification complete

The prior unapplied status above is historical. Desktop cell378 explicitly
authorized all three frozen patches, their tests, namespace format code and later
Erlog-only delivery. Exact receipt and previous rejection remain in the campaign.
Current source `applied-consolidated02-final01`, detailed results:
`doc/evidence/stage2-remaining-admission-20261103/APPLIED-RESULTS.md`.
Actual repository production+499/−635 (net−136), Erlog+23/−51 (net−28).
All failed builds/fixtures retain their original labels/exit/EOF; only affected
corrections were rerun. Current normal production compilation passes with the same
new Erlog record layout and no TEST/export_all. Affected runtime suites exercise
signed policy revocation/stale authority, finite policies, queue/custody/recovery,
real cursor/finality, namespace no-write preservation,65-worker release and
real-update/unchanged-work owners. Current native/browser namespace checks pass.
Full original large-display aggregate30s acceptance remains failed; prior native
cycle/editor/reconnect/selection evidence is not relabelled as new acceptance.

Only production follow-ups to the reviewed patch remove two missed certificate
subquota checks and correct stale comments/whitespace. The remaining changes
correct test input/expectations and build provenance, preserving denial/signature,
priority/retarget, exact snapshot and zero-unchanged-work obligations.

Erlog publication/pin remains blocked by required editor tool repository attachment,
with the exact scope error retained in `inputs/erlog-commit-proposal01.json`.
Parent handles the already-authorized commit proposal/publication/pin; no CLI
bypass or independent commit is allowed. All three tested dependency files remain
exactly the reviewed patch; inherited generated application/scanner files are
excluded. A subsequent pin requires a separate evidence supplement, not modification
of this freeze. Namespace migration/deployment/user-store access remain prohibited.
No Stage3/D7 or durable-abolish change, optional heap-accounting change, deadline
extension, uncertain replay, hardware/human test or Claude review occurred.
''';p.write_text(s)
# Historical proposal pages remain literal, with an explicit pointer to current status.
for n in ['RESULTS.md','OWNER-VERIFICATION.md','NAMESPACE-DECISION.md']:
 p=E/n;s=p.read_text();lines=s.splitlines(True);lines.insert(1,'\nHistorical consolidated02 proposal state is preserved below. The later explicitly authorized application and current validation are recorded in [APPLIED-RESULTS.md](APPLIED-RESULTS.md).\n');p.write_text(''.join(lines))
# Exact current repository state and harmless whitespace checks, with literal receipts.
rows=[]
for name,cwd in [('quod',R),('erlog',R/'_build/default/lib/erlog')]:
 for phase,args in [('diff-check',['git','diff','--check']),('status',['git','status','--short']),('head',['git','rev-parse','HEAD'])]:
  x=subprocess.run(args,cwd=cwd,capture_output=True);rows.append(dict(repository=name,phase=phase,command=args,true_exit=x.returncode,stdout_eof=True,stderr_eof=True,stdout=x.stdout.decode(),stderr=x.stderr.decode()))
(E/'application01/final-repository-state.json').write_text(json.dumps(rows,indent=2)+'\n')
assert all(x['true_exit']==0 for x in rows)
print('CURRENT_RESULTS_PLAN_HANDOFF_UPDATED')

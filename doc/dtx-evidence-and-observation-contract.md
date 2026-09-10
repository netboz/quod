# DTX evidence resolution and coordinator observation ownership

**2026-09-10 — contracts A+B independently approved; implementation follows
C in separately identified scopes, each reviewed before commit.**
Baseline `3b58f51`, 0.7.160. The independently accepted
[hardware evidence](residency-owner-hardware-results.md) endorses these seams
for contract-writing, not code changes. Question C's
[unchanged-source reproduction](retained-dtx-renewal-ordering-contract.md)
now precedes this proposal. No new measurement, deployment or resubmission
has occurred.

## 1. Evidence and scope

The current coordinator can use a remote phase reply to select foreign
verification even when the exact target is locally hosted. In the recorded
41.298-second job, source node 0 rebuilt A's 1210-entry foreign cache despite
hosting A's already-verified consensus ledger. Its client root was only about
546 ms: that shared verification outlived this caller. This is avoidable work,
not a 41-second measured client result or proof of every c4 delay.

The capture also has no exported `quod.dtx.coordinate` roots. A coordinator
owns its own process-lifetime span, while Simplex can retire that non-trapping
child with `exit(Pid, shutdown)`. The child's `try/after` cleanup cannot be
relied on after an external exit. The SDK root can therefore be absent even
when its phase children exist. Fixing the root lifetime does not itself make
canceled worker children complete or satisfy the attribution auditor.

Contracts are deliberately distinct:

- **A is behavioral source-selection and budget correction**, with unchanged
  authentication and existing caller result policies.
- **B is observation-only ownership correction**, with unchanged execution,
  public results, coordinator retirement and monitor behavior.

Neither is a duplicate-receipt shortcut, a new finality rule or permission to
trust a resident entry merely because it is in memory.

## 2. A — one route-neutral exact-evidence resolver

### 2.1 Existing seams and the deletion target

| Baseline seam | Problem / reusable contract |
| --- | --- |
| `quod_dtx_coordinator:phase_evidence_sources/7`, line 1500 | Uses delivery candidates to choose verification. Each remote arm discards the peer and invokes the same whole foreign source walk again with a fresh relative allowance. |
| `verify_phase_raw/6`, line 2177 | Sequential recovery independently repeats the local-versus-remote policy; the remote reply can force the foreign arm. |
| `endpoint_sources/2`, line 2525 | Correctly prioritizes endpoints for actual delivery. Its order must not choose authentication storage. |
| `quod_simplex:verify_remote_dtx_reference/5`, line 11581 | Existing local-first pattern, but calls the old local evidence wrapper and owns another copy of source-selection policy. |
| `dtx_local_evidence/3`, line 2819 | Captures via a 1000 ms namespace call, then verifies with `infinity`. Do not reproduce this split in A. |
| `history_view/3`, line 2656 | Exact-PID capture under the original absolute budget; immutable snapshot and matching verified projection, rechecked at publication. |
| `quod_foreign_log:verify_local/4`, line 507 | Direct exact check within the retained current committee era; older eras enter the same historical verifier using the captured snapshot as bytes. |
| `verify_reference/5`, line 418 | Existing routed exact job: contacts and entry hints are not authority; the one owner selects sources and verifies history. |

Put the common policy at the existing `quod_foreign_log` verification API,
not in a new module, process or service. Proposed API shape:

```erlang
resolve_reference(TargetIdentity, Ref, Phase, Contact, EntryHint, Deadline)
```

This is a caller-side adapter over the existing local and routed primitives,
not another verifier. Its internals share their existing validation and
absolute-deadline implementation; do not copy either verification body.
`TargetIdentity` is the expected anchored target, not a namespace inferred
from untrusted reply metadata. `Deadline` is an absolute monotonic deadline.
`Contact` retains the current authenticated contact type; a mere preferred
peer key is not promoted into an authenticated endpoint. Entry hints retain
the existing bounded normalization and verification contract.

Migrate both coordinator evidence paths and Simplex's **remote-reference
worker** policy to this common adapter. Leave explicit captured-view validation
inside Simplex on `verify_local`: the owner already passed that exact view to
its worker, so calling back into the owner would be a regression. Low-level
explicit foreign/source APIs remain real primitives used by the verifier and
tests, not a second normal coordinator policy or compatibility fallback.

### 2.2 Selection is storage preference, not authority

1. Validate the requested phase and exact reference binding to
   `TargetIdentity` before any owner/route work. A wrong reference target is
   invalid, even if some other ontology could authenticate it.
2. Capture the currently registered target owner once, through gproc's
   existing `quod_reg` lookup and `history_view` exact-PID call. Use the
   **committed** view requirement: proof of an exact stored entry is not
   execution readiness or proof that Prolog applied it. An empty joining
   prefix establishes no genesis or reference by itself.
3. If the exact captured prefix contains the reference's height, invoke the
   existing local verifier. Its current-era check validates the exact entry,
   phase, claim, finality and committee-era binding. Older eras still require
   the existing historical verifier; do not backdate the current committee.
4. If there is no owner, no usable captured view, a different local anchored
   incarnation, or a captured prefix below the required height, invoke the
   existing routed verifier **once**, within the same remaining deadline.
   It performs its own source walk. No outer per-endpoint repetition remains.

The distinction between malformed request and unavailable local copy matters.
A reference that disagrees with the expected target is invalid at step 1;
a valid expected old incarnation that differs from the node's re-founded
local incarnation is simply not available from that local copy. The routed
verifier stays pinned to the requested old anchor; no substitution is allowed.

**After a sufficient local view is captured, it stays pinned.** If that owner
dies/replaces itself during verification, return the existing unavailable
result; never retarget the old borrow or silently recapture a newer view.
There is no second routed job after a failed historical-local job. A later
attempt requires the existing legitimate progress/demand edge and gets its
own ordinary caller registration. This deliberately avoids inventing a new
handoff protocol between `local_exact` and routed work. It also means local
loss during a borrow may end this attempt despite a reachable remote copy;
the contract does not promise every possible fallback inside one call.

Definitive local verification failure must not be retried through another
source to turn invalid evidence into success. Preserve raw verifier errors
and the existing consuming seam's typed mapping; do not silently change the
coordinator's failure/parking policy or Simplex's invalid/abstain policy.
An unusable *hint* remains only a hint: the current hint normalization rules
are unchanged. A successful resident fast path must be tested with malformed
and wrong-era supplied finality proofs, not just equal claims.

This yields at most one foreign owner job per resolution (either historical
local verification or routed verification), not one job per delivery peer.
A current-era co-hosted hit uses no foreign cache job. It does not promise
zero cold work for historical eras, nor solve cold replay O(history).

### 2.3 One original finite deadline, no numeric retuning

Capture each existing evidence attempt's allowance before admitting its
verification wave/worker, and carry that exact deadline through snapshot
capture, local verification, routed admission and publication. The sequential
path captures at its equivalent attempt boundary. Do not combine formerly
separate command and evidence budgets into a new client-wide deadline, or
grant a new allowance per delivery candidate. Simplex's reference validation
keeps its existing 6000 ms allowance; coordinator evidence keeps its configured
allowance. Neither is increased or used to mint a retry.

Extract/reuse deadline-aware internals of `verify_local` and
`verify_reference`. Relative-budget public primitives may delegate once at
entry, but this adapter must not convert back to a fresh relative deadline
after spending time locally. Check before dispatch and after result return;
owner-mailbox time consumes the same budget. On expiry, no fallback starts
and no queued success is published. Existing foreign caller removal versus
shared-job lifetime, actual-death custody and source monitoring are unchanged.

Remove the old `dtx_local_evidence/3` capture/infinity split rather than leave
it as an alternate finite-request path. Its remaining serving use is the
`applied` endpoint, which already receives an absolute deadline: thread that
into the same **local-only** captured-view primitive, preserving endpoint
readiness and applied-state checks. The history-only Begin bootstrap already
has an explicit captured view and reviewed owner-death lifetime; preserve
that distinct borrow instead of giving routed requests infinity.
`dtx_applied_source/2` returns a source for current-view applied certification,
not exact evidence. It is not replaced by this resolver or treated as applied
proof; its separate capture-budget debt is named, not silently claimed fixed.

### 2.4 Required tests and structural work bounds

- Same locally hosted target, remote-first reply and multiple advertised
  delivery peers: both coordinator paths succeed via one exact owned read.
  Process-trace positive controls pin zero foreign job/replay/full-open work.
- No local owner: one routed invocation regardless of delivery-candidate
  count, with existing authenticated contact/entry hint passed once.
- Explicit contact negative: a preferred peer key carried by a reply must
  never become an authenticated endpoint. Pin the actual resolver admission
  arguments; a contact-promotion mutant must fail this assertion.
- Lagging prefix, missing registration, capture loss and a different local
  incarnation: allowed fallback keeps the exact requested identity and original
  deadline. A wrong expected-target/ref pair is refused before either path.
- Sufficient captured owner dies before/during/after result: unavailable,
  no publication from the old borrow, no replacement-owner recapture, no
  second foreign job. Preserve shared-caller expiry isolation.
- Hold owner admission, then verification, across expiry; a pre-expiry queued
  result cannot become post-expiry success. No foreign launch after expiry.
- Real committee replacement: old-slot references verify with their own era,
  never the current era. Forged proof, changed phase/record/hash/anchor and
  wrong-era signatures are refused. Distinct valid quorum subsets still pass.
- Local later append preserves the captured prefix. Foreign vocabulary
  remains wrapped with atom-count controls. MVCC/proof backtracking, sealed
  plans and current-view applied-vote thresholds are untouched.
- Existing ledger AST guards stay exact. Remove the coordinator evidence
  candidate recursion and its obsolete source-dispatch clauses/tests; keep
  actual command delivery, applied-source selection and result authentication.

The fail-before case must force a real remote-first reply for a hosted target;
mocking the answer of the proposed resolver would not establish the defect.
The 1210-entry hardware archive is evidence of work, not a required test size.

## 3. B — span lifetime follows the monitor holder

### 3.1 One existing owner, no execution changes

`#dtx_coordinator_owner{}` in Simplex already holds GroupId, PID, monitor,
Begin identity and original caller context. Add only an optional volatile
span handle/context there. Start `quod.dtx.coordinate` in
`start_dtx_coordinator_worker` before the existing `start_monitor` call, pass
its child context through the already-existing context carrier, and store its
handle with the returned exact PID/monitor. Remove the child `init/1`'s
process-lifetime `with_span` wrapper; the child uses inherited context for
its unchanged work.

Keep `trace_ctx` as the **original** caller/recovery parent. Replacement
attempts must not become children of a retired coordinator span. Reuse
`shared_context/1`'s existing parent/link policy; no fabricated sampled caller
for history-only work. A span is one owner-observed coordinator attempt, not
the whole durable group's lifetime across restarts.

One closure helper at existing owner release edges:

| Edge | Honest closure provenance |
| --- | --- |
| Matching PID+monitor DOWN, normal exit | `worker_exit`, exit class normal; semantic completion only if separately observed |
| Matching abnormal DOWN | `worker_exit`, bounded exit class; no raw reason/state export |
| Desired group removed / actual replacement | `retirement_requested`, not worker death or successful Complete |
| Existing child start fails | `start_failed`; preserve original failure behavior |
| Existing Simplex terminate callback | `owner_terminating`, best effort; no claim for untrappable owner death |

End once, clear/drop the owned handle in that existing transition, then retain
the exact existing demonitor/exit/removal behavior. No trap-exit change,
cooperative shutdown request, acknowledgment wait, extra queue, new monitor,
timer, worker or cancellation policy. A stale message for an older PID/monitor
cannot close the replacement's span. Ordinary Begin record→certified-ref
adoption is already in place (`adopt_committed_begin_owner/4`); it is **not**
a replacement or a reason to split/close the span.

Handle both a returned start error and an exception before row installation,
closing the local observation without changing the original exception. An
exact child-error event still takes the existing owner-fatal path; record
only its closed observation class and let the existing terminate path close
the retained handle, rather than ending twice through stale state. Do not
use `otel_span:is_recording/1` as a mutable ended-span flag: its context flag
does not track owner-handle retirement. Historical Begin loader rows have no
coordinate span until the coordinator starts; their duration remains outside
this root and must be accounted separately, not silently included.

### 3.2 Observation is not a durable verdict

`drive_commands_next` sends `{done, CompleteRef}` **before** child cleanup.
Record a bounded `done_observed` event at the existing exact-PID handler;
do not call this process exit or move cleanup ahead of notification. End at
the actual owner release edge above. If reconciliation retires the child
before it returns, closure is still `retirement_requested`, even with a
done observation. `{terminal, Terminal}` releases an existing client waiter
while Complete drains; it must not close the coordinator observation.

Never synthesize `dtx.completed` from desired-row omission, normal DOWN,
retirement, receipt visibility or a reported worker result. The existing
generic child `close_coordinator` currently emits that name for failed and
uncertain closures too: replace that ambiguous observation with a closed
coordinator-close event, and retain a semantic-completion event only on the
actual existing recovery `{done, CompleteRef}` branch. No new authority is
derived from that event or from the reference it names.

Root duration now ends when the owner releases its observation. It can include
owner-message delay and may end before killed children stop. Name that meaning
in the analyzer; never compare it as if it were the old child's measured
`coordinator_total`. Existing phase/total metrics are not fabricated on forced
shutdown. Late child events can be lost after span end; canceled phase/probe
children still require explicit auditor discrepancies, not invented intervals.

Untrappable Simplex/node death can still lose this volatile observation. No
external observer or durable trace journal is proposed. The expected-attempt
inventory must report missing roots; sampling/export loss is not idleness.
This contract repairs the known child-retirement root loss, not all 32 current
auditor issues or all cross-node interval attribution.

### 3.3 Required tests

Real SDK tests must drive Complete-derived desired-row retirement with the
child held before return; the old code loses the root and the new owner ends
it exactly once as retirement. Include done-before-child-cleanup, natural
normal exit, abnormal DOWN, start failure, genuine replacement, same-worker
Begin adoption, duplicate/stale messages and owner termination. A live public
terminal notification leaves the root open. Original caller ancestry must
survive replacement without chaining through the old attempt.

Pin actual wire bytes, replies, follow cleanup, process exit behavior, monitors
and work ordering unchanged. The disabled/unsampled path has no exported
children under an ambient unrelated context. Secret-bearing error reasons
never enter attributes. Use producer-side attempt counts and fail-before
controls, not only searches for traces that happened to export.

## 4. Review, sequencing and measurement

The C diagnosis/correction and these A+B contracts are approved. Implement
C as its own correctness scope; implement A and B as separately
identified behavioral and diagnostic scopes. Each final scope returns for
review before commit on the exact tree, with full clean sequential EUnit,
ask/QUIC CT, both Simplex suites, xref, Dialyzer, release and diff-check. No
production edits, new code gates or performance numbers are claimed here.

Only after reviewed deployment and a successful fleet-health boundary can a
new, explicitly warm-labeled campaign start. Preserve all ledgers, stopped
campaigns and original requests. Never resubmit uncertain writes. Repeat
the conserved A→B c1/c4 pilots first, then the planned facts/n100 matrix only
if their original-response/oracle gates allow it. Report all attempts and
means-based non-overlapping attribution; do not average eventual recovery into
delivery latency. Watch the unexplained serial mean increase
544.580→591.722 ms (~8.7%) explicitly. Do not promise c4 will equal serial.

Carry the replaying-1302/applied-1304 runtime-health discrepancy as a separate
untraced recovery edge: fixing C is not proof it resolves. The first four
24.7-second requests still have no exclusive blocker attribution. Both
BENCH_STOPs, the 95% client gate, slot1059, old .159 request8, absolute latency,
result authentication, Q4, duplicate-receipt contract, finality, L2, cold
start/compaction and 10k behavior remain independently open. Yan's five
write-lanes files remain excluded.

## 5. A implementation addendum — 2026-09-10

The approved text above is unchanged. C is committed as `cd3e10b`; this
addendum concerns only A. B's span-ownership changes and the next measurement
campaign have not begun. A remains subject to independent implementation
review before commit.

`quod_foreign_log:resolve_reference/6` now owns the caller-side selection
policy. It validates the expected binding/phase before capture, borrows one
committed local prefix, and uses at most one existing historical-local or
routed job. A sufficient captured view never falls back after owner loss or
verification failure. The local/routed APIs reuse their existing verification
bodies with the original absolute deadline; proof, finality and committee-era
checks are not replaced by resident-entry equality.

The coordinator's wave and sequential evidence paths use that adapter with
`Contact = none`; reply peer preferences remain unauthenticated hints. Both
outer phase-observation delivery walks now stop at the first correlated
committed reference and return its single evidence attempt. Transport errors,
pending and absence still use the existing delivery walk. A review caught
those outer loops after the first implementation, and their dedicated tests
now enter before endpoint selection. Obsolete evidence recursion and dead
preferred-source clauses were removed; all surviving actual-delivery calls
used the old `any` ordering, preserved by `endpoint_sources/1`.

Simplex carries its existing 6000ms reference-worker deadline from admission
through verification and owner consumption. A queued successful result cannot
become valid after expiry. Explicit captured-view workers do not callback into
their owner. The applied endpoint's exact local evidence takes its existing
absolute deadline through an `any` view, retaining readiness/applied checks.
The distinct history-only Begin bootstrap keeps its explicit infinite borrow;
`dtx_applied_source/2` and its separate capture-budget debt remain unchanged.

The review evidence is archived under `/tmp/quod-evidence-A-ugHGb9/`, with
coordinator controls under `/tmp/quod-a-coordinator-CS8LYr/` and resolver
sidecar transcript provenance under `/tmp/quod-resolver-sidecar.Ac83yk/evidence/`.
The first full run passed EUnit 2043/0, all four CT suites and xref, then failed
Dialyzer on four dead routing branches. It is retained as `gates-1`, not final
acceptance. Corrected compile, focused outer-loop tests (107/0), and standalone
Dialyzer subsequently passed. The final focused freeze passed 111/0.

The fresh final sequential run, `gates-2`, completed at 15:23:35 UTC:
EUnit **2049/0**, ask CT **26/26**, QUIC CT **26/26**, Quod Simplex CT **12/12**,
N=4 Simplex CT **8/8**, xref, Dialyzer, production release 0.7.160, diff-check
and unchanged-source/test hash verification — all exit 0. All 65 new A cases
are included. The exact six-file code/test manifest is
`gates-2/tree-sha256.txt`; the final handoff includes the contract separately.
The ordinary and uncertain outer-loop controls additionally show old code
renewing two deadlines after expiry, and repeating three captures for invalid
signatures; corrected code makes one attempt. Their transport-success controls
remain passing. A is ready for independent implementation review, uncommitted.

Fixtures state their boundaries: encoded endpoint replies use the production
codec, not a claimed real QUIC authentication handshake; registered history
owners are protocol fixtures, not full consensus readiness nodes; the Simplex
queue test is callback state, not candidate wire admission. Existing ledger
architecture and foreign-vocabulary tests were not weakened. An extra isolated
cold atom-count diagnostic failed then passed unchanged warm; the preserved
transcripts distinguish those outcomes and do not claim general atom safety.

No production deployment, ledger purge, uncertain request resubmission,
timeout increase, benchmark restart or latency result is claimed by A.

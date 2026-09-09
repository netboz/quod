# Exact-reference verification: lifecycle and trace contract

Status: **the lifecycle/tracing/custody cut's final implementation review is
closed (2026-09-10): SAFE TO COMMIT and proceed to preserved-ledger capture.
The conditions in §4.3 and §4.4 have fail-before and permanent regression
evidence; full sequential gate results are recorded in §7.**
The fail-before campaign reached §4.4's stop condition: watcher-only restart
exclusion is refuted at the same cache ledger inode. The resulting
[custody extension](foreign-cache-writer-custody-contract.md) has now been
reviewed and approved for this same cut, including the registry failure
boundary and session-specific cleanup corrections. Claude reproduced EUnit
1937/0, ask/QUIC 26/26, Simplex 12/12, xref, Dialyzer, production release and
diff-check on the exact tree. Hardware acceptance remains outstanding.
Source baseline: `5c374c5`, Quod 0.7.157. Claude's 0.7.157 evidence review
accepts the off measurements and the limited cold/warm diagnostic, not the
failed on capture or closure of any performance gate. Yan permits a genuine
refactor if it simplifies the owning logic. Claude approved both the diagnostic
and behavioral contracts, with the three text corrections below folded in.
This is not permission to change consensus, tune timeouts, introduce another
verifier or implement an unreviewed cache-writer exclusion protocol.

## 1. Problem and measured boundary

The [reviewed hardware evidence](consensus-owner-turn-hardware-results.md)
establishes:

| Observation | Established | Not established |
|---|---|---|
| Source block 1059 | Three claims plus a receipt unique to this block; 6001.673 ms validation → `abstain`, 963.428 ms gap, 1684.596 ms validation → `valid` | Which internal wait consumed six seconds; whether the second caller joined the first surviving job |
| Cold remote read | Successive 9704.204 / 27369.304 ms foreign-current stages; resident height zero, disk histories 389 / 1138 entries | Exclusive attribution of the 8033.420 / 22859.402 ms uncovered worker time to replay |
| Warm remote read | One 11.015 ms proof after the cold workers completed | A write-latency distribution, or the cause of the earlier on-preflight failure |

The source's six-second caller budget makes expiry a strong suspect, not a
proved trace verdict. A unique receipt means a duplicate-only verification
bypass does not answer this case. The 963 ms gap must not be renamed a network
delay or a measured retry timer without its actual triggering message.

Keep the other findings visible: serial `operation_result` rose **18.4% then
another 2.27%, now 195.679 ms**; the source-call/endpoint residual is
**58.302 / 152.248 ms** at c1/c4; c4 source-owner delivery rose
**22.817 → 26.909 ms**. Those intervals are not explained by block 1059.
Current one-hop p50/p99 are 378/476 ms serial and 893/9632 ms c4, all 200
writes committed and all outliers included. Both absolute gates remain open.

## 2. Existing owners and verified source facts

One node-wide `quod_foreign_log` owns the queue and certified cache. Within one
live owner incarnation, one worker at a time mutates an anchored identity's
cache; cross-restart exclusion remains the proof obligation in §4.4.
Existing catch-up links own
page credit; `quod_catchup` and the historical verifier establish authority.
The source Simplex owns its candidate and support verdict. No owner changes.

Source references below are for the baseline, not implementation promises:

| Seam | As built |
|---|---|
| `quod_simplex:verify_remote_dtx_reference_routes/6`, `:11555`; `DTX_FOREIGN_VERIFY_MS`, `:1021` | Exact reference caller gets 6000 ms; unavailable results become `abstain`, not invalid |
| `quod_foreign_log:verify_reference/5`, `:358`; `request_caller_timer/3`, `:1458` | Outer call uses timeout + 1000 ms; inner timer starts at owner admission, not before owner-mailbox waiting; the caller row holds a timer, not an absolute deadline |
| `start_distinct_routed_worker/5`, `:1247`; `join_identical_request/5`, `:1596` | Same semantic work shares a job; distinct work queues per identity; caller expiry does not cancel active or runnable queued work; last-caller expiry removes a parked row |
| `request_work_timer/3`, `:1468`; `verification_work/8`, `:4328` | Follow has an owner work timer; normal exact work does not, and ignores the nominal work timeout passed to it |
| `admit_pull/11`, `:3893` | Pages have actual absolute deadlines and monitored pullers; only follow clamps a page to a whole-work deadline |
| `park_failed_routed_request/2`, `:2357`; `release_route_waiters/2`, `:2530` | A temporary routed failure parks a row with remaining interest; concrete progress releases queued rows; an active attempt has no equivalent of follow's buffered `follow_dirty` edge |
| `shareable_waiting_work/4`, `:1684` | Parked no-contact equality compares the whole routed-work record, including `trace_ctx`; active equality excludes that context |
| `verification_trace_context/1`, `:4204`; `routed_worker_work/3`, `:1305` | Current work carries context; exact work discards it |
| `verification_worker/8`, `:4172`; `install_worker_result/5`, `:2248` | Cache suspension occurs outside the current worker span; owner installation/wake is not context-bound |
| `open_replayed_cache/8`, `:4802` | Replay has a metric, not a child span; checkpoint comparison occurs after that metric's interval |

Callerless queued progress is intentional, not dead code:
`queued_identical_callers_expire_without_cancelling_the_job_test/0`
(`test/quod_foreign_log_tests.erl:5246`) requires that job to run and permits a
later caller to join. Preserve this guarantee.

The API/owner deadline distinction is a concrete contract inconsistency with
[A1's original-budget rule](catchup-page-credit-plan.md#61-quiet-target-counterexample--correction-approved).
It does **not** prove owner-mailbox delay caused block 1059. Similarly, the
missing active-edge memory is a schedule to test, not a diagnosed hardware
lost wake. Keep these classifications separate.

## 3. Target abstraction: a shared job is not a caller

Keep one queue, one active-worker row and the existing resident history.
Separate three kinds of information in those existing records:

1. **Verification request:** anchored identity, expected phase, exact reference
   and existing entry-hint/source-view binding. This determines what must be
   proved. Do not change reference equality, interchangeable-certificate rules,
   or which entry hints can share work in this cut.
2. **Availability and lifecycle:** request-scoped contacts/supplied routes,
   active/queued/parked status, exact worker/source incarnation, caller
   registrations and an accepted progress edge. Contacts remain reachability,
   not authority. Preserve the existing distinction between active sharing and
   a differently routed row that can run past a parked row.
3. **Observation:** transient span contexts, local job/attempt correlation,
   admission timestamps and closed diagnostic causes. These never participate
   in work equality, routing, ordering, signatures, cache checkpoints or wire.

The parked no-contact equality seam must compare **`supplied` + `contact` +
`kind` exactly**, excluding only observation metadata. Preserve the distinct
active-sharing and authenticated-contact wake rules. Do not add an exact-only
exception or retain a whole-record
comparison after adding context. Different trace sampling, an ended parent or
a different caller deadline must never change deduplication or wake eligibility.
This also corrects the current-path metadata coupling at the same seam.

The intended path remains:

```text
caller registration ─┐
caller registration ─┼─> one queued / parked / active verification job
later caller ────────┘           │
                     resident session or one cold reconstruction
                                │
                     existing page/chain/exact-entry verifier
                                │
                     install verified state → wake live callers
```

A caller leaving is not job failure. A completed cache job is not a durable
write outcome. Trace completion is not proof of either.

## 4. Lifecycle contract and explicit behavioral changes

This section's behavior is approved with its stated proof conditions. The
completed implementation still requires review; context carriage alone must
not silently exceed this behavior.

### 4.1 One original deadline per caller

Capture the caller's absolute monotonic deadline before its first owner call.
Carry that deadline through admission, queueing, joins, parking and completion;
never renew it at dispatch, cache open, page decode or re-entry to the owner.
The existing timer expires a registration; it is not the authority for whether
the deadline has passed. Check the deadline in the owner before publishing a
result even if the timer message is still queued. Check again at the public
return boundary, as A1 does. Retain the existing public error grammar.
Existing explicitly owned infinite local borrows keep their reviewed source-
death lifetime; do not convert them to a new default timeout or extend infinity
to routed/network requests.

Reuse the existing caller map, expiry messages and exact-PID call boundary;
remove the relative-only representation in the touched common admission/reply
seam. Different callers retain independent deadlines. Owner unavailability,
expiry and malformed requests get distinct diagnostic causes without inventing
new public errors. No success is backdated to its worker completion time.

**Behavior change:** queued owner time now consumes the caller's original
budget, and an expired caller cannot receive late success because of mailbox
ordering. This is not timeout tuning; no numeric budget changes.

### 4.2 Shared work has a different lifetime

An admitted exact job remains an owner-owned cache-verification obligation,
including when all its current callers have expired. Preserve both active and
runnable queued callerless progress, not callerless route-parked retention.
An admitted row waiting only for writer custody keeps that obligation; it is
not a route failure, and expiry must not silently drop it. A later
equivalent caller can join that job; its
fresh caller registration does not restart the worker or change its budget.

Do **not** activate the nominal follow-derived 17000 ms allowance as a global
exact-job kill timer. It is not enforced today. The observed 27-second invocation
was current-view work, not exact work: it demonstrates that the shared cold-
rebuild mechanism can exceed that allowance. An equivalent exact rebuild could
be killed before resident installation and recreated from zero on every demand.
Exact verification uses its existing bounded transport/page operations and
single-pass route walk, then succeeds, fails definitively or returns temporary
unavailability. It has no independently established whole-job time bound.
Long local replay can therefore outlive a caller. This remains a performance
problem to measure, not an excuse to label the worker bounded or make it loop.

Remove misleading exact-only timeout threading/comments that imply a global
deadline; preserve the actual current-view probe and follow bounds unchanged.
Delete `remaining_work_timeout/2`'s non-follow clause with the obsolete exact
threading; do not retain a dead fallback clause.
No new duration setting, infinite page call or recurring background attempt.
On temporary failure, callerless work retires under the existing rule; work
with remaining interest parks until a genuine progress edge. A caller's timeout
does not itself create another attempt.

### 4.3 A progress edge cannot disappear between running and parking

Before work that may park, establish the existing exact-identity subscriptions
and re-check the current route/resident state in the same owner. While an
attempt is active, retain one coalesced permission if a relevant accepted
directory/feed/commit event arrives. Reuse the existing follow consume-once
discipline; no second event service or registration registry.

When an active attempt returns temporary failure:

- a buffered external edge allows one runnable turn through the existing queue;
- without one, park normally;
- consume the permission at dispatch; failure and elapsed time do not restore it;
- this job's own unchanged metadata installation is not a new external edge;
- clear/retire this attempt by its existing worker correlation before a successor
  can own the same cache.

Use the existing admitted event classes and exact identity/incarnation checks.
Do not promote arbitrary duplicate hints into progress, retain a second route
table, or make every no-contact caller join into a wake. The existing same
authenticated-contact reattachment rule remains an availability edge.

**Behavior change, subject to a failing regression:** an edge accepted while
work is active survives its subsequent transition to parked. A synthetic
schedule must fail before the change; if existing ownership already closes
the schedule, keep the existing implementation and trace it rather than add
redundant state.

Q4 is not closed: after a genuine terminal failure, recovery of a quiet
same-PID source with no subsequent event is still not guaranteed. There is no
feed ACK change, periodic resend, self-wake loop or new consensus redrive here.

### 4.4 Worker custody and restart boundary

Caller detachment must not kill shared work; death of its actual foreign-log
owner must not leave an orphaned cache writer. The current worker is monitored
by the owner, but that is not a reverse lifetime guarantee. Test owner death
while the worker is held in replay, fetch and result handoff, not only in a
receive loop. Reuse the existing directional process-ownership helper if the
gap reproduces; do not create a cleanup service.

Within a live owner, keep cache custody until the worker has stopped writing
and released/transferred its session, using the existing result/DOWN protocol.
Trace a result handoff separately from worker termination. Never release an
identity merely because `exit(Worker, kill)` was sent.

**Restart proof obligation:** an asynchronous owner-death watcher alone does
not prove an old writer and a replacement owner's writer cannot overlap.
Ledger open/resume and phase scratch sessions currently provide no such
exclusion: a session's end-of-file check is not a custody handoff. The
implementation review must establish this at the existing cache/session and
supervised-process seams, with a held-old-worker/replacement test targeting
**two writers appending to the same cache ledger file**, not merely two live
processes. That stop condition was reached and the
[existing-worker custody registration](foreign-cache-writer-custody-contract.md)
was returned for review and approved. Implement that bounded extension in
this same cut: atomic worker registration before cache mutation, actual death
release, retained admitted custody waits, and session-safe cleanup. Preserve
the permanent gproc application failure boundary, distinguish server restart
from table-owner death, and never park without an installed wake monitor.
Any further exclusion mechanism returns for review; it is not authorized by
calling it cleanup. The local implementation evidence is recorded separately
in §7; it is not hardware acceptance or a latency claim.

## 5. Trace the same lifecycle, not a second execution

### 5.1 Shared parenting and correlation

Carry local context through the existing request/caller rows for routed exact,
explicit-source exact, borrowed-local exact and current-view requests. Use
`quod_trace:shared_context/1`: first recording parent, links to the other valid
participants, no arbitrary ambient baggage and no manufactured sampled root.
No proposal/DTX/catch-up wire carrier is added.

Each caller has a wait span under its own context. At dispatch, start one worker
span under the selected shared context, with launch-time participant links.
Keep that worker parent fixed. A late caller links its own join/wait span to
the existing attempt; it does not reparent or rerun that attempt. The current
SDK has no established dynamic-link mechanism in this code: do not pretend
late participants were launch-time links. A late sampled join to unsampled
work establishes correlation, not recovery of missing earlier children.

Retain only the stripped span/correlation metadata needed by the existing
live job/callers. Removing a registration ends its owner-residence span, not
the caller-owned API wait: that ends at actual return, preserving delivery
delay. Removal does not erase the active job's trace identity. No completed-
result/trace cache. SDK link/event
truncation is reported, never silently treated as complete participation.

Use an opaque process-local job correlation and attempt ordinal in spans,
not public metrics labels or serialized Erlang references. Include exact
identity/anchor, requested slot, expected phase and admitted worker incarnation
where required for correlation, without serializing goals, signatures, entry
bytes, keys or exception terms. Closed outcome/reason labels only. Real returned
reasons are mapped before the existing `retry`/`abstain` collapse; mapping must
not change or catch away the production result or exception.

### 5.2 Required intervals and causes

Extend the existing stage helper; keep already-covered page delivery/decode,
ledger and phase-index spans. New observations cover these missing seams:

| Interval / transition | Required distinction |
|---|---|
| Caller admission/wait | API dispatch→owner admission, queued, parked, joined-active, reply; own deadline and expiry observation |
| Job dispatch and finish | Fresh job vs same job/new attempt vs joined surviving attempt; exact worker PID/incarnation |
| Route selection / park / wake | No route, anchor conflict, accepted event class, edge buffered/consumed, no-progress result; no raw endpoint dump |
| Whole cache open | Resident resume vs cold disk reconstruction vs a failed resume requiring recovery; includes ledger/index opening before `open_replayed_cache/8` |
| Cold reconstruction | Phase open, replay, checkpoint comparison, cleanup; trace the entire `open_replayed_cache/8`, not just the fold |
| Certified fold | Existing page fetch/decode, chain/finality validation and phase-index work, using page-level intervals/counts rather than one span per fact |
| Exact-entry validation | Entry lookup and existing slot/hash/digest/committee-era validation, outcome and duration |
| Worker handoff | Ledger/phase suspension and worker result send, followed by owner result installation and caller wake |
| Terminal events | Caller expiry, page expiry, link/source/worker/owner death, malformed reference, no-route, unavailable and unclassified failure |

Keep worker computation and owner installation as distinct linked intervals;
their waits overlap. Never add them twice to a request total. A worker span
ending before `close_worker_cache/1` is not the whole attempt. Add a closed
cause at the producer before Simplex maps its response to `abstain`; do not
change Simplex's approval/redrive grammar to make the diagnosis easier.

Record separate starting resident height, disk cache height, disk entries
replayed, network entries fetched/verified and final installed height.
`Resident = none` does not imply an empty disk cache. The existing
`verified_suffix = final - resident` includes replay after restart and must
not be presented as network traffic. Correct its documentation/consumers or
replace that ambiguous diagnostic field in this cut, with no compatibility
metric kept merely to avoid updating the analyzer.

No per-request state/ledger scans to obtain diagnostic attributes. Timing is
local monotonic elapsed time, not CPU; cross-node spans establish causality,
not a calibrated network latency. Preserve unknown time explicitly.

## 6. Non-vacuous implementation gates

The approved implementation uses production seams with
message barriers and trace-delivered barriers, not sleeps as progress drivers.

1. Different contexts (sampled, unsampled, ended, missing), same semantic work:
   identical active/queued/parked sharing and route/wake/worker counts. Different
   authenticated contacts, entry hints and borrowed views preserve current
   non-sharing behavior. Positive controls prove the observer hooks execute.
2. Hold the owner before admission and again before reply. An already-expired
   absolute caller cannot receive success even when worker completion is queued
   before the timer message. A second live caller still gets the verified result.
3. Callerless active **and runnable queued** jobs continue as currently promised;
   a callerless route-parked row still retires, whereas an admitted custody-
   blocked row retains its obligation. A new
   caller joins surviving work without another fetch, deadline renewal or vote.
   Exercise the block-1059-shaped six-second caller loss using controlled
   deadlines, not a real six-second sleep.
4. Edge before subscription, during execution, immediately before temporary
   completion, while parked and after replacement. One buffered genuine edge
   gives one attempt; wrong identity/incarnation and unchanged self-install give
   none. No new edge after repeated failure means no autonomous attempt.
5. Dead source, dead worker, dead owner and replacement during replay/fetch/
   handoff: test lifetime and cache-custody exclusion at the same ledger-file
   append seam explicitly, with the extension's separate server-restart,
   permanent-application failure and phase-session cleanup tests. Late results,
   timer messages and trace callbacks are inert for replacement rows.
6. Join/reply/expiry race with real SDK spans: one physical worker trace, linked
   independent caller waits, late caller correlation, no ambient baggage leak,
   no duplicated spans presented as duplicated execution. Exception class,
   reason and stack remain unchanged; sensitive sentinel absent from export.
7. Nonempty disk cache with no resident projection: exact and current paths
   show cold replay plus checkpoint validation and suspension/install. A changed
   checkpoint must reject that cache reconstruction; the existing subsequent
   certified recovery may still make the public request succeed. Tampered
   entries and wrong-era proofs cannot authenticate the claim. Warm resume
   proves zero cold opens/replay with a trace positive control.
8. Restoring each former defect in an isolated negative control fails its
   intended invariant. A missed trace hook must fail coverage, not yield zero
   measured work. Preserve A1 full-open and Cut-2 artifact AST guards unchanged.
9. Full clean-build sequential EUnit, ask CT, QUIC CT, Simplex CT, xref,
   dialyzer and diff-check; report true exit codes and any cancelled fixtures.
   Review the completed cut before commit/deploy. Focused fail-before and
   registry tests do not substitute for these complete implementation gates.

## 7. Capture, simplification and review boundary

### Pre-implementation checkpoint — 2026-09-09

All cases below ran against the baseline in isolated local VMs, not the fleet.
That campaign left production and repository test sources unchanged. This is fail-before
evidence, not a green implementation gate or latency improvement:

| Contract case | Observed baseline behavior | Control / consequence |
|---|---|---|
| Original caller budget | Public exact request budget 100 ms; owner held 150 ms; returns `ok` at 154 ms | Normal same-budget request succeeds; late success violates §4.1 |
| Completion/timer ordering | Historical-local request budget 500 ms; completion queued at 3 ms, processed before timer after expiry; returns `ok` at 551 ms | Actual owner queue order `[done, timeout]` captured; timer arrival cannot replace deadline check |
| Metadata-independent sharing | Same-context parked requests share one row; different trace/sampling contexts create two | Different-context active requests still share one worker; parked equality defect isolated |
| Edge while active | Exact route event processed during real worker attempt; subsequent retry parks the same job, attempts remain one | Same event after parking starts the second worker and verifies; five controls pass, intended regression fails |
| Restart file custody | Old and replacement workers both append after real reservations, same inode 755240/offset 1027, watcher installed but delayed | Watcher processed before replacement prevents old append; resulting custody extension subsequently reviewed and approved |

Budget/equality focused assertions: **3 expected failures / 2 passing controls**,
exit 1; `/tmp/quod-exact-deadline-failbefore-dAcEia/HANDOFF.md`.
Wake runner: **1 intended failure / 5 passing controls**, exit 1;
`/tmp/quod-wake-before-park-2j0s36/HANDOFF.md`. Its synthetic existing directory
message tests the consumer's ordering, not the hardware event's producer.
Custody reproduction exits 0 because it asserts that overlap occurs;
`/tmp/quod-custody-probe-vlt6hN/result.json`. Identical certified bytes were
written twice, so writer exclusion is refuted but corruption is not claimed.
Harness bootstrap/compile errors are retained and corrected in their artifact
directories; crash dumps are private scratch artifacts, not report attachments.

The three review text corrections are folded in: parked equality explicitly
pins `supplied/contact/kind`; obsolete non-follow timeout threading is named
for deletion; restart tests observe the actual cache ledger file. The custody
extension's subsequent approval preserves one coherent cut and its final review
boundary; it does not turn this baseline failure evidence into passing gates.

### Implementation checkpoint — 2026-09-09

The one cut changes `quod_foreign_log`, the existing phase-index cleanup seam
and one `quod_reg` key. All arrivals now enqueue through the same selector;
the separate immediate-dispatch/route-park path is deleted. Distinct routes
still bypass an unavailable-route park, but never an identity-wide custody
wait. Cancellation marks the existing worker retiring before later denial or
result messages can requeue it. Removing a parked follow re-drives its queued
sibling; discarding an unverified idle history first retires its feed signals.
These integration corrections have failing earlier-snapshot controls, not
only assertions against the repaired tree.

Absolute caller deadlines, observation-free `supplied/contact/kind` equality,
buffered external edges and worker-name custody replace their former paths.
No exact-path whole-job timer is activated. Cold replay/checkpoint comparison,
page/probe work, cache suspension, result installation and per-caller owner
stages now have local causal context. Producer-side stage ordinals/counts and
shared job/attempt IDs make missing coverage detectable. Closed route reasons
distinguish no route, anchor conflict and no accepted progress edge; source
death, worker death and caller expiry are separate observations.

Page terminal observation also belongs to its existing owner: one admission
child records the expected terminal, and the existing `page_completion_owner`
span now covers the successful row removal for every terminal path, not only
decode success. It records the closed cause and queued/sent/decoding turn,
including link death after raw delivery consumed the reply alias. A stale
completion cannot create a second terminal child. The parent may already have
ended after the puller's own deadline; the owner creates its child from the
retained context rather than attempting to rewrite that worker-owned span.
Worker-side original-budget checks annotate their own active span separately.
Unexported/killed parents remain incomplete traces, never inferred successes.

Focused evidence is preserved at:

- `/tmp/quod-lifecycle-focused/HANDOFF.md`: 21 lifecycle/SDK regressions plus
  119 existing foreign-owner tests passed together; five single-site negative
  controls fail their intended assertion while matching controls pass.
- `/tmp/quod-custody-final-OdU40Z/HANDOFF.md`: 17 actual file/registry/watcher
  schedules pass, including the same-inode watcher-only negative control;
  five additional queue/cancellation defects have earlier-snapshot failures.
- `/tmp/quod-foreign-job-trace-check-ZaaWU1/HANDOFF.md`: eleven SDK tests
  pass, including terminal page coverage after parent export, decoding-time
  link loss and duplicate completion; restoring metric-only replay fails the
  child-coverage assertion.
- `/tmp/quod-foreign-registry-u9fT6w/`: three real registry/application-lifetime
  tests pass, distinguishing restartable server loss from permanent-app exit.

The initial clean run in `/tmp/quod-exact-owner-gates-1WoS4m/` passed EUnit
1934/0, Ask and QUIC 26/26, Simplex 12/12 and xref, then stopped with 11
Dialyzer unmatched-return warnings from two diagnostic span-ending helpers.
The shared helpers now explicitly return `ok`. The final page-lifecycle
coverage audit also found and closed the terminal-cause gap above. A proposed
owner update of the worker's span was discarded: it loses observations after
span export and can race SDK attribute updates. No such shared-span write
remains. The final clean-build sequence in
`/tmp/quod-exact-owner-final-0PKNbG/` completed unsandboxed and sequentially
on the unchanged production/test tree, with `ERL_FLAGS='+S 4:4'`:

| Gate | Final result | Exit |
|---|---|---:|
| EUnit (`-v`) | All 1937 passed | 0 |
| `quod_ask_SUITE` | 26/26 | 0 |
| `quod_quic_SUITE` | 26/26 | 0 |
| `quod_simplex_SUITE` | 12/12 | 0 |
| xref | clean | 0 |
| Dialyzer | clean | 0 |
| `rebar3 as prod release` | built locally; gproc starts permanent | 0 |
| `git diff --check` | clean | 0 |

The prior `_build/test` was moved into that archive before the fresh build.
`run.sh`, per-gate logs and `exits.tsv` retain commands and true exit codes;
`source.sha256` pins the gated source/test tree. Only this result recording and
review handoff were finalized after the sequence; diff-check is repeated after
those document edits. These local gates are not the independent final review.
At this local-gate checkpoint no commit, version bump, deployment or purge had
occurred. Final independent review subsequently closed on 2026-09-10; it makes
no hardware performance claim or change to any other open architecture gate.
The five write-lanes files remain excluded from the implementation.

### Hardware capture after implementation review

Use the existing source/target N=4 fixture and preserved ledgers after code
review. Begin with a short signed read sanity check and a small diagnostic
window; archive stdout and stop on failure. Do not silently clear the old
`BENCH_STOP`, call a preflight retry loop a once-only probe, or retry an
uncertain execute. Ordinary requests may overlap ordinary autonomous receipts;
there is no receipt injection or duplicate-only benchmark path.

Do not enable fleet-wide 100% owner roots to obtain exact-reference children.
Use sampled request/job contexts at the existing owner, retaining trace IDs and
their links. Check backend capacity/health first; the temporary live Tempo
memory/placement override is documented in the hardware report, not evidence
of sustainable full sampling. Do not silently change it in this cut.
The separate owner-turn instrument still requires its own off/on comparison
and complete-root-and-child retrieval if it is used to claim occupancy.

For each captured exact job, retain admission, join, budget, route, page,
replay, exact-verdict and installation events. Specifically discriminate:
caller expired while same job survived; genuinely parked job; new attempt;
owner queue delay; cold replay; missing/late page; definitive bad proof. A
terminal clock can end a wait, but cannot be credited with ordinary progress.

Report distinct partitions for each caller's actual API wait and each worker
attempt, with those local durations as their respective denominators. The
numerator is the interval union of attributed, non-overlapping stages within
that interval, not the enclosing wait/worker span itself. Queue/park residence
is distinguishable waiting, not exclusive function or CPU attribution. Shared
work counts once in job totals and only its overlap in each caller partition.

Require at least 95% coverage on sums/means before a new causal optimization
claim; show every retained request/outlier's residual as well, so the aggregate
cannot conceal an entirely unexplained tail. A threshold does not itself prove
causation. Missing children, dropped attributes/events/links, sequence gaps and
unclassified reasons invalidate a completeness claim; retain an unknown bucket.
Short stage spans avoid relying on an append span that already lost 64 events.
Require producer-side expected child/transition counts or ordinals, terminal
and boundary reconciliation, and export controls; observed-span counts alone
cannot detect a wholly missing child. Keep this diagnostic metadata in existing
transient spans/rows, not a new journal or collector. Without that evidence,
report partial coverage. `multi_time_warp` is not whole-window calibration and
cross-node timestamps are not subtracted as though they were one clock.

### Deletions and expected benefit

Replace, rather than layer over: whole-record equality sensitive to tracing;
relative-only caller metadata/reply handling; exact-work context-discard
clauses; misleading shared-work-timeout claims; metric-only cold replay and
out-of-span handoff gaps. Consolidate any changed expiry/reply/wake logic at
the existing common owner. Keep distinct authority requirements for exact,
current and follow work; sameness of lifecycle is not sameness of proof.

Expected structural benefits are stable coalescing regardless of diagnostics,
no late success after a caller deadline, no lost already-accepted progress edge,
and reusable work surviving caller expiry without orphaned ownership. None is
yet a measured latency improvement. No promise that tracing or cleaner lifetime
alone makes the six-second cold verification fast.

### Exact document amendments when implemented

- This contract: mark decisions, implementation review and measured outcomes
  separately; do not overwrite 0.7.157 evidence with later numbers.
- `quod_foreign_log` moduledoc and equality/budget/worker comments: actual
  caller versus shared-job lifetime and single semantic comparison.
- `doc/catchup-page-credit-plan.md` §6.1: clarify that the original absolute
  deadline belongs to the borrowing operation; a detachable caller is not
  automatically the owner of shared exact cache work. §6.2/Q4 stays intact.
- `doc/phase-1b-codec-and-pull-contract.md` §1: shared-worker versus immediate
  puller cancellation remains unchanged; link to the clarified caller lifetime.
- `doc/performance-roadmap.md` status and §4: this approved coherent cut is next;
  numeric performance and all separate architecture gates remain open.
- `doc/consensus-owner-turn-hardware-results.md`: record external evidence
  approval and point to this contract; keep every failed capture and residual.

Both the tracing/metadata and explicit behavioral contracts in
§4.1/§4.3/§4.4 are approved as one coherent owner cut. Establish the required
failing regressions, implement within those conditions, and review the final
tree before commit/deploy. The separately reviewed existing-worker custody
extension is included; any further new protocol returns for review.
No new owner/cache/verifier/ACL/cap/poll/wire format or
cryptographic shortcut. Backtracking, frozen proof bases and target ACLs stay
untouched. Result authentication, Q4, finality, L2, compaction, the old outlier
and the unmeasured 10k behavior retain their own gates.

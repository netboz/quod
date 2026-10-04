# Shared history latency — proposed optimization plan

Status: reviewed investigation plan, 2026-09-22. Source base: .224
`d84d0db9fa32d4ec7bbaf629b5e713b9ecbb2e17`. No implementation, deployment,
protocol change or data reset accompanies this plan. The settled architecture
and protected residency/performance/write-lanes documents remain unchanged.

**Historical status — 2026-09-24.** The selected work was implemented and
measured in the subsequent .225/.226 releases. Keep this document as the
decision record for that campaign; its "ready to run" language is not current
authorization. Consult `multiwrite-architecture.md`, `performance-roadmap.md`
and the later handoff sections for the resulting state.

Step A is ready to run. Step B requires its result and an exact replacement /
deletion map before implementation. Step C is deferred: an existing progress
subscription does not bound acquisition to one operation's required history.
This is not approval of an as-yet-unselected production change.

## 1. Recommendation and limits

Keep the current owners, certificate rules and .224 routing cleanup. Work on
the shared missing-suffix acquisition pipeline, not another consensus rewrite.
First reduce demonstrated processing or waiting inside that pipeline; then
consider overlapping acquisition with existing useful work. Do not permanently
follow every retained identity to hide the next request's cost.

The evidence is `_build/causal224-BJrWzL/REPORT.md` and its frozen manifest.
One atomic block required source slots 3490–3565: 76 missing entries, 2.413 MB.
Three validators spent 647–779 ms obtaining them; another validated in 28 ms
and waited for its committee. Owner delivery overhead was below 1.6 ms. This
is not evidence of a lost gproc wake. The same missing-prefix dependency exists
in both .223 and .224 under controlled identical inputs.

Of each slow acquisition, 421–502 ms is page acquisition INCLUDING decoding,
202–256 ms is forward verification, and the remainder is mainly persistence.
The first bucket still lacks its exact hardware breakdown. Local profiling
finds 363 signature checks, all distinct within their respective pages, and
84.5 ms median decode alone. Do not propose removing these distinct checks on
the assumption that the old nested-decode defect remains.

No claim yet that a new change will save 500 ms, that the remaining steady-state
old/new difference is explained, or that moving work earlier reduces total
work. Those are acceptance questions below.

## 2. Existing components to reuse

| Responsibility | Existing implementation | Required disposition |
| --- | --- | --- |
| Hosted evidence | `quod_simplex:history_view_at/3`, `quod_foreign_log:resolve_reference/6` | Hosted identity stays local; lag waits within its original deadline. Never route away merely to avoid a wait. |
| Foreign ownership | `quod_foreign_log` history/request rows and `{foreign_cache_writer, Identity}` gproc name | One prefix and one exclusive writer per anchored identity. No cache beside it. |
| Demand and remote progress | `follow_request/2`, `unfollow_request/1`, `open_progress_signals`, authenticated `quod_feed` registrations | Reuse `progress`, not `projection`; asynchronous registration and monitored lifetime. |
| Local notification | `quod_reg:subscribe/publish`, existing direct owner/consumer messages | gproc is local pub/sub. Existing feed/QUIC transports remote events; do not invent distributed gproc messaging. |
| Page transport and decoding | `admit_pull`, `fetch_page_raw`, `decode_pulled_page`, `quod_catchup:decode_entries/2` | Decode in the requesting worker, never the node-wide owner. Keep link credit, bounds, exact completion key and deadline. |
| Verification and installation | `prepare_verified_page`, `quod_catchup:verify_forward/6`, `persist_verified_page` | One contiguous forward verifier; append and phase-index installation before publication. |
| Result reuse and wakes | `install_verified_progress`, `release_ready_readers`, `notify_follow`, `ack/2` | Existing immutable prefix serves covered readers, including queued readers. No new result cache or waiter queue. |
| Operation lifetime | Existing Simplex owned rows and `quod_dtx_coordinator` waves/follows | Preserve durable obligations, target-scoped resumes and cancellation; do not start an additional recovery engine. |

These are shared mechanisms, not interchangeable authorities. Authenticated
transport, decoded signed bytes, a certified history prefix, a fresh identity
view and a durably applied result remain different things.
In particular, `follow_request(progress)` follows an advancing tip; listing it
here does not authorize using it as a bounded prefetch request.

## 3. Step A — close the measurement needed to select the change

Use one bounded diagnostic experiment, not another broad fleet campaign.

1. Replay the same captured pages against equivalent verified starting state.
   Include missing and covered prefixes, one/four callers, and both lane types.
   The previous one-voter fixture proves acquisition/coalescing counts, but its
   transport supplies decoded artifacts: it is not the wire-cost experiment.
2. Join the existing `page_wait`, `page_decode`, `page_completion`,
   `page_verify`, append and checkpoint boundaries by identity, worker/request,
   page range and owner incarnation. Carry or observe ancestry through the
   existing worker spawn and page grant; do not add a tracing process per job.
3. Within `page_wait`, distinguish local admission/link-credit residence,
   transport plus serving work, and return dispatch. Use same-process/host
   durations; do not subtract unsynchronised host clocks or sum parallel spans.
4. Count work separately in decoding and forward verification: signature input,
   historical committee binding, entry/block materialization and phase-index
   preview. Signature identity counts alone never justify skipping a membership
   check or a check under a different enclosing reference.
5. Record per-replica routing: hosted versus foreign, starting prefix, demanded
   reference, installed tip, active consumer and worker. An absence of captured
   foreign-page events does not establish absence of hosted validation.

The experiment retains an independent start/completion denominator and every
failure. Ties, dropped events and missing ancestry are named exclusions with
the original denominator retained. Trace-off operation must be identical.
Add only bounded diagnostic detail if the existing spans cannot carry the join.

Exit: partition the acquisition interval and, if a removable component exists,
reproduce it through the production seam. Name the exact calls/transitions to
replace, the checks that remain, the code to delete, and the regression oracle
before Step B. If the measured work is required or attribution is incomplete,
report that; do not manufacture a cache or remove verification to meet a
predicted saving. The existing 363 distinct per-page checks are not themselves
evidence of redundant authentication.

## 4. Step B — one authenticated page pipeline

Candidate scope, not a selected fix: reduce work within the SAME acquisition,
so atomic writes, independent writes and reads can all benefit. Measurement
must justify the specific replacement; this list is not authority to implement
all three alternatives or to combine separate hypotheses into one patch.

Select the exact edit from Step A, rather than implement every possibility:

- If the same authenticated envelope/artifact is reconstructed or checked again
  at a downstream seam, carry the existing opaque material through that call
  and replace the reconstruction. Its receipt proves only its original bound
  bytes/signature statement. Exact reference, identity, committee era, sequence,
  finality and freshness checks remain at their own boundaries.
- If page credit is held after its current completion condition has already
  been satisfied, fix that owning transition and send its existing exact wake.
  Do not release credit on raw arrival: decode acceptance, link identity,
  cancellation and late-reply rules still govern it. If credit is legitimately
  held, it is not a lost wake and this edit is not justified.
- If queueing or repeated serving/materialization is responsible, remove the
  duplication at its current owner. Do not add a general worker pool, speculative
  page look-ahead, concurrent cache writers or a second scheduler. Existing
  coalescing and published-prefix reads already work and must not be rebuilt.

Do not extend authentication reuse across pages or requests. The page-local
decode context remains local, opaque and non-wire. A stronger certificate-reuse
mechanism would need its own exact binding proof before inclusion; a decoded
transaction is not a validated finality certificate.

The replacement must flow through the current exact/current/follow pipeline,
including hint-assisted acquisition and error handoff. No permanent old/new
selector or atomic-only bypass. Delete superseded calls/helpers/exports and
exclusive comments/tests in the same scope, preserving their valid obligations
on the remaining implementation.

## 5. Step C — earlier demand, deferred

Do not implement earlier subscriptions under this plan. The intended benefit is
overlap of REQUIRED work, not elimination of verification. It cannot guarantee
a zero-cost request after a genuinely idle gap.

Current facts matter:

- `follow_refresh_needed` requires a real consumer. A current-view watch keeps
  feed freshness observations but deliberately does not continuously download.
- An active progress consumer follows the advancing tip: after a verified page,
  `continue_follow_progress` can schedule another on a higher tip or dirty edge.
  It has no operation-specific stopping height. A group waiting for another
  target can therefore keep downloading unrelated later blocks. A real owner
  and eventual unsubscribe alone do not bound this extra work.
- Coordinators already own progress-only follows while waiting for targets.
- A non-source atomic role's recovery driver is only selected AFTER the vote
  deadline (`quod_atomic:recovery_rows/2`). There is not an already-running
  participant coordinator to casually reuse on the healthy path.

Reopen this option only if Step A shows useful overlap and a concrete design
answers all of the following without another queue, owner or recovery engine:

1. Which already-authenticated operation proves the dependency, at what exact
   reference/height, and how early is it known? Do not substitute the current
   tip for an unknown future requirement or count overlap that does not exist.
2. Which existing PID/incarnation and authoritative row own acquisition,
   cancellation and its original deadline? Record attach, satisfaction and
   release events. Do not start participant recovery before its ruled deadline.
3. How does satisfaction end this additional demand even while the operation
   remains alive, without detaching another consumer or losing durable duties?
   Reusing the unbounded progress subscription until terminal completion does
   not answer this. No new bounded-follow mode is prescribed here.
4. Does it reduce client-critical time without inflating total bytes, crypto,
   writer residence or the other lane's latency? Test an advancing unrelated
   tip while one target stalls, as well as ordinary completion and cancellation.

Any later design keeps subscription-before-snapshot ordering, correlated
owner-incarnation notices, coalesced wakes and one writer. Use `quod_reg` for
shared local events and direct messages for known recipients; remote feed
events remain authenticated wake hints, never authority. Finish custody-held
verified-cursor handoff on detach, preserving .222; original caller deadlines
and other callers' work survive unchanged. Final validation still uses the
ordinary evidence interface, with no Prolog-state copy or freshness shortcut.

No background fetch merely because a cache exists or a current-view watch is
stale. No change to voting/parent eligibility, recovery activation, or O-only
outcome authority. If these lifetime questions require additional machinery
whose cost outweighs measured overlap, reject this option rather than add it.

## 6. Regression and deliberate-bug controls

Keep existing page-credit, custody, freshness, decode-receipt, ready-reader and
proof-semantics suites. Add controls through production seams, not replacement
verifiers or sleeps:

| Case | Required oracle |
| --- | --- |
| Sufficient published prefix; one/four exact-reference callers | Zero page fetches and zero writer starts; same exact result. This is not a current-view freshness or progress-follow oracle. |
| Same exact missing reference, four callers, healthy transport | One shared suffix acquisition per identity per node, no per-caller duplicate page decode. Keep each caller's binding/deadline checks; distinct replicas verify independently. Route failure/recovery is a separate case, not forbidden by the one-acquisition count. |
| Atomic → independent → atomic, and reverse | Starting prefixes and exact references recorded on every validator; total and client-critical work separated. No gain hidden by warming or dropping the first batch. |
| Advance during subscribe/snapshot, duplicate and reordered messages | No lost wake, no wake storm, no authority from a feed hint; foreign-owner incarnation and exact identity checked. |
| Stop one/all consumers during queued and custody-held work | Correct detach and no fresh background jobs after demand ends; verified cursor returned, no rebuild caused by unsubscribe. |
| Owner/worker/link death and restart | Old grants/results cannot be installed by new owners; published reads survive as specified; one mutator through actual DOWN. |
| Invalid page bytes, nested signature, chain/anchor or historical-committee binding | Same typed refusal; invalid material never installed. Preserve the last sound persisted prefix, including earlier valid pages; post-mutation inconsistency takes the existing fail-closed custody path. |
| Valid suffix, invalid requested phase/digest or enclosing reference | Caller still refused; the healthy verified prefix remains reusable and may be published. Only genuine advancement wakes dependents; unchanged retained state cannot mint retries. No successful certificate or fresh-view result from failed binding/confirmation. Test missing and covered prefixes. |
| Known higher tip, opaque progress, committee change, revocation/apply fence | Same current-view quorum/freshness and attestation rules; historical sufficiency cannot impersonate a fresh view. |
| Different deadlines, queued late success, cancellation and unavailable peer | Original budgets preserved, no second submission instance, no timeout retry loop. |
| Independent N=1/N>1, mixed verdicts; atomic conflict/abort; proof cuts/savepoints/effects | Existing terminal/result, authorization, custody and proof semantics unchanged. |
| Large/implicit-child pages and page-boundary duplicates | Real payload and byte limits; canonical bytes identical; page-local receipt cannot escape its scope. |
| Unrelated identities and idle retained caches | No unrelated wake, owner responsiveness preserved, zero perpetual warming; transient jobs/handles do not leak with completed groups. Retained ledger/history bytes are not such a leak. |

Each implementation has a named counterexample that fails on the old code (or
a precise deliberate-bug variant), plus positive controls. Do not call a
synthetic one-voter timing test a full consensus witness.

## 7. Measurement, publication and rollback

Run old and candidate against equivalent isolated initial histories/cached
prefixes and identical workload shapes. Alternate run order; keep all samples.
Do not replay a signed uncertain operation on the retained production fleet.
Use fresh diagnostic namespaces or disposable local fixtures for resettable
states; production data remains preserved.

Compare atomic/independent c1 and c4, local/remote reads and one-target writes.
Include mixed sequences, zero/short/76-entry/larger gaps, and one unavailable
peer. Then extend to c8 only after the bounded witness and resource checks pass.
Record mean, median, tails/max with sample counts, 503/uncertainty counts,
per-node bytes, signatures, worker starts, prefix lag, queue residence, CPU,
memory and restarts. Separate post-start, settled and lane-transition cohorts,
but never exclude them from the overall result.

Define performance acceptance margins from repeated baseline variability before
running the candidate; do not widen them after seeing a regression. A small
sample cannot establish tail non-regression. Structural work-count controls
are mandatory even when latency improves. If a change only shifts cost from
atomic requests to independent work or idle time, report that explicitly and
reject it unless the full workload meets the predeclared acceptance criteria.

One causal implementation scope at a time, with its deletion ledger, full clean
sequential gates, full logs/true exits, failure triage and exact-tree freeze.
Separate implementation and label commits. No routine re-review per minor edit;
review the complete candidate at the standing boundary. Deploy only committed,
gated artifacts; preserve ledgers/identities, verify retention/health before and
after, and use fresh campaign labels with STOP/BENCH_STOP untouched.

If the candidate has a reproducible regression, withdraw that scope and return
to the known image/tree under the existing coordinated deployment procedure.
Do not revert unrelated accepted fixes or erase failed evidence. No format or
protocol break is planned, so no wipe or compatibility decoder is justified.

## 8. Completion and cleanup

Completion requires a demonstrated causal saving with the mixed-workload
regressions green, not just another passing deployment. Audit runtime and
dynamic callers before deleting code. Record actual changes in production
lines, functions, exports, state fields, process count and message types.
Do not hide growth by moving code or deleting coverage.

Update only current invariants in implementation docs. In particular, the
`hibernate_history` comment saying first use verifies disk fully is stale
relative to startup initialization and should be corrected in the touching
scope. Keep benchmark numbers and failed-attempt narration in the handoff.
Do not edit Yan's protected plans or the pinned architecture prefix.

This plan promises no numerical speedup. The immediate deliverable is the
bounded selection experiment; a shared-pipeline refactor requires its evidence
and deletion map. Earlier demand stays deferred. The release/rollback controls
cover both lanes; no new protocol, cache, executor or polling mechanism is
proposed.

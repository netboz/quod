# Verified-history lifetime across failed route attempts

**Architecture review approved — 2026-09-10, baseline `c2bf308`, 0.7.159.
The single residency/observation owner cut is implemented and locally gated.
The complete tree must return for implementation review before commit or
deployment; no performance gate is closed by these local results.**

## 1. Evidence and the problem to solve

The [warm multi-writer pilot](multi-writer-warm-hardware-results.md) passed
20 serial conserved transfers but stopped under concurrency: one committed
client reply and four pending replies among five admissions. A later caller
spent 47.056 seconds queued for foreign history and 5.961 ms actually verifying.
Scrape-bound counters record ten additional replay completions across five
nodes after the pre-c4 samples, despite all-node warm preparation. They do not
identify which job or foreign identity caused the queue. Missing L3 context
prevents exclusive phase attribution. These are separate knowns, not a complete
causal proof.

An isolated probe establishes one genuine amplifier on unchanged source:
`/tmp/quod-exact-route-replay-probe-DIys3I/HANDOFF.md`. A resident certified
Prepare at height 2 followed by a Finalize request at 3 has these outcomes:

- First route succeeds: zero full opens/replays; same phase file.
- First route returns existing typed `retry`, second succeeds: one full open,
  replay of both retained entries, phase file replaced. Both fetch only slot 3.

The same experiment with a genesis-only prefix agrees. Real call tracing and
SDK counters agree. This is a state-lifetime defect independently of whether
it explains this particular hardware run. The eventual fix must demonstrate
its own correctness and measured effect; no latency target is promised here.

## 2. Source-established ownership (reviewed pre-cut baseline)

| Existing seam | Current behavior | Proposed responsibility |
| --- | --- | --- |
| `quod_foreign_log:verification_work` / exact-route walk | A route attempt opens/resumes, validates, then closes or returns a store | The existing worker opens/resumes once; candidates borrow one threaded verified state |
| `verify_cached` | Temporary failure closes store and phase session | Return request verdict separately from the last sound verified cursor |
| `verify_exact_routes` | Next route receives `Resident=none` after failure | Next candidate receives that same sound cursor, not an instruction to reconstruct it |
| current/follow completion and `close_worker_cache` | Outcome-dependent lifecycle also controls reuse | One worker-boundary disposition for reusable state; preserve distinct public result families |
| registry custody / `retiring` / monitored DOWN | Excludes a second cache writer until real death | Unchanged, including replacement-owner and session-safe cleanup contracts |
| admission/coordinator trace context | L3 loses context before group spawn | Carry observation through existing transient owners and existing endpoint carrier |

Exact source baseline: foreign-log route recursion around 4851–4889,
`verify_cached` around 5012–5089, `certified_current_snapshot` around 5099,
`open_replayed_cache_raw` around 5334; group admission in Prolog around 5222,
Simplex group start around 5231, coordinator `start_monitor/5` around 133.
Implementation must re-check source locations, not match these numbers blindly.

The per-identity active worker is a **cache-writer custody boundary**, not the
deleted single-active-L3-group lock. Do not bypass it, add readers of a mutable
writer handle, parallelize cache appends, or weaken retirement. Unrelated
identities already have their own workers. This proposal fixes avoidable work
inside the existing owner rather than introducing another execution path.

## 3. Core contract: proof outcome is not cache validity

### 3.1 One worker-owned verified cursor

Represent the existing store, verified height/projection, phase index/session
and exact-slot context as one worker-local, explicitly threaded state. This is
not a new owner or a second cache. No process-dictionary escape hatch and no
copy of the index/ledger per route. Reuse existing store/session APIs and the
owner's existing result metadata for transfer at the job boundary.

Open or resume after acquiring current registry custody. For the same exact
reference, all route candidates operate on that state within the same worker.
Changing endpoint alone neither closes the state nor reruns certified replay.
Suspend once at the worker boundary when reusable; final cleanup still belongs
to the existing custodian and ends before its monitored release permits a
successor. A worker never transfers a mutable store handle to the owner.

### 3.2 Return the verified prefix on unsuccessful attempts

Internal success/error returns must carry the **last fully verified and
consistently persisted prefix**. A timeout, unreachable endpoint, malformed
candidate response, refused exact claim, or failed tip confirmation is not
evidence that an earlier certified prefix became invalid.

This includes partial advancement: if entries through K passed the existing
chain/committee checks and were appended, but K+1 failed, do not return the
old height with a physically advanced file. Thread the K cursor back with the
error. Invalid/unverified bytes may never enter that cursor. The ledger handle,
checkpoint projection and phase index must describe one prefix when suspended.
The implementation must name the exact verification/append/update order at the
shared advance seam and prove failures between those operations fail closed.

In particular, `persist_verified_page` currently orders ledger append, phase
commit, checkpoint publication and owner accounting. Later failure can return
`cache_corrupt` without the advanced cursor, while
`sequential_snapshot_sources` can treat a non-global error as a reason to try
another route with its old cursor. The new internal disposition must distinguish
**reusable verified cursor** from **invalid/unreconciled local state**, not
merely carry a store alongside every error. A post-mutation failure must never
be offered to the next peer as the old prefix. Stop/recover through the existing
custody-held local recovery path unless consistency is positively established.
A reservation refusal before mutation is different: the old prefix is intact.

Actual cache corruption, mismatched incarnation/file identity or unrecoverable
local persistence failure still invalidates reuse. Use the existing guarded
corruption/recovery path under custody; never relabel corruption as availability
or reconstruct from unverified memory. No new on-disk format or durable checkpoint
trust is introduced. Cold restart still requires current certified recovery.

### 3.3 Authority and caller result remain unchanged

Keeping a prefix does not make the requested reference valid or the current
tip confirmed. Preserve every exact claim/entry/height/phase/digest/anchored
incarnation and historical-committee-era check. Preserve the existing source
order, candidate eligibility, quorum and finality verification.

Current-view confirmation stays mandatory. A failed confirmation may retain
verified history, but must not publish a fresh `current_view`, execution route,
certificate, verified-contact promotion or successful caller result. Exact
verification and follow replies retain their different public grammars.
Publication remains checked against each original absolute caller deadline;
one caller's expiration does not corrupt or cancel another caller's work.

**Freshness-installation proof obligation:** `install_worker_meta` currently
changes height/projection while leaving the boolean `current_view` field, and
`retain_current_watch` changes that field only on a successful current result.
`resident_confirmed_current` also requires a quorum of matching ordered feed
registrations; the boolean alone is not its authority. Widening reusable error
outcomes must explicitly reconcile this state at the common installation seam.
An assertion for H/its committee era must not be silently rebound to a retained
K/new era merely because `resident_verified` remains true.

The conservative candidate is to preserve a confirmed assertion only for the
same head/era, otherwise mark it unconfirmed until the existing current-view
rule establishes the new binding. Review must prove whether the existing
matching-feed rule already establishes K's freshness after partial advance;
do not add a second current verifier or gratuitous quorum probe if it does.
This is a named obligation for the wider error-state lifetime, not a claim that
today's successful current-view fast path is unsound or an excuse to backdate
confirmation. Failed tip confirmation plus later feed arrival must be tested.

Only a genuinely verified prefix advance may emit the existing progress edge.
Retaining an unchanged cursor or finishing a failed attempt must not mint a
retry permission. No retry timer, polling, renewed deadline, population cap or
queue exception is part of this correction.

**Wake-installation obligation:** `install_worker_result` currently calls
`release_queued_route_waiters` whenever metadata says `resident_verified=true`.
That condition cannot survive unchanged when unsuccessful jobs can retain
resident state. Otherwise two different parked jobs with unreachable routes
can repeatedly wake each other after retaining the same prefix, with no new
external evidence. Separate reuse eligibility from wake permission at this
existing seam; the approved candidate is the same genuine verified-prefix
advance predicate, not `resident_verified` alone. No extra dispatcher or timer.
Preserve the approved consume-once
and self-install-exclusion rules and prove the two-job schedule cannot spin.

### 3.4 Sweep at the shared lifetime seam

Audit exact, current, follow, local-source and hint-assisted paths for the same
outcome/state coupling. Share lifecycle management, **not** their proof or
freshness result types. Remove per-candidate open/close/replay and **both**
`Resident=none` continuation arms in `verify_exact_routes`: availability errors
and definitive `phase_mismatch` / `invalid_foreign_reference` results. An invalid
request does not invalidate its healthy prefix. Thread the same sound cursor
through either continuation rather than adding a special
“warm retry” branch. A cold/no-resident or genuinely invalid store is still an
ordinary recovery case, not a compatibility path.

Do not change certified-reference acceptance, result authentication, signed
bytes, ordinary proof/backtracking snapshots, source authority, control roles,
consensus decisions, or the future finality/compaction designs. Both existing
ledger AST guards remain closure gates, adjusted only for a deliberately moved
owning call site if the reviewed refactor requires that movement.

## 4. Close observation gaps without a new transport

The next hardware run needs to identify the actual predecessor, not merely
measure another long queue. This observation portion is reviewed together with
the owning refactor; no state-machine transition may depend on tracing.

1. Carry the request context through existing transient group admission,
   activation and coordinator ownership. Reuse `quod_trace:shared_context/1`
   for first-recording-parent/links, and the operation-worker spawn pattern.
   Observation must not enter a signed plan/control, certified reference,
   transaction, journal, durable outcome, conflict descriptor or sharing key.
   Duplicate and late caller contexts must not alter group identity or lifetime.
2. The existing DTX endpoint already carries transient W3C context outside its
   semantic request. Reuse it. **No proposal-context protocol extension or new
   wire version** is opened. Recovery without a live caller has honest independent
   context; never pretend its work was parented to a caller it did not have.
3. At the existing foreign owner, describe queue blockers at real state changes:
   active/retiring job, earlier queued work, earlier custody wait, or unknown.
   Include existing identity/job IDs, work kind, monotonic residence/age and a
   link when a recorded predecessor context exists. Keep no second scheduler
   index. Derive from the existing history/request rows; delete transient
   observation with those rows. Do not poll the worker or retime its execution.
4. Record caller remaining budget at admission and dispatch, together with the
   existing work lifetime classification. These are observations, not new
   timeouts. Infinity must be typed explicitly; do not subtract clocks from
   different nodes. Distinguish client signed lifetime, proof lifetime and
   shared job lifetime rather than forcing them equal as a diagnostic “fix.”
5. Trace route failure classification, retained/replayed prefix disposition,
   resume/cold-open reason, verified delta and final cleanup using existing
   stages. Expected-child counts and sampling/missing-parent limitations stay
   explicit. No retrospectively invented spans, mutable-parent promises,
   owner-root flood or unbounded attribute arrays.

Job/group IDs may appear in the existing diagnostic trace/log fields, never
Prometheus labels. No goal, plan, symbol vocabulary, principal or key material
is exported. A missing predecessor trace remains a declared coverage gap even
when its job ID is known. Fixing group propagation alone does not promise that
every autonomous replica job was sampled.

Separately within the diagnostic review scope, the signing-journal vote-sync
histogram must observe the native duration directly. Its seconds-suffixed
declaration already instructs the library to convert on export. Pin one native
second → exported sum 1.0, and zero-duration behavior. The existing vote-sync
finite buckets end at 0.5 seconds: the one-second sample must overflow honestly;
two half-second samples must sum to 1.0 inside the existing finite bucket.
Do not alter bucket declarations to force the test shape. This changes
measurement only; never touch sync frequency or durability.

## 5. Non-vacuous implementation gates

1. Turn the preserved four-case probe into permanent regression tests: healthy
   route and transient-failure→healthy route both perform zero full open/replay
   after warm-up, preserve the phase session, fetch only the suffix and verify
   the same non-genesis Finalize. The old source must fail the no-replay assertion.
2. First peer verifies a nonempty suffix then fails; second resumes from exactly
   that verified height, never genesis or a stale checkpoint. Pin the real cache
   file contents, height/projection and phase state, not just API success.
3. Bad signature, wrong-era signature, wrong anchor, mismatching certified claim,
   malformed/unverified suffix and invalid local persistence each fail closed.
   Healthy retained history must neither authenticate the bad request nor be
   discarded merely because the request is bad.
   Inject failures after append, phase commit, checkpoint publication and owner
   accounting independently. Assert exact physical file/phase/checkpoint
   agreement or explicit unusable state, and **no next-source attempt with the
   pre-mutation cursor**. Add the pre-append refusal positive control, where
   the old verified prefix remains reusable. Do not conceal inconsistent state
   behind a generic endpoint-unreachable result.
4. All routes unavailable: callers receive the same typed result; no timed
   attempt follows. A later genuine demand/wake can reuse the retained prefix.
   Failed current-tip confirmation retains reachability/proof separation.
   Include **two distinct parked jobs** with live callers, different exact refs
   or kinds, unchanged verified height and all routes returning `retry`.
   Neither failure may release the other's park just because its cursor remains
   resident. One external edge grants only the existing bounded attempt
   permission; fail-before evidence must expose the naive widening's spin.
5. Run the existing owner-death, delayed watcher, same-inode overlapping-writer,
   suspended-session sweep and registry-restart tests against the changed
   lifecycle. Actual DOWN stays the only custody release. No successor opens,
   truncates or cleans the old writer's file/session early.
6. Exact callers with different budgets and sampled contexts share as before;
   queued/expired successes are refused; observation produces no wake and
   cannot extend or cancel durable obligations.
   Also drive confirmed H → verified partial advance K → failed confirmation,
   then ordered feed notifications for K. Assert the exact reviewed freshness
   binding and committee-era rule: no success based merely on H's old flag,
   no unnecessary network confirmation if existing K evidence already suffices.
7. Group trace tests drive real reserve→activate→spawn and existing endpoint
   carriage, mixed sampled callers, duplicate admission and recovery without a
   caller. Golden wire/signed bytes stay identical. Trace-off transitions and
   replies stay identical. Missing-context negative controls must fail.
8. Queue a current request behind a held exact job; identify that job/identity,
   then distinguish real custody retirement and a genuine route park. Test
   missing/sampled-out predecessor honestly; expected counts must not erase it.
9. Preserve full sequential clean-build gates with true exit codes: EUnit, ask
   CT, QUIC CT, Simplex CT, xref, Dialyzer, production release and diff-check.
   Review the complete changed tree **before commit**, especially DTX/Simplex
   observation plumbing. No version bump or deployment before that review.

After approval and implementation review, preserve ledgers and the old failed
operations. Explicitly label a new campaign; do not replay this campaign's
signed executes. First prove the changed failure path's structural work bounds,
then use finite trace capture to identify the hardware predecessor/phase and
run conserved/independent-shape pilots. Continue to n100 only when uncertainty
and durable/state checks permit. The >=95%-of-means gate applies to any claimed
causal latency explanation; sampled request trees and replica counter sums are
not a substitute.

## 6. Implementation checkpoint — final review required

The implementation uses one private `verified_cursor` in the existing
verification worker. `verification_work` opens/resumes it once under acquired
gproc custody, then dispatches exact/current/follow work inside that scope.
Every route continuation carries it, including definitive claim refusal.
The cursor never enters owner state: `close_worker_cache` removes it and
returns only the existing suspended-session/verified-projection metadata.
The old outcome-based `resident_worker_meta`, per-route open/close helpers,
`current_snapshot_result`, `verify_exact_work`, `finish_phase_session` and
`retry_corrupt_cache` are deleted rather than retained as parallel paths.

There are two dispositions, not two verifier paths. A sound prefix can be
suspended after a request failure. A cursor invalidated by partial local
persistence holds cleanup handles only; it cannot continue to another peer,
be suspended, or publish evidence. Reservation refusal before append still
permits the next source. Append, phase delta, checkpoint and accounting are
one checked persistence boundary. After any uncertain mutation the existing
typed retry is returned, the physical ledger is preserved, and the next
genuinely admitted job uses the existing recovery owner. Corrupt-open recovery
is now shared by current/follow and exact work at that single admission seam;
it is not a per-route recovery loop or an automatic resubmission.

Empty caches contain no certified genesis and are not retained as verified
history. Normal empty cleanup is traced as successful cleanup, not corruption.
A follow that loses its local source before the borrow is accepted also exits
through the common cursor scope. This closes a session-lifetime gap without
adding a follow-specific cleanup branch. Source-death checks still refuse its
result; retaining independently verified history grants the failed borrow no
authority.

`install_verified_progress` is the common metadata/wake seam. Only a strictly
higher verified height releases queued route parks. An unchanged failed job
does not wake its failed sibling. `install_worker_meta` preserves a confirmed
current-view assertion only for the same height and projection; otherwise it
is unconfirmed. A later K feed registration cannot turn H's old assertion
into K's: the existing feed handler never promotes an unconfirmed row. After
ordinary K confirmation, unchanged K requests still take the existing zero-
fetch fast path. No extra verifier or confirmation algorithm was introduced.

Observation uses existing transient rows. Group admission, activation,
coordinator ownership, phase fan-out and locally proposed group controls carry
context; the endpoint uses its existing W3C carrier. Duplicate/late contexts
do not change owner identity or retained work. Recovery without a retained
context starts independently. A remote consensus leader reached through the
context-free relay remains a declared coverage boundary: no new proposal
carrier or signed/wire format was added.

Foreign queue markers describe changes to the existing active/retiring/queued/
custody/route state and link a sampled predecessor when available. Job IDs are
trace attributes only. The marker deduplication key excludes elapsed age and
budget, so revisiting an unchanged selector state cannot manufacture markers.
Existing caller/work budgets are reported, not changed. The journal metric
now observes native duration with its existing buckets.

The implementation evidence and fail-before archive is
`/tmp/quod-residency-cut-M39iVr/` (including
`RESIDENCY-REGRESSION-EVIDENCE.md`). Its old-source replay/freshness/wake/
persistence controls remain separate from fixed-tree gate results. Group
context and queue/metric negative controls are in
`/tmp/quod-group-trace-baseline-qIvGFG/HANDOFF.md` and
`/tmp/quod-residency-metric-probe-iTkOfl/HANDOFF.md`.
The final review handoff records exact gate commands, outputs and fingerprints.
These are local correctness/work-bound tests, not a replacement hardware run.
The full-open architecture guard is unchanged. The artifact guard changes
exactly the owning `persist_verified_page` arity from 8 to 6 after cursor
consolidation; append API, inventory equality and call count stay pinned.
An additional run of the eight-case N=4 `simplex_SUITE` exposed a pre-existing
fixture-only raw block constructor in its two Byzantine membership cases.
The fixture now uses `quod_ledger:new_block/4` so its unchanged malicious
signed payload reaches the validators in a canonical frame; no production
codec exception or rejection/liveness assertion was changed. The standing
twelve-case `quod_simplex_SUITE` is a separate gate, and both are reported.

Final clean-build sequence, 2026-09-10: EUnit **1972/0**, ask CT **26/26**,
QUIC CT **26/26**, `quod_simplex_SUITE` **12/12**, extra N=4 `simplex_SUITE`
**8/8**, xref, Dialyzer, production release and diff-check all exit **0**.
Commands and true exit codes are in the archive's `final-gates/` and
`run-final-gates-v2.sh`; previous failed attempts remain separately preserved.
The production release still starts gproc as `permanent`. The review prompt is
`/tmp/quod-residency-cut-M39iVr/CLAUDE-REVIEW-PROMPT.md`. No commit, version
bump, deployment or post-fix performance measurement has occurred.

## 7. Review questions and retained gates

Approve or refute the single-worker cursor lifetime and partial-progress
contract, including whether any existing route-specific operation can invalidate
an already-certified prefix. Audit the complete advance/error-return paths for
places where store, checkpoint and phase projection can diverge. Identify the
minimal lifecycle surface needed for exact/current/follow without merging their
authority semantics. If a new owner or exclusion mechanism seems necessary,
stop and return; do not extend the approved registry-custody design implicitly.

The companion L2 refresh is still design-only. Its backtracking, origin-local
target and per-target result-authentication questions must not ride this fix.
Q4, duplicate-receipt policy, slot-1059 attribution, finality F1, compaction,
10k-history behavior and absolute latency gates all remain open. This contract
does not remove the fundamental cold-start O(history) cost; it removes an
unnecessary transition back to that cold state on an otherwise live path.

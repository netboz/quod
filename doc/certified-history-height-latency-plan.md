# Certified-history height-latency correction plan

**Status: reviewed; Slice H1 (observability and attribution) is in progress.
H2 waits for completed H1 attribution, the reviewed finality cut and coordinated
re-found, and a fresh post-cut baseline/backend review. No H2 implementation
before that cut.**

Sequencing agreed by Yan: H1 measurements on unaffected 0.7.143 fixtures run
alongside the paper-only finality review. Finish and archive the full H1 matrix
before finality code starts; no measurement may still be running when the cut
or re-found destroys its fixture. All such data are **pre-cut 0.7.143**. After
the cut/re-found, re-grow fixtures and establish a separate new-protocol baseline
before H2. Do not pool or compare results across the protocol change to claim
an H2 improvement. See `finality-round-recovery-plan.md` §7. The stuck group
`6FDDFDBA6A0D61C5E779593F08F5416F35ABCBE39FA7E2C8D20C1D2A6D231B6D`
and its ontology remain excluded from measurement until the scheduled re-found;
its evidence is then archived as unresolved-on-the-old-network.

This plan owns one observed defect: a warm signed one-hop write becomes slower
as the caller ontology's certified history grows. It does not own cold restart,
ledger compaction, route recovery, L2 write lanes, or DTX batching.

## 1. Problem and accepted evidence

The accepted hardware evidence is:

- on the older long-lived fixture, the per-request certified-history work rose
  from about 149 ms around height 80 to about 400 ms around height 7,000;
- a clean re-found reset that cost;
- the N=4 one-hop concurrency-4 p99 reached 676 ms, above the 450 ms absolute
  gate;
- the first request after a process restart at roughly height 7,000 took
  34.6 seconds, but that is a separate cold-start problem;
- after the 0.7.135 re-found, low-height node-actor reads cost 0.12--0.22 ms.
  Those heights were only 2--4 and therefore neither prove nor disprove the
  height-growth defect.

The defect matters outside DTX. A target authenticating an ordinary signed
remote scope must obtain the caller ontology's current certified identity view.
If that operation grows with all of the caller's old blocks, the base one-hop
path grows forever.

## 2. Architecture that must remain true

1. `quod_foreign_log` remains the one node-wide owner of foreign certified
   history, current views, exact references, and subscribed projections.
2. `quod_catchup` remains the one page grammar and forward verifier.
3. A feed height wake is only a freshness signal. It never becomes evidence
   and never makes an unverified resident row current.
4. A current view is returned without new verification only when the existing
   quorum-bound feed registrations still confirm the resident height. Any
   missing, newer, stale, or conflicting signal uses the ordinary verifier.
5. The target's normal scope authentication and `can_invoke/4` authorization
   are unchanged. This work adds no identity cache, verifier, ACL, executor, or
   route path.
6. Certified-history work stays message-driven. No polling, retry-delay ladder,
   keepalive loop, or idle timer may discover progress.
7. No population or history-height cap is introduced. An inactive ontology
   must not consume a permanently open worker or ledger handle merely to make
   the benchmark fast.
8. No consensus, transaction, block, certificate, catch-up-wire, or ledger
   format changes merely to correct this local derived-state cost.
9. Uncertain writes are never resubmitted automatically.

## 3. Current path and the bounded-work expectation

For a remote signed scope whose agent belongs to ontology A, a validator of B
uses this path:

1. `quod_prolog:local_or_foreign_agent_view/5` asks
   `quod_foreign_log:current/4` for A's anchored identity.
2. `resident_current_identity/3` may answer immediately only from a still
   quorum-confirmed resident view.
3. Otherwise one per-identity verification worker calls
   `certified_current_snapshot/9`.
4. `open_cache/6` resumes A's verified ledger session and its DTX phase index.
5. `advance_current_snapshot` fetches and verifies only the suffix after the
   resident height.
6. `current_view_confirmed` checks the resulting tip against A's certified
   current committee.
7. The worker returns the new certified projection to the same foreign-log
   owner, which retains the resident view and freshness registrations.

For an unchanged A, step 2 should be independent of height and perform no disk
or network work. For A advanced by one entry, steps 4--6 should cost only the
one-entry suffix plus committee confirmation. Neither case should scan or
rewrite A's complete history.

The serving side already calls `quod_simplex:ledger_read_snapshot/1` and
`quod_ledger_store:open_ro_snapshot/1`; it does not normally rescan the hosted
ledger for each page. The foreign cache's ledger session similarly resumes its
sparse index without a scan.

## 4. Phase-index hypothesis: weakened by the corrected diagnostic

`quod_dtx_phase_index` remains a measured candidate, not an established owner:

- it stores one exact row for every DTX GroupId so an evicted completed group
  remains an authoritative tombstone;
- its current DETS session is closed by `suspend/1` and reopened by `resume/1`
  for ordered verification workers;
- the original suspicion was that closing after one new row rewrote work
  proportional to all retained groups. That specific inference is withdrawn;
- the reviewer corrected the earlier probe description: its large close/sync
  measurements followed a **bulk insertion of N dirty rows**, not a reopened
  settled table plus one update. The previously cited 4/23/166 ms numbers
  therefore do not establish a table-size slope for Quod's steady-state path;
- the existing-API diagnostic on 0.7.143 instead resumes a settled table,
  inserts one synthetic completed-group row, and suspends it. On local ext4,
  mean dirty suspend was about 0.169 ms at 80 rows and 0.237 ms at 10,000
  (20 samples per size, all outliers retained). Resume was 0.215/0.255 ms.
  The tmpfs and ext4 runs are archived separately in
  `/tmp/quod-h1-phase-discriminator-XO3RT9/report.md`;
- those one-phase, roughly 500-byte synthetic rows do not reproduce the
  large alleged suspend slope. They are not real multi-phase certified fleet
  histories, and do not prove a universal complexity bound for fragmentation,
  dirty-byte counts or every DETS workload. The review's dirty-work correction
  weakens the prior; it does not approve or exonerate any backend.

H1 still separates **phase_suspend/commit** from **phase_resume** and records
actual changed rows/bytes alongside retained size. If another stage owns the
increase, name it and return for review instead of replacing the phase index
on the withdrawn premise. No backend selection before the 95% attribution gate.

Other candidates remain open until measured:

- an unexpected resident-current miss or freshness-registration rebuild;
- phase projection validation growing with committee eras;
- suffix verification doing work before the retained height;
- target-side tip serving falling back from the ledger snapshot;
- committee-tip confirmation, QUIC scheduling, or the foreign-log mailbox;
- caller-side identity-certificate collection outside `quod_foreign_log`.

No implementation choice is approved merely by this hypothesis.

## 5. Measurement contract

### 5.1 One correlated request

Extend the existing `quod_foreign_history_stage_seconds` owner rather than
creating another metric family. Add only closed stage/result values needed to
separate:

- owner queue wait;
- resident-current decision and miss class;
- ledger-session resume;
- retained-projection validation;
- phase-index resume and suspend/commit;
- suffix page fetch, verification, and persistence;
- current-committee tip confirmation;
- result installation and caller wake.

On the serving node, instrument the existing catch-up owner into the same
closed foreign-history stage family: ledger-snapshot lookup, snapshot resume,
fallback `open_ro` scan, range read, and response encoding. The caller's page
fetch remains the enclosing network measurement. This makes a serving-side
fallback scan distinguishable from QUIC time without introducing a second
metric owner or protocol field.

Add one `quod.foreign.current` OpenTelemetry span under the existing signed-goal
trace. The request's trace context must be carried into the already-existing
worker; process-dictionary inheritance is not assumed. Numeric attributes may
include retained height, verified suffix length, committee size, committee-era
count, and phase-index row/byte counts. Namespace, anchor, agent, goal, endpoint,
and failure payload never become Prometheus labels.

Instrumentation must not enumerate the phase store merely to count it. A count
used for attribution must already be maintained by the phase-index abstraction
or be read through a constant-work backend statistic.

The reviewed measurement alternative is a temporary **isolated OTP trace
session** at these same existing functions, not another production owner or
metric family. Capture only selected identities' correlation metadata and
closed numeric stage observations, never raw keys, proof arguments or evidence.
Destroy the session in `after`; its final cleanup safeguard is not protocol
polling. Compare traced/untraced runs and report instrumentation uncertainty.
Node-wide scrape deltas alone cannot separate preserved-group recovery from
the measured requests. Existing sampled spans do not contain every individual
phase duration, so increasing the sampler alone cannot fill that gap.

Before full-matrix growth, demonstrate both on one advancing-view cell:

1. `current_total`, emitted in the **caller's** process, is correlated through
   the existing caller/ref to the owner and worker. An owner-only trace misses
   it; `request_current` is not a substitute. Keep the same isolated session,
   with narrowly selected function matches across the required processes.
2. A one-entry advance actually runs the certified worker, with nonzero
   `phase_resume`/`phase_suspend` observations and verified suffix accounting.
   Reconstruct nesting/parallel intervals without double-counting. Prove that
   background or shared work cannot be attributed to the wrong request.

The 0.7.143 height-4 checkpoint already demonstrated the unchanged-view subset:
100/100 traced and 100/100 untraced signed reads, means 13.41/13.13 ms, exact
source association on a non-cohosted validator, and zero worker/fetch/phase
operations. This is neither the high-height result nor a full attribution gate.
Raw evidence: `/tmp/quod-h1-precut-audit-znCmzX/HANDOFF.md`.

The subsequent caller/worker capture meets those two feasibility checks:
100 unchanged reads at h6 and 100 one-entry advances with exact observed
heights 7–106 all succeeded. Advancing-read client mean was 44.88 ms;
`current_total` 32.804 ms; `phase_resume`/`phase_suspend` 0.492/0.089 ms.
Parallel probe durations are enclosed, not summed. Worker time still includes
2.950 ms mean unassigned, so this is not full stage attribution or a measured
height-growth slope. The unchanged traced/untraced means were 13.41/12.19 ms,
an observational difference, not a causal overhead estimate. Committee N=4
and the certified projection's **four historical committee eras** stayed
constant; a hosted status row's retained-view count is not that era count.
Raw per-request stages and summaries:
`/tmp/quod-h1-precut-capture2-HOFRDN/`. Full growth remains conditional on the
ordinary-content and genuine-DTX throughput estimate below.

### 5.2 Controlled discriminator matrix

Use the same N=4 physical topology and the real signed-client path. Preserve
raw per-request TSV and traces. At heights approximately 80, 500, 1,000, 2,000,
4,000, 7,000, and 10,000, measure three histories separately:

1. content-only growth with no DTX controls;
2. the same approximate block and byte count containing many completed DTX
   groups;
3. a normal application mixture.

Each history-class/starting-height point uses a separately grown source through
the ordinary signed path. A point is an **exposure window**, not a promise
that its probes leave the source at one height. Record actual per-request
source heights and per-case start/end heights, ledger bytes, operation counts
and completed phase-index GroupIds; match baseline block/byte sizes across
classes and use the same workload ordering. Regress attribution on **actual
per-request heights**, never nominal cell/directory labels, separately by
workload/history class and concurrency. Also report the observed mean deltas
and residuals; fitting a regression alone does not pass the 95% gate.

One-entry probes necessarily span heights, and write probes grow history too.
Ordinary L1 `remote_claim`/`remote_complete` metadata is not a
Begin/Prepare/Decision/Finalize/Complete group. The DTX-heavy class requires
real completed multi-writer goals, not relabelled L1 traffic. Do not infer
ledger height from assertion count or count metadata as phase-index rows.
Do not restore/fork a live anchored ledger to manufacture fixed-height samples.

An earlier archive labelled `h10000` actually began at h1811. Keep that raw
evidence, but its directory name is not a measurement. The historical inventory
records the mismatch; no new table may reuse the nominal label as fact.

All three keep the committee membership and committee-era count constant. That
deliberately excludes era growth as the cause. If H1 evidence points toward
projection-shape cost despite that control, add a separately labelled
membership-churn diagnostic run and return for review rather than contaminating
the three primary fixtures.

For each workload class, prove that the serving validator does not host the
source and that the intended foreign current-view path actually ran. `::`
syntax alone does not prove this: a co-hosted source uses its local view.

Before mass growth, measure a small ordinary-path content and genuine completed-
DTX growth sample and estimate the campaign wall time from actual blocks,
bytes and groups produced. The full matrix has 126 cells before repeats;
read latency is not a growth-throughput estimate. Finish/archive pre-cut runs
before the finality cut; do not risk losing partially grown fixtures at re-found.

At every point run:

- 100 unchanged-current-view requests after warm-up;
- 100 requests where A advances by exactly one content entry between checks;
- one-hop signed writes at concurrency 1 and 4, at least 100 requests each;
- L1 read-B/write-C at concurrency 1 and 4, at least 100 requests each, as a
  regression comparison rather than a new L1 optimization target.

Record mean, p50, p95, p99, failures, pending/uncertain results, scheduler
utilization, mailbox delay, bytes fetched, entries verified, and every
non-overlapping stage mean. Never subtract marginal percentiles.

Run a direct `quod_dtx_phase_index` discriminator at the same group counts:
empty resume, unchanged resume, one-row update plus suspend, exact lookup near
the beginning and end, and session close. It is diagnostic evidence, not a
replacement for the hardware run.

### 5.3 Attribution stop gate

No behavioral optimization starts until at least 95% of the *increase in mean
latency* between the low- and high-height runs is assigned to non-overlapping
stages. Report both the total mean and the explained delta. If the suspected
phase-index work is not the owner, stop and revise this plan before changing
another subsystem.

## 6. Slice H1 -- observability and reproduced baseline

- Add the closed metrics and trace described in section 5 at existing seams.
- Add structural counters only to their current owner; do not add a diagnostic
  process or cache.
- Add the controlled height-growth fixture to the existing signed-goal load
  driver. It must create and grow ontologies through ordinary signed goals.
- Reproduce the slope and pass the 95% attribution gate.
- Stop for review with the complete table and trace examples. H2 does not start
  from an unverified guess.

Tests pin that a trace spans the queued worker, stage names are closed, metric
labels contain no identity data, unchanged resident hits report zero fetch and
zero phase-store work, and instrumentation cannot change a result. H1 exposes
backend operation counts and constant-work row/byte extent statistics so the
hardware table can distinguish elapsed cost from the amount of work requested;
it does not assert the still-unproven H2 independence property. One
request-level test also asserts that the declared non-overlapping stage
durations sum to approximately the enclosing request duration, within only
explicitly recorded instrumentation/scheduling residual; this pins the
arithmetic used by the 95% gate. H2's structural-independence tests use backend
operation and byte counts, never wall-clock thresholds.

## 7. Slice H2 -- correct the owning derived-state abstraction

H2 is conditional on H1, the finality cut/re-found, and post-cut re-baselining.
Do not implement against the old catch-up/ledger/phase-index seams that finality
will rewrite. Carry H1's attribution table into backend review, confirm the
identified owner on the new protocol, then build the fix once. If the evidence
confirms the DETS phase-session lifecycle as the dominant owner, refactor
**`quod_dtx_phase_index` itself**, keeping its public semantic API and its sole
use by certified-history reduction.

The required behavior is:

- resume and suspend perform work independent of the number of completed
  groups;
- a lookup reads only the exact GroupId row;
- completed GroupIds remain exact authoritative tombstones, so a later control
  cannot reuse a completed group as new;
- incomplete groups retain the exact prior certified phase records needed by
  the next control;
- a preview changes nothing; after the ledger sink succeeds, one successful
  commit makes the whole window reusable;
- a process crash or partial storage error abandons that session. It is rebuilt
  only by the existing certified replay and can never be accepted as a partial
  index;
- session cleanup targets only its own derived files;
- no always-open handle, per-identity owner process, in-memory unbounded GroupId
  set, hard cap, or second truth store is introduced.

The backend shape is selected during H1 review. The preferred candidate is a
session-local exact disk index whose GroupId-addressed rows can be read or
replaced without opening or rewriting a table proportional to all prior rows.
It remains disposable derived state under `quod_dtx_phase_index`; the ledger is
still the only durable authority. A file-per-group implementation, a shared
node-wide table, or keeping every DETS file open is **not** pre-approved: inode
growth, cross-identity cleanup, and dormant-resource costs must be compared in
the H1 review before one is chosen.

If H1 instead names another owner, H2 must be rewritten and reviewed around
that owner. It may not add a bypass in `quod_prolog` or the scope path.

### H2 safety tests

- every legal Begin/Prepare/Decision/Finalize/Complete sequence reduces exactly
  as before across suspend/resume boundaries;
- a second Begin using a completed GroupId remains rejected after many other
  groups and after suspend/resume;
- incomplete and completed group rows survive exact lookup;
- a failed multi-group commit cannot be resumed as a partially updated index;
- worker death abandons its session and the next request rebuilds through the
  existing verifier;
- row corruption is a typed phase-index failure, never an empty history;
- two identities progressing concurrently cannot see each other's rows;
- backend operations and bytes for one new entry are structurally independent
  of earlier group count; no wall-clock assertion is used as a unit test;
- foreign vocabulary stays wrapped and creates no atoms.

## 8. Slice H3 -- integration, removal, and hardware gate

- Remove superseded DETS/session code, tests, comments, metrics, and scratch-file
  cleanup if H2 replaced them. No compatibility reader is retained because the
  phase index is disposable derived state.
- Verify unchanged views do no disk/fetch/fold work and one-entry advances
  process exactly their suffix at low and high heights.
- Run clean sequential gates: EUnit, `quod_ask_SUITE`, xref, dialyzer, and
  `git diff --check`.
- Deploy all nodes together if any local phase-scratch shape changed, even
  though no consensus or wire format changed.
- Repeat the full section-5 matrix without a re-found between height points.
- Inspect warning/error/critical logs, process restarts, outcome-unknown metrics,
  foreign-history replays, and route recovery throughout.

The release gate is:

1. 100/100 successful requests in every measured one-hop and L1 run;
2. no client-visible pending/uncertain result, automatic resubmission, node
   restart, or unexplained warning/error;
3. unchanged-current requests perform zero page, replay, ledger-resume, and
   phase-index work;
4. one-entry advances fetch and verify only that suffix;
5. warm current-view work has no material trend with total height or completed
   GroupId count through height 10,000;
6. N=4 one-hop concurrency-4 p99 is at most 450 ms;
7. L1 remains within approximately 100 ms of one-hop on the same topology;
8. the corrected owner accounts for at least 95% of the former mean-latency
   growth, using per-request sums or means.

If the absolute 450 ms gate still fails while height-dependent work is flat,
this arc closes the height defect but records the remaining constant/tail owner
as a separate optimization. It must not be hidden by redefining this result.

## 9. Explicit non-goals and later work

- **Cold-start re-verification remains next.** This plan may measure session
  close/rebuild effects but does not add a checkpoint or skip certified replay.
- **Ledger compaction remains separate.** A future reviewed plan owns a
  committee-certified projection checkpoint, verifiable suffix replay,
  archival, and committed Prolog policy for checkpoint creation. Deleting or
  truncating ledger history is forbidden here.
- The three small carried cleanups (`valid_role_fields` empty metadata fields,
  caller-less `verify_current/3`, and the lost `verify_local` committee-era
  assertion) do not belong to H1 or H2. They may be folded into H3 only if they
  touch the same final files and remain separate commits; otherwise they stay
  in the backlog.
- L2 / write-lanes slices 6--8 remain parked.

## 10. Documentation amendments when implementation is reviewed

| passage | amendment |
|---|---|
| `automatic-route-recovery-plan.md` section 14 item 1 | mark the height-growth defect measured and closed; preserve cold start as item 2 |
| `dtx-latency-optimization-plan.md` section 4.7.8 | add the controlled height curve, per-stage attribution, owning fix, and final N=4 results |
| `quod_foreign_log` moduledoc | state the final constant-work resident/delta lifecycle without claiming cold-start compaction |
| `quod_dtx_phase_index` moduledoc | if H2 owns the fix, describe the replacement session storage and exact tombstone invariant |
| `quod_ledger_store` moduledoc | change only if H1 proves this owner is involved; never imply compaction landed |
| `quod_metrics` and Grafana | document and display the closed current-view sub-stages; remove any superseded temporary panel |
| `deferred.md` compaction passage | state explicitly that the warm height-growth fix does not close cold-start replay or ledger compaction |

Historical benchmark text remains labelled historical. No documentation may
describe a hypothesis as an implemented mechanism.

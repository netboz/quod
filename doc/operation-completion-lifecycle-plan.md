# Remote-operation completion lifecycle

**Status:** implementation reviewed and approved for commit/deployment;
hardware acceptance remains outstanding.
This is a bounded correction to the existing single-writer operation/result
path. It does not implement the finality cut, H2, or L2.

## 1. Observed failure and scope

The non-co-hosted 0.7.144 one-hop run at N=4, concurrency 1, returned 15 clear
commits and 85 client-visible pending replies out of 100 requests. Read-only
resolution subsequently found all 100 source operations terminal and all 100
exact target transactions committed. The 100 reply durations, including the
pending replies, had mean 1964.39 ms, p50 2007 ms, and p99 3385 ms. They are
failure evidence, not successful-write latency or a release-gate pass.

Evidence is archived under `/tmp/quod-h1-144.qF9eqa/`, including
`onehop-c1-100-remote/`, `onehop-resolved-source.json`,
`onehop-resolved-target.json`, and `onehop-safe-log-events.json`. The fleet
counter and logs identify 85 `target_execute` / `engine_result` uncertainties.
They do not individually trace which internal branch each request took; do
not claim that all 85 have a proven identical cause before the regression and
post-fix validation establish that connection.

The source defect is concrete: applying `remote_complete` removes the local
operation owner using the same cleanup that replies `outcome_unknown` to its
waiters. Another source validator can commit that receipt before the local
worker delivers its target result. Removing the owner then reports uncertainty
on normal successful progress. Two related lifecycle holes belong to the same
correction: a late waiter can arrive after the owner was removed, and rebuilding
the unresolved-operation snapshot can remove an owner with pending waiters.

The receipt records completion of source recovery bookkeeping. It contains
the exact target reference and carried transaction evidence, **not the target's
committed-versus-rejected verdict**. Its arrival may not synthesize a successful
write, nor may it cancel delivery of the actual verified result.

## 2. One owner, two independent facts

Keep the existing Simplex operation owner and its monitored
`quod_dtx_coordinator` worker. Distinguish:

- source knowledge: `unknown`, `unresolved`, or `terminal`, derived from the
  existing committed operation projection;
- process progress: `pending`, `running`, `blocked`, or `settling`;
- target result: pending or the exact verified committed/rejected result; and
- the currently waiting callers.

Source knowledge is not a second operation index. The durable source remains
`quod_outcome`, rebuilt from the origin ledger. Simplex keeps only active
recovery/delivery state. Completed operations without waiting callers retain
neither a worker nor a permanent result cache.

| Existing artifact | D/P/E | Owner and meaning |
|---|---|---|
| `remote_claim`, `remote_application`, `remote_complete` | D | Unchanged signed ledger transactions |
| Operation/outcome row | P, disk-backed and rebuildable | `quod_outcome`; exact request digest, target reference, first claim slot, terminal/unresolved state |
| Active operation owner, worker, waiter monitors | P, volatile | Existing Simplex/coordinator lifecycle; not historical truth |
| Outcome endpoint request and snapshot wait | P, volatile | Existing Simplex endpoint-worker registry; retained until the current owner accepts the snapshot or the request terminates |
| Certified target result | P | Existing target-result verification path; no permission or new transaction |
| Wake and client reply messages | Transient runtime messages | Deliver current progress/result; not replayed ontology events or a durable result store |

## 3. Resolution and recovery contract

1. A waiter joins the existing owner. If no owner exists, create the same
   active owner and run the same monitored worker; do not infer the claim's
   durable state from the absence of its volatile owner.
2. The worker reads the source's **existing local outcome projection**. The
   row supplies the first claim slot, exact target reference, request digest,
   and source state. The Simplex callback must not synchronously call back
   into Prolog. This locally committed row is already authoritative; terminal
   result lookup does not add a redundant claim-history read.
3. For an unresolved source claim, retain the current target-application and
   completion-receipt flow. Load its certified claim and compare the exact
   operation/target/anchor/digest binding before preparing the application.
   Recovery uses the already-claimed exact operation; it never re-proves or
   creates another operation id.
4. For a terminal source row, perform **read-only target-result resolution**
   through the existing `quod_dtx_current_view:lookup_outcome` verifier. That
   owner obtains a certified current view and corroborated target outcome. A
   ready co-hosted validator can supply its local view; a co-hosted observer or
   unavailable local validator must not shadow the normal remote route path. No
   fresh `apply_claim`, target submission, or completion receipt is permitted
   after the worker observes the source row as terminal.
5. Both cases deliver the verified result through the existing owner message
   and waiter-reply seam. Only the owner's current worker, exact operation,
   and bound target may deliver it; old workers and wrong bindings cannot
   supply an alternate result.
6. Applying a receipt marks source knowledge terminal. Pending target results
   with waiting callers remain owned until delivery, caller loss, or a real
   failure boundary. Known results are delivered normally; terminal owners
   without callers retire. Normal retirement never sends uncertainty.
7. Restart/snapshot installation reconstructs unresolved recovery from the
   existing projection. A missing row in an unresolved-only snapshot is not
   proof of cancellation. Preserve pending callers and have their existing
   worker re-read authoritative source state. After a complete process restart,
   late callers use the same row-driven path; no historical reaction or result
   message needs replaying.

An application already in flight when another validator's receipt arrives is
not retroactively undone. The terminal rule forbids a new submission after
terminal knowledge; it does not pretend that a message already sent was never
sent. Existing exact-transaction idempotence remains the authority for racing
unresolved recovery workers.

## 4. Wake-up and failure rules

- Exact claim/receipt projection and the current Prolog incarnation's replay
  readiness wake the affected owner. These edges often follow the consensus
  height change; a height-only wake is insufficient.
- Outcome and outcome-barrier requests with the exact anchored identity and
  current committee binding may wait through local Prolog replay in the
  existing endpoint worker. The worker registers on the runtime gproc property
  **before** its first snapshot query and remains alive until Simplex accepts
  the reply against its unchanged exact era/head/member checks. An async
  snapshot overtaken by a demonstrably newer owner head gets at most one
  immediate resample per head; another stale answer parks on actual progress.
- The shared successful Prolog apply-entry transition publishes
  `{projection_advanced, EnginePid, Height}` on that same runtime property for
  every advanced P floor, including metadata, duplicate/rejected transactions,
  no-op blocks, and replay. It is not a material reaction event. Repeated
  already-applied entries and gaps emit nothing. Endpoint workers consume this
  complete floor stream plus replay readiness, not the material-only
  `applied_live`/`rejected_live` stream; ordinary metadata completion cannot
  strand a request at an otherwise quiet height. Each wake only re-reads the
  authoritative snapshot and grants no evidence or authority.
- Serialized Simplex readiness/era/head changes wake the same retained
  snapshot requests. Events arriving before a worker receives its owner's
  accept/wait decision remain queued. Owner death, caller loss and the existing
  endpoint deadline reclaim the worker and its gproc subscription. Snapshot
  reads use the request's remaining deadline, deleting the independent one-second
  helper cutoff rather than adding another timeout.
- A new waiter starts the normal worker when appropriate. It cannot require
  another unrelated block to get service.
- A worker crash is handled at the existing monitored owner. Operational
  termination (`killed`, `shutdown`, `noproc`) is itself a recovery edge;
  unexpected programming faults are logged and blocked rather than immediately
  respawned in a tight crash loop. Pending delivery must not remain indefinitely
  in `settling` merely because a process exited; process exit and successful
  result delivery are different events.
- Foreign-history progress and verifier-name replacement use the existing
  follow/gproc registration. Reattachment preserves operation mode: read-only
  terminal resolution must never become target submission. Retain the same
  follow across attempts. Acknowledge `building`/`unreachable` notices without
  re-driving; only certified `advanced`/`resnapshot` notices are history-progress
  wakes. Dropping and recreating the follow on its immediate `building` notice
  would be polling by messages, even without a timer.
- Source replay/unavailability and a missing not-yet-applied claim park on
  concrete existing progress edges. No ordinary polling, retry-delay ladder,
  idle timer, capacity limit, or extra recovery owner is added. Source identity,
  malformed-row, and binding errors remain typed, loud failures rather than
  quiet temporary waits.
- Caller death removes that caller's monitor and wait. It does not cancel an
  unresolved durable claim. Call completion or timeout also detaches its exact
  wait through the same owner: a long-lived caller can survive its reply alias.
  Cleanup is bound to the original server PID, caller, and unique wait reference
  so it cannot cancel another waiter or touch a replacement server incarnation.
  Terminal work without callers is released.
- Deadline or actual owner failure can still produce `outcome_unknown`. A
  timeout never authorizes re-proving or automatic resubmission.

## 5. Keep / replace / delete

| Keep | Replace or delete |
|---|---|
| Ledger roles, operation identity, outcome index and certified claim lookup | Delete the inference that a missing volatile owner means waiting for a future claim projection |
| One Simplex owner and its monitored coordinator | Replace receipt/snapshot pruning that cancels pending delivery with source-state-aware retirement |
| Existing target-result verifier and certified-current outcome lookup | Delete any need to reapply a terminal operation merely to recover its result |
| Existing follower, gproc lifecycle, correlated messages | Replace mode-resetting follow reattachment and height-only progress assumptions |
| Existing endpoint workers, monitors, request deadline, exact snapshot verifier | Replace one-shot outcome replies and material-only readiness assumptions with retained requests on the shared P-progress stream; remove `outcome_snapshot/2` in favor of the deadline-bound `/3` |
| Existing exact-transaction idempotence and result binding | Delete comments calling late-waiter timeout the desired no-second-path behavior |
| Existing outcome/uncertainty vocabulary and observability | Separate resource cleanup from client failure; no second result cache or normal-completion error |

The existing source/caller and endpoint deadlines remain failure safeguards.
This change does not tune them to hide pending replies; the snapshot helper
uses its already-owning request's remaining budget.

## 6. Tests and gates

Tests exercise the real owner transitions or monitored worker seams and prove
the pre-change failure, not only compare record shapes:

1. receipt before local target result, and target result before receipt;
2. rejected target in the receipt-first ordering, preserving the rejection;
3. late waiter after terminal-owner retirement, and after source replay;
4. unresolved-only snapshot omitting a terminal operation with a pending waiter;
5. absent source row followed by claim projection without another height
   change; replay readiness also resumes the parked request;
6. worker crash/replacement with pending delivery and stale old-worker refusal;
7. verifier unregister/register during terminal read-only resolution; repeated
   building/unreachable notices neither recreate the follow nor trigger work;
8. duplicate completion, conflicting operation/digest/target/anchor, multiple
   waiters, caller death, and timeout while the caller remains alive;
9. terminal resolution performs zero target/receipt submissions and retains
   no permanent owner/result cache after delivery; and
10. a co-hosted observer falls back to the ordinary remote validator route;
    source replay cannot change an already-terminal worker back into submission;
11. real endpoint workers remain parked until same-height replay readiness,
    re-sample an async snapshot overtaken by a newer head, and do not spin when
    the same stale floor is returned twice; a queued pre-decision runtime wake
    is not lost;
12. both outcome request families share this wait; wrong anchor/era is refused,
    a changed committee terminates a parked request, and deadline/owner death
    removes its worker and property subscription; and
13. the real Prolog apply path emits P progress for live/replayed non-material
    blocks, but none for duplicate apply casts or gaps, without creating a
    material reaction event.

Run EUnit, `quod_ask_SUITE`, xref, dialyzer, and diff-check sequentially on the
final tree. Record actual exit codes and disclose test-infrastructure failures.
Review the complete change before committing consensus-/DTX-touching code,
including the retained paths and deleted branches, not only the regression.

After approval, commit, bump separately, deploy, and repeat the same N=4
non-co-hosted one-hop n>=100 fixture without resubmission. Archive raw driver
output, all request results/durations, outcome audits, uncertainty counters,
and exact version/topology. A pending reply fails the run even if its operation
later resolves; do not exclude it from timings or call it a success.

## 7. Format and sequencing boundary

**No ledger, transaction, certificate, wire, or signing-journal format break.**
This volatile lifecycle refactor uses existing durable rows and verification
APIs. No compatibility decoder or migration is needed.

This narrowly expands H1's pre-cut correctness work because the 0.7.144 failure
prevents a valid measurement campaign. It is not the height-cost fix. H1 still
must archive its discriminator matrix and explain at least 95% of the measured
increase using means, with `phase_suspend` and `phase_resume` separate. Keep
0.7.143, 0.7.144, and later runs separately labelled.

The earlier 0.7.143 504 ms two-writer pending remains a distinct untraced item;
this correction does not close it by analogy. The preserved unresolved old
finality group stays intact until its evidence is archived and the coordinated
re-found is scheduled. Development permission to purge removes migration
requirements, not the obligation to preserve the measurement/failure record.

Finality F0/F1 ordering, throughput gates, and review requirements remain in
`finality-round-recovery-plan.md`. H2 starts only after that cut, coordinated
re-found, and fresh fixture growth/re-baselining. L2 remains gated. This slice
starts none of them and does not touch Yan's write-lanes document/SVG work.

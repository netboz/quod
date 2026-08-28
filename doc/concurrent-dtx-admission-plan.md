# Concurrent signed DTX admission plan

**Status:** historical admission refactor, implemented and deployed before the
later multi-group/control-wave hard break. Sections describing the old
single-group gate are retained only as non-normative rationale. The current
contract is summarized in §2 and the current-contract paragraphs of §3.3.

## 1. Problem confirmed on the deployed fleet

An exact agent-signed remote write now works through the complete existing
path:

```text
signed HTTP goal
  -> agent verification in its ontology
  -> ordinary Prolog proof and target ACL
  -> sealed participant plans
  -> one foreign target: remote_claim / application / remote_complete
  -> two or more material ontologies: DTX control waves through Complete
```

A direct signed request committed successfully on the source and target
ontologies. The identity certificate, remote scope, ACL, and DTX validation
paths are therefore not the current blocker.

The reproducible failure is concurrency at the source ontology:

- one signed distributed write succeeds;
- concurrent writes reach the same correct path;
- the first proof occupies the engine's single `dtx_handoff` slot and
  Simplex's single inactive `dtx_intent` slot;
- the others receive `{error, busy}` before any durable Begin exists; and
- HTTP currently mislabels that generic engine refusal as `cursor_busy`.

The earlier tentative diagnosis that target validators were re-reading the
agent key from the wrong ontology was incorrect. Direct source and HTTP runs
disproved it. This plan makes **no** certificate, signature, ACL, proof, or
transaction-format change.

## 2. Fixed architecture decisions

1. There remains one signed-goal path, one Prolog executor, one
   `can_invoke/4` path, and one DTX protocol.
2. The DTX ledger permits multiple active distributed groups. Exact signed
   conflict descriptors serialize only overlapping plans; deterministic
   GroupId wait-die prevents cycles. There is no namespace-global group lock.
3. Effect custody keeps the existing order:
   register an inactive Begin, durably bind every participant effect, then
   activate that exact Begin.
4. Concurrent requests wait only before durable handoff. Waiting is not a
   resubmission, re-proof, or retry, and it creates no ledger record.
5. After activation, the existing anchored outcome and `outcome_unknown`
   rules remain unchanged. Quod never automatically resubmits an uncertain
   operation.
6. No new service, process, store, protocol message, ACL, executor, timer loop,
   or polling path is introduced.
7. No separate hard-coded handoff-queue limit is introduced. The only
   population and lifetime controls are the existing configurable proof-worker
   capacity and proof deadline that already own these requests.
8. The former peer scope-open token bucket is removed. It was a separate,
   fixed peer-facing admission limit and is not part of durable correctness.
   Quod retains the existing optional operator-configured client-ingress
   policy and its ordinary proof-worker/deadline controls; this change adds no
   replacement default quota.

## 3. Chosen solution

### 3.1 Put each Prolog handoff under its proof worker

Today `quod_prolog` owns a global:

```erlang
dtx_handoff = none | #dtx_handoff{}
```

Replace it with a `handoff` field inside the existing `#proof_worker{}` record.
The proof worker is already the exact owner of the proof, caller monitor,
deadline, frozen snapshot, and cancellation. A handoff has no independent
owner, so it should not have independent top-level state.

The attached handoff contains only:

- its Simplex intent id;
- its exact group reference;
- the worker's parked registration caller while registration is pending; and
- `registering | dormant`.

The two callers must keep distinct names. `#proof_worker.from` is the original
client caller; the handoff's `registration_from` is the proof worker blocked in
`reserve_dtx_begin`. Worker identity and PID are read from the containing
worker instead of being duplicated in the handoff record.

This genuinely removes ownership rather than relocating it:

- `#dtx_handoff.worker_ref` duplicates the `workers` map key;
- `#dtx_handoff.worker_pid` duplicates `#proof_worker.pid`; and
- its `request_id` moves into the shared request-id collection below.

The existing deadline/worker-DOWN path already holds the proof-worker record,
so cancellation becomes direct field access instead of a lookup against a
second top-level owner. The local `reserve_dtx_begin` call must carry the
worker's existing absolute `quod_proof_context` deadline into this handoff and
then into Simplex. This is an internal process-local field, not a new wire
value, client option, or timeout.

Several proof workers may therefore be waiting, but each remains correlated to
exactly one handoff. Activation moves only that worker into the existing
`waiting_workers` / `group_waiters` outcome path.

### 3.1.1 Keep an exact live-operation guard with the worker owner

Before durable custody, the existing proof-worker maps are the only complete
record of a signed operation that is already being proved.  The engine compares
the agent-reference/operation-id key, signed request digest, and derived
operation reference against those maps:

- an exact match is the same still-live submission and receives the ordinary
  pre-custody `busy` result;
- the same key with different signed bytes is `operation_conflict`; and
- a different key proceeds normally to proof and FIFO admission.

This is a node-local mirror of the existing durable operation index, not a
distributed deduplication service and not a new outcome owner.  Once a worker
leaves those maps, only the durable index decides alias, conflict, or
`outcome_unknown`.  In particular, a live proof must never be reported as
`outcome_unknown`: it may still fail before it creates durable custody.

### 3.2 Use the existing Simplex request collection once

`quod_prolog` currently has two response paths for requests sent to Simplex:

- the `requests` request-id collection for ordinary appends; and
- a special `request_id` stored in the single DTX handoff.

Refactor them into the existing request-id collection with tagged owners:

```text
{append, TxId}
{dtx_handoff, ProofWorkerRef}
```

One `handle_response_info` dispatches both. A crossed or stale response can
only affect the exact tagged owner. Cancellation removes/deactivates the exact
request id through the same helper already used by ordinary append requests.

Reply ownership is explicit:

- when `quod_prolog` cancels a worker, it first removes/deactivates that exact
  request id with `abandon_request/2`, then casts the intent cancellation;
  Simplex removes that cancelled entry without replying; and
- when Simplex itself rejects or expires a live waiting entry, it replies once
  and the shared request collection consumes that reply.

This permits neither a leaked request alias nor a double reply.

Delete the separate handoff-response scanner and its fallback chain.

### 3.3 Let Simplex serialize admission asynchronously

Simplex already owns the only correct answer to “may another Begin become
inactive now?” because it owns:

- the active-group projection;
- the pending Begin in the signing journal;
- retained DTX submissions; and
- the current node admission binding.

Replace its single `dtx_intent` field with one bundled volatile admission
state:

```text
current engine incarnation + monitor
current dormant intents keyed by GroupId
waiting registration calls: FIFO
```

This is still one Begin-admission mechanism. The FIFO is merely the waiting
side of the current register operation; it is not a second submission path.

When `register_dtx_begin` arrives:

1. verify that it came from the current Prolog engine;
2. verify the Begin and group reference against the current DTX binding;
3. append it to the FIFO; and
4. run the one admission-progress function.

Every waiting entry also carries the proof's existing absolute monotonic
deadline. This is not another timeout: it is the same deadline needed to avoid
promoting work that can no longer complete.

The historical single-group admission predicate had three independently
changing inputs. It is not the current protocol contract:

1. the old DTX projection had no active group;
2. the old signing journal had no pending Begin; and
3. the retained-DTX registry contained no Begin.

The current owner keeps per-GroupId pending Begin custody and derives readiness
from the exact multi-group projection. Independent groups may progress in the
same canonical phase wave; overlapping acquisitions obey the shared wait-die
result.

Put one admission-progress function at the end of the existing Simplex
settling flow, after projection adoption, signing-journal reconciliation, and
retained-submission driving. Then explicitly require every transition that can
open one of those inputs to reach it:

- live commit and complaint-skip paths after `reconcile_signing_state/1`;
- verified catch-up after its projection install, signing-journal
  reconciliation, retained-submission settlement, Prolog replay, and final
  `sync_done(..., {ready, Height})` corroboration;
- committed, rejected, retired, or abandoned retained Begin removal;
- adoption of a committed or replayed DTX projection that clears the active
  group;
- dormant-intent activation or cancellation.

The catch-up sink passes `apply_catchup_window` through `keep_progress`, but
the node is still in `pulling` state at that point and must not sign. The
recovery owner always follows its last verified sink with
`sync_done(..., {ready, Height})`; that existing callback also passes through
`keep_progress` and is the first signing-safe point at which a waiting request
may promote. The implementation test drives both real callbacks and has no
timer or unrelated event between them. `finalize_applied` also reaches
`keep_progress`, but it is not itself one of the three gate inputs and is not
the event documented as releasing the FIFO.

The progress function uses no sleep, retry timer, or blocking call:

- if the ledger/journal admission gate is temporarily closed, it leaves the
  oldest request parked;
- if the oldest request's existing deadline has passed, it replies with the
  existing proof-limit failure, removes it, and examines the next request;
- when the exact group's gate opens, it rechecks that request against the
  current binding, retains that GroupId's dormant intent, and replies
  `accepted`;
- if a committee/admission change made it permanently invalid, it rejects that
  request and examines the next one; and
- it never admits a duplicate intent for the same GroupId; independent groups
  are governed by the shared multi-group readiness/conflict projection.

The progress function checks only the FIFO head. It does not sweep the queue.
Every non-head entry remains owned by its existing proof worker, whose existing
deadline timer kills that worker and makes `quod_prolog` cancel the exact FIFO
entry. If that cancellation removes the head, Simplex runs admission progress
for the next entry. The head deadline check above only closes the race in which
Simplex observes expiry before the worker-deadline message is processed.

A current Prolog-engine `DOWN` is cleanup, not a promotion event: Simplex drops
the dormant intent and every queued registration belonging to that incarnation.
There is deliberately nothing from the dead engine to promote. A replacement
engine's later `register_dtx_begin` call starts admission progress normally.

Activation removes the exact dormant intent and hands it to the existing
signing-journal submission path. The next registration remains parked until
the current group is durably resolved and the existing admission predicate
becomes true again.

### 3.4 Why waiting stays at the pre-Begin seam

The alternative is to queue before proof and prove only when the previous group
finishes. That gives each request a fresher snapshot, but Quod cannot know that
an `execute` goal needs DTX until Prolog has run it:

- serializing every signed execute at ingress would also serialize ordinary
  local writes that the existing content batcher can process concurrently, and
  would add a signed-client-only admission rule; or
- proving once to discover DTX, discarding that result, and proving again later
  would re-execute the goal and its external reads through a second retry path.

Both alternatives lose existing proof/consensus pipelining and add more policy
than the problem requires. Waiting at the existing register/bind/activate seam
keeps the one completed sealed proof and lets its existing target attestation,
ACL transcript, and OCC read set decide whether it is still valid.

This choice has one deliberate public consequence. Today a handoff-contention
`busy` happens before Begin, consumes no operation id, and permits retry with
the same signed operation. With FIFO, a promoted request may commit Begin and
claim its operation id, then abort at Prepare because its OCC reads became
stale while waiting. That result is terminal and unambiguous; retrying the
application action requires a newly signed operation id. The queue never
re-proves it or hides that abort.

### 3.5 Keep cancellation at the same ownership boundary

- A client disconnect or proof deadline kills its existing proof worker.
- `quod_prolog` cancels only the handoff attached to that worker.
- Simplex removes the exact waiting or dormant intent.
- Cancelling the current dormant intent lets the same progress function
  consider the next FIFO entry.
- Death of the current Prolog engine clears all of that engine incarnation's
  volatile intents at once.
- Once an intent was activated, none of these pre-handoff cancellations apply;
  the existing durable DTX recovery path owns it.

No cancellation broadcasts, queue sweeps in another process, or special
client retry behavior are added.

The existing activation capacity check still runs after effect custody was
bound. If `waiting_workers` or `group_waiters` has reached its existing
configured capacity, activation cancels this still-pre-handoff intent, the
already-bound rows retire through definitive absence, and the FIFO considers
the next entry. This remains the existing pre-handoff failure; the queue adds
no new error or capacity rule.

### 3.6 Consolidate the public busy renderer

`busy` from ordinary read/execute admission means the ontology cannot accept
another proof now. It must render as `ontology_busy` (HTTP 503), not
`cursor_busy`.

The correct mapping already exists in `quod_client_result`: raw `busy` becomes
`ontology_busy`, and `http_normalized/2` renders it as HTTP 503. Delete the
competing flat `{error, busy} -> cursor_busy` behavior from
`quod_client_http:signed_goal_result/1` and route ordinary signed-goal results
through that existing owner. Cursor ingress must translate its own bare cursor
states before the shared renderer. Do not add a new route or renderer.

After the FIFO change, DTX contention itself no longer produces either error.
`ontology_busy` remains possible only from real engine/proof capacity.

## 4. Exact keep / refactor / delete map

| Area | Keep exactly | Refactor | Delete completely |
|---|---|---|---|
| signed ingress | session, signature, agent certificate, operation id, target selection | consolidate on `quod_client_result`; tag cursor-only states at cursor ingress | competing flat busy renderer and execute paths that can report `cursor_busy` |
| Prolog execution | `execute_signed`, proof workers, scopes, `can_invoke/4`, sealing | attach handoff state to `#proof_worker{}` | top-level `#s.dtx_handoff` ownership |
| Simplex replies | existing request-id collection and exact correlation | tag append and handoff owners in the same collection | special single-handoff response scanner |
| pre-Begin custody | register -> bind effects -> activate -> cancel | allow several registration calls to wait FIFO | “second handoff returns busy” branch |
| Simplex admission | current binding checks, journal check, active-group check | one bundled volatile current+waiting state and one progress function | single `dtx_intent = none | record` assumptions |
| durable DTX | Begin through Complete, per-GroupId recovery, exact conflicts and canonical same-phase waves | generalize admission onto the multi-group projection | singleton active-group gate and namespace lock |
| ACL and identity | agent verification in A, target transcript and `can_invoke/4` | none | no compatibility or fallback validation |
| storage and wire | ledger V4, DTX codecs, signing journal, outcomes | none | none |
| effect custody | one effect journal and existing group reference reconciliation | none | none |

## 5. Failure and race rules

| Situation | Required result |
|---|---|
| second request arrives while another dormant intent is binding effects | its own GroupId is admitted when the shared readiness/conflict projection permits; otherwise it remains parked, with no `busy` or ledger write |
| second request overlaps an active group | shared wait-die/readiness decides whether it waits or aborts; an independent group is not namespace-globally blocked |
| queued proof reaches its existing deadline | remove only that proof and intent; return the existing pre-handoff failure |
| queued caller disconnects | remove only that proof and intent; no durable outcome exists |
| current dormant proof dies before activation | cancel it, then consider the next FIFO entry |
| effect binding fails | cancel that exact dormant intent; already-bound rows use existing definitive-absence cleanup; then consider the next entry |
| Prolog engine incarnation dies | Simplex drops every volatile intent owned by it; durable submissions and committed groups continue normally |
| node admission changes while a request waits | recheck on promotion and reject stale binding; never sign it |
| wrong intent id, group ref, PID, or crossed response | reject/ignore only that correlation; never advance another request |
| activation has occurred and reply is lost | existing anchored `outcome_unknown` behavior; never queue or submit it again |
| queued plan is semantically stale when later prepared | ordinary DTX/OCC validation decides it; the queue does not re-prove or rewrite it |
| promoted Begin claims the operation, then Prepare reports an OCC conflict | terminal group abort; that operation id remains consumed and a deliberate application retry needs a new signed operation id |
| activation capacity is unavailable after effects were bound | cancel before activation, let bound rows retire through definitive absence, and continue FIFO admission |
| restart with only volatile queued requests | requests disappear and callers get a definite pre-handoff failure; no recovery row is invented |
| restart after activation | signing journal / ledger recovery continues exactly as today |

## 6. Performance and observability

The change removes refusal under ordinary concurrency. Independent groups may
advance together in canonical same-phase waves; overlapping plans remain
serialized by the shared conflict projection rather than a namespace-global
lock.

The FIFO adds no process and no polling. Waiting workers keep their existing
proof snapshot and deadline, so memory and MVCC retention remain charged to
the already-configured proof-worker capacity. Unlike today's immediate `busy`,
each queued worker may retain that frozen snapshot and pin MVCC history for up
to the remaining proof deadline (60 seconds by default). Promotion checks the
same absolute deadline and drops expired heads before signing. No additional
queue limit or lifetime is compiled into the code.

Add bounded-label metrics at the existing namespace metrics seam:

- current waiting pre-Begin registrations;
- the number of distinct dormant GroupId intents retained; and
- wait time before a registration is accepted.

The dormant-intent gauge replaces the current Prolog `get_stats` boolean
`dtx_handoff`; it is not an additional observation of the same ownership from a
second process.

Namespace is the existing hosted-namespace label. No agent, target ontology,
goal, group id, error payload, or queue position becomes a metric label. Add
the corresponding dashboard panels with the implementation, not as a later
leftover.

The load report must separate:

- proof time;
- pre-Begin wait time;
- end-to-end commit time;
- committed, policy-failed, OCC-failed, uncertain, and transport-failed
  outcomes; and
- logs at warning/error/critical level during the run.

## 7. Format and deployment impact

There is no ledger, transaction, DTX, journal, certificate, Prolog fact-format,
or wire-envelope change. The queue, live-operation guard, and attached handoff
are process-local volatile state.

Therefore:

- no new Quod parser or protocol version;
- no genesis change;
- no ledger reset or re-found;
- no compatibility decoder or migration branch; and
- activation is a normal rolling image deployment after tests and review.

The pinned Erlog dependency changes from `7516121` to `9942191`.  It permits
the already-versioned signed-goal grammar to carry an opaque target functor
through relays, and leaves its materialization to the selected target
ontology. During a rolling deployment an older allocation can reject such a
request while an upgraded allocation accepts it. That is a temporary
availability difference only: the signed request is unchanged, no ledger
format differs, and validation cannot disagree. The client never retries
automatically. A user or caller may deliberately resubmit only an ordinary
pre-custody availability refusal after the fleet is uniform, never an uncertain
operation.

During a rolling deployment, upgraded nodes queue while old nodes may still
return the old pre-Begin `busy`. Admission is local to the hosting node and the
ledger protocol is unchanged, so the mixed fleet cannot disagree on blocks or
validation. It degrades safely until every allocation runs the new image.

## 8. Implementation slices

### Slice 1 — replace the single slots

1. Attach handoff state to proof workers.
2. Merge handoff replies into the existing tagged Simplex request collection.
3. Replace Simplex's single intent with the one bundled FIFO admission owner.
4. Drive promotion after every transition that can open any of the three
   admission-gate inputs, including verified catch-up.
5. Preserve register/bind/activate ordering and all cancellation semantics.
6. Replace the old contention test with non-vacuous FIFO, correlation,
   cancellation, engine-death, and binding-change tests.

Do not leave the tree between the old single-slot behavior and the FIFO owner:
both ends change and are tested together.

### Slice 2 — public result, metrics, docs, and live acceptance

1. Delete the competing HTTP busy renderer and consolidate on the existing
   `quod_client_result` mapping, with cursor-only states tagged at cursor
   ingress.
2. Add the three metrics and dashboard panels.
3. Update every affected architecture document and code comment.
4. Extend the existing signed cross-ontology workload; do not create a second
   benchmark client or direct Erlang submission path.
5. Run the complete local gates, deploy normally, and run live acceptance.

Slice 2 is part of the same change set. It is not deferred cleanup.

## 9. Required tests

### Unit and component tests

1. Three handoffs registered together preserve FIFO registration ownership;
   independent GroupIds may become dormant together, while a duplicate or
   conflicting group cannot bypass shared readiness.
2. A later Simplex response cannot wake or alter the wrong proof worker.
3. Cancelling the first, middle, or last waiter removes only that intent.
4. Cancelling the dormant head promotes the next request when admission is
   open.
5. Activation retains each exact Begin once; another independent GroupId may
   progress, while duplicate or conflicting work cannot bypass readiness.
6. Durable group resolution promotes the next request without polling on both
   live commit and the catch-up owner's final verified-ready path.
7. Engine `DOWN` clears every volatile intent but not an activated submission.
8. Admission-generation change rejects queued stale Begins before signing.
9. Effect-binding failure cleans its rows through the existing outcome/barrier
   path and does not poison the next request.
10. Proof timeout and caller death leave no handoff, request id, monitor,
    worker, snapshot pin, effect row, or Simplex waiter.
11. The unified request collection handles crossed append/handoff replies and
    stale replies safely.
12. Generic execute `busy` renders `ontology_busy`; cursor command contention
    alone renders `cursor_busy`.
13. An expired FIFO head is dropped without activation and the next live entry
    promotes immediately.
14. An activation-capacity refusal after effect binding retires those bound
    rows through definitive absence and does not stall the next entry.
15. Two conflicting read-modify-write operations prove concurrently: the first
    commits, the promoted second reaches Prepare, aborts with the existing OCC
    reason, and its already-claimed operation id resolves to that terminal
    abort rather than becoming reusable.
16. A retained Begin is removed independently while the projection and journal
    gates are already open; that exact third-gate transition promotes the FIFO
    head without another commit, tick, or request.
17. An expired non-head entry is cancelled exactly once by its proof worker and
    removed without disturbing the head or its live neighbors.
18. Prolog-owned cancellation abandons the request alias and produces zero
    later Simplex replies; Simplex-owned rejection or head-expiry produces
    exactly one correlated reply.
19. Existing single active-group, operation-id deduplication, uncertainty,
    ACL, certificate, and DTX effect-custody tests remain unchanged and green.

### End-to-end tests

1. One real signed agent in A performs at least eight concurrent independent
   writes to B; none is rejected as `cursor_busy`, every operation reference is
   unique, and every expected fact/outcome is committed exactly once.
2. Run a genuinely conflicting signed pair and prove the losing operation id
   has one terminal aborted outcome; a deliberate retry uses a new signed id.
3. Repeat through A -> B -> C and A -> B -> C -> D goals using the same signed
   request and ordinary target ACLs.
4. Race the same operation id through two gateways; preserve one durable claim
   and one logical outcome.
5. Race two distinct signed read-modify-write operations whose proofs both read
   the same fact. Prove that one commits, the later promoted operation is
   terminally aborted by its stale sealed read, and its original operation id
   resolves to that abort rather than becoming retryable.
6. Disconnect one queued caller, kill one queued proof worker, and restart the
   source engine before handoff; neighboring requests remain correct and no
   ledger entry exists for the cancelled requests.
6. Restart after activation; the group completes or exposes its anchored
   outcome without resubmission.
7. Resolve the preceding group through catch-up on the queue-owning node and
   prove the next request promotes immediately on an otherwise quiet ontology.
8. Remote read and node-authored DTX baselines remain green.
9. Run the cross-ontology workload concurrently with the normal consensus load
   and monitor all allocation logs for warning/error/critical messages.

### Gates

- `rebar3 compile`
- focused EUnit during development, then full `rebar3 eunit`
- the existing join and signed remote-lifecycle CT suites
- new signed concurrent-DTX CT acceptance
- `rebar3 xref`
- `rebar3 dialyzer`
- script checks/tests for the workload changes
- dashboard validation
- `git diff --check`

No gate is claimed unless it was run on the final tree.

## 10. Consistency and dead-path closure

Before review, search the complete repository—not only compiled callers—for:

- `#s.dtx_handoff`, its boolean `get_stats` field, and the global
  `#dtx_handoff` ownership comment; replace that boolean with the one
  Simplex-owned dormant-intent gauge rather than retaining both;
- `register_dtx_handoff/6`'s `{error, busy}` fallback,
  `handle_dtx_handoff_response/2`, and its fallback in
  `handle_response_info/2`;
- `#s.dtx_intent` and every helper assuming `none | #dtx_intent{}`;
- `dormant_dtx_intent_contention_is_busy_and_first_activates_test/0` and its
  comment that the second group is refused;
- “pending pre-Begin handoffs = 1” capacity wording;
- comments claiming one global engine-owned handoff;
- the flat `{error, busy} -> cursor_busy` clause in `quod_client_http`;
- a special handoff response path beside the shared request collection; and
- unused test exports/helpers introduced during the refactor.

Do not delete live, unrelated capacity behavior while doing that sweep:

- `{ontology_busy, Ns}` remains the real target proof/scope-capacity result;
- the scope-wire bare `busy` alphabet remains live; and
- ordinary proof/scope capacity remains configurable and enforced.

Update at least:

- `doc/distributed-proof-plan.md`: distinguish volatile waiting calls from
  per-GroupId accepted/journaled Begins and concurrent conflict-safe groups;
- `doc/dtx-durable-effects-plan.md`: replace the documented retryable-busy
  contention contract with FIFO pre-handoff waiting and the terminal
  operation-id consequence after Begin;
- `doc/inter-ontology.md`: signed write concurrency and benchmark outcomes;
- client/auth documentation for the corrected public busy name and the rule
  that a promoted, claimed operation which later aborts needs a new operation
  id for a deliberate application retry;
- affected Erlang moduledocs/comments, metrics documentation, and dashboards.

That statement described the historical journal. The current hard break stores
pending Begin custody by GroupId; no document may retain the former singleton
as a current invariant. Waiting registrations are still volatile until they
cross that boundary.

The closure criterion is zero unreachable compatibility clauses, zero old
single-slot ownership, zero duplicate response dispatch, and no document or
test describing behavior the code no longer has.

## 11. Acceptance verdict

The change is complete only when concurrent signed remote writes use this one
path:

```text
existing proof worker
  -> existing register/bind/activate seam
  -> one Simplex FIFO admission owner
  -> existing signing journal
  -> existing DTX consensus and outcome path
```

The safe outcome is admission without the old handoff-contention refusal.
Existing proof-capacity, deadline, policy, OCC, conflict, and durable-outcome
results still apply. This is not automatic retry, a second queue service, or a
special signed-client executor.

## 12. Questions the architecture review must answer

1. Does attaching handoff state to `#proof_worker{}` remove an owner rather
   than merely moving duplicate state?
2. Can the shared request-id collection correlate append and handoff replies
   without any remaining fallback response path?
3. Does the Simplex FIFO preserve caller ownership while retaining each
   dormant GroupId exactly once and letting independent groups progress under
   the one multi-group projection?
4. Is a sealed plan that waits behind another group still governed entirely by
   its existing target attestation, ACL transcript, and OCC read set, with no
   need or permission to re-prove it?
5. Do every cancellation and engine-death ordering remove the exact volatile
   request while preserving every already-activated group?
6. Is the FIFO population fully owned by the existing configurable proof
   workers and deadline, with no new hard-coded quota or unowned caller?
7. Are `ontology_busy` and `cursor_busy` distinguished once at the existing
   public-result boundary?
8. Does the keep/refactor/delete sweep leave zero single-slot branch, dead
   compatibility clause, stale test helper, or contradictory document?
9. Does every transition that can open the projection, journal, or retained
   submission gate drive FIFO promotion immediately, including catch-up on a
   quiet namespace?
10. Is the terminal operation-id consequence of a post-wait OCC abort explicit
    in code results, tests, and client documentation?

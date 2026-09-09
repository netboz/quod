# Performance roadmap

**Status: proposed sequencing based on the measured 0.7.151 write anatomy.
Claude confirmed the Phase-1A owner model and complete open-site inventory.
The backtracking contract below preserves pinned proofs across ordinary
appends. The architecture audit is recorded in §3.6. Claude has endorsed A2's
single-producer page-credit grammar and lifecycle, and the original-budget
capture correction in the page-credit plan §6.1. The A1/A2 code review is
closed (1756/0 EUnit, both CT suites 26/26); the completed A1–A4 cut is
reviewed and approved, with independently reproduced source gates (1799/0
EUnit, both CT suites 26/26, xref and dialyzer). The cut was committed and
deployed as 0.7.152; Claude independently approved its hardware evidence
(400/400 committed, live scans eliminated in the measured sample). The
absolute latency gate remains unmet. Phase 1B Cut 1 is reviewed and committed
as `e4ad3e1`, with the separate 0.7.153 bump `43bd48c`. Yan authorized
continuation to Cut 2, independently reviewed and committed as `8ca87e8`
(separate 0.7.154 bump `dd98f53`). Cut 3 was independently reviewed with
reproduced sequential gates (EUnit 1850/0, ask and QUIC CT 26/26 each, xref
and Dialyzer), then committed as `ecb7861` (0.7.155 bump `49f3759`). All three
cuts are deployed and the matched N=4 measurement is complete: 400/400
committed, one-hop mean 381.50 ms serial / 874.46 ms c4. The
[hardware evidence](phase-1b-hardware-results.md) is independently reviewed and approved;
absolute latency gates remain unmet, and the 1.625-second serial outlier's
approval stall is localized but its triggering event is not yet established.
The c4 result-return stage regressed 14.81%; both findings are the subject of
the [trace-only diagnosis cut](consensus-result-tracing.md), independently
reviewed and deployed as 0.7.156. Its [retained-ledger capture](consensus-tracing-hardware-results.md)
committed 400/400 writes, with one-hop p50/p99 371/422 ms c1 and 857/1167 ms c4;
neither absolute gate passes. A covered source block waits 288.780 ms after
local durable support, and result delivery waits 22.817 ms mean at the source
owner under c4. Neither is yet an exclusive root-cause attribution; the old
mixed-receipt outlier did not recur. This is not authorization for a
protocol change: the next [owner-turn diagnostic](consensus-owner-turn-tracing.md)
is local instrumentation, independently reviewed and deployed as 0.7.157
(EUnit 1885/0, ask/QUIC 26/26, Simplex 12/12, xref and dialyzer clean).
Its independently approved [hardware evidence](consensus-owner-turn-hardware-results.md) records
200/200 tracing-off writes committed, but a new 9.684-second mixed claim/receipt
tail with foreign validation returning `abstain` after 6.002 seconds. This
receipt is not a duplicate. The tracing-on attempt failed its read-only
preflight before measured writes; a later Tempo OOM also defeats a loss-free
capture claim. No protocol fix or successful on/off overhead comparison is
established. After restoring tracing off, a separate read-only control exposed
37.074 seconds of successive cold foreign-history stages (389/1138 entries);
both verifications passed, but exceeded the 35-second HTTP budget. A distinct
warm read then passed in 11.015 ms. These are health probes, not write latency
samples, and the cold replay's fine-grained attribution remains incomplete.
The cold-start item is still open. Serial `operation_result` has risen
18.4% then another 2.27%, now 195.679 ms. The source/endpoint residual is now
58.302/152.248 ms at c1/c4 (the previous c4 gap was 137.462 ms), and c4
source-owner delivery rose 22.817→26.909 ms. All remain unlocated or only
partially attributed. The next approved owner cut is the
[exact-reference lifecycle/trace contract](exact-reference-lifecycle-tracing-contract.md)
at the existing foreign-log owner: caller versus shared-work lifetime,
context-independent coalescing, queue/park/wake ordering and full cold-rebuild
coverage. Claude approved diagnostics and the specified lifecycle refactoring
as one coherent cut, conditional on fail-before wake evidence and a same-cache-
file restart-custody proof; final implementation review remains required before
commit/deploy.
The fail-before tests now reproduce deadline, sharing and wake-order defects;
the actual same-inode append test also refutes watcher-only restart exclusion.
The resulting [cache-writer custody extension](foreign-cache-writer-custody-contract.md)
was returned for review and is now approved within the same coherent cut:
existing-worker registration, actual-death release, admitted custody waits,
session-safe cleanup and the existing permanent-registry-application boundary.
The coherent cut's final independent review closed on 2026-09-10, with
fail-before controls and permanent lifecycle, file-custody and real-SDK
regressions. Claude reproduced EUnit 1937/0, ask/QUIC 26/26, Simplex 12/12,
xref, Dialyzer and the production release build. Its
[implementation checkpoint](exact-reference-lifecycle-tracing-contract.md#implementation-checkpoint--2026-09-09)
records the exact scope and local gate archive. Commit and preserved-ledger
deployment are approved; no new benchmark or hardware closure is claimed here.
This is not authorization for a
duplicate-receipt validation bypass. This
does not close the separate result-authentication design or authorize a
release-safety claim. After-terminal quiet-source
lag remains the explicit limitation in §6.2: consume-once progress alone does not
guarantee eventual fetch, and the proposed feed-semantics change is deferred.
Phase 1B's historical-committee shortcut was rejected as unsafe. The result
commitment and recovery commitment remain design gates before F1. This
document authorizes no implementation. Every behavioral phase requires
architecture review and a measured exit gate.**

The evidence is in [write-latency-anatomy.md](write-latency-anatomy.md). This
file owns sequencing only; detailed mechanics remain in their existing plans.

## 1. Rules for every phase

1. Correct the owner and delete the wrong path. Do not add a bypass,
   compatibility branch, benchmark exception, second cache, verifier, or
   authority.
2. Ordinary progress is message-driven. No poll or retry-delay ladder discovers
   progress; deadlines remain terminal failure safeguards only.
3. Reuse registered Erlang owners and existing messages. A missing owner
   returns the existing typed unavailable result.
4. Add no arbitrary population, worker, or history limit.
5. Tests prove correctness and structural work bounds; hardware proves latency.
6. Remove superseded code, tests, comments, metrics, and documentation in the
   phase that replaces them.
7. Report all requests and use means for attribution. Never subtract marginal
   percentiles.

### 1.1 Time is not a progress signal

The no-polling rule does not mean that a distributed system has no clocks.
Request deadlines, transport failure detection, certificate expiry, leases and
a consensus pacemaker are terminal/safety protocol clocks. They may conclude
that an expected message did not arrive; successful ordinary progress must not
wait for them.

Every touched wait must therefore be classified in review:

- **progress edge** — owner result, monitor, QUIC link/credit, committed-height,
  directory property or runtime publication; this is what resumes healthy work;
- **terminal clock** — ends or invalidates stalled work and returns a typed
  outcome; it never starts the next normal attempt;
- **poll/retry clock** — periodically asks whether ordinary progress happened;
  forbidden and deleted rather than retuned.

The pre-cut catch-up server's fixed-worker overflow was a direct violation: it
silently dropped an admitted request and made the requester discover that fact
through its deadline. Phase 1A removes that behavior. The existing Simplex
pacemaker/sync pacing is outside the ledger-view cut, but the Phase-2 finality
review must prove that its timers are failure-detection/pacemaker clocks and
that a healthy write, route, credit grant, or catch-up advance is resumed by a
message edge. Any healthy path that waits for the next tick is brought into the
finality refactor; this document does not hide it under a blanket “no polling”
claim.

### 1.2 Adversarial-review disposition

| area | disposition | consequence |
|---|---|---|
| Phase 1A owner views and production open-site inventory | A1–A4 source and 0.7.152 hardware evidence reviewed | live scans removed in the sample; absolute latency gate unmet; Phase 1B requires its own review |
| path-based foreign-cache replay | confirmed worse than linear across pages | one cold owner open, then session-based pages only |
| fixed 32 catch-up workers with silent drop | rejected | replace at the existing link/owner with message-driven pressure and terminal replies, not another cap or unbounded spawn |
| historical-committee identity shortcut | rejected as unsafe after committee replacement | retain latest-head/current-committee verification |
| block-committed result receipts | direction accepted, computation contract incomplete | release-safety claim stays blocked; the approved Phase-1A development measurement does not close this gate or let F1 freeze it |
| snapshot/recovery commitment | three storage roles accepted, custody/root/install contract incomplete | F1 cannot freeze it yet and no pruning is authorized |

## 2. Phase 0 — measurement and correctness

Measurement is complete:

- the 0.7.151 controlled run completed 400/400 requests without uncertainty;
- distributed traces explain 99.65--99.92% of representative one-hop requests;
- two per-request full ledger scans own the continuing height slope;
- consensus and the DTX phase index do not own that measured slope;
- the archive is `/tmp/quod-trace-151-clean/`.

One correctness gate remains: fix the live application-result authentication
mismatch described in the anatomy §9. The clean permanent design is the normal
blockchain rule: the certified block commits the deterministic applied/rejected
outcome for each included transaction (analogous to a receipt commitment), and
the one committed-projection reducer verifies and consumes that same outcome.
Then the existing block certificate authenticates both inclusion and result;
the endpoint cannot flip a status while reusing the same entry proof.

That shape is a direction, not yet an implementation contract. Blocks are
currently proposed from transactions before their authoritative outcomes
exist, proposals may advance ahead of applied state, and same-block OCC can
change a later transaction's result. Before F1, specify at the existing
proposal/reducer owners: the exact parent state used to compute the ordered
receipt vector, which process computes it, what every validator recomputes
before voting, how replay and duplicates recover it, and how useful proposal
pipelining is preserved. A receipt field must not merely move an
unauthenticated endpoint assertion into signed bytes.

Mandatory proof cases before accepting that contract are: identical inclusion
evidence paired with applied and rejected results (exactly one may verify), two
same-block transactions whose OCC results differ by order, a proposal whose
parent is approved but not yet applied, replay, duplicate transaction ids, and
restart recovery from the committed receipt vector.

Because that is a canonical block/entry change, decide it in the finality F1
format review and bundle it into the one coordinated cut. Do not create a
permanent second outcome-certificate or target-query mechanism merely to patch
the current wire. Until the cut, the existing quorum current-view outcome
lookup is the only already-built authority able to confirm a live status; if a
pre-cut correction is required, it must reuse that owner and be explicitly
deleted by F1. The development fleet is not release-safe while a one-peer live
reply can claim an unauthenticated status. Any Simplex/DTX correction returns
to review before commit.

Exit: these documents reviewed, and the result-authority defect closed or
explicitly blocking a release-safety claim. The completed-cut review expressly
permits the Phase-1A development deployment and measurement with that defect
carried openly, not repaired or waived. Measurement spans stay only while
later gates use them.

## 3. Phase 1A — one live ledger-view architecture

The two measured evidence scans are instances of a wider ownership error:
several live readers receive a filesystem path and reconstruct an index which
the ledger owner already holds. Replace that convention once.

### 3.1 One rule

`quod_ledger_store:open/2` and `open_ro/2` reconstruct an index from durable
bytes. Production uses them only when a process becomes responsible for a log
whose verified index is not in memory, or in an explicitly selected offline
inspection path. They are never a fallback inside a live request.

While an owner is live, every other process receives an immutable
`quod_ledger_store:session()` captured by that owner and opens it through
`open_ro_snapshot/1`. The snapshot supplies bytes and an already-verified
sparse index; any accompanying projection supplies semantic state. File paths
remain private placement details, not a second read capability.

For a hosted ontology, replace `history_source/2`, `history_current_view/2`,
`ledger_read_snapshot/1`, and private `local_reference_source/1` with one local
history view from the registered `quod_simplex` owner. One owner turn checks
the exact incarnation and requested readiness, then captures the immutable
ledger session and its matching verified projection. Every live consumer uses
that object. It contains the anchored identity, committed height, immutable
session and matching projection; it contains no ledger path or raw file handle.
The A1 API in this cut is `history_view/3`, with the operation's original
absolute deadline; there must be one shape and one
owner, not a forwarding compatibility layer. Capture committed height and the
owner's apply-sent frontier separately. Neither an apply-sent height nor the
history projection proves that the Prolog MVCC store has acknowledged apply;
existing application/visibility checks retain that job.

Byte availability and execution readiness are different requirements on this
same view. Boot and catch-up may borrow an already-verified committed prefix
before Prolog replay completes; they must not require the readiness whose
construction needs those bytes. Read-ready/validator consumers retain their
existing stricter admission checks. This is one accessor with explicit
requirements, not an alternate execution or verification path.

For fresh recovery, `committed` can capture a zero-length prefix from an
already-created writer with a pinned identity. No genesis is thereby verified
and no read-ready/validator capability is granted; runtime founding remains
pending until slot 1 exists. This removes the separate status-based recovery
capture rather than creating a bootstrap-only history accessor.

Current-era evidence uses `open_ro_snapshot/1` plus exact `read_at/2`. An
older-era reference still uses the existing historical verifier because its
semantic projection may differ at that slot, but its byte source is the same
immutable local snapshot rather than a path reopen. The existing foreign-log
worker/cache may retain the verified historical result; no new verifier or
local-history cache is created.

For a followed foreign ontology, `quod_foreign_log` is the ledger-session
owner. It already retains `cache_session` after verified work. Pass that
immutable session to its existing materializer and page reader when advancing;
do not let those workers reopen and rescan the cache path.

The foreign advance message must carry the requested height/head, projection,
session, and owner/worker incarnation as one indivisible view. Coalescing a
newer height with an older bounded session is structurally invalid. Replace
the target view atomically while retaining the already-verified contiguous
prefix; an ordinary append does not restart that work or invalidate an
admitted immutable reader. Reject a superseded publication as the current
view, and reject replies belonging to a replaced worker or owner. Close each
opened reader handle on termination; a session value itself owns no file
descriptor and is simply discarded when no longer referenced.

Snapshot refusal or owner death returns the existing typed unavailable result
at a live request boundary. Owner liveness is not certificate authority: losing
an owner does not falsify an already-verified historical entry, and ordinary
append does not invalidate its bounded snapshot. A stale owner reply cannot
establish current readiness or replace a current publication. The existing
request/job owner must handle the exact source incarnation's death while work
is parked; checking liveness only before and after a blocking call is not a
wake mechanism. Release that request through its existing cancellation and
monitor path, without cancelling another caller's shared verification job.
The existing route, monitor, committed-height, and projection messages wake
the owning operation. Do not fall through to a path scan, poll, or delayed
retry, including an immediate self-message loop after an unsuccessful read.

Owner unavailability is transient at live consumers. In particular, runtime
founding must not translate `not_ready` or an owner replacement into a
permanent unhealthy ontology. Permanent unhealthy remains reserved for a
verified malformed or conflicting founding state; the existing monitor and
runtime publication edges re-drive transient owner readiness.

### 3.2 Complete production sweep

This table records the pre-cut defects and their required replacement; it is
not a claim that deleted paths remain in the implementation candidate.

| pre-cut site | pre-cut behavior | required disposition |
|---|---|---|
| `quod_simplex:operation_claim_evidence_at/5` and `transaction_evidence_at/5` | `open_ro` scans the complete hosted ledger for each result | use the one owner view, exact indexed read; delete both path-based helpers |
| `quod_catchup:open_read_view/2` | uses an owner snapshot, but silently full-scans when the live owner is late or busy | live network serving requires the owner snapshot; return typed not-ready and let the caller use another certified route/event wake; delete the transparent fallback |
| `quod_catchup:handle_req/5` | after 32 workers, silently drops a valid request so the caller discovers pressure only by timeout | delete the arbitrary worker cap and silent-drop path in the same owner refactor. Keep work under the existing catch-up/link owners and give every admitted request a terminal reply. The implementation review must choose message-driven link backpressure or protocol-derived per-link serialization; it must not replace the defect with unbounded process spawning, an application mailbox flood, or another fixed population number. Page/frame byte bounds remain protocol safety bounds |
| `quod_foreign_log:follow_local_snapshot/9` | opens the co-hosted ledger path merely to learn its tip | take height and snapshot from the same owner view; no disk discovery |
| `quod_foreign_projection:materialize_turn/1` | reopens and scans the verified foreign cache on every bounded projection turn | foreign-log owner passes its retained immutable cache session on each advance; page turns use `open_ro_snapshot` |
| `quod_foreign_log:replay_cache/*` | after opening the cache once, calls the path-based page server, which reopens and rescans that same cache for every replay page | read bounded pages from the already-open cache handle; one cold index reconstruction, never one per page |
| `quod_explorer_http:with_store*` | every block/transaction page rebuilds the local index, including while the owner is running | use the hosted owner's snapshot first. Preserve stopped-ledger browsing only as an explicitly selected offline inspection path, never as a failure fallback from a live owner; Phase 4's archive owner eventually supplies indexed views for that case |
| `quod_runtime:read_founding/2` | runtime reconciliation rescans the ledger to read slot 1 | use the same Simplex view and exact read; runtime cannot be healthy without that owner |
| `quod_catchup:backfill_phase_index/5` | a recovery attempt semantically replays the already-sunk prefix when it first encounters DTX | classify as cold/gap recovery, not a live request. Open its input from an owner snapshot now; eliminate the semantic replay later with a certified recovery snapshot |
| `quod_ontology:existing_ledger/2`, Simplex restore, first foreign-cache open | deliberately reconstruct state before the live owner/session exists | retain one named index reconstruction per cold owner recovery until compaction replaces prefix replay; the subsequent semantic fold must reuse that handle |

**Recovery backfill source.** The ordinary `sink_catchup` acknowledgement now
returns the same writer-turn immutable view after the verified window is
appended. The driver carries that view to the next window; on its first DTX
control, the phase index reads its prior prefix using `open_ro_snapshot`.
The scratch root identifies only phase-index output, never input history.
Initial resumed recovery captures the same `history_view/3`; there is no
second snapshot/status accessor and no extra recapture between pages.

The acknowledgement binds original owner PID, anchored identity, committed
height and exact history head. It deliberately does not compare complete
projection maps: the recovery verifier retains historical committee-era rows,
whereas the live writer retains only the current era. The verifier continues
with its own verified projection; the borrowed snapshot supplies bytes only.
Preview → accepted sink → phase-delta commit remains unchanged.

Recovery and feed-gap workers reuse `quod_process:kill_when_owner_dies/2`,
already used by proof/coordinator workers, so losing the source terminates a
worker even while it is blocked in a page pull. Feed sink and replay completion
are pinned to that exact Simplex PID, never a replacement registration.
Recovery capture retains its existing five-second operation budget; the feed's
initial capture uses its existing pull-window budget, beginning before spawn.
Individual fetch/sink windows keep their existing bounds; no new clock governs
the entire multi-page recovery and no timeout starts another ordinary attempt.

After the cut, production `open_ro` callers must be a short allowlist of named
cold recovery owners plus explicit offline inspection. A source scan in a live
request is a test failure, not a performance counter to tolerate.

### 3.3 Implementation slices

Phase 1A is one reviewed behavioral cut; the following are editing/test
boundaries, not deployable compatibility stages:

1. **A1 — local source consolidation.** Introduce the one Simplex-owned view,
   convert evidence extraction, read certification, local outcome lookup and
   co-hosted reference verification, then delete path-valued local sources and
   the duplicate snapshot accessor. Delete the caller-less
   `quod_foreign_log:verify_current/3` surface and the path form of
   `verify_local/4`; older-era verification keeps the one verifier but receives
   the captured session rather than reopening a path.
2. **A2 — page-reader consolidation.** Make the existing catch-up page reader
   consume an immutable session. Convert network serving, co-hosted follow,
   foreign-cache replay and the existing materializer advance message; delete
   live fallback opens and raw-path materializer state. Delete the fixed
   32-worker/silent-drop branch. The reviewed direction is page credit on the
   authenticated link: legitimate concurrent requests remain owned and parked,
   rather than rejected as busy. The earlier busy-refusal recommendation was
   withdrawn because request expiry does not cancel the server read and no
   busy-clear message exists. The concrete wire grammar returns for review
   before implementation (now approved in the page-credit plan).
   Keep waiting work at existing owners and wake it from completion/credit
   messages; no silent drop, timer retry, unbounded spawn, or duplicate queue.
3. **A3 — local observers.** Convert runtime founding and Explorer to the same
   owner view. Keep Explorer's stopped-ledger inspection explicit and separate
   from live-owner failure handling; no implicit “snapshot failed, scan disk”
   branch. Runtime has no offline path.
4. **A4 — closure.** Classify every remaining production path open as cold
   recovery, add a guard/sweep test, delete superseded helpers, comments,
   metrics and tests, then run the complete sequential source gates and return
   the completed cut for review. Hardware follows that review and deployment
   authority; it is not authorized by the A1/A2 checkpoint.

**A3 deadline policy (approved by Yan).** Explorer receives a configurable
30-second history-read deadline, captured at operation admission and shared by
owner capture, indexed lookup and enrichment. It answers as soon as the read
completes; expiration is terminal, never a poll or retry trigger. No live
failure switches to a full disk scan. Cowboy's header/connection clocks are
not this operation deadline, and the shared accessor does not gain `infinity`.
Finalize enrichment remains available. Explicit `mode=offline` selects the
existing stopped-ledger inspection, not a fallback from live owner failure.
The deadline is checked before and after synchronous I/O and rendering; it
refuses late results but cannot interrupt an operating-system read in flight.
Handles close on completion or exception. It is not a promise that a stalled
disk system call is forcibly interrupted at exactly 30 seconds.

No intermediate slice adds a new route or authority; if an intermediate tree
needs both source representations to compile, it is not committed.

**A2 pressure closure (pre-cut diagnosis and approved replacement).** A transport link and a logical pull are distinct.
`quod_catchup` accepts multiple pending pulls, and the foreign-history owner
can run independent jobs through shared pinned links. The existing wire has
only `{blocks_err, ReqId}`, which becomes `server_error` or `retry`; it has no
typed busy/not-ready exchange or readiness subscription. Immediate refusal
alone would push service serialization into client retries.

Before A2 changes admission, trace every producer and specify how logical
requests already owned by those processes wait for a per-link service turn,
how completion grants the next turn, and how link/owner death terminates each
request. Read scheduling preserves request correlation and cancellation; it
cannot re-execute the enclosing Prolog proof or resubmit a write. Existing
send-side QUIC `send_ready` does not regulate incoming read
work: current receive credit is replenished when bytes are delivered to the
connection owner, before application consumption. Pausing only publication
would move the backlog into another mailbox. Any receive-demand solution must
connect consumption to credit at the existing transport owners, or specify one
reviewed demand grammar used by every sender. No second scheduler/cache/owner
or benchmark exception is authorized by this paragraph. The implementation
review must close this contract rather than invent it at the busy call site.

The endorsed mechanism is a page grant on the existing authenticated
catch-up link. Both producer owners retain unsent range/endpoint/deadline data
in their existing pending rows. A received terminal page response carries the
next grant. This paces serving while preserving multiple admitted logical
operations.

The architecture audit found that the producers do not share a production
link today: catch-up uses the ordinary or identified endpoint pool;
foreign-history pages use the pinned endpoint pool. The simpler proposed contract
therefore binds a link to one existing producer process, which services its
own pending rows in order. No cross-producer ticket/offer/fairness scheduler is
needed. Same-namespace/different-anchor foreign jobs still share that
producer's link and queue correctly. Keep the connection pools unchanged.
Claude's subsequent review explicitly endorsed this narrower contract in place
of generic coalesced-interest arbitration.
The concrete grammar is in
[catchup-page-credit-plan.md](catchup-page-credit-plan.md); it must satisfy
these mandatory review details:

- initial and successor grants are unique, directional and bound to that
  authenticated link incarnation; a broadcast grant cannot be spent twice;
- all senders use the same grant rule; one producer's pending rows cannot be
  starved by repeated reuse of the link. Request state remains in those rows,
  with monitor-based cleanup, not a duplicate link-owned request queue;
- caller expiry/cancellation never mints a new grant while the old server read
  still exists; a terminal response or exact link teardown releases the turn;
- the existing link reports ordered response acceptance asynchronously. Its
  synchronous `send_reliable` API cannot run inside a gen_server, and its
  drop-and-continue failure mode cannot let a next grant overtake a failed
  page. The terminal page response itself returns the grant, with one reader
  lifecycle through ordered acceptance; no separate acknowledgement round;
- a peer exceeding its grant is rejected before application publication,
  without an unbounded stream of busy replies. A credit violation is fatal to
  that exact link before application publication. The accepted transport
  posture is prompt reset plus the existing framing/buffering, not a change
  to receive-credit accounting in the pinned QUIC fork. Application grants
  do not claim a new absolute bound on bytes already delivered into mailboxes.

One grant per link is a protocol service invariant, not a population cap on
logical requests, identities or proof workers. Pending ranges stay in their
existing producer rows. Individual upstream verifier-caller detachment does
not cancel the shared page job; only expiry/death of the immediate page owner
tears down that exact page turn.

This mechanism changes the catch-up wire and admission contract, even though
it adds no ledger format or authority. It is a focused review item before A2,
not an already-implemented property of QUIC or a reason to implement a busy
exception in the proof engine.

### 3.4 Ownership after the cut

| data | sole live owner | borrowers |
|---|---|---|
| hosted committed ledger handle, sparse index, current history projection | `quod_simplex` for that ontology | evidence extraction, DTX/read certification, catch-up server, runtime, Explorer, co-hosted foreign follow |
| verified foreign cache append handle/session and certified projection | node-wide `quod_foreign_log` | its existing exact/current verifier and `quod_foreign_projection` worker |
| committed Prolog MVCC table and proof snapshot floors | existing `quod_prolog`/committed-projection path | scope workers and runtime through their existing handles |
| materialized foreign projection ETS table | existing `quod_foreign_projection` worker | foreign-log/runtime consumers through their existing APIs |
| stopped ledger with no process owner | the boot/recovery process, or one explicitly selected offline Explorer operation | nobody on a live request path |

The immutable session is a read capability, not authority by itself. The
identity/readiness check and matching semantic projection come from the live
owner; certified entry bytes and existing verification rules remain decisive.

Required tests:

- the local source's identity, readiness, snapshot, and projection are captured
  atomically, its public shape contains no path/handle, and claim/application
  evidence remains byte-identical;
- a commit/apply race yields either the complete preceding view or the complete
  following view: session height, history head, committee era and projection
  can never come from different owner turns;
- repeated and high-slot evidence reads perform no full index scan;
- a snapshot remains bounded after a later append;
- a future segment replacement/compaction cannot make an old session attach to
  different bytes at the same path and size; Phase 1 pins the current
  append-only/no-replacement premise, while Phase 4 must add store-owned
  generation binding before replacement exists;
- owner absence/death returns typed unavailability at the live boundary;
  stale owner replies cannot establish a current view, and a parked request
  is released by its existing owner/monitor path without waiting for a
  before/after liveness check to run;
- corrupt frames and identity/slot/id mismatches retain typed failures;
- current and older-era live verification perform no path-only fallback open,
  resubmission, poll, or timer;
- catch-up serving, local following, subscribed projection materialization,
  runtime founding and Explorer all use owner snapshots with zero index scan;
- foreign materialization receives the cache session and projection from one
  owner incarnation; coalescing replaces the whole target view, retains the
  verified prefix, and never publishes a superseded target as current. Old
  worker/owner replies are ignored and opened reader handles close exactly
  once; later appends alone do not invalidate pinned readers;
- a temporarily unavailable owner cannot trigger an O(history) fallback, and
  later progress is driven by the existing monitor/property edge;
- catch-up request pressure never becomes a silent drop followed by ordinary
  timeout discovery; wire/page memory bounds remain enforced;
- catch-up reader crash, requester/link death, duplicate id and concurrent
  per-link demand each clean up exactly one owned row; no response can be sent
  on a replacement link or stranded behind a dead worker;
- every wait in the changed paths is classified as a message-driven progress
  edge or a terminal deadline; no successful path wakes from a retry timer;
- the global production `open_ro` inventory contains only the reviewed cold
  recovery and explicit offline-inspection sites;

### 3.5 Prolog backtracking and action semantics

This cut changes how certified history bytes are read. The proof contract
remains the one in [distributed-proof-plan.md](distributed-proof-plan.md)
§§2–4 and §6 and the external-predicate classes in
[ontology-actor-architecture.md](ontology-actor-architecture.md).

Three objects have different lifetimes:

| object | purpose and lifetime |
|---|---|
| immutable ledger session | a bounded byte/index view for an evidence or page reader; no variables, overlay, or choicepoints |
| existing MVCC proof base | the committed facts pinned when that ontology scope opened; retained while the proof needs that scope |
| existing overlay checkpoint | staged assertions/retractions/abolishes, events, effects, and order at a transaction choicepoint; shares the base and monotonic read set |

An ordinary append leaves the admitted proof base and any bounded ledger prefix
usable. It does not refresh a scope on `::`, `next`, redo, a cut, or rollback.
Re-entry into an already-selected ontology keeps the saved bindings and
continuation and uses that scope's current staged overlay. Existing DTX
generation/visibility-fence checks still determine whether that proof may
return or commit. Do not replace those checks with latest-height equality.
Likewise, read certification retains the sealed plan, its proof base and the
committee admitted for that collection; agent attestation checks the consulted
OCC tokens. The certificate's `AnchorRef` may name a later block at which the
validators checked that same plan. If this quorum-selected anchor lies beyond
the initially borrowed byte session, capture a sufficient committed byte view
once from the same owner PID and exact anchored identity, then use the existing
exact-reference verifier. Do not refresh the proof, change the committee or
loop until a height appears. Insufficient verified votes cannot trigger that
capture; an insufficient/replaced owner returns existing typed unavailability.
An unrelated later block must not cause a false refusal. Identity-certificate
currency remains the separate current-committee verification described in §4.

Ordinary backtracking restores bindings, not database writes. The existing
`transaction/1` is the explicit rollback boundary: it restores failed
alternatives and total-failure/exception state across all touched ontologies,
including staged events and effect handles, while retaining every influencing
read. It selects the first complete solution and preserves cut barriers.
`goal/1` still enumerates `action/3` clauses in Prolog; each candidate runs in
that transaction. Prerequisites and postconditions inspect the current staged
overlay through the existing strict read-only state check, never through a
fresh ledger view. No storage helper selects actions or runs irreversible
effects during search.

Only the outer selected solution is sealed and submitted. Evidence extraction
and certification consume that exact immutable plan; they cannot reopen the
scope, re-prove a goal, or choose another Prolog answer. Later receipt/root
designs must authenticate deterministic application of this already-selected
plan, including OCC, without re-running Prolog alternatives or external
predicates. Effects remain governed by the ordinary commit/projection/effect
ordering. A cut cannot commit a block or authorize an effect.

Logical failure keeps the existing `fail_reasons` propagation and can cause
backtracking. Framework/transport/owner loss remains a typed error on the
existing proof or outcome path. It must not become logical `false`, select a
different action, rerun the proof, or erase a known committed result. Proof
completion/cancellation and durable handoff release their current MVCC pins and
scope resources; the ledger-view change adds no second proof cleanup owner.

Required semantic regressions, using the existing local/co-hosted/remote
scope fixtures and message barriers rather than sleeps:

1. Suspend an invocation, commit unrelated content, then resume/redo: preserve
   its original MVCC facts, answer order, bindings, and staged overlay. Exercise
   A→B→A re-entry and retain actual DTX-fence rejection cases.
2. Pin ordinary backtracking retaining an assertion, versus `transaction/1`
   restoring failed branches, retractions, abolishes, ordered events and
   prepared effects. Reads and `fail_reasons` survive rollback.
3. A failed action transition/postcondition tries the next declaration with
   restored staged changes; strict read-only prerequisites still backtrack
   normally. Cuts neither release needed shared scopes nor trigger effects.
4. Repeated sealing returns the same bytes; post-seal continuation/savepoint
   commands remain rejected. A later append cannot replace the admitted proof
   base or invalidate an attestation whose OCC tokens match. Cover a valid
   quorum selecting a later anchor: exactly one byte-view capture at the same
   owner/identity, no new capture for an in-range anchor or invalid votes, and
   refusal rather than recapture from a replacement process.
5. Owner replacement, cancellation, and late replies close opened readers once
   and follow existing typed-error rules. Invocation cancellation discards its
   continuation without rolling back ordinary staged writes; whole-proof
   failure commits nothing, and cleanup failure cannot undo a committed result.
6. Trace evidence reads and proof redo/rollback together: zero full index scans,
   no new proof bases or per-choicepoint history fetch, and no leaked MVCC pins
   after durable handoff or final cancellation.

### 3.6 Architecture conformance audit — 2026-09-08

Read the current actor, distributed-proof, inter-ontology and subscription
specifications together with the approved finality plan. Historical Raft and
early content-layer sketches are not competing normative architectures;
`content-layer-design.md` explicitly labels itself historical. This audit
changes the plan, not production behavior, and does not waive the A2 wire or
later current-view optimization reviews.

| requirement and source | binding consequence for Phase 1A |
|---|---|
| Prolog owns policy and durable intent — actor architecture §§1, 3–4; distributed-proof §§2–4, 6 | no new Prolog execution, ACL, action, effect release or consensus path; the selected sealed plan and ordinary validators remain decisive |
| One local and one foreign history owner — distributed-proof §§8–9 | one local `history_view/3` under the operation's original deadline; one retained foreign session/projection; borrowed sessions are capabilities to read bytes, never new certificate authority |
| Root-first bootstrap — actor architecture §2; namespace-manager contract | committed bytes can precede Prolog readiness; no circular requirement that replay be ready before its own history can be read; no hosting/directory authority change |
| Frozen scope and savepoint semantics — inter-ontology §4; distributed-proof §§4.1, 6 | ledger session, MVCC base, and overlay checkpoint remain distinct; a later certificate anchor does not refresh the proof or rerun Prolog |
| Exact historical era versus current identity authority — distributed-proof §8; roadmap §4 | an old entry uses its certified slot-era committee; fresh identity checks still require the current committee; a route, wake or resident row never substitutes for either proof |
| Owned cancellation and shared work — distributed-proof §4.2 and foreign verification caller-detach contract | gproc identifies the exact existing process; monitors/cancellation release its waiters; one caller's departure does not kill work another caller still needs |
| Subscription state versus occurrences — inter-ontology §5; subscription plan | the existing follower/materializer retains the verified prefix; coalescing/rebuilds remain state-only and do not replay `react_on` occurrences |
| Progress is event-driven — actor directory contract; roadmap §1.1 | no ordinary timeout discovery, busy retry or failed-read self-wake loop; credit, owner death, verified advance and route/property events are the wake sources |
| One durable history; future pruning preserves obligations — finality plan §7.1; roadmap Phase 4 | no format change or compaction now; later generation replacement preserves borrowed sessions/MVCC pins and exact-reference/finality custody; no second ledger truth |

Three concrete closure checks were exposed by this audit. They are required
at existing owners, not grounds for adding infrastructure:

1. An owner-liveness predicate alone cannot release historical verification
   parked in a call with an infinite timeout. The existing borrowing
   request/worker row monitors the view's exact source PID; `DOWN` retires that
   borrow and returns typed unavailability, with worker cleanup at the existing
   lane-release boundary. Prove queued and active cleanup, including an
   untrappable owner kill and unrelated shared callers; do not claim that
   before/after checks provide this guarantee.
2. Foreign follow currently retains an advertised high hint after a failed
   refresh. Its continuation must not repeatedly treat that unchanged hint as
   new progress. Attempt permission is consume-once; the informational height
   is not erased to conceal remaining work. The accepted Q2 matrix and Q3
   capture-on-original-budget contract are in page-credit plan §6/§6.1. Recovery
   within the real operation deadline completes that original request; after a
   true terminal failure a quiet source may leave known lag until the next real
   commit/restart/route/demand edge. This cut adopts that explicit boundary.
   The alternative proposed ACK-on-verified plus anti-entropy resend is a
   separate feed-semantics candidate requiring focused review, not authorized
   A2 work. Current anti-entropy does not resend validator recipient wakes;
   adding periodic retries conflicts with the standing no-progress-polling
   rule. Exact advertised ACK heights, certified versus materialized floors,
   and demand-only watches must be resolved by any future proposal (§6.2).
3. Compaction cannot invalidate snapshots still needed by admitted proofs.
   Preserve their store-owned generations until release, refuse accidental
   attachment to replacement bytes, and keep volatile continuations out of
   recovery snapshots. The contrary sentence in the height-latency plan is
   corrected with this audit.

The source audit also found two pre-existing documentation contradictions:
the general content guide allowed plain remote reads from arbitrary copies,
whereas distributed-proof §8 requires a certified current-validator route;
and the old foreign-verification 32/4 capacity row contradicted §8's existing
uncapped caller-owned queue. Correct those descriptions, not the implemented
trust/admission rules. The catch-up 32-worker row was kept visible at that
audit; A2 has now removed the branch and marked its capacity-table row as
historical. The implementation is reviewed; deployment and hardware results
must still be reported separately.

### 3.7 Measurement and documentation closure

**Source gate, 2026-09-09:** the completed A1–A4 tree at base `a300d51`
(subsequently committed as `45678f5`, version bump `d51503a` / 0.7.152)
passed a clean-build, sequential unsandboxed EUnit (1799/0),
`quod_ask_SUITE` (26/26), `quod_quic_SUITE` (26/26), xref and dialyzer,
all with exit 0 on the first run. Logs are
`/tmp/quod-a1-a4-final-{eunit,ask,quic,xref,dialyzer}.log`.
The production-AST inventory guard pins the remaining cold/offline opens;
runtime and Explorer have no live path-open fallback. The runtime combined
readiness-wake/queue-overflow regression also fails with the old overflow
branch restored in an isolated test module. These are structural and local
correctness results, not a measured write-latency improvement. Claude reproduced
these gates on the fingerprint-matched tree and approved the complete cut for
commit, bump and coordinated development deployment. The result-authentication
design, Q4, Phase 1B, finality, L2 and compaction gates remain separate.

**Hardware, 2026-09-09:** [the 0.7.152 report](phase-1a-hardware-results.md)
records 400/400 committed writes, zero full scans across all 200 one-hop
traces, and 99.756% / 99.901% per-request-means server attribution at c1/c4.
Serial one-hop p50 improves 1156→544 ms and c4 3723→1609 ms; the strong
within-run linear slope is no longer visible in this sample. The ≤300 ms
serial target is **not met**, and flat work through 10,000 entries is **not
measured**. Claude independently reproduced and approved the raw results,
trace attribution and durable receipts. `foreign.current` remains the largest
measured owner; no next-phase implementation or release-safety gate is opened
by this result. The next proposal is the
[Phase-1B current-view review brief](phase-1b-current-view-review.md).

N=4 gate: no evidence `index_scan` in live one-hop traces; evidence work flat
through at least 10,000 entries; c1 p50 at most 300 ms. Measure c4, but its
450 ms gate has no authorized implementation owner until the identity-freshness
design in Phase 1B is replaced and reviewed.

The 300 ms target is retained, but the earlier projection from request 1 alone
was incomplete. Anatomy §7 shows that subtracting the two scans from each of
requests 25/50/75 leaves 505.339/506.168/493.294 ms, with current-committee
verification retained. Those are counterfactual per-request values, not a new
p50. The broader serving refactor may help, but do not assume it closes the
gap. A flat ledger-cost result is not by itself passage of the latency gate;
report any shortfall before authorizing the next performance phase.

Documentation closure in the same cut:

- `quod_ledger_store` says path opens reconstruct an owner and snapshots serve
  concurrent live readers;
- `quod_simplex` documents the single identity-bound local history view;
- `quod_catchup` removes the claimed offline fallback from live serving and
  documents snapshot-only server work;
- `quod_foreign_log` and `quod_foreign_projection` document one retained cache
  session passed to verification/materialization;
- runtime and Explorer comments stop describing per-request path opens;
- this roadmap, the anatomy, and the height-latency plan receive measured gate
  results without preserving superseded API names as recommendations.

## 4. Phase 1B — rejected historical-committee shortcut

Do not implement the earlier exact-era proposal. The current identity statement
binds a `committee_id`, signing key, request digest and `not_after`, but it does
not contain a non-backdateable proof that the signatures were produced while
that committee was current. After a certified membership replacement, a fully
retired committee which still holds its old keys can sign a new request with a
fresh bounded expiry. Historical lookup proves only that those validators once
formed that era; it does not prove when they signed. `not_after` limits use but
does not establish issuance time.

Therefore the existing latest-head/current-committee verification remains the
authority. No 450 ms c4 gate is claimed by Phase 1A, and no stale-head shortcut
may be introduced to meet it. A future Phase 1B may proceed only after a
separate cryptographic review proves one of these clean properties without a
second authority or heuristic:

- current-era validators endorse the exact proof at use time;
- an explicitly specified key-evolution/erasure and authenticated-period
  contract prevents retired keys from authorizing new requests; the label
  “forward-secure” alone does not establish this property; or
- certificate issuance is bound to a certified, non-backdateable current-state
  event with equivalent security.

The mandatory adversarial test is: replace a committee completely, let the old
members sign a new request after retirement with a valid old `committee_id` and
unexpired `not_after`, and require rejection. Until a design passes that test,
keep the current certified-history owner hot and optimize its existing suffix
work only where measurement justifies it; do not weaken freshness.

The [Phase-1B review brief](phase-1b-current-view-review.md) separates that
cryptographic redesign from a semantics-preserving cleanup of the existing
verifier's execution. Claude approved the cleanup direction and all three
detailed cut contracts; all three implementations are reviewed, committed and
deployed in 0.7.155. Their measured results and later diagnostic captures are
linked in the status above. The
[shared artifact and pull contract](phase-1b-codec-and-pull-contract.md) is
reviewed; its shared artifact cut is explicitly consensus-facing. Each cut
required fresh sequential gates and review before commit. Cut 1 removed
owner-side page decoding while retaining the
existing page lifecycle. Broader response
reuse remains unapproved. Suffix reuse already exists. The audit
found owner-mailbox page decoding on 0.7.152, repeated canonical-byte work and all-reply
probe barriers; their individual latency contributions are not yet fully
attributed. The next
[exact-reference lifecycle/trace contract](exact-reference-lifecycle-tracing-contract.md)
is architecture-reviewed, with implementation proof gates pending:
context-independent sharing, absolute caller
budgets distinct from shared cache work, event ordering and complete cold
rebuild observation. Its specified behavioral refactoring is approved with
the fail-before wake and same-file custody conditions binding. The separately
reviewed existing-worker custody extension is now included; any further new
exclusion protocol returns for review. Approved measurements alone do not
close the implementation or hardware gates.
The brief also distinguishes rejecting a retired committee after its
replacement is known from discovering a concealed replacement; do not claim
the existing unit regression or key evolution proves both.

## 5. Phase 2 — finality cut and coordinated re-found

Implement F1--F3 through
[finality-round-recovery-plan.md](finality-round-recovery-plan.md) §7.1 after
consensus-area review. Bundle the format breaks, development key rotation, and
clean re-found once. Archive group
`6FDDFDBA6A0D61C5E779593F08F5416F35ABCBE39FA7E2C8D20C1D2A6D231B6D`
as unresolved on the old network; never resubmit it.

F1 must not freeze fields until one architecture review closes two adjacent
contracts so the development network does not need another format cut: the
certified per-transaction applied/rejected outcome from Phase 0, and the
minimum recovery-state commitment required by Phase 4 snapshots. For the
outcome, define deterministic computation and validation against the exact
parent while preserving or explicitly replacing proposal pipelining. For the
snapshot, define canonical encoding, authenticated object or root, atomic
install, archive proof, exact-reference and DTX custody, and dormant recovery.
Both should be authenticated by existing block/finality ownership, not new
consensus, certificate, or storage authorities. If either shape is rejected,
record and approve the replacement proof before F1 implementation rather than
reserving an unexplained field.

Gate: induced photo-finish/restart schedules recover without resubmission and
ordinary useful-write throughput remains within measured variation of the
Phase-1 baseline. Regrow fixtures and establish a new-protocol baseline; never
claim improvement by comparing across the re-found.

## 6. Phase 3 — reduce protocol rounds

First design and review reply-at-Decision for atomic multi-writer goals. The
Decision commit is the atomic answer; Finalize and Complete drain afterward
through the existing lifecycle. Public results distinguish committed from fully
drained.

Gate: atomic four-ontology p50 at most 300 ms, with terminal drain and restart
recovery proved separately.

Then implement the already-designed L2 `independent/1` slices. Independent
multi-target writes become ordinary parallel writes plus one receipt; atomic
multi-writer goals remain the default.

Gate: independent multi-target p50 at most 120 ms and flat with target count.

A separate one-round one-hop design is required before claiming a 60--120 ms
ordinary remote write. Today the source claim and target application are two
sequential consensus commits; local evidence reuse cannot erase that floor.
Prefer removing a round through the shared protocol over optimizing a second
path.

## 7. Phase 4 — compaction and cold start

Author and review the checkpoint/compaction **contract before the Phase-2 F1
format is frozen**; implement the storage machinery after Phase 3. If a
canonical recovery-state commitment is needed in committed block data, bundle
it with the already-planned finality format break and re-found rather than
creating another incompatible cut later. Preserve verifiable history,
committee-era transitions, exact references, and dormant-ontology recovery.
Compaction is not a history limit and cannot discard authority merely because
an ontology is inactive.

Use one ledger protocol with three storage roles, not two incompatible ledger
truths:

1. **Current materialized state** is the hot execution/read representation.
   Normal proof, ACL, OCC, and write work reads it or an immutable view of it;
   none replays history.
2. **Certified state snapshots** bind an ontology identity, exact height,
   canonical block/reference, committee era, and deterministic state digest.
   A snapshot is derived and replaceable, never authority merely because it is
   present on disk. Restore authenticates the anchor and snapshot certificate,
   installs the state atomically, then verifies only the suffix.
3. **Historical block/proof segments** provide audit, old exact-reference, and
   recovery data. Archive-profile hosts retain all of them. Pruned-profile
   hosts may retire a prefix only after a certified snapshot is durable and the
   still-live DTX/reference/custody obligations are provably preserved.

This follows the established full/archive-node split without creating a second
consensus format. `content-layer-design.md` already names the declarative
`local_history(Node)` archive-holder intent. The compaction review must either
retain that predicate or replace it once with the generic node-agent hosting
vocabulary; it must not add a config list or an imperative archive registry.
The chosen fact is committed knowledge, ACL-controlled like other hosting
intent, and projected by the existing state-handler/reconciliation tier.

Storage profile and snapshot policy are explicit node/ontology facts, not a
hard-coded retention count. Those facts express storage intent; they are not
evidence that another node actually holds durable recoverable bytes. The
ledger owner alone installs snapshots and retires segments. It may prune only
after the reviewed protocol proves enough independent durable custody for
every history/proof needed for network recovery. The state-handler/effect tier
reconciles intent but cannot grant pruning authority merely by observing a
fact. A snapshot cadence may be height- or workload-driven, but committed
policy owns that choice; no timer polls for eligibility. The existing
commit/publication edge wakes the one reconciliation path, snapshot work stays
outside consensus, and publication is visible only after durable completion.

The compaction design review must decide:

- the canonical state encoding and digest;
- the existing committed object that authenticates the recovery-state digest.
  Prefer a block-authenticated state/recovery commitment over a new snapshot
  certificate owner; prove the computation and write-path cost before choosing;
- atomic snapshot install and crash recovery;
- immutable live-session retention across atomic file/segment replacement:
  preserve the exact generation still borrowed by an admitted reader and
  prevent a session attaching to new bytes through reused offsets. Normal
  compaction must not silently refresh an ongoing proof or force it to restart;
- active proof MVCC floors and exact-reference borrowers at the existing
  owners, with release on existing completion/cancellation/monitor edges;
  volatile continuations and uncommitted overlays are not recovery snapshots;
- archive availability and safe prefix-retirement proof;
- the exact committed node-agent/ontology facts that request archive or pruned
  service, including the disposition of the existing `local_history(Node)`
  design, and their ACL/state-handler projection;
- exact-reference and DTX-custody data that cannot be pruned yet;
- selected finality-carrier ancestry and serving evidence that cannot be
  pruned before an approved checkpoint replaces its custody obligation;
- how an inactive ontology restarts from snapshot plus suffix without an
  always-running process;
- migration from no snapshot without a compatibility execution path.

The recovery state is wider than Prolog facts: it must include every
consensus-derived committee/admission/sequence/DTX/outcome value needed to
continue at the snapshot height. Uncommitted signing-journal custody remains
under its existing separate durable owner and is reconciled against the loaded
committed height. A snapshot that omits either side is not a restart point.

Gate: bounded cold start on a long ledger, corruption refusal, and identical
certified answers before and after compaction. The baseline symptom is the
previous 34.6-second first request around height 7,000.

The fault matrix includes crashes between snapshot durability, publication and
prefix retirement; an old exact reference into a retired prefix; unresolved
DTX crossing the checkpoint; dormant restart; archive-holder loss; corrupt
interior segments; and selected finality-carrier ancestry. No test may satisfy
availability using the same node that wants to prune.

### Design references

- Ethereum distinguishes current state needed for ordinary operation from
  optional historical-state archives and checkpoint-based regeneration:
  <https://ethereum.org/developers/docs/nodes-and-clients/archive-nodes>.
- CometBFT state sync restores application snapshots only under a separately
  verified trusted height/hash:
  <https://github.com/cometbft/cometbft/blob/main/docs/core/configuration.md>.
- Hyperledger Fabric snapshots contain the minimum current state needed to
  join without replaying every block:
  <https://hlf.readthedocs.io/en/main/peer_ledger_snapshot.html>.
- RocksDB checkpoints demonstrate cheap consistent point-in-time storage
  views; they are a backend technique, not blockchain authority:
  <https://github.com/facebook/rocksdb/wiki/Checkpoints>.
- Cosmos SDK separates consensus state commitment from the backend retaining
  versions and pruning policy; the retention choice does not create a second
  chain truth:
  <https://docs.cosmos.network/sdk/latest/reference/architecture/adr-040-storage-and-smt-state-commitments>.
- Tendermint light-client verification advances from authenticated headers and
  validator sets under explicit trust conditions instead of replaying every
  application transition:
  <https://github.com/tendermint/spec/blob/master/spec/light-client/README.md>.
- Raft snapshots pair state with the last included log index/term before a
  prefix is discarded; Quod needs the Byzantine/certificate analogue rather
  than trusting a local file:
  <https://www.web.stanford.edu/~ouster/cgi-bin/papers/OngaroPhD.pdf>.

## 8. End-state targets

| path | target | enabling work |
|---|---:|---|
| local write | about 65 ms | current measured N=4 floor |
| one-hop after Phase 1A | c1 p50 target ≤300 ms, still unsubstantiated | owner snapshot evidence; current-committee verification retained; later sampled requests still contain about 493–506 ms after subtracting only their scans |
| eventual one-hop | 60--120 ms | reviewed one-round protocol |
| independent multi-target | 60--120 ms, flat in target count | L2 `independent/1` |
| atomic four-ontology | 200--300 ms | reply at Decision after finality cut |

Targets are gates, not promises. Contradictory evidence changes the roadmap
before another optimization is built.

## 9. Carried work

- cold-start replay and compaction;
- opaque key handle in `quod_client_tls`;
- stale `quod_explorer_ws` outcome comment;
- supervisor-child restart health gate;
- harness stop-on-uncertainty behavior;
- finality-cut audit of the existing consensus pacemaker/sync timers: healthy
  work must wake from messages, with clocks retained only for protocol failure
  detection;
- empty metadata fields in `valid_role_fields`;
- lost `verify_local` committee-era regression.

Fold an item into another commit only when it belongs to the same owning
abstraction and remains independently reviewable. L2 stays gated until Phase 1
and finality activation are green.

## 10. Documentation ownership and amendment map

This planning cut changes documentation only:

- `write-latency-anatomy.md` replaces the temporary
  `single-write-trace-attribution.md` and owns measured numbers, trace ids,
  attribution, and the complete live-ledger-open audit;
- this roadmap owns sequence, architecture boundaries, performance gates, and
  the future storage contract;
- `certified-history-height-latency-plan.md` marks H1 complete, retires the
  phase-index hypothesis, and points its correction at Phase 1A;
- `finality-round-recovery-plan.md` status, §§4.3/6/7/7.1 and the format tables
  keep finality sequencing aligned with the completed H1 evidence and require
  outcome/recovery commitments to be decided before F1 freezes the formats;
- `content-layer-design.md`'s history section and `content-layer.md` §7 keep
  full history as current behavior while linking the planned single-ledger
  archive/pruned design;
- `deferred.md`'s founding-read and snapshot/compaction entries distinguish the
  Phase-1 live fix from cold recovery and point storage policy at committed
  node-agent/ontology facts;
- `deploy/grafana/README.md` points operators at the permanent anatomy rather
  than the deleted temporary trace plan.

When Phase 1A lands, update the module documentation and exact source comments
listed in §3. The historical `ordering-layer-spec.md` remains untouched: its
header already marks the entire Raft-era file superseded, so editing isolated
sentences inside it would make historical text look normative. Yan's
`write-lanes-plan.md` and its SVGs are explicitly outside this documentation
cut.

# Performance roadmap

**Status: proposed sequencing based on the measured 0.7.151 write anatomy.
Claude confirmed the Phase-1A owner model and complete open-site inventory.
The backtracking contract below preserves pinned proofs across ordinary
appends. A2's per-link pressure recommendation requires the caller/transport
closure in §3.3 before implementation; one active request per shared link is
not an existing protocol invariant.
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

The current catch-up server's fixed-worker overflow is a direct violation: it
silently drops an admitted request and makes the requester discover that fact
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
| Phase 1A owner views and production open-site inventory | accepted | next implementation candidate after Claude review |
| path-based foreign-cache replay | confirmed worse than linear across pages | one cold owner open, then session-based pages only |
| fixed 32 catch-up workers with silent drop | rejected | replace at the existing link/owner with message-driven pressure and terminal replies, not another cap or unbounded spawn |
| historical-committee identity shortcut | rejected as unsafe after committee replacement | retain latest-head/current-committee verification |
| block-committed result receipts | direction accepted, computation contract incomplete | deployment stays blocked; F1 cannot freeze it yet |
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
explicitly blocking deployment. Measurement spans stay only while later gates
use them.

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
The final API name is chosen during implementation; there must be one shape and
one owner, not a forwarding compatibility layer.

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

Snapshot refusal or owner death returns the existing typed unavailable result.
The existing route, monitor, committed-height, and projection messages wake
the owning operation. Do not fall through to a path scan, poll, or delayed
retry.

Owner unavailability is transient at live consumers. In particular, runtime
founding must not translate `not_ready` or an owner replacement into a
permanent unhealthy ontology. Permanent unhealthy remains reserved for a
verified malformed or conflicting founding state; the existing monitor and
runtime publication edges re-drive transient owner readiness.

### 3.2 Complete production sweep

| current site | present behavior | required disposition |
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
   32-worker/silent-drop branch. Claude recommends serial read service per
   authenticated link, with terminal busy/not-ready answers to excess
   requests. Record that as the service direction, subject to the pressure
   contract below: legitimate concurrent requests already share links, so
   rejecting all but the first cannot be treated as a behavior-neutral fix.
   Keep waiting work at existing owners and wake it from completion/credit
   messages; no silent drop, timer retry, unbounded spawn, or duplicate queue.
3. **A3 — local observers.** Convert runtime founding and Explorer to the same
   owner view. Keep Explorer's stopped-ledger inspection explicit and separate
   from live-owner failure handling; no implicit “snapshot failed, scan disk”
   branch. Runtime has no offline path.
4. **A4 — closure.** Classify every remaining production path open as cold
   recovery, add a guard/sweep test, delete superseded helpers, comments,
   metrics and tests, then run the hardware gate.

No intermediate slice adds a new route or authority; if an intermediate tree
needs both source representations to compile, it is not committed.

**A2 pressure closure.** A transport link and a logical pull are distinct.
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

The concrete review candidate is a page grant on the existing authenticated
catch-up link. Both producer owners retain unsent range/endpoint/deadline data
in their existing pending rows. The link grants a send turn to exactly one
registered owner at a time; owner interest is coalesced, not a second queue of
requests. A received terminal page response carries the next grant. This
paces serving while preserving multiple admitted logical operations. Before
accepting the candidate, review these mandatory details:

- initial and successor grants are unique, directional and bound to that
  authenticated link incarnation; a broadcast grant cannot be spent twice;
- all senders use the same grant rule, and owner selection is fair. Request
  state remains in existing producer rows, with monitor-based cleanup;
- caller expiry/cancellation never mints a new grant while the old server read
  still exists; a terminal response or exact link teardown releases the turn;
- the existing link reports ordered response acceptance asynchronously. Its
  synchronous `send_reliable` API cannot run inside a gen_server, and its
  drop-and-continue failure mode cannot let a next grant overtake a failed
  page. One response-plus-grant frame or equivalent fail-closed ordering is
  required, with one reader lifecycle through that acceptance;
- a peer exceeding its grant is rejected before application publication,
  without an unbounded stream of busy replies. Prove that protocol-violation
  reset plus existing transport buffering is sufficient, or couple receive
  consumption to credit at the existing transport owners. Application grants
  alone do not bound bytes already delivered into their mailboxes.

This candidate changes the catch-up wire and admission contract, even though
it adds no ledger format or authority. It is a focused review item before A2,
not an already-approved property of QUIC or a reason to implement a busy
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
- owner absence/death returns `not_ready`, never stale evidence;
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
Likewise, read certification retains its admitted anchor/committee, and agent
attestation checks the consulted OCC tokens; an unrelated later block must not
cause a false refusal. Identity-certificate currency remains the separate
current-committee verification described in §4.

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
   commands remain rejected. A later append cannot replace an admitted read
   certificate's anchor or invalidate an attestation whose OCC tokens match.
5. Owner replacement, cancellation, and late replies close opened readers once
   and follow existing typed-error rules. Invocation cancellation discards its
   continuation without rolling back ordinary staged writes; whole-proof
   failure commits nothing, and cleanup failure cannot undo a committed result.
6. Trace evidence reads and proof redo/rollback together: zero full index scans,
   no new proof bases or per-choicepoint history fetch, and no leaked MVCC pins
   after durable handoff or final cancellation.

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
- committee signing keys are forward-secure or key-evolving so retired eras
  cannot produce new signatures; or
- certificate issuance is bound to a certified, non-backdateable current-state
  event with equivalent security.

The mandatory adversarial test is: replace a committee completely, let the old
members sign a new request after retirement with a valid old `committee_id` and
unexpired `not_after`, and require rejection. Until a design passes that test,
keep the current certified-history owner hot and optimize its existing suffix
work only where measurement justifies it; do not weaken freshness.

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

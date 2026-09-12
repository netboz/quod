# Quod Multiwrite Architecture — Consolidated, Settled
2026-09-12. Authored by Claude. This is the single settled text: revision 2
plus every ruling, amendment and pin. It ships under `doc/` with the first
implementation commit and is the sole reference thereafter. Nothing here is
open for re-debate; genuinely deferred details are listed in §9 only.

Baseline for implementation: published S7/.165
`91c94d527d1ef81ac5882310f43f0fbae584a9a3` (isolated worktree; fleet stays on
the retained .164 line; no wipe is authorized by this document).

---

## 1. Governing principle

Never throw away verified work: build once, keep it, advance it with every new
block, save it (where §5 approves), restore it from the save. Full
reconstruction exists in exactly ONE implementation per state kind and runs in
exactly two situations — node startup, and detected corruption (a loud,
operator-visible event). No request, catch-up window, evidence lookup or
readiness dip may trigger it. Owners never block their mailbox and never
destroy live obligations they will need again.

The normative structural text is ARCHITECTURE.md revision 2 (its §§1–7:
pipeline, four owners, one history lifecycle, one evidence interface, one
coordination lifecycle, L2 completion, deletion discipline), as amended below.
DELETIONS.md is the implementation checklist with its four dispositions.

## 2. The four architecture rulings (settled)

**R1 — Retained owner-lifetime indexes.** The hosted-namespace Simplex owner
retains its startup-built phase/era bookkeeping for the whole VM session and
advances it at the applier seam on every applied entry. Views are coherent
as-of-height: a captured view at H never exposes rows later than H; readers at
H stay bounded to H during later appends. Catch-up borrows a READ-ONLY
as-of-height view of the owner's index (amended 2026-09-12; the earlier
"suspend/resume handoff" wording was wrong for the hosted case — that
mechanism is an exclusive writer-lifetime transfer and stays only where it
already exists, in the foreign writer's sequential custody):
- Simplex keeps the index open and remains its SOLE mutator throughout.
- The worker requests one short same-turn capture from the owner; the owner
  never waits on the worker's network I/O. The capture pins phase and
  committee lookup at H — later live commits, including to the SAME group,
  are invisible through it. Capture cost is bounded by open/changed groups,
  never by prefix length; no copy or re-verification of the prefix.
- The worker verifies only its missing window against that view and returns
  the verified index DELTA with the window (the existing preview/commit-delta
  pattern). The owner sink validates the base (First = last+1), appends,
  installs the delta BEFORE publishing — fail-loud on installation failure,
  never publishing with a stale pre-append index — and refuses overtaken
  windows as `stale_window` exactly as today. Owner death voids the capture.
The catch-up backfill family and every request-time prefix
reconstruction path are deleted (DELETIONS.md §C rows 1–4). Single-writer
custody per resource is unchanged; the indexed disk backend stays.
Required controls: append-after-capture (same and different group), old-era
committee lookup at H, stale window, failed sink leaves the index unchanged,
owner death, capture-cost boundedness (counted), and zero old-prefix
reads/verifications in the 8/64/257 cases.

**R2 — Hosted history ownership; exact routing rule.** Evidence selection is
by anchored identity `{Ns, Anchor}`:
- This node hosts that exact identity (same Ns AND same Anchor):
  the local hosted owner is the ONLY evidence source.
  - local committed height ≥ referenced slot → one pinned sufficient capture,
    local verification (unchanged from A);
  - local height < referenced slot (same identity, merely lagging) → wait on
    the owner's own progress edge under the caller's ORIGINAL absolute
    deadline; expiry keeps the existing typed retry/abstain grammar. No routed
    request, no cache, no recapture.
  - local owner unavailable → the existing typed unavailable result, within
    the same deadline semantics. Unavailability is never repaired inside a
    request.
- This node does not host that identity (different Ns, or same Ns with a
  DIFFERENT Anchor — a different era/incarnation IS a different identity):
  the foreign-history owner path (one retained verified prefix per identity;
  only genuinely new data is acquired).
This supersedes contract A's insufficient-local-view routed fallback, whose
tests are replaced (never left selectable). All other A rules remain binding:
expected-target binding validated first, one sufficient capture stays pinned,
no recapture after owner loss or invalid proof, one routed request for
non-hosted targets, absolute deadline end-to-end including queued-verdict
expiry → abstain, preferred peers are delivery hints not authenticated
contacts.

**R3 — Coordinator obligations pause, never retire, on unreadiness.** A
durable coordination obligation survives temporary sync/Prolog unreadiness:
the owner row, exact obligation and verified progress are retained; only
execution is gated; actual progress wakes it; completion or a real
ownership/admission change retires it. The readiness-driven teardown/
re-bootstrap cycle is deleted. Parking grants nothing readiness gates: no
signing, appending, proving against an unready KB, or publishing unverified
results. This explicitly supersedes contract B's observation-only boundary at
this seam; B's end-once/ancestry/death accounting stays honest.
R-RESTART-RACE-01 is a separate open item, neither fixed nor waived here.

**R4 — One responsive coordination lifecycle.** All coordinator I/O —
Begin/Decision/Complete submission, phase discovery, status walks, operation
recovery, L2 target actions — uses the existing asynchronous wave/result
mechanism (ordered work = one-item wave; independent targets = vector wave),
correlated to the exact pending action under its original deadline. The
synchronous command driver, nested owner-side endpoint collector and
duplicated delivery walks are deleted. The scalar `target_result` and vector
`target_results` converge on the canonical target vector. No retry timers,
renewed allowances, or resubmission of uncertain writes — ever.

## 3. The three amendments (settled)

**AM1 — Implementation order and morning minimum.**
Scope 1: history lifecycle (R1, R2) + DELETIONS §C rows 1–4.
Scope 2: coordination lifecycle (R3, R4) + §C rows 5–8.
Scope 3: L2 completion (§6 below) + its controls.
The Simplex consensus-core extraction and Prolog request-lifecycle rewrite
proceed only where these scopes touch them; new libraries exist only where
they remove a duplicate implementation; pure extraction waits. One runnable
implementation after each reviewed scope. **Morning minimum = scopes 1–2,
done properly.** Fewer scopes done properly beats all done badly; no gate is
weakened for the deadline.

**AM2 — Saves and checkpoints: what is approved.**
- APPROVED (D1): a durable save/checkpoint is a trusted restore point ONLY
  when bound to the certified tip (tip hash + height + manifest, CRC); any
  mismatch is a corruption event → the one rebuild path, loudly. An UNBOUND
  checkpoint is never authority — revision 2's sentence stands for the
  unbound case.
- APPROVED (D2): pause-don't-retire (= R3).
- APPROVED in principle (D3): periodic state save + fast boot (projection,
  phase index, KB snapshot, foreign prefixes) as the LAST stage ("F6");
  the numeric cadence is decided at that stage's implementation review
  (recommendation: every N committed entries with a time floor; bounded I/O).
- Consequence: eager startup initialization of retained foreign prefixes is
  affordable only WITH bound saves; until F6 lands, foreign-prefix
  initialization cost lives at explicit owner startup and is counted there,
  never at request time.
The older /tmp/quod-FINAL-ARCHITECTURE/FINAL-ARCHITECTURE.md is superseded by
THIS document; where it described D1–D3 as pending, the statuses above are
the settled ones.

**AM3 — The L2 exact-result certificate (settled contract).**
- Statement (one per target application): binds the network/genesis domain,
  the anchored target identity, the operation ref and claim ref, the exact
  application occurrence (transaction id, slot, entry digest), and the
  CANONICAL terminal result — `applied`, or `rejected` with a canonical
  reason class. Free-text reasons are outside the signed statement.
- Signers: validators of the TARGET committee AT THE APPLICATION SLOT.
- Attestation boundary: a validator signs only after its own Prolog outcome
  owner has durably published exactly that result (the existing applied-vote
  post-apply boundary).
- Quorum: **f+1** of that committee. Justification (part of the contract):
  with at most f Byzantine, any f+1 signatures contain one honest validator;
  an honest validator attests only its own deterministic apply's durably
  published result; deterministic apply over certified inputs yields a unique
  correct verdict; therefore one honest attestation suffices. 2f+1 remains
  reserved for ordering decisions, which this is not. This argument is valid
  only because result classes are canonical — hence they are mandatory.
- Historical/retired signers: verification resolves the committee and its
  admitted keys AT the certificate's slot via the retained historical
  committee lookup (bounded indexed read; no replay, no clocks, no current
  view). A signer retired after that slot remains valid FOR that slot; a key
  admitted later is invalid for it — the existing vote-verification key
  rules, unchanged.
- Receipt validation: the S7 receipt union gains the certified-verdict arm.
  A complete receipt = exactly one row per claimed target, each verdict
  backed by a valid certificate as above; rows and refs canonical per S7.
  Historical `included`-only rows remain valid bytes and can never back a
  verdict label. New receipts must carry the certified arm (validation rule,
  not a format break). Explicit non-substitutes: f+1 current-view lookup,
  inclusion references, transport acknowledgements, peer assertions.

## 4. Independent-dispatch authority (exact rule)

The independent lane may dispatch for a claim if and only if the validating
node can RECOMPUTE, from (a) the client's original signed request bytes and
(b) the sealed-proof evidence bound to that request, that the successful
sealed proof carried independent intent under the S6 rules (selected-answer
intent; provenance mask; mixing veto; uniform signing). Peer-supplied
booleans, wire flags and coordinator assertions grant nothing. The temporary
N>1 admission and worker refusals are removed only in the same scope that
implements this recomputation, with its fail-befores and the genuinely
admitted N>1 certified partial-outcome witness (the carried 7.4 obligation).

## 5. The five event/agent/proof pins (settled)

1. Fact events, explicit occurrences and certified remote wrappers go through
   ONE applied-ops reducer and ONE Prolog matcher; facts/projection precede
   effects; replay never re-fires historical reactions.
2. Four distinct delivery guarantees: best-effort, acknowledged-volatile,
   committed-signal, durable-outbox. A committed signal does not guarantee
   delivery.
3. Ordinary failed branches retain staged events; `transaction/1` rollback
   removes them (the S6 ruling). The event-plan document's test-18 sentence
   receives that explicit qualification.
4. Low-level agents: one ontology-backed identity/state, an optional
   rebuildable hosted process, NO private KB. Pending outbox facts feed one
   agent scheduler through state convergence — no namespace scanner, no
   duplicate reaction wake. The local effect journal is not an agent outbox.
5. FIPA is Prolog protocol/policy ABOVE that foundation — no second executor,
   no global message ledger. Agent hosting/delivery remains PENDING and is
   outside the multiwrite implementation scope.

## 6. L2 completion (scope 3)

One source claim; the canonical N-target set (N=1 included, no fork);
independent parallel target actions on the R4 lifecycle; ONE complete
certified per-target result vector to the client, exactly once (mixed
outcomes are success-shaped; partial vectors are never final; timeout means
uncertainty, never invented rejection); then the asynchronous source receipt
(client results precede receipt durability — the C3 ruling). Verdicts per
AM3; dispatch authority per §4.

## 7. Independent scope: PROLOG-CUT-FINDALL-01

Erlog's `prove_findall` discards the cut-presence result and pushes no cut
barrier; `!` inside findall's goal crashes `function_clause` in `cut/5`
(availability, not soundness — verified on unchanged raw Erlog; `call/1`
around the same goal behaves correctly). Correction: in the Erlog dependency
at the meta-goal boundary — consume the cut flag and push the `#cut{label}`
barrier as `call/1` does (ISO: cut is local to findall's goal; the probe
case yields `[1]`), audit the remaining meta-goal boundaries (three
`check_goal` call sites total), add permanent local/co-hosted/remote/
savepoint/event regressions. Own dependency-revision scope with exact-tree
review and full gates; no quod-side catch-and-fail or wrapper. Runs parallel
to or after the multiwrite scopes; it does not gate the morning minimum.

## 8. Acceptance (structural, with fail-befores)

DELETIONS.md §C's structural-proof column, plus:
- zero old-prefix reads/re-verification after initialization (the 8/64/257
  probe becomes this regression: a one-block DTX gap = 0 old entries);
- same-child retention through sync/Prolog unreadiness (readiness-probe-v2
  becomes this regression), no signing/dispatch while gated;
- coordinator processes an injected progress message while endpoint I/O is
  held open;
- co-hosted lagging: zero foreign jobs, resolution after local apply within
  the original deadline; era change still routes foreign; unavailable stays
  typed-unavailable (over-broad waiting is a failure);
- save restore verifies only the suffix (counted); a tampered binding
  triggers the loud rebuild; callers stay deadline-honest (F6 stage);
- L2: genuine signed admitted N-target writes, sibling progress under one
  delayed target, exact certified mixed outcomes, one final vector, receipt
  after client results;
- deletion accounting per DELETIONS.md §E (functions/exports/state fields/
  message variants/paths, not just lines; relocation ≠ deletion).
Per scope: clean sequential full gates, true exits, full logs, flake protocol
(both EUnit items open), frozen manifests, exact-tree review before commit.

## 9. Deferred — narrowly, without blocking anything above

- D3 numeric cadence (decided at the F6 stage review).
- bagof/setof/forall boundary audit result (inside the Erlog scope).
- The trigger-confirmation measurement (witness reference slots vs home0
  committed height, from retained data) — evidence completion for the record;
  R2 removes the path regardless of its outcome.
- R-RESTART-RACE-01 (its own future contract), both EUnit ledger items,
  the +8.7% question (state retires at the eventual wipe), slice-7
  deployment (separate explicit wipe authorization), agent hosting/FIPA.

## 10. Evidence of record (paths and SHA-256)

- Revision 2 (normative structural text):
  /tmp/quod-simplify-iJPWRa/freeze/ARCHITECTURE.md
  cec7a0b16c6254b5b1157709aa1067f2ffaaf04846deb9af3723e247589ef559
- Deletion ledger: /tmp/quod-simplify-iJPWRa/freeze/DELETIONS.md
  27761ea83a05819a4385972541db9cff9171d3a400344f660a5456a21ad0ca84
- Reachability audit: /tmp/quod-simplify-iJPWRa/freeze/AUDIT.md
  67520ee294612948dfc4e840daae11d874b9fd2bef4d6d29b5586d538d4fd654
- Superseded predecessor texts:
  /tmp/quod-FINAL-ARCHITECTURE/FINAL-ARCHITECTURE.md
  c41f4d1360a026a1c6ebc76ea9b11028483aa4cd4745f6971c99e2535561cce9
  /tmp/quod-final-multiwrite-VlU3GT/freeze/ARCHITECTURE-SYNC.md
  9639f9e6165db7740d7e82941fb6cc938264913dde5a536fb49c669fc08bf5dd
- Measured c4 diagnosis: /tmp/quod-c4-architecture-ltRORA/REVIEW.md
  382eab3cd0074e663d7d28b72cf6bb5b44bd034eae3d9724fab309f8cf4f8fc8
- Witness freeze: /tmp/quod-C4P1-164-CZkCg0/final-freeze/HANDOFF.md
  d03e18dec318c973fba6220ba9f3716ed56aeb7890cf30b766ac3b81e9bf278c
- Cut/events/agents pass: /tmp/quod-proof-events-agents-6KyHY6/HANDOFF.md
  5f9cf00da24cf01a3913562b8e8719db2b768078df5d79885d78a8bca81f78c5
All frozen campaign evidence, STOP/BENCH_STOP markers and Yan's write-lanes
files (fingerprint f0de37bfd4b4cf504502c51f502e756a4c110150628b86a7046979fe603fec04)
remain untouched.

---

## 11. Addendum (same authority as the body): system-predicate interfaces

The existing Prolog surface is RETAINED as the architecture's upper interface:
`goal/1` + `action/3` as the one target-driven evaluator, one `can_invoke/4`
entry policy, ontology-owned exact bridge manifests, the identity/lifecycle/
projection/reaction interfaces, and the delivery-guarantee tiers of §5. The
class seed ontologies are vocabulary and policy, not hidden agent executors;
agent hosting/delivery and FIPA remain pending and outside this scope. The
interface map of record: /tmp/quod-system-predicates-JT31GF/REVIEW.md.

**A1 — L2-ACTION-SAVEPOINT-COMPOSITION-01 (ruled).** `transaction/1` has been
serving two meanings: the user's public atomic commit-intent selection, and
the action evaluator's internal candidate rollback (common_predicates.pl:30).
The two are separated:
- `transaction/1` remains ONLY the public commit-intent control, with the S6
  nesting rules untouched.
- Action-candidate rollback becomes an INTERNAL proof-savepoint primitive:
  the same existing checkpoint/restore machinery (overlay checkpoint incl.
  provenance maps, staged events, prepared effects, cross-scope savepoint
  tokens), reused not duplicated, NOT exposed as a Prolog-visible control.
  It preserves the evaluator's exact semantics: desired-state first,
  declaration order, read-only prerequisites (explicit recursive `goal`
  prerequisites excepted), first-complete-solution retention, candidate-local
  cut barrier, rollback on failure or error, checked postcondition. Reads
  remain monotonic OCC dependencies and are never rolled back.
- Consequence: `independent(goal(X))` becomes legal and correct — intent is
  trail-scoped as in S6; a successful candidate's writes carry independent
  provenance through the ordinary write-intent mechanism; a rolled-back
  candidate's writes and marks vanish with the savepoint.
- One pinned semantic change: an `independent/1` wrapper INSIDE an action
  transition is no longer refused by evaluator state; it is governed
  uniformly by the S6 rules (trail-scoped intent, provenance mixing veto,
  nested-wrapper errors). No evaluator-context special case exists.
- Conditional on Yan's product answer that independent writes reuse
  `goal/1` (assumed yes; if no, the current refusal stands harmlessly).
- Own implementation scope AFTER the morning minimum, before or with S8;
  fail-befores: the eight pinned current-behavior probe cases, the
  now-succeeding independent(goal/1)-with-transition case with provenance
  asserted, the changed transition-wrapper case, and rollback coverage for
  facts/events/prepared effects/cross-scope across local, co-hosted and
  remote candidates. No functor exemption, no second evaluator, no dropped
  rollback.

**A2 — Dependency taxonomy (ruled): three classes, declared at registration,
enforced centrally. No name lists at sealing.**
1. PROOF-BOUND: values the engine itself authenticated or bound for this
   proof (`current_principal/1`, request bindings, proof context flags).
   Deterministically re-derivable by every validator from the signed request
   and engine rules; therefore admissible in write proofs and captured as
   proof context, not as a bridge dependency.
2. COMMITTED-SNAPSHOT: reads of committed facts under an anchored height
   (e.g. `directory_control_peer/1` over the root snapshot). Admissible in
   write proofs ONLY when captured through the ordinary read-dependency
   machinery (read set / foreign reads / read certificates) so validators
   recheck against the same committed base. Reclassification of each
   predicate family happens at implementation with evidence that its reads
   are so captured; until then it keeps class 3 treatment.
3. LIVE OBSERVATION: routes, availability, `peer_ready/1`,
   `directory_host/5`. Hints only; the material-diff sealing veto STAYS;
   never authorization, never application verdicts.
Anything not provably in class 1 or 2 is class 3. Caller-supplied identity
never becomes authority; staging a grant cannot authorize the proof that
stages it.

Retained boundaries, unchanged: `effect_requires_empty_diff` is not
broadened; founding declarations (not later asserts) define executable
handlers; genesis-pinned bridge BEAMs and application-common Prolog have
distinct deployment implications and neither mutates founded content.

## 12. Addendum 2026-09-12 morning (same authority): two rulings

**HISTORY-CUSTODY-LOSS-01 — RULED: custody loss IS the integrity-loss class;
the loud rebuild is allowed.** The governing principle's "detected corruption"
arm is defined as LOSS OF THE INTEGRITY INVARIANT, not proven-bad-bytes: an
exclusively held mutable cursor that dies unreturned leaves derived state
whose coherence cannot be proven (the design forbids repair), which is
precisely that loss. Retaining `resident_verified=true` would be a lie;
request-time rebuild is forbidden; killing the node-wide owner is
disproportionate. The draft's mechanics are confirmed with these pinned
conditions: (1) triggered on the actual DOWN, queued as owner work at the
front of the per-identity queue, never inside a request; (2) loud and counted,
with `custody_lost` counted SEPARATELY from `corrupt` so real corruption
trends stay visible; (3) blast radius = that identity's derived index only —
the retained ledger bytes are neither declared corrupt nor discarded, and the
rebuild is disk-only re-verification (network fetches must still throw, as
the control proves); (4) the previously certified height/projection and every
PUBLISHED immutable prefix view survive the loss — only the cursor's
unpublished frontier is lost; the unfinished ready-prefix-read path must
serve from published views and therefore remains valid through custody loss;
(5) when F6 lands, this same event restores from the bound save plus suffix —
same trigger, cheaper rebuild; until then the disk-only init is the cost.
No second owner, no unbound resume, no request replay, no unrelated-identity
restart.

**R4-UNCERTAIN-CLAIM-DELIVERY-01 — RULED: exact redelivery is the sanctioned
recovery action; uncertainty is not observation-only.** R4's "no resubmission
of uncertain writes" is refined to its intended meaning: never CREATE a new
submission instance (new signature, new operation identity, new bytes) while
an outcome is unknown, and never deliver on timers or polls. Redelivery of
the SAME durable, deterministic claim — byte-identical artifact, application
identity derived deterministically from {claim, target} — through the
target's EXISTING dedup is not that; it is the at-least-once liveness
mechanism the lane already relies on, and it also covers the
never-delivered-before-worker-loss case with no special path. Conditions:
(a) identity-exactness of the redelivered artifact is asserted, not assumed;
(b) target idempotence is proven by a permanent control — double delivery,
including delivery-after-acceptance, yields exactly one application, the
second refused/inert by the existing submission dedup/OCC/reclassification
machinery; if that control ever shows a double application, the defect is in
target admission and must be fixed there — it is never a reason to forbid
redelivery; (c) delivery happens only at genuine progress edges with the
existing finite attempts; (d) ordinary absence and f+1 current-view status
remain status observations — they authorize nothing and are required for
nothing, because redelivery is safe independent of whether the prior
delivery was accepted. The operation loop may now be converted to the shared
wave under this ruling. This ruling also gives the standing duplicate-receipt
gate its target-side test obligation.

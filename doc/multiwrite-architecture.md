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

## 13. Addendum 2026-09-13 (same authority): S8 design ruling — §3 closed

**S8 design (/tmp/quod-L2-s8-design-FYxCz2/REVIEW.md) is ENDORSED** as the
S8 implementation contract with the corrections below. Execution model,
owner table, one coordinator engine with target-keyed work, the pure
`quod_operation` transition library (no process), AM3 certificates with
domain-separated L3-Finalize vs L2-application statements, the certified
receipt arm, complete-vector-once reply, redelivery per §12, effects
unchanged, and the deletion list all stand as written.

**§3 CLOSED — selected-intent authority is STRUCTURAL; no control-flow
witness is required.** The question "how do validators prove `independent`
sat on the successful branch" rests on a premise this architecture does not
hold: branch-selection fidelity is EXECUTION fidelity, which quod already
delegates to each executing host. Targets today verify the client signature,
re-prove `can_invoke` for the invocations they executed, and bind plan/request/
manifest digests — they do not and cannot verify that a source's derivation
was the correct consequence of the goal. Independent dispatch changes nothing
about that trust boundary, for two reasons:
1. Forging surviving intent grants a Byzantine source NO new capability.
   Atomicity protects against partial FAILURE; a source that controls
   execution can already produce a partial commit of authorized writes by
   submitting one target's write alone. Lane selection is therefore an
   execution-fidelity property, not an authorization property.
2. Authorization for independent treatment is bounded by PROVENANCE, which
   each executing host records for its OWN material (S6: invocation mode
   threaded on the wire; each scope seals with its own provenance mask).
   No host can obtain independent treatment for material it did not itself
   stage under a wrapper.
The sufficient existing mechanism, made mandatory for S8 admission:
(a) client-signed request bound to the claim (S7, exists);
(b) source-owner-signed claim bound to request and plan digests (S7, exists);
(c) NEW ADMISSION CHECK: every target admitted to an independent claim must
    find its OWN sealed material staged under independent mode per its own
    scope-session record (provenance mask 2, no ordinary bit) — a target whose
    own seal says ordinary REFUSES independent participation by name; the
    source's word is never substituted for the target's own record;
(d) the origin's S6 mixing veto (exists): a remote intent flag can only ever
    cause a REFUSAL (mixing) or select L2 for material every executing host
    itself marked wrapped — never an unauthorized downgrade; this is codified,
    and the remote flag is explicitly NOT an authority input, only a selection
    hint checked by (c) and (d).
Consequences: the temporary N>1 route/validator/worker refusals are removed
in the same scope that lands (c) with its controls. Rules within remote
ontologies may themselves declare independence for their own sub-actions
(the ontology author's prerogative, executed on its own trusted host) — this
is by design, not a hole. No second evaluator, no KB transfer, no request
replay, no extra client signing, no restricted top-level-wrapper shortcut.

Additional controls (join §7 of the design): (i) target-side refusal when
its own mask lacks the independent bit, exercised at the validator endpoint;
(ii) forged/stripped remote flag with origin-local ordinary material → mixed
refusal, and with all-wrapped material → L2 with every target's own mask
honest (documented as by-design); (iii) source claim marking a target
independent whose seal is ordinary → refused by (c). The action-savepoint
scope precedes the action-based acceptance case, as already ruled.

## 14. Addendum 2026-09-13 (same authority): S8-READSET-SYMBOL-ORDER-01

**Diagnosis CONFIRMED** (independently: term-order probe). Read-set material
is canonicalized through an Erlang map round-trip; small maps (≤32 keys) list
atoms in a fixed name-based traversal, an opaque foreign symbol (a tuple)
falls outside that order, and large maps (>32 keys) iterate in hash order —
not ordered at all. So a verifier that lacks an atom re-encodes different
bytes and correctly refuses as noncanonical, and >32-key read-sets were never
representation-stable. Pre-existing in the S7 format; surfaced by S8's
cross-gateway reconnect.

**RULING — one shared, representation-independent read-set codec; no format
break for the real population; no S8-only path.**
1. Canonical read-set order is ASCENDING by the key pair
   `{UTF-8 predicate name, Arity}` — name bytes first, arity second — never by
   term order, map iteration or symbol representation. **Arity is part of key
   identity** (amended 2026-09-13 from "symbol NAME" after the golden-byte
   evidence: read-set keys are name/arity pairs, not bare names; `foo/1` and
   `foo/2` are two distinct keys). The SAME codec serves plan read-sets,
   semantic IDs and signed envelopes (`quod_dtx:encode_material`,
   `quod_transaction:semantic_material_bytes`, `encode/decode_material`).
2. The exact traversal direction is whatever the current all-atom small-map
   path emits today, pinned by GOLDEN-BYTE controls against real .174
   encodings — the codec must reproduce those bytes exactly. This makes the
   correction BYTE-PRESERVING for every producer that held its symbols as
   atoms with ≤32 read keys, i.e. the expected entire population: signatures,
   semantic IDs and stored bytes unchanged. Not a format break.
3. Verification never depends on a map: decode into the ordered pair list,
   validate name-order and name-uniqueness on the wire form, use a map only as
   a lookup index. Opaque symbols compare by name; no atom allocation on the
   consumer; no read-set omission; no relaxed signature/ID/canonical checks.
4. Duplicate/alias keys (atom and opaque tuple with the same name AND arity)
   are one key and are rejected as duplicates. Same name with different arity
   is not an alias.
5. Large maps: name order REPLACES hash order. Before commit, a read-only
   scan of all retained ledgers, signing/effect journals and caches must count
   read-sets with >32 keys. Zero (expected) → no break occurs. Any → that
   subset would become undecodable, and under the clean-break policy this is
   an EXPLICIT decision for Yan, never silently absorbed.
Controls: cross-VM producer-atoms/consumer-opaque byte-equal round trip;
consumer atom-table unchanged; golden signature + semantic-ID bytes vs .174
fixtures; alias-key rejection; key-set sizes 2, 32, 33, 64 encode identically
regardless of representation and of map iteration; mixed-representation
producer equals all-atom producer; the failed reconnect CT becomes the
permanent regression. This settles a correctness defect; S8 lane design and
intent authority (§13) are untouched.

**CLOSURE 2026-09-13 — both pre-commit obligations DISCHARGED**
(evidence `/tmp/quod-S8-readset-evidence-XfLvIS/HANDOFF.md`):
- §14.5 scan: read-only, in place, all ten .174-c4p1 allocations — 768
  distinct files, 1,510 read-set occurrences across active state, inactive
  pre-refound cloud state and retired caches; **zero above 32 keys, largest
  11**. Positive 33-key controls detected in all seven carriers (ledger,
  signing journal, effect journal, manifest, checkpoint, outcome DETS, phase
  DETS), so zero is a real zero. **No format break occurs; no decision is
  owed to Yan.**
- §14.2 golden bytes: real .174 encodings (2 keys, 32 keys) confirm ascending
  `{name, arity}` order; entire signed envelopes, signatures, semantic IDs,
  plan sealing and plan digests reproduce byte-exact. **Byte preservation
  proven on real vectors.**
- Codec shape as ruled: one pure library shared by all three encoders; wire
  order and uniqueness validated before any map is built; maps as index only;
  the old builder and the duplicated validator deleted.

**Reconnect residual — fixture precondition, not a second defect.** After the
codec correction, the standalone partial-outcome reconnect case still failed
because gateway B had no route to C (the suite withholds it in setup for a
different case); B's lookup waited out its caller budget and returned retry.
That is the CORRECT fail-closed behaviour under R2. A route-only
counterfactual (the ordinary C directory record added, same signed request,
no resubmission, no production change) returned the exact earlier complete
mixed vector. Pins: (a) the fixture establishes every route precondition
EXPLICITLY inside the case that needs it; (b) route absence and route
recovery are each their own isolated case with its own oracle; (c) no case
may depend on suite order or clear a route another case needs — the
standalone and combined runs must exercise identical setup. Recommended:
commit the codec correction as its OWN scope ahead of S8 (pre-existing,
L2-independent, byte-preserving), with the reconnect CT as its regression.

## 15. Integration note — Yan's confirmed product decisions

Yan confirmed on 2026-09-12 that independent writes must reuse existing actions;
§11 A1's condition is satisfied. Yan also explicitly requested fast ontology
restart from durable snapshots plus a suffix. This confirms AM2/F6's inclusion;
no snapshot cadence or fleet wipe is authorized by that request.

### Process and messaging constraints (Yan, 2026-09-12)

This refactor is for performance, not another layer of services. Use the
existing `quod_reg` gproc naming, subscriptions and name monitors. Registration
does not make a synchronous call asynchronous: long work must leave the owner
free to consume its normal result, progress, expiry and death messages.

| Process role | Cardinality and lifetime | Exclusive responsibility |
| --- | --- | --- |
| Simplex | One per hosted ontology, under the existing namespace supervisor | Consensus, signing/ledger custody, ordered publication, retained certified-history index |
| Prolog | One per hosted ontology, after Simplex in the existing restart order | Committed facts/outcomes and proof/session lifecycle; temporary proof data remains in existing workers/stores |
| Catch-up, feed, runtime | Existing three per-ontology siblings, not three new state owners | Range transport, dissemination, derived runtime respectively; no private authoritative ledger or KB |
| Multiwrite coordinator | Existing monitored child per exact durable obligation, retained across temporary unreadiness | Pending actions and verified results through one asynchronous wave/result loop; completion and real ownership changes end it |
| Foreign-history custodian | Existing node owner plus exact anchored-identity writer custody | Non-hosted retained history only; no duplicate hosted-history work |
| I/O and proof workers | Existing operation-scoped work, not permanent per-phase actors | Explicit input/view, original deadline, correlated result to the owning loop; no independent signing or commit authority |

Transport, routing, directory, effect-journal and Brahms processes retain their
existing responsibilities. This is the affected-process inventory, not a
claim that the whole node contains only the two primary state owners.

Message rules:

- Discover named owners through gproc. Pin the exact owner PID/incarnation
  for an admitted request; a replacement registration cannot inherit its
  response or authority. Use the existing gproc properties for progress and
  route notifications, with subscription before checking state to close the
  missed-wakeup window. A notification is a hint, never certified evidence.
- Owner-to-owner work uses correlated asynchronous requests/results in the
  ordinary receive loop, not a synchronous call chain or a nested collector.
  Required same-turn captures may be requested by an existing I/O worker;
  they must not make the consensus or facts owner wait on another owner.
- Start deadlines before dispatch and check them when consuming results.
  Sending is neither mailbox delivery nor processing; a committed signal is
  not delivery. Preserve the existing uncertainty and credit protocols.
- No polling process, retry timer, second queue owner, or per-target actor
  framework. Keep existing safety/format bounds without inventing worker caps
  to disguise saturation. Account for actual mailbox residence separately
  from send-to-dispatch time.
- Count all spawned workers and existing one-shot death watchers, not merely
  named actors. Existing watchers protect custody even when a worker cannot
  receive; they cannot be silently deleted or multiplied as an optimization.
  Each worker must have one explicit owner and a tested termination path.

For F6, use a verified immutable save image and asynchronous completion through
existing ownership. Do not invent a snapshot-manager actor or block either
primary owner on bulk serialization/disk I/O. The saved manifest must bind
the certified history and applied facts to their actual frontiers; committed
and applied heights are not interchangeable. Startup restores usable saved
state plus its suffix; absent or invalid saves take the one reported rebuild
path. Replay must not re-fire historic effects or reactions. Publication,
crash consistency and cadence remain F6 implementation-review obligations;
this paragraph does not claim they are implemented.

The approved revision-2 structural text and deletion ledger are embedded below
so this document is self-contained. Their original proposal/status wording is
preserved for exact provenance; §§1–11 above settle and supersede those pending
ruling/status statements. The embedded texts are not competing alternatives.

---

# Appendix A — Approved structural text (original revision 2)

# Multiwrites — structural rewrites and simplified architecture, revision 2

Proposed for Claude's architecture ruling. Supersedes the earlier convergence
text, not the approved correctness invariants. No production changes in this
review. Implementation baseline: published S7/.165 `91c94d527d1ef81ac5882310f43f0fbae584a9a3`.

## 1. One write pipeline, explicit semantics

```
signed goal → existing temporary proof state → sealed plans
                                              │
                                  select by intent + writers
                                     /                 \
                       ordinary atomic rules      explicit independent
                                     \                 /
                               same target validation/apply
                                              │
                                  verified client result
```

Keep the existing read/single-target cases. Atomic multiwrites remain the
default. Independent multiwrites share target execution and delivery machinery,
but not atomic decision semantics. N=1 is the ordinary case of the generalized
target vector, not a second implementation. No framework, new service or lane
fallback is needed to express this distinction.

Proof/backtracking, retained staged writes, signed intent, provenance veto,
policy validation, durable effects and the C1/C3 result rules are unchanged.
Do not simplify by dropping their checks or conflating their different states.

## 2. Four responsibilities in existing owners

| Responsibility | Existing owner | State that genuinely belongs there |
| --- | --- | --- |
| Hosted certified history | Simplex | Durable prefix, retained phase/committee lookup, coherent immutable read views |
| Non-hosted certified history | Foreign-log owner and its existing registered writer custody | One verified prefix per anchored identity; missing-range acquisition and followers |
| Facts and proof | Prolog plus its existing worker-local proof/session libraries | Applied facts/outcomes and temporary proof state; no second facts owner |
| One multiwrite's progress | Existing group/operation coordinator | Exact obligation, pending actions and verified results; no duplicate ledger or facts projection |

Libraries may share algorithms, but do not own another copy of the same truth.
Committed and applied heights remain distinct: consensus inclusion is not
execution completion. Historical membership is not fresh identity authority.
These are necessary distinctions, not redundant flags to delete.

### Structural rewrite of the three oversized modules

The target is a rewritten internal design, not cosmetic extraction. Keep each
existing actor's identity and externally required behaviour while replacing
its oversized internals with explicit state and small transitions. There is
no permanent old implementation, runtime switch or second actor alongside it.

- **Simplex becomes the consensus/ledger owner.** Extract its pure certificate
  pool/block-tree transition into one consensus-core library; reuse the
  existing quorum, ledger, signing-journal and ingress-state libraries. Shared
  certified-history transitions belong in one owner-free history library,
  used by hosted and foreign owners. Target validation stays in the existing
  validation/projection libraries and workers. Endpoint transport correlation
  uses one lifecycle, not several nested owner loops. The Simplex actor alone
  performs signing, durable append and ordered publication; grouping fields
  must not hide a second copy or move signing authority elsewhere.
- **Prolog becomes the facts/proof-lifecycle owner.** Keep the existing
  `quod_committed_projection` applier rather than inventing another one. Use
  the already-existing proof-context/session/scope implementations for both
  local and remote execution. Rewrite the surrounding request/session/result
  handling into one explicit lifecycle with transport-specific bindings at
  admission. Remove duplicate adapters and obsolete public-prove rendering.
  Remote authentication, sequence checks, cancellation and temporary-store
  semantics stay real; they are not collapsed into an untrusted local call.
- **Foreign-log becomes the non-hosted history custodian.** Rewrite its
  acquisition and verification lifecycle around one retained verified prefix
  and one job state per identity, with the existing writer-custody proof.
  Drop local-host verification jobs entirely. Use the common history library
  instead of a second reconstruction design, and the existing foreign
  projection library for genuinely needed materialized remote facts. Ready
  prefix reads no longer join the queue for a higher missing range.

These are responsibility boundaries, not instructions to create one new file
for each old section. New pure libraries are justified only where they remove
duplicate implementations or actor-specific dependence on shared algorithms.
They must not receive the entire actor record and become disguised extensions
of the same god module. No generic workflow framework or service layer.

Replace one closed responsibility at a time, across whichever of these actors
it touches. Maintain one runnable implementation after each reviewed scope.
This is a rewrite of internals, not a new consensus protocol, a format migration
or a whole-project restart. The current protocol/cryptographic invariants and
real regression controls constrain the new code, not the old function layout.

## 3. History: initialize once, advance, read

One history transition implementation serves startup, live commits and missing
windows. Startup retains its verified phase/era bookkeeping. Live work previews
only new entries, then the sole writer appends, installs the matching index
delta and publishes progress. A captured view at H never exposes later rows.

Keep the existing indexed backend; no replacement storage engine or separate
index service. Keep historical entries on disk and current/active state bounded
by its real work. Do not copy all historical groups into a new Erlang map.

Delete catch-up's empty-index creation/backfill path and hosted historical
`local_exact` reconstruction. Delete hosted-to-foreign-cache fallback. Known
retained foreign prefixes initialize during explicit owner startup, not first
request. Unknown remote history is acquired once as new data. An unavailable
owner stays unavailable; it does not trigger hidden repair/replay in a request.

One owner-view evidence interface retains A's target checks, sufficient-view
pinning and absolute deadline. A hosted but lagging identity waits on existing
progress under that deadline, or returns the existing typed unavailable result.
Fetching new bytes still uses peers; peers are not a second local history owner.
Fresh committee corroboration remains a different authority check.

Preserve registered writer custody until actual death. Consolidating a verified
prefix's representation must not create a concurrent writer during shutdown.
Do not turn an untrusted checkpoint into authority to avoid reconstruction.

## 4. Coordination: one action lifecycle

Use the existing asynchronous wave mechanism for all I/O actions, including
Begin/Decision/Complete, phase discovery and operation recovery. Ordered work
is a one-item wave; independent targets are a vector wave. All results return
through the normal owner loop, under the action's original deadline.

Delete the separate synchronous command driver, nested owner-side endpoint
collector and duplicate response-consumption paths. Keep one checked transport
primitive and one result-correlation/cleanup lifecycle. Shared I/O does not
mean one giant generic protocol state machine: L3 and L2 retain their small,
explicit protocol planners.

The coordinator remains owned while its exact durable obligation exists.
Temporary sync/Prolog unreadiness disables actions; it does not erase the owner
row. Actual progress wakes existing work. Completion or real ownership change
retires it. Delete the readiness-driven teardown/rebootstrap cycle. Keep all
signing, admission, apply and proof-readiness checks.

Keep only one authoritative representation of pending work. In particular,
fold separately maintained queued/running job metadata into a single lifecycle
where the ownership proof permits it; do not add a parallel queue or scheduler.
Distinct caller deadlines, shared-work lifetime and write uncertainty remain
explicit. Never substitute a retry timer, renewed allowance or resubmission.

## 5. L2 finishes on this machinery

One source claim, the canonical N-target set, independent target actions, one
complete certified result vector to the client, then asynchronous source receipt.
No final partial vector; timeout means uncertainty. No verdict label inferred
from an inclusion reference, transport reply or peer-supplied intent Boolean.

Recommend extending the existing applied-certificate family for exact operation
results, not introducing another target-facts replay engine. Its statement must
bind network, claim/operation, anchored target, exact application occurrence and
canonical terminal result, attested only after durable outcome publication.
The stronger verdict authority still requires the slice-8 quorum/committee/key
lifetime ruling. Existing f+1 current-view lookup is not its substitute.

Keep S7's single-format receipt union and its reviewed historical included arm.
Remove the temporary N>1 lane-unavailable guards only with signed-intent
authority and the genuinely admitted partial-outcome control in place.

## 6. Delete as part of replacing

`DELETIONS.md` is the implementation checklist, with separate dispositions:
unreferenced code, test-only/obsolete adapters, active paths to replace, and
required runtime entry points that must not be mistaken for dead code.

Every replacement commit must delete the superseded implementation and its
exclusive callers/helpers, message variants, state, metrics and stale comments.
No old/new selector, compatibility wrapper or permanent second path. A new
abstraction must name what it removes; moving code between files earns no
complexity-reduction claim. No process is introduced merely to shrink a module.

Test helpers may construct inputs; they must not keep a second implementation
of removed production behavior behind TEST. Port useful assertions to the one
live path, then delete obsolete-behavior tests. Preserve failures and controls
in frozen evidence. Do not remove feature or fault coverage to hit a line count.

## 7. Completion means both correctness and removal

- Close the complete unused-export/caller inventory, including dynamic roots,
  and remove each genuinely unused implementation plus newly dead descendants.
- Record before/after production functions, exports, state fields, message
  variants, duplicate execution paths and physical source lines. Distinguish
  actual deletion from relocation, comments, tests and generated assets.
- Prove zero old-prefix replay after initialization, coherent views, one writer,
  responsive coordination and retained obligations during temporary unreadiness.
- Prove signed N-target admission, certified mixed outcomes, one final vector
  and asynchronous receipt through the actual production path.
- Clean sequential gates, full logs, true exits, flake triage and exact-tree
  review; separately labeled hardware evidence for latency. No skipped gate
  or speculative 50,000-line reduction becomes a completion claim.

Claude's remaining architecture rulings are the coherent retained-index view,
hosted-lag ownership amendment, readiness-vs-retirement policy, and L2 exact
verdict authority. No wipe is authorized; .165 remains undeployed. Frozen
evidence, Yan's files, R-RESTART-RACE-01 and both EUnit ledger items stay intact.

---

# Appendix B — Approved deletion checklist (original text)

# Deletion ledger — required by architecture revision 2

All references below are to .165 `91c94d527d1ef81ac5882310f43f0fbae584a9a3`.
This is a reviewed-design input, not a claim that production deletions have
already happened. A missing static call is a candidate, not sufficient proof
that an exported function has no runtime, operator or test consumer.

## A. Concrete unreferenced implementations

The production call graph plus repository search identify these specific
removal candidates. Before the implementation commit, check dynamic roots and
operator contracts and close each row explicitly. Remove exports/specs/docs
with the functions and rerun the graph for newly orphaned private helpers.

| Candidate | Evidence / intended disposition |
| --- | --- |
| `quod_proof_session:run_first_with_dependencies/3` (775) | No repository caller. A second one-solution adapter, while `run_first/3` and explicit session access are live. Delete this unused adapter; retain the live dependency-capture path. |
| `quod_proof_session:absorb_live_bridges/2` (445) | No repository caller. Its only delegated call is to the following unused subtree. Delete the entry point, not live bridge tracking generally. |
| `quod_erlog_db_local_prove:absorb_live_bridges/2` (629), private `valid_bridge/1` (658) | The unused session adapter is the only known caller of the merge API; its validator is exclusive to it. Delete the closed subtree after removing that root. Ordinary `absorb_read_set`, bridge recording and proof authorization remain. |
| `quod_dtx:live_bridges_bytes/1` (531), `live_bridges/1` (762) | No repository consumers found for these accessor functions. The underlying signed material remains in the canonical plan and validation; deleting an accessor does not delete its wire field or authority check. |
| `quod_committed_projection:target/1` (91) | Unreferenced getter. Do not remove the anchored target from projection state. |
| `quod_client_goal:digest/1` (116) | Unreferenced convenience accessor. Preserve canonical request digests and every caller's verification. |

These examples establish real deletion opportunities, not a basis for claiming
50,000 lines are dead. Public/trusted in-VM APIs need explicit disposition even
when no in-repository runtime caller exists.

## B. Obsolete or test-only production surfaces

| Candidate | Required replacement / evidence |
| --- | --- |
| `quod_explorer_http:prove_result/1` (131), `participant_slots_json/2` (201), `bindings_json/1` (215) | Explorer now serves ledger/status reads; this proof-response renderer is called only by its tests. The latter two helpers are exclusive to it. Port any still-required protocol assertions to the signed client result path (`quod_client_http:signed_proof_result` and its normalizer), then delete the old renderer and exclusive helpers. Do not delete shared history/outcome JSON builders. |
| `quod_prolog:submit_plan/4` (594) | Only tests call this unsigned convenience wrapper; production uses `submit_plan_encoded` and the scoped protocol. Remove the wrapper after tests exercise the current target-owned path. The actual submit-plan owner handler is live and must remain. Correct stale comments claiming this arity is the production entry point. |
| `quod_foreign_log:verify/5` (370) | Documented explicit-source fixture API; no static production caller. Port controls through the canonical resolver with source/transport fixtures, then remove this alternate public request and exclusive admission arms if the dynamic/operator audit confirms no other consumer. Never replace real verification with a fake test result. |
| `quod_catchup:catch_up/5` (643) | Genesis-only adapter used by tests, while production calls the owner-view form. Port initialization controls through the one canonical initialized-owner interface; remove the second adapter, not genesis verification. |
| `quod_client_auth:materialize_goal/3` (132) | Tests use this goal-only message; production uses the full authenticated request. Port atom-budget/security assertions to that path before deleting the wrapper and exclusive handler. No budget/check removal. |
| Other test-only accessors/constructors, e.g. DTX transcript/read access and operation `included/1` builder | Inventory individually. Prefer the existing canonical inspection/construction API. A minimal test-only input constructor can remain in test code; a duplicate verifier or execution path cannot. S7 historical included rows remain valid. |
| `quod_ns_sup:stop_namespace/1`, `namespaces/0` | No literal repository callers found. Audit operator tools before deleting these facade APIs; keep the actual supervisor child operations and namespace-manager authority. This is not permission to remove hosting features. |

## C. Active duplication that the new architecture removes

These paths are reachable today, so a dead-code checker will not flag them.
They must be deleted in the same implementation scope as their replacement.

| Delete | Retain / replace with | Structural proof |
| --- | --- | --- |
| Catch-up `window_has_dtx`-driven scratch initialization, `open_phase_index`, `backfill_phase_index`, `backfill_phase_windows` and exclusive cleanup/error paths | Retained owner phase/era view; one missing-window verifier | Existing 8/64/257-prefix control becomes zero old-prefix reads and verification for a one-block gap, with real retained-owner fixtures |
| Hosted `verify_historical_local_reference` / `local_exact` reconstruction job, its source-owner gate and exclusive queue/worker clauses | Exact indexed historical committee/reference lookup on the captured hosted view | Old-epoch reference succeeds without prefix replay; stale/lost/superseded view still fails closed |
| Hosted-insufficient-view route-to-self-cache behavior | Same anchored local owner, existing progress/deadline | Lagging or unavailable hosted view launches zero duplicate foreign-cache jobs |
| Request-triggered `open_replayed_cache` reconstruction of retained history, and repair-on-next-request fallback | Explicit owner initialization plus retained verified prefix through failure/idle | Startup work is counted separately; route failure and later callers cannot trigger an old-prefix replay; one-writer custody remains |
| Coordinator's separate synchronous `drive_one_command`/`run_command` path and owner-side `collect_submit_endpoint_results` receive loop | Existing asynchronous wave/result lifecycle for ordered and parallel actions | Hold actual endpoint I/O; coordinator still handles owner/progress/deadline events; one outcome correlator and original deadline |
| Duplicated ordinary/uncertain phase delivery walks and their I/O lifecycle | One action mechanism with explicit ordinary/uncertain response policy | Fresh correlated absence remains required before uncertain write resubmission; invalid/abstain distinctions preserved |
| Readiness-driven removal/rebootstrap of a still-owned coordinator | Existing obligation row survives; only execution is gated | Existing real-child controls become same-child retention under temporary sync/Prolog unreadiness, with no signing/dispatch while prohibited |
| Duplicated queued/running common job metadata and conversions | One existing-owner job lifecycle where the custody proof supports consolidation | Correlated result/death handling, caller detach and actual-death writer exclusion preserved |
| Permanent N=1 selection/refusal fork in the operation worker | N-target action/result vector including N=1 | Real admitted N>1 partial outcome; no first-target shortcut, partial final reply or receipt-before-client delay |

The three giant actors are rewrite targets, not untouchable hosts for these
patches. The accompanying architecture names their final responsibilities.
During that rewrite, the operation owner's scalar `target_result` and vector
`target_results` must converge on the canonical target vector and an explicit
delivery obligation; do not retain both singleton and N-target result models.
The distinct receipt-custody and outstanding-client obligations must survive.

Shared lower-level request/certificate checks can remain in workers. The old
owner-blocking path must not merely be moved wholesale under another owner or
wrapped as a second permanent executor.

For every row, remove associated obsolete metrics and documentation only after
checking actual consumers. Keep ordinary diagnostic spans and all frozen C4/O
evidence; the shelved Phase-2 tree is not production and remains untouched.

## D. Do not mistake these for waste

- OTP behaviours, supervisor child-start MFAs, statem state functions, Cowboy
  handlers, logger formatters, configured extension modules and Erlog callbacks
  are runtime roots even when xref finds no direct caller.
- `independent/1`, transaction/action/ontology predicates and Erlog database
  callbacks are dynamically dispatched. They are not removable dead exports.
- Trusted console APIs are separate intentional entry points; unreferenced
  does not alone mean obsolete. Removing an actual feature requires scope
  agreement, not a line-count target.
- C4 compile-gated SDK observation is absent from ordinary call edges but used
  by the separate diagnostic build and harness. Keep it while that contract
  and the pending observations require it.
- Ledger inclusion vs Prolog application, historical membership vs current
  identity, caller lifetime vs durable/shared work, and control-plane metadata
  vs proof/session state are distinct safety responsibilities. Keep those
  boundaries while eliminating repeated implementations around them.
- Existing death/custody monitors, original deadlines, size limits guarding
  untrusted input, signature checks, refused-format tests and ordered apply
  guards are not deleted to make the program look smaller.

## E. Closure and accounting

Maintain an explicit disposition for every static candidate: delete, convert
to a test input helper, keep with a concrete runtime/operator root, or unresolved
pending review. No unresolved row is silently counted as removed. Follow
private descendants after deleting a public root; a clean locals-not-used
check alone cannot discover an unused exported subtree.

The scoped refactor must show a net removal of superseded production machinery.
Report functions, exported surfaces, unique state fields/message variants and
execution paths as well as physical lines. Compare the same build profiles,
include subdirectories, exclude generated bundles/dependencies, and separate
new L2 functionality from replacement/deletion. Moving code or deleting comments
does not count as eliminating execution complexity.

No user-owned plan/figures or frozen files are edited. Shared dead-adapter
cleanup outside the measured core is its own reviewed scope; it does not hold
the multiwrite fixes hostage to a whole-project cosmetic rewrite.

---

## Current implementation status

This section is the single implementation-status reference. The byte-pinned
rulings above and the original structural/deletion appendices remain design
inputs, not competing deployment diaries. Commit-specific gates, controls,
measurements and authorization are recorded in their frozen handoffs.

### Shared history and coordination

Simplex is the sole local ledger/signing/phase-index mutator. Catch-up captures
one short read-only prefix, verifies its window, and returns a delta; the owner
checks its base, appends and installs before publication. Exact ready-prefix
reads do not queue behind newer acquisitions or replay old history. Foreign
writer custody remains sequential. Published immutable views survive writer
loss; the existing foreign owner rebuilds only the affected derived index.
Custody loss, diagnosed corruption and phase-index handoff loss have separate
counters. A published DETS prefix retains its read hold; old and tentative
resources may coexist during reconstruction. This is not a second index owner.

Group, operation-recovery and dormant-cancellation work share
`quod_dtx_coordinator`'s asynchronous wave/result lifecycle. The replaced
blocking loops are deleted. Existing owners, progress messages, monitors and
absolute deadlines govern work; timers do not authorize redelivery.
Exact durable claim redelivery preserves its deterministic application identity
and relies on proven target deduplication. Uncertainty never creates a new
submission instance.

An atomic submission plan retains one canonical signed record; each concurrent
endpoint delivery owns its own transport request ID. The winning delivery's
actual request binds its response, while target retention and inclusion remain
keyed by the unchanged semantic record. Sibling cancellation releases transport
resources, not durable work. Phase queries walk peers sequentially and release
each correlation before advancing; they do not need a second fan-out mechanism.

`quod_dtx_owner` is a pure registry/transition library, not an actor. Simplex
executes its signing and publication decisions. The signing journal is the
single pending-Begin authority; the `dtx_pending` shadow inventory is deleted.
Indexed inclusion precedes readiness: late exact Prepares return certified
references without signing, retention or proposals. Conflicting phase digests
still refuse. Temporary catch-up preserves ownership; real admission loss
retires it. Classification precedes renewal, and resolutions publish after
commit/skip/catch-up application.

Retained relay placement on the current reliable link is work eligibility,
not just duplicate-send suppression. An already placed phase does not rebuild
or preview candidates on unrelated owner turns. Link replacement or new
unplaced work uses the existing driver; selection still checks the complete
canonical phase, including placed rows, before sending only its unplaced
subset. The same placement predicate governs selection and sending; there is
no new owner, queue, timer, retry or consensus authority.

An installed durable parent resumes held consensus validation through the
existing owner reconciliation. Validation requests use the existing
gproc-addressed Prolog owner and its exact applied-parent/outcome-floor checks;
they do not require permission to cast a fresh vote. In particular, an ahead
finalizer cannot block the validation needed to install that same finalizer.
Only participants request the verdict, and the existing signing boundaries
still require voting readiness. No certificate substitutes for a local verdict,
and neither a tick nor leader redelivery is needed to notice parent progress.

Certified block retrieval uses one owner-local lookup across the live engine
and committed ledger. Pruning engine memory does not retire durable block
availability. The durable lookup is the existing bounded sparse-index read,
not history opening or replay. The requester already holds the authenticated
support certificate; replies carry only canonical block bytes and their exact
requested hash. Outstanding-request, committee, hash, parent and final-vote
checks remain, and DTX still requires its local exact-parent verdict. The
certificate-bearing reply is removed rather than reverified or retained in a
second inventory. This transport-only break requires a coordinated fleet swap;
durable formats and retained data are unchanged.

Authenticated finality beyond the approved frontier is reconciled in the owner
turn, without two tick samples to reconfirm a cryptographically proven gap.
An exact next-parent validation with an installed monitored request is preferred
within its original validation deadline when the same hash has both support and
commit certificates. Its verdict or matching DOWN releases that request and
re-enters reconciliation; worker exit alone does not discard an answer still
queued for the owner. Missing/stale/expired work or a higher finalizer uses the
existing history-recovery worker. This selection never relaxes `behind` voting.
Only failed acquisitions retain the existing tick-driven backoff; ordinary peer
traffic cannot spend it. The same recovery enum enforces single flight, and the
same history verifier, indexed delta/sink and tip corroboration own advancement.
Finalized slots leave the support-only block-request walk instead of repeatedly
revalidating proposal bytes with a missing sidecar. Before finality, normal local
proposal checks remain mandatory. Complete validators still never repeat the
coordinator's target-application fan-out; committed Complete recovery uses its
origin QC through the existing certified-history path. No new state owner,
timer, polling loop, durable format or voting authority is introduced.

Accepted Begin activation uses the existing admission FIFO, not a separate
readiness/signing walk. The existing `from = none` distinguishes handed-off
rows from calls still awaiting acceptance. Identity and exact manifest binding
are checked before readiness; recovery parks the same authenticated material,
group and deadline without signing. Activation joins the FIFO in arrival order.
Pending-group and phase reads include these queued rows. Ready progress performs
classification, admission and coordinator reconciliation in that dependency
order in one owner turn, preserving paused ownership without authorizing
endpoint execution. Expiry, cancellation or changed ownership cannot sign the
intent later. A post-handoff resolution remains a hint to the existing exact
outcome/barrier check: if concurrent progress prevents authoritative absence,
the caller retains the existing deadline/uncertainty grammar, never a fabricated
rejection. No new tracking or reply authority is added.

### Independent writes and authenticated data

One proof evaluator stages and seals once. Ordinary multiwrites stay atomic;
only surviving independent intent selects L2. Every target supplies its own
signed independent eligibility attestation. Source and target admission refuse
a multi-target claim missing that attestation as `independent_scope_required`.
Peer-supplied intent flags are not authority. The intermediate N>1 lane-unavailable
refusals and the scalar worker fork are deleted.

`quod_operation` is the same pure target-keyed model in existing owners and
read-only resolution. A durable claim feeds apply/verify/certify work on each
target independently. Real progress edges are coalesced and spent per unfinished
target; an included target needs certification, never reapplication. One
worker per logical index, stale-result rejection, readiness pauses and the
original wave deadline remain. Only the complete certified vector joins.

Claim construction and canonical decode authenticate each opaque bundle once.
The transaction carries its authenticated plan/context view, bound to the exact
origin, manifest and bundles; it is not a wire field, store, global cache or
caller-supplied token. Target validation materializes only its own plan once
and carries that material through ordinary effect, OCC, membership and ACL
checks. Source cancellation reads opaque effect-plan headers and delivers the
unchanged signed claim. Foreign evidence does not allocate target vocabulary.

The source semantic identity and client binding are derived once per prediction
vector. Every plan still binds the exact request. Signed bytes, signatures,
semantic IDs and durable schemas are unchanged by carrying decoded views.
The private prepared-genesis journal explicitly encodes its existing native
transaction schema instead of serializing the evolving runtime record. Its
original byte-count/hash oracle is unchanged; runtime-sized native tuples are
not accepted as a second journal format.
Canonical read sets use UTF-8 name plus arity; opaque symbols do not become atoms
on receipt. Receipt evidence has one binding/verification owner. Exact decoded
values need no re-encoding; different symbol representations require complete
canonical-envelope equality, never unchecked IDs or signed-byte fields.

`quod_applied_certificate` owns domain-separated L3-Finalize and L2-application
statements. The latter bind network, historical committee, anchored target,
source claim/operation, exact application occurrence and terminal result.
`quod_quorum` owns the shared exact-f+1 verifier used by read and applied
certificates. Collectors authenticate votes once, assemble their certificate,
and recheck the original deadline; they do not verify their own votes again.
Batch certification validates every input before launching workers and carries
the checked statement/committee forward. The four observation families share
source selection and quorum admission, with distinct terminal policies. Stored
participant descriptors are checked against their authenticated plans and
reused for apply fencing; they are not an independent source of authority.

New source receipts contain the complete certified result vector. Historical
included-only rows remain valid discovery, not verdict authority. The durable
outcome row retains the format key `included` for its installed receipt,
regardless of arm. Receipt identity compares complete statements, not an
interchangeable honest signature subset. Pairing is canonical and shared;
the model carries the checked result for notification without rebinding it.

Each live caller receives one complete vector internally, with its deadline
checked at delivery. Mixed outcomes are success-shaped; partial vectors never
finalize, and expiry stays uncertain. The source receipt commits asynchronously.
Unowned reconnect resolution follows exact source receipt and target application
evidence, then AM3, without submitting anything. Its separate named observation
budget permits resolution after the original write expired.

The existing API presentation is unchanged: live N=1 execute presents a scalar
commit/rejection, while resolve presents a complete vector even for N=1.
Both use the same operation machinery. Uniform vector presentation for durable
operations would simplify clients, but changing that API is not a cleanup
side effect; ordinary single-target writes retain their scalar grammar.

### Proof, actions and process boundaries

Public `transaction/1` selects atomic intent and calls the internal
`quod_proof_savepoint` library. Action candidates call that same library with
inherited intent, so `independent(goal(State))` and the signed Root effect
compose without a hidden public wrapper. Failed candidates restore facts,
events, effects, provenance and cross-scope tokens together; reads remain
monotonic. Ordinary backtracking retains staged material. Public nesting rules,
successful-intent selection and the mixed-material veto remain unchanged.
`quod_proof_continuation` owns the shared released-scope/caller-error boundary:
a caller error cannot restore a candidate or read-only frame already released.

The pinned Erlog dependency contains the findall cut-barrier and sibling
cut-presence correction. Cuts select alternatives, not commits. Local,
co-hosted, remote, action, event and savepoint regressions remain required.
Effects keep their existing empty-diff/custody rules and executor. Exact outcome
lookup before redelivery covers both fact and effect applications; the journal
does not gain retention exceptions or become an outbox.

No new application processes, timers, polling loops, queues, gproc identities
or proof-state transfer protocol are introduced. Simplex owns signing and
ledger custody; Prolog owns proof/session/outcome publication; the coordinator
owns its existing monitored target workers; foreign history owns published
prefixes; the effect journal owns private effect custody. Addressing and progress
subscriptions use `quod_reg`/gproc. Nodes exchange goals, bindings, sealed material,
dependency metadata and certified references, never a Prolog database snapshot.
The system-ontology evaluator and ACL interfaces remain; agent/FIPA hosting
and delivery remain outside this implemented multiwrite work.

### Observation, formats and remaining acceptance

Group and operation span handles follow B's installed-owner token discipline
through `quod_attempt_span`. Caller ancestry stays separate from ownership.
Children write their final root event before owner notification. Fatal unwind
may expose a stale released token or lose a tentative handle; SDK end-after-take
idempotence is pinned, and lost roots are discrepancies, not idleness. SDK
failure cannot prevent shutdown. Boundary-span timestamps denote transitions;
their tiny durations are not queue-wait measurements.

Explorer serves history/status only; signed proof replies use the one client
normalizer and HTTP renderer. Formatter failures remain inside the redaction
boundary, and malformed receipt discovery bytes return retry before history
resolution. Neither diagnostic failure changes an operation's durable outcome.

The optional Phase-1 diagnostic decorator records both attempt families,
sampled/recording flags and effective SDK configuration. Independent VM counters
provide the start denominator. Normal builds erase allocation observation.
Analysis retains O-A1/O-A2: dropped/tied/unknown evidence stays counted and listed,
and coverage is a lower bound. Sampler reconciliation is explicit.

Durable transaction V14, ledger V6, signing QSJ4 and effect QEJ2 remain the current
single formats. Derived foreign-cache v4 supersedes v3 by name. Scope wire v13
and endpoint v12 require a coordinated full-fleet upgrade. This cleanup adds no
format break, ledger wipe or cache retirement. Existing frozen evidence and
STOP/BENCH_STOP markers remain untouched.

The .182 small retained-fleet witness completed 20/20 writes across atomic and
independent c1/c4, with 90/90 attempt roots captured. That establishes neither
broad performance acceptance nor a sub-500 ms L2 result. Compare the initial
concurrent four separately from the striped fifth request. Per-run details and
failed launches/analysis checks remain in the retained evidence, not erased by
a successful later witness.

Still open: Begin consensus/finality latency; broad c4/L2 acceptance and trace
attribution gaps; F6 fast-restart checkpoints; dependency-taxonomy enforcement;
R-RESTART-RACE-01; all three EUnit ledger items (B-EUNIT-UNIDENTIFIED-01,
EUNIT-SEND-TRACE-MAILBOX-01, EUNIT-OPERATION-FOLLOW-RACE-01); and the historical +8.7%
question (its earlier retained state was retired, not its question solved).
CT-JOIN-STARTUP-TIMEOUT-01 also remains open: a peer application-start timeout
has been observed in a combined gate run, followed by clean isolated reruns.
No gate is retired by this cleanup. Full clean sequential gates, retained true
exits and exact-tree review govern its publication. Yan's write-lanes and
performance-roadmap documents are reported separately, not edited here.

Exact ordinary application redelivery enters Prolog's one admission transition:
new work submits, pending work joins existing waiters, terminal work returns its
durable outcome. Private effects retain journal custody and a terminal lookup
before accessing possibly retired prepared material. Transport only frames and
correlates opaque claim/application blobs; existing workers authenticate them
and bind returned evidence to the exact operation before history/AM3 work.
Request-scoped contact matching runs in the existing foreign verifier, by exact
candidate claim bytes, not by decoding every active request in Simplex. Contacts
remain untrusted hints until the candidate's references verify.

Atomic queued intents and retained rows share the authenticated record, digest
and opaque plans; retained rows also hold the original signed envelope.
Admission and journal restoration create that material, and handoff reuses it.
Owner queries use it against the current installed
projection without reauthenticating history. Classification still precedes
signature renewal and publication still follows application. Slot/barrier
and relay-readiness eligibility precede candidate construction. Selection advances one
temporary projection through the shared reducer, never replays each selected
prefix, and never installs its preview in the owner. The selected block is reused
for local proposal. The canonical codec still sizes each growing candidate to
enforce block/frame limits; no estimated-size encoder, extra cache, process,
timer or durable format is introduced. Existing parent/author/finality checks
remain validation boundaries. Performance acceptance requires a fresh witness,
including target-owner admission-to-proposal residence; local call counts alone
do not establish fleet latency.
Queue progress still checks the current binding, deadline and projection;
carried authentication is not permission to sign after ownership changes.
Peer-candidate material failure uses the existing rejection and exact-retirement
transition, not a callback assertion or a second validation engine.

### Proposal receipt and admission

Simplex's existing bounded live-round map is the only owner of pending proposal
input. A canonical, bounded leader body may arrive before its durable parent.
The candidate field distinguishes that **unadmitted offer** from the existing
admitted DTX candidate: receipt alone grants no engine insertion, validation
verdict, support vote or recovery exemption. There is no second queue or owner.

The ordinary receipt and durable-parent/capability transitions advance the same
row. DTX and committee-changing input wait for their actual durable parent;
approval is insufficient. Temporary parent eligibility never latches a body as
invalid. Membership singleton shape remains a material check; the proposer
retains its durable-parent gate before collecting a membership batch.
Full admission runs once when eligible, followed by the existing exact-parent
verifier. Exact duplicates preserve that request's token, owner and deadline.
The wire parent is a slot, not a hash: an early offer cannot carry authority from
the uncommitted parent seen at receipt. Validation binds the parent actually
installed, and existing stale-verdict, owner-loss and deadline rules still apply.

Only live-window leader input or an exact certificate-authorized replacement
is retained. Rejected input stays bounded and latched: progress and alternating
invalid offers cannot repeatedly buy authentication. Existing pruning/reseating
owns cleanup. A requested, support-certified alternate may replace an unadmitted
first body, but must pass the same full admission before gaining authority;
a junk first offer has no veto over that evidence.
The existing committee-change transition invalidates unadmitted receipts whose
leader/certificate authority belonged to the old committee. It clears only
those bodies and hints, preserving every voting and validation latch.
An admitted ordinary block lives in the engine, not a duplicate candidate row.
Progress walks slot numbers and re-reads each current row, so a nested commit
cannot resurrect a stale snapshot. Recovery for a gap of at least two slots
and all signing/finality rules remain unchanged.

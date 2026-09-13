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

## 12. Integration note — Yan's confirmed product decisions

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

## History R1/R2 publication candidate — implementation status, 2026-09-12

The current approved body, including its morning section 12, is preserved
byte-for-byte above. The original architecture/deletion appendices are retained
as design inputs; their historical pending-ruling and deployment statements
do not override that body or Yan's subsequent explicit authority.

The history implementation now records separate owner-lifetime totals for
`custody_lost`, `cache_corrupt`, and `phase_index_lost`. The existing foreign
owner stores three diagnostic integers; its existing metrics collector exports
fixed-name node-wide gauges. Index handoff loss is not mislabeled as ledger
corruption or worker death. Repeated callers do not increment the cause again,
and a corruption rebuild does not count its reset acknowledgement twice.
No new timer, polling loop, process, durable format or repair authority is added.
Five targeted tests check actual death, inconsistent resident state, startup
corruption, live corruption without double-counting, and metrics exposition.

This is the narrow counter delta required by the morning history verdict.
Full assembled gates and exact-tree delta review remain required before its
commit. The separate coordination scope still owes operation/dormant-loop
conversion, actual target double-delivery idempotence, and ready-prefix reads
that survive mutable-writer loss. No deployment or performance result, F6
checkpoint completion, or completion of the morning minimum is claimed here.

## Coordination R3/R4 completion candidate — implementation status, 2026-09-12

This appendix supersedes the pending-work status above, not the approved
architecture. History and its counter delta are published through .169;
dead-adapter deletion and the reviewed Erlog revision are published through
.171. This coordination tree is an uncommitted candidate requiring full gates
and exact-tree review. No deployment or performance acceptance is claimed.

Group, operation and dormant-cancellation work now use the same responsive
wave/result lifecycle. Ordered work is a one-item wave. Source-custody calls
use native asynchronous OTP requests from the actual coordinator PID, with
the same wave correlation, deadlines and cancellation; no proxy bypasses the
source's caller-identity check. Exact durable claim bytes and deterministic
application identity remain pinned across progress-edge redelivery. The real
target double-delivery regression asserts exactly one ledger application.

The foreign owner's published prefix and the temporary writer's resumable
cursor have separate validity, not separate owners or indexes. The owner
retains read access to the existing index while it is still empty, before
the writer populates it. Mutation access still passes through the existing
registered writer's suspend/resume custody. A read hold cannot install deltas.
DETS requires matching underlying open options: read-only access is enforced
by the opaque library capability, not claimed as DETS read-mode protection.

Physical resource accounting is explicit: an existing DETS table process now
lives with each retained foreign prefix instead of closing between writers.
During reconstruction the previous published resource and the tentative new
resource coexist. There is no new application actor, watchdog, retry timer,
polling loop, queue, global inventory or alternative storage backend.

Ready exact reads do not join a newer range's acquisition queue. The owner
captures one historical era at the published height in its own turn; the
existing caller performs one point read and the shared exact verifier. No
DETS handle escapes that capture turn, no Prolog state moves, and neither an
unavailable capture nor an invalid proof authorizes another route/replay.
Published views survive mutable-writer loss; the exact node-owner lifetime
and original absolute caller deadline still bound result consumption.

Direct reads and acquisition use one point-read/verifier implementation and
one stage-tracing helper. Direct-read timing belongs to the real caller span;
there is no fabricated verification-worker span. Controls count capture/read
work independently of SDK export and preserve O-A1/O-A2 analysis discipline.
N>1 remains the ruled lane-unavailable boundary until slice 8. F6, the action
savepoint scope, R-RESTART-RACE-01, both EUnit ledger items, c4 and +8.7% remain
open; this candidate does not retire them.

## Transaction-owner integration candidate — implementation status, 2026-09-12

This appendix supersedes the publication status above, not the approved
architecture prefix. History and coordination are published through .172.
The .172 hardware witness exposed an incomplete ownership integration: the
coordinator retained work across catch-up, but signing reconciliation still
interpreted the same temporary pause as loss of ownership. A second local
pending inventory inside the history projection could also erase a Begin
admitted after a recovery worker's capture. The following is a local candidate
for exact-tree review. Yan has explicitly prohibited deployment for now.

### Responsibilities and deletion

`quod_dtx_owner` is a library called by the existing Simplex process, not a
second actor. It owns the opaque retained-control registry, anchored ownership
decision, classification, signature-action selection and desired obligations.
It reconciles the signing journal against current admissions and the current
installed phase index. It receives neither the Simplex actor record nor keys.
Simplex alone performs signing, append/install and ordered Prolog publication.
`quod_dtx_coordinator` remains the one group/operation/dormant execution engine.

| Previous implementation | Disposition |
| --- | --- |
| Simplex `retained_*` registry helpers and private registry record | Relocated once into `quod_dtx_owner`; old definitions deleted |
| `pending_origin_begins` and `committed_origin_recoveries` | One desired-obligation function in that library |
| `reclassify_retained_rows` / `reclassify_retained_row` | One classifier returning the updated registry and removed rows before effects |
| `refresh_dtx_submission` and bulk `abandon_retained_dtx` | Deleted; anchored ownership and execution readiness are separate inputs to one signature policy |
| Actor/history `dtx_pending`, seed, reducer and reconciliation helpers | Deleted, not moved or kept as padding; the signing journal is the sole durable pending-Begin authority |
| `trace_shared_work` / `trace_block_attributes` | Relocated into `quod_consensus_trace`; existing actor adapters only select exact slot/hash ancestry |
| Appending consensus boundary events to ended proof spans | Replaced by short boundary spans using the same ancestry, links and sampler |

A temporary sync or KB pause preserves the exact signed envelope, body,
waiters and exposed floor. It does not renew a consumed sequence. The existing
readiness transition classifies then renews the same retained row before its
next drive. Actual admission/membership loss still retires it. Classification
precedes renewal, and commit, skip and catch-up retain their existing
post-application resolution boundary. No new readiness flag, message, queue,
retry timer, polling loop, process or alternative execution path is added.

Admission is monotone across active-row retirement: `quod_dtx_owner:admission`
consults one current indexed group history before applying that same active
readiness rule. An exact previously certified phase returns its reference
through the ordinary submit-result channel, with no signature, retained row
or proposal. A different digest for an already-included phase is not accepted.
Local endpoint requests, remote endpoint requests and relayed signed controls
all enter this same rule. The same-turn installation assertion uses the active
placement rule without repeating the admission's history lookup. Live commits
still attach the available entry as a validation sidecar; historical inclusion
returns its reference without fetching an entry merely to forward it. The
consumer must verify the reference through A's existing resolver. Wire grammar,
cryptographic checks, observation authority and deadlines are unchanged.

Journal reconciliation reads the current pending rows and one indexed group
history per surviving admission. Work is bounded by pending groups and their
fixed phase family, not ledger-prefix length. Inclusion remains provable after
Complete removes an active group. Captured committed projections contain no
local pending custody and therefore cannot overwrite requests admitted later.
The public Prolog pending view remains derived from the journal; it does not
authorize or own execution. No proof/Prolog database state is copied to another
node. Proof, backtracking, cut, signing and caller-deadline rules are unchanged.

### Process and messaging inventory delta

Both new modules are libraries with **zero processes**. The existing Simplex
process still owns the journal and mutable local index. The existing
coordinator owns its asynchronous wave, and existing foreign-validation
workers perform their same bounded verification. Existing `quod_reg`/gproc
routes, monitors, cancellation, Prolog apply channel and readiness/progress
notifications are unchanged. The validation closure receives a small trace
location, not a copy of the actor state. No new service or wake-up path exists.

### Explicit derived-cache format break

Removing `dtx_pending` changes the committed projection stored in foreign-cache
checkpoints. The foreign-cache identity/manifest/checkpoint version moves from
3 to 4 together. V3 is refused as `unsupported_foreign_cache_format, 3` at
owner startup, without mutation, corruption accounting, a legacy decoder or
automatic request-time refetch. Compact/resident/captured projections have
9/10/11 fields, respectively. There is no obsolete-field compatibility padding.

This is **not** a deployable image-only preserved-cache swap. A future deployment
must explicitly retire the old derived foreign-cache directories, retain their
evidence if needed, and record that the new cache starts cold. Source ontology
ledgers, transaction encoding, signing journals and identities do not change
format in this scope and do not require wiping. No cache reset is performed by
this candidate. The format test constructs the actual .172 manifest and
checkpoint encoding around a real empty ledger store; it is a format-admission
fixture, not a claimed certified-history replay witness.

### Timing evidence and acceptance boundary

An ended proof span is still valid ancestry, but the SDK cannot append later
events to it. `quod_consensus_trace` distinguishes enclosed work spans from
short `quod.consensus.observation = boundary` spans. Only the latter's **start
timestamp** denotes the observed boundary; its tiny duration is not a consensus
round or mailbox-wait measurement. Exact slot/hash binding, trace parents,
shared links and sampling remain intact. Missing ancestry produces no invented
root. SDK errors in a boundary observation cannot change the protocol result.

The retained .172 witness does not establish that the entire slow interval was
mailbox waiting, and this correctness refactor claims no measured speedup.
Future testing must use a fresh label, the existing shape and deadlines,
independent request/attempt denominators, full logs and true exits, and stop
on the first failure. Use the reviewed full-sampling configuration window and
restore its exact previous value; never clear STOP/BENCH_STOP or resubmit an
uncertain operation. Compare submitter latency, coordinator work, exact consensus
boundaries and application, keeping unknown gaps unknown. O-A1/O-A2 apply:
excluded/dropped/tied evidence stays counted and listed, never removed from
the denominator. Account separately for the explicitly cold derived cache.

Local real-journal, certified-window, SDK and fail-before controls accompany
this candidate. Exact-tree review and clean sequential gates remain the
publication boundary. R-RESTART-RACE-01, both standing EUnit ledger items,
c4, +8.7%, L2 slice 8, F6 restart checkpoints and action savepoints remain open.
The fixture-only explorer trace-correlation correction is identified separately
in the handoff; unrelated spans must not inflate one request's read count.
The QUIC and N=4/join/growth/feed app fixtures also isolate their foreign caches
under CT's private directory, as they already isolate effect journals. The ask
fixture already did so; the app-start inventory is now covered. This prevents test
startup from inheriting a developer's old cache format; no old cache is deleted
or migrated to make the gate pass. All original protocol assertions remain.
The join-action fixture also registers its actual root bootstrap configuration
before invoking lifecycle creation; starting a Prolog process alone is not
that configuration. The missing-configuration failure reproduces against
unchanged .172 production code, and the corrected fixture passes against it.
The growth fixture constructs its deliberately invalid membership proposal as
a canonical block artifact, not a raw record view rejected by the wire encoder
before reaching any validator. No membership-rejection assertion is weakened.

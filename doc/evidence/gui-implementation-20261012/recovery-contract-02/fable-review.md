# Fable review: exact completion intent and certified expiry (recovery-contract-02)

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-13. Consultative only.
Basis: `candidate.md`, `integration-review-01/assessment.md`, the frozen
`tree/` (AGENTS.md identical to the component packet), and one live
read-only range, `quod_proof_context.erl:300-316` (vote deadline derivation).
No command, build or test was run. Nothing here approves a runtime change.

## 1. Verdict

**Part one holds.** Retaining the exact unsigned completion request bytes in
the accepted-answer transaction removes the recursive custody-store operation
and, more importantly, makes every later dispatch of those bytes the *same*
operation: a second signing of identical bytes is refused by the validators
as `duplicate_operation`, so lost replies and duplicate wakes are safe
without any quiet period. Two consequences must be written into the contract:
the retained bytes bind the signing key, so a key rotation strands the
request until its expiry; and a proof-level failure of `gui_complete/1`
leaves no durable trace, so re-dispatch is bounded only by pass semantics
until the expiry theorem retires the request.

**Part two holds for every lane I could trace**, with the preconditions the
candidate states. I found no admission lane that can install a positive
source claim for a request with expiry E in a certified block whose time is
greater than E. The one real gap is evidentiary, not logical: validators must
be able to check E without trusting the caller, and the existing diff already
carries what they need. Section 4 names it.

## 2. Verified lane facts

L1. **Ordinary content.** A signed `application` transaction is validated at
the block timestamp through `validate_request/4` and
`validate_context/5`, which refuses `Timestamp > NotAfter`
(`tree/src/quod_transaction.erl:538-547`, `tree/src/quod_client_goal.erl:525-541`).
The same apply pass installs the operation claim at that slot
(`tree/src/quod_commit_validation.erl:371-400`), refusing a second claim with
the same key and digest as `duplicate_operation` and a different digest as
`operation_conflict`. An unsigned application transaction carries no claim
and no expiry (`quod_transaction.erl:529-536`); see N4.

L2. **Independent dispatch.** The source claim is a `remote_claim`
transaction validated through the same evidence check at block time
(`quod_transaction.erl:548-558`), and its claim is installed at the source
slot.

L3. **Atomic.** The manifest vote deadline is bound once from the proof
budget and capped by the signed request's expiry (`quod_proof_context.erl:308-316`;
`tree/src/quod_atomic.erl:148-158` requires `Deadline =< Expiry`). A
*prepared* source vote at block time greater than the deadline is refused
(`quod_atomic.erl:437`, `quod_commit_validation.erl:596-600`), and a
positive vote installs the claim at its slot (`quod_commit_validation.erl:671-679`).
After the deadline only negative votes are eligible, including from a
journaled positive vote resumed after restart, because resumption re-enters
the same admission check.

L4. **Time.** Material blocks have non-decreasing timestamps along a
history; empty recovery carriers inherit their parent's time and produce no
apply (`tree/src/quod_simplex.erl:817-828, 12266-12270`, `ts_acceptable/3`).
The future-skew bound is a local sanity limit and does not matter for the
theorem, which compares certified block times only.

L5. **Index.** Claims are staged with their block and flushed together;
public visibility advances only on flush (`tree/src/quod_outcome.erl:2-37,
669-690`). Rows surviving a reopen may name a `first_slot` beyond the replay
parent (`quod_commit_validation.erl:617-622`), and the positive dependency
read already refuses anything above the applied floor
(`quod_outcome.erl:76-96`).

L6. **Request bytes.** The canonical wire binds network, signing key,
operation id, actor identity, mode, parser, expiry and goal text
(`quod_client_goal.erl:307-320`); the digest in evidence and in the index is
the digest of these bytes, which are the unsigned bytes. An observer holding
them can therefore compute the same digest without the signature.

## 3. Part one: retained exact completion request

### 3.1 What works

- Construction is pure: every field is committed or authenticated at
  submission time, and `quod_client_goal:encode/1` is a pure codec. It needs
  one common primitive bridge so a Prolog transaction can produce and
  round-trip the bytes; that primitive stays sealable because it reads no
  node state.
- Live dispatch through governed signing keeps authority where it is:
  `can_sign_agent_request/3` is evaluated against the typed request decoded
  from the bytes, so policy can insist the goal is `gui_complete(Q)` and the
  actor is the row's actor. The human who wrote the row never chose its
  bytes; the shared rule did.
- Duplicate live events and lost replies collapse: two signings of the same
  bytes are the same operation (L1), so a reaction and a work pass racing,
  or an agent re-dispatching after its reply was lost, cannot double-commit.
  This is stronger than the FIPA policy and is the right basis.

### 3.2 Required (part one)

R1. **Key binding.** The bytes bind `signing_public_key`. After a host or
key change the vault cannot sign them and `can_sign_agent_request/3`
refuses. State that a rotated key strands the completion until E and that
the authored allowance must be short enough to make that acceptable. Do not
"fix" it by re-signing under the new key: that is a different digest with
the same id, which is exactly the fresh attempt the contract forbids until
the theorem has retired the original.

R2. **Exact-bytes agent mode.** `quod_agent:start_request/5` mints the id
and `sign_request/4` rebuilds the request from a goal and budget
(`tree/src/quod_agent.erl:95-131, 233-261`). A new work shape must carry the
bytes, decode them, refuse if actor, namespace, anchor or key differ from the
binding, build `Typed` from the decoded request, and report
`{outcome_unknown, OperationRef}` with the reference *from the bytes*. The
reaction preparation needs a variant beside `custody` and `signed_store`
whose bridge reads the committed row and checks the goal before handing the
bytes over. Without this the runtime would regenerate id and deadline.

R3. **Proof failure is transient.** If `gui_complete/1` fails as a proof
(schema changed, continuation refused), nothing durable records it and the
next pass may dispatch the same bytes again. That is safe (R2 makes it the
same operation) and bounded by pass semantics, but the plan must say so and
must not describe it as a retry promise. The only durable exit before E is a
committed outcome; after E it is the theorem.

R4. **Observation bridge.** `committed_operation_outcome/3` requires bytes
and signature. The signature-free read must decode the unsigned bytes,
derive key and digest, use the existing `operation_dependency` path for
positive evidence, keep the live-bridge marker on unavailability, and never
return a refusal for absence. It is a read under the containing ontology's
ACL; the bytes grant nothing. Replace the signed variant rather than adding
a second API, as the candidate says.

## 4. Part two: certified expiry theorem

### 4.1 Lanes challenged

For a request with expiry E and a certified, contiguous, fully applied
source prefix ending at H with block time T > E:

- Ordinary content and independent source claims need block time ≤ E at
  admission and claim at that slot (L1, L2); by monotonicity (L4) every such
  slot is ≤ H and its claim is visible once applied and flushed (L5).
- Atomic positive source votes need block time ≤ deadline ≤ E (L3) and claim
  at that slot; Resolve and Complete after E keep the earlier claim.
- A journaled positive vote resumed after restart is re-admitted through the
  same check and refused after the deadline (L3); duty presentations and
  remote prepared roles produce refusals or aborts, never a positive source
  vote.
- Finality: the prefix must be certified by a descendant commit certificate,
  not merely notarized; `history_view_at/3` is the accessor.

I found no counterexample. Two near-misses are worth recording:

- **Retained future rows.** An index row with `first_slot > H` that names
  this key contradicts T > E under L4; it must be treated as an index error,
  not as absence and not as presence.
- **Unsigned completion.** A trusted in-VM `execute/2` can run
  `gui_complete(Q)` without a claim (L1, N4). The theorem then classifies the
  retained request as expired while the question is already consumed. That
  is correct about the request and harmless for the question; the retirement
  transition finds no row.

### 4.2 Required (part two)

R5. **Evidence the validator can check.** The candidate is right that a
caller-supplied expiry and digest are insufficient, and right that carrying
the bytes is needed. The bytes do not need a new carrier: the retirement
transaction retracts the row that holds them, and a retract operation in the
diff carries the full fact. Validators of the origin namespace therefore
already receive the exact bytes in material they validate. Specify the
token as `{Agent, OperationId, Digest, H, T}` bound to that retract, and the
validator rule as: decode the retracted bytes, check agent, id, digest and
expiry E < T; check the index has no claim for the key with `first_slot ≤ H`
and treat `first_slot > H` as error; check the certified block at H has time
T; check H ≤ the committed parent through `at_height`. This needs a new
read-set kind in `quod_read_set` (today only positive terminal tokens with
`Claim > 0` validate), a negative lookup in `quod_outcome` bounded by the
applied floor, and the check in content, atomic and read-only validation.

R6. **Snapshot readiness.** `ready = false` and `outside_snapshot` must stay
unavailable, never absence; replay must rebuild the same negative evidence
from the same reducer; the applied floor, not the latest applied height, is
the boundary.

R7. **No time advancement.** If the certified source time at the applied
floor is not greater than E, the answer is unknown. No proposal is made to
move time; the candidate already says this and it must stay.

## 5. Failure recovery and lifecycle

Committed completion consumes the row as now. The pending inventory is the
`submitted` rows themselves; selection reads them through the existing work
owner; observation reads the index; no second queue. Before E a pass may
re-dispatch the exact bytes; after E it may only observe, and once R5
evidence certifies absence the authenticated human may retire or replace the
interaction in one ordinary atomic transaction, which also answers the open
R1 of the question review. No actor cancellation, no fresh id while unknown.

Repeated unchanged observation must not replay history: the index read is
retained owner state, but the certified block time at H comes from Simplex
history and must be served from retained projection state, not a ledger
read. That is a condition to verify when implementing R5.

## 6. Optional

- Keep the authored completion allowance small; it bounds both the
  key-rotation strand (R1) and the time a human waits before retirement.
- A test that signs the same retained bytes twice and asserts one commit and
  one `duplicate_operation` would pin the property everything else rests on.

## 7. Unverified

Era transitions preserving timestamp monotonicity across the virtual root;
`register_dormant_transaction/4` role rules (not needed by this candidate);
whether `history_view_at/3` is served from retained state; the exact
allowance policy ownership in the application versus responder ontology.

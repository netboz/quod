# Exact outcome dependencies for the door transition

Repair validated by Claude Fable and implemented following the review. Yan authorized validating
this solution with Claude and then implementing it. No new store, process,
executor, polling loop, history scan or sealing exemption is proposed.

## Contract

A proof may rely on an already-published terminal outcome of an exact signed
operation in its current ontology. The query must capture that dependency in
the existing monotonic read set. The signed plan and transaction carry it, and
the existing validator and committed-apply paths check it against the retained
outcome index owned by the committed projection. There is no live native read.

This is deliberately a terminal-evidence query, not a general test for absence.
Pending, missing, not-yet-in-the-pinned-view, deadline and storage errors raise
typed unavailable errors. Negation propagates their error. A swallowed error retains the existing live
bridge marker and cannot authorize a diff. A known
terminal status can fail ordinary unification, but its dependency is retained
even on failed alternatives, cuts and rollback. A committed result therefore
cannot be mistaken for rejection.

## Representation and owners

1. Extend the existing `quod_read_set` key/token alphabet with a distinct key
   `{1, AgentRefBytes, OperationId}` and an atom-free token carrying
   original request digest, exact outcome reference, claim height,
   terminal status/height and publication height. Target namespace and anchor
   come from the enclosing scope/plan and must match the outcome reference.
   Preserve all existing predicate-only canonical bytes. Count these entries
   under the existing plan/read-material allowances; do not add a fixed cap.
2. Add a bounded read to `quod_outcome`, reused both by the owner query and by
   validation. It resolves the operation claim and terminal result through the
   existing index, never ledger prefixes. It exposes only immutable fields.
   For group results, publication height must include Complete's slot, not
   merely the earlier Resolve/application slot. The proof's pinned height and
   published floor must both include all evidence. No negative historical view
   has to be reconstructed.
3. Add the corresponding `quod_prolog` owner request with the caller's remaining
   deadline. The owner returns the frozen dependency value, not an assertion
   supplied by the actor. Outcome indexes remain under their current owner;
   proof workers receive only bounded values. Read errors remain distinct from
   definite validation mismatch.
4. Introduce a governed generic `committed_operation_outcome(Bytes, Sig, Status)`
   bridge. It verifies the signed operation, current scope identity and pinned
   context; records the dependency in `quod_erlog_db_local_prove` before any
   status/digest unification; and returns its terminal status. It is callable
   from an ordinary proof, not an in-owner membership verdict or policy verdict.
   This prevents self-calls into a blocked owner. The physics-specific Erlang
   rejection reader is removed. The rejection rule becomes ordinary Prolog over
   this generic query.
5. The existing read-set table retains outcome dependencies monotonically and
   carries them through authorization absorption and plan extraction. Sealing
   verifies that every evidence height is at or below the plan's base height. The existing
   `committed_snapshot` contract is extended to describe both tracked MVCC facts
   and tracked immutable outcome evidence; there is no predicate-name exemption
   and no change to the veto against untracked live queries.
6. Extend the common read validation used by `quod_commit_validation` and
   `quod_committed_projection` to check both kinds. Validators compare the exact
   recorded value against their own retained index and current published floor.
   Missing readiness/index errors must abstain or stop apply, never be converted
   into a certified rejection. Forged/mismatching dependencies fail validation.
   The existing fact-only `quod_diff:validate/2` must reject outcome reads when
   no outcome context was supplied. Callers must be audited for this new kind.
7. Terminal evidence never changes, so it contributes no mutable predicate lock
   to atomic conflict descriptors. It remains signed, counted and validated in
   the read set, including read-only plans and foreign-read certification. Wire
   shape validation must distinguish it before materializing vocabulary. Old
   nodes reject the new dependency kind; no deployment or data migration is
   authorized by this change.

## Door integration and remaining review findings

Keep the existing original-operation resolution and server-checked replacement
rule. A proof-time refusal that never entered ordering remains unknown; explicit
authorized cancellation is its escape. Do not resubmit the original request.
Cover the store/finish/edit interleaving and state this limitation explicitly.

Finish checking status retention and resolution readiness: per-door uncertainty
must remain inspectable after sleeping or another door's progress. Recovery must
use existing scoped owner notifications or an explicit reconciliation edge;
no periodic retry is introduced. Certainly-unsent samples may resample, but
unknown custody writes must remain fenced until selection/outcome/cancellation.

## Verification

- Golden-byte and malformed/duplicate-key read-set controls, signed plan and
  transaction round trips, forged digest/ref/status/height refusals.
- Proof capture through failure, negation, backtracking, policy absorption and
  sealing; unavailable evidence never becomes a logical success under negation.
- Real owner reads with an old pinned height, pending operation, wrong identity,
  published terminal rejection and committed result. Repeated unchanged reads
  perform no ledger replay, rebuild, file write or sync.
- Shared validator/apply, read-only plan and multiwriter coverage; group outcomes
  cannot become visible before Complete publication. Infrastructure failure is
  not a vote to reject the original operation.
- Restore the competing-edit acceptance test, add the uncovered production
  interleavings and preserve prior negative controls. Complete native checks,
  focused physics/actor/outcome tests and clean sequential full gates. Preserve
  the two existing names-test timeouts and investigate rather than loosen them.

## Review decisions applied

The [Fable validation](outcome-dependency-review-fable.md) found this implementable
with shared extraction, codec, descriptor and error propagation changes. The
parent verified these against the pinned dependency taxonomy. The token omits
capture height: immutable evidence is a pure function of committed history;
sealing and validation independently enforce their enclosing base/parent.

The recommendation to classify every thrown custody proof error as certainly
unsent is not applied. The public result normalizer collapses several causes
into `proof_unavailable`, so that result alone cannot prove no custody write.
The existing uncertain classification remains visible and fenced. An exact
outcome edge or explicit reconciliation can resolve retained custody; explicit
cancellation handles an original request that never entered ordering. No
original operation is resubmitted and no deadline is extended.

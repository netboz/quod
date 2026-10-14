# Fable review: reuse of the latest unmaterialized distributed batch (savepoint-review-01)

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-13. Consultative only.
Basis: `candidate.md`, the frozen `tree/` (AGENTS.md identical to the
component packet), and, read live and read-only for the call sites the owners
depend on, `quod_ask.erl:794-870` and `quod_proof_session.erl:496-530`.
No command, build or test was run. No cap change or transaction split is
proposed.

## 1. Verdict

I could not construct a counterexample. The reuse is sound, but not for the
reason the candidate states. The candidate's premise, "while a batch has no
materialized foreign scope, no foreign state has been touched between the
two choice points", is false in one reachable case, yet the reuse remains
correct because correctness rests on a different, stronger-by-construction
invariant of the existing lazy materialization. Section 3 states that
invariant and the proof sketch; section 4 lists the cases the tests must pin
so a later change to materialization cannot silently break the reuse.

## 2. Verified owner facts

S1. **Allocation per choice point.** Once a savepoint has activated a
lineage, every erlog choice point's checkpoint calls
`quod_transaction_scope:checkpoint_token/0`, which requests `allocate` for
the current lineage (`tree/src/quod_erlog_db_local_prove.erl:699-712`,
`tree/src/quod_transaction_scope.erl:244-261`). `allocate_batch/3` mints a
fresh id, records the lineage's transaction ids as owners and the actor's
scope as `local_owner`, and counts against the 1024 batch cap
(`tree/src/quod_proof_context.erl:951-973`). The savepoint entry checkpoint
itself is taken the same way after `enter/1` (`tree/src/quod_proof_savepoint.erl:46-49`).
That is the demonstrated gap: a long local search after the first foreign
call allocates one batch per choice point.

S2. **Materialization is lazy and gated.** Every path that runs a target
invocation first calls `quod_proof_context:materialize/2` with the actor's
current selection: at open (`quod_ask.erl:755-762`), before every answer pull
of the target (`:828, :847`), and again for the owner's own selection when
control returns (`:861`). The selection is the live choice-point tokens plus
base and entry batches (`quod_transaction_scope.erl:100-122`). Materialize
checkpoints, on each scope not yet holding the batch and not its local owner,
that scope's *current* revision under the batch id
(`quod_proof_context.erl:832-889`; `quod_proof_session.erl:505-528`, new ids
only). So a batch's captured revision on a scope is the scope's state at the
first invocation after the batch entered a live selection, not at allocation.

S3. **Restore and release.** Backtracking restores the local snapshot and
asks the origin to restore the batch on every scope where it is materialized
(`quod_erlog_db_local_prove.erl:714-725`,
`quod_transaction_scope.erl:265-297`, `quod_proof_context.erl:975-1005`). A
batch with an empty `materialized` map restores nothing foreign. Batches are
released only when the last owning transaction finishes
(`:1017-1074`), and a committed savepoint has already cut its inner choice
points (`quod_proof_savepoint.erl:59-63`), so no live choice point can hold
a released batch.

S4. **Local state is per choice point regardless.** Facts, events, effects,
prepared effects, provenance and transient are copied into each local
`#checkpoint` (`quod_erlog_db_local_prove.erl:104-113`), so sharing a
distributed batch changes nothing about local rollback, including effect
rollback inside action candidates.

S5. **Nested savepoints before activation.** `enter/1` pushes a pending
frame without allocation; choice points inside it still allocate under the
parent lineage until the first foreign call activates the frame, which mints
a separate baseline batch outside `allocate_batch/3`
(`quod_transaction_scope.erl:124-146, 148-183`;
`quod_proof_context.erl:904-937`). Rollback of the nested frame relies on
that baseline through the pending marker, not on the entry's allocated batch.

## 3. Why the reuse is correct, and the premise correction

**Counterexample to the premise.** Actor A pushes CP1 (allocates B). A cut
pops CP1. A invokes scope S; B is no longer in the selection, so S changes
without B being materialized. A pushes CP2. B exists, same actor, same
lineage, `materialized` empty, so the candidate reuses it. Foreign state did
change between CP1 and CP2. The premise is false here. The reuse is still
correct: CP1 is gone, and for CP2 the captured revision of B will be S's
state at the next invocation, which equals S's state at CP2 because no
invocation happens in between (S2).

**The invariant that actually holds.** For every live choice point C holding
token B, the revision captured for B on any scope equals that scope's state
at C's push. Proof sketch: while C is live, B is in every selection A
materializes, so the first invocation after C materializes B before touching
any scope (S2). Reuse is granted only while B is unmaterialized, so a new
C' sharing B is pushed before any foreign change since the older live
holders' pushes; if a foreign change had occurred while an older holder was
live, B would already be materialized and reuse refused. Nested invocations
inherit the owner's selection as base batches, so target-side actors and
their nested asks also materialize B before changing any scope. The
requirement "same actor and same lineage" is what keeps `local_owner` and
owners consistent (S1); same lineage implies the same owner set because a
lineage's transaction list is fixed at activation.

**Reentrant and returning cases.** A self-ask on the actor's own ontology
runs as a local `call/1` without a scope and cannot change foreign state. A
call into an already open scope goes through open or next, both gated by
materialize. Return from a target to its owner re-materializes the owner's
selection (`quod_ask.erl:861`), so a batch reused by the owner after return
behaves as in the premise counterexample above: correct. A batch allocated by
a target worker has `local_owner` equal to that scope, is never materialized
on itself, and is restored only on the scopes it was materialized on
(`batches_restorable/4`); the owner's advance skips it for the same reason.

**Restore then reuse.** After backtracking to CP1, the pointer may name a
batch allocated at a later, now popped choice point. If that batch is still
unmaterialized, reuse is correct by the invariant; if it was materialized,
reuse is refused. Either way no live holder is affected.

**Caps.** Batch count becomes roughly the number of foreign invocations
inside the lineage plus one, instead of the number of choice points. All
existing limits, owners and release paths are unchanged.

## 4. Conditions and tests the implementation must pin

1. Reuse only when the batch exists, `materialized` is empty, actor and
   lineage match exactly, and the allocation request itself is authorized as
   today. Replace the pointer on any other allocation, on activation (new
   lineage) and implicitly on finish (lineage changes). Never update the
   pointer from a target-side request with a different actor without
   replacing it.
2. Test the premise counterexample: cut CP1, foreign change, CP2 reuses,
   foreign change, backtrack to CP2 restores exactly the state at CP2.
3. Test two live holders: CP1 and CP2 share B, foreign change, backtrack to
   CP2 then to CP1; both restore the same captured revision; then a new
   choice point after further foreign change allocates a fresh batch.
4. Test the nested-savepoint entry sharing a batch with parent choice points
   before activation, and rollback of the nested frame through its baseline.
5. Test a target worker's own choice points sharing a batch while the owner
   advances it, and restore reaching only the scopes it was materialized on.
6. Test restore followed by reuse of a popped choice point's batch.
7. Test that the four-field form validation now stays far below the cap and
   that batch count equals foreign invocations plus one for that proof.
8. Keep an assertion that a reused batch is never referenced by a released
   or finished lineage; the "missing batch fails reuse" rule covers it, so
   the test is for the pointer, not the rule.

## 5. Note on direction, not a request

The reuse is a correct constant-size fix inside the existing owner. The
underlying cause is allocation at choice-point time while materialization is
at invocation time; allocating only when a selection is first materialized
would remove the pointer entirely. That is a larger change to the same owner
and is not needed for this gap.

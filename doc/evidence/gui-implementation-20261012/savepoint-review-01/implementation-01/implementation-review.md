# Fable implementation review: unmaterialized batch reuse (savepoint-review-01/implementation-01)

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-13. Consultative only.
Basis: `implementation-01/tree` (AGENTS.md identical to the original packet)
diffed against `savepoint-review-01/tree/src/quod_proof_context.erl`, the
four test files in the packet, and the accepted candidate review. No command,
build or test was run; the parent's 75-test run and the broad gate are not
claimed here.

## 1. Verdict

The production change implements exactly the accepted shape and nothing
else. I found no defect. The rollback tests cover every condition from the
candidate review's section 4, including the premise counterexample, with one
assertion that is weaker than it could be and is noted below as optional.

## 2. Production change, verified

- **One pointer.** `#ctx.last_batch :: none | {actor(), opaque_id(), opaque_id()}`
  holding `{Actor, Lineage, BatchId}`; no other state added.
- **Authority before lookup.** `allocate_batch/3` first requires
  `Lineage =/= none` and `invocation_authorized/3`, then consults
  `reusable_batch/3`, then `allocate_new_batch/3`. The error classes and
  their order are the same as before for an unauthorized or unlineaged
  request.
- **Exact actor and lineage, extant empty batch.** `reusable_batch/3`
  pattern-matches the pointer on the bound `Actor` and `Lineage`, looks the
  id up in the live `batches` map and accepts only an empty `materialized`
  map. `local_owner` and owners are consistent by construction because the
  pointer is written only by `allocate_new_batch/3` for that actor and
  lineage, and a lineage's owner set is fixed at activation.
- **Cleared on activation and finish.** `activate_transactions_validated/5`
  and the success path of `finish_transaction/4` set `last_batch = none`.
  Both clears are redundant with the lineage in the key, since activation
  always produces a new lineage and finish returns to a different one, but
  they are harmless and make the intent explicit. Materialize and restore do
  not touch the pointer; the live `materialized` check is what retires a
  reused id, which matches the corrected live-holder invariant.
- **Limits and wire unchanged.** The 1024 cap is checked only when a new
  batch is minted; reuse consumes nothing. No scope-wire, selection shape,
  authorization or release path changed. The comment in `reusable_batch/3`
  states the corrected invariant, not the original premise.

## 3. Tests against the review's section 4

| Condition | Where covered |
| --- | --- |
| 1 exact actor/lineage, pointer replacement | `unmaterialized_batches_reuse_only_exact_actor_and_lineage_test`: same actor reuses `First` 3072 times; unregistered actor refused before lookup; registered reentrant actor and child lineage get distinct batches; finished lineage refused |
| 2 premise counterexample (cut-away holder, foreign change, reuse) | same test: materialize with an empty selection, foreign write retained, `First` reused, later write removed on restore |
| 3 two live holders, nested entry, cut, fresh batch after foreign change | `tx_shared_batch` via `t_shared_batch_nested_rollback`; unit test `Second`/`Third` after materialization |
| 4 nested-savepoint entry sharing before activation and baseline rollback | `tx_shared_batch` inner `transaction/1`; unit test child lineage and finish |
| 5 target-side worker sharing while the owner advances | `tx_many_local` runs in `chain_b` as a target scope with 1200 local alternatives around a `chain_c` rollback; CT `remote_signed_transaction_savepoints` does the same with signed remote scopes |
| 6 restore then reuse | implicit in the second 1200-alternative burst after the failed alternative in both `tx_many_local` and the CT case |
| 7 cap no longer reached | CT 1200 + 1200 alternatives; GUI validation inside `transaction/1` with a rolled-back preceding write and unchanged repeated no-I/O reads |
| 8 no reuse of a released batch | unit test: `allocate` after `finish` is `not_allowed` |

The GUI addition is the right production seam: validation runs inside the
same `transaction/1` shape the submission will use, a rejected field set
rolls back `invalid_form_write`, and the repeated read-only bind stays under
the existing no-I/O trace.

## 4. Optional

- In the unit test, add `?assertNotEqual(Third, ParentBatch)` next to
  `?assertNotEqual(ChildBatch, ParentBatch)`. It passes with or without the
  pointer clears, so it documents rather than enforces, but it names the
  parent-lineage expectation directly.
- Origin-actor sharing is exercised only through the unit harness; every
  Prolog-level case shares on a target scope. The mechanism is actor-agnostic
  by construction, so this is a note, not a gap.

## 5. Correction, 2026-10-13, after the parent's gate evidence

The frozen `test/quod_ask_SUITE.erl` Fallback goal in
`remote_signed_transaction_savepoints/1` is syntactically unbalanced: the
generated Prolog has 15 opening and 14 closing parentheses (counted over the
string segments of lines 385-389), so ingress rejects it as `invalid_goal`
before any proof runs. My section 3 row for condition 5 cited this CT case as
coverage; as frozen, it covered nothing, and I missed the defect. The parent's
one-character suffix fix (`(3))))).` to `(3)))))).`) balances it; production
is unchanged and the frozen tree keeps the failing original. The CT row in
section 3 stands only for the corrected case, whose result is the parent's to
report. The unit test and `tx_many_local` coverage cited in the same row are
unaffected.

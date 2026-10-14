# Reuse before foreign checkpoint materialization

A real signed GUI submission, whose form has four fields, failed validation
with savepoint_limit_exceeded(1024). The submitted field set was deliberately
incomplete. The test should produce ordinary failure without any committed
change. The retained diagnostic observes only two transaction entries, not
recursive transaction nesting. No limit was raised and no transaction split.

Existing allocate_batch/3 in quod_proof_context allocates on every local choice
point once a transaction activates. Local snapshots already retain each local
overlay separately. A distributed batch is lazily materialized into foreign
scopes by materialize/2 before they run. While a batch has no materialized foreign
scope, successive choice points in the SAME actor and SAME lineage can share
that foreign checkpoint: no foreign state has been touched between them. Local
writes still have distinct local checkpoint values.

Proposed implementation, not yet applied:
- One optional last_batch = {Actor, Lineage, BatchId} pointer in the existing
  proof context. No new owner, registry or domain state.
- allocate_batch still validates invocation authority and active lineage first.
  Reuse the pointer only when Actor and Lineage match, the batch still exists,
  and its materialized map is empty. No cache scan or per-operation history read.
- Otherwise use the existing allocation and limits; update the pointer. Once
  any foreign scope materializes that batch, it cannot be reused this way.
- A missing/retired batch fails the reuse check and allocates normally. The
  pointer is constant-size and dies with the proof. Nested actors conservatively
  replace it, so this is not a second lifetime inventory.
- Restore and finish continue to use the existing batches and exact scope
  checkpoint tokens. No token, wire shape, authorization or budget changes.

Please check the reentrant-scope, restore, transaction-lineage and effect rollback
cases against the frozen owner code before implementation. Specifically, does
empty materialized prove absence of foreign state changes at every point where
this same actor may allocate a new local CP, including returning from a call to
its own already-open ontology? Identify a counterexample if not. No code edits,
commands or tests. Write fable-review.md here. This is the requested plan/code
review boundary for a demonstrated gap in the existing transaction owner.

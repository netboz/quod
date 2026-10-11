Reading done. I've traced the delta against the owner modules in the tree; now writing the review.

**Verdict for this scope.** The four corrections are adequate for inactive existing-editor authoring in a never-physical ontology. No code-level blocking issue in the delta. Nothing here claims or authorizes activation, key provision, deployment or collision acceptance, and the revised two-module run is still pending, so I do not certify its outcome.

**Cold absence guard and conflict read capture**

- The gap is real and the fix targets the right seam. `quod_common_primitives.erl:142-147` answers an opaque `'$quod_symbol'` indicator with an empty baseline and never touches the overlay, so no read is recorded. The materializer does not descend into argument positions, so a cold indicator inside `'$quod_predicate_source'` stays opaque in production too. Log 02 confirms `reads=[]`.
- The negated callable guards are walked by production admission. `quod_ask.erl:1477` runs `materialize_goal_symbols` on every target goal, and `quod_wire_term.erl:490-498` descends through `','`, `transaction/1` and `'\\+'`, so a cold functor in the guard becomes an atom under the normal budget. Execution then reaches `raw_get_procedure`, whose `undefined` branch records the read at `quod_erlog_db_local_prove.erl:844-846`.
- The unit test at `quod_common_primitives_tests.erl:147-157` exercises exactly that path on a random cold name and asserts the functor key and no local changes. It also shows erlog fails rather than errors on the unknown procedure, so the guard is safe inside the transaction.
- For warm names the source primitive already records the read through `authored_state` and `raw_get_procedure` (`:61` proves `{missing,1}` is captured). The integration test uses warm atoms, so the cold path is covered only by the unit test. Given the shared materializer, that is sufficient.

**Full-program restart.** `quod_lobby_tests.erl:152-159` stops the resumed node after all entry points are published, boots again from the same data directory, and compares height, complete source and the inactive checks, then re-traces for zero I/O. The second `stop_process(Resumed)` in the outer `after` hits a dead pid; `monitor` returns `noproc` immediately, so it is harmless.

**Canonical readback and order.** `source_predicate_drafts` now mirrors the production path: `:-` normalization plus `term_instance(_, 0)` plus `format_clause`, matching `canonical_source` at `quod_common_primitives.erl:196-198`. The per-edit `?assertEqual(Draft, editor_source(...))` at `:124` reads clauses back in stored order, so the two `agent_hosting_suspended/1` clauses are order-checked.

**Precise rejections.** `{not_allowed, Ns}` is the exact reason `quod_proof_session.erl:190-193` emits on a denied scope, with `Ns` the target namespace. `{edit_conflict, Indicator}` matches the shape the existing test at `:1069` already decodes. Canonical comparison is the correct way to equate atom and opaque spellings. Minor: `assert_editor_refusal` compares `{ok, Bin}` tuples, so two encode errors would compare equal; harmless for these ground reasons.

**Unverified**

- Whether `quod_erlog_db_mvcc:version_token` for an absent functor differs from the token after a concurrent commit creates it. The module is not in the tree. The guard only pins the transaction if it does.
- Whether the other-principal request reaches scope admission at all, rather than failing earlier in the agent namespace with a different reason. The pending run decides this.
- Edit-conflict generation lives in the quod:prolog ontology, not in the tree.
- Cold followers, as stated in the disposition.

**Accepted as design.** Reusing the commit-time internal reconcile ordering, and qualifying the zero reaction counters as runtime-only evidence, both read correctly now.

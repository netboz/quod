**Verdict.** The offline per-predicate authoring procedure is now adequately tested as an inactive-definition publication in a never-physical ontology, with the caveats below. The full real-world activation remains BLOCKED: no activation goal, geometry, key preparation or live acceptance exists in this tree, and the initial-custody gap is real. Nothing here authorizes deployment.

**Code-specific findings (tests that can pass without proving their claim)**

1. **Restart happens before the entry points are published.** `test/quod_lobby_tests.erl:139-149` splits the remainder of the helper list; `agent_hosting_projection/4`, `physics_projection/2` and `react_on/2` are always in `Remaining`. The test never boots a node holding the complete inactive program, which is the exact state the real world will be in when a validator restarts. Move the split point after the last entry point, or add a second restart at the end.

2. **The live reaction assertion is vacuous.** Domain notices reach `dispatch_candidates` through `reaction_agents` (`src/quod_runtime.erl:353-358`), which returns no bindings when no agent is hosted. With `agent_host/4` empty the physics clauses are never evaluated live, so `reaction_failures := 0` proves nothing about this world. The synthetic matcher test (`:208-219`) does prove unmatched for a non-physics binding, which is the condition that matters once the authority is hosted. State that honestly; do not present the integration counter as evidence.

3. **Clause order is not read back.** The plan claims both `agent_hosting_suspended/1` clauses keep their original order. No `editor_source` equality follows a publish. One `?assertEqual(Draft-canonical, editor_source(...))` per edit closes this.

4. **Rejections are not reason-checked.** `:135-138` accept any `{failed, _}` for the other-principal and stale submissions, unlike `:1046-1048` which decodes `edit_conflict`. Mitigated because the identical goal commits in between, but decode the reasons.

5. **Resource-failure map semantics.** `resource_failures` is populated only for `{internal, Key}` runs (`:1112-1122`); the test's explicit `reconcile_resource` calls never write it. The assertion still works because the internal cursor queued at commit (`:1527`) is processed before the test's request, but the test is relying on that ordering silently.

6. **Cold symbol is single-VM.** The parser emits `'$quod_symbol'` tuples, so the atom is created by committee admission on the proposer. A follower receiving the block cold is not exercised. The plan admits this.

7. **Guard OCC semantics unverified.** The `'$quod_predicate_source'(physics_space/3, <<>>)` guards (`:161-164`) depend on `quod_common_primitives` recording a read on an undefined indicator. That module is not in the tree; I could not confirm the guard pins the transaction.

8. **The ordering guarantee lives only in test code.** `source_predicate_drafts` (`:166-186`) is the sole artefact encoding helpers-before-selectors. The real-world 169-edit publication has no driver or document to follow; a human reproducing it by hand in the browser is the procedure.

**Prior findings**

- Ordering: addressed, subject to item 8.
- Intermediate state: addressed except item 1.
- Cold symbols: measured and within the 512 and 16384 allowances; I verified both constants in `include/quod_vm_limits.hrl:12` and `include/quod_client_goal_limits.hrl:21`.
- Resource reporting: the named limits are correct. `QUOD_MAX_INVOCATIONS_PER_SCOPE` is 64 (`include/quod_proof_limits.hrl:14`), nested and top-level goal bytes are 128 KiB (`:19`, `:37`), plan envelope 128 KiB (`:27`). Two further allowances the activation goal will meet are unreported: `QUOD_CLIENT_GOAL_MAX_TOKENS` 2048 (`quod_client_goal_limits.hrl:11`) and `QUOD_MAX_PLAN_DIFF_OPS` 1024 (`quod_proof_limits.hrl:28`).
- Reactions: partially, see item 2.
- Uncertainty: the text is corrected. The test only exercises terminal outcomes via `await_operation_complete`. Acceptable as procedure.

**Initial key custody**

The gap is confirmed, and no existing governed route was missed:

- `quod_agent_vault:generate/1` has no caller in `src` (`src/quod_agent_vault.erl:37,123`). It writes epoch-0 custody straight to the key path, bypassing the prepare slot.
- `prepare_custody` (`src/quod_agent.erl:179-196`) authorizes through the `agent_custody` selection, whose goal requires an existing `agent_hosted/4` row at that epoch (`src/quod_runtime.erl:2817`). Circular for a first host.
- `prepare_agent_custody/3` requires recovery metadata (`src/predicates/quod_runtime_predicates.erl:164-178`), and the `prepare_agent_key/5` action requires an existing assignment (`priv/ontologies/agent_instance.pl:119`).
- `initialize_agent_host/3` takes an administrator-asserted public key (`agent_instance.pl:34-45`). Nothing proves the destination vault holds it. The recovery path is stronger: the node commits `agent_candidate_key` as its own principal.

The existing owner to extend is the `agent_custody` selection plus the `can_prepare_agent_key/4` and `prepare_agent_key/5` family. The `(none, 0)` prior-assignment form already exists in `initialize_agent_host`'s `can_assign_agent_host` call (`agent_instance.pl:36`). Whether to admit that form there, or to document `generate/1` as operator provisioning and retire the other path, is Yan's decision. Two implementations of custody creation should not both survive. The vault's signing ignores the custody epoch (`quod_agent_vault.erl:225-226`), so an epoch-0 file would sign for epoch-1 hosting; that is a fact to weigh, not a route to use.

**Boundary.** Tested: offline publication of inactive definitions in a non-physical ontology, resumable at an exact ledger, with zero resource failures and no repeat I/O. Not tested and still blocked: the atomic activation goal and its size against the limits above, the geometry and allowances, authority custody preparation, remote collider update and desktop collision acceptance. The real signed world is unchanged beyond the already-committed space.pl clauses.

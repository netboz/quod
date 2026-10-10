Review complete. Write tools are disabled in this session, so nothing was saved to memory; the report below is the deliverable.

**Verdict:** the local slice is coherent under its stated scope. Registration is reachable, idempotent and grants nothing. I found no production defect. All findings are test-only or validation limits.

## Findings

- **Low. Stale timeout in the receipt wait.** `tree/test/quod_physics_tests.erl:1198-1210` computes `Remaining` once, spends up to that much inside `outcome_snapshot`, then reuses the same value in `after`. The wait can overshoot the 5 s deadline by up to 2x before the next iteration fails the `?assert`. The comment claims an absolute deadline. Recompute before the `receive`.
- **Low. Unhandled snapshot shapes crash instead of naming the failure.** The same function matches only `terminal` with `Height =< Floor` and `unresolved`. A `not_found` outcome, a terminal receipt above the floor, or an `{error, timeout}` reply produces `case_clause`/`badmatch`. These are loud, not concealing, but a named error would be clearer. Terminal-above-floor cannot occur in practice: `quod_committed_projection.erl:539-548` advances the floor and flushes staged rows in one write, so `outcome_snapshot` sees both or neither.
- **Low. Label overclaim in the projection test.** `tree/test/quod_committed_projection_tests.erl:246-264` runs two fresh `new_est` projections labelled `initial` and `recovery`. The second is not a retained-history recovery through the real owner. It proves determinism of the base plus genesis apply, which is still the right check for this slice.
- **Info. The two-world fixture is two sequential single-world fixtures.** `tree/test/quod_physics_tests.erl:164-207` founds one actor ontology per case. It does not show two worlds with different gravity coexisting under one runtime. The first body read at line 176 asserts only `failed` without a reason. The denied case checks a grant on `another_space` does not leak to `room`, which is a real check.
- **Info. Physics-named generic verifiers now load everywhere.** `current_signed_request/2` and `signed_physics_request/3` (`quod_physics_predicates.erl:18-21`) are pure signed-request checks with no authority. Registering them in every ontology is harmless. Naming only.

## Claims checked

- Reachability: `quod_predicates:load/1` lists physics, `new_est/0` calls it, and `new_est` backs the live engine (`quod_prolog.erl:1074`) and genesis compilation (`quod_prolog.erl:7531`).
- No grant, no allocation: dispatch still fails closed without context, `live_query` still requires a read-only proof, scope identity and the world's own `physics_body_read_projection`. An ontology without that rule fails under the `unknown=fail` flag set at `new_est` line 59.
- Old manifests listing the module stay harmless by existing semantics: `register/6` returns the engine unchanged on an identical descriptor (`quod_predicates.erl:320-321`). No new branch was added for this.
- No colliding heads for the eight registered functors in any `priv/ontologies` file.
- Gravity replacement: the selector reads `attribute/3` through the derived `physics_allowances` rule, the basis invalidates on change, and `install_physics` retires the run when gravity differs (`quod_runtime.erl:2878-2886`). World identity is unchanged.
- Measurement synchronisation: subscribe precedes snapshot, the source namespace comes from the operation ref, and `Target` is the exact `{transaction, Ns, Anchor, TxId}` returned at `quod_prolog.erl:4949-4951`. Tracing starts after the wait, reconcile is synchronous through `project_physics`, and the `status` call syncs the owner. The wait cannot hide I/O caused by the measured checks; the only risk is flake from unrelated writes, not concealment.

## Unused or compatibility-only code

None in production. In tests, the `caller` and `registered_keys` fields collected by `trace_calls` appear only in failure output. That is diagnostic payload, not dead code.

## Validation limits

- `quod_ledger_store` is not in the frozen tree, so I cannot confirm `append/2` is the real append entry. A wrong arity would make that trace point silently watch nothing.
- `quod_foreign_projection` is not in the tree, so "all committed projection owners use the base" is verified only for the live engine and genesis path.
- `native/quod_physics/src/lib.rs` is absent from the tree; the hinge rotation refusal was checked from the patch only.
- The 228-test receipt predates the final projection test file and doc. Only the projection module was re-run against the frozen hashes. The physics test hash matches across all three receipts.
- No live remote propagation, signed lobby baseline or deployment is evidenced, as the packet states.

The full task stays open. Source-notice invalidation into the resource basis, cross-scope collider selection and ordinary-view dependency tracking are not in this slice, and no pinned-copy substitute is acceptable.

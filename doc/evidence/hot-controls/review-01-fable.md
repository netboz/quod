# Fable hot controls review

Read-only review of `/tmp/quod-hot-controls/review-01/tree`, session `b9c69c1b-d4e1-4471-8824-0f4b8e205475`, 2026-10-08. Consultative findings, independently verified by the implementation owner. No builds or tests were run by the reviewer.

Addendum on redundant or compatibility branches in the reviewed hot-control and checkpoint path, against the unchanged snapshot. The `step/1` removal you describe is consistent with what I saw: the snapshot's only production caller already used `step/2` (quod_physics.erl:379), and the `step/1` callers were tests and the benchmark. Keeping the authored `vector/3` pose shorthand and observer navigation as documented semantics is right. They are domain vocabulary, not alternate executors.

**Actual fallback branch worth removing**

- **Absent navigation guard silently disables fencing.** quod_physics.erl:571 treats a missing `navigation_guard` key as "current", and :311 defaults it to `undefined`. Production always supplies the guard from `project_physics`, so the default exists only for simulator fixtures that build a spec by hand, such as the expired-rest test. A world installed without a guard would accept every watch, query and input with no invalidation. This is hidden fallback behaviour in production code. Make the guard mandatory in the spec and have the fixtures supply one.

**Convenience wrappers, not protocol paths**

- `step_native/1` in quod_physics.erl:376 is a one-argument default over `step_native/2`. It is a local convenience, not an old implementation. Keep or inline at your discretion.
- `quod_effect:release_transient(none, _)` is the legitimate no-effect case for a control proof that staged nothing. Not a compatibility branch.
- `activity({rest,...})` delegating to `activity({door,...})` in quod_physics.erl is reuse of one validator, not duplication.
- The paired lookups `quod_scope_session:request_expiry()` falling back to `quod_proof_context:request_expiry()` (and the same pattern for remaining time and request binding in quod_physics_predicates.erl) distinguish a remote scope session from the local origin. Both are live paths, not an old one.

**Branches I could not confirm as dead**

- `observation_result` maps `{error,{reaction_guard,_}}` and `{error,invalid_reaction_request}` to `held` (quod_physics.erl:821-823). I did not find producers of either shape in the runtime's physics dispatch. Verify runtime reachability before deleting. Absence from my grep is not proof.
- Including the transient in `quod_proof_session:dirty/1` only matters when a control proof's scope is sealed or reported remotely. For a local read-only control proof, `seal_material_scopes` returns before reading dirtiness. Check whether the remote-scope reply path needs it. If nothing consumes it, the clause is redundant.

**Stale naming, not branches**

- `physics_projection` still binds body rows as `Position, HalfExtents` although the fields are now pose and shape (quod_physics.pl, projection findall). Rename only.
- Rest observation statuses publish under `door_observation` (quod_physics.erl:846). Rename to a neutral observation label.

No other old-protocol implementation or compatibility shim is present in the push, rest-request, custody, sample, finish or restore path. The clean-break rule is otherwise satisfied in this scope.


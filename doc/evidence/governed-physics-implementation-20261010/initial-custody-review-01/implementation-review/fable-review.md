**Verdict: approve for the next gate.** The implementation matches the corrected plan and I found no blocking correctness defect. The findings below are small reuse and precision items plus one coverage gap. Full clean release gates are still outstanding, so this is not a release verdict, and nothing here claims desktop, remote or headset acceptance.

**Verified against code**

- Strict context: `custody_policy/2` at `tree/src/predicates/quod_agent_predicates.erl:126` re-proves on `committed_state` with `policy_verdict` kind, original chain and access guard, read-only plus read-set, absorbs reads into the caller and always cleans up. Governed predicates inside the policy yield `invalid_custody_policy`, as tested.
- Caller, scope, destination, output: principal bound in proof context at `:105`; anchor and namespace matched against the chain head at `:78`; destination must materialize to the installed node at `:90`; `Key` must be an unbound variable at `:76`.
- Deadline: scope remaining or the proof's absolute deadline at `:110`, never extended.
- Vault: unchanged repeat is two `read_file_info` calls and no write or sync (`tree/src/quod_agent_vault.erl:300`); startup syncs an existing directory at `:113`; a failed mutation forces one sync before the next success at `:156`. `generate/1` is gone and no live caller of it or of `can_prepare_agent_key/4` remains outside `doc/evidence` and `doc/outdated`.
- Positive-only recovery: `valid_resource_scope` at `tree/src/quod_runtime.erl:2708` keeps the runtime custody scope at epoch above zero, so the `none, 0` clause is unreachable from the selector.
- Atomic assignment, missing-camera rollback, grant revocation after proof and two-destination race are exercised through real signed ingress in `first_physical_configuration`; receipts show true child exit 0.
- Native: the new annulus test has no default floor, the box passes through the hole at the origin and lands on the rim at x=3 with y≈1.0. That is real passage plus solid rim.

**Findings**

1. **Fourth copy of "local node reference".** `local_destination/1` at `quod_agent_predicates.erl:90` duplicates `local_node_agent/3` in the same file at `:41`, `quod_runtime:local_node_reference/0` at `:2849` and `quod_agent:current_node/2` at `:198`. Reuse one helper.
2. **Second live destination check** at `quod_agent_predicates.erl:116` re-samples node identity after the vault call. Either state the reason in a comment or remove it. It never undoes prepared custody, so it only withholds an answer.
3. **Uncertainty flag is too broad.** `custody_reply/2` at `quod_agent_vault.erl:167` sets `sync_pending` on every error, including outcomes that mutated nothing: the pre-check expiry at `:173`, `stale_preparation` at `:274`, identity errors at `:205` and `conflicting_vault_custody` at `:309`. The next call then fsyncs for no reason. Safe, but it is a sync after an unchanged check. Narrow it to paths that entered `write_atomic`, `make_link` or `delete_file`.
4. **Redundant `agent_hosted` proofs and an implicit guard.** In the `prepare_agent_key` action (`priv/ontologies/agent_instance.pl:128` and `:130`) `agent_hosted` is proven three times: via `agent_preparation_assignment` clause 2, again inside `can_prepare_agent_key/5` at `agent_recovery_policy.pl:19`, and again at `:130`. Line `:130` is now the only thing preventing a `none, 0` candidate publication when an explicit first-preparation grant exists. Make that explicit with an epoch-positive check, drop the duplicates, and add one test that the action refuses `none, 0` with such a grant present. No test covers that today.
5. **Two authorization disciplines in one module.** `authorize_sign` at `quod_agent_predicates.erl:187` still evaluates its policy in ordinary proof context while the custody bridge uses the strict re-proof. `custody_policy/2` is reusable as written. Follow-up, not in this scope.
6. **Minor test coupling.** `failed_mutation_requires_successful_directory_sync_test` asserts the exact trace shape of `sync_dir` internals, and the pure-policy test mutates the global `node_actor_principal` env. Both are acceptable under sequential EUnit; note them if either suite is parallelized.

Growth is about one hundred production lines for a new governed capability; items 1, 2 and 4 are the avoidable part.

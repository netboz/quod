**Verdict: legitimate reuse, conditionally.** Per-predicate authoring is the existing work unit by construction: the compiler takes one indicator per goal (`priv/ontologies/quod_prolog.pl:54`) and the client edits one predicate at a time. The required atomic transitions in doc/spaces.md and doc/physics-native.md are live admission, definition edit and withdrawal with their receiver consequences. Those are not touched. The "one giant installation" assumption was wrong: founding is the bulk path, and refounding is excluded by identity preservation, so no bulk editing path exists to split. The rule against splitting applies if any intermediate program state carries domain meaning. I checked the three consumers of installed code and found one real counterexample, so the candidate's claim that every edit is independently complete is false as written.

**Blocking findings**

1. **Selector publication order.** A defined selector whose body fails is an error, not absence (`src/quod_runtime.erl:2840-2871`). Publishing `agent_hosting_projection/4` before `agent_hosting_scope/2`, `agent_hosting_instances/3`, `agent_hosted/4` makes the agent_hosts reconcile throw and records a resource failure until a later commit reselects. The gallery test shows undefined predicates fail silently in proofs, so `physics_projection/2` yields empty rows early, but order it last as well. Required: publish helpers before any selector and assert after every publication that the runtime reports no resource failures and an empty physics map, as `test/quod_lobby_tests.erl:43` already does once.

2. **Activation transaction size unmeasured.** The whole candidate rests on the later governed configuration fitting the same allowance that refused the 170 KB goal. That transaction must replace roughly fifteen `:- fail` policy stubs with per-predicate edits, add space, allowances, run, structure, allocator, physical_space membership, agent and viewpoint definitions, an owned body, the authority host via `goal(agent_hosted/4)` with its `can_assign_agent_host/6` rule, actor `can_invoke` grants and the `space_physical_change/3` composition. Measure it before any authoring starts. If it does not fit, the blocked resource is a real domain transition and the cap must be fixed at its owner, not routed around.

3. **Exceeded resource still unreported.** The plan names bytes but not which limit refused the goal, its module, and whether it is encoding or budget. AGENTS requires that report regardless of this candidate.

4. **Cold symbols not measured.** The measurement script counts bytes only. Admission allocates and tracks new functors per signed request (`src/predicates/quod_common_primitives.erl:144-147`). Count new symbols per edit against the admission allowance; `action/3` and `physics_space_change/3` are the largest.

5. **Reactions become live immediately.** Asserting `react_on/2` replans the catalog and puts both physics clauses in front of every runtime observed notice in this world (`src/quod_runtime.erl:1183-1185`, `2896-2901`). Show for this world that `physics_observation/1` fails rather than errors under domain audience and that reaction failures stay zero.

6. **Uncertain edits.** A re-prepared edit is idempotent through the baseline check, but a fresh source read showing the predicate absent does not prove the first request will never land. The driver must wait for the original request's terminal outcome or expiry before preparing a replacement, and never run two edits of one predicate concurrently.

**Requirements, not blocking**

- The activation transaction should pin the authored program it depends on. Its own calls create per-predicate OCC reads, not content checks. One `'$quod_source_chunk'` fold plus `term_digest/2` is a cheap whole-program pin.
- Confirm the target world already holds space.pl. The libraries call `space_instance/2` and `space_assignment/3`; the lobby test composes it only in test.
- `agent_hosting_suspended/1` is defined in both files; publish it as one two-clause edit with the `fail` clause first.
- Authority key custody is node-side. `initialize_agent_host` needs a vault-held key before the transaction; document how the physics fixture provisions it.

**New production machinery:** none. The publication driver is tooling: read source, compile, sign, wait for a definite outcome, rederive progress from source reads on restart. Batching several anchored transactions in one signed goal, as the lobby test does, is allowed and reduces round trips.

**Missing evidence:** activation goal size and symbol counts, per-edit cold-symbol counts, runtime status after each publication in both identities, reaction statistics, the exact refused limit and owner, and the real world's current baseline including space.pl and any existing `action/3` or `react_on/2` clauses.

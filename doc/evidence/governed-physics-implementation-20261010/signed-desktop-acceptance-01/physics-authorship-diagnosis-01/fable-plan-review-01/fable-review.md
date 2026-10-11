**Verdict: the gap is real in kind but not yet demonstrated in size, and the proposal is under-specified on where the algorithm runs and who admits the new goal shape. Not approvable as written.**

**Blocking findings**

1. **Algorithm location is unstated and decides everything.** Today the diff algorithm lives in the `quod:prolog` ontology (`tree/priv/ontologies/quod_prolog.pl:54-135`) and returns an expanded goal the client resubmits. If a compact goal computes that expansion and then crosses `::` into the target, the nested goal is canonically encoded and charged against the 128 KiB nested-goal bound before it runs (`tree/src/quod_proof_session.erl:213-230`, `tree/include/quod_proof_limits.hrl:19`). Compact source only helps if expansion and execution happen inside the target scope with no cross-scope expanded goal. The plan must say this explicitly and state that the shared algorithm becomes common Prolog available in the target, with the compiler path in quod_prolog.pl removed, not kept beside it (AGENTS.md "replace the old path").

2. **Cold callable admission has no owner-side seam.** The parser keeps unknown names opaque (`quod_common_primitives.erl:123-127, 204-207`). Materialization exists only for callable positions of a signed goal (`quod_wire_term.erl:478-558`), which sees a source binary as data. The plan must name the single admission step: after the target verdict, once per invocation, over the whole parsed bundle, reusing the existing `assertz`-clause walk and the one aggregate new-atom budget. No per-clause budgets, no second materializer.

3. **Policy sees a binary, not predicates.** With expanded goals the target's `can_invoke` can inspect which indicators change. The plan must state that policy parses the source with the existing non-allocating primitive and decides on the indicator set before materialization, and that materialization never precedes the verdict.

4. **Admission under the human principal is unproven.** `prolog_edit_destination` (`quod_prolog.pl:74-91`) selects an administrator wrapper only when root catalogues the target. For the human-owned lobby world, the world's own `can_invoke` must already admit the new goal shape. The plan must cite the exact existing target clause. If none exists, the first compact edit cannot be bootstrapped without a prior expanded edit, which is a scope decision for Yan.

5. **Sealed plan is the next ceiling.** Compact source moves bytes from goal to diff. The diff carries expanded clauses and is bounded by the 128 KiB plan envelope and 1024 diff ops (`quod_proof_limits.hrl:27-28`), then 224 KiB DTX body. The plan lists measuring these but not what happens if the diff exceeds them. State that a refusal there is reported as that resource, with no constant raised and no split.

**Demonstrated gap and smallest extension**

The shape of the gap is supported by the tree: expanded output grows per clause with `assertz` wrappers (`quod_prolog.pl:113-127`), the nested-goal bound is 128 KiB, and multi-predicate edits cost one invocation each against 64 per scope (`quod_proof_limits.hrl:14`, `quod_proof_session.erl:161`). The specific numbers are not in the tree.

Smallest justified extension, reusing what exists: parse via `'$quod_program_source'`, OCC via `'$quod_predicate_source'`, removal via `'$quod_retract_exact'`, assertion via ordinary `assertz`, all already in `quod_common_primitives.erl`. The only new Erlang is the single post-verdict callable-materialization step. Everything else is relocating the Prolog algorithm. Any new common primitive changes signed semantics on every validator and needs the deployment gate the plan already names.

**Requirements the plan must add**

- Proof: transcript records the compact signed source; the diff is derived deterministically from that source plus the OCC-checked authored state, and validators verify by applying ops, not re-parsing. State this.
- OCC: expected source per predicate inside one transaction, with `edit_conflict` and `edit_not_representable` reasons retained, as the tests at `tree/test/quod_prolog_ontology_tests.erl:114-138` require. List which existing test obligations move to the new seam, including unchanged-source-no-mutation (lines 19-30) and cut/rollback (lines 63-73).
- Resource: name the actual bound hit on refusal (nested goal, transcript, plan envelope, diff ops, DTX body, new-atom budget, durable result 16 KiB).
- Provenance: the signed goal, not the expansion, is the immutable record; native capability manifests unchanged, consistent with `tree/doc/spaces.md:9-13`.
- Fence: keep `current_ontology_identity(Namespace, Anchor)` conjunct and the matching `can_invoke` clause (`quod_prolog.pl:5, 68`).

**Unsupported statements** (not verifiable from the frozen tree; do not treat as established)

- 227 clauses, 66674 raw bytes, 169953 canonical bytes.
- "Directly asserting parsed cold symbols fails callable admission." Plausible from the opaque functor shape, but no test shows the failure.
- "Common native physics interfaces are already loaded."
- "Normal scene/console now work."
- Any claim that compact source fits the plan envelope or DTX body.

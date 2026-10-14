Verdict first: the plan is consistent with the architecture and the existing owners, but six concrete gaps need correction before implementation. Three are missing capabilities (anchored lens subjects, a routes bridge usable outside root, a second Eidolon result shape). Three are under-specifications that would otherwise produce a second permission truth or an unbounded answer.

## Findings by plan item

**1. Ontology instance term.** The derived rule is sound and cheap. Write it exactly as a head-guarded clause in common predicates so the proof-bound bridge only runs when the head unifies:

```prolog
instance_of(ontology, ontology_ref(Ns, Anchor)) :- current_ontology_identity(Ns, Anchor).
isa(ontology, thing).
```

- **Admission safety.** Human-user admission must re-prove without external predicates (`human_user_instance.pl:4-7`). Its `instance_of(human_user, I)` call never unifies with the new head, so the bridge is not invoked. Keep that property and add a test that proves it rather than assuming it.
- **No `no_follow` on `instance_of/2` or `isa/2`.** Following only triggers on `Ns:Name` terms, and `ontology_ref/2` is not one. Putting `instance_of/2` on the list in `common_predicates.pl:188-202` would break foreign class membership that the lobby relies on. The plan should name the predicate it means, or drop the clause.
- **`thing` becomes declared everywhere.** `isa(ontology, thing)` makes `thing` a known class in every ontology. The existing assertion that `isa(sky_sphere, thing)` fails in the class vocabulary (`quod_lobby_tests.erl:588-589`) still holds, but say so in the plan.
- **Client term.** `World.tsx:431` builds `entity: atom('ontology')`; replace with the `ontology_ref/2` compound and drop the `kind` branch at `world.js:351` and the type at `world.d.ts:49`. The workspace key at `World.tsx:293` already renders the term, so it stays stable.

**2. Policy, interface and route selections.**

- **Policy answers are bounded only per predicate.** The chunk primitive has no indicator filter (`common_predicates.pl:84-85`), and the predicate lens returns one whole binary (`quod_lens.pl:291-299`). Smallest fix: a `policy_source` lens whose `rows/3` backtracks over the fixed set `{can_invoke/4, can_join/3, acl_sovereign/1}` so the cursor yields one predicate per `next`. Only if one predicate can exceed the read answer bound, extend `'$quod_source_chunk'` with an indicator list. Do not add a second chunker.
- **Interface facts are a per-target authoring cost.** No ontology in the frozen tree authors them. The read itself needs no new ACL for system targets because the wrapper shape leaves the query unbound (`common_predicates.pl:68-69`). The plan must list which targets get `interface/2` facts in this scope; an empty answer for the rest is accurate, not a defect.
- **Routes have no bridge outside root.** `directory_host/5` refuses any non-root scope (`quod_directory_predicates.erl:36-39, 55-56`). So `prolog_inspect` must ask `quod:root::` and root needs one new entry in `root_public_goal/1` (`quod_root.pl:48-55`). That is the one new root policy clause; name it.
- **Anchor conflict must be computed, not filtered away.** The bridge enumerates by namespace. Binding the anchor in the call would silently pick one of two incompatible histories, which the exact lookup forbids (`quod_directory.erl:171-175`). Collect distinct anchors first: one matching anchor yields routes, several yields `anchor_conflict`, one other anchor yields "advertised under a different history".
- **Private hosting is invisible to this bridge.** Public hosts exclude private contacts (`quod_directory.erl:292-314`), and unknown versus known-but-empty is only distinguished by `resolve/1` (`:67-89`), which is not bridged. A personal lobby will always report no route. Report "no public route" rather than "unavailable", and never surface the private host contact.
- **Role is not filtered.** `directory_hosts/1` ignores the role column (`:301-309`), so replicas appear beside validators. Call the answer "hosts" or add the role argument; no compatibility concern applies.

**3. Modes without a second truth.** Yes, this is representable. The current non-system clause implies editable from identity alone (`quod_prolog_eidolons.pl:33-34`), which the plan correctly retires. The single-truth shape is:

- Author the mode as a projection of the same ownership predicate that `can_invoke/4` uses: `lobby_owner/1` (`lobby_instance.pl:4`) and `human_user_owner/1` (`human_user_instance.pl:9-11`).
- Read it through the existing introspection shape, for example `prolog_introspection(presentation, Mode)`, so admission of the mode read is admission of the read path. Default to `read_only`, and guard the undefined-predicate case explicitly.
- Keep the root path for system targets (`quod_prolog_eidolons.pl:28-32`). Actual edits already carry their own admission because the compiler returns a goal the client signs separately (`quod_prolog.pl:54-70`).

**4. Class Eidolons and the lens result.**

- **Only `workspace/4` exists.** The client demands it (`world.js:372-376`) and forces `codeForm` (`World.tsx:298-301`). Add one second result functor, for example `lens(Target, Entity, ontology_ref(LensNs, LensAnchor), Marks)`, validated with the same target and entity checks. Specify the consumer: the existing scene path used by the licence view (`World.tsx:225-230`) is the smallest fit.
- **Lens subjects discard anchors.** Marks come out as `depicts/2` (`quod_lens.pl:231, 244-245`) because `lens_subject/3` carries a flat name (`:317`). The reader then sets `anchor: null` (`marks.js:196-210`) and the inspector drops such marks (`World.tsx:341`). An ontology mark is therefore not selectable and not exact. Smallest fix: let rows carry an anchored thing and add one `subject/3` clause emitting `depicts(Ns, Anchor, ontology_ref(Ns, Anchor))`. Rendering already accepts `depicts/3` (`quod_lobby_tests.erl:289`).
- **Choice filtering.** The panel keeps only `prolog`/`source` choices (`World.tsx:343-344`); generalise for ontology subjects.
- **Class diagrams.** Foreign classes surface as `Ns:Class` names without anchors (`common_predicates.pl:160-165`). If a class lens is in scope, it must resolve the anchor through the pinned vocabulary facts as `vocabulary_class/3` does; otherwise state that class marks are name-exact, not history-exact.

**Privacy check.** Other-owner lobby reads fail closed (`lobby_instance.pl:4`), root and signup policy stay admin-only (`quod_root.pl:64-69`), and the new instance rule exposes nothing beyond the identity that `public_source_query` already exposes (`common_predicates.pl:59-64`). No new disclosure found.

## Test coverage

| Obligation | Already covered | Missing |
| --- | --- | --- |
| System read-only and administrator | `quod_lobby_tests.erl:793-910, 912-1023` | |
| Owned non-system access | `:611-677` | |
| Other-owner refusal, root/signup | `:659-663, 867-876` | `entity_eidolons` on an `ontology_ref` subject by a non-owner |
| Wrong anchors | `:731-732, 905-907, 975-976` | Wrong anchor via `entity_eidolons` and via the new lens result |
| Policy source without invocation | `:719-720, 839-845` | Policy lens per-indicator cursor walk |
| Forbidden policy edit | `:880-901` content only | Non-admin edit of `can_invoke/4` on a system target; owner edit on own lobby |
| Baseline race, exact outcome | `:670-675, 1119-1121`, `quod_prolog_ontology_tests.erl:114-127` | |
| Cursor snapshot, restart, no-I/O | `:679-791, 957-967` | No-I/O for policy, interface and route inspections |
| Stale presentation mode | | Mode read editable, ownership changed, edit refused |
| Routes | | Match, no public route, conflict, other anchor |
| Admission unaffected by new rule | | `can_join`/membership verdict with the shared clause loaded |
| Client | `world.test.js:78-90` codeForm | New result functor, anchored ontology mark, `ontologies_eidolons` fixtures at `:136,140` renamed |

Not done: the working agreement asks for the stop notifier, but this review was restricted to read-only tools, so it was not invoked.

**Verdict: no blocking correctness or security defect in the frozen implementation.** The plan's five points are implemented through existing owners, the acceptance tests run through real signed seams, and the docs match the code. I found three low-severity items with one-line fixes, two assumptions I could not verify inside `tree/`, and a few uncovered obligations.

## Findings

- **Duplicate identical mode answers are refused as ambiguous.** `tree/priv/ontologies/common_predicates.pl:102-108` collects every `ontology_source_mode/1` answer and only accepts a one-element list. Two rules that both yield `editable` (owner plus a future delegate) would make the ontology unviewable, not just uneditable. Smallest fix: collect into `Raw` and add `sort(Raw, Modes)` before `ontology_presentation_mode/2`.
- **Lens eidolon lacks the ground guard the source eidolon has.** `tree/priv/ontologies/quod_prolog_eidolons.pl:41-49` versus line 20. With an unbound subject, `prolog_inspect/3` clause 1 enumerates root's catalogue and commits to the first system identity; if root refuses, clause 2 reaches `Namespace::` with an unbound namespace. Disclosure is nil (the catalogue is public), but it is an enumerable public path. Fix: open the body with `Target = ontology_ref(_, _), term_variables(Target, []),`.
- **Route list comprehension can silently under-report.** `tree/src/predicates/quod_runtime_predicates.erl:93-95` filters by map pattern, so any route map missing a field or with a non-pair endpoint is dropped while the status still says `available`. Replace the generator pattern with a single strict function clause so a shape change raises instead of hiding routes.
- **Observation, not a defect.** The exposed expiry is the directory's monotonic-clock lease (`tree/src/quod_directory.erl:435`) or `infinity` for private rows. It is harmless but meaningless off-node. Consider omitting it or naming it a lease.
- **Optional simplification.** `prolog_source_view/2` at `tree/priv/ontologies/quod_prolog_eidolons.pl:30-39` repeats root's classification that `prolog_inspect/3` already performs, so a non-system source eidolon opens root twice and the target twice (identity at line 24, presentation at line 38). Letting `system_prolog_introspection(presentation, Mode)` answer from root's access would collapse it. Not required for this scope.

## Confirmed

- **Instance identity.** The head-guarded rule at `common_predicates.pl:43-44` derives the term from proof-bound identity only. Catalogue selection (`tree/client/src/world.js:28-30`), owned ontologies (test asserts identical four choices, `tree/test/quod_lobby_tests.erl:759-764`) and marks (`tree/priv/ontologies/quod_lens.pl:245-246`, `marks.test.js:8-19`) all carry the same term. `instance_of/2` and `isa/2` following code is byte-identical to `before/`. `ontology_eidolons/1` and the client `kind` survive only in the plan text.
- **No spatial or physics semantics.** Only `isa(ontology, thing)` is declared; space membership still comes from `space_instance/2` (`common_predicates.pl:14,30`). Tests assert `isa(ontology, space)` fails (`quod_lobby_tests.erl:758`, `quod_lens_tests.erl:317`), and a mark's depicts carries anchor and entity but no body (`marks.js:196-210`).
- **Routes.** The predicate reads only `scope_identity/1`, delegates to `validator_routes/2` (anchor-conflict check, confirmed validators, private rows resolved through their host at `quod_directory.erl:623-634`), persists nothing, and adds no root API. The live veto is proven through the real seam: a transaction that reads routes then asserts gets `proof_unavailable` with height unchanged (`quod_lobby_tests.erl:1174-1180`). Private routes stay out of `directory_hosts/1` and other owners are refused (lines 1170, 1182).
- **Chunker.** One chunker with three selections (`quod_common_primitives.erl:148-157`); absent predicates land in the read set, unknown symbols yield empty text without atom allocation (`quod_common_primitives_tests.erl:150-164`).
- **Views and modes.** Policy selects the fixed ACL indicator list; interfaces are explicit facts only (test asserts `prolog_query(` is absent, line 784). Absent mode is read-only, ambiguity fails. Every edit still passes the target's `can_invoke/4` and exact baseline (lines 797-802, 811-818). The edit compiler in `quod_prolog.pl:62-99` is unchanged.
- **Client.** Target, entity and lens parameters are validated against the subject (`world.js:412-419`); lens results never reach `codeForm` (`World.tsx:301`); the cursor lifecycle is shared through `readTextProjection`.

## Unverified and uncovered

Two things live outside the frozen set. I could not confirm that `quod_runtime_predicates` is loaded in every scope; root's module list in `quod_lobby_tests.erl:1003` names only directory and ontology predicates. If the route predicate is absent in a scope, `route_chunks` raises an existence error instead of reporting a status. I also could not confirm production endpoint hosts are binaries; a tuple host would make `format_clause` raise at `quod_common_primitives.erl:202-206`. The route lens is only exercised on the lobby.

Uncovered acceptance obligations:

1. Route lens on a public system target, and on root for an administrator.
2. Ambiguous or invalid `ontology_source_mode` declarations refusing the recipe (this would also expose the duplicate-answer item above).
3. Lens eidolon asked with an unbound subject.
4. Interface lens on `quod:lens` itself, which has declarations at `quod_lens.pl:315-316`.

The two corrected route-format expectations match the chunk shape the primitive test and lobby test now assert. I could not run the stop notifier because this review was command-free.

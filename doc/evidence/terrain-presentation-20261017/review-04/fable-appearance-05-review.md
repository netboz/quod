Reading the appearance-05 brief, its script manifest and the patch.

All evidence read; nothing further is needed. Complete report for the appearance-05 correction.

References are to `_build/terrain-presentation-20261017/deployment-274-rolling/` and the frozen production tree `_build/terrain-presentation-20261017/review-04/tree/`. Inspection was read-only: file reads, hash recomputation of the eight listed files and JSON summaries of the retained results. No build, test, edit, memory update or delegation. All eight manifest entries match on disk.

## Verdict

The correction is sound and narrow. The execute03 failure was a definite pre-admission refusal, the rename is a bijection on the finite variable set with its inverse checked against the original term, the verify helper now reuses the compiler's own canonical guard literals instead of a second normalizer, and submission remains a single `quod_prolog:execute` behind both the old and the new clearances. No confirmed issue. The owner harness change is the receipt path only. Execute05 has not run, so nothing here is an appearance or acceptance pass.

**Definite refusal, verified.** `src/quod_prolog.erl:5061-5063` and `5270-5271` call `encode_proof_submission` before `submit_single_ordinary_plan`, `submit_single_effect_plan` or `build_and_register_group`. That path reaches `src/quod_wire_term.erl:178-187`, where `binding_name/1` accepts atoms and binaries only and raises for integers, which `binding_pairs` turns into `{error, invalid_result}` at lines 168-173. The compiled edit from prepare03 carried seventy-nine parser-numbered integer variables, so the result encoding failed before any plan was registered or submitted. `shared-appearance-execute-03/result.json` records exactly `{error,invalid_result}`, verify03 failed only because `world_palette/1` is still absent, and inspection04 shows the lobby at thirteen committed with the original `lobby_query/1` source. No write occurred.

**Reversible rename, verified.** `shared_appearance_05.py` collects every `{N}` one-tuple with a non-negative integer, which in the erlog term encoding is only ever a variable, maps each to a distinct atom `OperatorVariableN`, rebuilds the term, and then asserts `Edit = Restore(Named)` so the inverse reproduces the original term structurally. Prepare05 records seventy-nine variables, the inverse holding, the integer-keyed result refused and the named-keyed result accepted through the real `quod_durable_term:encode_result`. Named atoms are what trusted VM proofs use, per the comment at `quod_wire_term.erl:176`. Variables inside asserted clauses are standardised apart on assert, and the compiler's after-source guard compares canonical text with independent variable numbering, so the spelling change cannot alter stored source.

**Compiler guard reuse, verified.** `SourceChecks` walks the compiled term left to right and pattern-matches exactly six `$quod_predicate_source` literals in before/after order for `lobby_query/1`, `lobby_options/3` and `world_palette/1`, which is the occurrence count in prepare03. Prepare05 proves all three before-literals against the live lobby, so the baseline still holds; verify05 proves all three after-literals before emitting `verified`. The fact-normalisation mistake that broke prepare04 cannot recur because no reprinting happens in the helper.

**Clearance and single submission, verified.** The execute branch still requires release pass, fleet probe pass, `review-clearance.json` with matching `mutation-inputs.json` hashes, and now also `appearance-clearance-05.json` with matching `appearance-inputs-05.json` hashes plus the four prepare05 flags. It proves `material_eidolons/2` first, then calls `quod_prolog:execute` once, and the exclusive `shared-appearance-execute-05` directory prevents a second run.

**Owner harness, verified.** `owner-appearance-acceptance-05.mjs` differs from the reviewed harness only at line 13, which now requires `shared-appearance-verify-05/result.json`. Goal, cleanup, post-state assertions and definitions comparison are unchanged.

## Risks

- **Interval between prepare05 and execute05.** The before-source checks ran at preparation. If the live lobby source changed in between, the compiled guards fail closed with `edit_conflict`, which is the intended outcome; the retained failure would simply need a fresh prepare.
- **Result size.** The named result now carries seventy-nine unbound variables. Prepare05 showed `encode_result` accepting that shape, so the durable result limit is not expected to bind, but execute05 is the first real exercise.
- **Unchanged limitations.** `appearance-clearance-05.json` and `appearance-inputs-05.json` are not yet issued, verify05 does not exist, and the owner update, acceptance world and deployed walk remain unexecuted. This review is consultative only.

# S1.8 class operations Claude Fable review

Review session: `cea32d38-76bc-41da-a1e4-9101a71dffd3`. Yan requested this review after implementation. The reviewer had read-only tools and reported no file or memory edits. Parent verification and disposition follow; the original report is retained below.

## Parent disposition

1. **Confirmed and reproduced:** binding an offered creation output to the existing `space_name` control committed a new space membership, skipping allocation and constructors. The outer class-create permission still ran; this was a change of operation semantics, not removal of that check. `review-repro-01` retains the failing signed test (6 tests, one failure). The shared guard now compares a freshly compiled authored goal/result variant without unification, preserving intentional aliases while rejecting prebinding and new aliases. Constructor/source-classification semantics remain unchanged.
2. **Confirmed test gap:** the question-separation test now passes the real schema revision from `gui_definition/6` to `gui_bind` and separately requires `gui_schema` refusal. The original test used the operation revision and therefore could pass for the wrong reason.
3. **Confirmed simplification:** the shared binding helper now owns the one ground-input/read-only boundary used by binding and execution checks. There is no duplicate compiler or validator. Per-name selection still uses the existing class recipe selector; it creates no stored projection or history replay.

All eight focused correction tests pass (`review-focused-03`). Final sequential gates passed: **342 EUnit tests, zero failures**, and **production xref** (`regression-03`, `xref-03`). Both ran in the verified matching tmpfs workspace after the original-workspace regression hit 38 helper-copy `ENOSPC` failures; all failed evidence is retained. [Full verification and triage](/tmp/quod-s1.8-verification.md). The new tests also cover a foreign recipe anchor, stale fixed values while the form survives, and disappearance of the withdrawal offer after withdrawal. The later S1.9 client/admission boundary remains unchanged. Existing scope ACLs govern these queries; merely composing the contract grants no authority. The inherited recipe selector is reused rather than reimplemented. Transitive helper-source hashing remains an explicit authored validation-context obligation.

## Original reviewer report

Full review record for S1.8 / QUO-44, unchanged from my frozen-snapshot review except where noted as responding to your assessment. No files or memory were edited.

## Scope and verification of inputs

- Frozen tree `/tmp/quod-s1.8-regression-01-tree/`: all nine manifest hashes verified OK. Baseline `bbc13893`.
- Plan tracking after freeze differs from `/tmp/quod-s1.8-plan-before.md` only in status text, progress and the S1.8 checkbox wording; confirmed directions are identical.
- Later evidence (regression-01 338/0, transport-04 5/0, xref-02 pass on tmpfs) covers a tree whose production files are byte-identical to the snapshot I read.

## Confirmed findings, by priority

**1. Output freshness is checked at bind time only; prebinding a result before execution changes creation semantics.** [gui_operation.pl:54-59](/tmp/quod-s1.8-regression-01-tree/priv/ontologies/gui_operation.pl:54) requires `var(Results)`, but the execution guard at [gui_operation.pl:69-71](/tmp/quod-s1.8-regression-01-tree/priv/ontologies/gui_operation.pl:69) receives only the five bind inputs and never sees the result term shared with the authored goal. Reproduction in the harness authority model:

```prolog
gui_operation_bind(class_ref(Ns,A,space), create, Rev, create, Values, G, R),
R = [result(space, entity_ref(Ns, A, ExistingId))],
call(G)
```

The guard passes, then `with_build_plan(..., assert(instance_of(space, ExistingId)))` takes the nonvar branch of `'$quod_assert_instance'` ([construction.pl:17-19](/home/yan/src/quod/priv/ontologies/construction.pl:17)). Precise distinction, as you noted: the bind-time and guard-time `operation_authorized(class(space), create(Inputs))` checks still run, but the hook's creation path (ULID allocation, constructor plan, attribute writes, constructors) is skipped and the assertion becomes a membership clause on an existing instance, which the hook does not guard. Multi-output forms have the related new-alias case. The transported-goal flow makes this more relevant, since the goal term is client-supplied in the second request. Your fix direction is better than my original suggestion: comparing variant digests of the fresh authored goal plus results against the submitted ones preserves intentional authored sharing while rejecting narrowing, new aliases and altered fixed terms. Doc line to adjust once fixed: [gui-implementation-plan.md:225-226](/tmp/quod-s1.8-regression-01-tree/doc/gui-implementation-plan.md:225).

**2. The operation-forms-do-not-enter-question-submission test proves only a revision mismatch.** [quod_gui_operations_tests.erl:68](/tmp/quod-s1.8-regression-01-tree/test/quod_gui_operations_tests.erl:68) in the frozen file passes the operation revision to `gui_bind`, which differs from the schema revision by construction. The separation itself is correct in code: `gui_definition/5` fixes `Contract = question` at [gui_instance.pl:41-48](/tmp/quod-s1.8-regression-01-tree/priv/ontologies/gui_instance.pl:41), so `gui_schema`, `gui_bind`, `gui_form_projection` and `gui_open_definition` all refuse operation forms. Using the schema revision from `gui_definition/6` and adding a `gui_schema` refusal closes the fourth QUO-44 acceptance box.

**3. Duplicate ground-check and read-only boundary.** `gui_operation_guard/5` repeats the checks of `gui_operation_bind/7` ([gui_operation.pl:54-71](/tmp/quod-s1.8-regression-01-tree/priv/ontologies/gui_operation.pl:54)). Moving the ground check and `$quod_state_check` into `gui_operation_binding` so bind and guard share one checker, as you plan, removes the duplication. `gui_operation_definition` also recomputes the subject and `class_eidolons` per name after `gui_operations` already did; harmless at this size.

## Verified as correct

- Exact subject and history: both subject forms require the current anchor ([gui_operation.pl:46-50](/tmp/quod-s1.8-regression-01-tree/priv/ontologies/gui_operation.pl:46)); wrong anchor, wrong namespace, missing class and instance-as-class are refused and tested.
- Revision pins declaration, permission, result sharing, fixed values and validation context through `binding(Fields, Declaration)` plus the `offered_operation` wrapper. Question digests use the unchanged `submit/2` declaration, so pre-S1.8 question revisions are preserved structurally. `variant_digest` canonicalises variables, so renaming is stable.
- Input and output separation, output coverage, permission parameters from inputs ([gui_instance.pl:67-77](/tmp/quod-s1.8-regression-01-tree/priv/ontologies/gui_instance.pl:67)) are sound; each malformed declaration is tested.
- Fixed parameters: the readonly destination enters both the revision and `gui_match_fixed`; duplicate and extra fields are refused. erlog `delete/3` removes one element, so the duplicate test is meaningful.
- Discovery is read-only in execute via the outer `$quod_state_check` ([gui_operation.pl:17](/tmp/quod-s1.8-regression-01-tree/priv/ontologies/gui_operation.pl:17)). Committed policy goes through the existing `$quod_committed_check`; staged policy is rejected (test lines 81-85 in the frozen file).
- The guard re-runs definition, values and committed permission at execution; stale definition and retracted policy are both tested against a previously bound goal.
- Question path: `gui_bind` keeps its order and ground-continuation check; `gui_bind_values` is a pure extraction. `action/3` is not published.
- Creation subject convention is consistent: both bind-time and hook-time checks use `class(Class)`, so fixture checks matching `class(_)` behave identically on both paths.

## Verification gaps, now partly closed

- Regression-01 and xref-02 results arrived after my snapshot review; I did not run anything. xref-01's disk-space failure is an environment fact, not a code finding.
- `gui_definition/6` newly wraps compilation in `$quod_state_check`, which previously had no use on a path reached through `::` asks. The question-form read path now exercises it; the passing gui question and examples modules in regression-01 are the evidence.
- No test uses a recipe ontology different from the target, so the anchored `Ns::` recipe hop at [gui_operation.pl:40-41](/tmp/quod-s1.8-regression-01-tree/priv/ontologies/gui_operation.pl:40) is exercised only locally. Most-specific selection with a subclass override is untested here and relies on existing `class_eidolons` coverage.
- Stale fixed value with a still-existing form (re-place elsewhere, resubmit the old revision) is untested; the revision and `gui_match_fixed` catch it by construction.
- Discovery after withdrawal returning no `withdraw` view is not asserted.

## Later-scope limitations, not defects

- No `can_invoke` admits `gui_operations` or `gui_operation_bind`; the contract is unreachable in production until S1.9 adds admission. The admission shape is security-relevant for finding 1 even after the digest fix.
- `requires_input` can mask an input-independent committed denial on create, and the destination's eviction right makes `unavailable` conservative for withdraw. Both are advisory by design.

## Review limits

Read-only consultative review of the frozen tree and the stated evidence paths; no builds, tests or agents. Reproductions are by code reading against the harness authority model, which lets the actor invoke any goal; production reachability of finding 1 depends on the S1.9 admission shape. The parent owns independent verification, fixes and evidence.


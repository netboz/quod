# Signup terms: partial implementation and creation mismatch

Phase 1 remains incomplete. No commit, version bump, deployment, refound or live edit was performed.

Signup now authors facts, seven vocabulary pins, local ACL clauses, one hosted completion reaction and the two hosting derivations at `quod:user`. Its options contain only `terms/1` and the existing external-predicate module list. The obsolete `user_instance.pl` is removed; migrated fixtures consume the authored policy facts. The old local space checks, source-file list, source directory and source digest are removed from signup. The creation policy compares variants of the complete expected options, rejecting modified ACL clauses, extra source files and omitted facts.

The GUI-owner and client-view checklist items are now checked. Remaining callers, lifecycle fixtures, documentation and phase gates are unfinished.

## Validation

- `owned-user-gui-combined-01.log`: exit 0, 47 tests.
- `owned-signup-regression-01.log`: exit 0, 53 tests. This predates the final exact-options validation and focused test.
- `owned-signup-terms-01.log`: exit 0, one test exercising signed creation-policy checks, including altered rules and extra options.
- `owned-signup-terms-02.log`: exit 1, one test. The test now also checks the real creation validator. Its output is:

```
expected: = { ok , _ }
     got: {error,invalid_arguments}
```

The retained fixture is `/tmp/quod_hosted_D8DE9D9D41FE26DA`. No failed run was overwritten or silently rerun. Clean sequential EUnit, CT, Dialyzer, xref and client phase gates have not been run for this partial tree.

## Concrete mismatch

`quod_ontology:validate_typed_action/1` rejects any variable anywhere in the creation request. Authored ACL clauses and the reaction necessarily contain Prolog variables. The existing preparation/staging code in `quod_ontology_predicates` repeats the same restriction. The compiler already accepts clauses; creation admission and staging prevent these clauses from reaching it through `terms/1`.

The plan requires these rules as terms, so signup is not operational yet. No creation-engine fix has been written. Under Yan's explicit code/plan-mismatch stop instruction, the proposed next step is to refactor those existing creation checks to treat variables inside authored clauses as clause data, while retaining fixed request fields, exact policy approval, reserved-head checks, material admission and prepared-effect guarantees. No new source encoding, path, process or registry is proposed.

## Measured production delta

`signup-terms-delta.json` records the exact tracked production comparison, including the deleted source file. Relative to the Phase 1 starting tree: +2,551 / −2,238, net +313 lines. Relative to HEAD: +2,701 / −2,420, net +281. These are partial totals, not the final phase delta.

## Documentation

No normative documentation sentence changed during this signup step. The plan's GUI and client-view boxes were ticked, its combined-test result updated, and this mismatch recorded. Earlier normative changes remain in the existing Phase 0/Phase 1 evidence and will be included in the phase-end report.

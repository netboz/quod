# Governed-space implementation evidence

Yan requested a Claude plan review during implementation. The
[request](review-request.md) freezes the preliminary plan and its known failing
tests. [Fable's report](review-02/fable-review.md), its
[exit receipt](review-02/receipt.json), and the
[independent disposition](disposition.md) record the consultation and corrections.
Review-01 failed before launching Claude; its stop marker and copied inputs remain.
No prior review campaign was modified or resumed.

## Validation

- [Full relevant regression log](regressions-01.log): **154 tests, 0 failures**,
  exit 0. Space, class semantics, action savepoints, transaction predicates and
  the full physics module ran sequentially in one EUnit invocation. The
  [source manifest](regressions-1-manifest.json) identifies that exact tree.
- [Final focused log](eunit-07.log): **3 tests, 0 failures**, exit 0, after the
  final revision-before-destination diagnostic fix. The
  [final manifest](final-manifest.json) identifies the accepted source.
- `git diff --check` passed. No commit, deployment, refounding, native capability
  change or existing history deletion was performed.

## Retained attempts

| Attempt | Result | Diagnosis |
| --- | --- | --- |
| eunit-01 | 2 failures | Wrong resolution result expectation; nonexistent registry API |
| eunit-02 | 2 failures | Plain policy failures include automatic call frames; reused barrier required top-level context |
| eunit-03 | 1 failure | Simultaneous releases did not guarantee the single-writer conflict reason assumed by the assertion |
| eunit-04 | 1 failure | Exact reason-list assertion incorrectly excluded automatic call frames; race passed |
| eunit-05 | 1 failure | Undefined predicate discovery returns plain `fail`, not `{fail, Reasons}` |
| eunit-06 | 3 passed | Complete lifecycle, deterministic race and distinct-principal scenarios |
| regressions-01 | 154 passed | Relevant shared semantics and physics regressions |
| eunit-07 | 3 passed | Final diagnostic check ordering and explicit regression cases |

Both competing proofs are now parked after completing all staged admission work;
the second is released after the first commits. Its stale proof must produce
`conflict_retry`, and exactly one destination admits. Every parked worker is
monitored and cleaned up, including when preparation fails. No sleeps establish
ordering. Expected fault-injection warnings and deliberate ACL denial remain in
the logs; failed fixture directories printed by earlier runs were preserved.

## Accepted scope

The code adds organizational containment, exclusive physical admission,
withdrawal/revocation and anchored recovery semantics through existing owners.
Production grows by **143 Prolog lines**, because no generic governed-space path
previously existed. There is no new Erlang module, process, registry or execution
lane. Tests add 319 lines; current documentation adds 168 lines outside evidence.

Physical acceptance here is an explicitly unsimulated physical-space class.
Physics vocabulary is present during the no-allocation checks. The required
domain consequence rejects missing/refused physical composition atomically.
Entity/body bindings, simulation installation and actual body/constraint/checkpoint
cleanup remain the separately owned physics integration task. The code neither
copies colliders on containment nor claims transfer between independent
simulations. Existing subscription/resource tests passed; foreign collider
integration is not claimed by this evidence.

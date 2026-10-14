# Captured network context implementation

Read tree/AGENTS.md. Source-only review of before/ versus tree/; no commands,
tests or production edits. Save fable-review.md here. No further architecture
consultation: the corrected pre-batch invariant is accepted.

This slice replaces new/5 with new/6 (all real callers updated, no shim), captures
the trusted immutable root anchor from the existing content/vote acquisition,
and carries it into and out of the shared projection. Captured contexts never
consult readiness again. It does not add negative dependencies, change OCC
validation or acquire network in read-only plans. Those are subsequent work.

New production-seam tests exercise content and vote after root readiness loss,
request-network mismatch against captured trust, and a content batch whose first
unsigned transaction would write a fact but whose later signed transaction needs
network. Before availability, exact projection equality and absent facts prove no
partial application; after availability both apply; after readiness loss an exact
duplicate applies with the retained anchor. No index repair or history replay.

gate01: 27 tests/one failure, exit1. Fixture incorrectly seeded timestamp1 before
the shared committed_entry helper's timestamp0. Correctly rejected by immutable
time guard. gate01-test-source.erl preserved. Final fixture seeds timestamp0;
none of the behavioral assertions changed. gate02 affected suites running.

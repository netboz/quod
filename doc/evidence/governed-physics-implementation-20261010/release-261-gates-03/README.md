# Release261 gate03 stopped at EUnit

Native22, Clippy, client tests, UI build and lint passed. EUnit ran3,879 tests
with two failures, exit1. All frozen source hashes remained unchanged. CT,
xref, Dialyzer and packaging did not run.

The opening-worker cancellation test did not receive a DOWN with reason killed;
the original failure did not retain other reasons. Separate diagnostics are
investigating it without changing the deadline or accepting other exits.

The strict unchanged-source trace captured pwrite/datasync from a Simplex
signing journal registered in the unrelated e2e:6322 namespace. Separate real
owner diagnostics establish a non-parent teardown defect in that fixture.
This attribution is new evidence for this run, not proof of the earlier
unattributed release260 observation. The zero-work assertion is preserved.

Full raw logs, exact frozen inputs and child-exit receipts are retained. No
release deployment is authorized by this failed campaign.

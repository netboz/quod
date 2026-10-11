# Release260 test diagnostics

The first clean release gate stopped with two failures. This evidence retains
the failed diagnostic compile (01), the instrumented isolated checks (02),
the deterministic predecessor-custody reproduction (03), twenty source reads
per window across both identities and recovery (04), and the corrected queue
fixture's180 passing executions. All true child exits are recorded.

The queue defect was in its timing assumption: publishing a result precedes
the worker's actual exit and registry custody release. The test now checks
the legitimate second wait, and the forced-handoff case deterministically
proves that execution cannot bypass custody. No runtime behavior changed.

The source-read observation remains unattributed. The original trace retained
only pwrite/datasync MFAs; isolated passing checks do not identify their caller.
The current test preserves zero work and captures PID/caller/registered names
on any future failure. The complete second EUnit run passed3879 tests; that
pass does not retrospectively explain the first observation.

Fable found no blocker in the test correction. The independent disposition
checks its cleanup and journal-order hypotheses against production code.
Automatic review rejected a broader source/log packet; the actual completed
review used only a fixed48925-byte stdin packet of changed tests, bounded
source excerpts and synthetic test evidence, with all Claude tools disabled.
No live browser, world or credential files were sent in that review.

Read-only Fable review of the final frozen routing scope, 2026-10-07. No builds or tests were run by this reviewer. The parent independently checked the code and retains the full gate logs.

Verified. This closes the boundary review.

**Hashes.** All seven files in tree-04.json match the working tree byte for byte, the evidence copy under doc/evidence is identical, and the scoped seven-path diff hashes to exactly tree-04.patch (ac886ad8…). Directory control, the ask suite, the directory unit tests and the routing doc are unchanged from tree-03.

**The hunk.** `evidence_accept/4` now guards on `more | done`, keeps the parts validator, and both completeness clauses test `End =:= done`. The spec is narrowed to match. `fetch_evidence_pages` maps `done` to `done` and any pair to `more` in its consume fun and still recurses with the original continue query. The wire decoder and request validator are untouched, so `valid_transfer_continuation` keeps its two real callers. `range_accept` and `fetch_range` are untouched, as they should be. The two new exports sit inside the TEST block.

**The regression.** It drives the real path: a read-only snapshot of the source store, a captured phase index rather than a rebuild, a compacted authority, and the owner registered so the view liveness check passes. It explicitly requires the first page to return an opaque local continuation, which fails on a single-page fixture, so it proves the multi-page case rather than passing vacuously. It then runs the full page loop through the local adapter, checks the verified entry against the exact encoded expected entry, and checks the phase index stats are unchanged, which rules out hidden rebuilds. The negative wire case adds a local-shaped token to the page decoder's rejection list. The old helper now passes `more` instead of a fabricated nonce. Focused run 49 of 49.

**One minor note, no change required.** The regression registers the simplex name for the test process and unregisters in the after clause, so a failure mid-test cannot leak the registration into later tests in the same VM.

Verdict unchanged in kind: approve tree-04 for commit once gates-04 completes green and its logs are retained. Nothing further is open on this scope from my side. Finding 5, the self-pull transport cause, stays documented outside it.

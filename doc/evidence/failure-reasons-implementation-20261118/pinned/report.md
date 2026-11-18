# Published-pin validation

Engine commit `5dad08cdc95f5100f8885caa65038b0c6ee832f9` was committed through
the Nimbalyst widget and pushed to `netboz/erlog` branch `quod` after Yan
approved the push and pinned-build validation. Both dependency files name
that SHA. The development override and generated checkout beam caches were
removed. Removed 24 stale test dependency links to the old pearl-stone build;
only links inside this checkout were removed, not their targets. Rebar will
recreate dependency links against this checkout. The cache generated app-file
diff is retained before restoring that build output for dependency update.

The pinned candidate is validated. Quod commit/push approval and deployment
authority are separate; no deployment has occurred.

Both clean steps passed. EUnit passed 4,370 tests with zero failures in
981.535 seconds. Common Test passed all 150 cases. Xref and Dialyzer both
exited zero. All six sequential gate steps passed, with unchanged frozen
source hashes and lock pins.


The focused rendering case passed in **1.700 seconds**, under the unchanged
five-second limit. The final scene qualification passed **36 samples**, with
the expected verdict and zero reasons in every sample. Each of the six cases
runs three fresh proofs over reusable immutable initial state. Timing and
allocation samples use separate fresh VMs. The actual engine path resolves
through `_build/test/lib/erlog` to this checkout's normal published dependency.

| Scene | Marks | Median seconds | Median held MB | Median allocated Mwords |
| --- | ---: | ---: | ---: | ---: |
| valid | 300 | 0.332206 | 16.584 | 76.298 |
| valid | 600 | 0.845770 | 34.387 | 152.455 |
| valid | 1200 | 2.345937 | 71.303 | 304.949 |
| refused | 300 | 0.296643 | 0.089 | 75.719 |
| refused | 600 | 0.662090 | 0.231 | 151.169 |
| refused | 1200 | 1.689611 | 0.372 | 302.097 |

[Raw samples](scenes.json), [CSV](scenes.csv) and [grouped statistics](scene-summary.json)
retain first/repeated costs and observed ranges. Held MB is allocated process
memory after full GC with the result, input and initial state reachable; it is
not peak or VM-wide memory. Allocation is tprof-attributed machine words;
profiled elapsed times are not used for speed comparisons. This is a final
qualification run, separate from the earlier matched baseline/sharing campaign.

All authored engine source files still match the published commit after gates.
The only tracked cache difference is rebar's generated `ebin/erlog.app` module
metadata. The source/lock freeze check passed, and no checkout override remains.

Retained the complete CT run and logs, redacting 200 generated test private-key
values with line counts preserved. The post-redaction scan is clear. Removed
only this campaign's CT run tree and scene build folder after recording their
evidence, preserving all 43 pre-existing CT run directories.

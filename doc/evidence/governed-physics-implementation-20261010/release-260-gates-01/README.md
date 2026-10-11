# Release260 gate01 — stopped

Native tests, Clippy, client tests, UI build and lint passed. EUnit exited1:
3878 tests, two failures. Later gates did not run. Frozen source hashes stayed
unchanged. Full logs, exact inputs, runners and the original stop marker are
retained.

The queue test expected one blocker, but real result publication can precede
release of the predecessor's registered cache custody. A deterministic
held-worker diagnostic reproduces the second custody wait. The corrected
test verifies both legitimate dispatch stages and adds forced-handoff coverage.

The inactive physics source test recorded `file:pwrite/3` and `file:datasync/1`
in its VM-wide zero-work window. Its original trace retained no owner. Separate
isolated checks passed with2 and20 repeated reads/window, across two identities
and recovery. Those passes do not explain the original observation. The next
separately frozen campaign retains the assertion and adds PID/caller/registered
owner attribution; the observation remains unresolved pending that evidence.

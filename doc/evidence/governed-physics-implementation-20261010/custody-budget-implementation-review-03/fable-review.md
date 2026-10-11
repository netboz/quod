**Verdict: approve. The prior required correction is closed, and I found no remaining blocker.**

**Required correction, verified in the frozen tree**

- The post-admission expiry at `quod_runtime.erl:2746` now returns the interrupted completion, and the old `install_resource(..., {error, deadline_exceeded})` arm is gone. The worker result reaches the interrupted clause via the runner-done cast, so all three interrupt sources (budget already spent, worker down, post-admission expiry) share one path.
- That clause sets the internal key's basis to unknown, which is `#{parent => true}`. `affected/2` returns true for any change on a parent-fenced basis, so the next root commit of any kind re-queues the selector. A later successful external admission merges rather than replaces, so it cannot erase the fence. Liveness is closed without polling.
- Withdrawal now runs only for the root runtime and the internal custody key, and a failed withdrawal is logged instead of discarded.

**Governing-scope boundary**

- The foreign-namespace leak was real. Scope-probe-02 ran on the pre-correction code and recorded the configured pair becoming unconfigured. Probe-01's triage honestly records a harness mistake, not a reproduction.
- The regression uses the real runtime and journal owners, a real absolute deadline, and sys instrumentation only. The fixture namespace is not root, and the journal is the node-wide singleton, so it exercises exactly the leaked path. I accept that this window is deterministically testable; my earlier statement was wrong.
- The `install_resource` error arm is now root-only too. For a non-root namespace the selector yields `inactive`, so this arm is defensive and consistent.
- An external caller in root that expires after admission now leaves limits untouched with a merged basis. That matches the pre-feature behaviour, and the internal key keeps installed policy current, so one owner is preserved.
- `doc/README.md` is absent from the patch and the frozen manifest, as required.

**Evidence integrity**

- The tests-04 manifest hashes for `quod_runtime.erl` and the lifecycle test file match the frozen source manifest.
- EUnit reports 173 tests and 0 failures with child exit 0. The client run reports 14 files passing with exit 0. The count rose by exactly the one added test.

**One nonblocker, no action required before release**

The new test's limit assertion runs before the runtime is resumed, and its request comes from an external caller. So the namespace gate inside the interrupted clause, which protects a starved foreign-namespace internal custody key, is correct by inspection but not asserted directly. A later follow-up could add that assertion; it does not affect this approval.

Full release gate, candidate-only cold refound with ledger and journal wipe, and live acceptance remain outstanding as stated in the disposition.

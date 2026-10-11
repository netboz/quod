**Verdict:** the test diff is semantically sound and does not weaken assertions. No blocker on the test change. Failure (2) remains unexplained, and the supplied production excerpts point to one concrete candidate boundary gap, stated below as a hypothesis.

**Failure (1), queue observation**

- **The handoff is real production ordering.** The worker sends its result at `quod_foreign_log.erl:5123`, then sets attributes and ends its span, and the registry name lives until process exit. The owner demonitors in `finish_request` and starts the next request, which finds the name still held. Count 2 is legitimate, and the old count 1 was a race assertion. The held_exit mode pins the window deterministically. Good.
- **Accepting 1 or 2 in recorded and missing modes** is honest but means those two modes no longer pin timing. Acceptable since held_exit does.
- **Unbounded hold.** The hook's receive has no timeout. If EUnit kills the test process on its own timeout, the `after` block never runs, the worker stays wedged in `end_span`, and the registry name leaks into later tests in the same VM. Add a generous `after` fallback to the hook's receive. This is a safety bound, not polling.
- **Private SDK header.** Including `opentelemetry/src/otel_tracer.hrl` couples the test to the pinned SDK's internals. The existing with_tracer already does this, so it is consistent, but note it as pinned-version coupling.
- **The test pins a weak observation as correct.** For the custody blocker it asserts no trace link and `blocker_trace_available` false, and `blocker_job_id` names the waiter rather than the custody holder. For the active blocker the same attribute names the predecessor. That is inconsistent attribute semantics, and the holder is a process the owner just finished and could attribute. Record this as a production follow-up decision rather than freezing it as desired behavior without a note.
- **Design question, not for this scope:** whether custody should release before handoff so a finished predecessor never costs a successor a second dispatch. Leave it until the cache-install race between owner install and a successor writer is understood.

**Failure (2), unchanged source read wrote pwrite then datasync**

- **The test change is correct.** Caller attribution and pid capture add information only. One weakness: `gproc:info` runs after the barrier, so a transient process that already exited yields empty names. Resolve names in the relay at receive time instead.
- **Candidate boundary gap, unverified.** In `quod_simplex.erl:9676` the inner `resolve_committed_custody` runs first and the journal retire runs last in the same continuation. Each retire does one pwrite plus one datasync, exactly the observed pair. If the operation's terminal row is published from the inner call, the test's wait on `await_operation_complete` returns before that journal I/O lands. The excerpts do not show where terminal is published, nor whether the lobby fixture runs a file-backed journal rather than the TEST memory mode. Both must be confirmed before calling this the cause.
- **Alternative:** idle consensus voting also journals through the same function. If the leader proposes slots while the read runs, a VM-wide trace of all processes is not hermetic regardless of waits.
- **Passing reruns prove nothing here.** The four-window and twenty-read diagnostics only raise the odds of recurrence. The smallest useful diagnostic is to add `quod_signing_journal:retire_transaction/2`, `persist_mutation/2` and `compact/1` to the traced set with caller and pid, and record the tx id and slot, so the next recurrence names its owner directly.

**Evidence limits**

I could not see `span/2`, `lifecycle/2`, `start_next_request`, `close_worker_cache`, `resolve_committed_custody`, the terminal publication site, `complete_source`, or the fixture's journal configuration. The held_exit assertions depend on `span/2` consuming from the mailbox, which the 180 passes support but the excerpts do not show.

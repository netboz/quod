Review of the Release 261 test-only correction plan, from the excerpts only.

**Verdict.** The failure 2 diagnosis is correct and the fix is the right one. No blockers. Failure 1 has no cancellation defect visible in the supplied source, and the plan's stance of leaving it unexplained is right.

**Failure 2: confirmed from source**

- Each test body calls start_ns inside the test fun, so the supervisor's recorded parent is the test body process, which dies before cleanup runs. The unlink means the supervisor never sees that death.
- Cleanup runs in the fixture process. A shutdown exit signal from a non-parent reaches a trapping gen_server as a plain message. The supervisor's handle_info logs "received unexpected message" and ignores it. The 5000 ms silent fallthrough in stop_ns hides this every time.
- In-test restarts still worked because stop_ns was called from the same process that called start_link, so the signal matched the parent path. That is why the suite never noticed.
- Alphabetical EUnit order runs e2e before lobby before physics. Seven leaked single-node committees, each with its data directory already deleted under it, stay alive through both later modules. A journal write attributed to a registered e2e name in the lobby trace is exactly what that predicts.

The replacement with gen_server:stop and timeout 5000 is correct. It goes through sys:terminate, so it works from any process and runs the supervisor's ordered child shutdown.

**Required checks before trusting the fix**

- Search the other test modules for the same pattern. The stop_ontology helper in quod_agent_hosting_tests is not shown. One more leaking helper keeps the strict I/O gate flaky even after the e2e fix.
- Make the leak loud in cleanup itself. Monitor the child pids from supervisor:which_children before the stop and receive their DOWNs after it. This is deterministic and covers the non-parent teardown on every run without a separate test. Registered names clear asynchronously after death, so do not assert on names without an eventually wait.
- Check the retained gate 03 log for the supervisor "unexpected message" report from e2e supervisors. That confirms the diagnosis in the actual failing run rather than only in the synthetic reproduction.

**Optional for failure 2**

- The stop timeout of 5000 covers five children each with a default 5000 ms shutdown. A slow quod_simplex close would now fail cleanup loudly. That is the desired behaviour, but record the stop duration from the diagnostic run so a new flake is not a surprise.
- A dedicated non-parent teardown test is not needed if cleanup asserts child death.

**Failure 1: no defect found in source**

- The kill is unconditional. The timeout clause calls release, which executes exit kill on the opening pid before the reply is built. The test had already received that reply, so the kill signal was sent to the pid in the socket state, and the test monitored the same pid from the same state inspection.
- A missing DOWN after a sent kill leaves only three explanations: the worker was in uninterruptible native code, the test process itself stalled for 5 s, or the pid differed from what release killed. The source shows no path for the third.
- So no deterministic synchronization is missing from this test. Adding one would be a workaround for an unexplained event.

**Make the diagnostic distinguish those three cases.** When the DOWN is missing, capture:

- is_process_alive on the worker, plus process_info with status, current_function, current_stacktrace, message_queue_len, and monitored_by. A live worker in a NIF frame points at uninterruptible native code. A dead worker without DOWN points at the test process.
- A fresh simulation_state inspection, to compare the socket's opening pid with the monitored pid.
- The test process's own message queue, dumped in full, so "no other DOWN reason retained" becomes recorded rather than asserted.
- The prover pid from the local_proof_waiting message, which the test currently discards. Record whether it also dies on cancellation. If the proof runs in a separate process that survives the kill, each cancelled open leaves a proof parked on a snapshot. That would be a production finding to record, not to fix in this scope.

**Sequencing and the residual record**

- Running the physics module alone excludes e2e leaks by construction. If it passes and the fixed full gate passes, the leak remains an unverified candidate disturbance for failure 1. The record must say "not reproduced after an unrelated cleanup fix", not "explained".
- Keep the diagnostic armed in the standing gate so the next occurrence self-reports.

**Minimal further evidence to close Release 261:** one full clean sequential gate with the strict I/O assertion unfiltered, the e2e cleanup asserting child death, the other stop helpers checked, and the cancellation diagnostic in place. Plus the explicit residual entry for failure 1 as unexplained with the first-run log retained.

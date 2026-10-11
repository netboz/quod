# Review: renewal follow-up

**Verdict: GO for this follow-up.** I found no blockers. This was inspection only: I ran no tests, checked no hashes, and did not run the notifier because tools were disabled for this review.

## What the code shows

- **Fixture fix is correct.**
  - `open_request` decodes and validates the goal (`src/quod_client_simulation.erl:50-53`) before it decides between renewal and cleanup (`:56-68`). Empty request bytes therefore now end at `invalid_view_request` (`:72`).
  - The new fixture reaches the cleanup barrier through the real handler.
  - All earlier assertions are still there: one pending registration, both completion cases, and the clean final state. The new no-worker check is added on top (`test/quod_foreign_lifecycle_tests.erl:880-895`).
  - Nothing was weakened, and no error-precedence branch was added.
- **Removing `view` from inactive selections is safe** (`:329`). Acks need `pid`, `ref` and `tick` (`:43-45`), and frames need `pid` (`:422`). Neither exists on an inactive selection.
- **The different-session test tells the two paths apart.**
  - Renewal keeps `monitor` and `dependency_monitors`; the release path replaces both (`test/quod_physics_tests.erl:1456-1462`).
  - The timer assertion would pass on either path, so the monitor checks carry the proof.
  - Subscriptions are not asserted directly, although the handoff says they are tested.
- **The timeout test is sound.** It waits on processing evidence, not sleeps.
  - The gate parks physics before it handles the watch call.
  - The socket's `unwatch(old ref)` is queued behind that call, and the socket's DOWN behind the unwatch.
  - If the late watch had been refused, the unwatch would have cleared the viewer and flushed the DOWN. So seeing the DOWN, and then a successful `watch(...,none)`, shows the late registration was installed and later cleared through the retained monitor (`src/quod_physics.erl:73,150-153`).
  - The harness close path matches cowboy: close frame, then `terminate/3`, then normal exit.

## Non-blocking

1. **Duplicate check.**
   - The expiry test in `attach` (`:334-335`) repeats the one in `resume_projection` (`:284`) within the same handler turn. Only pure decoding and a registry lookup run between them, so the relabelled branch is effectively unreachable.
   - AGENTS.md says to remove duplicate validation. Leave `attach` as only the owner check, and keep the post-call check (`:349`).
   - That also brings the follow-up's production delta from +1 line to 0. The handoff does not report the delta.
2. **Same cause, two outcomes.**
   - When the old view's deadline passes during a renewal, the client gets `refresh expired` if the old timer message is handled first (`:427`, pinned at `test/quod_physics_tests.erl:1904`). It gets `unavailable expired` if a deadline check runs first (`:285`, `:359`).
   - Both paths release server state, so "fail-closed" does not distinguish them.
   - The only difference is in the browser: it re-opens on `refresh` (`client/src/simulation.js:151-156`) and stays failed on `unavailable` (`:157-158`).
   - Settling this after the recording is fine. A slow renewal can produce either outcome.
3. **Reason given for keeping `expires`.**
   - Keeping it is right, because the signed bound is wall-clock and is checked the same way as the candidate's own `Expiry`.
   - The stated reason doesn't hold, though. `erlang:read_timer/1` also detects expiry across a blocking call: it returns `false` once the timer fires, whether or not the message has been handled. "Independently of timer-message delivery" therefore doesn't separate the two options.
4. **The timeout test does not pin the renewal path.**
   - The test would also pass through a fresh open: the unwatch goes first, and physics then monitors an already-dead socket.
   - Matching `{watch,_,Previous}` with `is_reference(Previous)` in the gate (`test/quod_physics_tests.erl:1797`) would pin the replacement-monitor case the test is named for.
5. **Fable items the handoff doesn't mention:**
   - Socket-level `view_busy` and `unavailable` replies during a renewal. Only the exit case is now covered.
   - Whether the resolution text now says that a changed dependency set refreshes with `durable_gap` (`:147`).
   - Fable's stale-drive note cites `client/src/simulation.js:147` for `lastDrive`, but that file has no `lastDrive`. The "resends immediately" claim is unverified, so observing it in the recording is the right call.

## Still required

- A fresh, clean, sequential run of the full gates, with full logs and true exit codes. Keep the logs of the failed 3883-test / 2-failure run alongside it.
- Freeze the exact tree with that evidence, and keep the label bump in a separate commit.
- Deploy, then make the coordinated desktop renewal recording.

This GO covers the implementation follow-up only. It is not acceptance and not main-network promotion.

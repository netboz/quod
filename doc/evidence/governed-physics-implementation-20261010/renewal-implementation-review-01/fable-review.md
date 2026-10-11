I read the diff and the surrounding owners (socket, physics, browser client, tests) by inspection only. No commands were run and no runtime behaviour is claimed here.

**Verdict: GO for the implementation, with the two outstanding items (clean release gates, coordinated desktop renewal recording) still required before release.** I found no correctness blocker in the renewal path. Everything below is either a confirmed-covered obligation, a suggestion, or a test gap.

## Obligations I verified in the code

- **Old expiry stays armed; one worker.** `open_worker` arms `candidate_timer` only when installed (`src/quod_client_simulation.erl:82`); `view_opened` is accepted only while the old `timer` exists (`:410`), so a result arriving after release is dropped. Promotion cancels the old timer in `projection_deadline` (`:381`); release cancels both (`:549`).
- **Exact scope.** `Scope` keeps the whole decoded request minus operation id and deadline, plus session, world namespace and anchor (`:55`). Signing key, actor, mode, parser version and goal text are all inside.
- **Equal dependencies, fresh snapshots.** Renewal compares the sorted local plus foreign triples against the proof (`:140-147`), requires owners and anchors current (`:158`), then takes the ordinary `get_stats` snapshots without re-following. A snapshot at a higher height still goes to `durable_gap` (`:502`). Foreign follows stay governed by owner notices and the foreign-log pid check.
- **Expiry before and during attach.** `candidate_live` is checked before `open_view` (`:284`), before the watch call (`:334`) and again after it (`:348`); the post-call failure releases the returned reference via `release(Watched)`.
- **Unknown call outcome.** Exit from the call closes the socket with 1011 (`:364-368`); physics keeps the retained socket monitor on replacement (`src/quod_physics.erl:73`), so socket death clears any reference a lost reply installed.
- **Native replacement.** Ownership requires same caller pid, same previous ref and exact installed selection minus registration (`quod_physics.erl:64-69`). Inputs are untouched; registration rotates; credit false and tick reset. Wrong caller or ref gets `view_busy`, old acks and unwatch are fenced by ref. All asserted in `renewed_control_preserves_input_and_fences_registration_test_`.
- **Browser continuity.** `open()` no longer discards state; `discard()` only runs on refresh, unavailable, failure or close. Command epoch, discrete gate and sequence survive, and `sequence` only ratchets upward (`client/src/simulation.js:172-173`). Frames are matched on `current.view`, not `expected`. Controlled navigation keeps held keys because the binding key excludes view and registration.
- **Old callers.** `watch/2` is gone from the export list; all test call sites moved to `/3`, and the module compiled under eunit, so no stray `/2` caller remains. The old unconditional `release(S0)` in `command` is removed, not kept beside the new path.

## Suggestions (not blockers)

- **Stale drive refusal during the swap.** A drive command signed with the old registration that reaches physics after the replacement fails `stale_registration`. The browser resends immediately (`simulation.js:147` clears `lastDrive`), so motion continues, but `refused()` fires and the UI prints "Movement was refused." Expect this roughly once every few renewals while moving. The resolution accepts the refusal; whether the status line should show it is a UI decision. Watch for it in the desktop recording before deciding.
- **Changed dependency set discards a valid proof.** `install_dependencies` answers a mismatch with `refresh(durable_gap)` (`:147`), so the browser re-proves. The resolution described retiring the old projection and installing directly. The refresh is simpler and conservative; the cost is one wasted proof per real change, which is rare. Fine to keep, but the resolution text should match.
- **Unnecessary state.** `view` is stored on non-active selections (`:329`) and never read there. `expires` duplicates the armed timer's deadline; `erlang:read_timer/1` on `timer` would give the same liveness answer with one owner. Both are small.
- **Reason labels.** `attach` reports `owner_changed` when the real cause is old-view expiry (`:336`), and `resume_projection` sends `unavailable expired` where the old-timer path sends `refresh expired` (`:285` vs `:426`). The UI reconnects only on `refresh`, so the two races end differently for the user. Using `refresh` when `installed` is set would make them consistent.
- **Renewal cost.** Two signed proofs per 30 s view per viewer, plus one view-clearance query per watch. Accepted by the design; just noting it is now steady-state load.

## Test gaps worth closing

- No direct test that a same-socket open with a different scope (other mode, actor or session) takes the release path instead of `Renew`. The ordinary-views test changes the goal only after a refresh.
- No socket-level test of a renewal whose physics attach fails (`view_busy`, `unavailable`, exit). The physics side is covered; the socket's fail-closed handling of those replies is not.
- The foreign test asserts retention only. A certified height advance during a pending renewal should assert `durable_gap` so the comparison correction stays pinned.

I could not run the stop notification script because no tools were enabled this turn.

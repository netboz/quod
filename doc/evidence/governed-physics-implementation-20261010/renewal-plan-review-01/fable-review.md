Reviewing renewal-plan-01 against the supplied socket, physics, browser and test sources. No tools are available, so this is a source read, not an executed check.

## Verdict

**Conditional GO.** The ownership split, the "old expiry stays armed, late result cannot resurrect" rule, and the retained-subscription idea are right. Six concrete points in the plan collide with the supplied code and must be corrected before edits. Two plan items should be dropped as duplicated ownership.

## Blockers

**B1. The `open` command unconditionally releases the installed view.** In `quod_client_simulation:command/2` the first line is `S = release(S0)`. A renewal `open` would tear down exactly the view it is meant to renew. Smallest fix: enter candidate mode only when all hold: `installed` present, `dependencies_ready(S)` true, no `opening`, same stored session, and `view_request/3` yields the same `{Instance, Dependencies}` plus the same source anchor as installed. Otherwise fall through to the existing release path. Two consequences:
- The socket does not store the session today. `open_worker/5` passes it only to the worker. Store it in state at first open so the same-owner check is possible.
- The `dependencies_ready` guard matters because `detach/1` leaves `installed => true` in place after `dependency_recovering/2`. Without it a stale renewal could be treated as a candidate over a detached view.

**B2. The `timer` key is also the "this opening is still live" marker.** In `websocket_info({'DOWN',...}, S = #{opening := {_,Pid,M}})` the no-result branch checks `maps:is_key(timer, Clean)` and replies `proof_unavailable` with `release`. With an installed view the key is always present, so a candidate worker dying without a result would release the live view. The `view_opened` clause has the same `timer := _` guard. Smallest fix: keep the installed expiry as `timer`, add `candidate_timer`, and make both handlers test `candidate_timer` when `installed` is present and `timer` otherwise. On successful replacement cancel the old `timer`, promote `candidate_timer` to `timer`. Add `candidate_timer` to the cancel list in `release/1`. Because the plan only schedules renewal when the fresh read outlives the current view, the candidate timer can never fire while pending, so no handler is needed for that case.

**B3. `open_request/6` and `open_result/2` overwrite installed state.** `open_request` writes `namespace, anchor, source, source_anchor, instance, expected_dependencies` into the socket map. `open_result` resets `heights, owners, anchors, follows, dependency_monitors, dependency_names, local_ready` to empty without unsubscribing. In candidate mode the scope keys are identical by the B1 check, so overwriting them is harmless. The map reset is not. Candidate handling must branch before the `Pending` construction:
- Dependency set equal to installed `heights`/`anchors`: skip follow and snapshot entirely and call `open_view(Outcome, Digest, Expiry, S)` directly. The retained subscriptions already guarantee no advance happened, otherwise `durable_gap` or `dependency_owner_changed` would be in the mailbox and will be processed in order.
- Dependency set different with expected rows still matching: call `release/1` first, then the existing `Pending` path. Without the release the old monitors, runtime subscriptions and foreign follows leak.
- Expected rows mismatch: existing `refresh(S, navigation_changed)` is correct and releases everything.
- Any other failure, including `proof_unavailable`, `view_not_authorized_or_ready`, `invalid_projection` and physics `view_busy`/`simulation_failed`: drop the candidate and keep the installed view untouched. The installed view's authorization is its own signed proof, valid to its own expiry.

Also the `open_worker` error branch returns `maps:with([peer], S)`. Today that is safe because `command` already released. In candidate mode it would drop the whole installed state without cleanup.

**B4. Physics replacement must reset `credit` and `tick`.** The plan says retain "monitor, sequence and admitted inputs", which is right, but it does not say what happens to delivery credit. If a frame was delivered under the old ref and not yet acked, `credit = false`. After replacement the socket's `view` is the new digest, so the old ack hits `command(#{<<"type">> := <<"ack">>}, S) -> {ok, S}` and is dropped. Credit never returns and delivery stalls. The replacement clause in `quod_physics:handle_current_call/3` must do what the fresh clause at `src/quod_physics.erl:66-69` does: `tick => maps:get(tick, Frame), credit => false`. The browser acks the new projection's tick immediately, which restores credit under the new ref. Also update the `NeedsNavigation` pattern at `src/quod_physics.erl:50` for the new arity.

**B5. Browser message correlation and epoch.** Four things in `connectWorldView`:
- `open()` sets `current = null; expected = null; commandEpoch++; discreteSequence = null`. A renewal call must do none of these. Parameterize the open and keep a separate `candidateExpected`.
- `unavailable` messages carry no view id. The handler sets `current = null` and calls `unavailable(reason)`, which in `ui/src/World.tsx:167` pauses the scene. A failed candidate therefore clears movement, the exact symptom the plan fixes. The server knows whether the failure concerns a candidate. Smallest fix: add `candidate => true` to the reply when an installed view remains, and have the browser drop only the pending renewal in that case. A new message type is not needed.
- The `projection` handler assigns `sequence = BigInt(feedback.sequence)`. For a renewal it must take the max with the local sequence, or an in-flight command's number is reused and refused as stale.
- Do not increment `commandEpoch` on a renewal install. If an in-flight discrete command then fails uncertainly, the catch branch checks `epoch === commandEpoch`, swallows it, and `discreteSequence` stays set. `command()` then returns false forever because feedback never reaches that sequence. The existing contract is that an uncertain outcome clears the view, and renewal must preserve that, which is exactly the plan's "cannot be automatically resubmitted" rule stated from the other side.

**B6. `attach/7` creates a second monitor and releases on failure.** For a candidate, reuse the existing `pid`/`monitor` and pass the stored `ref` as the previous reference. Every failure branch in `attach` currently calls `release(S)` or `waiting(S, World)`. In candidate mode both are wrong. Treat all of them as candidate failure per B3. If the physics process registered under a new pid, the owner `DOWN` is already in the mailbox and will refresh the view after the candidate is dropped.

## Drop from the plan

**`watch/4` with `SignedExpiry`, and storing view expiry in physics (plan items 4 and 5).** The socket owns view expiry through its timer, and expiry already reaches physics via `unwatch` and `clear_viewer/1` at `src/quod_physics.erl:608-618`, which zeroes the controlled input's expiry. Admitted inputs are already bounded by their own signed deadline in `quod_physics:input/7` and in the check at `src/quod_physics.erl:120`. A second expiry check inside physics is a second owner of the same truth. Reduce to `watch(Pid, Expected, PreviousOrNone)`. Same calling socket comes from `From`, so it needs no argument. The replacement clause should require `viewer = #{pid := Caller, ref := Previous, expected := Installed}` with `Installed` minus `registration` equal to `Expected`, plus `current_projection` and `current_control`. Any other viewer state, including `none` when `Previous =/= none`, returns a definite error so the socket drops the candidate.

**"The browser immediately sends a fresh ordinary drive level" (item 5).** Not required for continuity. The retained input row keeps driving until its own lease expires, and `render` already resends every `lease / 2` at `client/src/controlled-navigation.js:145`, always with at least half a lease remaining. The resend uses the new registration once the projection is installed. Keeping `lastDrive` untouched is the minimal path. If kept, it is harmless.

## Verify before implementing

Two facts are not in the supplied sources:
- `current_projection/2` must not compare `registration`. Retained input rows keep the old registration in `expected` at `src/quod_physics.erl:123`, and `input_current/2` at line 464 depends on this to keep stepping across replacement.
- How a `{error, stale_registration}` from the staged `physics_input` effect surfaces to the browser. If it is `fail` with reasons, an in-flight drive at the boundary shows a brief "Movement was refused." and recovers on the next sample. If it is `error`, the browser clears movement and the fix is defeated. The existing test at `client/test/simulation.test.js:353` suggests `fail`, which is the safe shape.

## Tests the plan should add

- Server: candidate failure keeps `follows`, `dependency_monitors`, `pid`, `ref` and `timer` unchanged, and the browser-visible reply carries the candidate tag. Old-ref `physics_frame` and old-view `ack` after replacement are dropped. Delivery resumes after the new ack.
- Server: installed expiry firing while a candidate is pending kills the worker, cancels both timers, and a later `view_opened` for that ref is ignored. The harness in `test/quod_physics_tests.erl:1979` already supports this shape.
- Browser: `unavailable` with the candidate tag keeps `current`; an uncertain in-flight command during renewal still clears the view; sequence after renewal is the max of local and server.

## Docs in scope

`doc/physics-native.md:681-683` says inactive selections renew at authorization expiry, and lines 719-722 describe expiry handling without renewal. Both must change in the same scope.

## Not done

No tests were run and no files were edited. The stop notification script could not be invoked because no tools are enabled in this session.

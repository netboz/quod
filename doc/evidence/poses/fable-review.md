I'll re-read the endpoint, owner, tests and docs for the installation-wait expiry and failed-status changes, then give final findings.

Final findings against the current tree. Not an approval.

## Re-evaluation of finding 1 (durable advance tears the view down)

Classification: **not a correctness blocker for this bounded slice**. The evidence supports your reading. The native resource survives, `incarnation` and `installs` are unchanged across the appearance commit, `assert_no_physics_io` holds on repeated acks, and the re-opened projection carries the live pose, not the baseline. The task text names durable gaps as a fresh-projection case, and the signed answer exposes only a height, so a conservative teardown is a defensible first-slice choice. Two consequences remain and belong in the doc as chosen costs:

- **Cost per commit.** Each commit in the view's namespace costs a signature, a read-only proof and a watch. During a door close that is three commits (close request, custody, finish). On a busy namespace the view may rarely stay attached long enough to deliver frames. That is starvation, not incorrectness.
- **Visible blanking.** This is the part that still matters for the slice, and it is a client defect, not a server one. On `refresh` the client clears poses ([simulation.js:75](/home/yan/src/quod/client/src/simulation.js:75)), `World.tsx` calls `scene.simulation(null)` ([World.tsx:127](/home/yan/src/quod/ui/src/World.tsx:127)), and `paintBodyPoses` disables every body node until the next projection arrives. With the 30 s deadline kept, the door now blinks every 30 s and on every commit, including mid-close. The node test proves `paintMarks` keeps the transform, but the live path never reaches that case because the poses map is emptied first. world.md allows stale display as long as freshness is not claimed. Keep the last frame painted through a `refresh`, replace it on the next projection, and hide only on `unavailable` or close. This is a few lines in the client and I would treat it as required for the slice.

## New code since the last pass

- **Installation wait with absolute expiry** ([quod_client_simulation.erl:104](/home/yan/src/quod/src/quod_client_simulation.erl:104)). Correct. The timer uses the original signed deadline, is cancelled on release, and a stale timeout after release falls through. No retry timer.
- **Current-owner status filter** ([quod_client_simulation.erl:146](/home/yan/src/quod/src/quod_client_simulation.erl:146)). Correct and authenticated against the runtime and owner registrations. Two consequences to be aware of:
  - A `{failed, {owner_down, _}}` notice names a dead pid, so the current-owner check filters it out. A waiting viewer whose owner crashes sees nothing until the runtime installs a successor or the deadline expires. Acceptable, but it means `simulation_failed` is only reported for an owner that failed while still registered.
  - An owner already in `{failed, _}` at open time is registered, so `watch` returns `unavailable`, the handler waits, and no new status will arrive. The client waits the full deadline and then sees `expired`. One synchronous `status` call on the owner after an `unavailable` watch reply would report `simulation_failed` immediately. That is a single read of the current owner, not polling.
- **Tests.** The two added tests cover credit, revision invalidation, the signed endpoint, appearance, real door close, restart and revocation. Nothing exercises the waiting path, `waiting_expired`, `simulation_failed` or the attached-state `expired` refresh. Those are the new branches and should have at least one test each before the scope is frozen.

## Standing findings, unchanged

1. **30 s deadline.** Your decision, documented. The consequence is the blink above and a re-sign every 30 s. The ingress accepts any deadline up to session expiry ([quod_client_goal_ingress.erl:154](/home/yan/src/quod/src/quod_client_goal_ingress.erl:154)) if Yan later wants a longer-lived view without changing server semantics.
2. **World in the agent's own ontology.** Documented and consistent with the fixed unscoped goal. Fine for the slice.
3. **`physics_client_view/1` order** ([quod_physics.pl:13](/home/yan/src/quod/priv/ontologies/quod_physics.pl:13)). `physics_view/2` runs before `can_view_physics/2`. Swap them so an unauthorized principal does not pay for mark enumeration.
4. **Ambiguous answers** collapse into `view_not_authorized_or_ready` ([quod_client_simulation.erl:76](/home/yan/src/quod/src/quod_client_simulation.erl:76)). A distinct reason would help diagnosis.
5. **Unauthenticated idle socket** with `idle_timeout => infinity` ([quod_client_simulation.erl:15](/home/yan/src/quod/src/quod_client_simulation.erl:15)). Bound the idle time until the first authenticated `open`.
6. **Doc sentence** that the snapshot API is internal and not remotely authorized still sits above the new section ([physics-native.md:227](/home/yan/src/quod/doc/physics-native.md:227)). Reconcile it.

## Verified sound

Selection and authorization chain, owner credit semantics, clause ordering for viewer versus owner DOWN, subscribe-before-read with post-attach height check, pose filtering to the Prolog-authorized body set with contacts withheld, fixed bodies present in native frames so frame marks bind, client fence and tick validation with uint64 as decimal strings.

I did not touch memory, run the notifier, or build, as requested.

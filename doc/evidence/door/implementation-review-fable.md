**Verdict: not ready to commit.** The durable Prolog path is sound, but the simulator's observation state machine loses wakes in the ordinary competing-edit interleavings. Three of the four orderings of "obstacle edit vs pending observation" leave the door `closing` with no automatic exit; the existing test covers only the fourth.

This was a read-only review: nothing was executed or edited, and I did not run the stop notifier because of the no-commands instruction.

## Blockers

**B1. Lost wake when the selection arrives before an unsent result.**
- **Evidence:** [quod_physics.erl:419](/home/yan/src/quod/src/quod_physics.erl:419) resumes only for `unresolved`, `rejected` and `expired`. `stale`, `held` and `unsent` wait for a later selection ([:458](/home/yan/src/quod/src/quod_physics.erl:458)). A selection that lands while the observation is `offered` or `in_flight` is a no-op ([:463](/home/yan/src/quod/src/quod_physics.erl:463)).
- **Sequence 1:** sample S1 (structure 2) is queued; `physics_move_body` commits; the runtime sends selection 3; the queued item is then dispatched as `stale_observation` ([quod_runtime.erl:1348](/home/yan/src/quod/src/quod_runtime.erl:1348)). The basis has already changed and nothing re-evaluates it.
- **Sequence 2:** S1 is admitted to the actor; the edit commits and the selection is delivered; the store proof then fails and returns `unsent`.
- **Fix:** call `resume_observations` for `stale`, `held` and `unsent` as well. The existing basis comparison makes that a no-op when nothing changed.

**B2. Replacement after a verified rejection is one-shot.**
- **Evidence:** `expired` resamples only `when Custody =:= none` ([:455](/home/yan/src/quod/src/quod_physics.erl:455)); `stale`/`held`/`unsent` likewise ([:460](/home/yan/src/quod/src/quod_physics.erl:460)).
- **Sequence:** the finish is OCC-rejected and resolve confirms it; replacement sample S2 is offered while the rejected custody C1 is still stored; S2 expires in the queue or goes stale. No clause matches and the door stays held.
- **Fix:** with custody present, those states should call `resolve_door` again. The server re-confirms the rejection, then a fresh sample follows.

**B3. Certainly-unsent results are misclassified.**
- **Actor-queue expiry:** [quod_agent.erl:78](/home/yan/src/quod/src/quod_agent.erl:78) returns `{request_not_submitted, deadline_exceeded}`, which maps to `unsent` ([quod_physics.erl:407](/home/yan/src/quod/src/quod_physics.erl:407)), so there is no resample. It is reachable because capacity only needs fewer than 16 pending ([quod_runtime.erl:2084](/home/yan/src/quod/src/quod_runtime.erl:2084)); the expiry test fills all 16 and never admits. This contradicts physics-native.md ("expired unsent evidence requires another completed native step").
- **Match-side failures:** `{reaction_guard,_}`, `invalid_reaction_request` and `stale_executor` ([quod_runtime.erl:1353](/home/yan/src/quod/src/quod_runtime.erl:1353)) fall to `unresolved` ([quod_physics.erl:411](/home/yan/src/quod/src/quod_physics.erl:411)). With no custody, nothing ever resumes them.
- **Fix:** map deadline-unsent to `expired` and match-side errors to the `held` class. Keep `unresolved` for results after the actor started work.

**B4. An edit after custody but before the finish proof has no terminal outcome (needs Yan's ruling).**
- **Evidence:** outcome rows come only from ordered transactions ([quod_outcome.erl:549](/home/yan/src/quod/src/quod_outcome.erl:549), [:613](/home/yan/src/quod/src/quod_outcome.erl:613)), and absence resolves as `operation_pending` ([quod_client_goal_ingress.erl:266](/home/yan/src/quod/src/quod_client_goal_ingress.erl:266)). I infer from this that a proof-time failure records nothing; I did not trace the failure reply in `quod_prolog`.
- **Sequence:** the store commits; `physics_move_body` commits; the finish proof fails on structure. `physics_request_rejected` can never succeed, so the door is held until `physics_cancel_door` plus a new close.
- **Coverage:** the competing-edit test pauses inside the finish proof, which is the only ordering that produces a recorded OCC rejection.
- **Recommended fix, within the ruling:** let the exact original request retire its own custody. When `physics_finish_door` runs as the stored request but its sample is stale, it commits a custody retirement instead of failing. The server then verifies the exact request under consensus with no outcome-index read.
- **Alternative:** accept explicit cancel for this race, and pin it in the doc and a test.

## Outcome query versus `committed_snapshot`

- **Positive answers are sound.** They are digest-bound, same-ontology, immutable, and at or below both the pinned height and the durable floor (`committed_outcome` in [quod_physics_predicates.erl](/home/yan/src/quod/src/predicates/quod_physics_predicates.erl)).
- **Failure is not a snapshot function (High).** Timeout, engine unavailable, lagging floor and index error all collapse into `fail`, the same as "not rejected". The shipped rule only uses it positively, but `\+ physics_request_rejected(...)` would turn infrastructure failure into a proof branch. Fix: throw a typed unavailable error and keep `fail` for definite absence.
- **The class contract is not met as written (High).** [quod_predicates.erl:283](/home/yan/src/quod/src/quod_predicates.erl:283) says committed-snapshot reads go through the MVCC dependency machinery. This one is a live engine call, and the declaration skips live-bridge recording ([:367](/home/yan/src/quod/src/quod_predicates.erl:367)). Unless that contract is amended to name immutable outcome rows at or below the pinned height, this is a self-declared sealing exemption.

## Other findings

- **Medium: door status is not durably visible.** The world has one status slot ([quod_runtime.erl:608](/home/yan/src/quod/src/quod_runtime.erl:608)). A later `sleeping`, or another door's result, overwrites `{unavailable,{door_observation,…}}`. That also disables the reconcile re-send lever ([:2841](/home/yan/src/quod/src/quod_runtime.erl:2841)).
- **Medium: a failed resolve read has no retry edge.** A transient read timeout looks like `operation_pending`. If the outcome is already terminal, no notification will ever come.
- **Medium: a worker deadline kill before the store leaves `unresolved` with no custody.** Cancel is the only exit, and any runtime collapse stops all simulators ([:1770](/home/yan/src/quod/src/quod_runtime.erl:1770)), so overload can create the same hold.
- **Medium: world.md contradicts the chosen contract.** [world.md:350](/home/yan/src/quod/doc/world.md:350) and [:422](/home/yan/src/quod/doc/world.md:422) say old-run cursors retire on fence close and a pending R resumes on a fresh level. Update it to the ruling.
- **Low:**
  - The `applied_operation` fix matches the raw rows ([quod_outcome.erl:800](/home/yan/src/quod/src/quod_outcome.erl:800)), but it changes a shared gate and needs its own regression test and commit scope.
  - `door/1` re-verifies a signature per custody row on every selection ([quod_physics.erl:341](/home/yan/src/quod/src/quod_physics.erl:341)).
  - The runtime now receives every block's change map, even with no doors ([quod_runtime.erl:494](/home/yan/src/quod/src/quod_runtime.erl:494)).
  - `wake_physics` sets status `activating` on an active world ([:2880](/home/yan/src/quod/src/quod_runtime.erl:2880)).
  - The observation basis omits `budget`.
  - `blocked` means any non-frame contact, so a floor or door-stop counts.
  - An angle slightly past baseline fails the measurement permanently.

## Test gaps

- Edit while the sample is queued, edit between match and store, and edit between store and finish proof.
- Actor-queue expiry with 1–15 pending.
- A replacement sample that expires or goes stale after a verified rejection.
- Restart where the original is later rejected; this is the only path that needs `physics_outcome_changed`, and it has no negative control.
- Two doors, one unresolved, with status retention.
- `physics_request_rejected` under timeout and under negation.
- Native: drive a hinge after the leaf has slept.

## Not verified

- The `quod_prolog:outcome_snapshot` implementation, and whether the publication follows the outcome flush.
- Whether `verdict` proofs could call the new predicate from inside the engine process.
- Whether `quod_agent_observer:handle` tolerates the new 4-tuple outside live mode.
- Rapier joint wake semantics.
- The archived pinned rulings: I read the compact multiwrite map only.

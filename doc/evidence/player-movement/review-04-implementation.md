# Player movement review 04: implementation (Fable, consultative, read-only)

Date: 2026-10-07. Target: the uncommitted working tree on `master` at
`0e5b887` plus the collision/control implementation (79 changed files, 2293+/921-).
Files read: `priv/ontologies/quod_physics.pl`, `src/quod_physics.erl`,
`src/predicates/quod_physics_predicates.erl`, `src/quod_runtime.erl`
(navigation guard), `src/quod_client_simulation.erl`,
`native/quod_physics/src/{geometry,motion,lib}.rs`,
`client/src/{locomotion,controlled-navigation,simulation,world-scene,signed-client}.js`,
`ui/src/World.tsx`, the proof-path diffs in `quod_prolog`, `quod_proof_scope`,
`quod_proof_session`, `quod_proof_context`, `quod_scope_session`,
`quod_proof_savepoint`, `quod_erlog_db_local_prove`, `quod_effect`, ingress and
wire, `doc/physics-native.md`, and the new tests in `quod_physics_tests.erl`
and `quod_physics_control_tests.erl`. `AGENTS.md`, `world.md` and
`multiwrite-architecture.md` re-read; neither contract doc changed in this tree.

No file outside `doc/evidence/player-movement/` was edited. No build, Erlang or
Cargo run was launched. Severity: **High** = wrong result or security hole
in a normal path; **Medium** = correctness or cost defect in a reachable path;
**Low** = robustness, consistency or UX. Each finding states what the code does,
the concrete scenario, and the smallest fix. "Unverified" means I could not
confirm without running it.

---

## 1. Verified sound

- **Transient effect lifecycle.** `stage_transient/2` only accepts an overlay
  with `transient_allowed`, `signed_request`, `read_only`, `transient = none`
  and `write_intent = ordinary` (`quod_erlog_db_local_prove.erl`). The flag is
  set only when the signed request mode is `control`
  (`quod_prolog.erl:run_pinned_origin`, `verify_scope_authentication`), so
  `read`, `execute` and `cursor` cannot stage. The slot lives in `#lp{}` and
  `#checkpoint{}`, so savepoint restore and failed branches discard it;
  `enter_read_only` clears `transient_allowed` so negation frames refuse
  staging outright. Release happens in `finalize_request_result/3` only for
  `{ok,_,_,_}` after `finalize_pinned_result/1` succeeded, through
  `quod_effect:release_transient/2` to the local owner. A second transient in
  another scope yields `multiple_transient_effects`. The origin scope is in
  `ctx.scopes` (`quod_prolog.erl:4380`), so a self-world control goal is
  released too. Read-only contexts never seal (`seal_material_scopes/1`).
  The test `signed_control_releases_only_successful_proof_test_` covers
  failure, disjunction, negation, cut and double staging.
- **Ordinary read semantics preserved.** `physics_client_control/2` under
  `control` mode stages nothing; `release_transient(none,_)` is `ok`.
- **Principal and policy.** `physics_input_projection/8` proves
  `current_principal/1`, the current `physics_control/4` epoch, the grant via
  `physics_agent_configuration/5`, motion schema, speed/turn bounds and
  `physics_body(..., controlled, ...)` before the bridge stages. The frame term
  must unify with the committed `physics_frame/6` including run token and
  structure. The Erlang continuation is reachable only through the opaque
  `register_action_request` handle.
- **Owner admission.** `physics_input` requires current projection, control in
  the installed `agent_controls`, unexpired, `Sequence > highwater`, the
  viewer's own registration bound to the same control, and no pending discrete
  command. Inputs are keyed by principal and survive disconnect with
  `expiry = 0`, so a reopened view starts above the retained sequence. A
  released binding drops the row, and a new epoch defeats old signed bytes.
- **Navigation guard.** The runtime bumps one atomic on any committed change
  affecting the `physics_worlds` basis before reselection
  (`invalidate_physics_navigation/2`); the owner refuses `watch`, `body_state`,
  `motion_query` and `physics_input`, and `advance_inputs` skips rows, until a
  spec carrying the new generation installs. `project_physics` also refuses a
  superseded selection. This closes the pre-installation window I described
  in review-02 R1 down to message latency between `quod_prolog` and the
  runtime. Control-only reinstalls now notify `installed` (review-02 R2 fixed).
- **Endpoint.** Goal text is parsed and canonically compared to the anchored
  view goal; both source and world namespaces are subscribed before the read;
  all heights are rechecked after attach; the controlled body is projected
  without a mark; other principals' feedback is filtered out.
- **Native.** Occupancy, straight and nonlinear casts, slide, landing, view
  clearance, `query_ready` after install, revision/kind checks, conservative
  rotation bounds, `apply` updating collider pose and broad-phase AABB so a
  second agent in the same step sees the first. Dynamic obstacles are not
  pushed (`movement_stops_before_dynamic_objects_without_pushing_them`).
  Geometry budget charged for unchanged bodies.
- **Client.** One request in flight, no retry after an uncertain reply,
  teardown on refusal, sequence derived from server feedback, drive coalesced
  and re-sent at half lease, no Babylon translation inputs in the physical
  view, default XR teleport disabled.

---

## 2. Findings

### F1. Medium (unverified): resting dynamic contact freezes a controlled agent

`motion.rs:solve` runs `space.occupied(pose)` before every travel, teleport
and at the end of sliding. `occupied` flags any collider whose contact
distance is below `-tolerance`, including **dynamic** bodies. Rapier resolves
kinematic-versus-dynamic contacts leaving up to `allowed_linear_error`
(default 1 mm scaled by `length_unit`) of penetration. The fixtures use
`query_limits(2,0,...)`, tolerance 0.

Scenario: a closing door leaf (motor driven, dynamic) presses into a standing
agent; `brake_hinges` stops it one step after contact. The leaf now rests
against the agent with sub-millimetre penetration. Every subsequent drive,
snap or teleport from that agent returns `occupied(Leaf)`; the pose never
changes; the human is stuck unless `reposition` is granted. Same for a crate
settling against the agent under gravity.
`idle_compound_agent_blocks_moving_door_test_` asserts the agent did not move
but never drives it afterwards, so this is not covered.

Fix options, smallest first: document that policy tolerance must exceed the
engine's allowed penetration and set the fixtures accordingly; or exclude
`Kind::Dynamic` colliders from the occupancy precheck while still treating
them as sweep obstacles (the sweep already stops at skin distance, so the
agent can only move away from them). Add a test: door brakes on agent, then
agent drives away.

### F2. Medium: wedged grounded agent keeps the simulator awake indefinitely

`advance_input/3` sets `falling` when the clipped result has no contact
normal above the grounded threshold. `inputs_active/1` keeps the step timer
running while any row is `falling`. If the downward sweep is cancelled by
sliding (two facing walls, a crack, a ledge edge whose only contact normal is
horizontal), the pose does not change, `Grounded` stays false, `falling`
stays true, and `vertical` accumulates `gravity*dt` every step with no
terminal velocity. The world steps at the configured rate and runs a native
sweep per step with zero motion until `(pose+travel)` exceeds the coordinate
allowance and the answer becomes `Invalid` (minutes to hours). This breaks
the "repeated unchanged work reuses retained state" obligation for a
reachable configuration.

Fix: treat a clipped answer with zero displacement as settled (`falling =
false`, `vertical = 0.0`), or cap `vertical` by a policy terminal speed and
stop after N steps without progress. Add a test with a wedge.

### F3. Medium: gravity stops after any committed change

`handle_info({physics_invalidated,...})` calls `suspend_input/1` on every
row, which sets `falling = false` and `vertical = 0.0`. On reinstall with an
unchanged control, `install/2` keeps the row as is. An agent mid-air when
anybody commits a physics-affecting change (a bind by another human, a door
close, a body edit) hangs where it was until its own next drive command.
`physics-native.md` says the selected mode continues its mechanical behaviour
including gravity. Disconnect (`clear_viewer/1`) correctly keeps `falling`;
invalidation does not.

Fix: in `suspend_input/1` keep `falling` and `vertical`, only zero expiry and
pending; or on reinstall with the same control set `falling = true` for
grounded modes and let the next step settle it.

### F4. Low: client offers teleport in `free` mode, server refuses, view torn down

`physics_allowed_input(teleport(...), grounded(_), ...)` is the only teleport
clause. `locomotion.js:readControl` enables `teleport` from capabilities
regardless of mode, and `controlled-navigation.js:teleport` sends it. The
proof fails, `simulation.js:command` treats a non-`ok` reply as a reason to
`failed(...)`, and the whole view is torn down for a certain, deterministic
refusal. Gate the client on `grounded`, and consider reporting certain
refusals (proof `failed`) as feedback instead of teardown; only uncertain
replies need the suspend-and-refresh behaviour.

### F5. Low: endpoint does not enforce a local signer and loops on a remote one

`quod_client_simulation.erl:command({open,...})` checks locality only for the
world. For a foreign signer whose ontology is not local,
`quod_prolog:applied(Source)` returns 0 (`quod_prolog.erl:873-877`), `Owners`
gets an `undefined` key, ingress forwards the read over the network, the
answer height is non-zero, `attach` fails the height check and sends
`refresh`; `World.tsx:refreshing` bumps the revision and reconnects at once.
Result: a tight loop of forwarded signed reads bounded only by ingress rate
limits. The doc states both must be local; enforce it with
`quod_client_goal_target:available({Source, SourceAnchor}) =:= ok` before
subscribing and reply `local_authority_required`.

### F6. Low: ambiguous binding degrades silently to a spectator view

`physics_client_view/1` sets `Control = none` whenever
`physics_control_configuration/4` fails, which includes a *bound* principal
whose agent, body or viewpoint definition is ambiguous or whose body revision
is unique but the `physics_agent` row is duplicated. The human sees a working
spectator view with no indication the binding is broken, while the plan says
ambiguous configuration fails closed. Distinguish `none` (no binding) from a
visible `invalid_binding(Epoch)` so the client can say so.

### F7. Low: reposition rotation is unbounded while the doc says pi per component

`physics_absolute_input(reposition(Pose), Coordinate)` passes `Coordinate` as
the rotation bound, so Euler components up to the coordinate allowance in
milliradians are accepted and the native `place` builds any finite rotation.
Mechanically harmless (angles wrap), but `physics-native.md` states the native
rotation query accepts at most pi per component. Either bound place rotation
by `physics_query_allowances` `Turn` or scope the sentence to travel.

### F8. Low: `instance_of(agent, Agent)` is a direct membership test

`physics_agent_configuration/5` requires a direct `instance_of(agent, Agent)`
fact. If a world declares its characters as instances of a subclass
(`instance_of(pilot_class, X)` with `isa(pilot_class, agent)`), binding fails
unless `instance_of/2` in that ontology is closed under `isa/2`. Verify which
convention the world templates use; if closure is expected, use the shared
closure predicate rather than the raw fact.

### F9. Low: idle controlled agents run a native sweep every step while the world is awake

`advance_inputs/1` evaluates every input row on every step. With an expired
drive and `falling = false`, a grounded row still issues `move_body` with a
small downward travel (`gravity*dt*dt`) each step whenever the world is awake
for another reason (a moving door, a settling crate). Cost is N agents times
one sweep per step, not an unbounded loop. Skip rows with zero travel, not
pending and not falling.

### F10. Low: XR calibration cancels the full head rotation

`controlled-navigation.js:render` calibrates `trackingOrigin` with the
inverse of the headset's full rotation (pitch and roll included). The authored
viewpoint orientation is therefore only honoured if the human is looking level
at calibration time; a tilted head makes the mount tilt. Cancel yaw only, or
map the XR reference frame rather than the head pose. Cosmetic until Vive is
validated.

### F11. Low: self-ask cut semantics changed globally

`quod_ask.erl:do_ask` now wraps a same-namespace `Ns::Inner` in `call/1`,
making a cut inside `Inner` local. Any existing ontology clause that relied on
cut transparency through a self-ask changes behaviour. Unrelated to physics
but in the same tree; confirm no shipped rule depends on the old behaviour.

---

## 3. Contract and doc consistency

- `physics-native.md` "Both the signer's ontology and the selected world must
  be local": only the world is enforced (F5).
- "The selected mode continues its mechanical behavior (including gravity)":
  violated after invalidation (F3).
- "Occupied destinations ... leave the pose unchanged": correct, but the doc
  should say that resting dynamic contact deeper than the policy tolerance also
  counts as occupied, and what tolerance is safe (F1).
- "The native rotation query accepts at most pi radians per component":
  travel only (F7).
- The navigation guard is one atomic per runtime: any commit touching the
  `physics_worlds` basis (including another principal's bind or release and
  every `physics_control` change) suspends all inputs and refreshes the viewer
  for every world in that namespace until reinstall. Correct and conservative;
  it belongs in the doc as a stated cost, as does the still-single viewer
  slot, which means one controller per world in this profile.
- Rapier penetration defaults (`normalized_allowed_linear_error`,
  `integration_parameters.rs:266`) are the real lower bound for
  `PenetrationToleranceMm`; the doc gives no guidance.

---

## 4. Client XR limitations (reported by the parent, confirmed from code)

- `isSessionSupported('immersive-vr')` is false on the gate host, so the
  calibration, per-frame rig reparenting (`eye.parent = trackingOrigin`),
  `trackingState` masking, left-grip travel, pad-click snap/teleport and
  haptic pulse paths have never run on hardware. Babylon's `WebXRCamera`
  updates rig cameras from XR poses each frame; parenting them is supported
  in current releases but must be seen on the Vive.
- `enterXRAsync('immersive-vr','local-floor')` plus origin calibration is
  coherent; `local` would avoid the floor-height dependency but is not required.
- The teleport gesture flattens the controller ray and targets the last
  delivered body position; the server validates, so staleness is safe.

---

## 5. Tests worth adding before freezing the scope

1. Door brakes against a standing agent, then the agent drives away (F1).
2. Agent wedged between two walls: simulator sleeps within a bounded number
   of steps (F2).
3. Agent in the air when an unrelated physics commit lands: it still lands
   after reinstall without a new drive (F3).
4. Simulation `open` with a non-local signer namespace returns
   `local_authority_required` without forwarding (F5).
5. Bound principal with a duplicated `physics_agent` row: the view reports
   the invalid binding rather than `none` (F6).

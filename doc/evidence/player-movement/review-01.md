# Player movement review 01 (Fable, consultative)

Date: 2026-10-07. Scope: `doc/player-movement-plan.md` as on disk at review
time (377 lines, including the "Concrete first profile for review" section),
checked against `world.md`, `multiwrite-architecture.md`,
`runtime-and-agents.md`, `physics-native.md`, the five ontologies, the three
Erlang modules, the three client modules and `native/quod_physics/src/lib.rs`.
Archived `client-world-direction.md` §4.3 was read only for the acting
identity / controlled character / Eidolon distinction.

No production file or the plan was edited. No build or test was run. Every
"EXISTING" statement below cites the code it was read from; every
"RECOMMENDATION" is advice to be checked against the code before use.

Legend: **EXISTING** = what the tree does today. **GAP/BLOCKER** = the first
profile cannot be correct without it. **RECOMMENDATION** = the smallest
contract I would adopt. **OPTIONAL** = can be deferred without breaking the
profile.

---

## 1. What exists today (EXISTING)

### Principal and admission

- The signed request selects the principal, `agent_instance_ref(Ns, Anchor, I)`.
  `can_invoke/4` in the target ontology is the only ACL; foreign `::` scopes
  carry the same principal and apply their own `can_invoke/4`
  (`src/quod_client_goal_ingress.erl` moduledoc, lines 4-14).
- `human_user_instance.pl:7` admits the human instance for any goal in its
  own namespace. The world ontology therefore decides, by its own
  `can_invoke/4`, whether a foreign human may call `World::Goal`.
- A world already stores a foreign principal's full ref as a fact:
  `lobby_owner(Principal)` in `lobby_instance.pl:4`. That is the precedent for
  `physics_control(World, Principal, ...)`; nothing new is needed to name a
  foreign human inside a world.
- There is no delegation, no `subject/3`, no second signer. A controlled
  agent does not need keys or an `agent_host` row: `agent_hosting_projection`
  (`agent_instance.pl:11-18`) only hosts instances that have an `agent_host`
  row, so a classed instance without one is an ordinary domain object.

### Physics ontology and owner

- `physics_body(W, Id, Rev, fixed|dynamic, vector(X,Y,Z), box(Hx,Hy,Hz), Density)`
  is the only body row (`quod_physics.pl`, `physics_projection/2`). The
  authored baseline has **no orientation** and **no shape other than one
  cuboid**. The native `Body` type is `(u64,u64,bool,xyz,half-extents,density)`
  (`lib.rs:16`) and `install` sets only `translation` (`lib.rs:138`).
- The only joint is the vertical hinge, the only checkpoint is
  `hinge(D,Rev,Gen,Tick,Angle)`. There is **no body-pose checkpoint**. A fresh
  run restores hinge angles and resets every other body to its authored
  baseline with zero velocity (`physics-native.md` "Owner and recovery",
  `lib.rs:install_hinges`).
- `physics_move_body/5` is a durable baseline edit: it bumps the world
  structure revision and the body revision; installation resets that body to
  the new baseline. It performs **no occupancy check** and takes no
  orientation (`quod_physics.pl` bottom third).
- The door path is the only authenticated observation lane: owner samples →
  runtime matches `react_on(observed(Sample), ...)` with
  `physics_observation/1` metadata → authority actor stores the exact signed
  bytes (`physics_store_door_request/5`) → submits `physics_finish_door/2`
  (`quod_physics.pl`, `quod_physics_predicates.erl`, `quod_runtime.erl:574-600`).
- `quod_physics` holds exactly **one viewer** (`viewer = none | #{...}`,
  `watch` replies `view_busy` to a second). Unknown calls return
  `{error, unavailable}`. There is **no input or control registration of any
  kind**. The only inputs that reach the owner are the committed selection
  (`physics_selected`), its own work results, and `physics_ack`/`physics_unwatch`
  from the socket (`src/quod_physics.erl:40-115`).
- When the selection changes without a run or structural change, `install/2`
  takes the `{_,0,Frame}` branch: it updates the retained frame's structure
  and, if the structure is unchanged, does **not** deliver a frame, does
  **not** notify `installed`, and does **not** touch the viewer
  (`src/quod_physics.erl:168-183`). Only `install_controls` reconciles door
  controls against the new spec.
- `brake_hinges` stops a driven leaf on any active contact with a non-frame
  collider (`lib.rs:brake_hinges`), and `physics_door_result/7` turns that into
  `blocked(Other)` provided `physics_body(W, Other, Revision, ...)` exists. A
  controlled agent that is a `physics_body` row therefore already blocks a
  closing door through the existing path, with one caveat in §4.

### Simulation endpoint

- `quod_client_simulation.erl:40-55` accepts only the literal goal text
  `physics_client_view(View).`, in read mode, and requires the **signer's**
  namespace to be local (`local_authority_required`). It subscribes to the
  **signer's** `{runtime, Ns}` and `{physics, Ns}` and compares the answer
  height with `quod_prolog:applied(SignerNs)`.
- `physics_client_view/1` requires `current_ontology_identity(Ns, Anchor)` to
  equal the world ref. So today the view works only when the signer's
  ontology **is** the world ontology.
- Each world commit retires the view (`durable_gap`), and the signed
  deadline is chosen by the client; ingress accepts any deadline up to the
  session expiry (`quod_client_goal_ingress.erl:154`). This was already
  recorded in `doc/evidence/poses/fable-review.md`.

### Client

- Desktop: a `UniversalCamera` with WASD and pointer lock moves the camera
  directly (`navigation.js`, `world-scene.js:49-57`). Nothing is sent to the
  server.
- XR: `createDefaultXRExperienceAsync({ floorMeshes })` with the lobby floor
  marks and `enterXRAsync('immersive-vr', 'local-floor')` (`world-scene.js:195-213`).
  That is Babylon's default teleport-on-visual-floor; it is the "visual-floor
  teleport permission" the plan says must be replaced. The touchpad/thumbstick
  press already opens the radial menu (`bindRadialControl`); locomotion will
  compete for the same component on the Vive wand.
- `simulation.js` validates fence/tick/body set per frame and never moves a
  body on a stale fence. It has no input path.

---

## 2. Blockers for the first profile (GAP/BLOCKER)

Each one is a concrete missing capability traced through the existing owners.

**B1. Foreign human cannot open the simulation view.** The endpoint pins the
goal text, the signer's locality and the signer's height watch. The plan's
requirement ("accept a bounded anchored world read under a foreign human
principal through ordinary ingress") needs: a scoped goal
`World::physics_client_view(...)`, subscription to the **world's** namespace
before the read, and the locality check applied to the world (from the
answer's `world_ref`), not to the signer. The signer's ontology may be on
another node; ordinary ingress already forwards it. The browser must still be
connected to the world's host node because the owner pid must be local.
Height: the answer height is the signer's; for the world use "any world
advance observed after subscription retires the view" (conservative, correct,
same cost as today).

**B2. No controlled body kind, no orientation, no shape beyond one cuboid, no
sweep query.** The native adapter needs: (a) a third body kind
(`controlled` → Rapier kinematic position-based); (b) baseline orientation in
the body row; (c) at least ball/capsule parts, since the plan's first example
is a "compact rounded body"; (d) several collider parts per body (Rapier
attaches multiple colliders to one rigid body, no compound-shape machinery
needed); (e) a rotation-aware sweep. A translation-only `cast_shape` fails the
plan's "fits at both endpoints but hits a wall while turning" obligation;
parry's nonlinear shape cast (`NonlinearRigidMotion`) covers rotation and is
exposed through Rapier's query pipeline. Verify the exact 0.36 entry point and
measure it; this is the one API whose cost is unknown.

**B3. Owner has no registration and does not reconcile viewers on
control-only selection changes.** Three concrete points in `quod_physics.erl`:
the single viewer slot; the `{_,0,Frame}` install branch (§1) which would let
a revoked or switched controller keep its registration until the next
structural change; and the absence of any `installed`-class notification on
that branch, so a viewer `waiting` for the new control never wakes and waits
to expiry. Registrations must be reconciled in `install/2` exactly where
`install_controls` reconciles doors, and a control-only change must notify.

**B4. Durable placement with occupancy validation cannot be one proof.** A
proof cannot read live native state (sealing rule, `world.md` "oracle
boundary"). `physics_move_body/5` validates nothing against moving doors or
other agents. A "spawn/reposition with full-shape placement validation"
therefore has the door's shape: an authorized request transition, the owner
validates against installed state (full configuration, destination
orientation), the authority signs the sampled result, and one transaction
commits either the new baseline + revisions or an explicit
`invalid_placement` outcome. Two committed transitions, exactly as grab/release
in `world.md`. The plan currently reads as if the edit itself validates.

**B5. Restart respawns every controlled agent.** With no body-pose checkpoint,
actor death, runtime collapse, host move or any changed body definition
resets a controlled body to its authored baseline. That is permitted by
`world.md` ("rollback to the checkpoint/baseline is observable and allowed")
but it must be stated as the profile's behavior, and the first executable
obligations should include it. The exit is a body checkpoint
(`physics_checkpoint(W, body(Id, Rev, Gen, Tick, Pose, Velocity))`) written
by the authority under a Prolog cadence policy. Optional for the slice, not
for the contract.

**B6. Grant revocation must be captured as a projection dependency.** If
`can_control_physics_agent/3` is evaluated only inside the bind action,
retracting a grant does not change `physics_control/4` and the runtime never
re-selects. The world projection (`physics_projection/2` or a sibling) must
evaluate the grant for every stored control row so the selector's read set
carries it; the runtime already invalidates resources on observed predicate
dependencies (`agent_instance.pl:11` comment, `quod_runtime.erl` selectors).

---

## 3. Smallest contract I would adopt (RECOMMENDATION)

### 3.1 Ontology (world-owned, local to the world)

```prolog
%% Physical definition of a controlled instance. Body is a physics_body id.
physics_agent(World, Agent, Revision, Body, Motion).
%% Baseline gains orientation and parts; one cuboid stays valid.
physics_body(World, Id, Rev, fixed|dynamic|controlled,
             pose(vector(X,Y,Z), euler_mrad(RX,RY,RZ)),
             box(Hx,Hy,Hz) | parts([part(Shape, pose(...)), ...]),
             Density).
%% Camera: position and orientation relative to a body of the agent's group.
physics_viewpoint(World, Agent, Name, Body, transform(X,Y,Z,RX,RY,RZ), Tracking).
%% One selection per principal per world; epoch never reused.
physics_control(World, Principal, Epoch, none | controlled(Agent)).
can_control_physics_agent(World, Principal, Agent).      % policy, default fail
can_use_physics_viewpoint(World, Principal, Agent, Name). % policy, default fail
```

Why these shapes:

- `pose/2` with Euler millirads in the rendering order (X, then Y, then Z,
  `quod_rendering.pl:1-3`) keeps one rotation convention across marks,
  hinges (already mrad) and bodies. Integers only, as every descriptor.
- `parts/1` is a list of (shape, local pose) on one rigid body. That is the
  asymmetric compound of the plan without joints. Articulated agents are
  OPTIONAL and need explicit joint rows, as the plan says.
- `transform/6` for the camera is the existing `relative(Parent, transform(...))`
  vocabulary of `mark/7`. The client builds the camera node as a child of the
  body's pose node; the camera follows the body's current transform for free.
  A "component" camera on a rigid compound is a body-relative transform
  composed with the part offset; only a jointed component needs a second body
  id, which the same row expresses by naming that body.
- `Tracking` minimal form: `tracking(Look, Turn, Offset)` with
  `Look ∈ {view_only(YawMrad, PitchMrad) | fixed}`,
  `Turn ∈ {view_only | body}`, `Offset ∈ {none | bounded(Mm)}`. `body` means
  yaw input is a collision-checked body rotation request; `view_only` leaves
  the body. Room-scale head offset within `bounded(Mm)` is view-only and
  clamped; beyond it is not mapped. Anything richer is OPTIONAL.
- Viewpoint selection as **session state**, not a durable fact. Put the name
  in the read (`physics_client_view(viewpoint(Name), View)`) and gate it by
  `can_use_physics_viewpoint/4`. The archived §4.3 already classifies camera
  selection as session state, and making it durable would spend a consensus
  commit and retire every viewer of the world for a presentation-only change.
  This departs from the plan's `controlled(Agent, Viewpoint)`; the plan's form
  is not wrong, only more expensive. Yan's call.

### 3.2 Control action

`physics_control_agent(World, ExpectedEpoch, ExpectedSelection, Selection)` as
a `transaction((...))` predicate in the style of `quod_physics.pl`, not an
`action/3`: ground args, `current_principal(P)`, world `can_invoke` already
passed, `can_control_physics_agent(W, P, Agent)` for a `controlled(Agent)`
selection, exact prior row `physics_control(W, P, ExpectedEpoch, ExpectedSelection)`
(absent row ≡ `(0, none)`), target not held by another principal
(`\+ (physics_control(W, Q, _, controlled(Agent)), Q \= P)`), `physics_agent/5`
exists, then retract/assert with `Epoch + 1`. Release keeps the tombstone row.
Cross-world switch is two such calls in one outer `transaction` through `::`,
which is the ordinary atomic group lane; no new machinery.

Per-predicate OCC means two humans binding in the same world at the same
time conflict and one retries. `world.md` already accepts this contention
class for physics. Say so in the plan rather than engineering around it.

### 3.3 Projection and the signed view

Extend `physics_projection/2` rows with `controls([control(P, Epoch, Agent,
AgentRev, Body, BodyRev, Motion)])` and `viewpoints(...)`, with the grant
re-evaluated per row (B6). Extend `simulation_view/8` with
`Control = none | control(P, Epoch, Agent, AgentRev, Body, BodyRev, Motion,
viewpoint(Name, Body, Transform, Tracking))`. Opening a view binds nothing;
the owner cross-checks the socket's `Control` against the installed spec at
`watch` time and at every `physics_selected`, so a forged socket message can
gain nothing the spec does not already grant.

### 3.4 Owner (`quod_physics`)

- Viewers become a map keyed by ref, each with its own credit and optional
  control; one delivery per viewer per tick, bounded by MaxPoses and the
  reply encoding limit as today. Each viewer's registration binds
  `{SocketPid, Ref, Control, fence, structure, incarnation}`.
- Input is a per-registration **latest intent**, not a queue:
  `{Seq, Expiry, Linear(x,y,z), Angular(yaw…)}` in the agent's motion frame;
  a newer sequence replaces the older. Teleport is `{Seq, Pose}` applied once
  at the next step with a reply `applied(Seq) | blocked(Seq, Reason)`. A lost
  reply is answered by the next frame or a `state` request; nothing is
  resubmitted.
- Each step consumes the current intent for every registration whose
  control still equals the installed spec, converts it to a bounded
  displacement under the motion policy (speed, turn, gravity/support), runs
  the rotation-aware sweep, applies the accepted motion as the kinematic
  body's next pose, and marks the world changed only if something moved.
  Zero intent leaves a supported body asleep (repeated-operation obligation).
- `install/2` reconciles registrations against the new spec next to
  `install_controls`, retires mismatches with `physics_refresh`, and notifies
  on control-only changes so waiting viewers re-attach (B3).

### 3.5 Native

Add `controlled` kind, baseline rotation, `parts`, ball/capsule, a
`move_controlled(Id, Rev, Translation, Rotation, Mode) -> {applied|slid|blocked, Pose}`
that wraps the nonlinear shape cast plus the stop-and-slide response, and a
`support(Id)` downward cast for grounded modes. Everything else (owner PID
check, try_lock, allowances, retire) is unchanged. Kinematic bodies are
infinitely massive in Rapier, which gives "no push" for free in one
direction; the sweep must treat dynamic bodies (door leaves) as obstacles so
the agent cannot push them either.

### 3.6 Client

Desktop and XR both: camera node parented to the body pose node with the
viewpoint transform; WASD/thumbstick → intent messages on the simulation
socket; snap turn → `Turn=body` yaw request or view-only per `Tracking`;
teleport → sequenced request. Remove `floorMeshes` teleport and direct camera
translation when a control is present; keep the current observer camera for
view-only sessions. Vive wand: the touchpad press keeps the menu; locomotion
uses touch-without-press, or the other hand. Enter XR with `local` rather
than `local-floor` so the mount, not the physical floor, is the origin;
verify Babylon's WebXR camera parenting on the actual Vive runtime. On
Linux this also means qualifying an OpenXR runtime that drives the original
Vive (OPTIONAL to record, but it decides the hardware test).

---

## 4. Races, recovery and repeated cost (RECOMMENDATION, with existing seams)

- **Revocation / switch vs input.** Commit → runtime selection →
  `physics_selected` → owner retires the registration. Between the commit and
  `physics_selected` the owner may apply a bounded number of steps with the
  old intent. That window cannot be closed without blocking the owner on the
  runtime, which the working agreement forbids. The plan's obligation "zero
  old-target motion after new control becomes installed" is the right
  statement; add "motion applied before installation is transient and lossy".
  The endpoint also retires the view on `projection_advanced` independently,
  so in practice the earlier of the two cuts input.
- **Re-open before the owner has the new spec.** `watch` compares the new
  `Control` against the old spec → `unavailable` → endpoint waits. Without a
  notification on the control-only install branch the wait runs to expiry
  (B3). With it, the viewer re-attaches once.
- **Moving door vs idle controlled body.** Existing path works for a
  `physics_body` row: active contact kinematic↔dynamic leaf brakes the motor,
  `physics_door_result` yields `blocked(Agent)`, and the finish transaction
  checkpoints the hinge. One caveat: the sample names `contact(Other, Revision)`
  and `physics_door_measurement` requires that revision to be current. A
  controlled body's revision only changes on authored edits, not on motion, so
  this holds. The agent moving **into** a leaf is a sweep rejection, never a
  contact.
- **Teleport vs structural edit.** A transient teleport is validated at
  application against installed structure; if the edit lands first the body
  resets and the request is answered `blocked(structure_changed)` via refresh.
  A durable reposition follows B4 and conflicts on the structure revision as
  the door does.
- **Disconnect.** Registration dies with the socket monitor; intent is
  dropped; the body keeps its mode (gravity/support continue). The binding row
  is untouched. Reconnect is a fresh signed read; nothing is replayed.
- **Restart / host move.** B5: respawn at baseline unless a body checkpoint
  exists. Old registrations have the wrong run fence and are discarded.
- **Repeated cost.** Unchanged selection: `install` must find zero body,
  hinge and control changes and do nothing (current `installs` counter and
  `assert_no_physics_io` test seams apply). Idle intent must not set
  `changed`. Each world commit still re-signs every viewer; with controls in
  the world ontology every bind/switch by anyone kicks every viewer off. Use a
  long signed deadline for control views (ingress permits up to the session
  expiry) and measure before narrowing the durable-gap teardown; narrowing is
  OPTIONAL and outside this profile.

---

## 5. Optional scope (OPTIONAL)

- Multiple viewpoints and switching while bound (session-state form above
  makes this cheap once the policy predicate exists).
- Body-pose checkpoints and their Prolog cadence (B5 exit).
- Spectator viewers of a controlled agent (multi-viewer map makes this a
  policy question only).
- Articulated agents, held objects, pushing dynamic bodies.
- Non-box terrain surfaces (trimesh/convex parts) through the same `parts`
  row; nothing in the recommended contract assumes cubic cells.
- Local prediction, WASM controller.
- Narrower view invalidation than "any world commit".

---

## 6. Points to check against the parent's interface delta

1. Does the delta keep the controlled agent a plain classed instance in the
   world ontology, without keys or hosting?
2. Does the simulation read become scoped (`World::...`) and does the
   endpoint subscribe to the world namespace before reading?
3. Is viewpoint selection durable or session-level, and is the cost of the
   durable form accepted explicitly?
4. Are grants evaluated in the projection selector (B6)?
5. Where in `quod_physics:install/2` are registrations reconciled, and what
   status wakes a waiting viewer on a control-only change (B3)?
6. Is durable reposition two transitions (B4), and is transient teleport an
   input-class request with a sequence?
7. Does the native delta include rotation-aware sweep, kinematic kind,
   baseline rotation and `parts`, with a measured cost for the sweep?
8. Is "restart respawns at baseline" stated and tested, or is the body
   checkpoint in scope (B5)?

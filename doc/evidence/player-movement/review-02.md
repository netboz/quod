# Player movement review 02: the concrete first profile (Fable, consultative)

Date: 2026-10-07. Target: "Concrete first profile for review" in
`doc/player-movement-plan.md` (md5 f3d78e61…, 377 lines). Builds on
[review-01.md](review-01.md); contract recommendations there are not repeated.
No production file, test or plan was edited; no build or test was run.

Legend: **COMPATIBLE** = the choice holds against current code and contracts.
**INCOMPATIBLE** = as written it contradicts a current contract or the code it
names; the fix is stated. **RACE** = an exact ordering with the handlers that
decide it. **TEST** = what the parent's domain scenarios should assert.

---

## 1. Verdict on the five key choices

| Choice | Verdict | Basis |
| --- | --- | --- |
| Controlled agents physically contained in the world ontology; human may be foreign | COMPATIBLE | Selector stays local (`physics_projection/2`, `quod_runtime.erl:2497`). A foreign principal stored in a world fact has precedent (`lobby_owner/1`, `lobby_instance.pl:4`). A foreign write through `World::transaction(...)` has production precedent (`provision_lobby/1`, `human_user_instance.pl:25-40`: `quod:root::create_ontology`, `NodeNamespace::request_ontology_hosting`). |
| World-owned binding, epoch tombstone, one selection per principal per world, exclusive target | COMPATIBLE | Pure Prolog over one predicate. Two binders in one world conflict on `physics_control/4` per-predicate OCC; `world.md` already accepts that contention class for physics. State it. |
| Explicit shapes and camera mounts | COMPATIBLE in the ontology, INCOMPATIBLE with the native row today | `physics_body/7` has no orientation, one cuboid, two kinds; `lib.rs:16,138`. Review-01 B2. The plan's own first example (compact rounded body) needs a non-box part. |
| Anchored signed world read under the original human principal | INCOMPATIBLE with the endpoint as written | `quod_client_simulation.erl:40-55` pins the literal goal text, requires the **signer's** namespace local, subscribes to the signer's `{runtime,Ns}`/`{physics,Ns}` and compares against the signer's `applied/1`. For a foreign human every one of those is the wrong namespace. Review-01 B1 gives the fix. |
| No mandatory WASM prediction | COMPATIBLE | Nothing in the profile depends on it. |

---

## 2. Material incompatibilities in the profile text

**I1. "Spawn/reposition is a separate authorized action with full-shape
placement validation."** A proof cannot read live native state (`world.md`
"oracle boundary"; `quod_predicates.erl:283-302` marks live queries as
`live_observation` dependencies that block sealing a nonempty diff). The only
state a one-transaction edit can validate against is the authored baseline,
which is wrong once anything has moved. Full-shape validation against the
installed world is therefore the door's two-transition shape: authorized
request → owner samples placement → authority signs the sample →
one transaction commits new baseline + revisions, or an explicit
`invalid_placement`. Rewrite the sentence; otherwise the domain scenarios will
encode a check that cannot exist.

**I2. "Native restart restores the existing compatible checkpoint/baseline
contract."** True, and the existing contract has no body checkpoint
(`physics_checkpoint/2` is hinge-only; `quod_physics.erl:hinge/4`). So the
profile's restart behavior is: every controlled body returns to its authored
baseline with zero velocity. `world.md` permits that rollback. The plan must
say it, and the "idle body blocks a moving door" obligation must accept that
after a restart the door is `finished(R, blocked(Agent))` at its stopped angle
while the agent is back at baseline. No contract is violated: a finished
activity never restarts its motor, and a rewound agent cannot repeat the
consequence. It is visibly odd, and that is the stated profile.

**I3. "Subscribe before reading, then verify read height."** The answer height
is the signer's namespace height. For a foreign human it says nothing about
the world. Replace with: subscribe to the world namespace named in the scoped
goal before submitting; any world `projection_advanced` observed after
subscription retires the view. Conservative, same cost class as today.

**I4. "Selection is none or controlled(Agent, Viewpoint)."** Durable
viewpoint selection means every camera change is a world commit, which
(a) runs consensus, (b) retires every viewer of that world through the
`durable_gap` teardown, and (c) conflicts on `physics_control/4` with every
other binder. The archived §4.3 classifies camera selection as session state.
Not a correctness defect; a cost choice to make explicitly. Review-01 §3.1
gives the session-state form.

**I5. "A native step must not consume input after the relevant committed
invalidation is known but before its replacement configuration is
installed."** With the owner as a `gen_server`, "known" and "installed" are the
same handler invocation if, and only if, registration reconciliation runs
inside `handle_info({physics_selected, ...})` → `install/2`. Today that branch
(`quod_physics.erl:168-183`, zero body/hinge changes) touches nothing but the
retained frame's structure. If reconciliation is deferred to the next `step`,
the sentence is violated by construction. Pin it to `install/2`.

**I6. "Inputs bind … original expiry."** The expiry is the signed read's
deadline. The client currently signs a 30 s deadline
(`doc/evidence/poses/fable-review.md`), so a controller is cut every 30 s and
on every world commit. Ingress accepts any deadline up to session expiry
(`quod_client_goal_ingress.erl:154`). The profile should name the control
view's deadline policy; the server needs no change.

**I7. "The same object may be controlled by a human or another principal."**
The binding action is principal-agnostic, but the only input lane in the
profile is the browser simulation socket. A hosted actor principal has no
way to send intent. Either scope the sentence to binding only, or defer it.

**I8. Agent instance identity.** "Classed agent instances in one ontology"
is compatible only if `Agent` has no `agent_host`/`agent_key` rows; the
hosting projection (`agent_instance.pl:11-18`) would otherwise try to host
and sign for it. Say "classed instance, not hosted" so no scenario gives it
keys.

---

## 3. Exact revocation and installation races (RACE)

Handlers involved, in the order a commit reaches them:

1. `quod_prolog` applies the world commit; publishes `applied_live` and
   `projection_advanced` to `{runtime, WorldNs}` subscribers. The endpoint is
   one of them (`quod_client_simulation.erl:139-143`).
2. `quod_runtime` receives `applied_live` → `invalidate_resources`
   (`quod_runtime.erl:1412, 2384`) using the retained read set of the
   `physics_worlds` selector → re-selects → `install_physics`
   (`quod_runtime.erl:2818-2860`) → `send_physics_selection`
   (`quod_runtime.erl:2875`). At most one selection is in flight; a newer
   desired spec is re-sent on `physics_selection_applied`
   (`quod_runtime.erl:592-599`).
3. `quod_physics` receives `physics_selected` → replies applied → `install/2`.

Only the retained read set drives step 2. Therefore grants must be evaluated
inside the projection selector (review-01 B6); a grant evaluated only in the
bind action is invisible to invalidation and revocation never reaches the
owner until some unrelated physics predicate changes.

**R1. Revocation vs continuous input.**
Sequence: commit C revokes grant at height H. Endpoint gets
`projection_advanced(H)` → `refresh` → `unwatch` → owner `clear_viewer`.
Independently, runtime step 2 → owner `physics_selected` → `install/2`
reconciles. Input is cut at the earlier of the two. Between C and the earlier
message, the owner may run `k` step timers consuming the old intent;
`k` is bounded by selection latency plus one in-flight selection round trip.
This window cannot be closed without blocking the owner on the runtime. The
profile's obligation ("zero old-target motion after new control becomes
installed") is the correct one. TEST: assert zero motion after `install/2`
returns for the new spec, not after the commit.

**R2. Switch A→B by the same principal, then re-open.**
Commit at H. Endpoint refreshes; client re-signs and gets `Control(B, Epoch+1)`
from a proof at H' ≥ H. Owner may still hold spec(H0) with `Control(A, Epoch)`
if `physics_selected` lags. `watch` compares the socket's control against the
installed spec → mismatch → `{error, unavailable}` → endpoint enters `waiting`
(`quod_client_simulation.erl:103-111`) for a `physics_status … installed`.
On the zero-change install branch no status is sent, so the wait runs to the
signed expiry. Fix: a control-only install must notify (`installed` or a new
status) so `websocket_info({physics_status, …})` (line 146) re-opens. TEST:
switch, re-open before the owner's selection, assert re-attachment without
waiting for expiry.

**R3. Opposite order: owner first, endpoint later.**
`physics_selected` reaches the owner before the endpoint's `projection_advanced`.
`install/2` reconciles: registration `(P, Epoch, A)` ≠ spec `(P, Epoch+1, B)`
→ `physics_refresh` + clear. Endpoint then also gets `projection_advanced`;
its `refresh` on an already-released socket must be idempotent (`release/1`
is). TEST: both orders, same end state.

**R4. Input arriving after reconciliation.**
The socket sends `intent(Seq)` bound to `{Ref, Epoch, AgentRev, BodyRev,
fence, structure}`. Owner matches on `viewer ref` like `physics_ack`
(`quod_physics.erl:66`). A retired ref drops the message. No principal
substitution is possible because the registration, not the message, names
the control. TEST: late intent on a retired ref produces no motion and no
error reply other than the pending `refresh`.

**R5. Structural edit of the agent's body or `physics_agent` revision.**
Body change → `current_projection` false → `physics_refresh` + `clear_viewer`
(existing, `quod_physics.erl:deliver_frame`). `physics_agent` revision-only
change → same zero-change install branch as R2; reconciliation must compare
`AgentRev` too. TEST: motion-policy edit without geometry change retires
the registration and re-attaches with the new policy.

**R6. Authority host move or run restart.**
`ChangedRun` → owner `{stop, normal}` (`quod_physics.erl:85-90`); all
registrations die with the process; endpoint sees `DOWN` → `owner_changed`
refresh. New incarnation starts from baseline (I2). TEST: after restart the
re-opened view shows baseline poses and the old intent sequence is not
honored.

**R7. Transient teleport vs structural edit.**
Teleport `(Seq, Pose)` applied at the next step. If an edit installs first,
the registration is gone (R5); the socket gets `refresh`, never `applied`.
A lost `applied` reply is resolved by the next frame or a `state` request.
TEST: teleport then edit in either order; never both `applied` and a
baseline reset for the same Seq.

**R8. Durable reposition request vs door close (I1 shape).**
Request transaction and door `physics_close_door/4` touch different
predicates; the owner's placement sample and the door sample each carry the
structure revision; the finish transaction of whichever lands second is
rejected by the conservative world fence exactly as `world.md` states for
observations. TEST: reuse the door's race test shape.

**R9. Two principals bind the same agent.**
Both prove `\+ physics_control(W, Q, _, controlled(Agent))`; both stage an
assert on `physics_control/4`; second commit fails OCC. TEST: exactly one
`controlled(Agent)` row survives; the loser's expected epoch is unchanged.

**R10. Grant revoked while the bind transaction is in flight.**
Bind read `can_control_physics_agent/3`; revocation retracts the fact; OCC
orders them. If bind commits first, the row exists but the projection
(evaluating the grant) omits it → owner never installs control → view shows
`Control = none` with the row's epoch intact. If revocation commits first,
bind is rejected. TEST: both orders; in the first, assert the row exists and
no registration is accepted.

---

## 4. Obligations the domain scenarios can already test (TEST)

Pure Prolog, no owner or native change required:

- bind/switch/release with epoch guards, tombstone retention, stale epoch
  rejection, `none` release without body change;
- exclusive target and per-principal single selection;
- grant in the projection: `physics_projection/2` (or its sibling) returns
  control rows only while `can_control_physics_agent/3` holds, and the
  selector's read set contains that predicate (observable through
  `quod_runtime:stats/1` `resource_dependencies` or a reconcile after a grant
  retraction);
- foreign human through `World::physics_control_agent/4` under the human's
  own `can_invoke` (`human_user_instance.pl:7`) and the world's `can_invoke`;
- cross-world switch as one atomic group (two writers) with one signed
  request;
- `physics_client_view` answer carrying `Control` for the current principal
  and `none` for a view-only principal;
- a controlled body row being a `physics_body` so `physics_door_result/7`
  yields `blocked(Agent)` unchanged.

Not testable before the owner/native delta: anything in §3 beyond R9/R10,
sweep correctness, repeated-cost of idle intent.

---

## 5. Smallest changes to the profile text

1. Replace the reposition sentence with the two-transition form (I1).
2. State the restart-respawn behavior and its door interaction (I2).
3. Replace "verify read height" with the world-namespace subscription rule (I3).
4. Decide durable vs session viewpoint and say why (I4).
5. Pin reconciliation to `install/2` and require a notification on the
   control-only branch (I5, R2).
6. Name the control view's signed deadline policy (I6).
7. Scope "another principal" to binding (I7); say "not hosted" (I8).

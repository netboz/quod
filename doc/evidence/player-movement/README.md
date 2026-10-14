# Player movement implementation evidence

2026-10-07. Uncommitted implementation; no deployment or ontology migration.
The task remains in progress because original HTC Vive hardware acceptance
has not run. The current contract is in [physics-native.md](../../physics-native.md).

## Architecture and scope

Human principal, played agent, physical body and camera mount are distinct.
Prolog selects bindings, arbitrary rigid geometry, mounts, movement capabilities,
permissions and budgets. Signed `control` proofs stage one ephemeral effect via
an Erlang external predicate; existing proof/savepoint/effect owners release it
only after successful finalization. The retained physics owner alone applies
collision-tested motion. No visual collision authority, universal capsule,
browser simulator, per-frame durable journal or replay of uncertain commands.
The BBSvx predicate/effect pattern informed this interface; its legacy defaults
and direct native reads were not copied.

Implemented geometry includes explicit hulls and rigid compounds, and fixed
triangle surfaces for non-cubic terrain. Smooth movement, swept snap turns,
straight-path supported teleport, explicit occupancy-tested live reposition,
view registration/revocation, sequence fencing and XR sensory masking are
covered. General checkpoints, articulated controlled agents, pushing and held
objects remain outside this slice. Reposition is not a durable baseline edit.

The session-owned production delta is **+2047/-215 lines (net +1832)** across
33 files; see [production-delta-final.json](production-delta-final.json). This excludes
shared `ui/src/World.tsx`, tests, docs and evidence. Growth is primarily the
missing geometry/query mechanics, signed transient-effect interface and physical
camera/input adapter. Unrelated editor/system-ontology/deployment work was
preserved. No second state owner or simulation engine was introduced.

## Successful gates and limits

- [control-owner-17](control-owner-17.json): **119 tests, zero failures** through
  production physics/runtime/proof/socket seams. Includes permissions and
  revocation, subclass bindings, ambiguous configuration, proof rollback/cut/
  negation, caller deadline, disconnect/reconnect registration, foreign local
  human scope, refusal of non-local signer, collider revisions, occupied
  teleport/reposition, moving-door obstruction and a clear escape query after
  braking. Grounded bodies land after a structural invalidation without another
  command, a V-shaped wedge settles without continuing timer work, and moving
  or deleting their support resumes falling without a new command.
- [control-proof-regression-02](control-proof-regression-02.json): **308 tests,
  zero failures** across proof/session/savepoint, transaction, ingress/target/
  router, runtime and durable-effect regression suites. Source did not change
  during that campaign. Later deadline admission and physics/client fixes were
  covered by the targeted gates; the proof/savepoint implementation did not change.
- [surface-native-01](surface-native-01.json): **16 native tests passed**, including
  two-sided triangle wall collision, slopes, compounds and rotational arcs,
  sliding, occupied spawn, no pushing, sequential controlled-body coherence,
  full-path landing and sensory clearance. Native source has not changed since.
- [navigation-client-05](navigation-client-05.json),
  [movement-types-03](movement-types-03.json),
  [movement-bundle-02](movement-bundle-02.json): client tests, TypeScript and
  isolated UI bundle. Build output is `/tmp/quod-player-movement-ui-02`.
- [browser-02](browser-02.json): WebGL2 rendering/lifecycle smoke passed for
  authored mount, accepted-pose correction, disabling direct camera translation,
  unavailable-world freeze, observer restoration and disposal. This is a browser
  rendering fixture; it does not claim end-to-end browser/native-server coverage.
- Repeated unchanged reconcile/query/control checks use real production owners
  and trace absence of history folds, native reinstalls and disk writes/syncs.
  Settled-world checks assert stable step/tick/install counters.
- [source-manifest-final-02](source-manifest-final-02.json) records source hashes
  after the final owner campaign. [whitespace-02](whitespace-02.json) records
  `git diff --check`. This is focused feature validation, not a release campaign.

Browser host: Nimbalyst Electron 43.2.0, Chromium 150.0.7871.129, Linux.
`navigator.xr.isSessionSupported('immersive-vr')` returned **false**. No hardware
result is implied by NullEngine tests or the WebGL smoke. A final attempt to
reuse the browser session found it already closed; the successful browser-02
record is retained rather than represented as a newer run.

## Fable consultation and resolution

Yan explicitly requested Claude; the review session used **claude-code:fable**.
Reports [01](review-01.md), [02](review-02.md),
[03](review-03-predicate-interface.md) and
[04](review-04-implementation.md) are consultative, not approval certificates.
Implementation findings were independently checked:

- **F1 dynamic contact:** the proposed door freeze did not reproduce. The real
  door fixture now queries departure after motor braking and requires a clear
  full-body escape. Dynamic obstacles remain collision authority. Penetration
  beyond an explicitly authored tolerance still returns occupied; no exemption
  for dynamic colliders or hidden depenetration was added. Rapier's nominal
  solver error is not a guaranteed upper bound on arbitrary motor penetration.
- **F2 wedge:** fixed by settling clipped downward motion with no downward
  progress, separately from valid landing support. Real-owner V-wedge test
  asserts settlement and no unchanged reconciliation work.
- **F3 invalidation:** suspension preserves vertical mechanics, installation
  refreshes the internal physical frame fence, and installation resumes needed
  stepping. A real-owner mid-air structural update now lands without new input.
  Physical changes also wake previously settled support checks; unavailable
  controls cannot keep a retained falling row's timer awake.
- **F4 free teleport:** the client suppresses landing teleport in free mode.
  Certain command refusals still conservatively suspend the view; distinguishing
  them for gentler feedback is an optional UX improvement.
- **F5 locality:** both source and world require an exact ready local authority
  before subscription or ingress; the non-local-source socket test passes.
- **F6 invalid binding:** a bound but invalid/ambiguous configuration refuses
  the view instead of silently becoming a spectator. The socket reports
  `view_not_authorized_or_ready`; the client freezes movement.
- **F7 angle documentation:** pi applies to a relative travel sweep, not an
  authored absolute pose. Documentation corrected.
- **F8 subclasses:** binding uses direct membership or shared `isa/2` closure;
  a subclass binding regression passes. Direct agent membership does not require
  a separate authored reflexive `isa(agent,agent)` fact.
- **F9 idle cost:** grounded support is rechecked while physical-world activity
  continues, because a dynamic support can move. This bounded per-step query
  remains; skipping it blindly would suspend gravity after support motion.
  A sleeping world performs no periodic support query.
- **F10 XR calibration:** recenter position and heading only; tracked pitch/roll
  remain relative to the authored mount. Client regression passes. Hardware
  assessment remains pending.
- **F11 self-ask:** belongs to the concurrent ontology-source scope, not this
  movement change. Its owner documented the generic uncompiled-goal `call/1`
  fix and cut/conjunction regressions in the separate ontology-source evidence.
  Movement did not replace or revert that work.

## Retained failures and corrections

Every campaign has its own log/exit JSON; failed logs were not overwritten.
The following groups explain why later campaigns were necessary:

- control-tests 01/02: signed wire fixture errors; 03 passed.
- control-installation 01: selection test scope; 02 passed.
- geometry-native 02: Rustler atom use outside BEAM aborted a standalone test;
  replaced the test seam. 03: flat-hull volume validation defect; 04 passed.
- geometry-owner 01: obsolete four-field allowance fixture; 02 passed.
- control-owner 01: cross-scope transient rollback exposed missing root
  savepoint; fixed with the existing distributed savepoint owner.
- motion-native 03: sleeping sentinel changed incorrectly; restored its
  unchanged-world meaning in 04.
- control-owner 03: installation synchronization, failure cleanup and unbounded
  invalidation notices; fixed retained guard/coalesced acknowledgement in 04.
- control-owner 05: unsupported catch/throw test; replaced with supported
  negation and compiled-cut obligations. Production changed during that run,
  so it is not frozen-tree evidence. 06 exposed cut-fixture and anchored ACL
  mistakes; 07 passed without weakening production authorization.
- control-owner 08: stale installed notice; helper now checks installed readiness.
  09: expected door-observation rejection misclassified by test helper; door
  outcome tests retained. 10 passed.
- control-owner 11: view-only permission edit does not emit physical installation;
  used actual reconciliation instead. 12 passed.
- control-owner 14: adding subclass closure accidentally required a separate
  declaration even for direct agent membership; corrected the domain predicate.
  15 passed, including the new subclass/door/wedge/reinstall obligations.
- control-owner 16: the added support-removal fixture used unsupported Erlog
  `retractall/1`; replaced it with `retract/1` for the single authored surface.
  17 passed with support removal and moved-floor obligations intact.
- browser 01 timed out waiting for offscreen requestAnimationFrame; the fixture
  now calls the public Scene renderer explicitly and makes no XR timing claim.
  Initial Vite configuration also denied the sibling client path; a temporary
  explicit development-server allowlist resolved that import.

## Required Vive acceptance (not run)

Record the original HTC Vive, controller model, host OS, OpenXR runtime,
browser/version, refresh rate, world anchor/run and exact tested source hashes.
Use an authored compact body and an asymmetric rigid compound with an off-centre,
rotated viewpoint. Do not derive physical definitions from displayed meshes.

1. Desktop and Vive smooth travel: approach floor, wall, corner and obstacle;
   slide alongside them; rotate the asymmetric body where the middle of the arc
   collides although endpoints fit. Confirm no pushing of dynamic objects.
2. Vive controls: left grip plus pad/stick smooth travel; horizontal pad click
   swept snap; forward click validated teleport; right pad/menu arbitration.
   Confirm controller discovery and haptics on the actual runtime.
3. Teleport: supported floor/slope accepted; occupied destination, intervening
   wall, unsupported slope, missing floor and stale frame refused without drift.
4. Room-scale motion: authored mount respected in both eyes; head pitch/roll
   retained during entry; leaning toward a solid produces the sensory mask;
   tracking loss and missing clearance mask and pause. Check comfort and stereo
   rendering, especially eye/controller parenting.
5. Moving door presses against an idle agent, stops, and permits clear departure.
   Occupied authored spawn stays put; authorized live reposition repairs it.
6. Edit/remove support or wall while moving; revoke/switch binding; disconnect
   and reconnect; expire a view; restart/change physics authority. Confirm
   stale commands never resume and baseline restoration is visible.
7. Renew a view while wearing the headset without recentering it; leave XR and
   confirm the desktop camera returns to its authored mount. Record latency,
   perceived correction and any headset/controller discomfort separately from
   collision correctness.

The hardware gate is the remaining acceptance blocker. No tracker completion,
commit, deployment, data wipe or hardware approval is claimed.

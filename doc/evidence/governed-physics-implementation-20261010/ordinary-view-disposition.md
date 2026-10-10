# Ordinary space views: independent implementation review

Codex performed this review under Yan's instruction to review independently
while Claude/Fable was quota-blocked. No new Claude review is claimed. This is
local implementation evidence for QUD.27, which remains open.

## Implemented ownership

The normal browser view now signs `client_world_view/4` at the exact visible
space instance. Its shared Prolog wrapper selects one representation, validates
it through the pinned rendering vocabulary and derives physical selection from
space classification and existing physics policy. `physics_enabled/2` is shared
by allocation, authority hosting, live body reads/inputs and physical actions.
Query/push policy alternatives remain ordinary Prolog alternatives; world
configuration must be a singleton.

The socket retains its original deadline, actual signed dependency envelope,
subscribe-before-snapshot ordering and exact installed-owner fencing. A monitored
opening worker calls existing ingress, permitting remote acting-agent routing
without blocking the socket. Expiry/reopen/socket death cancels it; a second
opening waits for the first worker's DOWN and pending follow cleanup.

Navigation contributes exact namespace/anchor/uint64-height triples in the
signed goal. The Prolog wrapper visits them under ordinary ACLs; the socket
compares them with the proof's actual envelope before exposing a view. Public
vocabularies which already opt into `public_source_query/1` now explicitly expose
`current_ontology_identity/2`. Private owners retain their own ACL decision.
There is no live-height predicate, scope authorization exemption or alternative
read engine. Decimal HTTP dependency heights remain exact in JavaScript.

The separate Simulation menu, acting-agent `physics_client_world/1`, old
`physics_client_view/1`, `physics_view/2`, `readSimulationWorld` and parallel
scene painters are removed. One scene method applies marks and body poses.
Nonphysical and active unbound views explicitly permit observer travel;
disabled, denied, recovering, unavailable and disconnected controlled views
pause. A retained controller prevents classification removal from selecting
observer travel. Authored parents, anchored subjects and camera mounts remain
under their existing owners.

The personal-lobby navigation adapter returns its authored entity instance and
modes in one signed read. It contains no physics selection. Source changes here
do not update any retained existing ontology or its founding manifest. No live
source edit, deployment, refound or personal-lobby baseline is claimed.

## Findings and corrections

- `ordinary-view-01`: 174 tests, five failures. The endpoint initially matched
  opaque parser symbols as Erlang atoms. It now compares the complete canonical
  goal, without allocating client-controlled atoms. Applying singleton checks to
  query/push alternatives also broke an existing valid policy obligation; the
  world-configuration singleton is now distinct from those alternatives.
- `ordinary-view-02`: nine tests, three failures. Expected navigation visits
  exposed the missing public identity-query declaration. Generic ambiguity tests
  also attempted to duplicate an identical fact, which the state owner deduplicates.
- `ordinary-view-03`: three tests, two failures. Identity visits passed; the
  remaining ambiguity fixtures were corrected to author distinct scenes. The
  assertion still requires unavailable, and no production fallback was added.
- `ordinary-view-deadline-01`: 135 tests, one failure. An unrepresentable timer
  was correctly rejected, but its cleanup tried to unregister a subscription
  which had never been installed. Rejection now discards only the unallocated
  opening state; no worker or subscription exists on that path.
- The independent pass also added expiry checking after asynchronous dependency
  snapshots, rejected expired browser projections, preserved UTF-8 dependency
  ordering and prevented repeated observer updates from recentering the camera.

All failed campaigns and fixtures are retained. No deadline was extended and no
failed assertion was weakened.

## Verification

- `ordinary-view-04`: **181 tests passed**, exit 0, tracked inputs unchanged.
  Physics, control, foreign subscriptions, lobby and space owners are exercised.
  New signed tests use **ordinary-workshop** and **ordinary-observatory**, covering
  disabled/denied renewal, enablement, nonphysical withdrawal, retained control,
  ambiguous scenes, missing instances and absence of native allocation/hosting.
- `ordinary-view-deadline-02`: **135 tests passed**, exit 0, tracked inputs
  unchanged. Includes cancellation/reopen/socket death, unrepresentable deadline,
  actual restart readiness, Prolog/runtime recovery and result codecs.
- `ordinary-view-client-02`: **three client test files passed**, exit 0,
  tracked inputs unchanged. Includes typed inactive views, exact uint64 fences,
  stale frames, uncertain controls, authored attachments and camera tracking.
- `ordinary-view-types-01`: TypeScript project check passed, exit 0.
- `ordinary-view-bundle-01`: final TypeScript and production Vite build passed,
  exit 0, authored inputs unchanged. Checked-in browser assets replace the former
  menu/discovery bundle; no old/new bundle path remains.
- `ordinary-view-browser-02.json`: MCP WebGL2 fixture passed camera mount,
  accepted pose correction, disabled direct translation, unavailable-view pause,
  explicit observer restoration and disposal. Frozen source hashes matched.
  `immersiveVR: false`; this is neither physical Vive acceptance nor signed live
  desktop acceptance. The first browser attempt and a prematurely started retry
  hit Vite file-watcher exhaustion in the unrelated Chromium build tree; the
  successful separately labelled run disabled watching. No system limit changed.

Counts overlap and are not a full-suite or complete-ticket claim. Native malformed
input and runtime failure-injection diagnostics remain in the owner logs.

At this boundary the accumulated authored production delta is **+813/-306,
net +507 across 27 files**, an increase of 144 lines since the preceding independent
review. The increase implements typed selection, dependency fencing and owned
opening cancellation while removing the duplicated browser paths. Generated
release assets are counted separately.

## Remaining acceptance

Remote live collider selection/invalidation through the existing retained
projection and resource owners is still missing. Its authorized source edit and
receiver revision/checkpoint consequences must be one existing atomic transition.
The remote-change/repeat-work measurements, full concurrency and withdrawal
integration, coordinated release, fresh signed personal-lobby identity/history
baseline and real normal-view collision acceptance remain outstanding. Neither
this fixture nor the separately completed network refound satisfies those gates.

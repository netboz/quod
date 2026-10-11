# Renew the existing signed view without interrupting unchanged control

## Demonstrated failure and existing owners

The windowed desktop261-07 recording shows a 517 ms stationary interval with
ArrowUp continuously held and uninterrupted rendering near 60 fps. The signed
view expires inside that interval; a replacement arrives 302 ms later. The
current socket calls `release/1`, the physics owner disconnects its input, and
the UI rereads navigation while `update(null)` clears held keys. Movement only
resumes on the next key transition. The recording's later deliberate stop does
not overlap this interval; it remains an incomplete overall acceptance run.

`quod_client_simulation` already owns signature admission through one monitored
opening worker, exact proof dependencies, subscribe-before-snapshot installation,
expiry and cleanup. `quod_physics` owns the one viewer registration, retained
mechanical state and accepted input sequences. `connectWorldView` owns signed
reads and browser expiry; controlled navigation owns input and the authored
camera mount. These remain the owners. Prolog continues to decide all viewing,
control, resource and geometry policy through the unchanged ordinary signed
read/control predicates.

## Replacement within the existing lifecycle

1. Schedule one fresh signed `open` halfway through the remaining lifetime of
   each installed projection. This is protocol renewal, not readiness polling.
   Keep the current projection, its absolute expiry and commands usable while
   that one new read is being proved. Do not reread derived navigation merely
   because time passed: the existing navigation dependencies remain pinned in
   the signed goal and subscribed. Actual invalidation still rereads navigation.
   Only schedule renewal when a fresh read can outlive the current view under
   the existing sign-in session expiry. A session-limited view keeps its hard
   expiry; do not create an ever-shorter renewal loop or extend authentication.

2. Extend the existing opening worker to permit one candidate alongside the
   still-valid installed view. Reuse that worker path, with a distinct candidate
   timer under its original signed expiry. An overlapping open, cancellation,
   socket death or invalidation uses the existing cleanup barrier. The old view's
   expiry remains armed throughout. If it expires before replacement, release
   it, cancel the candidate and take the existing paused/fresh-read path.
   No deadline is extended and a late result cannot resurrect the retired view.

3. Retain subscriptions only when the freshly verified read has exactly the
   same request scope (authenticated session, anchored actor, anchored world,
   instance, mode and navigation goal), dependency identities/heights and ready
   owner incarnations. Reuse the existing followed readers and monitor set;
   do not unfollow/refollow an unchanged foreign projection. Changed dependencies
   take the existing release, subscribe-before-snapshot and installation path.
   Conservative world/dependency invalidation and per-predicate OCC are unchanged.
   No new transaction, diff broker, source mirror or private domain state exists.

4. Replace the internal native-owner `watch/2` call with one `watch/4` contract:
   `(OwnerPid, PreviousReferenceOrNone, ExpectedPhysicalSelection, SignedExpiry)`.
   Initial attachment uses `none`. Replacement requires the same calling socket,
   exact previous reference, live unexpired lease and unchanged complete physical
   fence/control selection. Check the runtime navigation guard and installed
   configuration again in the physical owner. A different viewer stays busy;
   wrong references, incarnation, body/binding or expired leases cannot renew.
   Replace the delivery reference and random registration atomically while
   retaining mechanical state, monitor, sequence and admitted inputs. Old queued
   frames/acks/controls then fail their old reference/registration. Never recreate
   the native resource or apply/replay an input as part of renewal.

5. Store the verified view expiry with its registration and check it in native
   control admission/delivery. Bound a newly admitted input by both its existing
   signed/Prolog lease deadline and the current viewer expiry. Replacement does
   not lengthen any accepted input deadline. The browser immediately sends a
   fresh ordinary drive level for keys still held after verified replacement;
   that is not replay of a discrete command. Preserve pending discrete sequence
   and feedback rules and fence any late old-registration request. An uncertain
   command cannot be automatically resubmitted by renewal.

6. Accept old-view frames while the candidate is pending, then switch to the
   new view ID only upon its matching verified projection. Keep a monotonically
   increasing local command sequence across renewal. The navigation adapter
   retains held keys, camera orientation and XR calibration when the actual
   world/run/body/binding/mount is unchanged; a registration change only makes
   the next drive sample due. Genuine unavailability, lost focus, revocation,
   changed selection or expired permission continues to clear/pause input.
   There is still one pose writer and no observer-flight fallback.

This is a refinement of the shared view lifecycle for every world, including
inactive/nonphysical views; it does not add a lobby path. No compatibility
branch, old watch export or redundant renewal executor remains. Predicate
selection, founding manifests and committed data formats do not change. Deploy
matching client/server code through the existing single-writer release gate;
this correction needs no ledger refound or domain-authority change.

## Required proof before release

- Native owner: continuous admitted drive survives verified replacement with
  unchanged input deadline, sequence, pose and install count; old references and
  registrations fail. Wrong caller, changed physical/control fence, expiry,
  revocation, recovery and second-viewer admission remain rejected. Discrete
  inputs are never applied twice or silently discarded by a successful renewal.
- Socket owner: an in-flight renewal retains its original expiry and current
  credit path; unchanged dependencies preserve exact follows/monitors. Exercise
  delayed proof, expiry/commit/owner-death races, cleanup, stale messages and
  failed signed admission with production ingress and authenticated fixtures.
  Use two generic world identities plus an inactive/nonphysical case.
- Repeated cost: trace unchanged renewal through the real owner and distinguish
  legitimate simulation stepping from history replay, projection/geometry
  rebuilds, file writes or syncs. A real dependency change must still retire
  the view and install through the existing owners.
- Browser: deterministic timers and deferred signing/HTTP replies cover early
  renewal, old-frame delivery, atomic replacement, held-key continuation, hard
  expiry, failed renewal, stale signer completion, sequence monotonicity and
  uncertain discrete commands. Actual unavailability still clears movement.
- Run relevant tests, Fable implementation review and the standing clean
  sequential release gates against frozen inputs before committing/deploying.
  Retain failed campaigns. Recheck the deployed unchanged lobby identity/history
  and run sustained signed desktop movement during a newly coordinated window.
  Yan can game during background work; do not focus or drive a browser now.

Fable is asked to challenge the ownership, exact expiry/race guarantees and
smallest implementation above before production edits. Its review is advisory;
the implementation must satisfy the repository architecture and independent tests.

# Real startup succeeds; physical-view guard prevents usable acceptance

This is the actual built HTTPS application from demo-02's pinned image, with
normal browser permission, the qualified Chromium/Monado binaries and physical
Vive. No permission override, simulated device, security-policy relaxation,
controller-profile fetch or second controller-loading path was introduced.
Yan confirmed readiness before both entries. The session remained interactive
until Yan selected “Stop the demo and diagnose the view-mask problem.”

## Observed results

- The first immersive session produced 23,842 stereo/tracked frames before
  normal app exit. Each eye had a distinct 1512 × 1680 viewport. Head poses
  changed. Both physical controllers eventually supplied grip/ray poses;
  their initial absence and later acquisition are retained in the observations.
- The app's Exit VR control invoked native session end once, the end event was
  observed, and Enter VR became available again. Re-entry in the same browser
  and runtime produced another 1,614 stereo/tracked frames at the saved sample.
- Yan first reported “View blocked, return your head toward your starting
  position.” After re-entering with the headset on, Yan reported seeing the
  scene, but small head movements repeatedly brought the mask back and removed
  it. These observations fail usable physical acceptance.
- No CSP violation or application exception was recorded in the saved browser
  measurements. The pinned Vive model loaded once from the application's own
  origin. No foreign resource origin was recorded. The historical missing
  InstancedMesh exception, helper-style block and remote-profile block did not
  recur in the captured startup.
- Physical controller selection, menu operation, locomotion and comfort were
  not accepted. Visibility interruption, refusal and a controlled post-session
  entry failure were not physically tested. Existing software tests are not a
  substitute for those physical cases.

## View-mask diagnosis

The exact message comes from `client/src/controlled-navigation.js`. The scene
owns an opaque contact layer; its visibility follows whether either eye exceeds
the smaller of the current server clearance and the authored tracking radius.
The lobby's existing `tracking(view_only,500)` allows at most 500 mm relative to
the position calibrated on entry. The native owner measures a conservative
clearance ball around the authored camera mount, excludes the controlled body,
and subtracts the contact skin. A nearby object can therefore reduce the
permitted displacement in every direction. Crossing the threshold switches the
opaque layer immediately; there is no transition band.

The first sampled headset height was 0.747 m, whereas later samples were around
1.5 m. This is consistent with the headset being raised after the first entry;
the measurement alone does not establish what Yan physically did. Re-entry
started at 1.552 m and removed that particular low-height starting condition.

On re-entry, the sampled head displacement reached 0.606 m after 5.15 seconds.
Thirteen of 27 retained samples exceeded the authored 0.5 m maximum. These are
distances between raw WebXR head positions, not a capture of the actual eye
comparison inside the app. They nevertheless demonstrate reported translations
large enough to reach the guard's outer bound. Yan described small movements;
the evidence does not distinguish actual translation from native tracking drift
or jumps. It does not justify silently raising the allowance or removing the
physical-view check.

A read-only scene inspection confirmed that the contact layer was enabled and
the camera had an entry-calibrated tracking origin. A later bounded attempt to
capture the exact live server clearance failed: Chromium's renderer stopped
answering debugger requests. The first Runtime.evaluate request and its cleanup
returned HTTP 500; the WebSocket listener installation was never reached.
Subsequent status/final-observation requests reported renderer timeouts. No
exact clearance value was recovered, and the cause of this later renderer
unresponsiveness remains unresolved. The evidence does not establish that the
inspection caused it.

The next focused diagnosis should correlate the actual per-eye offset, current
clearance, mask transitions and tracking state with a known stationary-head
interval and Yan's movement observations. Apparent pose jumps belong with the
native/readiness investigation (QUO-38). The physical-view/comfort result belongs
with GUI acceptance (QUO-24). A demonstrated coordinate/calibration defect should
be fixed in the existing navigation owner. A change to the authored allowance or
the conservative-clearance behavior needs an explicit scope decision and, for
already founded ontologies, an explicit governed source update; rebuilding files
does not change those ontologies. No further reset, source change, runtime patch
or hardware launch was performed for this diagnosis.

## Cleanup and evidence

At Yan's request, the owned browser was closed, Monado exited 0 and the owned
driver was terminated. Desktop geometry and the headset's prior disabled state
were restored. Only the exact temporary certificate trust was removed; other
trust rows were unchanged. Runner exit 0 describes cleanup, not acceptance.
The second session's native end event was not captured because the final browser
observation timed out; process cleanup must not be presented as that missing
session-level evidence.

Sources: [first immersive observation](05-first-immersive.json),
[first human report](yan-first-observation.json),
[normal exit](10-after-normal-exit.json), [re-entry](11-reentry.json),
[second human report](yan-reentry-observation.json),
[tracking analysis](tracking-analysis.json),
[failed clearance observation](12-live-clearance-failed.json),
[cleanup](result.json), [process exit](process-exit.json), and
[stop instruction](yan-stop-and-diagnose.json).

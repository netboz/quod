# Signed desktop 0.7.263 — acceptance passed

Yan authorized unattended foreground testing while asleep. This campaign used
his existing signed profile and actual personal world at the stable client
origin. Ordinary keyboard input and the ordinary console exercised the
deployed production view. No body or camera pose was set by the harness.
Hardware rendering used the NVIDIA RTX 4090 through ANGLE/WebGL2.

The [predeclared acceptance](acceptance-plan.json) and [derived receipt](PASSED.json)
cover the unchanged 42-cycle movement route, floor/console/roof/opening contact,
identity and scene preservation, and ordinary reconnect. The browser was closed
after parking the body on clear floor; its [harness exited zero](browser-exit.json)
and the owned browser process is gone. The private profile is preserved.

## Sustained movement

The complete route lasted **80.509 seconds**, with 4,831 animation frames,
4,424 simulation frames and six active projection renewals, all while a movement
key was held. Animation intervals were median 16.7 ms and maximum 31.5 ms; none
exceeded 33 ms. No focus/capture loss, unavailable message or refresh occurred.
The body remained 2 revision 1 in the same authority run throughout.

The [analysis](analysis.json) found **no occupied-floor refusal and no held-key
stationary interval of 100 ms or more**. The longest sampled interval was
50.5 ms. The prior [262 recording](../desktop-262-02/README.md) had reproduced
three native floor stalls of 382.6, 150.8 and 434.0 ms on this same route.
This is a bounded measurement, not a guarantee of zero pauses under every load.

Of 456 control responses, 455 were accepted. One definite `stale_registration`
refusal occurred 12.275 ms after a renewal; the next accepted response followed
21.796 ms later. All response bodies were captured. The longest stationary
interval within 500 ms of each renewal was 16.6, 34.3, 16.8, 17.0, 49.9 and
16.9 ms. The native authority/run fence never changed.

Stationary means consecutive animation samples with the same nonempty held-key
set and horizontal displacement at most 0.00001 metre. Durations are observed
sample bounds. Browser/network alignment used the median request clock offset;
the measured spread was 0.313 ms. Full frames, inputs, response results and the
derivation scripts are in the archive.

## Geometry, identity and reconnect

- The ordinary console returned the existing `me` principal at human height
  358 for `current_principal(P).`. The proof was stopped, not committed.
  [Screenshot](console-read.png) and archived DOM evidence retain the result.
- Console contact appears in 36 frames against body 4, including its authored
  sloped surface. The body clips against it; the console is not a box substitute.
- The low roof clips the moving capsule against body 3 at approximately
  `(8.060191, 0.752, 0.381712)` metres. Two consecutive contact frames retain
  exactly the same body position despite accepted movement.
- The positive-Z tall opening permits travel from z=5.248476 to z=8.081866,
  x≈0.693377. All 89 captured frames report only floor contact (body 1).
  The route stays inside the authored annulus. The [crossed-opening view](opening-crossed-17.png)
  accompanies the authoritative positions, rather than substituting for them.
- The [identity comparison](retained-view-identities.json) retains the exact
  authored scene and control/viewpoint terms from the preceding release. All
  six authored marks, decorative assets and parent frames remain present.
  Body 2 revision 1 and pilot definition revision 3 are unchanged. The camera
  keeps its authored 0.7 m eye offset, zero local position and authored orientation.

The original sign-in reached its existing ten-minute expiry after the long
movement and roof tests. The client paused physical travel and reported
authentication failure; it did not enable observer translation. Two subsequent
route attempts stopped at the ready-state guard before sending any movement.
Their failed exits and logs are retained. An [ordinary page reload](ordinary-reconnect-11-check.json)
reauthenticated the same profile and restored the exact position, body revision,
generation and incarnation. No signup, replacement body, deadline extension or
automatic retry of an uncertain domain write was introduced. The separately
labelled opening route then passed.

The [final parked view](final-parked-19.png) is ready at native body position
`(0.6933771512563647, 0.7519999915217519, 6.048491937791469)` metres.
All keys and pointer capture were released. Final deployment readback confirms
human/world heights 358/188, unchanged anchors and retained historical blocks.

## Retained harness corrections and scope

The archive preserves the initial window-identification mismatch, a console
return assertion that incorrectly expected its hidden draft textarea to vanish,
and a final diagnostic boolean that counted imported mesh primitives instead of
authored marks. The corrected mark check compares the actual six authored nodes
and their complete transforms. The first two offline acceptance verifiers also
retain their failures: the final current frame arrived in a projection envelope,
and textarea values are absent from `innerText`. The third verifier checks the
actual frame and rendered solution and exits zero. None required a live rerun
or weakened collision/identity assertion.

[Full evidence](evidence.tar.gz) contains 251 files with [verified hashes](files.json),
including the failed ready-state attempts, exact native contact frames, scripts,
screenshots, true exits and successful acceptance. Session connection details,
raw driver logs and private browser data are excluded. This establishes desktop
acceptance only; physical Vive/WebXR and durable real-world door consequences
retain their separate requirements.

# Signed desktop acceptance: partial, native floor snag reproduced

This is Yan's actual signed personal world, opened in the ordinary client with
the same private browser profile and origin used for the established baseline.
No fixture account, replacement world or refound was used. The private profile
is excluded from this archive.

Yan reported moving and falling into the central opening. The
[recorded frames](reported-fall-frames.json) confirm actual body travel and
descent through that authored opening, reaching the configured coordinate bound.
This is evidence that the opening was preserved, not a failed solid-floor
collision. The body remained the same anchored body 2, revision 1.

Recovery used the existing Prolog capability and signed control protocol:

- A guarded transaction temporarily granted `reposition`, agent revision 1→2.
- Signed control sequence 60 was [admitted](rescue-reposition-submission.json).
  Its separate [mechanical result](rescue-reposition-mechanical.json) reports
  clear placement at `(0, 0.760, 2.800)` metres.
- A second guarded transaction removed that capability, revision 2→3, and the
  [final signed read](rescue-state-final.json) verifies the original motion
  policy. The operation journal was empty.
- The [final frames](rescue-final-frames.json) show the same body settled on
  floor collider 1 at approximately `(0, 0.752, 2.800)`. Geometry, body revision,
  binding, world identity, authority, run and incarnation were preserved.

The recorder initially watched the socket that the normal client retired after
the policy change. Its observation deadline is retained. The network log shows
the automatic replacement projection; this was a recorder limitation, not a
failed client refresh. A local term-builder failure occurred before any write
and is also retained.

[Console collision](console-backward-01-summary.json) passed through normal
keyboard input: nine signed controls accepted, none refused, with contacts on
console collider 4 and floor collider 1. When the normal authentication session
expired during a later route, input stayed paused. An
[ordinary browser reload](ordinary-reconnect-dom.json) restored the same account
and existing body position without creating another account or world.

The [roof approach](low-roof-contact-01-STOP.json) **did not pass**. At
`(2.68794584274292, 0.7519908547401428, 0.36940792202949524)`, horizontal drive
repeated a floor contact without advancing. The roof was not reached. The exact
sample reproduces against the production native solver: floating-point slide
projection retains a tiny inward component and repeatedly hits at time zero.
This is a shared mechanical defect, independent of world naming or lobby rules.

An attempted console-opening recording later timed out in WebDriver while
releasing pointer capture; no console proof was submitted. Its stop marker is
retained. Earlier failed browser trials are under
[campaign 01](../desktop-260-01/archive-manifest.json).

Remaining desktop acceptance includes the corrected floor/roof/opening route,
live permission revocation/restoration and ordinary console use. The item stays
open. No Vive/WebXR or durable closed-door consequence acceptance is claimed.

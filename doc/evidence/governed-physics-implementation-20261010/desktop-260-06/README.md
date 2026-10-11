# Desktop campaign 260-06: movement stops with hardware rendering

This snapshot preserves the same private profile, signed account, actual world,
body and ordinary client view. The renderer is NVIDIA RTX 4090 through ANGLE
OpenGL 4.5. Yan reports smooth mouse look with hardware acceleration but
intermittent stops while walking and strafing.

The [movement trace](movement-stutters-01.json) and
[analysis](movement-stutters-analysis.json) capture 37 samples exhausting eight
contacts against floor body 1. At
`(4.832062244415283, 0.7518041729927063, 0.44425371289253235)`, accepted control
sequences 1124, 1125 and 1126 advance while position stays exactly unchanged.
Each reports the same floor contact eight times. This corroborates the shared
[native floor slide defect](../floor-slide-disposition.md); it does not establish
that every source of latency has been removed.

The initial rendering sample includes 16.7 ms frame intervals and two long
pauses; a later idle sample is roughly 1 Hz. These are not evidence of sustained
60 Hz rendering. Neither client interpolation nor authorization renewal behavior
was changed. The normal view renews authorization at its existing interval.

The [pre-update snapshot](before-release261-01.json) retains the body at
`(4.528850078582764, 0.7515183687210083, -0.4881959557533264)` and the authored
700 mm camera offset. At that point the idle authentication session has expired
and the view reports `authentication_failed`; input remains paused. Ordinary
reconnection and movement acceptance remain to be checked after release 261.

This is an immutable snapshot of selected public artifacts. The private profile
and the active driver's live log are excluded. The native correction is not yet
deployed in this record.

An appended [ordinary reconnect capture](ordinary-reconnect-pre261-ready.json)
confirms successful reauthentication, the same account and exact body position,
the 700 mm camera offset and unchanged authored scene attachments. The view
reports "Physical space ready." This still runs release 260.

The first capture immediately after reload ran before the scene existed. Its
script threw before calling the WebDriver completion callback and reached the
existing ten-second deadline. The stop record is retained. The browser remained
responsive and authenticated normally. The diagnostic now reports promise
exceptions and waits on the existing ready UI before reading the scene; no
production code, deadline or rendering policy changed.

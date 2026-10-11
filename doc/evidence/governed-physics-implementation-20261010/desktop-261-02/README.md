# Desktop campaign 261-02: retained identity, movement and opening

The ordinary signed view runs deployed release 0.7.261 with the same private
profile, account and actual personal world. The renderer is NVIDIA RTX 4090
through ANGLE OpenGL 4.5. [Retained view identities](retained-view-identities.json)
confirm the same six scene marks, pilot definition revision 3, body 2 revision 1,
structure 1 and authored 700 mm eye offset. The recovered authority generation
is 3. The [deployment record](../deployment-261/README.md) separately verifies
the unchanged anchors and retained ledger blocks.

The first [user movement capture](restored-physical-view.json) contains 1,229
physical frames with floor and console contact. The next
[capture](live-user-movement-02.json) contains 1,022 frames, also including
console contact. Neither contains the repeated eight-floor-contact pattern
observed before the native correction. These are the normal view and its real
installed physics owner, not a fixture world.

The [ordinary outward strafe](opening-outward-01-summary.json) passes the tall
opening on the positive-Z side, from `(-0.8145, 0.7517, 6.8201)` to
`(-0.6061, 0.7517, 8.0691)` metres. All seven collected signed control responses
are accepted; the 43 physical frames contact the floor and do not contact the
roof or console. The animation counter records 44 callbacks over 727 ms.
The short route stays on the authored annulus; no geometry, body pose or
reposition permission was edited for the test.

The return step failed in `Page.bringToFront` before sending keys. Chrome's
main thread was waiting in `anon_pipe_write`, and DevTools was unresponsive.
The [pipe measurement](browser-pipe-occupancy.json) found the stdout pipe empty
with its reader alive, disproving the initial output-backpressure explanation.
An internal pipe held 61,544 of 65,536 bytes; its purpose and the hang's cause
remain unknown. Kernel restrictions prevented thread-stack inspection; no host
security settings were changed. Only the verified test browser was terminated,
and its profile was preserved. Failed diagnostics and the corrected
[stop record](STOP.json) remain in this campaign.

The [offline analysis](../desktop-261-05/trace-analysis.json) also records
authorization-expiry refreshes and the time until replacement projections.
Keyboard state was not captured across those events, so these traces do not
establish whether renewal explains any remaining user-reported pauses.
Low-roof contact and longer visible movement acceptance remain open.

[SNAPSHOT.json](SNAPSHOT.json) hashes all retained public artifacts. The private
profile, signing keys and compiled Python caches are excluded.

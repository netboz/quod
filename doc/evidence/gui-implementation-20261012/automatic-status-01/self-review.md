# Automatic question status

Independent review; no Claude review was requested for this slice.

The existing controller now calls the existing authenticated status read when a
submitted question is projected or restored. It also checks after an in-flight
submission or saved-operation resolution finishes. A generation number retires
late UI results after a newer projection, disconnect or write. Unreadable local
custody and unresolved saved writes suppress these reads; cancellation still
requires a certified negative and is rechecked in Prolog.

No server code, work selector, request format, queue or timer changed. The existing
signed view already follows the exact ontology scopes opened by its proof, with
subscription-before-snapshot and owner recovery handling. Its existing whole-scope
invalidation supplies refreshes; this does not claim per-request-only wakeups.
Authorization renewal remains the existing view lifecycle. The terminal outcome
read reuses retained verified state and never submits the completion bytes.

Production delta: +24/-10, net14, in one controller. This replaces the practical
need for the withdrawn background observer; it does not promise eventual execution
of a lost live reaction. Such an interaction remains submitted until an actual
outcome or certified expiry permits the human's ordinary cancellation.

Final client-gate06:172 tests,0 failures,true exit0. UI build02:true exit0.
Server-gate01:9 tests,0 failures,true exit0,77.623s. Existing production-seam tests
cover signed status authority, certified expiry, cancellation, rollback, concurrent
operations and unchanged-read no-I/O behavior, plus six live application cycles.

Browser-result05 verifies desktop and spatial status/cancellation availability,
one original execute and one exact outcome lookup, two status reads, zero retained
operations and no browser errors. These browser transports are fixtures, not a
physical-headset acceptance claim. The failed result04 is retained: it sampled
the spatial model before React's effect delivery. The fixture now joins that
delivery explicitly rather than waiting a guessed duration.

Client gates01–03 only reported the file wrapper in the sandbox; they are not
accepted as individual-test evidence. Normal host execution in gate04 exposed
and passed all12 controller tests; gate06 includes the final thirteenth test.
Browser attempts01/02 used unsupported evaluation syntax (confirmed in Vite's
console); attempt03 did not complete and reported an approval-review deadline
after session closure. All failed/invalidated evidence remains. The later browser
run used a bounded Promise expression and a fresh session.

Physical validation subsequently found a separate modular Babylon XR construction
defect; see vive-gui-02 and the replacement call exercised in vive-gui-04. That
later scope and incomplete controller/placement acceptance must not be hidden by
this controller slice's passing gates.

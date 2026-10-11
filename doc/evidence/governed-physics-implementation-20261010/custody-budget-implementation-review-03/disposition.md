# Fable implementation review disposition

Fable's required deadline correction is accepted: a deadline expiring after
selection admission uses the existing interrupted completion. That restores
the conservative root dependency and withdraws new custody in the same owner.
The earlier precise-basis choice could leave admission withdrawn until a
selector predicate changed. No readiness polling or new retry path is added.

Independent review reproduced an additional scope error: the prior deadline
branch could withdraw root limits from a foreign ontology. A deterministic
real-owner regression suspends the selector and runtime, waits for the original
absolute expiry, then completes the worker before processing queued expiry.
It observed `{7,500000}` become `unconfigured`. The same interrupted-path
correction closes that window; withdrawal also explicitly matches root.
Fable's statement that this window is not deterministically testable is not
accepted: the reproduction uses existing owner instrumentation and an actual
deadline, with no native predicate or proof exemption. Both initial probe
fixture failure and genuine reproduction are retained.

Also accepted: log unavailable interrupted withdrawal instead of discarding
its error silently. Liveness remains governed by existing committed dependency
notices: an interrupted internal selector waits for the next root commit or
journal incarnation notice, and never polls. Failed policy is visible through
resource failures, journal limits and the configured gauge.

Optional byte-limit gauges and JS error metadata are deferred: exact bytes and
limits are exposed by the paired journal stats, public Prolog policy and typed
HTTP response/message. Existing count metrics retain their current meaning.
Single-writer and scope-specific unavailable mappings are retained; attestation
reserve and stage both pass raw unavailable through the same scope normalizer.
Byte pressure itself is identical and tested across all three signed lanes.
A missing journal's unavailable result remains visible; selection dependencies
are retained for owner restoration.

The suggested inclusion of `doc/README.md` is rejected: that is a user-owned
unrelated modification, explicitly excluded from this session's commit scope.
No current ownership or compatibility requirement authorizes taking it.

The implementation remains +48 production lines: governed paired limits,
withdrawal and useful typed errors replace the compiled cap and old API.
Corrected focused scope and a Fable correction review are required before the
final clean release gate and candidate deployment. No live acceptance is claimed.

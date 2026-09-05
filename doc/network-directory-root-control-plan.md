# Root directory control

**Status: implemented with the fact-backed generation wire; activation awaits the coordinated Slice-6 re-found.**

Root control peers provide an authenticated relay surface for directory
generations. They do not own routes, hosting truth, target authorization, or
service discovery. `quod_directory_control` owns links, signed-generation
renewal, relay, resynchronization, and validation orchestration;
`quod_directory` remains the sole live-index writer.

The current root `directory_control_peer/1` facts select relay peers. Root join
contacts may locate those keys, but a contact is retained only after its TLS key
matches the proved root set. Control links do not populate the ordinary QUIC
address cache.

The namespace manager sends one revisioned snapshot of ready public hosting
facts plus local private contacts. Directory control signs the public snapshot
as a complete paged generation and installs the private projection locally.
Renewal re-signs the same current facts; it does not rescan processes or invent
authority.

Every control link carries only `{quod_directory_generation, SignedPage}` and
`quod_directory_generation_resync`. A receiver accepts a direct node-actor
generation only from the matching authenticated key and endpoint. Relayed
generations are accepted only on a current root-control link. Complete
generations are validated asynchronously through the existing certified
foreign-log projection, installed atomically, and relayed onward. A newer
complete generation supersedes an older validation worker; stale results are
ignored by their request token.

Cached generations are served only while their lease is live. Process monitors
remove dead validation/link work. Timeouts are terminal failure safeguards, not
progress polling. An exact `route_needed(Identity)` from an existing consumer
is deduplicated here and immediately drives the same control-link resync; the
lease-renewal tick never polls for missing routes. Directory control subscribes
to root's runtime projection: replay readiness and committed
`peer_admitted/4` changes refresh the relay-authority set immediately. The
lease tick maintains only the already-authorized control transports, so a
quiet node can reconnect after transient network loss without using route
demand as a polling mechanism.

Configuration contains root contacts, the local node identity, and root's
founding material. It contains no general namespace/key allowlist. A
root-bootstrap generation is accepted only when signed by a current root
control peer and when all system rows match the current committed root
catalogue. Ordinary node generations require the exact certified node-actor
facts described in [network-directory-plan.md](network-directory-plan.md).

This is not FIPA DF service discovery. A later DF maps service descriptions to
anchored agent identities; the directory maps already-known ontology identities
to current network contacts.

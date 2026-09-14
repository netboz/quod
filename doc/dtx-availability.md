# DTX admission during catch-up

A participant's anchored admission binding survives temporary catch-up. A new
atomic Begin enters the existing proof-owned FIFO and waits under its original
caller deadline. Readiness permits signing, not membership. A long catch-up can
therefore consume the caller's remaining allowance instead of immediately
returning `ontology_unavailable`; expiry keeps the existing `proof_limit_exceeded`
reply and signs nothing. Boot without a projection, non-membership and mismatched
anchor/admission bindings remain refusals. Admission is checked again before
promotion, so recovery cannot carry an obsolete binding into signing.

`submit_remote_claim` and `submit_effect_foreign_claim` deliberately remain
**ready-strict**, using `dtx_ready_binding`. Their custody registration has no
existing wait, so lag is refused before attestation or custody work. The target
private-effect binding and effect journal also keep their ready-strict checks. There is no second
queue. Internal signing, endpoint and custody readiness requirements are unchanged.

## Bounded preference for local parent validation

The existing namespace `validation_ttl_ms` (default 2000 ms) also bounds how
long Simplex prefers its already-requested next-parent verdict over recovery.
The absolute monotonic deadline starts before dispatch and survives the handoff
to foreign-reference verification. That worker's separate evidence allowance
is unchanged. Prolog's parked-request TTL uses the same configuration/default.

When the preference expires, the existing 300 ms tick (or earlier progress)
may arm recovery. Expiry is not a verdict: it neither rejects the block nor
clears the validation latch, and cannot spawn another request to a stuck owner.
An exact valid answer can still advance the head while recovery runs. Once a
recovery window re-seats the engine, its old request is gone and a late answer
is an exact no-op. Discarding those rounds also releases their validation
monitors through the existing cleanup. The deadline grants no voting or signing authority.

**DTX-INLINE-VALIDATION-EXECUTION-BOUND-01 remains open:** inline Prolog
authorization re-proving has no hard execution bound. Bounding the recovery
preference does not bound that computation; no executor, kill, timer or KB
copy is introduced here. Recovery classification (scope B) awaits review of
the post-change 16-request atomic c4 witness.

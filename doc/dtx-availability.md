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

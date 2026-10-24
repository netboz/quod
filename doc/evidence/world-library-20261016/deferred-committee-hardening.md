# Deferred committee ingress hardening

The world-library release preserves the documented trusted-validator
execution boundary. Material admission is enforced by the sealing proposer;
its policy reads use ordinary OCC validation. Encoding and VM headroom checks
remain. See the [independent notes](review-04/independent-notes.md) and
[Fable's corrected consultation](review-02/admission-consult-final.md).

If protection against arbitrary atom allocation by admitted committee members
is later requested, treat it as one coherent ingress change. The existing
consensus ETF decode already allocates atoms before dispatch, predating this
refactor. Hardening one materializer does not close that boundary.

The design must trace ordinary proposals and relayed submissions, atomic
plans, independent applications, and uncertified claims of certified blocks.
It must retain wrapped symbols until the existing validation owner checks
fresh admission or verifies finality. Certified replay must remain independent
of today's policy. Define ordinary-transaction accounting and policy-change
race outcomes explicitly before changing consensus refusal semantics.

No implementation of that broader change is included in this release.

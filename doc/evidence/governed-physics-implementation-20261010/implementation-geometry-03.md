# Shared geometry: refusal contract correction

This supplements the frozen `implementation-geometry-02.md` evidence. The full
governed-physics feature remains unimplemented and unaccepted. Fable reviewed
that earlier tree and found one remaining regression: reasoned coordinate
failure leaked from the common scalar helper into control, motion-query and
recovery readers. The signed input protocol requires these policy refusals to
remain ordinary failures.

The shared coordinate predicate is silent again. Authored body pose, geometry
and dimensions use a body-specific wrapper to attach coordinate-allowance
reasons; malformed encoding still reports invalid-body refusal. The native
encoding algorithm remains shared. Documentation now includes motor scalars.

The existing signed owner test now checks that refused speed, angular input,
push impulse and motion query add no `coordinate_allowance` reason. It preserves
the protocol's normal failed-goal breadcrumbs. The body-edit test continues to
require the actual coordinate allowance in its explicit refusal.

- `control-reasons-01`: child exit 1; the signed drive reproduction contained
  `coordinate_allowance(2000)`. Its initial assertion also incorrectly expected
  the entire failure list to be empty. The failed fixture remains at
  `/tmp/quod_hosted_3ACCA4448D2AE3D1`.
- `control-reasons-02`: 13 tests, one failure, exit 1. After the production
  correction there was no coordinate-allowance reason; the test still rejected
  normal goal breadcrumbs. Its evidence and failed fixture remain intact.
- `control-reasons-03`: corrected assertion checks absence of the added reason;
  all 13 focused owner/schema/native tests passed, exit 0, hashes stable.
- `owners-geometry-03`: physics, control, runtime and space owner modules passed
  all 178 tests, exit 0, source hashes stable. This is a new verification after
  the shared production predicate changed, not a rerun replacing prior failures.

The earlier unattributed datasync remains unexplained. No trace assertion was
weakened and no successful run establishes that its cause is resolved. Remote
invalidation/work measurements and real signed desktop acceptance remain open.

Current production delta is Prolog +71/-13 and native +2/-0, net +60 lines.
Documentation adds 9 lines; tests +138/-2, net +136 lines. The additional four
production lines isolate authored-body reasons from the shared input contract.
No new process, broker, mutable collider store or capability-loading path exists.

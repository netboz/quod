# Withdrawn after architecture simplification review

Yan requested an architecture review for simplification. The candidate added
81 production lines and removed27 (net54) across five production files, including
a change to the shared work selection API and runtime snapshot message shape.
Final gate07 passed90 tests with true exit0,15.140s; earlier failures are retained.
This establishes that tested mechanics worked, not that this was a useful GUI
architecture. No GUI selector or GUI result consumer had been added.

The proposed observer sends signed reads and publishes agent_request_finished.
Source tracing finds no production GUI subscriber to that notification, and the
runtime's agent_owned_result consumer handles only its existing physics jobs.
Therefore the new work does not change question state, deliver a HUD status, or
resume an unexecuted continuation. Connecting those results would require yet
more machinery without first establishing a missing user-visible capability.
It is not a solution to automatic GUI recovery, even if wired into a selector.

The complete candidate source and tests are frozen in withdrawn-tree with hashes
and a diff. Live files were restored byte-for-byte from this scope's before tree;
all earlier GUI, outcome, native opening, unrelated work and failed evidence are
preserved. The candidate-only tests are retained in that frozen tree rather than
claiming coverage for an API no longer installed. Existing execution, custody,
read-outcome and lifecycle tests remain live.

The same-height notification correction belongs to the withdrawn candidate's
new request-delta consumer. Existing physics outcome notifications use the
separate detailed projection_advanced message, and ordinary resource policy
readers already have the prior snapshot contract. Keeping the new cursor and
message shape without their consumer would retain speculative infrastructure.
No independent pre-existing defect has been established by those candidate tests.

This does not waive automatic recovery acceptance. It rejects an implementation
that supplied background reads without a consumer. Retained question state,
exact completion bytes, existing committed outcome reads and the human's status/
cancel actions remain. No uncertain completion may be resubmitted; no automatic
recovery or headset completion claim is made.

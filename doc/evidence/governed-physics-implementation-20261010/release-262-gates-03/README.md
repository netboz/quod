# Candidate 0.7.262 — clean release campaign 03

All eleven sequential stages passed on the frozen source tree with true child
exit zero and unchanged source hashes. The parent runner also exited zero.
The source manifest covers 684 inputs and records the proposed 0.7.262 label;
that label is committed separately from implementation. The UI output manifest
covers 176 browser assets.

Verification includes native debug/release tests and Clippy, 134 client tests,
UI build and lint, 3,884 EUnit tests, 146 Common Test cases, xref, Dialyzer and
production release packaging. Full logs, per-stage receipts, exact source inputs
and output hashes are retained. Test schedulers were bounded to four; the tests
used their real loopback production seams without desktop input.

Campaign 01 retains its two obsolete-request fixture failures. Campaign 02
retains its Dialyzer unmatched-return warning. Their corrections are documented
with those stopped campaigns; neither failed run is relabelled as a pass.

Fable approved the plan and main implementation. Opus 5.5 approved the narrow
follow-up after the second Fable invocation was refused for exhausted credits.
The only production change after Opus's packet explicitly discards the timer
cancellation return list; its exact diff and independent disposition are retained.

This gate pass establishes build/test evidence, not deployment or desktop motion
acceptance. The existing signed world and its history remain the desktop target;
no refound is necessary for the renewal fix.

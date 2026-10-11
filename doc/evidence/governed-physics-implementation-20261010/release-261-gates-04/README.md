# Release 261 gate 04: interrupted after review

The exact frozen scope passed native debug tests (22), native release tests (22),
Clippy, client tests, UI build and UI lint. EUnit was still running when Fable's
[implementation review](../release-261-test-implementation-review-01/fable-review.md)
found an unbounded `supervisor:which_children/1` call in the new test cleanup
helper. The cleanup deadline did not cover that enumeration.

The [interruption intent](INTERRUPTED.json) was recorded before SIGINT was sent
to the verified process group for this campaign only. The
[result](interruption-result.json) records runner exit 130 and confirms no group
processes survived. The interrupted EUnit child has no retained final exit or
completed result; no EUnit success is claimed. No later gates ran.

All partial test output, exact inputs, manifests and completed-stage exits are
retained. The final correction removes the redundant child enumeration and
monitoring, using the existing bounded OTP stop directly. New gate 05 checks the
separately frozen corrected tree. No server mutation occurred in this campaign.

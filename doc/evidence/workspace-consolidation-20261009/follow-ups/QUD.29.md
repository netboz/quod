# Diagnose intermittent full-suite timeout in saltless_draw naming tests

Local tracker: [QUD.29](nimbalyst://QUD.29). Tracker metadata and local body are saved; collaborative body storage failed on creation and retry. This file preserves the complete task description.

+Retained failure from failure-reasons release-08: EUnit saltless_draw case 5 exceeded its existing default 5-second timeout; 3488 tests, 0 assertion failures, 3 cancellations. The observed stack was recognition/failure-reason encoding. Exact random proof seed was not captured. No root-cause fix is claimed.

Evidence: /tmp/quod-failure-reasons-01/release-08/cancellation-triage.json and gates/eunit.log; names-cost-22 removable diagnostic passed all 9 tests without changing assertions/deadlines, maximum observed origin time 470824 microseconds. Exact-source release-09 later passed 3805 EUnit tests with zero failures/cancellations. Full failed and passing receipts are retained.

Use bounded removable tracing and reproducible input/seed capture to distinguish computation, mailbox, I/O and protocol waits through production owners. Do not extend deadlines, weaken assertions, hide failures or rerun until green. Change production only after a causal reproduction. Verify unchanged repeated operations and retain campaign identities. This is separate from the qualified failure-taxonomy change; no live deployment failure has been established.

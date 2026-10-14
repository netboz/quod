# Integration verification receipt

Final gate05: **303 tests, zero failures, true exit0, 205.870s**.
Modules: reaction metadata, agent hosting, agent vault, agent reaction, full physics
and scope session. Source was held unchanged throughout this run. Final and
combined manifests verified against live files; all frozen before/tree/followup
manifests verified. git diff --check passes. All child exits collected; no active
jobs remain. No commit, deployment or hardware validation.

Gate01: compile failure, exit1; missing test tuple brace. Original source retained.
Gate02:24/0 exit0,1.747s focused metadata and actual retained-agent dispatch.
Gate03: known failed run, stopped after diagnosing a missed current_signed_request/2
call in quod_hinged.pl. VM accepted SIGTERM and returned exit0; this is explicitly
**not a passing test result**, and no final count is claimed. Log and original
frozen tree retained. followup01 migrates that caller; no compatibility shim.
Gate04:1/0 exit0,5.498s actual hinged signed view/recovery fixture.
Gate05 is the complete clean final integration result above and also covers the
retained-request-01 code and vault trace-isolation correction.

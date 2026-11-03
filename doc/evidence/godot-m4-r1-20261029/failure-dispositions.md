# R1 failures and unresolved hypotheses

gui-final03-backup-import remains failed after its historical direct test quit.
physics-final06 remains failed after normal Main.CloseApplication:39 assertions,
M3_PHYSICS_PASS, client-9/wrapper1/server0 after the unchanged watchdog. The exact
coordinator source/output verification is retained in the original evidence.
Neither failure had an original stack. Neither is reclassified by the R1 passes.

H1 (pending managed retirement), H2 (main-thread scheduling/unobserved close
fault) and H3 (engine/resource/native-driver destruction) were not reproduced.
Successful diagnostic phases distinguish these boundaries in the observed runs
only. In particular, the active backup did require an asynchronous await and
returned to the Godot main thread before identity release. These observations
do not prove the historical failures external or native-only. No speculative
production correction was made.

Bounded attempts: two observed diagnostic physics runs; one exact historical
final04 export with original flags; one local active-backup cancellation. No
indefinite soak or additional product test rerun followed their success. No
stall triggered the pre-watchdog capture; the capture branch is unexercised.

Preflight failures remain diagnostic failures, not product campaign passes:

- The first sandbox tracker radar invocation returned kill/ESRCH and exit1.
  The authorized explicit-project caller succeeded with escalation; nested
  radar/read/link outcomes were inspected. linkedCount0 is not visible attribution.
- Creating the new task cache inside the sandbox returned read-only filesystem
  before creation. The authorized separate cache was then created with escalation;
  no old artifact or cache was deleted.
- The first evidence-wrapper invocation put --timeout after the positional label.
  Its REMAINDER parser attempted to execute --timeout and failed before launching
  a build child. Its empty raw file is retained; no inner child exit is invented.
  The separately labelled corrected invocation built diagnostic01 successfully.

All three actual physics clients and the local client exited0, as did their
campaign wrappers and owned physics servers. No timeout or engine diagnostic
was ignored. All earlier source/build/campaign failures, private stores and
snapshots remain unchanged. Unsupported retractall/proof_unavailable and the
M1/M3b original unknown outcomes were never cleared, resubmitted or relabelled.

Monado's missing OpenCV4.13 ABI is an independent known loader dependency.
R1 did not alter packages, runtime/config/display/session/socket or another app.
Native OpenXR session/swapchain/profile RID teardown, SESSION_NOT_STOPPING,
spatial-discovery diagnostics and physical Vive pixels/poses/gestures/comfort/
platform exit remain unqualified. USB and injected frames do not qualify them.

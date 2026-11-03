Claude Fable consultation report (read-only, 21 approved files under /home/yan/.cache/quod-m4-r2-coordinator-verification-21-corrected02; no commands, edits or tests; stop-notification script not invoked per read-only scope). Yan asked me to forward this to you directly.

VERDICT: No demonstrated defect in the application close chain for the two retained desktop stalls (gui-final03-backup-import, physics-final06). One confirmed harness reporting gap and one latent application ordering window, neither proven as the stall cause. Consultative only; verify against the code.

FINDINGS

A. Harness stdout reader cannot distinguish "child hung" from "reader thread died" (confirmed, both production drivers). client/godot-tests/local.py:47-50 and journey.py:245-249 read child.stdout in a daemon thread and post None only on normal loop exit; a reader exception (strict UTF-8 text mode) ends the thread silently, so lines.get(timeout=60) trips the watchdog. Counter-evidence for the historical runs: result.json shows child_exit -9, so the child was still alive at SIGKILL, and no traceback is in either log. So A does not explain the stalls, but it is a real reporting gap. shutdown-connect.py:64-68 and the renewal campaign already record reader_errors; the production drivers do not.

B. SignedView renewal timer is outside every awaited completion (confirmed structure, unproven cause). Core/SignedView.cs:99 fires ExpireOrRenew unawaited; Completion (:39) covers Receive only. Cancellation is correct: Dispose (:122) cancels authorization and lifetime; ExpireOrRenew catches OCE (:112); a renewal Open inside BeforeOpen (Main.cs:251-261) uses lifetime.Token through SignedSession.SendAt -> Transport.Send (:131-134, :80), so HTTP sees cancellation. Residual: Main.CloseSession Finish (:347-351) disposes the Transport after Task.WhenAll(completions) which excludes the renewal task, so HttpClient.Dispose can race a cancelled in-flight renewal. In .NET this is benign, not a hang. Observation02 (five timers retired 4,3,2,1,0 before quit) is consistent; it never exercised an automatic BeforeOpen, so B stays a hypothesis.

C. CloseApplication chain has no unbounded wait on the historical desktop paths (ruled out). Main.cs:450-457: closing latch, cancels action/backupCancellation, CloseSession, awaits ViewsDisposed/activeAction/backupWork/xr.Completion, models.Dispose, xr.Shutdown under absolute 5 s deadline (:455), Quit. OpenXR uninitialized on desktop so Shutdown returns at OpenXRInput.cs:307. activeAction bounded by the 5-minute CTS in Run (:138); backupWork Apply (:420-442) awaits ReadAllTextAsync and Task.Run(Decrypt) without a token (:433-434) but both completed before close in the log (backup-import.log line 21). _ExitTree (:458-464) releases identity only when all three tasks are complete; correct.

D. Disconnect then CloseApplication in the same run composes two Finish chains (benign, verified). backup-import.log lines 52-57: Press("disconnect") -> CloseSession -> ViewsDisposed=Finish(); ExportLifecycle.cs:392 awaits it; CloseApplication calls CloseSession again (:452) composing WhenAll(ViewsDisposed, Finish()) (:352) with empty views and null session. Log line 57 shows live_sockets 0 after M1B_LOCAL_PASS, so socket retirement completed.

E. Latent ordering window (real, ruled out for these two runs). CloseApplication awaits xr.Completion (:453) BEFORE models.Dispose() (:454). OpenXRInput Load (:197-206) awaits Lease.Instantiate -> entry.Ready -> fetch with entry.Lifetime.Token (RenderModels.cs:65); only Retire/Dispose (:92, :96) cancels it. A stalled model HTTP body would hold xr.Completion up to the asset deadline (Main.cs:74-75, consumer.Deadline <= 5 min), exceeding the 60 s watchdog. Both historical logs show Acquisitions 0, so no fetch existed; not the cause here.

HYPOTHESES (not established)
1. Engine-side quit stall after GetTree().Quit in desktop/OpenGL/Wayland teardown. Both stalls occurred after the PASS marker with live_sockets 0, proving CloseSession ran, but no production marker exists after Quit, so the logs cannot separate "stuck before Quit" from "stuck in engine teardown". The xdg-toplevel-icon warning marks the compositor path as the only one uncovered by managed evidence.
2. Finding B interleaving (automatic BeforeOpen in flight at Dispose). Not exercised by any retained observation.

MISSING EVIDENCE
- A native stack for a recurrence on the same desktop configuration. local.py:56-64 now captures it at watchdog; the historical gui-final03 result.json has no diagnostic key because that branch did not exist then.
- One managed marker after GetTree().Quit returns in production (the diagnostic build has exit-tree-return; production does not).

TWO BOUNDED DISCRIMINATING OBSERVATIONS (no patch, no deadline change)
1. Re-run gui backup-import once on desktop with the current local.py. If it stalls: GDB showing managed threads idle and the main thread in Wayland/GL teardown -> hypothesis 1; a managed thread parked in HttpClient/WebSocket receive -> B or E. A pass yields no inference.
2. Read the retained renewal-owner-observation02 client log for quit-requested -> exit-tree-return timing (not in my approved 21 files; I did not read it). Multi-second lag on desktop makes hypothesis 1 plausible under the 60 s watchdog; sub-second lag weakens it.

Yan's short-form decision from this session: nothing in the app needs fixing today; stop re-reviewing the close chain; do observation 1 and add the single post-Quit marker.


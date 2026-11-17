# R2 shutdown diagnosis scope

This evidence maps the existing QUO-65 scope; it is not a second tracker status.
The original gui-final03-backup-import and normal-close physics-final06 failures
remain failed. Both were desktop/OpenGL runs without native OpenXR. No original
thread stacks exist. Neither the Monado ABI repair nor later successful closes
identify their cause.

The managed chain remains Main.CloseApplication → cancel action/backup →
CloseSession → retire world/views/source/forms/questions/input/model loads →
await owned work → retire immutable templates → request native session stopping
under the existing absolute5s deadline → release identity → engine quit → tree
exit and engine/driver destruction. The current output harness also owns stdout
draining, EOF, process wait, native input, fixture output and fixture shutdown.

R2 discriminates concrete waits rather than repeating R1's completed physics
path. The pending-sign-in probe delivers a real native window-close event only
after an owned TLS peer receives the actual challenge request and deliberately
withholds its reply. It generates no domain response and submits no domain
write. Temporary Main/SignedView phase observation is supplied to a separate
source-only diagnostic build; live production remains free of tracing.

shutdown-connect-diagnostic01 records activeAction WaitingForActivation at close,
then cancellation observed by the TLS peer, completed owner/transport/model/XR
retirement on GodotSynchronizationContext thread1, identity release, quit request,
tree exit return, output EOF and client0. Its receiver and peer threads also
finish. This rejects a deterministic cancellation/main-thread deadlock for that
controlled wait. It does not reject every possible transport interleaving or
explain either historical failure.

The original journey/local/physics stdout readers use daemon threads and strict
UTF-8 without explicit reader-error propagation. Their old logs contain no
reader exception or Unicode traceback. A missing EOF notice alone cannot
explain a child still alive when SIGKILL returned-9. No evidence yet attributes
the historical stalls to this possible harness failure. No speculative decoder
or process-success workaround is installed. Existing preexec ptrace setup runs
before exec and cannot by itself explain a post-assertion hang.

Native API-layer observation caught two separate render-owner errors: a hidden
SubViewportContainer disables its child's update mode, and stretched layout
prevents the mono view-count reset. The first R2 correction accidentally placed
visibility last, so its fresh pose/view-count assertions masked absent rendering.
That failed evidence remains intact. The final ordering releases stretch, sets
presentation visibility, sets XR/mono layout, then installs the owned update
mode. Native-simulated04 observes one real stereo swapchain,269 acquisitions,
269 releases,269 two-view submissions and one destruction, plus actual draw
work in every cycle. This fixes the demonstrated render issue; it is not a
desktop shutdown-stall attribution.

The first real-wand observation also demonstrated that the exported test's error
catch bypassed normal shutdown, reproducing SESSION_NOT_STOPPING. The shared
close owner now accepts the failing exit code and that caller awaits it. Final
intentional output-I/O failure exercises that running native session path,
preserves1, reaches EOF and removes the owned client without SESSION_NOT_STOPPING.
Two pinned-engine diagnostics remain failed. Minimal direct-quit negative repros remain
separate; they are not production success paths.

Before an owned stall reaches an unchanged watchdog, diagnostic drivers arm
one bounded native capture. GDB prints no frame arguments or entry values and
captures no memory dump, environment or command line. Raw stacks remain0700/
0600 private; public analysis must be redacted. Native client watchdog90s,
desktop inactivity watchdog60s and original owner deadlines remain unchanged.
Failure-trigger capture is observation, not readiness polling. If no real stall
occurs, no historical native/managed wait attribution is invented.

## Renewal hypothesis and attribution limits

SignedView.Completion covers Receive; automatic ExpireOrRenew is separate.
This is a concrete ownership question, not a demonstrated historical hang.
Diagnostic-only renewal observation02 counts five pending timers at close and
zero at transport retirement, owner retirement and quit. All14 observed renewal
events retire in that case. No automatic BeforeOpen was reached, so a blocked
automatic reopening interleaving was not exercised. No speculative SignedView
correction was made. Main/SignedView observation exists only in retained
non-distributable builds; the production export remains free of tracing.

The first renewal diagnostic build failed because an instrumentation rewrite
changed a method call as well as its declaration. A dependent observation was
started prematurely and failed without a usable client. Both failures remain.
The separate corrected build passes, and the campaign now validates the actual
completed build manifest and every export hash before starting its fixture.

Headless GUI observation initially times out with its pointer outside64x64;
the generic resolution request does not change that headless viewport. The
existing controller test's explicit headless window setup now belongs to the
shared qualification entry point. Its fresh/reset/m4-live phases then pass,
including real signed preference repair and resource reuse. Full headless GUI
still fails at the required native window-close delivery; that assertion is not
skipped or replaced. Actual desktop final03 passes the complete GUI/backup path.

Desktop final01's native input guard fails after its click changes focus to
another PID. The reason is unknown. It kills the owned client before a close
request; it is not a shutdown-stall reproduction. The shared test driver now
refreshes owned geometry after focus, validates cursor/geometry before clicking,
and records the target. Addressed close does not require a retired window to
remain focused; real process exit/EOF still determines campaign completion.
Later passing checks do not retroactively attribute that guard failure.

The final qualification receipt maps affected true exits. No new stall has
supplied a stack for either original failure. They remain failed, desktop-only
and unattributed; no Monado, native-only, direct-quit-only or stronger-model
explanation is established. Future causal closure needs a discriminating real
trigger and the retained bounded observation on the actually offending process,
not another indefinite happy-path repetition.

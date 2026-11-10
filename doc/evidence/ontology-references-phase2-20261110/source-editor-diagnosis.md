# Complete-source editor diagnosis

Client campaign 01, source-ui-trace-01 and proxy-stack-02 each exit 1 at the
unchanged watchdog after complete source assembly. Their logs and private
fixtures remain retained. The actual editor contains approximately 495,845
characters at width 8 with boundary wrapping; Godot consumes about 93% CPU.

The standalone controls at normal and eight-pixel widths all complete quickly.
They are not reproductions of the full layout failure. A single Python proxy
thread snapshot shows its sockets waiting normally, rejecting the shared-lock
hypothesis. The native stack capture exited 1 because the watchdog had already
ended that process (`No such process`). Proxy-stack-01 exited 1 before its
journey on a diagnostic import-path error, corrected in the separately labelled
run 02. No claim is based on that failed setup.

The controlled actual journey disables wrapping on that same editor after the
complete bytes arrive. It exits 0 in 43.54 seconds, with source renewal,
revocation, exact reopening, update invalidation and all remaining GUI checks.
The temporary tracing and override are retained as source-ui-diagnostic.patch
and removed from the test. The production correction is the existing shared
FormPanel structured-text editor's wrapping setting. Complete lines remain
scrollable, with no text quota, dropped content or timing change.

The fresh clean client campaign verifies that setting without diagnostic code.
Server implementation, ontology, Erlang tests and server-gate inputs are unchanged.

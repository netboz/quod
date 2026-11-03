# Case22 — failed before wrapper child launch

The controller-power answer and accepted morning seal were both present before
the one explicit-PTY launch. Current ownership/provider preflight passed and
restored HDMI disabled, other display settings and configuration unchanged.

The launch then exited **2**: `launch.py` supplied `--timeout 2100` to the
unchanged `manual_run.py`, whose parser accepts only a label and command. Its
existing child watchdog is already 2100 seconds. Parsing stopped before the
wrapper body, fixture, runtime or application. FIRST_DRAW and the human journey
are **UNRUN**. No retry or source correction was executed.

The actual tool responses are retained in `execution-receipt.json`. This was a
combined PTY transcript; separate child streams, reader EOFs and resource
lifecycle observations do not exist for an unlaunched child. `preserve.py` only
copies and binds existing small invocation/preflight files, including original
full modes. It performs no live query, display action, process launch or export
audit. Raw provider/ownership/display data stays private under the task Data
root. The accepted parent snapshot remains unchanged.

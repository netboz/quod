# Portable question client primitives

Independent source review, not Claude. These extend world.js's existing signed
ontology projection helpers. There is no new endpoint, journal, execution path
or client-owned question status.

HUD discovery signs gui_pending_questions under the selected human. References
must be ground, proper, anchored, nonempty and unique. Status reads use the exact
responsible scope and accept only the common terminal/awaiting vocabulary. Unknown,
proof-unavailable and denied replies throw rather than permitting cancellation.

Submission is a pure goal builder. It uses the opened revision and authored
control identity, requires exactly the projected input fields, and converts local
text to binary data, selection to a declared ground option and numbers to supported
integers. Both renderers already use the same numeric/text presentation helpers.
Current ontology schema, authority, readonly/disabled policy and atomic transitions
remain the server's responsibility. The controller must retain its existing busy
and uncertain-operation lock before passing the goal to signedGoal. No new write
wrapper bypasses that ownership. Cancellation is likewise an ordinary goal builder.

These primitives are not yet a mounted question controller, live HUD subscription,
opening receiver or proof of headset usability. Those remain integration work.

Gate01: focused world tests pass (true exit0). Gate02: all15 client test files pass,
zero failures, true exit0. Gate03: TypeScript and Vite UI build pass, true exit0.
Exact frozen/live files match manifests. No commit/deployment/hardware validation.

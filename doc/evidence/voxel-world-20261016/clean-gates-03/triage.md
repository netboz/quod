# Dialyzer stop

Native tests/checks, 206 client tests, UI build/asset identity/lint, 4,051 EUnit
tests, all 148 Common Test cases, and xref passed on unchanged frozen inputs.
The campaign stopped at Dialyzer's true exit 1; the release build did not run.

Five unmatched-return diagnostics are the same command helper:
`send_view_resource/2` returns the message tuple produced by `!` although its
callers need only command completion. Give that helper an explicit `ok` result.

The sixth diagnostic exposes a redundant owner transition: camera-clearance
projection calls `request_terrain/2` but discards its returned state. Tracing
both callers shows that `refresh_terrain` already computes and records the
same native eye-region demand on watch and every published frame. Remove the
duplicate request from projection; keep the consumer lifecycle as its sole
owner. A missing query result remains null until installation. Verify a real
camera whose clearance region extends beyond its body's retained support,
including repeated watch/renewal without new generation or duplicate demand.
Do not suppress the warning or explicitly discard state. Keep the log, source
manifest and STOP marker intact.

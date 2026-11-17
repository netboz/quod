# Phase 2 gate run 01 stopped

`server-gates-phase2-01.py` was killed at 09:42 UTC on 2026-11-12, during
`phase2-server-01-eunit`, when the Claude Code session restarted for a model
change. That was not a test failure. The partial eunit log is kept as it was.
The client gates in that chain never started.

Run 02 uses the same frozen tree (`phase2-01-tree.diff`, checked unchanged
before it started) under new labels, `phase2-server-02-*` and `phase2-client-02-*`.

# Release 259 gate 02: retained Dialyzer failure

This scope froze the earlier implementation before Fable's deadline and
withdrawal-result correction. Native tests, Clippy, client tests, UI build and
lint, EUnit (3,877 tests), Common Test and xref passed. Dialyzer exited 1 on
2026-10-11 with one unmatched-return warning at `quod_runtime.erl:1103`: the
internal interruption path discarded `withdraw_limits/0`'s possible error.
Release packaging was not run. The frozen sources remained unchanged.

The corrected implementation handles both `ok` and `{error, Reason}` and logs
the latter, as independently checked and approved by Fable correction review
03. It also scopes withdrawal to root and routes post-admission expiry through
the existing interrupted completion. No extra production change was needed
for this warning; final gate 03 was prepared from those reviewed corrections.

This failed campaign is retained in full and cannot authorize deployment.
Gate 03 runs separately and sequentially after this true child exit.

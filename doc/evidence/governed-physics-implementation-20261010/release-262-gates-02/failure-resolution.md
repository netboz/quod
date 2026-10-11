# Dialyzer stop in clean campaign 262-02

The unchanged frozen campaign passed 3,884 EUnit tests, 146 Common Test cases,
134 client tests, native debug/release tests, Clippy, UI build/lint and xref.
Dialyzer exited 1: the list of timer cancellation results in release/1 had an
unmatched return value. Release packaging did not run.

The shared source now explicitly discards that list with `_ =`, matching the
existing intentional-discard convention. Cancellation calls and their order
are unchanged; no warning or assertion was disabled. The stopped tree and all
logs remain intact. Verification continues in a separately frozen 262-03
campaign. The running Opus review covers the preceding semantic snapshot;
this discard-only correction is independently checked against its exact diff.

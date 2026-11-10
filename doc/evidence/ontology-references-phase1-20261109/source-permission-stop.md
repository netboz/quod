# Source permission conflict — intermediate Phase 1 stop

The existing physics source delegation is independent of source invocation
and display permission. The signed reader now observes that invocation ACL;
withdrawal invalidates physics even when its source delegation remains valid.
This contradicts the existing behavior required by the production source rule
and its control-continuity test. No new permission rule or workaround has been
written to reconcile this conflict. Phase 1 is incomplete.

Evidence: `priv/ontologies/quod_physics.pl`, the comment and rule for
`physics_definition_projection/5`; `test/quod_physics_tests.erl`,
`live_source_control_continuity_test_/0` and the source disclosure withdrawal
assertions in `m3a_shared_projection_test_/0`.

The earlier `non_control` error had a separate cause: propagation treated a
signed control proof's durable-write restriction as a prohibition on transient
input. `read_mode/1` now propagates the full read-only restriction only when
transient permission is absent. Nested scopes retain their independently
verified request restrictions. Temporary diagnostic tracing has been removed.
The first control command now succeeds; the remaining failure is Command(2),
after source invocation ACL withdrawal. Its normalized failure is `reinstalling`.

Validation, true child exits (all logs retained beside this report):

- `precise-read-compile-01.log`: exit 0.
- `precise-read-focused-01.log`: 73 tests, zero failures, exit 0.
- `precise-physics-01.log`: 4 tests, 2 failures, exit 1. Control permission and source-update coalescing failed.
- `precise-physics-diagnostic-02.log`: 2 tests, 1 failure, exit 1. Coalescing passes after applying the existing verified source delta; control still fails.
- `precise-control-diagnostic-03.log`: 1 test, 1 failure, exit 1. Raw error: `{erlog,{context_violation,physics_control_input,staging,non_control}}`.
- `precise-control-04.log`: 36 tests, 1 failure, exit 1. Source-view and scope-wire tests pass, including the newly added read-set codec check. The control test now reaches source ACL withdrawal, where Command(2) fails with `reinstalling`.

No full Phase 1 clean gate campaign has run. No commit, version bump, deployment,
refound or live edit has been performed. No normative documentation sentence
changed in this last control-permission correction; its source comment states
why control's durable-write restriction differs from a fully read-only frame.
The previous measured production delta is in `signed-reader-delta.json`; it
predates the precise-read extension and is not a measurement of this tree.

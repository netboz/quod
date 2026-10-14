# Consume certified occurrences once

Read frozen AGENTS.md. Source-only implementation review, no commands/tests or
production edits. Save fable-review.md here. Actual small delta is in
handle_source_notice/5 and the existing subscribed reaction regression fixture.
The dispatch-provenance-01 tree preserves the runtime immediately before this
correction; use it as the source baseline.

A real founded subscription fixture captures the actual certified advanced
notice delivered to the runtime. Re-delivering that same notice after processing
calls the existing dispatcher twice. red01 proves duplicate_routed_event,
1 test/1 failure, true exit1. The filter now uses that same follower row's
retained verified height to pass only newer publication heights. No new inventory,
process or mutable state. State/freshness still update at equal height, so owner
readiness restoration is not discarded with the old occurrences.

The regression synchronizes on the existing post-processing source ack and owner
stats, then checks the actual dispatcher. It does not infer processing from the
send. Its repeated notice also uses the existing zero-I/O trace helper to exclude
history reconstruction/reads and file writes/syncs. Later genuine changes, runtime
restart and foreign cache rebuild remain in the same production fixture.

green01: 1/0 exit0. Full affected runtime/reaction/metadata gate01: 65/0 exit0,
9.543 seconds. Logs retained; Claude did not run them. Five production lines plus
one argument replacement; no public API or wire change. Review same-height
readiness, multi-publication blocks, overlapping notices, and replay semantics.

This fixes one concrete repeat-dispatch gap. It does not implement GUI automatic
completion or prove the full proposed retained-byte reaction contract.

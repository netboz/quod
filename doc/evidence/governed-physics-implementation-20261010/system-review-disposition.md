# Checked system-registration review

Yan requested this review. `system-review-02` ran Claude/Fable with read-only
tools, no hooks/MCP/commands and 68 frozen inputs. Its receipt records
`claude-fable-5-1`, child exit 0, no model error and no changed frozen inputs.
The failed `system-review-01` packet setup is retained; no Claude process was
launched for that attempt.

The reviewer found no production defect and no unused or compatibility-only
production code. It judged this local slice coherent, explicitly leaving the
full task open. The prior compatibility proposal remains discarded.

## Findings and disposition

- Accepted the stale timeout finding. The receipt-wait helper now recomputes
  time remaining after the outcome snapshot, before entering its receive.
- Accepted the projection-test wording finding. It applies identical genesis
  to fresh canonical bases; it is not itself a complete owner-recovery test.
  Existing live-owner restart/replay tests remain in the broader regression run.
- Kept the test's explicit expected-shape assertions. Unexpected or unavailable
  snapshots fail loudly; no recovery or fallback behavior is needed in this
  fixture. The review independently confirmed a terminal receipt cannot be
  above its atomic publication floor. Extra test-only handling would not add a
  product guarantee.
- The two distinct world tests are sequential fixtures, not concurrent worlds
  or concurrent admission/edit/withdrawal evidence. There is no requirement to
  support two physics worlds inside one ontology/runtime in this slice.
- Generic request-verification predicate naming is pre-existing and introduces
  no authority or separate implementation. No naming-only refactor was added.

## Independently checked packet omissions

`quod_foreign_projection:init` uses `quod_committed_projection:new_est/0`, so
the retained foreign materializer receives the common registration too.
`quod_ledger_store:append/2` is the production append entry called by Simplex;
the retained failure diagnostic also observed that exact call. The native
adapter's current source hash exactly matches the earlier Fable
`implementation-review-03` input. These supplemental checks are recorded in
`system-review-02/independent-supplemental-source-manifest.json`; they were not
part of the 68-file review packet.

## Validation and scope

The broad `system-worlds-02` run passed 228 tests before compatibility-test
removal. `system-registration-cleanup-01` passed all six remaining projection
tests. Following the two review corrections, `system-review-fixes-01` passed
15 tests: the nine geometry/receipt cases and six projection tests. Every run
retains its child exit and unchanged source hashes. `git diff --check` passes.

Current production diff: +76/-15, net +61 lines, mostly the previously reviewed
shared geometry validation; common registration adds one line. Tests:
+255/-12, net +243 lines. No new production process, loader, compatibility branch,
mutable domain store or propagation protocol was introduced. User-owned changes
outside this scope remain untouched. No commit or deployment was made.

QUD.27 remains open: live referenced collider wiring, ordinary-view integration
and real signed personal-lobby acceptance are still outstanding.

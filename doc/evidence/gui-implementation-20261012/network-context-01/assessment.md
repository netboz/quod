# Independent implementation assessment

The existing content/vote network acquisition now returns verified immutable
context. Content validation captures it before any application; vote validation
passes it through both duplicate-history and own-vote branches; selection returns
the captured context. Projection carries the anchor alongside outcome state into
subsequent validation contexts. No new process, lookup owner, wire format or wait
inside the application fold. New/6 replaces new/5 in every production/test caller.
Fresh validation requests start with none; only projection supplies retained trust.
Expiry, agent keys, authorization and parent-state validation still run normally.

Production delta against before/: +45/-28, net17. The added field and acquisition
helper replace two direct readiness reads and carry their result; growth is needed
to preserve trust through later checks, not another mutable network authority.

gate01 failed on a fixture timestamp regression1->0. gate02 failed because the
fixture attempted to re-claim a signed operation at a later certified slot, which
the existing claim owner correctly refuses. Both logs and test sources retained.
Final test uses the same authorized keys with a new operation and new goal to
verify a genuine update after root readiness disappears. No resubmission behavior
has been added or authorized. The original frozen test is in tree/; followup02/
contains the final two test files and supersedes followup01/.

gate03 178/0 exit0,9.741s. gate04 178/0 exit0,10.598s adds twenty unchanged content
and vote checks under the existing trace-based no-history/no-rebuild/no-write/sync
assertion, plus the real later update. All true child exits collected.

Claude implementation review is pending: the requested Fable child reported a
provider session limit resetting15:50 Europe/Paris on2026-10-13. Architecture
network-review-addendum-01 is received and accepted; it is not a review of this
implementation. Do not invent approval. Resume at the quota reset using this
packet's tree/ plus followup02/, then independently assess the report.

Yan subsequently requested Claude Opus for this pending review. New source-only
child7a486fb0-9f42-4194-924d-f4bf620952dc uses claude-code:opus and targets
opus-review.md. It also returned the provider limit resetting15:50 Paris;
no review was performed. Scheduled continuation must reuse this Opus child,
not send a duplicate review to Fable. This explicit user choice overrides the
standing default reviewer model for this review.

No negative dependency codec, plan-level acquisition, expired query answer,
automatic agent continuation or live GUI opening was introduced by this slice.

Yan then explicitly requested self-review instead. self-review.md completes that
review with no blocking correctness findings and one reporting correction:
the hosted owner recreates its projection each block; retained network trust
is guaranteed through the current batch, while the foreign projection keeps its
object across entries. The direct projection test does not prove cross-block
hosted caching. No production changes were required. The earlier Claude quota
notes are historical; do not treat them as a continuing gate or solicit another
review of this slice automatically.

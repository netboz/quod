# Fable review: consume certified occurrences once (source-notice-01)

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-13. Consultative only.
Basis: `candidate.md`, `manifest.json`, `receipt.json`, the frozen `tree/`
diffed against `dispatch-provenance-01/tree` (the runtime immediately before
this correction) and git HEAD for the test; `red01.log`. Read-only lookups:
`quod_foreign_log` follow delivery, acknowledgement and coalescing;
`quod_foreign_projection` publication construction. No command or test was
run; the parent's red, green and gate logs are the evidence.

## 1. Verdict

Correct and minimal. The retained verified height is the right owner for
occurrence consumption, and the filter cannot drop a legitimate publication
under the follower's actual protocol. Nothing required. Two notes below are
about what the fix does not cover, not defects in it.

## 2. What changed

Five lines in `handle_source_notice/5` compute the height verified before
this notice and pass only publications above it to the existing enqueue
(`quod_runtime.erl:1646-1659`). State and freshness are still refreshed at
equal height, so a duplicate ready notice remains a readiness refresh. The
test re-delivers the captured certified notice to the runtime, waits on the
existing post-processing acknowledgement and owner stats, then inspects the
real dispatcher, all inside the zero-I/O trace helper.

## 3. Checked against the follower protocol

- **One outstanding notice per consumer.** The follower sends the next
  notice only after the acknowledgement for the previous one
  (`quod_foreign_log.erl:3412-3431, 3581-3596`). Advances therefore arrive
  in order with `From` equal to the last delivered `To`; the only way a
  publication at or below the verified height can arrive is re-delivery.
- **Whole heights, never split.** The projection publishes ready only when
  its applied height reaches the target, and publications accumulate across
  pages until then (`quod_foreign_projection.erl:185-205, 317-350`). A height's
  publications are all in one notice, so the height-granular filter is safe
  for multi-publication blocks.
- **First delivery is a baseline.** A consumer with a pending baseline
  receives a resnapshot, not an advance (`:3600-3606`), so the verified height
  is set before any publication can be compared against it. The `Known = 0`
  fallback is unreachable for a healthy follow and harmless otherwise.
- **Coalescing drops, never duplicates.** Two advances pending behind one
  outstanding notice collapse to a resnapshot without publications
  (`:3618-3637`). Those occurrences are lost under the documented best-effort
  rule; they cannot come back later below the new verified height.
- **Equal-height readiness.** The pre-existing guard acknowledges strictly
  older ready notices without touching the row. The new code lets an
  equal-height notice through to refresh state, freshness and resource
  change detection, with an empty fresh list. That is the behaviour the
  candidate describes and the test exercises.
- **Replay modes.** Non-event modes still update the row and acknowledge
  without enqueuing, so after reconciliation the verified height already
  covers what was skipped. The filter makes this explicit rather than
  changing it.

## 4. Replay and acknowledgement semantics

Re-acknowledging a notice reference the follower no longer holds is a no-op
(`acknowledge_follow/4` falls through to `S0`), so the duplicate's ack cannot
disturb the follower's outstanding slot. The regression therefore proves the
property it claims: a re-delivered certified notice reaches the runtime,
is processed, and yields no second routed event.

## 5. Not covered, by design

- Local applied envelopes have no verified-height filter of this kind; they
  are dispatched once per runtime incarnation and dropped on collapse or
  restart. That is examined in the dispatch-provenance review.
- Lost occurrences (overflow acknowledgement, coalesced resnapshot, collapse)
  remain lost. This fix removes a duplicate, it adds no retention.

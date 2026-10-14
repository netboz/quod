# Fable review: retained certified timestamps in the outcome owner (outcome-time-01)

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-13. Consultative only.
Basis: `review-request.md`, `manifest.json`, `before/` against `tree/` for the
two production files and six test files, the doc delta, and read-only lookups
of the live apply paths. No command or test was run; the parent's gates are
the evidence. This is a source and format review, not release approval.

## 1. Verdict

Sound. The time row lives in the existing index, is staged and flushed with
the floor and claims, is read only through the published floor, and is
immutable under replay. The format bump refuses recognised older files
without touching their bytes. Nothing required. Two notes in section 6.

## 2. Projection path (verified)

- Every apply goes through `quod_committed_projection:apply_entry/3`: the
  hosted owner (`quod_prolog.erl:6604`) and the foreign projection
  (`quod_foreign_projection.erl:322`). `publish/5` is the only caller of
  `advance_applied/3`, and it receives the entry's certified timestamp from
  the ledger view for content, control batches and the invalid-payload
  branch alike. No `/2` remains.
- Non-material carriers never produce a ledger entry, so every stored time
  belongs to a material height, which is exactly what the admission lanes
  compared against.

## 3. Immutability, order and visibility (verified)

- `stage_timestamp/3` requires the new time to be at least the previous
  height's time (equality legal, matching `valid_parent_transition/3`), and
  for an already present row requires exact equality, else
  `outcome_index_conflict`. Slot 1 compares against zero.
- Replay at or below the floor is inert only when the retained row equals
  the replayed time; a mismatch is refused rather than overwritten, the same
  rule `terminal/4` applies to outcomes.
- Slot zero is a no-op only with time zero; any other time at slot zero is
  refused through the lookup path.
- Reads: `applied_timestamp/2` answers only for heights at or below the
  flushed `applied_floor`, so a staged row is invisible until the same flush
  that publishes its claims. After reopen the floor is reset, so retained
  rows stay unavailable until replay advances past them. The test pins
  both.
- Reopen preserves time rows: `reset_existing_dtx/3` deletes only group
  rows and the DTX state. Rows are validated on every backend read by
  `valid_stored/2`, so a corrupt time row invalidates the backend instead of
  being served.

## 4. Cache and repeated work (verified)

`lookup_cached/2` is the former `lookup_operation/2` and now serves group,
operation and time keys; the three private copies collapsed into it, which
is where most of the negative line count comes from. An unchanged repeat
(`advance_applied` at a published height with the retained time, then
`flush` with nothing staged) performs no staging and no write; the disk
fixture asserts that twenty times under the no-I/O helper and then a real
update at the next height.

## 5. Format boundary (verified)

Format 9 replaces 8. An existing file with a recognised lower version is
closed and refused as `{unsupported_format, V}` before any interpretation,
reset or deletion; the synthetic v8 test pins identical bytes before and
after. A fresh file is created at 9. No migration exists and none is
authorised by this packet.

## 6. Noted, no change required

- A file whose header is *newer* than the running format, or whose anchor
  differs at the same format, falls to the generic reset branch and may be
  deleted and rebuilt when reset is permitted. That is pre-existing policy
  for derived state and the index is rebuildable from the ledger, but a
  rollback deployment would silently discard the derived index rather than
  refuse. Worth a sentence in the format note.
- A non-integer timestamp is refused with `outcome_index_gap`, which names
  the wrong reason. Harmless; the guard clause could say so.
- Growth is one small row per material height. The cache is bounded and
  the rest is on disk; no replay or rebuild serves a time read.

## 7. Out of scope

No negative-expiry token, observation result or dispatch is enabled. The
doc paragraph says so and says retained time alone is not a certified
negative outcome, which matches the expiry-dependency consultation.

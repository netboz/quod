# Retained certified timestamps in the existing outcome owner

Read frozen AGENTS.md. Source-only: no commands/tests/production edits. Compare
before/ to tree/. Certified material entry timestamp is threaded through the
shared projection into the replacement advance_applied/3, with no /2 shim.
Immutable time rows use the existing staged flush, cache and index. Prior time
checks use the staged ordered floor; public reads use only the flushed floor.
Replay preserves rows but refuses mismatch. Slot zero remains only a (0,0)
no-op and cannot yield a published timestamp. Monotonic equal times are legal.
Generic cached lookup now replaces identical group/operation algorithms and also
serves time rows. Production delta +87/-51, net36 lines. No extra owner, cache,
queue, budget, request-time replay or weakening of durability.

Derived format 9 replaces 8. Recognized old formats are refused unchanged;
new synthetic v8-header test pins exact file bytes before/after refusal. No data
migration/deployment is performed or authorized. Check the compatibility boundary
and timestamp immutability, staged/reopen visibility and actual projection path.
The new disk fixture pins unchanged read/repeated apply/empty flush no-I/O and
then real update. Shared projection fixture checks emitted entry times. Existing
adapter fixtures supply deterministic material-height times. Gate01 211/0 exit0;
final broader gate02 pending when frozen. Write fable-review.md here.

No negative expiry token, observation result or GUI dispatch is implemented here.
The independently assessed expiry contract remains the next separate correctness
step. This packet requests source/format review, not release approval.

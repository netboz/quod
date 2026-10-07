# Body pose stream review disposition

The requested Claude/Fable review is retained in [fable-review.md](fable-review.md).
Its findings were checked against the implementation and production-seam tests;
the review is consultative, not a deployment or commit approval.

- Refresh blanking: fixed. Refresh invalidates motion acceptance but preserves
  the painted last pose with an explicit refreshing status. Unavailable/close
  hides the bodies. The socket test checks that refresh never invokes the
  unavailable callback; scene tests check pose and node retention.
- Installation waits: bounded by the original signed deadline, without retry
  timers. The signed lifecycle test holds the real runtime installer, observes
  a newer committed structure, checks waiting/expiry and ignores a stale timer.
- Already-failed simulation: the existing owner reports its failed phase from
  `watch/2`, so the endpoint reports failure immediately. The test creates a
  real native body-allowance failure and opens the signed view afterward.
- Policy before enumeration: `physics_space/3` identifies the world, then
  `can_view_physics/2` runs before `physics_view/2` enumerates its marks.
- Idle unauthenticated sockets: use Cowboy's finite default idle timeout.
- Snapshot documentation: distinguishes the internal snapshot API from the
  signed client pose boundary and excludes contact proofs from both.
- Conservative durable invalidation: retained and documented. Signed answers
  expose a height, not a retained dependency watch. Every durable advance
  obtains a fresh signed projection, including custody/checkpoint changes.
  This can starve motion in a busy namespace; it neither rebuilds native state
  nor restores an authored baseline. Fable classified it as a cost rather than
  a correctness blocker for this bounded slice.
- Signed deadline: retains the existing client request lifetime. Renewal is a
  new signed read; it never changes an old request's deadline. No write request
  is retried or extended. The UI remains visibly stale during renewal.
- View scope: remains the selected agent's local ontology and one active view.
  There is no default human-lobby grant or remote viewer authorization. The
  fixture supplies explicit view policy, marks and a viewer key.

An independent final check also found that a retired asynchronous signer could
report failure into a replacement view. Both cancellation and open-request
generation now guard that callback, with a regression test. The client tests
and browser build were rerun for those two JavaScript-only source/test changes;
the Erlang gate scope did not change.

The subsequent full gate stopped on two Dialyzer unmatched-return warnings in
socket cleanup. Explicitly discarding those return values resolved the warnings;
fresh clean campaign 03 validated the final implementation and tests together.

The tests exercise the production WebSocket callbacks, signed session/proof
ingress, runtime and native door owner, plus the browser socket lifecycle and
Babylon NullEngine. They are not a manual headset or end-to-end TLS browser
acceptance claim.

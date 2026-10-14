# Independent integration disposition

Fable's source-only report confirms the main missing ownership facts. Its
proposed fixes are consultative and are **not approved implementation contracts**.
No production runtime or transport change follows from this packet.

## Custody

Accepted C1-C4: the original hosted-agent bytes are transient before ingress,
the recovery snapshot is atomic-group custody rather than all requests, and
the physics custodied mode has a separate signed store transition. The existing
agent work selector cannot by itself supply exact request custody.

Rejected E3's quiet period. Waiting the configured request budget after an
incarnation starts is not terminal evidence about an earlier signed store
operation. The earlier budget may differ, certified progress may lag, and an
already admitted group can remain unresolved after its caller's deadline.
An untracked store write must not be replaced on elapsed-time inference. This
does not satisfy Yan's exact-outcome rule, even if it often avoids a race.

C5/E2 are overstated. Expiry refuses *new temporal admission*; it does not
invalidate historical positive votes or prove an already admitted operation
aborted. test/quod_atomic_tests.erl explicitly preserves historical positive
authentication after expiry. src/quod_client_goal_ingress.erl:266-269 retains
pending on missing evidence because custody and publication can be separated;
its production-seam expiry test preserves that behavior. Current key revocation
also cannot prove "can never commit": already prepared authority and possible
authorized future key changes must be accounted for.

A narrower negative-expiry result might be possible from a proved-complete,
certified source prefix beyond the original expiry, whose exact operation
index proves no earlier winning admission. That requires an explicit invariant
covering every source lane, applied/index frontier, prepared group and pending
publication, plus portable evidence and validator checks. The review left the
time source and parts of custody validation unverified. Neither local absence,
wall-clock passage nor a standalone key lookup establishes this theorem. It is
not implemented or treated as permission for a new request.

Generalizing prepare_signed_request alone therefore does not close the gap.
The same ownership must also cover the custody-store operation's own uncertain
outcome, before any replacement is allowed. A proven common request-custody
contract remains necessary; the GUI must not invent a private queue to get it.

## Opening

Accepted the distinction between a client-serving node and an ontology's
validator. C6 accurately describes current signed-target/control routing.
An authorized fact in the human ontology can select a receiver scope, but it
cannot establish live connection or handler acceptance. This is consistent
with the original plan, not a replacement for its preparation requirement.

Rejected 4.3 as currently specified. The existing read-only flag belongs to the
proof path; there is no already implemented per-call observer scope inside a
write proof. More importantly, a query bridge that allocates a provisional
presentation is not just a read of immutable ontology state. Calling it from
native preparation does not remove the need to bind real effect preparation,
rollback, authority, expiry and exact original operation to the existing owner.
It must not become the previously rejected standalone live-query path.

Certified HUD notifications may wake discovery, but 4.4's journal carrier with
"no external work" does not specify the selected real prepared-presentation
effect. It also assumes the client node follows the human ontology; the report
explicitly did not verify that. Do not silently replace effect release with an
unimplemented local feed or treat an ordinary HUD row as native acceptance.

The required concrete contracts remain authenticated request-to-connection
binding, remote native acceptance through an existing transport owner,
preparation/rollback/expiry, and certified release/discovery ordering. No absent
human/agent failure, original deadline or live-observation seal rule changed.

## Result

The review helped isolate the remaining correctness gate but did not close it.
Delivered component, explicit transition and renderer code is independently
reviewed and tested. Live opening and automatic recovery remain disabled rather
than inheriting the FIPA policy that permits new attempts after unknown results.

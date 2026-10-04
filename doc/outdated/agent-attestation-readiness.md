# Agent attestation readiness

Membership, committee identity and routes are consensus-installed facts owned
by Simplex. Local Prolog apply lag does not remove them. Co-hosted routing and
verification of an existing identity certificate therefore keep using that
installed view during an apply fence.

Issuing a certificate is different: a committed but unapplied key revocation
must prevent signing. The existing attestation worker acquires proof access
before capturing its Prolog snapshot. It subscribes through `quod_reg` before
checking the gate and waits for its exact `{group, slot, generation}` fence to
clear. Simplex publishes that event only after installing the cleared gate.
Duplicate acknowledgements and unrelated commits publish no such event.

Access binds the Simplex incarnation, committee identity and gate generation.
The Prolog snapshot and signing boundaries validate that same access, plus
the ordinary MVCC key reads; they do not independently acquire a new gate.
The attester's existing lifecycle row pins its acquired snapshot until the
worker finishes. No snapshot is retained while waiting for a fence.

The caller's absolute deadline includes router queueing, route lookup, fence
waiting, key evaluation and signing. Waiting cannot renew it. Loss of the
Simplex owner, Prolog owner or reply owner cancels the wait; subscriptions and
monitors are released. Committee replacement invalidates it. Unknown identities
and non-validator membership still refuse immediately. Rebuilding is not
silently treated as an open gate.

There is no additional process, request queue, readiness timer or polling.
The fence remains whole-ontology; dependency-scoped fencing is outside this
contract. This does not alter certificate quorum, signed bytes, revocation
rules or public client result grammar.

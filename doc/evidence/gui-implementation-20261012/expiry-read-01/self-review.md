# Negative expiry dependency review

Self-review by the implementing Codex agent, under Yan's explicit self-review
steering. This is not a Claude review or an independent implementation review.
Scope: before-manifest.json against manifest.json/tree, existing proof and
multiwrite contracts, expiry-dependency-01 assessment and the accepted network
integration addendum. No blocking correctness finding in this scope.

The new tag2 dependency carries original bounded unsigned request bytes plus a
captured prefix and its certified timestamp. The codec verifies canonical actor/id,
execute mode, uint64 bounds and a timestamp strictly after expiry. Semantic
validation receives the owning scope and trusted network separately; embedded
network bytes cannot authenticate themselves. It checks the published immutable
time and no claim through that prefix. A later retained claim is deliberately
ignored, preserving validation during replay and later reuse of the actor/id by
a different request. An already claimed operation, including a prepared or
unpublished group, never becomes expired. Positive terminal evidence and its
existing digest-mismatch dependency behavior retain precedence.

Every path needing the network captures it before material application: whole
content scan, decoded prepared material for votes and read-only certification.
Missing context stays unavailable/abstain rather than refused or outcome_error.
The remote application record's own read_check is bound to its certified plan by
semantic identity before validation. Shared projection retains captured network
through ordinary and remote second OCC checks; no inner application wait exists.
Hosted projection lifetime remains one applied block, foreign projection lifetime
spans entries. No stronger cross-block hosted-cache claim is made.

Membership changes reject both operation dependency kinds. Material decoding uses
the same seal-bound read checks, including captured prefix <= base. Pure identity
validation has no outcome context and fails closed. The real query records expiry
before unification; failed alternatives, negation, cuts and explicit transaction
rollback cannot erase it. Unavailable remains a monotonic live-bridge veto even
when caught. Observation does not sign, execute, extend deadlines or redispatch.

Evidence covers published/unflushed/reopened prefixes, retained future claims,
nonterminal claims, source/network/token mismatch, ordinary application, remote
application, vote preparation and read-only certification. Real hosted proof
sessions seal material writes after expiry reads. Repeated reads use the existing
retained outcome owner/index with no history rebuild or file write/sync. Real
later entries still advance evidence. Actual live and recovered Simplex owners
refuse protocol advancement for timestamp regression after pruning or membership
reseating; receiving a raw block into the bounded pool is not acceptance.

Production delta against this packet's baseline: +147/-34, net +113 lines in
existing owners. Growth is the new dependency contract and its validation inputs,
not another owner, process, queue or history service. No persisted format change
beyond the previously reviewed format9 timestamp slice. No GUI automatic dispatch,
original live opening, client lifecycle or headset acceptance is claimed here.

Failed gate04 and gate07 sources/logs remain intact. They were fixture errors:
gate04 omitted transaction predicates in a minimal proof environment; gate07
mistook block-pool retention for notarization acceptance. The corrected tests
exercise the required rollback dependency and actual quorum-supported protocol
boundary, respectively. Full gate details are recorded in receipt.md.

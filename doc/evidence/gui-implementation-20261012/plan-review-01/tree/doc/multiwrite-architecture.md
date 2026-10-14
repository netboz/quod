# Multi-ontology writes

This is the current compact map of Quod's write lanes. The
[archived consolidated architecture](outdated/multiwrite-architecture.md)
preserves its pinned rulings, protocol amendments and implementation record.
Read that record and the affected code before changing wire, custody or
recovery semantics.

## One sealed proof, three lanes

The proof worker selects one answer and seals all participating scopes once.
Read-only dependencies are certified and validated at their target; they do
not become writers merely because they were read. The resulting write shape
selects a lane:

| Shape | Commit path | Result |
| --- | --- | --- |
| One writer | That ontology's ordinary signed transaction and consensus | Its applied outcome |
| Several ordinary writers | One atomic source-and-role group | Commit or abort together |
| Explicit independent intent | One durable source claim and separate target applications | Complete vector of certified target outcomes |

The independent lane requires intent proved from the original signed request
and sealed plans. A peer flag or coordinator assertion cannot grant it. The
source role is retained for an ordinary atomic multiwriter even if the
source's own diff is empty. Each target receives only its own sealed material
plus bounded shared evidence; no participant receives another ontology's KB.

## Atomic group

The installed protocol uses Vote, Resolve and Complete records.
Each role makes one immutable prepared or refused Vote under its own
committee. All certified prepared references authorize commit; one certified
refusal authorizes abort. Timeout, missing route and transport refusal do
not decide the group. Resolve publishes or discards each role's hidden plan.
Complete records the terminal group and portable application evidence for
recovery. The client waits for certified applied outcome, while Complete may
finish asynchronously.

`quod_dtx_coordinator` is a volatile driver started from a durable source or
role obligation. It uses monitored asynchronous target work and exact
progress notices. Its restart reconstructs work from certified history;
readiness dips pause obligations rather than retiring them. No timer grants
permission to resubmit an uncertain write or extends the caller's original
deadline.

## Independent operation

A source claim fixes the exact target set. Target applications progress
independently through the same owners. A committed inclusion still needs an
exact applied-result certificate; it is not a terminal result by itself.
Only a complete certified target vector is final. Mixed applied and rejected
results are valid. A timeout yields uncertainty, not an invented rejection.
Source receipt durability can follow client result delivery; resolution uses
the original claim and exact target evidence without new submission.

The pure record and transition modules are `quod_dtx`, `quod_atomic` and
`quod_operation`. `quod_prolog` owns proof and apply, `quod_simplex` owns
ledger custody, and `quod_foreign_log` owns foreign evidence. The local
`quod_effect_journal` retains private direct-effect preparation until the
controlling committed transition authorizes its release. Related domain
changes and receiver consequences belong in one atomic transaction when
they are one transition, as in the [internal FIPA Request](runtime-and-agents.md).

Root's committed `effect_custody_limits(Count, PreparedBytes)` governs new
private-effect admission. `set_effect_custody_limits/2` replaces both limits
atomically under root's existing privileged ACL. Each limit is a nonnegative
integer or `unlimited`; the bootstrap policy selects `64, unlimited`. The
existing resource selector installs that policy into the one node-wide journal.
Missing, ambiguous, invalid or interrupted root selection withdraws new
admission while preserving staged and bound obligations. An interrupted
selection retains a conservative root dependency for the next committed change.
Count pressure remains `busy`; byte pressure reports
`effect_custody_limit(prepared_bytes, Actual, Limit)` after digest validation.
Neither policy tightening nor recovery re-admits already accepted obligations.
Unchanged policy checks do not write the journal. Canonical transaction and
genesis encoding bounds remain separate from this resource policy.

## Exact terminal outcome reads

`committed_operation_outcome(Bytes, Signature, Status)` reads the current
scope's exact signed operation through its retained outcome index. It is an
ordinary-proof query, unavailable to in-owner membership verdicts and reaction
matching. Positive terminal evidence is captured monotonically before result
unification; failed alternatives, negation and rollback retain the dependency.
Missing, pending, unpublished and infrastructure-unavailable results raise an
error. If caught, their live-bridge marker still prevents sealing a nonempty
diff; the existing read-only/effect-only boundary is unchanged.

The canonical read set carries atom-free operation keys `{1, AgentBytes, Id}`
and tokens `{Digest, LocalReference, ClaimHeight, StatusCode, TerminalHeight,
PublicationHeight}`. Reference tags distinguish local transactions and atomic
groups; status codes distinguish committed, rejected and aborted. No rejection
reason or mutable receipt vector is copied. Independent application vectors
are outside this terminal query's supported result types. Every evidence height
must fit the sealed base and published parent. A group's publication height is
Complete's slot, even when its public result reports an earlier Resolve slot.

The same validators check exact evidence during ordinary apply, atomic prepare,
remote application and read-only certification. Mismatch is the existing OCC
conflict; storage failure is an outcome error, never a certified refusal.
Membership diffs cannot carry these dependencies, and agent identity proofs
continue to fail closed without an outcome context. Immutable terminal reads
need no mutable predicate reservation, but remain signed, counted and validated.

Existing predicate-only canonical bytes are unchanged. Older binaries reject
this new read kind; enabling its ontology rules requires compatible validators
and the applicable founded predicate-module deployment procedure. This change
does not authorize a deployment, history rewrite or data migration.

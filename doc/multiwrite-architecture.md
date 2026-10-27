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
| One writer in the signed origin | That ontology's ordinary signed transaction and consensus | Its applied outcome |
| One foreign writer | Durable source claim and that target's application, without requiring independent intent | Its applied outcome; recovery resolves the target vector and original claim bindings |
| Several ordinary writers | One atomic source-and-role group | Commit or abort together |
| Explicit independent intent | One durable source claim and separate target applications | Complete vector of certified target outcomes |

Several independent writers require intent proved from the original signed
request and sealed plans. A peer flag or coordinator assertion cannot grant
that intent. A lone foreign writer uses the same source-claim lifecycle
without independent intent. The source role is retained for an ordinary
atomic multiwriter even if the
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

## Source claims and target applications

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

New founding material and sealed plans use the shared
[material policy](../priv/ontologies/material_policy.pl). Root's existing
creation proof selects founding limits; each target session selects its plan
limits. The selection is a strictly local, read-only proof over the pinned
committed state. Its exact reads enter the existing OCC set, so a proposed
change cannot grant itself a larger allowance and a concurrent policy change
conflicts normally. Overrides are ordinary ontology facts under its existing
authorization. Missing, ambiguous or invalid limits refuse new admission.
Refusals identify the material kind, resource, actual quantity and allowance.
If a proposed diff changes a dependency of the selected plan policy, sealing
checks that the final candidate still selects a valid policy. An atomic
replacement is checked as one final state, including changes to helper
predicates. This does not grant the candidate's larger allowance to its own
write. Zero remains an explicit owner policy: it can permanently close the
ordinary write lane. There is no implicit repair allowance or privileged
recovery write that bypasses that policy.

Founding counts the authored source's distinct symbols before allocation and
checks its compiled canonical diff. Plans count their complete encoded
envelope, joint decoded vocabulary (including transcript goals), operations
and read entries. Counts do not depend on which atoms a VM already knows.
Admission is enforced by the sealing proposer under the existing trusted
validator execution boundary. Validators enforce the sealed policy reads and
encoding bounds; material decoding retains VM headroom checks. This is not a
new resource sandbox for arbitrary traffic from admitted committee members.
The full enclosing transaction, block and transport still have encoding
capacity checks. Their shared material capacity fits both the existing scope
carrier and the history page with a full-committee compact witness; accepted
canonical bytes are unchanged. Decoding accepted history does not reapply current admission
policy. It still validates the wire alphabet and real VM atom-table headroom.
Retained vote selections distinguish read and write reservation changes.
Shared policy readers do not invalidate each other's unchanged selections;
an overlapping writer still invalidates readers and writers through the
existing installed-change notification.

The same committed policy selects `material_limit(proof, heap_bytes, Limit)`
when an actual proof session starts, for both origin and selected scopes.
The bootstrap source explicitly selects `unlimited`; an owner may supply a
nonnegative byte allowance through `material_limit_override/3`. The worker
checks its existing heap before installing the VM's hard kill limit. Initial
refusals report `material_limit(proof, heap_bytes, Actual, Limit)`; a later
VM heap kill retains the VM's measured heap report and the existing monitored
worker-failure path. The session retains those exact policy reads and joins
them to the normal OCC set when sealing a material plan. Admission alone does
not make an untouched scope a transaction participant. A staged increase
does not enlarge its own running proof, and a policy-changing plan must leave
a valid final policy. Zero can close the proof lane; there is no repair bypass.
Local committed-policy selectors do not change their owner's process limit.

Proof scopes, invocations, proxies, answers and distributed savepoints have
no separate population ceilings in Erlang. Their retained state uses the
proof's memory allowance and lifetime. Routers retain exact correlations
under the same caller deadlines without imposing another count quota.
Participant and dependency vectors preserve every exact identity; canonical
ordering, uniqueness and complete message bounds still apply. Invocation
transcripts record every call before execution and share the complete sealed
plan's encoding bound, rather than an independent component allowance.

Foreign-history verification no longer borrows a proof worker's heap allowance.
It verifies already accepted material under the existing page, canonical
encoding and VM-headroom checks; current proof admission policy does not
re-admit that history. Its existing owner, custody, cancellation and deadline
mechanisms remain responsible for worker lifetime.

## Exact terminal outcome reads

`committed_operation_outcome(Bytes, Status)` reads the current scope's exact
execute request through its retained outcome index. Canonical unsigned bytes
identify the request; their digest must match committed evidence. Reading grants
no execution authority and needs no retained signature. Identity decoding is
atom-safe and does not parse or execute the goal. The containing ontology's ACL
still governs the proof. Signed HTTP operation resolution remains unchanged.
The query is unavailable to in-owner membership verdicts and reaction
matching. Terminal evidence is captured monotonically before result
unification; failed alternatives, negation and rollback retain the dependency.
An absent request returns `expired` only with certified evidence described below.
Pending, unpublished and infrastructure-unavailable results raise an error, as
does absence without that evidence. If caught, their live-bridge marker still prevents sealing a nonempty
diff; the existing read-only/effect-only boundary is unchanged.

The canonical read set carries atom-free operation keys `{1, AgentBytes, Id}`
and tokens `{Digest, LocalReference, ClaimHeight, StatusCode, TerminalHeight,
PublicationHeight}`. Reference tags distinguish local transactions and atomic
groups; status codes distinguish committed, rejected and aborted. No rejection
reason or mutable receipt vector is copied. Independent application vectors
are outside this terminal query's supported result types. Every evidence height
must fit the sealed base and published parent. A group's publication height is
Complete's slot, even when its public result reports an earlier Resolve slot.

Negative expiry uses `{2, AgentBytes, Id}` with the token
`{OriginalUnsignedRequestBytes, PrefixHeight, CertifiedTimestamp}`. The bounded
codec checks execute mode, canonical actor/id, uint64 height/time and time strictly
after the request deadline. Validation checks the request's exact scope and trusted
network, the retained timestamp at that published prefix, and absence of any claim
at or before it. The prefix must fit the sealed base and current parent. A retained
future claim for another request with the same actor/id cannot invalidate expiry
of these exact bytes. A claim at or before the prefix, even without a published
completion, prevents expiry. Neither wall-clock time nor key revocation proves it.

Trusted network identity is captured by the existing content, vote and read-only
certification owners. Missing identity produces their ordinary unavailable or
abstention result before application; it is not a certified refusal or index
corruption. Projection carries this immutable context through the second OCC check,
so there is no readiness wait inside a partially applied batch.

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

The existing outcome index retains an immutable timestamp for each applied
material height. The shared committed projection passes the certified entry time
to `advance_applied/3`; time, claims and the published floor share one flush.
Times are nondecreasing and replay must match retained rows. Timestamp reads are
unavailable above the published floor, including after reopening until replay
advances it. They reuse the same bounded cache and disk index. Derived outcome
format 9 refuses other integer versions without rewriting them; deployment or migration
requires its own authority. Retained time alone does not provide a certified
negative operation outcome: the exact request, source, network and prefix absence
checks above are also required. `expired` authorizes no replay of an uncertain
request; it only supplies a dependency for an ordinary ontology transition.

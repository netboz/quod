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
encoding constraints. This is not a resource sandbox for arbitrary traffic
from admitted committee members. Materialization checks actual VM atom-table
capacity before allocating new names; this precheck does not reserve capacity
against unrelated concurrent VM allocation. Explicit finite client vocabulary
allowances remain enforced by the authentication owner.
The complete transport envelope and store record retain their actual encoded
length constraints. History readers retain one captured cursor and stream
complete frames with exact continuation tokens; partial finality groups are
never installed. Decoding accepted history does not reapply current admission
policy. It still validates the wire alphabet and canonical identity bindings.
Retained vote selections distinguish read and write reservation changes.
Shared policy readers do not invalidate each other's unchanged selections;
an overlapping writer still invalidates readers and writers through the
existing installed-change notification.

The same committed policy selects `material_limit(proof, heap_bytes, Limit)`
and `material_limit(proof, answer_bytes, Limit)` when an actual proof session
starts, for both origin and selected scopes. The bootstrap source explicitly
selects `unlimited` for both; an owner may supply a
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

Answer allocation measures the canonical atom-safe payload of one computed
answer, excluding its transport envelope and retained ground inputs. The
producing proof checks before exposing the solution; a receiving proof checks
against its own pinned allowance before unification. Peer policy or a staged
increase cannot enlarge that receiving allowance. Atom and opaque-symbol
spellings have the same canonical quantity. Refusals report
`material_limit(proof, answer_bytes, Actual, Limit)`; zero refuses every nonempty
answer. Selection happens once per proof session and its exact policy reads
join the existing OCC/seal validation, including validation of policy changes.
Existing cancellation and owner-incarnation fences retire invalidated work.

Scope wire v16 carries each selection's read mode and exchanges precise scope
read sets for committed resource selectors. Ordinary signed reads retain scope
identities and heights without fetching those predicate versions. The codec has
no separate 64 KiB answer allocation. It still
checks the existing complete scope envelope and enclosing transport capacities;
`too_large(answer)` denotes a payload that cannot fit that carrier, separately
from a policy refusal. The version boundary rejects v15 and all older scope
frames, with no compatibility lane. This source change authorizes no deployment
or rewrite of a founded ontology. Compatible runtime owners and the current
material policy are required together for a fresh deployment.

Proof scopes, invocations, proxies, answers and distributed savepoints have
no separate population ceilings in Erlang. Their retained state uses the
proof's memory allowance and lifetime. Routers retain exact correlations
under the same caller deadlines without imposing another count quota.
Within one scope invocation, local choice points reuse the controller's exact
unmaterialized batch token. Publishing a foreign selection, completing a frame,
restoring a different batch or returning from reentrant work invalidates that
assumption. Repeated local checkpoints/restores therefore make no controller
round trips; real foreign changes retain the existing materialize/restore path.
An allocation reply cannot reinstate a token invalidated during its wait.
Participant and dependency vectors preserve every exact identity; canonical
ordering, uniqueness and complete message bounds still apply. Computed answers retain callable structure and new variable bindings. Known
ground arguments are represented by distinct fresh variables and recovered by
unification with the caller's retained invocation; replies do not echo input
payloads. Output variables retain their resolved values and aliases, including
unbound aliases. The existing wire alphabet, sequence and backtracking semantics
are unchanged. Answer allocation uses committed policy and carrier safety checks
above. The synchronous native adapter uses the
same unifier to return its fully resolved retained call. Invocation
transcripts record every exact call before execution and share the complete sealed
plan's encoding bound, rather than an independent component allowance.

Foreign-history verification no longer borrows a proof worker's heap allowance.
It verifies already accepted material under the existing page, canonical
encoding and VM-headroom checks; current proof admission policy does not
re-admit that history. Its existing owner, custody, cancellation and deadline
mechanisms remain responsible for worker lifetime.

## Predicate definition removal

A sealed `abolish(Name/Arity)` retains its exact clause retractions, followed by
`{abolish,{Name,Arity}}` in the same material diff. Retractions preserve the
existing fact-reaction events; the final operation removes the interpreted
definition, including an already-empty definition. Retracting the last clause
alone keeps that definition. No separate registry or persistence path is used.

Definition removal carries the predicate's ordinary OCC read and write
reservation, including when it has no clauses. Committed policy, immutable
manifest and committee guards treat it as a mutation of that exact predicate.
The existing reducer and MVCC publication apply and notify it; history recovery
uses the same operation without re-executing the goal or historical reactions.
Absent definitions produce no applied removal or new MVCC mutation.

Existing operation encodings are unchanged. The new operation requires compatible
validators/readers before deployment; older runtimes reject it. This code change
authorizes no deployment, history rewrite or user-store migration. Predicate
deletion/recreation presentation identity remains outside this contract.

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


Proof and scope worker admission uses the existing ontology-engine owner and
configured allowances. The built-in population default is unlimited; explicit
positive finite settings still govern active/pending scopes, derivation workers
and retained completion waiters. Capacity release, exact operation deduplication,
worker monitors and original deadlines are unchanged. This is not an aggregate
memory reservation or a new proof-resource policy.


## Namespace storage representation

Namespace/genesis pairs remain exact authenticated identities. Shared store
paths and the existing feed/genesis ETS names use the deterministic namespace
key `ns.` followed by SHA256 hex. That key is a representation, never authority.
The dot keeps the layout disjoint from the prior raw-base64url component.

Store lifecycle entry and stopped-outcome reads refuse an existing prior-layout
path explicitly. Simplex preflights both configured ledger and signing roots
before creating either store. Foreign-cache startup inspects all manifests
before projection cleanup or writer launch, so a retained legacy cache cannot
be silently skipped. Preflight performs exact path metadata reads; ordinary
retained readers continue using their existing handles.

This is a storage format break. A deployment requires a separately approved
preservation/cutover procedure covering both roots, signing journals, ledger
archives, outcome indexes, phase indexes and foreign cache manifests. There is
no runtime fallback, automatic migration, deletion or replacement founding.
The raw signed namespace and encoded link channel retain their distinct uint16
length representations; neither may wrap or truncate a namespace.

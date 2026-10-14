# Fable review: remaining integration gaps (integration-review-01)

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-13. Consultative only.
Basis: `candidate.md`, the frozen owner `tree/` (AGENTS.md identical to the
component packet), and, read live and read-only, `quod_simplex.erl` custody
(`:1184-1192, 2314-2370, 3366-3380, 7524-7532, 8146-8175, 8872-8900`),
`quod_client_goal_target.erl:55-70`, and the ingress forwarding rule already
cited in earlier packets. No command, build or test was run. Nothing here
proposes a new engine, queue, cap change, transaction split, offline
placeholder, weaker absence behaviour or resubmission of an uncertain write.

## 1. Verdict

**Custody.** The trace is right that no existing owner retains a hosted
agent's signed request bytes before sealing, and right that the custodied
mode cannot be generalized blindly. It is wrong that the custodied mode is
therefore unusable. The custody-store row already retains the exact bytes,
and the one contract that makes a lost outcome *definite* rather than
*unknown forever* already exists on the validator side: an expired signed
request can never commit. What is missing is that outcome resolution does not
report that definiteness. Section 3 gives the counterexample, the two paths
I rejected, and the minimum extension with its lifecycle.

**Opening.** The trace is right that `::` cannot reach an arbitrary
client-serving node, and the situation is slightly worse than stated:
observer nodes refuse signed targets and control requests are not
forwarded, so a human connected to an observer-only node cannot run even a
presentation-only control proof today. There is no existing owner-level
channel from a validator-run proof to a client node's view process. Section
4 gives the one existing seam the trace missed for *receiver selection*,
the minimum transport extension for *acceptance*, and the existing path for
*release*.

## 2. Verified owner facts

C1. `quod_agent:start_request/5` mints the operation id and `sign_request/4`
builds the bytes inside the worker; neither is retained. Death or deadline
reports `{outcome_unknown, OperationRef}` to the owner and publishes it, but
the runtime's work state "is not durable" by its own comment
(`tree/src/quod_runtime.erl:2180-2183`).

C2. The per-incarnation custody snapshot `prior_agent_work/3` answers only
atomic-group and claim ids whose request claim names the agent
(`quod_simplex.erl:7524-7532`). Ordinary single-writer transactions and
never-sealed requests are invisible to it, as the candidate says.

C3. Simplex dormant custody persists an exact `#transaction{}` with its
signed submission, monitors the registering process, moves an orphaned row
to the one cancellation owner on owner death or restart, and expires rows by
deadline to a terminal `not_in_charge/unavailable` result
(`quod_simplex.erl:1184-1192, 3366-3380, 8146-8175, 8872-8900`). It never
resubmits. It is sealed-transaction custody, not raw-request custody, and
today only the claim lane registers rows.

C4. The custodied mode commits a Prolog custody row carrying the exact bytes
and signature, then submits those bytes; `resolve` mode resolves an exact
prior request from stored bytes through ingress (`tree/src/quod_agent.erl:202-218`).
Ingress resolution with absent evidence returns `operation_pending` and
states that absence is never permission to create another operation
(`tree/src/quod_client_goal_ingress.erl:266-269`).

C5. Validators refuse a signed request whose `not_after_ms` precedes the
block's admission time (`quod_client_goal:verify_for/5`, `{error, expired}`),
and a key revoked by a host change can no longer commit (`agent_key/3`
checked at scope authentication). These are the two existing facts that can
turn "pending" into "definitely never".

C6. A signed read, execute or control request from a browser executes locally
only where the target is hosted as a ready validator; observers answer
`signed_target_unavailable`, execute and read are forwarded to validator
routes, control is not forwarded (`quod_client_goal_target.erl:55-70`,
`tree/src/quod_client_goal_ingress.erl:316-330`).

## 3. Hosted-agent custody

### 3.1 Counterexample to blind generalization of the custodied mode

Agent incarnation E1 on host H1 runs `gui_complete(Q)` through the custodied
mode: it commits the custody row with bytes B (operation O, expiry T), then
crashes before submitting B. The question stays `submitted`. The host is
reassigned; E2 on H2 starts, its key epoch revokes E1's key. E2's pass reads
the committed custody row, takes `resolve` with B, and ingress answers
`operation_pending` because no claim exists. Nothing in the existing owners
ever turns that into a terminal answer, even after T has passed and the
revoked key makes commitment impossible. E2 can neither retire the row nor
legitimately start a new attempt. The question is stuck forever, and any
"wait for pending" rule only delays the same dead end. This is the exact
gap, not the store write's own uncertainty.

### 3.2 Two paths I rejected

- **Deterministic operation identity without retained bytes** (derive O from
  `Q` and the submission reference so a new incarnation can rebuild it). The
  bytes still contain `not_after_ms` and the goal text, so they are not
  reproducible, the ingress resolver requires exact bytes, and a rebuilt
  request with the same id but a different digest is the FIPA distinct
  attempt under another name. Rejected.
- **Registering the agent's raw request in Simplex dormant custody.** Dormant
  custody takes a sealed `#transaction{}` (C3); the agent's request becomes
  one only after the proof. Using it would mean sealing first, then
  registering, then activating, which is the claim lane's shape and would
  need a new role. Larger than necessary. Rejected.

### 3.3 Minimum extension through existing owners

Keep the custodied mode as the retained-bytes owner. Three contracts are
missing, all in existing owners:

E1. **`prepare_signed_request/3` gating.** It accepts only physics reaction
metadata (`tree/src/predicates/quod_runtime_predicates.erl:186-195`). The
GUI completion must be reachable from the ordinary agent-work path, so the
gate must accept the work owner's metadata as well. Already identified in
the component review; restated because it is on the critical path.

E2. **Expiry-definite resolution.** Outcome resolution must distinguish
"no claim yet" from "no claim and the request can no longer commit". Ingress
holds the bytes, hence `not_after_ms`; compare it with the certified latest
block time of the target namespace, not the local clock, and when the
request is expired and no claim exists, return a terminal `expired` result.
The same rule applies when the signing key's epoch has been revoked by a
committed host change. This is the one new verdict; it is derived from facts
validators already enforce (C5), so it cannot contradict a later commit.

E3. **Pass rule for custody rows.** A pass that finds a committed custody row
for a `submitted` question takes `resolve` with its bytes: `committed`
retires the row through the existing consumption; `rejected` or `expired`
retires the row and leaves the question `submitted` as visible unresolved
work for an authorized domain action (the question review's open R1);
`pending` blocks the pass until the row's own expiry, using the request's
`not_after_ms`, which is protocol expiry detection, not readiness polling.
A pass may start a *new* custody-store attempt only when no custody row
exists and the incarnation is older than the configured agent request
budget, so any store write signed by a dead incarnation has already expired.
That quiet period uses the existing `request_timeout_ms` binding and no new
state.

Lifecycle under E1 to E3:

| Boundary | State | Rule |
| --- | --- | --- |
| Crash before custody commit | nothing durable, store write may be in flight | next incarnation waits the request budget, then attempts; an in-flight store write has expired |
| Crash after custody commit, before submit | row with bytes | `resolve`; pending until expiry, then `expired`, retire row |
| Submitted, reply lost | row with bytes, claim may exist | `resolve`; committed or rejected terminal; pending until expiry |
| Host change | old key revoked | old bytes can never commit; E2 reports `expired`; new host retires and may attempt anew |
| Unchanged repeat | row unchanged, outcome unchanged | one resolve read per pass, no writes, no journal or file I/O |

No second queue, no GUI status fact, no resubmission of uncertain bytes.

## 4. Live opening

### 4.1 Why no existing channel reaches the receiver

Every cross-node owner path is validator-bound: scope sessions select
confirmed validator routes and refuse read-write service to observers;
signed-goal forwarding goes to validator routes and does not forward
control; the foreign log is a one-way certified feed; the directory carries
routes only; the coordinator speaks between validators; the physics owner is
node-local. A client-serving node that validates nothing is unreachable by
any proof, and by C6 a human connected there cannot even run a control proof
for a presentation-only form. The candidate's "receiver-host scope pin cannot
be assumed executable" is therefore understated: today it is not executable
for observers at all, and effects additionally require the executor to be
the scope's dtx signer.

### 4.2 The seam the trace missed: receiver selection is the human's own ontology

The human's client already proves signed goals under the human's identity
at session open. A signed execute at that point, asserting in the human's
own ontology a fact such as `connected_via(NodeKey, Session, NotAfter)`,
written by the human's own authority and retracted or superseded on a new
session, is a committed, authenticated receiver selection with no new owner,
registry or caller-supplied string. Preparation reads it under ordinary
policy; a stale fact resolves to authoritative absence on that selected
scope, which is exactly the settled behaviour. Cost is one small write per
session, nothing on unchanged repeats.

### 4.3 Minimum transport extension for acceptance

Observers already serve local read-only proofs (`cohosted_scope_route`
returns `local` for read-only), and the scope-session transport already
binds the target key end to end. The smallest extension is to let a
**read-only scope be served by a route selected by node key, observer
included**, while keeping read-write and effect scopes validator-only. With
it, the preparing continuation opens a read-only scope on the selected
receiver node for a namespace that node hosts (the human's ontology, which a
client node serving that human's HUD hosts at least as observer), and a
query-class bridge there asks the local view owner to accept the exact
descriptor and allocate the hidden provisional view. The answer is consumed
into the private preparation payload and never becomes a term or a fact; a
refusal is Prolog failure in the preparing proof. This is the `at/2`
candidate narrowed to read-only service, which is the only service an
observer can honestly give. The agent-feasibility bridge from the earlier
addendum sits on the same mechanism.

### 4.4 Release without a push

The receiver needs no post-commit message from the executor. The committed
question row and HUD reference reach the receiver node through the certified
feed it already follows for the human's ontology, and the view owner's
existing projection notifications drive HUD discovery; the provisional view
activates on that certified evidence, by `Q`, and expires on its own
deadline otherwise. "A peer claiming commit" never enters. The journal row
of the prepared presentation then has no external work to perform; whether
the plan keeps it as the admission carrier or drops it is a design choice
already noted in renderer addendum 3 and component addendum 3.

### 4.5 What still prevents a safe implementation

Nothing in 4.2 to 4.4 is implemented. Before coding: the receiver fact's
exact shape and retraction policy; the observer-served read-only route
selection with its refusal classes (`pinned_host_unavailable` distinct from
absence); the view-owner acceptance bridge's deadline and payload; and the
binding of `Q` to the original request through the accessor that now exists.
Nothing requires weakening the absent-human or absent-agent failure.

## 5. Unverified

`register_dormant_transaction/4` role validation, the exact block-time
source ingress would compare against for E2, and whether client nodes host
the human ontologies they serve as observers today.

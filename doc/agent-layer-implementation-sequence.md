# Agent layer: implementation inventory and proposed sequence

2026-09-22. Proposal for Yan's approval; no implementation authority inferred.
Inspected HEAD: `45e3e1308b9542462ba8165b5c3ffc04ac054f9f` (.226).
The deployment status comes from the supplied handoff, not a new fleet check.
Existing uncommitted user/Claude files are left untouched.
Revised after checking Claude's five recommendations against the current code.
Approval of this sequence approves neither a signed-format change nor any fleet action.

**Historical status — 2026-09-24.** This is the pre-implementation inventory
used for the generic-hosting work through 0.7.236. The resulting contracts are
in `ontology-actor-architecture.md` and `agent-fipa-plan.md`; later release and
test evidence in `WORK-IN-PROGRESS.md` supersedes the sequencing language here.
FIPA messaging semantics remain ontology policy built on the reaction model.

## Outcome and scope

Two ordinary ontologies contain two anchored agent instances. Each has one
current hosted process selected by committed NodeRef and epoch. One agent
executes an ordinary `goal(DesiredState)`, stages a durable addressed message,
and the other commits its receipt and one domain consequence. Pending work
survives agent, runtime, and host restart. An authorized host move rotates the
key and resumes the same message without duplicating the receiver consequence.

FIPA ontologies will supply agent specialisation, message meaning, conversation
rules and policy above this substrate. Erlang supplies governed reality bridges,
supervision and bounded asynchronous I/O. It does not interpret performatives,
own domain state or run a second action evaluator.

The two deferred .226 performance findings stay deferred unless a reproducible
correctness or availability failure blocks this milestone. No new optimization
campaign, fleet mutation or data reset is part of this proposal.

## Requirements compared with current code

| Requirement | Inspected implementation | Remaining work |
| --- | --- | --- |
| Ordinary actions and rollback | `priv/ontologies/common_predicates.pl`, `quod_proof_savepoint`, existing proof/commit path | Reuse; add domain actions, not an agent executor |
| Anchored agent identity and signed goals | `quod_agent_ref`, `quod_agent_identity`, `quod_client_goal`, `quod_client_goal_ingress`, `quod_prolog:execute_signed/3` | Hosted caller integration and vault custody; keep active-key certificates and ordinary ACL |
| Stable local NodeRef | `quod_node_actor:creation_options/4`, `bind/4`, `bootstrap/0`, `verify/2`, `principal/0`; node-actor tests | Already implemented; verify ready identity in integration fixtures, do not reimplement node-instance Slices 2–3 |
| Ontology hosting | Node actor's founding `node_ontology_hosting` handler, `hosting_projection/5`, namespace manager's existing mutation lane | Already implemented for `hosts_ontology/4`; this does not start an agent process |
| Ordered D/P/reaction processing | `quod_runtime`, `quod_committed_projection`, runtime tests | Extend existing convergence and frontier lifecycle for hosted children and delivery eligibility |
| Event matching and bindings | `quod_runtime_predicates:diff_to_events/1`, `run_reaction/6`, `reaction_dispatch_6/3` | Already uses `unify_prove_body`; preserve one matcher and continuation |
| Executor ownership | Prolog `executor_owner_node/2` proof followed by unique local key selection in `quod_runtime_predicates` | Add stable agent/NodeRef/epoch resolution and current-incarnation fencing through this same path |
| Certified subscriptions | `subscribes/2`, source-qualified `react_on/3`, runtime catalogue, `quod_foreign_log`, `quod_foreign_projection` | Reuse exact identity, one shared projection, state-only baseline and later live events |
| Node vault | No vault implementation found in production | One encrypted local secret owner, typed signing bridge, mTLS provider endpoint and rotation lifecycle |
| Agent process and durable messaging | No hosted-agent implementation, durable agent outbox or receiver inbox found | Hosting projection, one volatile scheduler, Prolog message state and receiver deduplication |
| Transport priority | `quod_conn:open_new/3` opens streams without assigning priority; pinned `quic` exposes `set_stream_priority/4` | Assign shared channel priorities and demonstrate consensus protection before new agent traffic is activated |

Source search hits for Simplex/Brahms `outbox` are transport buffers, not agent
custody. There is no legacy `quod_outbox` production module to delete or reuse.
The node-wide effect journal remains private lifecycle-effect custody.

This is a static code/test inventory, not a fresh test-pass claim. In particular,
existing runtime tests cover variable binding, unique executor ownership,
context refusal and founding declarations; they do not prove autonomous
hosting or durable agent delivery.

## Contract discrepancies to close first

1. `agent-fipa-plan.md` §§16/19 and the performance closure still list stable
   NodeRef as missing. Node-instance Slices 2–3 and their code are delivered.
   The event plan's heading says hosting is delivered, but its concrete facts
   and implementation concern ontology hosting. Agent-process hosting remains
   new work within the existing runtime owner.
2. Retain `quod.agent.goal.v1`. For hosted agents, every host-epoch advance
   must atomically activate a fresh, previously unused key and revoke the old
   key, including reassignment to the same node. The vault checks committed
   local hosting and active-key authority before signing; normal identity
   validation rejects revoked keys for new work. Existing admitted-operation
   recovery is not undone by a subsequent rotation. Host epoch still fences
   local process incarnations; it needs no extra signed field or goal wrapper.
   A freshly generated random 256-bit `operation_id` supplies request uniqueness
   as well as stable recovery identity; retries retain it and the exact request.
   The codec enforces its size, not its randomness: the hosted request builder
   must generate it securely and preserve it. Propose corresponding §4.1 wording
   in the actor document; do not require another nonce. Ordinary ACL must prevent
   callers bypassing assignment invariants with direct host/key fact mutations.
3. Durable delivery uses the existing signed-goal path. The signed entry target
   is the sender's exact containing ontology, as required by actor architecture
   §10.1, with a goal selecting the receiver through ordinary `::`. It is not a
   sender-signed request claiming the receiver's identity. The receiver checks
   the authenticated sender under its own `can_invoke/4`, not a trusted `From`
   argument. The existing target/router already supports node-to-node requests:
   `quod_client_goal_router:submit/9` and
   `quod_client_goal_target:prepare_forwarded/5` converge on the normal executor.
   However, outbound ownership accepts only `{session, Id, Key}` and public
   ingress requires session admission. Hosted invocation needs a bounded local
   caller integration into this same verified path, with real owner/death and
   admission accounting, not a fabricated browser session or arbitrary-byte
   vault signing. This remaining work does not justify new message framing.
4. The actor document says initially only system ontologies carry governed
   modules, but the delivered node-instance genesis pins
   `quod_ontology_predicates` in an ordinary node ontology. Agent instance
   handlers also need an explicit bridge-access contract. Proposed alignment:
   audited actor-instance modules may be explicitly genesis-pinned, following
   the existing node-instance model; domain policy stays in Prolog. This is an
   explicit documentation/architecture decision, not inferred permission to
   load bridges globally or bypass the manifest.
5. Existing genesis manifests pin BEAM hashes and `state_handler/4` and
   `react_on/3` declarations are founding-only. Ordinary Prolog `action/3`
   rules are not subject to that runtime declaration lock; changing them still
   requires ordinary authorization and the applicable content policy. Step 1
   must list which required policy fits in newly founded agent ontologies,
   which needs authorized changes to existing system rules, and which actually
   needs new founding declarations or pinned modules. The last case requires
   explicit ontology succession/migration, including any affected system
   catalogue identity, and retaining still-pinned BEAMs. Prefer policy in the
   new instance ontologies where consistent with `quod:node`/`quod:agent`
   ownership; do not relocate authority merely to avoid succession. State this
   deployment cost before coding dependent bridges. No network re-found is assumed.

These are the first bounded design checkpoint. The proposal removes the
signed-format-change branch and the epoch-in-goal alternative. The precise
policy/bridge placement and local caller admission still need a concrete
contract before dependent implementation. Governing spec edits follow that
contract; this revision changes only this proposed sequence.

## Ontology-first event and ownership model

Durable facts describe local instances, keys, host assignments, pending sends,
received message identities and application results. Genesis stores local
instance terms; exact external references use the resulting certified anchor.
Host policy remains ordinary Prolog actions governed by `quod:node` policy,
with the authoritative assignment in the agent's containing ontology.

Publication uses a fact mutation or `trigger_event(Term)`. Subscription uses
`subscribes(SourceNamespace, SourceAnchor)` in the subscriber. For example,
this founding declaration expresses a variable-binding reaction:

```prolog
react_on(agent(Agent),
         from(SourceNamespace, SourceAnchor,
              assert(task_ready(Agent, Task))),
         notify_agent(Agent, Task)).
```

Here SourceNamespace/SourceAnchor denote fixed exact source values in the
actual founding declaration. Agent and Task are pattern variables. The existing
Prolog unification binds them for both executor selection and the continuation.
`notify_agent` is an illustrative Prolog handler using a governed reaction bridge;
it is not a new Erlang callback catalogue. Local patterns omit `from/3`.

The runtime considers candidates once, unifies through Erlog, resolves the
unique executor, and delivers only the grounded work to its current process.
A durable reaction consequence enters the ordinary signed-goal path. Reaction
frames remain read-only. Dynamic declarations retain the founding lock; a later
FIPA subscription can activate ordinary protocol facts behind an already-founded
reaction rather than silently enabling newly asserted executable declarations.

Reliable delivery has a different recovery obligation: one founding state
handler reads pending outbox state on live changes and reconciliation, installs
revision-tagged work in the hosted agent, and withdraws superseded work. It
does no network I/O. It needs no second `react_on` rule to wake delivery.
Replay reconstructs pending state; it never re-fires historical reactions.

## Implementation sequence

### 1. Settle the concrete contracts and replacement map

Close the five discrepancies above. Specify the outbox/inbox terms, exact
MessageId and payload binding, completion evidence, host/key transition,
signing/ingress contract, bridge ownership and immutable-manifest rollout.
Keep MessageId stable across delivery attempts, key rotation and host movement;
an attempt's signed operation identity is separate and cannot be regenerated
merely because a response was lost. Reusing an ID with different content must
be refused. Define explicit dedup retention: the first milestone retains its
receiver records; later pruning requires a proved replay horizon.

Record each new bridge's modes, context, policy entry, dependency class,
bounded cost and failure meanings. Signing must use committed authority;
staged grants and live observations cannot authorize it. Resolve how key
generation is requested through the same governed policy without returning
secrets. Do not turn signing into a general query usable by arbitrary proofs.

Deliverable: the actual Prolog terms and action clauses for pending outbox,
receiver inbox/dedup, host assignment and key state, plus their exact owning
ontologies, bridge declarations, source seams, security controls and deployment
impact. Include same-node epoch rotation, forbidden key reuse, atomic host/key
updates and direct-mutation refusal. Define the recoverable signed-request
representation before the first send: expiry or key rotation changes signed
bytes, so re-signing with the same operation ID is not transparent recovery.
Specify resolution of an old operation before any distinct authorized attempt;
retain MessageId dedup across those attempts and never reset a caller deadline.
Then proceed through the following implementation slices under the standing
review and commit gates.

### 2. Implement node-vault custody and ordinary signed agent actions

Add the one supervised vault with encrypted-at-rest keys, non-secret handles,
typed canonical signing and internal mTLS provider boundary. Keep private keys
out of agent state, crash/status formatting, logs and all ontology data.
Specify the local encryption-key provisioning/restart contract as part of the
vault slice; encryption is not complete if its unlock material is accidental.

Use Prolog policy and a narrow external predicate to authorize the exact
request, then enter the common signed target path asynchronously. Verify a real
agent-signed `goal(DesiredState)` through the existing action/savepoint/commit
path, including foreign selection. No hosted-agent-specific proof evaluator.
Test wrong network/anchor/agent, stale epoch, revoked or staged key, unavailable
vault, unauthenticated provider calls and attempted arbitrary-byte signing.

### 3. Add hosted-agent start/stop convergence

Extend `quod_runtime`'s existing handler/lifecycle machinery to supervise only
locally assigned active instances. Prolog resolves NodeRef and epoch; Erlang
registers/monitors the corresponding process incarnation. Multiple instances
per ontology remain valid. No global agent manager or private KB is introduced.

One founding hosting handler starts/stops the projection on live changes and
reconciliation. Process DOWN triggers this same convergence even without a new
ledger block. Runtime death/replay disables old children until reconstruction
establishes current authority. Test start, stop, same-node epoch replacement,
ambiguous ownership and runtime/process restart before adding delivery work.
Hosting convergence itself needs neither an outbox nor a signing call.

Subscribe before snapshot/capture, use exact identity-scoped gproc properties
and known-owner messages, and reject stale revisions, PIDs and duplicate notices.
Route/owner/readiness changes wake only affected work. Worker I/O never blocks
the namespace runtime or facts owner. The hosted process stores only disposable
working state and non-secret key handles; ordinary actions still use the vault
and the one signed proof path established in step 2.

### 4. Add durable signed-goal delivery and the agent's single scheduler

Use ordinary Prolog actions to stage the sender's pending row. The sender signs
one normal request in its containing ontology whose goal invokes, schematically,
`Receiver::accept_message(MessageId, From, Payload)`. Step 1 supplies the actual
exact-anchor selector, receiver instance and result terms. Receiver policy binds
`From` to the authenticated sender and validates its intended local instance;
message arguments never confer authority. No new message envelope or channel.

The receiver commits deduplication and its domain consequence in one ordinary
transaction. Identical duplicates return the established result; a reused
MessageId with different sender/receiver/content fails. The existing verified
applied outcome is the durable ACK. Pending, rejected, mailbox admission and
consensus inclusion are not a successful ACK. Bind the accepted result to the
exact message and receiver through the original signed goal and committed
receipt, using the existing transaction/outcome evidence path.

One founding outbox convergence handler depends on hosting via the existing
`Needs` ordering and feeds the real hosted agent's single volatile scheduler.
Live updates use affected keys; full reconciliation reads current committed
pending state, not ledger prefixes. The projection bridge installs desired
work and performs no I/O. No duplicate delivery reaction, scanner or journal.

The agent owns bounded attempts and ordinary signed-operation correlations.
Before every send, require the installed P-before-E revision, ready runtime
incarnation, exact pending tuple, unique current local host epoch and active
key. Extend the runtime's installed-frontier notification seam if needed;
do not poll its synchronous `effect_frontier/1` accessor. Original operation
budgets, uncertainty, cancellation and actual owner-incarnation checks remain.

The sender commits completion separately after verifying receiver completion.
On uncertainty resolve the existing operation/current committed state; never
blindly create another signed operation. Stable receiver dedup covers actual
message retransmission and host-transfer overlap. Temporary route/key/authority
unavailability leaves the same pending row. No attempt-count loss policy.

Acknowledged volatile delivery is outside this milestone. It belongs with the
later FIPA/ACL transport work, when its independent transport mechanics have a
real consumer. Do not add its framing or scheduler to the durable path.

### 5. Prove restart and explicit host-transfer recovery

Found two agent ontologies through ordinary creation with their declarations,
keys and ACLs. Exercise local, co-hosted and remote delivery through the same
production path. Add authorized reassignment actions: destination vault stages
a fresh key; one ordinary atomic change advances host epoch, activates the new
key and revokes the old one. Use existing DTX only if multiple ontologies write.
Never copy the old secret. Pending messages keep their original identity.

Initially reassignment is an explicit authorized action. Local gproc/monitors
do not decide remote partition authority or elect a replacement host. Test a
returning old host and a destination failure after the assignment commits;
neither may restore the old authority. Recovery after host restart with its
volume and recovery by authorized movement to another host are distinct tests.

## Separate transport slice: stream priorities

Implement the shared priority assignment at `quod_conn`'s existing stream-open
boundary as a separate change, review, gate set and release scope. Audit both
stream directions and all existing channel classes. Use the pinned library's
`set_stream_priority/4`; no new connection pool or consensus path. Its dedicated
mixed-load control must prove lower-priority producers cannot starve `{log}`,
with throughput/latency and resource evidence, including reconnects.

This is independent of message semantics and can land before step 4. It is a
prerequisite to activating additional agent traffic on shared connections, not
permission to reopen the deferred .226 optimization campaign. Local functional
tests need not wait for its separate hardware acceptance.

## Verification and removal obligations

Acceptance must use real production seams and processing/commit evidence:

- A target-driven action commits once; rollback, cut and ordinary read behavior
  remain intact. No staged hosting or outbox fact starts outward work.
- All replicas store the pending fact; only the selected host sends. Zero or
  ambiguous owners, wrong anchors and obsolete epochs fail closed.
- Kill the sender after outbox commit/before send, after receiver commit/before
  ACK, and after ACK/before sender completion. Restart receiver before retry.
  The same MessageId yields exactly one durable receiver consequence.
- Restart agent, runtime and whole host separately; repair a replay gap and
  collapse an overloaded live queue. Pending delivery resumes and completed
  delivery and historical best-effort reactions do not repeat.
- Transfer hosting while work is in flight; inject old-incarnation results and
  conflicting payloads. Verify current key/epoch and receiver dedup together.
- Local and certified subscribed event matches bind the same variables. No-op
  fact changes emit nothing; repeated explicit events remain occurrences.
  First subscription/rebuild baselines trigger no historical handlers.
- Missing routes/readiness park without polling; matching availability wakes
  work. Caller deadlines, cancellation and uncertain outcomes remain honest.
- Count processes/workers, mailbox/queue growth, pending age, retries and dedup;
  mixed agent/subscription traffic must not starve consensus. Report action and
  durable-message latency separately; volatile delivery has its own later acceptance.

For each replacement, audit static callers and dynamic predicate/supervisor
roots. Remove replaced executor-resolution helpers and exclusive tests/docs
only when their obligations move to the common path. Preserve necessary
bootstrap node-key semantics; do not sweep consensus principals into this work.
Correct stale status text by a scoped edit after approval, preserving Yan's
changes and pinned document prefixes. No legacy scanner is implemented merely
to remove it later. No production deletion is claimed from absent code.

Report actual src/include additions/deletions, functions/exports, owner/state
and message changes at each slice. New vault and hosted-agent behavior will
add code; justify that growth separately from any simplification. Run focused
controls, then the standing clean sequential full gates and required exact-tree
review at release/commit boundaries, retaining full logs and true child exits.
Label bumps remain separate. Hardware acceptance gets its own fresh evidence.

Acknowledged volatile delivery, FIPA ACL syntax, AMS/DF, delegation and full
conversation protocols follow this milestone. They consume these same ontology
actions, subscriptions, reactions,
host ownership and four delivery guarantees; none gains another executor.

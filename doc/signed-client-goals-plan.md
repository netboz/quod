# Signed client goals

**Status:** Slices 1 through 6 were the committed key-as-user generation. The
generic agent hard break is implemented, committed, and deployed;
`generic-agent-identity-plan.md` is now authoritative
for its request, principal, certificate, and durable-operation shapes. The
paragraphs below summarize the earlier delivery slices; current shapes are
stated in the dedicated sections and agent plan. Slice 1 contained
the pure request codec, signature verifier, and atom-safe parser. Slice 2 adds
authenticated `read`: it entered the ordinary read-only proof path and applied
the ontology's normal ACL. Slice 3 added the coordinated durable
format break, validator-side request/ACL revalidation, one shared operation
projection for ordinary transactions and DTX Begins, and Explorer rendering.
Slice 4 added local signed execution and cursors and moved the Explorer console
to that authenticated path. Its temporary `create_user_home` convenience is
now deleted. Slice 5 carried the same signed request through remote and nested scopes and activated signed
multi-ontology commit, makes missing root identity retryable during history
validation, and persisted unresolved browser writes. Slice 6 let any client
node route the unchanged signed request to one exact target validator, while
the target still uses the same proof, ACL, transaction, DTX, lifecycle, cursor,
and outcome paths. It also adds predicate-neutral client term builders. The
incompatible generation has no compatibility decoder; any fleet still carrying
an older generation must activate it through the documented clean re-found
procedure.

The current coordinated generation extends that same projection with
batchable `remote_claim` and `remote_complete` metadata. A signed write with
one foreign material target is no longer a one-participant DTX group: it is a
source claim followed by the target's ordinary application. The historical
Slice-3 one-participant wording below is retained only where explicitly
labelled.

> **Architecture correction.** This document records the implemented signed
> request whose principal was labelled `{user, Key}`. That retired label is
> retained below only where the earlier delivery history is being described.
> `ontology-actor-architecture.md` defines the deployed model in which every
> durable actor state is ontology content and `agent` is the generic signer
> class. A concrete signer is a local agent instance identified externally by
> `agent_instance_ref/3`; the containing ontology, its creator, that instance,
> its key, and its ACL permissions remain distinct. The deployed
> agent-bound request is one hard format migration of this same path, not a
> second client endpoint, executor, or ACL.

> The deployed model removes the transitional `create_user_home` helper. It
> is not renamed to `create_agent`: Quod has no core agent-construction
> predicate. Existing `create_ontology/2` may place local `instance_of/2`,
> `agent_key/3`, and ACL facts in genesis, and ordinary transactions may add
> instances later. `instance_of/2` creates only logical class membership; a
> separate committed hosting fact controls an optional Erlang runtime.

> `generic-agent-identity-plan.md` owns the exact replacement request,
> certified identity validation, format audit, deletion map, and closure
> tests. Historical slice descriptions below are not compatibility contracts.

### Agent-format routing decision

The retired user-key request entered the selected target ontology directly.
The agent-format break changes this once: a signed request enters the exact
ontology containing its claimed agent instance, and another target is reached
through the existing `Target::Goal` mechanism. The old direct-target form is
deleted rather than retained beside it.

The containing ontology validates the active `agent_key/3` binding. Remote
targets additionally receive one independently verifiable **identity**
certificate from that origin; trusting the single node which opened a scope is
not enough. The certificate proves the active key only. Each target still
applies its own existing `can_invoke/4`; the origin never authorizes another
ontology's predicate.

## Purpose

An authenticated client must be able to submit an ordinary Prolog goal. The
goal may contain any predicate admitted by the target ontology. It is not
selected from a server-owned catalogue.

This plan concerns only the path:

```text
agent runtime or human-facing client -> constructs goal -> signs goal
    -> server processes goal

agent runtime receives an event -> constructs goal -> signs goal
    -> server processes goal
```

Direct text entry, menus, forms, buttons, voice input, scripts, and received
events are different origins for a goal. They have no additional execution
authority. Every origin submits the same signed-goal request and reaches the
same ACL, proof, backtracking, transaction, DTX, and lifecycle-effect
machinery.

This plan does not define or reinterpret any Prolog predicate. A client API may
offer convenient goal builders, but they still produce an ordinary goal before
signing.

## Non-negotiable rules

1. A browser-provided goal is data until its signature, bounds, target, and
   protocol version have been checked.
2. The user's Ed25519 signature covers the exact goal and its exact target. A
   node may route the request but may not replace either.
3. Every validator that votes for a resulting transaction independently
   verifies the user signature and the binding between the request, principal,
   goal, plan, and transaction.
4. The existing ontology `can_invoke/4` proof is the authorization decision.
   Signed ingress does not introduce a second ACL or a predicate allowlist.
5. The signing layer does not classify predicates or change their meaning. It
   hands the verified goal to the existing server execution entry point.
6. Resource limits are generic. Goal bytes, syntax depth, symbols, proof time,
   alternatives, scopes, diff size, effect size, and transaction size remain
   bounded regardless of the predicate or domain.
7. A client session is temporary transport state. It is never written into an
   ontology or ledger and is not the durable proof of user intent.
8. A write with an uncertain result is resolved by stable identity. It is never
   silently re-proved as a new operation.
9. Client-side goal construction cannot grant authority, bypass ACLs, or
   substitute a different server-side goal.

## Request origins, one execution path

### Direct goals

The protocol accepts a bounded signed request containing a Prolog goal. This is
the foundation used by power users, scripts, the Explorer once it shares client
authentication, and higher-level interfaces.

The initial protocol modes are:

- `read`: prove without permitting material writes;
- `execute`: use the first successful result and commit any material work;
- `cursor`: preserve the proof and expose `next`, `accept`, and `stop`.

These modes describe what the client requests from the proof session. They do
not classify the goal's predicates. After verification the goal is handed to
the same execution boundary used for server-local terms.

### Client-generated goals

Client code may construct a goal from a GUI interaction, a received event, a
script, a projected ontology description, or any other input. The subject
matter is unrestricted; the result is still simply a Prolog goal.

The client converts a chosen description locally into an inspectable goal and
signs that goal through the same protocol. The server does not replace an
opaque input ID with different executable code. A client may also skip the
description entirely and enter a goal directly.

The exact constructed goal must be available for inspection; a friendly client
need not interrupt every ordinary interaction with raw Prolog text.
Presentation metadata may explain the goal, collect values, or choose defaults;
it is not authorization evidence. Convenience APIs may build common goal
patterns, but the signing and server paths do not know or care why a predicate
was chosen.

## Signed request

The wire format must be a small, versioned, cross-language binary layout. It
must not use JavaScript object iteration order or Erlang external-term encoding
as the signing contract.

The current agent request binds:

```text
domain                 = "quod.agent.goal.v1"
network_identity       = pinned root/network identity
signing_public_key     = 32-byte Ed25519 public key
operation_id           = 32 random bytes generated once by the client
agent_namespace        = bounded UTF-8 bytes
agent_genesis_anchor   = 32 bytes
agent_instance_text    = one ground dot-terminated Prolog term
mode                   = read | execute | cursor
parser_version         = 1 | 2
not_after_ms            = signed admission deadline
goal_text              = exact bounded UTF-8 bytes
```

The signature is Ed25519 over the canonical concatenation of those fields with
fixed-width lengths and tags. For writes, `operation_id` is the durable
duplicate-protection identity. For reads it is request correlation only,
because reads create no ledger claim. The node-local `session_id` is
deliberately absent.

Whitespace differences create different request digests. That is harmless:
the signature protects the exact text the user saw. The target anchor prevents
a namespace name from being replayed after re-foundation, and the network
identity prevents replay on another Quod network.

`parser_version = 1` freezes the complete parsing contract, not merely a codec
number. It fixes the grammar and operator table without consulting ontology
state, plus UTF-8 handling, comments, escapes, integer and float syntax,
character codes, quoted atoms, list syntax, variable naming, and the rule that
every anonymous `_` is a distinct fresh variable. Validators never interpret
version 1 through their current ambient Prolog operator table.

Version 2 adds the explicit Erlang-style binary literal `<<"...">>`. It
yields one opaque Erlang binary; ordinary `"..."` remains a Prolog character
list, and spaced `A << B` remains the shift operator. A contiguous `<<"`
sequence is intentionally reassigned by Version 2, so the signed parser-version
byte—not grammar superset compatibility—preserves every existing request's
meaning. Literal escapes must resolve to bytes (`0..255`); full Erlang
bit-syntax segments are intentionally outside this grammar. A later grammar or
operator change requires another parser version.

Both supported versions accept exactly one dot-terminated term, followed only
by layout or comments. Bare identifiers use the Prolog ASCII
letter/digit/underscore form; UTF-8 remains available inside quoted atoms and
strings. A missing terminator, a second term, or trailing non-layout input is
rejected.

Quoted values use strict backslash escapes. Both versions accept `n r t v b f e s d`,
escaped single quote, double quote, and backslash, plus terminated hexadecimal
`\x...\` and octal `\...\` numeric escapes. Any other escape, an invalid
Unicode code point, or ISO doubled-quote syntax is rejected rather than
silently changing the signed value.

`not_after_ms` limits first admission of a captured request. It is no later than
the current authenticated session expiry. An ordinary transaction or DTX Begin
must have a certified block timestamp within that limit; once admitted, later
DTX recovery phases remain valid so recovery cannot be stranded by wall-clock
expiry. Historical replay verifies the original admission condition against
the committed block timestamp, not the current clock.

An optional future immutable session subject, such as a selected agent chain,
must be added as a new signed protocol version. It must not be inserted into v1
implicitly by a node.

## Parsing and canonical goal binding

The former Explorer parser was not a suitable trust boundary: it parsed text into
VM atoms before user authentication. The public client path needs one bounded,
atom-safe parser boundary.

The sequence is:

1. enforce HTTP/body and field bounds;
2. resolve the live session and, only when an operator enabled one, apply the
   configured rate policy;
3. verify the Ed25519 signature over the exact request bytes;
4. atom-safely lex and parse `goal_text` under `parser_version`;
5. encode the parsed term with `quod_durable_term:encode_goal/1`;
6. retain the request bytes, request digest, and canonical goal blob together;
7. materialize only the bounded callable symbols required for execution.

The parser must assign named variables deterministically by first appearance and
each anonymous variable deterministically by occurrence, so every validator
derives the same durable goal blob. It must reject malformed or ambiguous
syntax, trailing terms, excessive nesting, excessive symbol count, and invalid
UTF-8 before execution.

The verified evidence, including that name-to-variable-id table, is carried
through the one proof context. A committing node uses it to give the selected
durable result the exact signed binary variable names without parsing the goal
again. Unsigned node-local proofs retain their traditional atom-named result;
both forms converge on the same canonical durable result encoding. Each `_`
occurrence remains a distinct variable in the proof but has no signed name, so
the one shared result projection omits it from read replies, cursor replies,
and durable execute/accept results.

All non-operator symbols must use the existing opaque-symbol representation
during parsing, even if a same-named atom already happens to exist in one
validator VM. This makes the parse result independent of node-local atom-table
history. The owning ontology performs the controlled callable materialization
step afterward. The design must not call the current atom-creating text parser
and then try to count new atoms afterward. This is a resource boundary, not a
predicate allowlist.

New callable-symbol materialization is charged only after authentication. It
has a per-request maximum and one global node headroom/cumulative safety ceiling
so creating free user keys cannot exhaust the BEAM atom table slowly. Operators
may additionally enable per-signing-key and per-peer rate budgets, but Quod ships with
no request-rate policy by default. Existing symbols do not consume allocation
budget. Exceeding a safety or explicitly configured policy limit fails before
proof execution and does not grow the atom table. The cumulative ceiling uses
one VM-lifetime atom-count baseline retained across auth-owner restarts,
matching the lifetime of the atom table it protects.

Every validator later repeats the signature check and deterministic parse and
requires the derived goal blob to equal the durable goal binding carried by the
record it validates. A sealing node therefore cannot turn a signed harmless
goal into a different executable goal. The browser does not implement this
parser or Erlang's durable codec: it signs the exact text. Cross-language tests
pin request bytes/signatures, while Erlang parser fixtures pin the resulting
durable goal blobs.

## Ingress and routing

Every client-enabled node exposes the same endpoint. A node that hosts the exact
target identity may execute locally. Otherwise it resolves a current target
validator and forwards the signed request unchanged over an authenticated node
channel with bounded correlations, time, and bytes.

The gateway may add transport correlation and tracing outside the signed
payload. It may not rewrite the principal, target, mode, operation ID, parser
version, or goal. The target cannot inspect the gateway's node-local browser
session and does not need to: it independently verifies the user signature,
operation ID, and deadline, and may apply operator-configured rate policy to
the authenticated forwarding node and signing key.

Routing failure returns a typed availability result. It never causes the
gateway to execute the goal in another namespace or to substitute a local
ontology with the same name and a different genesis anchor.

## Authorization and proof execution

After validation, the engine receives:

```text
exact agent-ontology identity
parsed goal
{agent, AgentReferenceBlob}
signed request evidence
execution mode
```

It enters the existing `quod_prolog` path. Top-level `can_invoke/4`, proof
limits, predicate semantics, backtracking, overlays, OCC checks, sealing,
ordinary transactions, distributed transactions, and lifecycle effects are
unchanged in meaning.

There is no `case Predicate of ...` authorization table at HTTP ingress. If an
ontology permits a predicate through its existing policies and proof rules, the
signed client may use it. If the ontology refuses it, the normal bounded failure
reasons are returned.

The direct `quod_prolog:prove/2`, `prove_ro/2`, and `execute/2` functions remain
trusted in-VM operator and test interfaces. They are not HTTP client routes,
are not mounted by Explorer, and do not compete with the signed browser
boundary. Lifecycle goals use `execute/2` like every other write; the former
dedicated action interface was deleted.

For a signed local read, the exact target anchor is carried into the proof
worker and checked there again before the frozen ontology snapshot is used.
Stopping and re-founding a namespace between HTTP admission and worker startup
therefore refuses the old signed request instead of rebinding it to the new
incarnation.

## Remote scopes and the agent principal

The earlier remote scope binding carried only the origin node key. That was
insufficient for signed agent goals.

Scope-open V5 carries one bounded authentication context:

```text
node proof: auth = node
agent proof: auth =
  {signed_goal, RequestBytes, AgentSignature, AgentIdentityCertificate}
```

The binding includes the authentication-context digest. A remote target
verifies the request signature, exact origin request, stable agent principal,
and quorum identity certificate before opening the scope. The certificate
proves the origin agent's active key, not permission. The scope latches the
principal and request digest for its lifetime; nested scopes forward the same
evidence unchanged and each target applies its own ordinary ACL.

The nested invocation goal need not equal the signed top-level goal: it is a
derivation of the signed proof. Existing call-chain and authorization
transcripts prove that derivation. All participant plans must nevertheless bind
the same signed request digest and principal, so a mixed-principal group is
rejected before Begin.

## Plan, transaction, and DTX binding

A durable write requires the agent evidence to survive beyond the entry node.
The three record roles are deliberately different:

```text
sealed plan:
    request_binding = none | {agent_goal_v1, RequestDigest}

ordinary transaction:
    request_auth = none |
      {agent_goal_v1, RequestDigest, RequestBytes, AgentSignature}
    auth_transcript = none |
      {agent_goal_v1, TargetAuthorizationTranscriptBlob}

DTX Begin:
    request_auth = none |
      {agent_goal_v1, RequestDigest, RequestBytes, AgentSignature}
```

An ordinary transaction must carry the complete `request_auth`, not only its
digest: validators receive the transaction but never receive its sealed plan.
The node-author signature and semantic transaction ID cover that complete
field, allowing proposal validation, replay, catch-up, and Explorer inspection
to re-verify the agent signature and re-parse the text independently.

An ordinary agent transaction also carries the one target authorization
entry already recorded by the proof. It is encoded with the existing bounded
authorization-transcript codec; it is not a new ACL or a second authorization
format. The entry must name the exact transaction goal and the canonical
single-target agent chain `[TargetIdentity]`. At proposal validation, ordered
apply, replay, and catch-up, validators decode that one entry and call the same
`quod_ask:validate_authorization_transcript/6` checker used for DTX Prepare.
They re-prove `can_invoke/4` against the committed parent state and require the
new verdict to equal the recorded verdict. A changed policy is therefore
handled by the same deterministic authorization and OCC rules as the original
proof. Node-authored transactions and genesis carry `none` and retain their
current behavior.

For DTX, the origin Begin carries the complete request and stable operation
claim, but no origin ACL transcript. Origin validators verify the request and
the agent ontology's active-key fact. A direct `A -> B::Goal` is authorized by
B, not A. The Manifest and every participant plan bind the request digest. A
participant validator follows the certified Begin reference, verifies that
binding, and re-proves its own target plan's existing authorization transcript.
Prepare does not copy the complete request into every participant ledger.

The former home-registration request, `create_user_home`, specialized route,
and `quod_user` helper are deleted. Enrollment is ordinary ontology creation
and ordinary `instance_of/2`, `agent_key/3`, and ACL facts. There is no
`user_registration_v1` or replacement registration executor.

For every agent write, validators require:

- the signature verifies under the public key inside `RequestBytes`;
- the request target is the proof origin's exact identity;
- the request principal equals the plan and record principal;
- parsing the request produces the exact top-level durable goal blob;
- an ordinary local transaction contains exactly one target authorization
  entry and re-proves it at the committed parent;
- a DTX Begin contains the active-key proof and operation claim but no
  caller-ontology permission verdict for a remote predicate;
- every participant plan binds the same request digest;
- the operation identity has not been used with another request digest.

Explorer must show the user request identity and signature separately from the
node author signature. A DTX view obtains the full evidence from its certified
Begin rather than pretending each participant authored another copy.

The node author signature keeps its present meaning: a validator authored the
ledger proposal. It does not replace or imply the user's authorization
signature.

This changes signed plan, transaction, DTX, and scope-wire formats. There must
be one hard protocol version at implementation time, with no permissive dual
decoder.

### Durable evidence limits

The limits are shared protocol constants, not estimates chosen independently
by each caller:

- canonical signed-goal request bytes are at most
  `?QUOD_CLIENT_GOAL_REQUEST_BYTES` (currently 8,623 bytes); the accompanying
  Ed25519 signature is exactly 64 bytes and its digest exactly 32 bytes;
- the complete transaction encoding, including `request_auth` and the
  top-level authorization entry, remains within
  `quod_transaction`'s `?MAX_CANONICAL_BYTES` limit (256 KiB);
- the encoded authorization entry remains within the existing
  `?QUOD_MAX_SCOPE_TRANSCRIPT_BYTES` limit (12 KiB); the same codec and bound
  are used when it is sealed and when every validator decodes it;
- a DTX Begin containing the one complete request evidence remains within
  `?QUOD_MAX_DTX_BODY_BYTES` (224 KiB), and its signed control envelope remains
  within `?QUOD_MAX_DTX_CONTROL_BYTES`; and
- the signing-journal pending-Begin frame keeps its existing derived bound:
  `max(?QUOD_MAX_DTX_BODY_BYTES + ?QUOD_MAX_DTX_CONTROL_BYTES + 165,
       ?MAX_BLOCK_BYTES + 4096)`. The journal must derive from the shared DTX
  limits rather than introduce another request-size constant.

Every encoder and decoder enforces the same limit. Exact-limit and limit-plus-
one fixtures are protocol tests for transactions, Begins, transcript entries,
and signing-journal frames.

## Stable operation identity and outcomes

### One authoritative origin ledger

The signed request's exact agent-ontology identity is the proof origin and the
sole authority for `{AgentReferenceBlob, OperationId}`. Operation identity cannot be kept
independently in whatever foreign ontology happened to receive a diff: two
proofs may legitimately discover different material participant sets.

The origin ledger therefore receives the first durable claim before any foreign
material can become visible:

- a read creates no durable claim;
- a write whose sole material participant is the origin uses its ordinary
  transaction as the claim;
- a write with exactly one foreign material target commits a batchable
  `remote_claim` in the origin, then one ordinary `remote_application` in the
  target; a batchable `remote_complete` in the origin later marks the claim
  terminal; and
- two or more material/read-dependent targets use a DTX Begin and the atomic
  group protocol.

The claim fixes the exact target transaction before any foreign diff can
become visible. It preserves the authoritative origin operation record without
misclassifying a one-target write as a distributed atomic group.

This is not an ontology fact and does not accumulate user data in the origin
KB. It is ledger/control metadata, like the existing transaction and DTX
records.

### One shared operation projection

Ordinary origin transactions and origin DTX Begins feed the same deterministic,
disk-backed projection keyed by:

```text
{AgentReferenceBlob, OperationId}
```

Each row is bounded and stores the unique request digest plus its ordinary or
group outcome reference. The memory cache is bounded; total durable history
follows ledger retention rather than an unbounded RAM map.

This projection is consensus-critical validation state, not a lookup cache.
Every validator reconstructs it deterministically from certified ledger order
before validating later blocks, using the same discipline as the existing
author-sequence floor. Proposal preview starts from the approved parent's
projection and reserves its claims; candidate validation, ordered apply,
replay, catch-up, and boot reconstruction all run the same transition
function. A candidate containing an invalid duplicate claim is invalid even if
an in-memory lookup table happens to be empty.

The current ledger is unpruned, so the disk projection is fully reconstructible
from history, like the outcome index and author-sequence floors. Every admitted
operation keeps its stable agent reference, operation id, request digest, and
first outcome reference
indefinitely on disk. Disk compaction may rewrite those rows but must not remove
their tombstones; only the RAM cache is size-bounded. Any future ledger-pruning
design must preserve equivalent durable tombstones and requires a separate
protocol review before operation IDs may be forgotten.

The public client reference is anchored and independent of whichever validator
accepted the connection:

```text
{operation, OriginNamespace, OriginGenesisAnchor,
            AgentReferenceBlob, OperationId}
```

Current origin validators answer operation lookup from the same applied
projection and corroborate it through the existing certified-current-view
quorum mechanism. A claimed row returns its first ordinary or group outcome
reference and the exact request digest, whose normal resolver supplies the
result. The client compares that digest with its persisted signed request
before accepting the result. Absence is not reported as safe-to-retry while an
admission could still be in flight.

Proposal preview, consensus validation, ordered apply, replay, and catch-up all
use the same rules in certified order:

- no prior claim: admit this transaction or Begin and record the operation;
- same key/id and same digest at ingress or in retained custody: do not propose
  another record; return the first operation reference and resolve it;
- same key/id and different digest: deterministically reject the conflict;
- retained but not yet certified: report pending;
- uncertainty: return `outcome_unknown` with the stable operation reference.

The rule is not merely a lookup optimization. Proposal preview reserves claims
from its approved parent so two gateways cannot both introduce the same
operation as fresh work in consecutive slots. A Byzantine candidate that still
contains a second same-digest record is invalid; validators do not commit a
redundant no-op ledger record. Ordered validation and replay enforce the same
transition, and the same projection arbitrates an ordinary transaction racing a
DTX Begin.

If a node cannot resolve the pinned root-network identity while applying an
already committed signed record, it closes its proof gate and waits. It keeps
no second entry queue: once the identity is available, the namespace replays
the committed ledger through the same apply path. The temporary local lookup
failure is never converted into a crash or a verdict about the committed
record.

The deterministic parent-state checks live in the process-free
`quod_commit_validation` library. Consensus voting and ordered apply call the
same content/DTX validators; only apply records an operation claim at the
certified slot. `quod_prolog` remains the sole owner of the knowledge base,
outcome index, scheduling, replay, diff application, and publication. The
extraction adds no process, cache, ACL, or alternate goal executor.

The client checkpoints the operation ID and signed request before sending.
After an uncertain response it resolves that identity; it does not generate a
new operation ID or silently re-prove the goal. Automatic retransmission is not
enabled until consensus admission and outcome lookup prove this invariant for
ordinary and distributed writes.

Read-only requests do not need ledger rows. Their operation ID remains useful
for request correlation but does not create durable state.

An admitted `execute` request, and a cursor request once Accept is chosen,
always records exactly one durable operation claim. If its requested database
change is already present, the ordinary transaction or DTX origin plan carries
that claim with an empty diff; it does not invent a root write or a second
record format. Untouched foreign scopes remain non-participants. This makes a
successful no-change write resolvable after reply loss while signed reads stay
ledger-free.

### Expired custody

Before placing retained work, a proposer compares the request deadline with the
next proposed block timestamp. Expired work is removed rather than poisoning a
whole candidate block that every validator must reject. It returns a definite
`expired` result only when authoritative origin lookup proves there was no
claim; otherwise it returns the stable operation reference for resolution.
Replay checks the original deadline against the certified admission block
timestamp, never against the current wall clock.

The same distinction applies to a caller parked on retained custody. When the
proposer drops that custody, it replies `expired` only after the applied origin
projection proves absence and no valid admission can still commit. If a claim
or an approved-but-uncertified candidate may exist, it replies
`{outcome_unknown, OperationRef}`. It never reports a timeout as permission to
generate a new operation ID.

## Backtracking cursors

Opening a cursor uses one signed request with `mode = cursor`. `next` and `stop`
are node-local session operations on an unguessable cursor ID and do not create
ledger records.

`accept` commits the currently displayed alternative through the original
proof; it never re-proves. The durable plan binds the original signed goal,
operation ID, canonical selected result, and proof transcript. A signed cursor
goal authorizes any valid alternative of that goal. Interfaces that require the
user to authorize one exact ground result should construct and sign that ground
goal instead of relying on a nondeterministic cursor.

Caller disconnect, cursor-owner restart, and engine restart retain the existing
rule: after durable handoff the result is resolved by its reference and never
retried as a fresh proof.

## Explorer and client relationship

The ledger browser may remain public, but its interactive console is mounted at
`/explorer/` on the TLS client listener and uses the same login and signed-goal
API as the browser client:

- the Explorer console is simply one signed-goal editor;
- its Next/Accept/Stop controls use the signed cursor flow;
- transactions display both user intent signature and validator-author
  signature;
- ontology lists continue to update from runtime projection events;
- no Explorer-only proof or ACL bypass remains.

This was one replacement, not a compatibility period. The cursor coordinator
is now the UI-neutral `quod_client_cursor`; `/api/prove`,
`/api/proof-cursors*`, the atom-creating Explorer goal parser, and the
specialized registration endpoint/executor are absent. No deployment or
re-found may expose both the specialized and signed write entrances.

## Historical signed-client protocol break and deployment

This section records the generation introduced by the signed-client work. The
current event-capable generation is transaction V9, semantic transaction ID
V5, and signed DTX plan V6; `doc/transaction-signatures.md` and
`doc/event-reaction-refinement-plan.md` are authoritative for those current
formats. The V8/V4/plan-V5 values below are retained only as the history of the
earlier coordinated break, not as accepted formats.

The deployed 0.7.71 protocol uses transaction V7, semantic transaction ID V3,
plan V4, scope wire V3, and DTX V1 records. Signed writes are a separate future
hard break. They are not part of the already-deployed lifecycle-effects break.

The following list records the **historical Slice-3 format break**, not the
current accepted format. That implementation used one coordinated protocol
generation:

- transaction V7 becomes V8 and semantic ID V3 becomes V4; the fixed V8 tuple
  grows from arity 16 to arity 18 and carries both `request_auth` and the
  top-level `auth_transcript`; both fields are covered by the node signature
  and semantic transaction ID, and every decoder accepts that exact arity
  only;
- plan V4 becomes V5 and its core carries `request_binding`;
- DTX Manifest V1 becomes V2, all DTX records and controls become V2, and Begin
  carries the one full `request_auth` plus the one top-level authorization
  entry; the Manifest and plans carry the request digest;
- signed DTX groups temporarily permitted one participant so a foreign-only
  write still had an authoritative Begin on the origin; the current generation
  replaces that temporary shape with `remote_claim`, `remote_application`, and
  `remote_complete`, and restores the DTX minimum to two participants;
- scope wire V3 becomes V4 and binds the principal plus authentication-context
  digest;
- the origin operation projection and operation outcome reference land in the
  same generation; and
- Explorer JSON exposes the new request and operation fields explicitly.

There is no dual decoder and no compatibility branch for older ledger records.
Enabling signed writes therefore requires a deliberate clean re-found. The
pure request codec, parser, signatures, and read-only ingress may be developed
and reviewed before that deployment break is activated.

Slices 3 through 5 were development stages of this one protocol generation, not
three deployment generations. Slice 3 lands all affected V8/V4, plan V5, DTX
V2, and scope V4 data shapes; Slice 5 completes scope propagation. There was no
deployment or re-found between those slices. The final generation passed its
focused replay, crash, and multi-ontology gates and was activated through one
deliberate clean re-found; there was no rolling mixed-version upgrade.

## Implementation slices

### Slice 1: pure request contract

- Add a process-free request codec and signature verifier.
- Define fixed field sizes, byte caps, parser version, request digest, and
  stable operation reference.
- Add a bounded atom-safe goal-text parser that derives the existing durable
  goal blob deterministically.
- Test browser/Erlang byte fixtures, signature substitution, malformed syntax,
  variable determinism, symbol exhaustion attempts, and target/network replay.

No execution endpoint lands before this slice is independently reviewed.

### Slice 2: local signed reads

- Add authenticated `read` ingress on the client listener.
- Thread request evidence and the then-current `{user, Key}` into `prove_ro`
  (historical Slice-2 shape, replaced atomically by the agent format).
- Use the normal top-level ACL and return normal bindings/failure reasons.
- Reuse the bounded ingress and worker admission. An operator may opt into
  per-signing-key or per-peer rate policy; it is disabled by default.
- During this intermediate slice, reject a foreign scope rather than
  substituting the forwarding node principal for the signed principal. Slice 5
  removes that temporary gate by carrying the exact signed authentication.

This proves origin-local predicates without changing a ledger format.

Implemented endpoint:

```text
POST /api/goals/read
{
  "session_id": base64url(32 bytes),
  "request": base64url(canonical signed request bytes),
  "signature": base64url(64-byte Ed25519 signature)
}
```

The exact request target must be hosted locally in this slice. Successful and
logical-failure replies include the request digest and operation id for
correlation; reads create no ledger operation row. Named variables are returned
under the exact UTF-8 names from the frozen parser, not VM-created atoms.

Admission uses the shared bounded ingress and worker pools. An operator may
opt into per-signing-key or per-peer request and symbol rate policies, but neither is
enabled by default. New callable vocabulary remains subject to the
VM-lifetime cumulative safety ceiling that survives auth-owner restarts.
Existing symbols are free, ordinary data atoms are not allocated merely because
the request mentioned them, and the shared VM headroom limit remains
authoritative. The exact signed anchor is checked once more inside the proof
worker so a re-found cannot rebind an already-admitted read.

An internet-facing client listener should explicitly configure a
`challenge_limit` inside `client_rate_limits`, because login challenge issuance
is unauthenticated. On a trusted network, the bounded challenge and session
tables are the default capacity protection.

### Historical Slice 3: durable request and operation binding

- Land the coordinated format break described above.
- Verify request evidence independently during proposal validation, ordered
  apply, replay, catch-up, and outcome reconstruction. Re-prove the one origin
  authorization entry through the same ACL checker for both an ordinary
  transaction and a DTX Begin.
- Add the shared origin operation projection for ordinary transactions and DTX
  Begins, with exact first-claim, alias, conflict, pending, and uncertain rules.
- Route a signed foreign-only write through an origin Begin with one DTX
  participant rather than the then-existing direct foreign ordinary
  optimization. This historical route is deleted in the current generation.
- Render user request identity, signature, operation reference, and first
  outcome in Explorer.
- Test two gateways racing the same request; ordinary-versus-Begin races; a
  foreign-only participant; same ID with a different digest; expired retained
  custody; replay at the signed deadline; and crashes before and after every
  origin claim checkpoint.

At the Slice-3 boundary, the foreign-only case was fixture-tested by
constructing signed plans in-VM while remote signed scopes remained closed.
Slice 5 now exercises that record shape through the real scope transport.

An older persisted generation cannot be upgraded in place; activation uses the
required clean re-found.

### Slice 4: local signed execute and cursor

- Add `execute` and `cursor` endpoints using the existing engine and Explorer
  cursor state machine rather than a second implementation. Refactor that
  state machine into a neutral signed-goal cursor owner; do not retain an
  Explorer-specific coordinator beside it.
- Pass verified goals through the ordinary proof boundary with their verified
  request evidence, without adding signing-specific predicate dispatch.
- Carry the already-verified request evidence through proof and transaction
  construction. The submitting node must not repeat signature verification or
  parsing merely to derive the transaction and its outcome reference;
  validators still verify the durable evidence independently.
- Preserve the original request evidence and operation ID through cursor
  Accept after any number of `next` operations.
- Migrate fixed home registration to a normal signed root goal using the same
  operation projection, then delete `/api/user/register`, the specialized
  registration signature request, and its dedicated executor.
- Move the Explorer console and its Next/Accept/Stop controls to those same
  signed endpoints, then delete its unsigned prove/cursor routes and current
  parser in the same change.
- Test ordinary writes, lifecycle effects, failure reasons, every cursor
  transition, disconnects, deadline expiry, exact duplicates, conflicting
  duplicates, registration migration, removal of every replaced specialized
  route, and uncertain outcomes.

Implemented closure includes a composed signed cursor test that opens,
advances, accepts, reads the committed fact, and verifies that the ledger
transaction retained the original request evidence and operation ID. The TLS
client-listener test also fetches the mounted `/explorer/` bundle; the
disabled-listener test proves that mount is unavailable when the client
listener is disabled.

At the Slice-4 boundary, signed proofs were still limited to origin-local
material plans. That temporary development restriction is removed by Slice 5;
it never fell through to the old node-principal behavior.

### Slice 5: activate scopes and multi-ontology goals

- Complete the then-current scope V4 implementation carrying the full
  principal and request digest. The later agent hard break replaces it once
  with scope V5.
- Verify evidence at every remote target and preserve it through nested scopes.
- Bind the identical request digest into every participant plan and Manifest;
  keep the complete request and operation claim once in Begin. The current
  Begin has no caller-ontology ACL verdict for a remote target predicate.
- Test two- and three-ontology user writes, restrictive target ACLs, principal
  substitution, altered request bytes, stripped evidence, route failover,
  coordinator crash, abort, and Complete recovery.
- Make a temporarily unavailable root-network identity a retryable
  history-validation result rather than an invalid committed transaction.
  Carry that result through the shared replay and catch-up validator instead
  of adding a special catch-up exception.
- Persist the signed request and operation ID until its anchored outcome is
  definite; a lost response must not depend on browser memory.

Current closure uses the one scope path for local, co-hosted, and remote
targets. Scope-open authentication contains the exact signed request, stable
agent principal, and proof-scoped identity certificate. Each target verifies
identity and then runs its own ordinary `can_invoke/4` proof. Every sealed plan
binds the same request digest. A foreign-only material write commits the
complete request and operation claim once as `remote_claim` in the origin,
then uses the target's ordinary `remote_application`; two or more targets carry
the request once in the origin Begin.

Root-network identity unavailability is one typed retry result shared by live
preview, replay, catch-up, and foreign-history verification. It is not a
catch-up exception and never converts a committed signed record into invalid
history merely because the local root projection is temporarily unavailable.

The browser journals unresolved durable operations in IndexedDB without a
fixed population limit; available browser storage is the only capacity bound.
It writes the exact request and signature before Execute or cursor Accept,
never evicts an unresolved row, and removes it only after a definite outcome.
Reload recovery sends those bytes only to `POST /api/goals/outcomes`; it never
re-proves or resubmits the goal. If durable browser storage is unavailable,
login, reads, and cursor browsing remain usable, while Execute and Accept fail
closed before submission.

The real three-node suite sends one browser-equivalent signed goal through two
remote scope hops and commits three participant plans under the same user
request. It also covers target ACL refusal, exact wire evidence, route
failover, and composes with the existing coordinator Decision-boundary crash
test, which proves recovery from certified records without re-proving.

### Slice 6: any-node ingress and client goal builders

**Delivered implementation:** one bounded node-level router now carries
the exact request bytes and signature between a gateway and an
identity-pinned target. Browser sessions and addresses remain local to the
gateway; the target derives the agent from the signature, derives the
forwarder from the authenticated link, independently verifies the request,
and enters the same target executor used by local ingress. Authentication,
cursor, and router owners run on every node, while `client_enabled` still
controls only the public listener. Local and remote replies share one closed,
bounded result codec and one HTTP renderer. The generalized cursor owner
handles both local sessions and authenticated forwarders, and the gateway
keeps only a bounded volatile route to the owning target. Optional JavaScript
term builders produce inspectable goal text and feed the existing signer;
they contain no predicate or authorization catalogue. The shared wire-goal
materializer also treats the heads and bodies of the standard database-update
predicates as callable positions, so fresh predicates use the same atom-safe
target materialization path rather than an ingress exception. Real three-node
tests exercise remote read, execute, cursor commands, lifecycle execution,
and two- and three-participant signed writes through a gateway that does not
host the target.

This slice changes where a signed request may enter the network. It does not
add another way to execute a goal. A browser remains authenticated to the node
whose HTTP listener it chose (the **gateway**); the ontology engine that owns
the exact signed target remains the **target**.

#### One gateway, one target executor

Refactor the current local-only ingress into these two boundaries:

1. The gateway validates its node-local browser session, charges the existing
   browser peer and user request budgets, verifies the exact signed request,
   and checks the signed network identity and session deadline.
2. If the gateway hosts the exact `{Namespace, GenesisAnchor}`, it calls the
   target executor locally with that verified evidence.
3. Otherwise it resolves only
   `quod_directory:validator_routes(Namespace, GenesisAnchor)`, opens an
   identity-pinned link to one ready validator, and forwards the exact request
   bytes and signature unchanged.
4. The target independently verifies the signature, network, exact local
   target identity, parser version, and deadline. It charges the same generic
   user request budget plus an authenticated-forwarding-node budget, performs
   callable-symbol materialization on the target VM, and calls the same target
   executor as the local path.
5. That executor enters the existing `quod_prolog` signed proof path. The
   existing `can_invoke/4`, proof, scope, OCC, transaction, DTX, lifecycle
   effect, and outcome machinery remain the only implementations.

The gateway never sends its browser session id or browser IP to the target.
They are local transport facts, not agent authority. The target derives the
agent solely from the verified request and derives the forwarding peer solely
from the authenticated node link. A forwarding node need not be a validator:
it routes an agent-signed request but gains no permission from doing so.

The gateway and target verification intentionally repeat the bounded signature
and atom-safe parse: each protects a different trust boundary. Profile this
cost under remote load before considering an optimization; do not introduce a
gateway-attested shortcut or a second evidence format merely to avoid parsing
at most one bounded signed request twice.

The internal authentication/materialization owner and signed cursor owner must
run on every node that may host a target, even when that node's public client
listener is disabled. `client_enabled` continues to control only the public
HTTP listener. Concretely, remove the `client_enabled` checks from
`quod_client_auth:start_link/0` and `quod_client_cursor:start_link/0`; start
both idle owners unconditionally under `quod_sup`, and leave the existing check
only in `quod_client:start_link/0`. Do not introduce a second
"target-capable" flag. Do not add target-only copies of optional rate policy
or the symbol allocator; expose one sessionless, verified-forwarder admission
operation on the existing owner and reuse its current admission logic.

#### Transport owner and closed wire

Add one node-level signed-goal router outside `quod_simplex` and
`quod_prolog`. It owns only:

- a single fixed signed-goal transport channel;
- exactly monitored outbound request correlations and pinned peer/link identity;
- exactly monitored inbound workers, with no fixed population refusal;
- same-link replies, timers, monitors, and cleanup; and
- volatile cursor routes from a gateway cursor id to its exact target peer.

The router uses the existing `quod_quic`/`quod_link` pinned-link and channel
infrastructure with one new deterministic channel name. It does not introduce
another link manager. Live authenticated links are reused per target peer and
multiplex bounded request ids; do not open one transport connection per goal.

It owns no Prolog state, overlay, plan, ACL result, transaction, or durable
outcome. Raw signed goals must not be put through the existing transaction
relay: that relay begins after proof and belongs to consensus custody, while a
signed goal is still bounded untrusted proof input. They also must not be
modelled as a fake remote scope; a top-level request has no origin proof or
scope session yet.

Use a process-free codec beside the router. Its outer and inner forms are
closed, canonical, atom-safe, and smaller than the shared transport frame
limit. The request algebra contains only:

```text
submit(RequestId, exact RequestBytes, exact Signature, optional CursorId,
       trace carrier)
cursor(RequestId, CursorId, next | accept | stop)
```

The reply algebra contains only pre-execution refusal, one bounded normalized
proof result, and typed availability/protocol failure. There is no separate
accepted frame: a correlated refusal is route-eligible, a correlated result or
error is terminal, and silence after send is uncertain.
Every reply binds the exact request id; cursor replies additionally bind the
exact cursor id. Peer identity always comes from `quod_link:peer_key/1`, never
from a payload field.

The router mailbox performs only outer frame admission, peer/link and request
correlation, worker admission, and delivery. Like `quod_ask_router`, it hands
the still-bounded result payload directly to the waiting request worker for
closed decoding and HTTP rendering. It must not deserialize proof bindings,
format failure reasons, or wait for proof execution in its serialized loop.

Factor proof-result normalization out of the HTTP renderer. Local execution
and a remote target both produce the same closed result form. Bindings use the
existing signed variable-name projection and `quod_durable_term` result codec;
failure stacks use the existing bounded failure-reason codec; anchored outcome
references use their existing validated forms. The gateway's HTTP renderer
then renders that one normalized result regardless of where it ran. Do not
send arbitrary Erlang terms or JSON between nodes and do not add a second
result renderer.

A shared `QUOD_CLIENT_GOAL_MAX_REPLY_BYTES` bound is derived below
`QUOD_TRANSPORT_MAX_FRAME_BYTES` with the codec's fixed envelope allowance.
Apply that same source-of-truth bound to local HTTP results so routing does not
change observable semantics. A read whose complete answer list exceeds that
bound fails with the same typed `result_too_large` reply locally and remotely
and may be performed with the existing cursor mode instead; do not add a
private multi-frame result stream in this slice.

#### Admission, route changes, and uncertainty

Directory routes are hints, not authority. The request's signed namespace and
anchor are authoritative, and an `anchor_conflict` fails the whole lookup.
The gateway may try the next exact validator only when link establishment
failed before the request was sent, or when a target explicitly refused it
before acquiring durable custody because it was not ready or had no worker
capacity.
A missing, malformed, or non-correlating reply after send is uncertainty, not
a pre-execution refusal, and never permits automatic route advancement.

The closed route-eligible refusal set is exactly `not_ready`, `busy`, and
`rate_limited`, and each is emitted only while no durable handoff exists.
`rate_limited` can occur only when an operator enabled a policy; it is
route-eligible because that policy protects one target and distributing
admitted load across validators is intentional. `invalid_request`, `invalid_signature`, `wrong_network`,
`wrong_target`, and `expired` are terminal request failures and never cause
route shopping. Every other response after send is uncertain.

Once a request has been sent, it is pinned unless that target returns one of
the three explicit pre-execution refusals above. A timeout, link loss,
malformed reply, or gateway restart never causes an automatic proof on another
validator:

- `execute` returns the existing stable operation reference as
  `outcome_unknown`; the browser retains its already-journalled request and
  resolves it through `POST /api/goals/outcomes`;
- `accept` uses that same operation reference and uncertainty rule;
- `read` has no durable side effect and returns target unavailable;
- a lost cursor open/next/stop makes that volatile cursor unavailable rather
  than guessing its proof position.

The existing outcome path is reused unchanged. `quod_prolog:outcome/1` already
resolves a foreign operation through a certified current target view and
requires `f + 1` identical current-validator replies. Ordinary absence remains
uncertain. The new goal channel must not grow another outcome query or trust a
single target's claim that an uncertain write never happened.

An authenticated target's live read, solution, or logical failure has the same
serving-node trust boundary as the current local client endpoint. Durable
write certainty continues to come from the existing ledger/outcome path; the
transport reply does not become a new certificate.

#### One cursor coordinator

Keep `quod_client_cursor` as the only proof-cursor state machine. Generalize
its owner binding from a local `{SessionId, User}` pair to one exact volatile
owner capability:

```text
local browser:    {session, SessionId, User}
forwarded cursor: {forwarder, GatewayNodeKey, RequestLink, User}
```

The cursor owner's internal key is the full
`{OwnerCapability, CursorId}` pair, never the externally supplied cursor id
alone. The gateway creates one random cursor id before local execution or
forwarding and retains a bounded route row tying an **opaque** owner capability
to the exact target identity and pinned target peer/link. Session lookup and
interpretation remain solely in `quod_client_auth`; the router only compares
the capability for exact equality. A target opens the ordinary
`quod_client_cursor` under the authenticated gateway key and that same cursor
id. Next, Accept, and Stop pass through the gateway route to the same target;
the target accepts them only from the authenticated peer and exact link that
opened the cursor. The cursor owner monitors that link directly, so the target
router does not retain a second cursor table. No target can inspect the
gateway's browser session, and no second cursor continuation or proof state
lives at the gateway.

Cursor state remains deliberately volatile. A gateway or target restart loses
it. Link or command uncertainty invalidates the gateway route instead of
issuing a fresh Next and possibly skipping a solution. Accept is the one
exception in durability, not in code path: once it may have crossed handoff,
the existing detached-observer behavior lets the write finish and the browser
uses its operation journal to resolve the outcome. Stopping, expiry, engine
death, link death, router death, session mismatch, and peer mismatch must each
clean the exact route, monitors, workers, and cursor once.

#### Predicate-neutral client goal builders

Add optional pure client-side term builders next to `signed-client.js`. They
construct and render ordinary inspectable Prolog goal text from generic term
parts such as atoms, strings, numbers, variables, compounds, and lists. They
must:

- escape according to the selected frozen parser contract;
- contain no predicate catalogue, action catalogue, ACL, namespace policy, or
  server-side intent mapping;
- return the exact goal text before signing so a UI can display it;
- feed the existing `signedGoal` function without a second request encoder;
  and
- remain optional: direct text and application-specific builders continue to
  work.

Menus, forms, received events, scripts, and future world interactions are
only possible callers of these generic helpers. The subject of a goal is not
part of this transport slice, and Prolog's `action` design pattern is not
reinterpreted as a UI action system.

Fixture tests freeze the operation id and deadline and prove that direct text
and every builder origin producing the same goal text yield byte-identical
request bytes and signatures. They then submit those requests through local
and remote ingress and require identical normal `can_invoke/4` results.

#### Required pre-activation closure from Slices 1 through 5

Slice 6 is the last implementation slice before a separately authorized
activation. It therefore owns these already-identified closures; none may be
left as an implicit follow-up:

- Remote signed scope admission must enforce the request's `not_after_ms`.
  Refactor `scope_authentication_reason` to use the same contextual signed-goal
  validator with the exact origin identity and target admission time rather
  than calling bare `quod_client_goal:verify/2`. An expired request cannot open
  a new remote or nested scope merely because its origin proof began earlier.
- Resolving an operation row whose stored request digest differs from the exact
  signed request is a typed operation-id conflict, not
  `outcome_index_corrupt`. Preserve genuine corrupt-index handling, but map
  this expected first-claim conflict explicitly as `operation_conflict`
  through ingress and HTTP.
- A ready target that temporarily lacks the root network identity is not
  necessarily rebuilding. Replace that scope-admission misnomer with one exact
  `network_identity_unavailable` retry result through the scope wire, Ask
  mapping, docs, and tests; retain `ontology_rebuilding` only for an ontology
  that is actually not ready.
- The production-dead legacy exports were removed or TEST-fenced:
  `quod_ontology:network_identity/1`, `prepare_action/1`, `create/2`, `join/3`,
  `quod_proof_context:start/5`, `quod_prolog:open_cursor/4`,
  `quod_client_auth:session/1` remains TEST-only; the other obsolete APIs,
  including the old DTX request-authorization accessor, are absent. Tests use
  the surviving production boundaries except for that direct session fixture.
- Add the missing real-path negatives for wrong network at admission, expired
  signed request, and a restrictive foreign target refusing a nested sub-goal
  through its ordinary `can_invoke/4` policy.

These are code and test closures, not new protocol features. Their stale
"before public activation" wording is removed from Slice 5 because the two
implemented items there are already described as completed; this list is the
authoritative remaining pre-activation work.

#### Implementation order and deletion rule

1. Close the inherited Slices 1-through-5 items above and run their focused
   tests before widening ingress.
2. Add the pure closed wire/result codec and adversarial codec fixtures.
3. Extract one normalized signed-client result boundary and make the existing
   local HTTP path use it.
4. Split gateway session admission from the shared target executor; keep one
   local call into that executor and add the bounded router's remote call.
5. Generalize the existing cursor owner, then route local and remote cursor
   operations through that one owner and the gateway's volatile route table.
6. Add generic client builders and byte-identity fixtures.
7. Delete the local-only target gate, temporary result branches, old cursor
   ownership shape, and any test-only routing scaffold before broad gates.

There is no ledger or consensus format change in Slice 6 and therefore no new
re-found requirement. This slice must not deploy while it is being developed.
Before review it must pass compile, full EUnit, the real local and three-node
signed-goal suites, xref, Dialyzer, diff check, client tests/build, Explorer
lint/build, and a stale-path grep.

Required non-vacuous Slice-6 tests include:

- a gateway that does not host the target performs read, execute, cursor
  Next/Accept/Stop, a lifecycle effect, and a multi-ontology write;
- exact request bytes and signature observed at the target equal the browser
  bytes, while session id and browser address are absent;
- wrong anchor, whole-directory anchor conflict, wrong network, changed bytes,
  changed signature, changed user, unauthenticated peer, and non-validator
  target all fail before proof;
- local and forwarded forms of the same request reach the same target executor
  and return the same normalized result and ACL reasons;
- gateway and target user/peer limits, inbound worker caps, correlation caps,
  result caps, timeouts, caller death, link death, and router restart leave no
  retained worker, route, monitor, or subscription;
- a first unavailable route may advance to a second route before execution,
  while loss after admission never starts a second proof;
- two gateways racing the same execute still converge through the existing
  operation claim on one durable record, at most one material diff, and one
  outcome;
- remote execute and Accept reply loss retain the browser journal row and are
  resolved only through the existing certified outcome path;
- cursor peer/session substitution fails, ambiguous Next invalidates rather
  than advances the route twice, and ambiguous Accept completes at most once;
- a second authenticated gateway cannot open or command a cursor using an id
  already minted by the first gateway;
- a buggy gateway forwarding one admitted execute to two validators still
  converges through the existing operation claim on one durable record and at
  most one material diff;
- an unresolved browser journal row from a dead gateway resolves through a
  new authenticated session on another gateway without resubmitting the goal;
- an expired forwarded request is refused independently at the target before
  proof or cursor creation;
- an oversized read returns the identical typed `result_too_large` refusal on
  local and forwarded paths; and
- disabling the public client listener leaves target forwarding available but
  exposes no HTTP client routes.

The Slice-6 review must answer explicitly:

1. Is the new node owner transport-only, with all goal execution still
   converging on one target function and the existing Prolog path?
2. Are browser-session authority, authenticated forwarding-peer identity, and
   the stable agent identity separated
   without trusting a forwarded field?
3. Do typed refusals permit route changes only before durable handoff, while
   every ambiguous post-send write returns the stable operation reference
   without automatic re-proof?
4. Does the generalized cursor owner keep exactly one proof continuation and
   make link loss, Next uncertainty, and Accept uncertainty unambiguous?
5. Is the normalized result codec canonical, atom-safe, bounded, and shared by
   local HTTP and remote transport rather than becoming a second renderer?
6. Does operation recovery reuse certified current-view outcome resolution
   without trusting one target or adding another status owner?
7. Are client builders purely predicate-neutral term renderers whose output is
   visible before the existing request encoder signs it?
8. Can an HTTP-disabled target accept forwarded signed goals without exposing
   a public listener or duplicating auth, rate, cursor, or symbol state?

## Historical required review questions

The review must answer these before implementation:

1. Does signing exact UTF-8 goal text plus a fixed parser version give every
   validator enough information to detect goal substitution?
2. Is the atom-safe parsing/materialization boundary complete for nested
   meta-calls and write predicates such as `assertz/1`?
3. Does the single origin operation projection arbitrate concurrent gateways,
   ordinary transactions, and DTX Begins in certified order without permitting
   a second diff?
4. Can the operation outcome reference resolve the first claim without
   trusting one node or keeping unbounded pending state?
5. Does carrying one request evidence object through all scopes preserve the
   existing call-chain authorization semantics?
6. Are cursor semantics clear enough, especially that signing a nondeterministic
   goal permits accepting any valid alternative?
7. Does storing full evidence in an ordinary transaction or once in DTX Begin,
   with digest references in plans and Manifest, still permit independent
   replay verification by every voter?
8. Is the coordinated V8/V4, plan V5, DTX V2, and scope V4 break complete, with
   every old arity rejected and a clean re-found required before activation?

## Mandatory adversarial tests

- Exact parser fixtures cover every Version-1 operator, comment, escape,
  integer, float, character-code, quoted-atom, list, named-variable, and
  anonymous-`_` rule, plus Version-2 byte literals, including malformed and
  ambiguous inputs.
- Parsing unknown symbols within the limit produces the same goal blob on
  every validator; exceeding request/user/peer/global symbol budgets fails
  before materialization and does not increase the VM atom count.
- The same signed request arriving concurrently through two gateways produces
  one origin claim, one logical outcome, and at most one material diff.
- Two gateways racing byte-identical requests through different validator
  authors produce one claim; the second aliases the first, and both operation
  references resolve to that one outcome.
- An ordinary origin transaction racing a DTX Begin for the same operation is
  ordered by the shared projection; one is the claim and the other aliases it.
- Reusing an operation ID with different signed bytes is rejected across
  ordinary and DTX admission.
- A forged recorded authorization verdict, an authorization entry for another
  goal, and a policy revoked between sealing and apply are each rejected
  deterministically during proposal validation and replay.
- A signed write with only one foreign material participant creates an origin
  Begin and never uses the direct foreign ordinary path.
- Request evidence and authorization transcripts at their exact transaction,
  Begin, and signing-journal limits are accepted; each limit-plus-one form is
  rejected before retention.
- Mutating any byte of `request_auth` in replay or catch-up makes the certified
  record invalid rather than accepting the node-author signature alone.
- Admission exactly at the signed deadline replays identically; later custody
  is dropped before proposal, and uncertainty returns the operation reference
  rather than authorizing another proof.
- Every remote and nested scope rejects changed request bytes, changed
  principal, changed authentication digest, or missing evidence.
- Cursor Accept after multiple Next operations commits the selected result
  under the original request evidence and operation ID without re-proving.
- After Slice 4, the specialized registration route, unsigned Explorer prove/cursor
  routes, atom-creating Explorer parser, and dedicated registration executor
  are absent; registration and Explorer goals work through the signed-goal
  path only.
- If an operation is reserved only in an approved parent that is later skipped,
  a second gateway initially resolves through the operation reference; after
  authoritative absence is established, the exact still-valid signed request
  is re-admissible and no phantom tombstone remains.
- A participant that cannot fetch and verify the certified origin Begin treats
  Prepare as retryable and never approves it from the Manifest digest alone.
- Compaction and restart retain enough operation tombstone information that a
  different digest cannot reuse an old `{AgentReferenceBlob, OperationId}`.
- A crash after the operation claim is applied but before its outcome row is
  published rebuilds both projections from ledger order and converges on the
  same first outcome.
- Cross-node resolution of `outcome_unknown` requires the existing certified
  current-view threshold and ignores one Byzantine conflicting response.
- A remote or nested scope rejects altered request bytes, a substituted agent,
  a mismatched authentication digest, and missing evidence; the valid exact
  request reaches the normal target ACL and transaction path.

## Explicit non-goals

- no hard-coded list or classification of predicates;
- no change to any predicate's semantics;
- no second goal executor;
- no server substitution of an opaque menu ID for user-visible intent;
- no client-provided Erlang term or executable callback;
- no session token in durable state;
- no automatic retry based only on a timeout;
- no weakening of existing ACL, proof, OCC, DTX, effect, or resource checks.

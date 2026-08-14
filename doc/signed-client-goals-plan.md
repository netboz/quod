# Signed client goals

**Status:** Slices 1 through 3 are implemented in the working tree. Slice 1 contains
the pure request codec, signature verifier, and atom-safe parser. Slice 2 adds
authenticated local `read`: it enters the ordinary read-only proof path as the
signed user, applies the ontology's normal ACL, and refuses foreign scopes
until signed scope propagation lands. Slice 3 adds the coordinated durable
format break, validator-side request/ACL revalidation, one shared operation
projection for ordinary transactions and DTX Begins, and Explorer rendering.
It is awaiting independent review. No public signed write, signed cursor, or
any-node forwarding endpoint exists yet.

## Purpose

An authenticated client must be able to submit an ordinary Prolog goal. The
goal may contain any predicate admitted by the target ontology. It is not
selected from a server-owned catalogue.

This plan concerns only the path:

```text
user interacts with client UI -> client constructs goal -> client signs goal
    -> server processes goal

client receives an event -> client constructs goal -> client signs goal
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

Conceptually, version 1 binds:

```text
domain                 = "quod.user.goal.v1"
network_identity       = pinned root/network identity
user_public_key        = 32-byte Ed25519 public key
operation_id           = 32 random bytes generated once by the client
target_namespace       = bounded UTF-8 bytes
target_genesis_anchor  = 32 bytes
mode                   = read | execute | cursor
parser_version         = 1
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
every anonymous `_` is a distinct fresh variable. A later grammar or operator
change requires another parser version; validators never interpret version 1
through their current ambient Prolog operator table.

Version 1 accepts exactly one dot-terminated term, followed only by layout or
comments. Bare identifiers use the Prolog ASCII letter/digit/underscore form;
UTF-8 remains available inside quoted atoms and strings. A missing terminator,
a second term, or trailing non-layout input is rejected.

Quoted values use strict backslash escapes. V1 accepts `n r t v b f e s d`,
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

The current Explorer parser is not the new trust boundary: it parses text into
VM atoms before user authentication. The public client path needs one bounded,
atom-safe parser boundary.

The sequence is:

1. enforce HTTP/body and field bounds;
2. resolve the live session and rate limit the authenticated user and peer;
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

All non-operator symbols must use the existing opaque-symbol representation
during parsing, even if a same-named atom already happens to exist in one
validator VM. This makes the parse result independent of node-local atom-table
history. The owning ontology performs the controlled callable materialization
step afterward. The design must not call the current atom-creating text parser
and then try to count new atoms afterward. This is a resource boundary, not a
predicate allowlist.

New callable-symbol materialization is charged only after authentication. It
has a per-request maximum, per-user and per-peer rate budgets, and one global
node headroom/cumulative safety ceiling so creating free user keys cannot
exhaust the BEAM atom table slowly. Existing symbols do not consume that
allocation budget. Exceeding any limit fails before proof execution and does
not grow the atom table. User and peer charges commit together: if either
budget refuses, neither allowance is spent. The cumulative ceiling uses one
VM-lifetime atom-count baseline retained across auth-owner restarts, matching
the lifetime of the atom table it protects.

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
operation ID, and deadline, and rate-limits both the authenticated forwarding
node and the user key.

Routing failure returns a typed availability result. It never causes the
gateway to execute the goal in another namespace or to substitute a local
ontology with the same name and a different genesis anchor.

## Authorization and proof execution

After validation, the engine receives:

```text
exact target identity
parsed goal
{user, PublicKey}
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

For a signed local read, the exact target anchor is carried into the proof
worker and checked there again before the frozen ontology snapshot is used.
Stopping and re-founding a namespace between HTTP admission and worker startup
therefore refuses the old signed request instead of rebinding it to the new
incarnation.

## Remote scopes and the user principal

The current remote scope binding carries the origin node key, and the remote
runtime reconstructs `{node, OriginKey}`. That is insufficient for signed user
goals.

Scope-open v4 must add a bounded authentication context:

```text
node proof: auth = node
user proof: auth = {signed_goal, RequestBytes, UserSignature}
```

The binding includes the authentication-context digest. A remote target
verifies the user signature, exact origin request, and `{user, PublicKey}`
principal before opening the scope. The scope latches that full principal and
request digest for its entire lifetime. Nested scopes forward the same evidence
unchanged.

The nested invocation goal need not equal the signed top-level goal: it is a
derivation of the signed proof. Existing call-chain and authorization
transcripts prove that derivation. All participant plans must nevertheless bind
the same signed request digest and principal, so a mixed-principal group is
rejected before Begin.

## Plan, transaction, and DTX binding

A durable write requires the user evidence to survive beyond the entry node.
The three record roles are deliberately different:

```text
sealed plan:
    request_binding = none | {user_goal_v1, RequestDigest}

ordinary transaction:
    request_auth = none |
      {user_goal_v1, RequestDigest, RequestBytes, UserSignature}
    auth_transcript = none |
      {user_goal_v1, TopLevelAuthorizationTranscriptBlob}

DTX Begin:
    request_auth = none |
      {user_goal_v1, RequestDigest, RequestBytes, UserSignature}
    auth_transcript = none |
      {user_goal_v1, TopLevelAuthorizationTranscriptBlob}
```

An ordinary transaction must carry the complete `request_auth`, not only its
digest: validators receive the transaction but never receive its sealed plan.
The node-author signature and semantic transaction ID cover that complete
field, allowing proposal validation, replay, catch-up, and Explorer inspection
to re-verify the user signature and re-parse the text independently.

An ordinary user transaction also carries the one top-level authorization
entry already recorded by the proof. It is encoded with the existing bounded
authorization-transcript codec; it is not a new ACL or a second authorization
format. The entry must name the exact transaction goal and the canonical
single-target user chain `[TargetIdentity]`. At proposal validation, ordered
apply, replay, and catch-up, validators decode that one entry and call the same
`quod_ask:validate_authorization_transcript/6` checker used for DTX Prepare.
They re-prove `can_invoke/4` against the committed parent state and require the
new verdict to equal the recorded verdict. A changed policy is therefore
handled by the same deterministic authorization and OCC rules as the original
proof. Node-authored transactions and genesis carry `none` and retain their
current behavior.

For DTX, the origin Begin carries the complete request and the one top-level
authorization entry once. Origin validators re-prove that entry through the
same `quod_ask:validate_authorization_transcript/6` path used for an ordinary
transaction. The Manifest and every participant plan bind only the request
digest. A participant validator follows the certified Begin reference it
already must verify, checks the full evidence there, and requires the
Manifest/plan digest binding to match. It then re-proves its target plan's
existing authorization transcript. Prepare must not copy the full request or
the origin authorization entry into every participant ledger merely for
convenience.

The currently deployed fixed home-registration request is not added to the new
ledger format. There is no `user_registration_v1` transaction variant. Slices
3 through 5 are one undeployed protocol generation, so Slice 4 replaces the
current specialized registration endpoint with a normal `user_goal_v1` root
goal before the generation can be activated. That goal's predicate derives the
fixed home from the authenticated principal and enters the ordinary
lifecycle-effect path. The current specialized HTTP route, request signature
domain, and dedicated registration executor are deleted in the same change.
The two registration paths are never enabled together in an activated
signed-write release.

For every user write, validators require:

- the signature verifies under the public key inside `RequestBytes`;
- the request target is the proof origin's exact identity;
- the request principal equals the plan and record principal;
- parsing the request produces the exact top-level durable goal blob;
- an ordinary user transaction or origin DTX Begin contains exactly one
  top-level authorization entry for that same goal and target, and re-proving
  it against the committed origin parent through
  `validate_authorization_transcript/6` yields the recorded verdict;
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

The signed request's exact target identity is the proof origin and the sole
authority for `{UserPublicKey, OperationId}`. Operation identity cannot be kept
independently in whatever foreign ontology happened to receive a diff: two
proofs may legitimately discover different material participant sets.

The origin ledger therefore receives the first durable claim before any foreign
material can become visible:

- a read creates no durable claim;
- a write whose sole material participant is the origin uses its ordinary
  transaction as the claim;
- any write with foreign material uses a DTX Begin on the origin, even when
  there is only one material participant and that participant is foreign;
- the DTX participant lower bound therefore becomes one for signed requests;
- the existing direct foreign-only ordinary submission is not used for signed
  writes, because it would leave no authoritative origin claim.

That foreign-only case deliberately adds the origin Begin round trip. It is the
cost of recording the user's operation before a foreign diff can become
visible, and must not later be removed as a performance optimization.

This is not an ontology fact and does not accumulate user data in the origin
KB. It is ledger/control metadata, like the existing transaction and DTX
records.

### One shared operation projection

Ordinary origin transactions and origin DTX Begins feed the same deterministic,
disk-backed projection keyed by:

```text
{UserPublicKey, OperationId}
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
operation keeps its key, request digest, and first outcome reference
indefinitely on disk. Disk compaction may rewrite those rows but must not remove
their tombstones; only the RAM cache is size-bounded. Any future ledger-pruning
design must preserve equivalent durable tombstones and requires a separate
protocol review before operation IDs may be forgotten.

The public client reference is anchored and independent of whichever validator
accepted the connection:

```text
{operation, OriginNamespace, OriginGenesisAnchor,
            UserPublicKey, OperationId}
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

The client checkpoints the operation ID and signed request before sending.
After an uncertain response it resolves that identity; it does not generate a
new operation ID or silently re-prove the goal. Automatic retransmission is not
enabled until consensus admission and outcome lookup prove this invariant for
ordinary and distributed writes.

Read-only requests do not need ledger rows. Their operation ID remains useful
for request correlation but does not create durable state.

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

The Explorer is currently an operator console with a separate unauthenticated
goal endpoint. Slice 4 moves it to the same client login and signed-goal API:

- the Explorer console is simply one signed-goal editor;
- its Next/Accept/Stop controls use the signed cursor flow;
- transactions display both user intent signature and validator-author
  signature;
- ontology lists continue to update from runtime projection events;
- no Explorer-only proof or ACL bypass remains.

This is one replacement, not a compatibility period. Slice 4 first refactors
the existing Explorer cursor coordinator into the shared signed-goal cursor
owner, then switches the Explorer UI to signed `execute` and `cursor` requests,
and finally deletes `/api/prove`, `/api/proof-cursors*`, the current
atom-creating Explorer goal parser, and their unsigned server entry points in
the same change. No deployment or re-found may expose both the specialized and
signed write entrances. Ledger browsing may remain public if desired;
submitting a goal always uses the authenticated client boundary.

## Protocol break and deployment

The deployed 0.7.71 protocol uses transaction V7, semantic transaction ID V3,
plan V4, scope wire V3, and DTX V1 records. Signed writes are a separate future
hard break. They are not part of the already-deployed lifecycle-effects break.

Implementation uses one coordinated protocol generation:

- transaction V7 becomes V8 and semantic ID V3 becomes V4; the fixed V8 tuple
  grows from arity 16 to arity 18 and carries both `request_auth` and the
  top-level `auth_transcript`; both fields are covered by the node signature
  and semantic transaction ID, and every decoder accepts that exact arity
  only;
- plan V4 becomes V5 and its core carries `request_binding`;
- DTX Manifest V1 becomes V2, all DTX records and controls become V2, and Begin
  carries the one full `request_auth` plus the one top-level authorization
  entry; the Manifest and plans carry the request digest;
- signed DTX groups permit one participant so a foreign-only write still has
  an authoritative Begin on the origin;
- scope wire V3 becomes V4 and binds the principal plus authentication-context
  digest;
- the origin operation projection and operation outcome reference land in the
  same generation; and
- Explorer JSON exposes the new request and operation fields explicitly.

There is no dual decoder and no compatibility branch for older ledger records.
Enabling signed writes therefore requires a deliberate clean re-found. The
pure request codec, parser, signatures, and read-only ingress may be developed
and reviewed before that deployment break is activated.

Slices 3 through 5 are development stages of this one protocol generation, not
three deployment generations. Slice 3 lands all affected V8/V4, plan V5, DTX
V2, and scope V4 data shapes behind disabled signed-write ingress. Slice 5
completes and activates scope propagation. There is no deployment or re-found
between those slices. After Slice 5 passes its full replay, crash, and
multi-ontology gates, the generation is activated with one clean re-found.

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
- Thread request evidence and `{user, Key}` into `prove_ro`.
- Use the normal top-level ACL and return normal bindings/failure reasons.
- Add per-user and per-peer bounded admission.
- Reject any attempted foreign scope with the bounded
  `signed_scope_unavailable` refusal until Slice 5; V3 must never substitute the
  forwarding node principal for the signed user, even on a read-only proof.

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

Admission is bounded independently per user and peer. Authenticated requests
that introduce new callable vocabulary also use per-user and per-peer symbol
budgets plus a VM-lifetime cumulative ceiling that survives auth-owner
restarts. Paired user/peer charges are all-or-nothing. Existing symbols are
free, ordinary data atoms are not allocated merely because the request
mentioned them, and the shared VM headroom limit remains authoritative. The
exact signed anchor is checked once more inside the proof worker so a re-found
cannot rebind an already-admitted read.

### Slice 3: durable request and operation binding

- Land the coordinated format break described above.
- Verify request evidence independently during proposal validation, ordered
  apply, replay, catch-up, and outcome reconstruction. Re-prove the one origin
  authorization entry through the same ACL checker for both an ordinary
  transaction and a DTX Begin.
- Add the shared origin operation projection for ordinary transactions and DTX
  Begins, with exact first-claim, alias, conflict, pending, and uncertain rules.
- Route a signed foreign-only write through an origin Begin with one DTX
  participant rather than the existing direct foreign ordinary optimization.
- Render user request identity, signature, operation reference, and first
  outcome in Explorer.
- Test two gateways racing the same request; ordinary-versus-Begin races; a
  foreign-only participant; same ID with a different digest; expired retained
  custody; replay at the signed deadline; and crashes before and after every
  origin claim checkpoint.

Because signed user scopes deliberately remain unavailable until Slice 5, the
Slice-3 foreign-only case is fixture-tested by constructing the signed plans
in-VM, as existing DTX tests do. Slice 3 must not make that public path
reachable by weakening `signed_scope_unavailable`.

Public signed writes remain disabled while this slice is independently
reviewed and until the later activation slices pass their replay/crash gates.

### Slice 4: local signed execute and cursor

- Add `execute` and `cursor` endpoints using the existing engine and Explorer
  cursor state machine rather than a second implementation. Refactor that
  state machine into a neutral signed-goal cursor owner; do not retain an
  Explorer-specific coordinator beside it.
- Pass verified goals through the existing `execute_as`/proof boundary without
  adding signing-specific predicate dispatch.
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

Until Slice 5 completes, this development stage permits only proofs whose
material plans all belong to the origin. A signed proof that touches a foreign
scope returns a bounded `signed_scope_unavailable` refusal before durable
handoff; it never falls through to the V3 node-principal behavior. Public signed
write ingress remains disabled in deployed releases throughout this interval.

### Slice 5: activate scopes and multi-ontology goals

- Complete the Slice-3 scope V4 implementation that carries the full principal
  and request digest; do not introduce another wire version or re-found.
- Verify evidence at every remote target and preserve it through nested scopes.
- Bind the identical request digest into every participant plan and Manifest;
  keep the complete request and origin authorization entry once in Begin.
- Test two- and three-ontology user writes, restrictive target ACLs, principal
  substitution, altered request bytes, stripped evidence, route failover,
  coordinator crash, abort, and Complete recovery.

### Slice 6: any-node ingress and client goal builders

- Forward unchanged signed requests from a non-host gateway to an exact target
  validator.
- Add optional client-side builders that produce inspectable goals.
- Prove direct text, received events, menus, forms, scripts, and other inputs all
  converge on byte-identical signed requests and receive identical ACL results.

## Required review questions

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

- Exact parser fixtures cover every V1 operator, comment, escape, integer,
  float, character-code, quoted-atom, list, named-variable, and anonymous-`_`
  rule, including malformed and ambiguous inputs.
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
  different digest cannot reuse an old `{UserKey, OperationId}`.
- A crash after the operation claim is applied but before its outcome row is
  published rebuilds both projections from ledger order and converges on the
  same first outcome.
- Cross-node resolution of `outcome_unknown` requires the existing certified
  current-view threshold and ignores one Byzantine conflicting response.
- Before Slice 5 activation, a signed proof touching a foreign scope receives
  the specified bounded refusal and creates no transaction, Begin, or foreign
  diff.

## Explicit non-goals

- no hard-coded list or classification of predicates;
- no change to any predicate's semantics;
- no second goal executor;
- no server substitution of an opaque menu ID for user-visible intent;
- no client-provided Erlang term or executable callback;
- no session token in durable state;
- no automatic retry based only on a timeout;
- no weakening of existing ACL, proof, OCC, DTX, effect, or resource checks.

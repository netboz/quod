# Durable lifecycle effects

> **Architecture update:** the transaction effect, durable effect journal, and
> post-apply execution described here remain authoritative. The lifecycle-only
> authorization proof, action worker, private principal/effect slots, and
> duplicate checks described below were removed by
> `ontology-lifecycle-single-path-plan.md`. They are historical, not
> compatibility requirements.

**Status:** the base protocol was implemented in Quod 0.7.71. The later
single-path refactor is implemented only in the current working tree and is
not a rolling upgrade. Its next deployment requires the coordinated clean
re-found and private-journal cleanup specified in
`ontology-lifecycle-single-path-plan.md` §2.6; no compatibility decoder is
retained.

## 1. Goal

An authorized external action such as:

```prolog
create_ontology("demo:console", [{terms, [hello(world)]}]).
```

must leave one normal, visible transaction in the controlling ontology's ledger before
the node creates the ontology. The transaction records that the action was
accepted and identifies its exact typed effect. It does **not** assert a
catalogue fact into the root knowledge base.

This distinction is intentional:

- the controlling ledger is the durable history of accepted operations;
- its D projection remains unchanged when an operation has no logical fact to
  add;
- the node-local ontology manager performs the external E operation only after
  the transaction commits.

The design is not specific to creation. `join_ontology/3`, a future ontology
deletion predicate, and other bounded node-local external predicates must use
the same path. Adding one must not require another consensus record type or a
new special branch in `quod_prolog`.

## 2. D, P, and E interpretation

Quod's existing D/P/E split remains unchanged.

- **D** remains the committed Prolog state reconstructed from transaction
  diffs. An effect-only transaction changes no D facts, but its occurrence and
  typed descriptor are still durable consensus history in the ledger.
- **P** is the rebuildable local projection. After ordered apply it validates
  and schedules the transaction's typed effect for the node named as executor.
- **E** is the external operation: start hosting, join, or later stop/delete a
  local ontology.

An empty root diff does not mean “nothing happened.” It means the accepted
operation changed external node state rather than root Prolog state. The
transaction goal, result, actor, and typed effect descriptor remain signed and
durable in the ledger and are rendered by Explorer.

This adds a second source of E work beside `react_on/3`:

1. **reaction effects** are derived from committed D diff operations;
2. **direct effects** are already present as typed descriptors in the
   committed transaction.

Both cross the existing ordered P-before-E barrier. Neither performs IO in the
proof, consensus, or apply process.

## 3. One ordinary transaction, not a new ledger kind

Extend the sealed plan and `#transaction{}` with one bounded canonical
`effects` list. Do not add a lifecycle block, lifecycle consensus lane, root
catalogue table, or compatibility path.

The exact descriptor is the closed tuple:

```erlang
{quod_direct_effect, 1, local_durable, ontology_lifecycle,
 Operation, EffectId, Executor, Actor,
 {Namespace, ExpectedGenesisAnchor}, RequestDigest, PreparedDigest}
```

`Operation` is currently `create | join`; `Actor` is
`{node, PublicKey} | {user, PublicKey}`; every identity/digest is exactly 32
bytes. It is data, not an arbitrary callback, MFA, module name, or Prolog goal.

The descriptor is deliberately small. Creation source, compiled genesis diff,
filesystem paths, seed details, and private manager configuration do not get
copied into the controlling ontology's ledger. The original durable goal already
records the public request. The node-wide prepared-action journal holds the exact opaque payload
and the transaction binds it through `prepared_digest`.

The protocol hard break must cover all of these together:

- plan schema and plan digest;
- transaction schema, semantic transaction id, and author signature;
- canonical encoding and size/count limits;
- ingress, relay, catch-up, replay, and outcome tests;
- Explorer JSON and rendering.

Genesis keeps `effects = []`. An ordinary proof also has `effects = []`.

The signed plan core also carries its sorted live-bridge functor list. Those
markers are not OCC tokens; they document which node-local observations
influenced an effect-only plan and let validators enforce the narrow admission
rule in section 4.1.

## 4. Effect staging uses the ordinary proof boundary

A `staging` external predicate may prepare data for an effect, but never
performs the external operation while Prolog is running. It uses the same
governed-predicate dispatcher and the same proof overlay as staged D changes;
there is no effect predicate class or lifecycle executor.

The generic flow is:

```text
execute(Goal)
  -> ordinary can_invoke/4 entry
  -> shared action/3 relation and ordinary prerequisites
  -> exact internal staging continuation
  -> validate and stage one typed effect in the proof overlay
  -> seal and submit the ordinary controlling-ontology transaction
  -> ordered apply and P-before-E handoff
  -> node-wide journal executes the prepared local effect
  -> journal verifies the real DesiredState and releases the reply
```

The overlay owns the staged effect list just as it owns staged D operations.
Checkpoint, restore, failed alternatives, cancellation, and scope sealing
restore both together. A failed action candidate therefore leaves neither a D
write nor an effect descriptor behind.

The action itself is not read-only: its normal Prolog transition may stage D.
For a direct external effect, the exact internal continuation adds the prepared
effect to the same immutable overlay revision. The action postcondition may
recognize that exact staged promise; the journal must still verify real node
state after execution. The promise is not a side channel and disappears when
the candidate or savepoint is restored.

`quod_dtx:participates/1` is true when a sealed plan contains a D diff, an OCC
read check, or a direct effect. An effect-only action therefore produces a
normal transaction even when its controlling ontology diff is empty.

### 4.1 Committed reads and local observations are different

An action proof can consult two kinds of information:

- committed root clauses, such as `action/3`, `can_create_ontology/3`, and
  `peer_admitted/4`;
- node-local bridge results, such as `ontology_join_state/2` and
  `ontology_genesis_anchor/2`.

Only the first kind enters the transaction's OCC `read_check`. The existing
overlay already separates real read tokens from `'$quod_live_bridge'` markers;
this slice must not collapse them back into one map.

There is no lifecycle policy sub-proof or absorb-back step. The normal proof
selects the action declaration, checks `can_invoke/4` and the action
prerequisites, and records both dependency kinds in its one rollback-safe
overlay. Consequently every committed predicate read by declaration selection,
authorization, and policy becomes an exact controlling-ontology OCC
dependency, while every bridge observation remains a separately typed live
marker. `quod_proof_session:read_set/1` excludes those markers and
`live_bridges/1` returns them for the signed plan core.

`quod_dtx:seal_admissible` gains one deliberately narrow rule:

- a plan with a D diff and a live bridge remains forbidden, except for the
  existing separately reviewed membership exception;
- a plan with exactly one valid direct effect and no D diff may seal after
  consulting query bridges, because those observations govern only local E on
  the named executor;
- a plan with neither condition does not gain any new permission.

Validators check the signed bridge list, empty diff, one-effect bound, known
descriptor, and executor/author binding. They do not pretend to reproduce
another node's manager state.

The local `not_hosted` check is therefore not network consensus. A concurrent
local start is closed by the prepared-action journal and the serialized
`quod_namespace_manager` operation. Its exact `already_configured` result is
recorded as the local execution outcome; it is never converted into an OCC
token or compared with another validator's local state.

### 4.2 Direct effects are excluded from DTX groups

The first slice permits a direct effect only when its plan is the sole material
participant and therefore uses the ordinary transaction path.

If two or more scopes participate, the origin rejects the submission before it
constructs a DTX Begin. Independently, manifest construction, plan
attestation, `plan_matches_manifest`, Prepare validation, replay, and catch-up
reject an effect-bearing participant. This is a hard protocol rule, not merely
an origin-side convenience.

The public bounded failure is `effect_requires_single_participant`. A
lifecycle action whose `::` work makes another ontology material returns that
reason before Begin; it must not surface as an internal DTX codec or reducer
error.

Atomic effects spanning several ontologies are undefined in this slice. They
must receive a separate design covering preparation ownership, abort, and
post-Complete execution before this exclusion can ever be removed.

## 5. Authorization remains Prolog policy

This slice adds no new permission system.

The ordinary `can_invoke/4` entry and the action prerequisites are the only
authority: root's `can_create_ontology/3` governs creation of a new identity,
while node's `can_join_ontology/4` governs local hosting of an existing one. A
future delete predicate must add its policy clause and action declaration in
its chosen controlling ontology. The external effect machinery does not grant
permission merely because it recognizes an operation.

The engine-owned authenticated principal remains private proof state. It is
bound into the sealed plan, durable transaction, and effect descriptor; a
browser cannot provide or replace it.

The implementation must preserve the existing defense in depth:

- authorization before reading caller-selected source files;
- exact action declaration and prerequisite proof in the same pinned view;
- executor equals the node that prepared and authors the local effect;
- a node never executes another node's local lifecycle effect.

There is no ACL re-proof after the transaction commits. Its absorbed policy
read set already makes a concurrent committed revocation reject through OCC.
Once applied, the effect is a committed local obligation; evaluating a newer
policy view at E time could strand it and would make replay nondeterministic.
The E handler rechecks only descriptor/journal identity, executor ownership,
and the operation's current idempotent postcondition.

A validator admits only canonical, bounded, known effect descriptors with a
valid executor/author binding. It never runs the effect while validating a
proposal.

### 5.1 What consensus does and does not prove

For this ordinary single-participant transaction, the committee proves that a
currently admitted node authored the exact transaction bytes and that the
typed effect is canonical, bounded, local, and names that same node as
executor. The committee does **not** re-run the node's lifecycle ACL proof.

The durable record therefore means:

> this admitted executor node claims that it authenticated and authorized this
> exact local action.

It does not mean that the committee independently proved the business policy.
That limitation is safe for the present host-local operation: a malicious node
can already create, join, stop, or erase data on its own storage. The record
does not let it make an honest peer execute the operation.

It is nevertheless a real product boundary:

- Explorer labels `actor` as **claimed by the author node**, not
  committee-verified;
- a node-authored action remains an author-node claim, while a signed client
  action carries its exact `{user, PublicKey}` principal and request evidence
  in the transaction for independent validation by every committee member;
- quotas, payment, or network-wide creation rights must not treat the effect
  descriptor as proof of compliance;
- policy involving delegated agents or capabilities still requires the
  separately planned immutable subject chain and wielding checks; it must not
  be inferred from the base user signature or another effect field.

## 6. Exact preparation and transaction hand-off

### 6.1 Preparation

Preparation stays side-effect-free with respect to hosting state. It may read
and compile requested source, but it must not create directories, start
supervisors, or open network work.

For creation, preparation must reserve every byte that contributes to genesis
and compute the exact expected genesis anchor before submission. The private
prepared value freezes:

- the canonical namespace;
- the random consensus incarnation;
- the exact compiled and ordered initial diff;
- the generated host-entry policy;
- the complete founding committee facts, including each founder key and
  advertised host/port;
- the unsigned genesis transaction defaults;
- slot/index 1 and the genesis block timestamp, which is fixed to zero rather
  than sampled later.

The live genesis constructor and preview must share one pure builder. Execution
consumes those frozen values; it does not reread `node_addr` or rebuild the
founder fact from current configuration. A mismatch with the committed expected
anchor fails closed. A later address change is normal routing state and must not
rewrite the already-founded identity.

For join, the request already carries the exact anchor. Seeds remain routing
hints and are included only in the private prepared payload and its digest.

Preparation returns:

```text
PublicDescriptor  -- bounded data committed in the controlling transaction
PrivatePrepared   -- exact local payload needed by the manager
```

The canonical digest of `PrivatePrepared` is in `PublicDescriptor`.

### 6.2 Local prepared-action journal and capacity

Source reading and preparation occur only after the ordinary Prolog
prerequisites succeed. Their payload remains rollback-safe proof state while
the plan is being derived and sealed; an abandoned branch or worker cannot
leave a durable row.

After the plan is sealed and its exact unsigned semantic transaction is built,
the proof owner reserves the one node-wide journal and datasyncs one bounded
local row before checkpoint or submission. Every failed hand-off releases its
reservation. The effective node-wide custody capacity is ordinary committed
root policy: `effect_custody_capacity/1` defaults to 64, a single
`effect_custody_capacity_override/1` assertion replaces that default, and
`set_effect_custody_capacity/1` performs the replacement atomically. Any
non-negative integer or `unlimited` is valid; there is no compiled maximum.
Root is the one ontology every node starts before it can create or join the
remaining system ontologies, avoiding a circular bootstrap dependency. Its
founding `state_handler/4` projects that fact through the existing P tier into
the journal, and a full configured capacity is a loud `busy` refusal.
Per-effect descriptor and byte bounds remain protocol validation; ingress rate
limits remain a separate concern.

The row contains:

```text
EffectId
PublicDescriptor
PrivatePrepared
TransactionRef
SealedPlan and exact durable goal/result
state = bound | prepared | handed_off | committed | applied | retired
```

The journal is local execution custody, not ontology D and not a second
authority database. Its cached capacity is a projection of root D; it
exists solely to preserve the private
prepared payload and complete an already-authorized local effect across worker
or node restart. It must use a versioned, checksummed format with bounded rows,
exact idempotence, conflict rejection, atomic compaction, and the same
fail-loud durability discipline as Quod's signing journal. The row count is
the committed policy above; `unlimited` deliberately imposes no count bound.

The exact `TransactionRef` is checkpointed before submission. From then on an
engine crash or timeout returns `{outcome_unknown, TransactionRef}`; it never
prepares a new effect or re-proves the request automatically.

### 6.3 Signed-submission custody

The local effect journal owns preparation, but Simplex must durably own every
signed byte it exposes. Extend the existing signing journal with a
pending-effect-transaction table keyed by `TxId`. Its population is already
governed by the one node-wide custody reservation; the signing journal does not
apply a duplicate effect-specific count. One row contains:

```text
continuous AuthorAdmission
Author and AuthorSequence
TxId and exact unsigned semantic body
exact signed submission envelope
```

Hand-off is one correlated idempotent operation:

1. the ordinary proof worker passes the exact journaled semantic transaction to its
   local Simplex;
2. Simplex returns an existing matching custody row or allocates/signs a new
   author sequence;
3. Simplex appends and datasyncs the exact signed envelope in its signing
journal before acknowledging the proof worker or exposing the bytes;
4. the action journal records `handed_off` after that acknowledgement.

If Simplex persists the row and crashes before acknowledging, retrying the
hand-off returns the same custody row. If the proof worker crashes before it
ever calls Simplex, restart retries the exact sealed semantic transaction from
its journal. This is not a re-proof and cannot change the effect, goal, result,
plan digest, transaction id, or private prepared payload.

Simplex redrives the exact signed bytes while they remain unresolved. Retained
signed custody drains before unsigned ingress and is globally ordered by
`AuthorSequence`, so a later local sequence cannot overtake this effect and
make its envelope stale. Recovery therefore never re-signs an effect: an exact
retry returns the same journaled envelope, while any different envelope for the
same `TxId` is an anti-equivocation conflict.

An author removal/re-admission is not the same continuous authority. Recovery
first checks deterministic ledger history for the `TxId`; if it did not commit,
the old-admission row retires visibly and is never re-signed under the new
admission or re-authorized automatically.

### 6.4 Commit and execution

Only a committed transaction releases its effect. A rejected transaction
retires the prepared journal row without external IO.

Ordered controlling-ontology apply publishes an `applied_live` envelope even when `diff = []`
if `effects` is non-empty. The envelope carries the already-decoded bounded
effect descriptor, not an executable goal. `quod_runtime` first completes P
through that height, then hands the descriptor to the closed effect registry.

The lifecycle handler matches the descriptor to the exact local journal row,
verifies both digests and the executor key, and calls
`quod_ontology:execute_prepared/1`. A ledger record without the matching local
journal row is visible for audit but cannot make an honest node execute local
IO.

After execution, the handler verifies the declared desired state and exact
anchor, marks the row applied, and releases the original caller. The success
result includes the ordinary controlling transaction reference/height. The new
ontology separately has its own slot-1 genesis transaction.

## 7. Crash, retry, and replay rules

Lifecycle handlers must be idempotent and state-verifying. A crash may repeat a
local call, but must not create a second logical ontology or erase a different
incarnation.

Recovery follows the exact transaction reference:

- **prepared but not handed off:** repeat only the idempotent Simplex custody
  hand-off using the exact sealed semantic bytes;
- **handed off and pending:** Simplex redrives the exact journaled envelope;
  the ordered custody lane prevents a later local sequence overtaking it, and
  the proof owner never resubmits a newly built transaction;
- **not found while durable Simplex custody exists:** keep custody and retry;
- **not found with neither valid custody nor the original continuous
  admission:** retire visibly; never re-prove;
- **rejected:** retire it and perform no effect;
- **committed, ordered P projection not yet through that height:** keep the
  handed-off row and wait; the outcome alone does not bypass P-before-E;
- **committed, ordered P projection complete, local state absent:** run the
  exact prepared effect;
- **committed, exact desired state already present:** mark applied;
- **committed, incompatible local state:** fail closed and expose an operator
  error; never overwrite it.

`committed` is not automatically `applied`: an ordinary transaction can be
OCC-rejected when its ledger slot is applied. Recovery obtains the verdict by
the same deterministic ordered replay that rebuilds the outcome projection,
including the read-check at that historical entry. The Prolog owner refuses
outcome reads while rebuilding; before it becomes ready, replay from slot 1
has recreated every ordinary terminal outcome in a reset or missing index.
The effect journal therefore retries through rebuild and reads the complete
projection afterward; it does not depend on an old DETS row surviving.
For a handed-off row, a committed outcome becomes an executable journal row
only after `quod_runtime`'s existing `e_frontier` covers the transaction
height. Live apply and restart recovery therefore cross the same P-before-E
barrier. A row already persisted as `committed` is itself the durable record
that this release happened before the crash.

Historical ledger replay never blindly re-executes all effects. The local
journal and an incremental applied-effect frontier identify unfinished local
work. If that projection is rebuilt, deterministic replay first classifies
each effect transaction as applied or OCC-rejected. It then schedules only
applied descriptors whose executor is this node and whose exact local journal
payload still exists, in bounded chunks.

Loss of the node's storage loses its prepared payload and hosted ontology
together. The durable controlling-ledger record remains an audit fact, but another node does
not recreate the ontology automatically. Hosting elsewhere remains an explicit
authorized join action.

### 7.1 Concurrent creation and ontology identity

This design intentionally does not turn a namespace string into a globally
unique allocation. Quod's ontology identity is `{Namespace, GenesisAnchor}`.

Two nodes can concurrently commit accepted creation effects for the same name
and then found two different anchors. Both controlling-ledger records are honest
records of separate node-local operations; neither gives one fork authority
over the other. This is possible today and the durable record makes it visible
rather than silently resolving it.

The system must handle the conflict explicitly:

- clients persist the exact anchor of the home/ontology they created;
- a later host uses `join_ontology(Name, Anchor, Seeds)`, not another create;
- directory resolution for one name with competing anchors fails closed and
  never chooses or merges one implicitly;
- Explorer shows the full namespace-plus-anchor identity and warns about the
  name conflict.

For a user home, simultaneous first registration on two nodes can therefore
create two incarnations bearing the same deterministic `user:<key>` name. This
slice accepts that consequence rather than adding the forbidden global
per-user root catalogue. If a product later requires globally unique names, it
needs a separately reviewed allocation policy or registry and must account for
its state growth honestly.

## 8. Future deletion and other predicates

The implementation routes both `create_ontology/2` and `join_ontology/3`
through the shared mechanism.

A future deletion predicate must use the same transaction/effect path:

1. authorize and prepare an exact target identity;
2. commit the controlling ontology transaction containing the deletion effect descriptor;
3. only then perform the local deletion;
4. recover or verify it by the same `EffectId` after a crash.

The deletion specification must distinguish stopping local hosting from
irreversibly erasing local ledger data. That choice belongs to the predicate
and its ACL, not to the generic effect runner. Both operations must be recorded
before execution if they are added.

New effect predicates are accepted only when they satisfy the same contract:

- fixed typed schema and fixed internal handler;
- bounded canonical data;
- one explicit executor;
- idempotent execution or exact deduplication;
- observable postcondition;
- safe recovery from an exact transaction reference.

Arbitrary network delivery, e-mail, payment, or third-party API calls do not
automatically qualify. Operations needing durable remote acknowledgement use
the durable D outbox architecture in `minimal-agent-delivery-plan.md`.

## 9. Explorer

Explorer must make the distinction visible without implying a root KB write.

For an effect-only transaction it shows:

- normal transaction id, root height, author, actor, goal, and result;
- `diff: []` / “no root facts changed”;
- each typed effect's operation, executor, target identity, and `EffectId`;
- local execution state when the viewed node is the executor:
  `pending`, `applied`, or `operator_error`.

Execution state is explicitly local and is not presented as consensus truth.
The committed descriptor bytes and admitted node author are consensus truth.
For a node-authored action, the displayed actor and “authorized” claim remain
explicitly labelled **author-node claimed**. For a signed client action,
Explorer separately renders the verified user request and the validator-node
signature; it must not present either one as an agent delegation or capability
that the request did not contain.

The namespace list also needs the already-planned local topology notification:
`quod_namespace_manager` publishes a namespace change after start/stop, the
Explorer WebSocket receives it through one node-wide subscription, immediately
subscribes to the new namespace's runtime/consensus topics (or unsubscribes the
removed namespace), and emits its existing `sync` invalidation. The browser
then refreshes `/api/summary`. Merely invalidating the list without updating
the server-side topic subscriptions is insufficient: the new namespace must
stream blocks and status on the already-open socket. A full page reload must
not be required after creation or a future deletion.

## 10. Implementation and release order

This slice changes the plan schema, transaction schema, semantic id, signature
bytes, and founding transaction defaults. It therefore requires one clean
protocol break and re-found; it must not be rolled onto an existing ledger.

Do not spend several re-founds on adjacent pending work. Before coding, audit
the approved agent-delivery work and any other already-approved plan/transaction
schema changes. Land compatible schema changes in the same release, then:

1. complete and review the signed client-goal generation described in
   `signed-client-goals-plan.md` (implemented in the working tree);
2. run the coordinated protocol and release gates;
3. found the network once from the current root source, including root's
   generic creation policy and its signed `create_user_home` convenience rule;
4. never apply a separate temporary live root-policy migration immediately
   before that planned re-found.

There is no compatibility decoder and no mixed-version committee. The release
and deployment plan must explicitly name the re-found before implementation is
called deployable.

The implementation landed in this order:

1. Add the canonical effect schema and limits to proof session, sealed plan,
   transaction identity/signature, codecs, and validators.
2. Make savepoints and scope hand-off carry staged effects exactly like staged
   D operations; make effect-only plans material.
3. Refactor the lifecycle external predicates to prepare and stage descriptors
   instead of executing IO; make top-level effect routing class-driven.
4. Add the node-wide prepared-action journal and exact OutcomeRef hand-off.
5. Emit effect-bearing apply envelopes for empty-diff transactions and add the
   one direct-effect path behind the existing P-before-E barrier.
6. Migrate create and join to the common handler; delete the old
   execute-directly-after-read-only-proof path rather than retaining two modes.
7. Render effect transactions and add dynamic namespace-list updates in
   Explorer.
8. Run the complete crash, replay, catch-up, authorization, and protocol gates
   before deployment, including after any later single-path refactor. The
   incompatible format still requires the single clean re-found stated above.

No compatibility decoder or dual lifecycle executor remains after this hard
break.

The same implementation delta updated every document and source contract that
previously described direct IO after a read-only lifecycle proof or said that
`applied_live` exists only for transactions changing D. The mandatory sweep
includes:

- `doc/ontology-lifecycle-authorization-plan.md` §3.3;
- `doc/ontology-creation-input-plan.md`;
- `doc/ontology-creation-plan.md`;
- `doc/ontology-join-plan.md`;
- `doc/agent-fipa-plan.md` actions/apply sections;
- `doc/minimal-agent-delivery-plan.md` §3.1 and its D/P/E contracts;
- `doc/client-authentication-plan.md` actor-verification caveat;
- `src/quod_prolog.erl` apply/runtime moduledoc and comments;
- `src/quod_predicates.erl`, `src/quod_runtime.erl`, Explorer documentation,
  and release/deployment notes.

Historical text may remain only when it is explicitly labelled as removed
behavior. A final repository-wide stale-contract search is a release gate.

### 10.1 Exact source seams

The implementation review must account for at least these concrete seams:

- `include/quod_ledger.hrl`: add `effects = []` to `#transaction{}` and its
  type contract.
- `quod_transaction`: bump both wire and semantic-id versions; include effects
  in semantic ids, signatures, durable submission material, and decoding. The
  fixed ETF tuple-arity prefix in `decode_verified_submission/2` must change
  with the signed tuple rather than silently rejecting every new envelope.
- `quod_erlog_db_local_prove` and `quod_proof_session`: store staged effects in
  the immutable overlay revision, not session side state, so Erlog
  `transaction/1`, savepoints, restore, and failed alternatives roll them back
  automatically. Add the sibling accessor beside `local_changes/1` and
  `read_set/1`, plus the explicit live-bridge dependency absorption seam from
  section 4.1.
- `quod_dtx`: plan version/core/material/counts, effect/bridge blobs,
  `participates/1`, the effect-only live-bridge rule, and hard rejection from
  manifests/attestations/group validation.
- `quod_prolog`: the ordinary execute worker stages, seals, submits, checkpoints
  the exact outcome, and releases its waiter only after E; `applied_live` is
  emitted for non-empty effects even when the diff is empty.
- `quod_predicates`, `quod_ontology_predicates`, and the common action relation:
  one staging-class bridge, an opaque proof-local continuation, typed
  descriptor staging, and no lifecycle IO from Erlog.
- `quod_ontology` and `quod_simplex`: factor one pure genesis builder and
  consume frozen creation inputs; add pending effect-transaction custody to
  the existing signing-journal owner.
- `quod_simplex`, ingress, relay, ledger verification, catch-up, feed, outcome,
  metrics, and schema reflection: validate and preserve the new field and
  empty-diff materiality everywhere.
- the one node-wide prepared-action journal owner and `quod_runtime`: reconcile exact
  committed/rejected outcomes and admit direct descriptors only after the
  existing `e_frontier` barrier.
- `quod_namespace_manager`, `quod_explorer`, `quod_explorer_http`, and
  `quod_explorer_ws`: topology publication, subscription refresh, effect
  details, local status, and authorship labels.
- `quod_directory`, `quod_directory_control`, their route/anchor allowlists,
  and directory predicates: preserve distinct `{Namespace, Anchor}` identities
  and return one explicit fail-closed conflict when the same name has competing
  anchors; never pick or merge one.

## 11. Required tests

### Protocol and validation

1. An effect-only plan participates and yields one normal transaction with an
   empty diff.
2. Effect bytes are included in the plan digest, semantic transaction id,
   author signature, block hash, relay, and catch-up verification.
3. Unknown handler/version/operation, unbound or noncanonical fields,
   executor/author mismatch, a duplicate `EffectId` inside one transaction,
   excessive count, and oversized descriptors are rejected before consensus
   support.
4. Genesis and ordinary transactions retain empty effects.
5. An effect-bearing plan is rejected both when the origin attempts to build a
   DTX group and when a target validator receives a forged effect-bearing DTX
   participant/manifest.
6. An effect-only plan that consulted a local bridge seals with only committed
   policy/declaration reads in `read_check`, with the bridge list separately
   signed; the same bridge plus a D diff is rejected.

### Action semantics and authorization

7. Create and join use the same external-predicate staging primitive and the
   same Prolog ACL path.
8. Unauthorized, undeclared, malformed, observer-owned, or failed action
   candidates produce neither transaction nor journal row nor IO.
9. Savepoint/restore, failed alternatives, worker cancellation, and scope
   teardown remove staged effects exactly as they remove staged D changes.
10. A future test-only second lifecycle operation uses the same ordinary
    action/staging path without a new `quod_prolog` operation branch.
11. Journal capacity and total-byte exhaustion refuse after sealing but before
    checkpoint/submission, and recover their reservations after failed
    hand-off.

### Durability and recovery

12. Crash before journal binding performs no submission or effect.
13. Crash after the `bound` row datasync but before checkpoint activation
    retires that row as `not_activated`; losing its monitored Prolog owner can
    never leave it occupying custody or make it executable.
14. Crash after activation but before Simplex hand-off retries the exact sealed
    semantic bytes and completes.
15. Crash after signing-journal datasync but before hand-off acknowledgement
    recovers the exact signed envelope; a later local author sequence remains
    behind it and cannot make it stale.
16. Attempt a different envelope for the same effect `TxId`: signing custody
    rejects it without changing the durable journal.
17. Crash after OutcomeRef checkpoint, after commit but before E, during E,
    and after E but before journal completion never duplicates the logical
    operation.
18. A rejected transaction never executes its effect; an uncertain submission
    is resolved and never re-proved.
19. Recovery with an empty outcome index deterministically classifies an
    OCC-rejected effect transaction and retires it without IO.
20. A forged committed descriptor with no matching local prepared row performs
    no IO.
21. Creation preview and actual genesis produce the same exact anchor; a
    mismatch fails closed.
22. Changing the advertised address after preparation does not alter the
    frozen founder fact or computed anchor; tampering with a frozen input
    produces an anchor mismatch and no start.
23. Sequential creation of many user homes adds ledger entries but no per-home
    root Prolog facts.
24. Two nodes concurrently create the same name: both receipts remain visible,
    the anchors remain distinct, directory resolution reports the conflict,
    and neither fork is silently selected or merged.
25. A directory-level test supplies competing anchors for one namespace and
    asserts the exact fail-closed conflict from resolution, control, and the
    rendered route allowlist; input order cannot select a winner.

### Apply, runtime, and Explorer

26. Empty-diff committed effects emit one live apply envelope; replay does not
    blindly execute them.
27. P completes through height H before E for H begins.
28. Effect queue overflow/restart is repaired from the journal/frontier and
    cannot strand committed work.
29. Explorer renders the controlling transaction as an effect with no D change,
    labels the actor author-node-claimed rather than committee-verified, and
    refreshes the namespace list without a page reload.
30. A namespace created while an Explorer socket is already open begins
    streaming blocks/status on that same socket.
31. A future deletion fixture proves that the ledger entry commits before the
    destructive handler is allowed to run.

## 12. Non-goals

- no root fact per created, joined, or deleted ontology;
- no global ontology catalogue;
- no automatic replication or hosting transfer;
- no implementation of deletion in this slice;
- no arbitrary Prolog goal, callback, or MFA in an effect descriptor;
- no generic replacement for the durable outbox protocol;
- no deployment until this plan is reviewed and its implementation passes the
  stated gates.

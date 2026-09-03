# Automatic ontology-route recovery — implementation plan

**Status: Slices 1–4 implemented and reviewed.**
The byte-canonical correction R1–R4 is implemented and reviewed.
Signed and hashed artifacts now persist and
travel as the exact canonical bytes produced once at their owning constructor:
transaction blobs form block payloads, block bytes form the consensus identity,
and canonical entry envelopes carry those bytes plus finality evidence. Decoded
records are local views, never a second identity. This is a ledger and wire
format break folded into the coordinated Slice-6 clean re-found; there is no old
decoder or compatibility path. The source identifiers are transaction V13,
ledger-frame V5, canonical block/entry V1, and DTX-endpoint V9. R3 keeps
foreign application symbols opaque through catch-up, disk cache, projection,
and certified-current reads; it also replaces fleet-local catch-up request
references with binary ids. R4 proves that the plain-read committee filter
uses that opaque certified view: observers and lying advertisers cannot answer,
and resolution continues to an honest current validator without allocating
the target ontology's vocabulary.
Versions 0.7.129 and later in this development arc must not be deployed to the
existing fleet before the coordinated Slice-6 clean re-found: its immutable
root ledger contains `create_ontology/2`, while this cut deliberately replaces
that contract with `create_ontology/3` and provides no compatibility path.
This plan is the implementation boundary for replacing
operator-listed routes and node-local hosting intent with one fact-driven
recovery path. Slice 1 may start only from this reviewed revision.

## 1. Problem

`quod_directory` is correctly soft state: its ETS indexes contain current
network observations and are rebuilt after a process or node restart. The
authority which decides what a node may advertise is not reconstructible,
however. It is currently split between:

- deployment `directory_public_namespaces` allowlists;
- `quod_namespace_desired_store`, which persists dynamic hosting intent in a
  node-local file; and
- the namespaces which happen to be running under `quod_ns_sup`.

A runtime-created ontology is not automatically added to another node's
deployment configuration. After restart its ledger may still exist, but its
host cannot re-advertise it unless an operator had listed that exact namespace
and node key. The N=4 benchmark avoided the defect by pre-listing its fixture
ontologies. That is not automatic recovery.

The split also gives three answers to one question: what should this node host?
The replacement has one durable answer and one projection:

```prolog
hosts_ontology(NodeRef, Namespace, GenesisAnchor, Visibility).
```

The fact is committed in the physical node's dedicated actor ontology. The
existing runtime and namespace manager make local reality agree with it. The
directory observes the resulting live host and remains disposable soft state.
`Visibility` is `discoverable` or `private`; private hosting remains durable
without publishing the target identity to the network.

## 2. Fixed decisions

1. **Prolog facts own desired hosting.** No Erlang table, local checkpoint, or
   deployment namespace list is a second authority.
2. **The directory remains P.** Endpoint, reachability, role observation,
   lease, sequence, and route rows are never ledger facts.
3. **Agents feed the directory declaratively.** An agent commits hosting and
   private-contact truth. It cannot call an API which inserts a route row
   directly.
4. **One projection path.** `state_handler/4` projects the node ontology's
   current hosting facts into the existing `quod_namespace_manager`; the
   manager is still the sole desired-state and supervisor-mutation owner.
5. **One route owner.** `quod_directory` remains the only live route-index
   writer. `quod_directory_control` remains the signed dissemination owner.
6. **Discoverable hosting facts permit publication; routes do not authorize
   use.** An ordinary advertisement is installed only after the existing
   certified foreign-history owner confirms the author's active node-agent
   key and exact `hosts_ontology/4` rows. The resulting row is only a
   reachability hint. At selection, the existing consumer's certified target
   current view must confirm the answering key's current role; target history,
   committee, TLS key, and target `can_invoke/4` remain the authority to write
   or certify a read.
7. **Exact route discovery and service discovery remain distinct.** This work
   maps an already-known `{Namespace, GenesisAnchor}` to current hosts. A
   future DF maps an application/service name to an exact identity. It is not
   a route store and is outside this plan.
8. **No progress polling.** Missing routes park work on the existing exact
   `{directory_route, Identity}` property. A route installation or link/resync
   event wakes it. A deadline may end an unanswered operation, but no retry
   delay discovers progress.
9. **No compatibility path.** The local checkpoint authority, generic
   allowlist, direct-route insertion API, old directory wire form, and old
   lifecycle API shapes are deleted in the same coordinated cut.
10. **No population limit is introduced or preserved as hosting policy.**
    Namespace and frame byte validation remains. A node's committed number of
    hosting facts is not capped by a compile-time directory constant.
11. **Private identities stay private.** A `private` hosting row is never sent
    in a network generation. Exact private reachability comes from a committed
    `knows_ontology_host/4` row in the caller node actor and is projected into
    the same local directory as a private route. It contains a node reference,
    never an endpoint.
12. **Plain remote reads remain explicitly single-host reads in this cut.** A
    fact-backed route may serve such a read only when certified target history
    proves the answering key is a current target validator. This authenticates
    the current replica but does not make one answer Byzantine-certified. A
    durable write still uses consensus, and an L1 read dependency still uses
    the existing f+1 read certificate. A future f+1 answer/transcript contract
    is separate work; route recovery must neither claim nor simulate it.

## 3. Terms and owner boundaries

| term | meaning | owner |
|---|---|---|
| node actor ontology | the dedicated ordinary ontology containing this physical node's `instance_of(node, Instance)` and active key | its own consensus ledger |
| node reference | `agent_instance_ref(NodeNamespace, NodeAnchor, NodeInstance)` | certified node-ontology history |
| hosting fact | `hosts_ontology(NodeRef, Namespace, Anchor, discoverable \| private)` | the node actor ontology |
| private-contact fact | `knows_ontology_host(NodeRef, TargetNamespace, TargetAnchor, HostNodeRef)` | the caller physical node's actor ontology |
| system catalogue row | `system_ontology(Namespace, Anchor)`; means every node must recover that shared system ontology | root ledger |
| desired-host projection | exact current set derived from root catalogue plus the local node actor's hosting facts | `quod_namespace_manager` P state |
| live host observation | exact identity and current local validator/observer role after the namespace is ready | existing namespace/Simplex processes |
| advertisement | node-agent-signed current live-host observation, bound to its exact `NodeRef` | `quod_directory_control` P state |
| route | received live `{identity, node key, endpoint, role, lease}` hint | `quod_directory` ETS P state |
| service registration | future semantic name to exact ontology identity | future DF; not this plan |

`hosts_ontology/4` deliberately names an exact ontology identity and no
endpoint, seed, connection, lease, process id, or role. The current role comes
from the hosted ontology itself. A node-key rotation does not rewrite the
hosting facts because `NodeRef`, not its active key, is the subject.

`knows_ontology_host/4` is the durable replacement for a configured private
direct seed. It says that this node may try one exact host actor as a contact
for one exact private ontology. The host actor's current endpoint is resolved
from its own discoverable node-actor identity; the target history is then
verified through the existing request-scoped bootstrap-candidate seam. The
fact grants no target authority and creates no globally visible target row.

## 4. Durable facts and authorization

### 4.1 Shared system ontologies

No new system-host fact is needed. The existing root fact

```prolog
system_ontology(Namespace, GenesisAnchor).
```

already means that every node starts or joins that exact shared system
ontology. It is the committed desired-host authority for the system tier. It
contains no endpoint. Root itself remains the sole configured bootstrap
exception and is not a catalogue row.

### 4.2 Ordinary dynamic ontologies

The dedicated node actor ontology owns:

```prolog
hosts_ontology(NodeRef, Namespace, GenesisAnchor, Visibility).
knows_ontology_host(NodeRef, TargetNamespace, TargetAnchor, HostNodeRef).
```

The default policy permits the exact active node actor represented by
`NodeRef` to add or remove its own rows. `Visibility` must be exactly
`discoverable` or `private`. The same subject restriction applies to
`knows_ontology_host/4`. Neither fact infers ownership of, membership in, or
permission from the target ontology. A later authorized agent may manage the
rows only by an ordinary ACL grant in that node ontology. There is no
Erlang-side delegation list.

The active `agent_key/3` in this exact ontology also authenticates the node's
ordinary directory generations. Receipt uses the existing certified foreign
projection to check that key and the carried discoverable host rows. It does
not run a second Prolog proof or add a directory ACL.

The assertion and retraction use the normal signed goal, `can_invoke/4`,
Prolog action/prerequisite, transaction, consensus, and outcome path. A
convenience rule may compose creation or joining with the assertion, but it is
Prolog and creates no server command:

```prolog
host_ontology(NodeRef, Namespace, Anchor) :-
    current_principal(NodeRef),
    can_host_ontology(NodeRef, Namespace, Anchor),
    assertz(hosts_ontology(NodeRef, Namespace, Anchor, private)).
```

This is illustrative policy, not a hard-coded grant. Retraction is governed by
the same ontology's normal ACL and policy. If the node is still a validator,
the ordinary unhost action must first remove that validator through the
target's existing membership predicate; reconciliation never silently stops a
validator which the target committee still requires.

Private is the conservative default in the illustrative helper. Publishing is
an explicit change to the same hosting row, subject to the same ontology's
policy. A node actor which wants a private target records the exact host actor
with `knows_ontology_host/4`; the founding handler projects that relation into
the local directory's private class. The directory resolves the host actor's
current authenticated contact and offers it to the existing target verifier.
It never publishes or enumerates the private target identity.

### 4.3 Creation and joining

Root continues to own creation. `quod:node` continues to own the existing join
policy. No lifecycle predicate moves into the directory.

Persistent hosting is composed with those actions rather than hidden inside
them:

- creation exposes its already-prepared exact genesis anchor to the Prolog
  continuation; the `/2` shape is replaced by one `create_ontology/3` shape
  which binds `Anchor`;
- a caller authorized by both ontologies may run the root creation and assert
  the node's hosting fact in the same ordinary multi-ontology goal;
- joining already receives the exact anchor, so the same composition applies;
- the existing one-time create/join direct effect and the persistent hosting
  projection have different jobs: the effect performs the accepted lifecycle
  operation once, while the fact reconstructs desired hosting after every
  restart.

The group-effect path already supports an effect-only plan beside another
ontology's fact-changing plan. No new transaction or effect mechanism is
needed. A bare creation without a committed hosting row may finish its one-time
effect, but it is intentionally not durable node hosting and is not
advertised. Client and test helpers which promise persistent creation must use
the composed goal.

## 5. Bootstrap without a circular route

The exact order is:

1. **Root.** The configured root block starts first through the existing
   bootstrap path. Its configured contacts and exact root node-key set are the
   only directory configuration left.
2. **Shared system ontologies.** The namespace manager reads root's committed
   `system_ontology/2` catalogue. A locally retained exact ledger resumes
   without a route. If a local copy is absent, the manager parks the exact join
   on `{directory_route, {Namespace, Anchor}}`; another live holder's signed
   advertisement wakes it.
3. **The local node actor ontology.** Its one exact local bootstrap pointer
   `{NodeNamespace, NodeAnchor, NodeInstance}` is loaded from the node identity
   directory beside `node.key` and the existing directory epoch, never from
   the desired-state store which this plan deletes. It is verified against
   that ontology's certified history. On a normal restart its ledger is local,
   so reading its hosting facts needs no directory route. The pointer is
   neither hosting authority nor a general restart catalogue. The node actor's
   own discoverable hosting row makes its exact actor identity routable after
   this local bootstrap; it does not participate in bootstrapping itself.
4. **Ordinary dynamic ontologies.** The node actor's founding
   `state_handler/4` projects its committed `hosts_ontology/4` and
   `knows_ontology_host/4` rows. The namespace manager resumes local ledgers or
   parks exact joins on route availability. Local private contacts become
   directory-private routes only after their exact host actor route is known.
5. **Advertisements.** Only after each desired namespace is ready and its
   exact anchor is checked does directory control advertise it.

This refines the required root -> system -> ordinary order without inventing a
bootstrap service: the node actor pointer is the already-planned minimal bridge
between shared system recovery and ordinary per-node policy.

A missing pointer leaves node actor authority unavailable and starts no
ordinary hosted ontology. A malformed, conflicting, wrong-anchor, or
locally-unresolvable retained pointer fails namespace-manager initialization
loudly instead of running with an ambiguous physical identity. Neither case
selects a directory result by name or creates a replacement actor. A node that
has lost every local copy and has no other certified replica is a data-loss
case, not something route discovery may conceal.

## 6. One committed node-policy projection

The node actor's immutable genesis contains one founding handler:

```prolog
state_handler(node_ontology_hosting,
              [hosts_ontology/4, knows_ontology_host/4], [],
              reconcile_node_ontology_hosting).
```

Its convergence goal reads the complete current solution set and calls one
genesis-pinned `projection`-class Erlang predicate. The bridge:

1. requires a ground, canonical list;
2. accepts both row types only for the exact locally verified `NodeRef`;
3. rejects duplicate names with different anchors, the same identity asserted
   with both visibility values, invalid visibility, and malformed rows loudly;
4. hands one revisioned node-policy snapshot to `quod_namespace_manager`; and
5. never calls `quod_directory`, opens a connection, or mutates a ledger.

The bridge is placed in the reviewed node-actor predicate module pinned by the
node ontology's genesis. It is not installed globally. `quod_runtime` keeps
the existing P-before-E ordering and reruns the same handler after replay,
restart, assertion, and retraction.

`quod_namespace_manager` merges exactly three sources:

1. configured root bootstrap;
2. root-catalogued system ontologies; and
3. the local node actor's committed hosting projection.

Precedence is exact and fail-closed. Root bootstrap is immutable. A committed
root `system_ontology/2` row is stronger than a node hosting row with the same
namespace. Equal anchors merge into the system row; different anchors reject
the node row, keep the last valid root-derived desired state, and mark the node
projection unhealthy. Node facts can never replace or shadow root/system
identity. Two node rows for one name with different anchors are likewise an
invalid complete projection, never last-write-wins. Two rows for the same name
and anchor with `discoverable` and `private` are also invalid; neither
visibility wins implicitly, because an ordering accident must never publish a
private identity.

For source 3 it derives a join/resume configuration from `{Namespace, Anchor}`
and local storage. It never persists that map as authority. If no local ledger
is ready, it watches the exact route identity and uses the existing pinned join
path when awakened.

Supervisor `DOWN`, namespace-ready, route-available, root-catalogue change,
and state-handler revision messages drive reconciliation. The existing
mutation worker and supervisor owners remain. Route unavailability does not
arm `system_retry`, `reconcile_retry`, or an equivalent delay. Process/work
deadlines remain final failure safeguards only.

The same revision carries `knows_ontology_host/4` rows as a separate local
private-contact projection. These do not enter the desired-host map. The
manager relays the complete derived set to the existing directory owner, which
replaces its local private rows atomically. The directory derives the current
endpoint from the exact `HostNodeRef` route and exposes the target only to this
node's resolver; it never advertises that row.

If the manager is temporarily absent, the projection bridge fails the current
handler run without changing P. The restarted manager re-verifies its node
actor and asks that actor's existing runtime owner for a fresh reconciliation;
the bridge owns no second manager subscription. It does not sleep and call the
bridge again. Likewise, a child-start failure is redriven only by a concrete
supervisor, route, catalogue, hosting, or explicit lifecycle event. The
manager's ordinary `reconcile_retry` timer is deleted rather than retained for
non-route failures under another name.

The manager publishes one revisioned, complete projection of desired source
and ready local identities to directory control through their existing
`quod_reg`/gproc identities. Directory control monitors the manager. On either
process restarting, it asks for the current complete snapshot before
advertising, so a lost notification cannot require a polling renewal to repair
authority.

System-catalogue failures have named, event-driven outcomes; deleting
`system_retry` must not turn them into an immediate respawn loop:

| condition | owner response | event which permits another attempt |
|---|---|---|
| root absent, rebuilding, or not replayed | park the catalogue read | root runtime registration or `replay_ready` |
| committed `system_ontology/2` changed | invalidate the old query/result | exact root `applied_live` changed-head edge |
| exact route absent/unavailable | park only that materialization | `{directory_route, {Namespace, Anchor}}` availability/withdrawal edge |
| `anchor_conflict` | keep the last valid root row and mark the exact identity blocked | root catalogue changed-head or a newer node-policy projection revision |
| query-worker crash | fail the namespace manager so its existing supervisor restarts the owner; do not respawn the worker in place | supervisor restart and fresh root registration/snapshot |
| query-worker deadline | kill the wedged worker and fail the owner as above; the deadline is only a final failure safeguard | supervisor restart |
| `{ledger_read_failed, Reason}` | fail loudly as a local storage-owner fault instead of classifying it retryable | existing supervisor/application recovery after storage reopens |

A persistent worker or ledger fault therefore trips existing supervisor
intensity and node health instead of polling forever. A root or route becoming
available wakes only the parked exact work. Advancing time alone never turns a
failed catalogue into progress.

Directory control retains one pre-existing one-second retry only for failure
to refresh the root control-peer authority set. This is a root-authority
liveness fallback, not namespace-route progress polling; successful root
projection changes remain the normal event-driven wake.

A child start or stop failure is logged and remains pending until a concrete
supervisor, route, catalogue, hosting, or explicit lifecycle event changes the
inputs. It is never redriven merely because time passed.

## 7. Directory publication and receipt

### 7.1 Local eligibility

Directory control advertises the intersection of:

- root itself, under the remaining root bootstrap key configuration;
- ready shared system identities present in root's current catalogue; and
- ready ordinary identities whose node-actor row is explicitly
  `discoverable`.

It no longer iterates a deployment namespace allowlist or every process under
`quod_ns_sup`. A process which happens to be alive but has no committed desired
source is not advertised. A committed row whose local runtime is not ready is
also not advertised. A `private` row is desired hosting but is excluded before
generation construction; it cannot leak into a page, resync, renewal, or
`directory_host/5` answer.

Before the node actor is available, a current root control peer may advertise
only root-catalogued system ontologies. This is the narrow bootstrap case: the
receiver checks both the author in root's current `peer_admitted/4` projection
and every descriptor in root's current `system_ontology/2` catalogue. Once the
node actor is verified, the ordinary fact-backed generation replaces that
bootstrap generation. A non-root-control node cannot use the bootstrap form.

The existing `?RENEW_MS` directory lease renewal may remain because it
expresses liveness and expiry, not progress discovery. It republishes only the
last complete accepted manager projection. It neither rescans processes nor
re-evaluates facts, cannot complete a partial generation, and cannot make a
private row public. Projection changes are event-driven.

### 7.2 Remote interpretation

Every receiver still verifies the record author's node-key signature,
authenticated direct-link identity, epoch, sequence, and payload shape. The
generic namespace/node-key allowlist check is removed.

An ordinary generation also carries its exact node reference. Directory
control supplies the signed author contact only as a request-scoped bootstrap
candidate to the existing `quod_foreign_log` owner. That owner verifies and
materializes the node actor's certified history through its one current
projection path. The directory worker then requires:

- the record's signing key is active for the exact `NodeRef`; and
- every advertised `{Namespace, Anchor}` has the exact committed
  `hosts_ontology(NodeRef, Namespace, Anchor, discoverable)` fact.

The worker reads the already-certified projection; it does not execute a
foreign goal, create another cache, or trust the contact. Concurrent records
for one node actor share the foreign-log owner's existing in-flight work and
resident projection. Verification is on demand for one new signed generation;
Slice 4 does not create a standing follow between every pair of node actors.
The sender's local hosting handler emits the new generation after a fact
change. The received generation itself starts or joins the existing coalesced
verification work. Until author/fact validation completes, no route row is
installed.

Target-role confirmation happens at route selection, not generation install.
The proof scope, consensus submitter, certified follower, or DTX verifier
already opens the existing certified current view for the target it is about
to use; that owner checks the candidate key and advertised role against the
committee/current-view data it already holds. A current-validator row may
serve consensus submissions and a plain remote read. A certified observer row
may supply history/bootstrap data but is never selected as the authority for a
plain read or validator submission. A self-authored route whose node actor is
valid but whose key has no current target role may remain only an untrusted
bootstrap contact; it gains no vote or answer authority.

One plain read answer remains the authenticated answer of one certified current
validator, not a quorum-certified result. That limitation is explicit: the
removed operator allowlist no longer pretends to provide BFT read integrity.
Any durable consequence is protected by target consensus or the existing f+1
read certificate. An application which requires Byzantine-certified query
answers must wait for a separately reviewed answer/transcript certificate.

During a complete fleet rebuild, installing generations can approach one
node-actor verification per receiver/advertiser pair. Selection also performs
the target-current-view work already required by each consuming operation; it
must not add another target-history open or fold. Node actor ledgers are
expected to change far less often than application ledgers, but correctness
does not depend on that expectation and no population cap hides the work. The
existing coalesced certified cache and resident projection must be reused.
Slice 6 measures both generation-install node-actor verification and
selection-time target-current-view reuse, including counts and wall time as
fleet size and node-actor height grow. The height-growth and cold-start costs
remain the separate first two backlog items in §14; they must not be
rediscovered as a directory cache.

Bootstrap system generations use root's already-local certified projection as
described in §7.1 and need no node-actor route. This prevents a circular system
start while keeping the exception restricted to root control peers and root
catalogue identities.

After either validation form, an installed non-root row remains only a signed
bootstrap contact. Existing consumers independently verify the exact target
anchor and certified committee history before accepting facts, votes, read
certificates, or authorization. The advertised role remains a selection hint.
Publication validation does not replace target validation.

Root remains special: the configured root key set and genesis anchor are the
network bootstrap trust boundary. That exception cannot authorize any other
namespace.

### 7.3 Private local reachability

A `private` hosting row is omitted from every network generation. A node which
must initiate contact commits this relation in its own node actor ontology:

```prolog
knows_ontology_host(SelfNodeRef, TargetNamespace,
                    TargetAnchor, HostNodeRef).
```

The same founding handler and revisioned manager snapshot project it into the
existing directory owner. It becomes one local private association from the
exact target identity to `HostNodeRef`, not an endpoint and not a globally
installed advertisement. The directory resolves the discoverable node-actor
identity for `HostNodeRef`, takes its current authenticated contact, and offers
that contact request-scoped to the existing `quod_foreign_log` verification
of the target. Only verified target history can confirm that the contacted key
currently serves the exact target. The resulting private row is readable only
by this node's existing resolver and is never returned by `directory_host/5`.

If `HostNodeRef` has no current route, the private target work parks on the
host actor's exact route property and emits the same demand signal. A host
move changes `knows_ontology_host/4` through an ordinary authorized
transaction; reconciliation atomically replaces the local association. DTX
return verification still reuses the authenticated request contact from
`authenticated-route-continuity-plan.md` and does not require a reverse fact.

`private` here means absent from network enumeration and advertisement; it is
not a cryptographic confidentiality format for ledger contents. Per-fact
confidentiality remains separate, just as certified catch-up pages are not
selectively confidential today.

### 7.4 No ontology-count cap

The current one-record complete set has fixed limits of 32 namespaces, 8
routes per namespace, and 2,048 total rows. Those are arbitrary population
limits and cannot become limits on committed hosting facts.

The replacement keeps byte-bounded frames but streams one node's sorted
complete generation as signed pages. Every page binds the exact author
`NodeRef` (or the explicit root-peer bootstrap marker), signing key, endpoint,
epoch, generation, page position, and descriptors. The existing directory
control owner holds the current generation for that authenticated author and
atomically replaces that author's visible rows only after the complete ordered
generation is present and its committed source has been certified. A newer
generation supersedes an incomplete older one; link loss discards the
incomplete generation. No partial host set becomes visible.

This removes ontology-count and route-table population constants while keeping
transport byte validation and QUIC backpressure. Resync uses the same paged
generation, not a second snapshot codec. The wire change is a hard break with
no old decoder.

### 7.5 Demand-driven wake-up

When a system join, ordinary join, proof scope, certified follower, or DTX
verification lacks an exact route, the existing owner:

1. subscribes to `{directory_route, Identity}`;
2. sends a `route_needed(Identity)` demand signal to directory control; and
3. parks its existing work item.

Directory control uses the already-authenticated root control links and the
existing resync exchange. Link-up or a demand signal starts/resumes the signed
generation transfer. Installation publishes the existing
`directory_route_available` edge, and the parked owner rereads the sole ETS
index. No route is carried in the wake-up message, and no caller inserts one.

The same demand signal is deduplicated by the existing control owner. It is
not a request retry, proof retry, or timer. If no control link becomes usable,
the caller's ordinary deadline returns unavailability.

## 8. Full restart story

| event | recovery path | wake-up | no operator action |
|---|---|---|---:|
| namespace supervisor restarts | manager still owns the projected desired set and recreates missing children | supervisor monitor | yes |
| directory process restarts | recreates empty ETS, control resends its current signed generation | process monitor + snapshot handshake | yes |
| directory-control process restarts | obtains the manager's complete projection, then advertises under a new persisted epoch | manager/control registration edge | yes |
| one physical node restarts | root -> system catalogue -> verified node actor pointer -> hosting handler -> manager -> advertisement | replay/ready messages | yes |
| all physical nodes restart | local root/system copies resume first and begin advertising; node actors then restore ordinary hosts | ready and advertisement messages | yes |
| desired ontology has no local ledger | exact join parks until another host advertises | exact route property | yes |
| remote consumer has no route | its existing request/follow row parks and signals demand | resync/link-up then exact route property | yes |
| hosting fact is asserted | handler installs a new manager revision; ready runtime becomes advertised | applied block -> handler -> manager | yes |
| hosting fact is retracted | handler removes desired state; safe leave/stop completes; next generation withdraws the route | applied block -> handler -> manager | yes |
| private host/contact fact is asserted | target hosting resumes locally but is not advertised; an authorized caller derives its local private association from `HostNodeRef` | applied block -> handler -> manager/directory | yes |
| private host actor moves | caller commits the replacement `HostNodeRef`; the old local association is atomically replaced | applied block -> handler -> exact host-actor route | yes |
| endpoint changes | next signed lease generation carries the new endpoint; exact identity is unchanged | authenticated reconnect/renewal | yes |
| stale or forged advertisement | existing target-history/TLS verification refuses it; no ledger or ACL changes | terminal validation result | yes |

On a restart, a remote consumer does not need the sender to be already in its
ETS. Its next exact use parks, signals demand, and is woken by the republished
signed generation. The proof engine is unchanged.

## 9. Delete and refactor map

| area | keep/refactor | delete |
|---|---|---|
| node identity | existing key directory and atomic writer; extend it with one exact validated node-actor pointer | any general local namespace-intent file |
| Prolog | ordinary ACL/action/assert/retract path; add `hosts_ontology/4`, `knows_ontology_host/4`, and one founding handler | any imperative route-management staging predicate |
| lifecycle | root creation, node join, one effect journal, one namespace manager; creation binds its prepared anchor | old `create_ontology/2` shape and helpers which promise persistence without a hosting fact |
| namespace manager | one node-policy projection, desired-host projection, mutation lane, supervisor monitors, root catalogue | `durable_content`, ordinary static-content override, persistence calls to `quod_namespace_desired_store`, route retry/backoff state |
| desired store | nothing | `quod_namespace_desired_store.erl`, its tests, `namespace_desired_path`, QND1 files and comments |
| directory control | signed author, root relays, epochs, leases, resync, manager snapshot | per-namespace allowlist state, allowlist intersection, process-registry rescans as authority, timer-based route rediscovery |
| directory | sole ETS writer/read API, exact route event, signed soft rows, fact-projected local private rows keyed by `HostNodeRef` | allowlist checks, fixed population caps, `add_direct_seed/2`, `confirm_direct_seed/5`, config-seed rows and imperative confirmation/reannouncement state |
| `quod_ask` scope resolver | co-hosted-first resolution plus one ordered list of already authenticated directory candidates | `probe_direct_routes`, `identify_direct_seed`, `continue_seed_routes`, provisional/TOFU confirmation, and the separate direct-before-system branch train |
| directory auth | move byte/shape checks to the record codec and ontology-name validator | `quod_directory_auth` allowlist/index API; delete the module if no shape function remains |
| config/deploy | root genesis/contacts and exact root node keys | `directory_public_namespaces`, generic `directory.allowlist`, ordinary `directory.direct_seeds`, static benchmark ontology blocks used as route authority |
| foreign history/scopes/DTX | one existing verifier/materialized projection, request-scoped bootstrap-candidate seam, exact route subscription, current target-role proof, and authenticated DTX return contacts | any new route cache, verifier, foreign Prolog executor, retry loop, or proof-engine exception |
| discovery | exact identity -> current route | DF/service-name logic in this slice |

Root content seeds remain operational bootstrap contacts for root. They are not
ordinary ontology route rows and are not exposed through `directory_host/5`.
The old configured private direct seed is replaced, not discarded: its durable
counterpart is `knows_ontology_host/4`, and only its derived local P row reaches
the same directory resolver. Request-scoped authenticated contacts already
used by DTX/foreign-history verification also remain transient hints; they are
not persistent route authority.

## 10. Implementation slices

Each slice must compile, pass focused tests, full EUnit, `quod_ask_SUITE`, xref,
dialyzer, and `git diff --check` before review. EUnit and CT run sequentially.
No later slice starts until the prior review is green.

### Slice 1 — node actor bootstrap prerequisite

- Complete `node-instance-identity-plan.md` Slices 2 and 3: create the node
  actor ontology through root, persist one exact pointer beside `node.key`,
  verify its instance and active key on every boot, and activate the common
  `agent_instance_ref/3` principal.
- Replace the identity plan's §6 references to the existing desired-state
  store: the pointer lives in the identity directory beside `node.key` and the
  directory epoch. Slice 2 commits the node actor's own discoverable
  self-hosting row as soon as `hosts_ontology/4` and the anchor-binding creation
  continuation exist; the row is not part of the actor's own bootstrap.
- Pin the existing ontology external-predicate module in the node actor's
  genesis. The founding hosting handler and its projection bridge land with
  `hosts_ontology/4` in Slice 2; Slice-1 development actors are recreated by
  the coordinated Slice-6 clean re-found because genesis is immutable.
- Add no node-specific signer, ACL evaluator, route owner, or process.
- Tests: first creation, exact restart, wrong anchor, wrong instance, inactive
  key, corrupt pointer, key rotation, and another host carrying the ledger
  without possessing the private key.

### Slice 2 — committed hosting/private contacts and the sole projection

**Implemented; review closed.**

- Add `hosts_ontology/4`, `knows_ontology_host/4`, their ordinary policy/action
  rules, the founding state handler, and one projection bridge.
- Put that founding handler and bridge module in every new node actor's
  genesis; do not attempt to retrofit the Slice-1 development genesis.
- Refactor creation to the single anchor-binding shape and compose create/join
  plus hosting facts through ordinary multi-ontology goals.
- Make namespace manager merge root, system catalogue, and node-actor
  projection only, with root/system precedence explicit and fail-closed.
- When root removes a system ontology, retire and stop that system-owned local
  child. If an equal-anchor node hosting fact still desires it, keep it running
  without a stop/restart flap. If a newly added system identity conflicts with
  an earlier node row, discard only that weaker row, retain the root identity,
  and make the node handler fail loudly on its next reconciliation.
- Delete `quod_namespace_desired_store`, `durable_content`, ordinary static
  ownership, and persistence-after-start.
- Keep one-time lifecycle effect custody unchanged.
- Tests: uncommitted/aborted goals change nothing; commit starts; restart
  restores; retraction safely stops; private rows never enter the public
  projection; a private contact reaches only its exact target through
  `HostNodeRef`; conflicting node anchors fail loudly; a same-name different-
  anchor node row cannot replace a root system row; the same name/anchor
  asserted once private and once discoverable rejects the complete projection
  rather than choosing either; caller death and uncertain outcomes create no
  second mutation path.

### Slice 3 — event-driven bottom-up recovery

**Implemented; review closed.**

- Resume local system ledgers from root catalogue and park missing exact
  identities on directory route properties.
- Resume the exact node actor from its local pointer, then enable ordinary
  hosting projection.
- Delete `system_retry` and `reconcile_retry`; replace them with exact route,
  replay-ready, supervisor-registration, manager-registration, and projection
  messages.
- Apply the failure table in §6: root and route absence park on exact events;
  anchor conflicts wait for a named source-generation change; query-worker
  crash/timeout and ledger read failure fail the existing supervised owner
  loudly instead of respawning/polling in place.
- Add the revisioned manager/control snapshot handshake using existing
  `quod_reg` registrations and monitors.
- Tests: root unavailable, system route absent then arriving, all system rows
  becoming ready independently, manager/control restart in either order,
  catalogue-query worker crash and deadline recovery through supervisor
  restart, bounded restart intensity ending in visible unhealthy state for a
  persistent worker fault, ledger-read failure surfacing unhealthy, and no
  progress after advancing time alone.

### Slice 4 — fact-backed advertisements and one directory wire

**Implemented, including corrections R1–R4; review closed.**

- Replace local allowlist eligibility with the manager's committed-source plus
  ready-runtime projection.
- Keep root's exact bootstrap keys as the only configured advertisement
  exception.
- Replace the directory record/resync family with the one signed paged
  generation and remove fixed population caps.
- Validate ordinary generation authors and exact host rows through the one
  existing certified foreign projection; validate bootstrap system generations
  through the local root peer/catalogue projection.
- At selection, reuse the consumer's existing certified target current view to
  validate the candidate's role. Do not add an install-time target-history
  fold or a second selection verifier.
- Verify node actor and target history on demand per new signed generation,
  coalesced and resident in the existing foreign-log owner; add no standing
  all-pairs follows.
- Project `private` hosting and `knows_ontology_host/4` into the same local
  directory's private class while excluding both from public generation and
  `directory_host/5`.
- Refactor `quod_ask:open_directory_scope` onto the directory's one ordered
  authenticated-candidate result. Delete `probe_direct_routes`,
  `identify_direct_seed`, `continue_seed_routes`, provisional seed identity,
  TOFU confirmation, and the direct-versus-system branch split rather than
  adapting those functions to the new fact projection.
- Treat the resulting non-root rows as reachability hints still subject to
  target-history and target-ACL verification; only a certified current
  validator may answer an explicitly single-host plain read.
- Delete direct-seed insertion/storage, generic allowlists, and their
  compatibility-free config/schema paths.
- Tests: exact complete generation, reorder/duplicate/stale page handling,
  interrupted generation invisibility, withdrawal, key/endpoint mismatch,
  unlimited sequential host rows, private omission, on-demand verification
  reuse, observer exclusion from plain reads, and a liar never gaining target
  authority while resolution advances to an honest coexisting advertiser.

### Slice 5 — demand wake-up and integration

- Connect all existing route consumers to one exact `route_needed` + property
  wake path: system materialization, ordinary hosting, foreign follow, proof
  scope, and DTX reference verification.
- Delete every remaining timer/poll whose ordinary job is rediscovering route
  progress.
- Test simultaneous fleet restart, port rollover, host move, assertion and
  retraction, dynamic creation with no deployment entry, subscriptions, and an
  A -> B -> C -> D call after routes are initially empty.
- Preserve the authenticated-route-continuity private-participant regression:
  A knows private B/C from committed node-agent facts, B/C have no configured
  route back to A, and the request-scoped authenticated return contact closes
  DTX verification without exposing B/C globally.
- Test a `knows_ontology_host/4` row whose `HostNodeRef` never publishes a
  discoverable self-route: work parks on that exact host-actor property and
  ends with ordinary caller-deadline unavailability, with no timer-driven
  retry or private-target demand leak.
- Add fixed-label metrics for desired-host projection, advertisement
  generation, route demand/wake, and rebuild duration; never label arbitrary
  namespaces, node references, endpoints, or payloads. Update Grafana in this
  slice if new metrics land.

### Slice 6 — coordinated activation and hardware gate

- Bump all hard-break formats once, remove old fixtures/assets/comments, and
  perform the coordinated clean re-found. No rolling mixed-wire deployment.
- Create system, node actor, and benchmark ontologies through ordinary goals;
  do not list benchmark namespaces in Nomad.
- Restart all allocations together, then prove every tier reconstructs without
  an operator edit.
- Move an ontology from one node to another through ordinary hosting and
  membership goals, verify withdrawal/republication, then run remote read,
  write, subscription, and chained-goal acceptance.
- Require zero unplanned restarts, no route-progress polling, clean logs, and
  no client-visible uncertain outcome attributable to route loss.
- Measure full-restart node-actor verification count, reuse, wall time, and
  height sensitivity; no standing node-pair follows or hidden population cap
  may appear. Report the single-host trust status of plain reads explicitly.

## 11. Acceptance tests which must be non-vacuous

1. A runtime-created ontology absent from every deployment file is reachable,
   the whole fleet restarts, and it becomes reachable again from facts alone.
2. Deleting the old local desired-state file before restart changes nothing.
3. Removing a `hosts_ontology/4` fact withdraws the route; leaving a stale
   ledger directory cannot resurrect it.
4. Adding a fact while the target route is missing parks a join. Installing
   the exact signed route wakes it without time advancement or resubmission.
5. A wrong-anchor advertisement does not wake an exact-anchor waiter.
6. A node advertising an ontology absent from its local projection fails local
   eligibility; a Byzantine signed generation without the exact certified
   discoverable host fact is refused before ETS installation; a fact-backed
   candidate without a current target role remains only a bootstrap hint and
   is rejected at selection; with a liar and an honest current advertiser for
   the same identity, resolution advances past the liar and reaches the honest
   route; a formerly valid stale hint still cannot pass current target
   verification or `can_invoke/4`.
7. Root restarts with no system route rows, local system hosts advertise after
   replay, and a fresh node joins them from the root catalogue.
8. The node actor ontology is read before ordinary hosting without consulting
   its own missing route.
9. Manager and directory control each restart alone and in both orders; the
   published set converges exactly and never exposes a partial empty set.
10. More than every former 32/8/2,048 directory population boundary is
    exercised through paged generations; no committed row is silently
    omitted.
11. An interrupted or reordered generation never replaces the last complete
    generation. A newer complete generation atomically supersedes it.
12. A remote proof started with an empty directory parks, triggers resync, and
    completes when the route message arrives. The proof deadline is not used
    to discover progress.
13. A host move removes the old validator through normal membership, retracts
    its fact, asserts the destination fact, and leaves exactly the certified
    new route.
14. System, node actor, and ordinary ontology recovery all survive a complete
    application restart with no Nomad namespace-list change.
15. Greps prove zero `directory_public_namespaces`, generic allowlist,
    `quod_namespace_desired_store`, direct-seed insertion, or route-retry timer
    residue in source, tests, comments, schemas, deploy files, and docs.
16. A `private` hosted ontology resumes after restart but appears in no public
    generation, resync, renewal, `directory_host/5` answer, or remote known-name
    index.
17. A committed `knows_ontology_host/4` row lets only that physical node derive
    the private target contact through the exact `HostNodeRef`; retraction
    removes it and restart reconstructs it without config.
18. The authenticated-route-continuity private DTX case remains green: A knows
    private B/C, B/C have no configured reverse route, and the authenticated
    request contact suffices without publishing either target.
19. A plain remote read refuses observer and stale-validator rows, accepts only
    a certified current validator route, and is labelled/documented as a
    single-host result rather than a quorum-certified answer.
20. Catalogue query-worker crash and deadline fail/restart the supervised owner
    without an internal retry timer; route/root arrival wakes only exact parked
    work; a local ledger read error is visible in node health.
21. A root system row and node hosting row naming one namespace with different
    anchors retain the root identity, reject the node projection, and never
    start or advertise the conflicting target.
22. A private contact naming a `HostNodeRef` with no discoverable self-route
    parks on the host actor's route property, emits no demand containing the
    private target identity, and returns unavailability only at the caller's
    existing deadline without looping.
23. Two hosting rows for the same namespace and anchor with different
    visibility reject the complete node-policy projection; row order cannot
    make a private identity public.

## 12. D/P/E classification

| artifact | class | consequence |
|---|---|---|
| `system_ontology/2` | D | root-owned all-node system desired state |
| node instance, active key, ACL | D | node actor ontology |
| `hosts_ontology/4` | D | node actor's ordinary desired hosting and discoverability truth |
| `knows_ontology_host/4` | D | local node actor's exact private target-to-host knowledge |
| create/join/membership transactions | D | normal ontology ledgers and consensus |
| prepared lifecycle effect descriptor | D | existing transaction/effect contract |
| lifecycle execution | E | existing effect journal, once after commit |
| state-handler convergence | P/E boundary | rebuilds local desired runtime from D |
| manager desired snapshot | P | derived, replaceable, not persisted as authority |
| local private target/host association | P | derived from `knows_ontology_host/4`, local directory only |
| directory advertisement/assembly/lease | P | signed network observation accepted only against an existing certified D source |
| ETS route/high-water/known rows | P | disposable local index |
| endpoint, QUIC link, request contact | P | existing transport/foreign-log owners |
| route-available notification | E | wake-up only; consumer rereads P |
| plain remote read answer | E/P reply | authenticated single current validator; not a quorum certificate |
| DF service registration | out of scope | later semantic discovery layer |

No consensus format changes merely because routes recover. The planned hard
breaks are the lifecycle predicate shape, node actor genesis, and directory
wire/config removal. They activate together; no old decoder or forwarding
shim remains.

## 13. Exact documentation amendments when implementation lands

| document/passage | required amendment |
|---|---|
| `ontology-actor-architecture.md` §2 system bootstrap | replace “waits and retries asynchronously” with exact route-property parking/wake; add node actor pointer between systems and ordinary hosting |
| `ontology-actor-architecture.md` §3 and §7 | mark the reviewed node-actor projection-module extension; replace planned hosting text with the single `hosts_ontology/4` plus `knows_ontology_host/4` path and delete local checkpoint wording |
| `node-instance-identity-plan.md` §3, §6.1(4), §6.2(4), §8, Slices 2–4 | move the pointer from the deleted desired-state store to the identity directory beside `node.key`/directory epoch; record principal activation, fact owner, manager projection, and route reconstruction; preserve the distinction between node class ontology and dedicated node actor ontology |
| `agent-fipa-plan.md` invariant 5, §11, §13 | name `hosts_ontology/4` and `knows_ontology_host/4` as reconstructible node-level relations; state that exact public route ads derive only from discoverable rows while DF remains name-to-identity only |
| `event-reaction-refinement-plan.md` §5 | change the illustrative hosting example to implemented status and link this plan; keep `state_handler` distinct from `react_on` |
| `durable-lifecycle-effects-plan.md` root/bootstrap and recovery passages | distinguish one-time create/join effect custody from persistent fact-driven hosting; retain root-first custody and remove checkpoint claims |
| `network-directory-plan.md` §§1–6, §9 acceptance tests 3–6/10–11/15, and §§10–11 | replace config allowlist/direct-seed authority with root bootstrap, discoverable fact-backed generations, and fact-projected local private routes; state explicitly that plain remote reads trust one certified current validator; document paged generations, no population caps, and exact route demand/wake |
| `network-directory-root-control-plan.md` §§5–10 | remove generic allowlist authority and its deferred root replacement; retain root control relays, signatures, epochs, leases, and one resync family |
| `authenticated-route-continuity-plan.md` §§2–5 and §11 tests 1–2 | replace configured private-seed persistence with `knows_ontology_host/4`-derived local routes; keep request-scoped authenticated contacts, asymmetric private DTX, and the one foreign-history verifier |
| `ontology-subscription-plan.md` private reachability passages around lines 60, 135, 159, and 264 | replace “directory/private-seed path” with public fact-backed routes or local `knows_ontology_host/4` projection; subscriptions remain semantic relations, never routes |
| `inter-ontology.md` deployment example around `directory_public_namespaces` | delete manual namespace-list instructions; show fact-based host assignment and automatic restart recovery |
| `ontology-creation-plan.md` restart/persistence passages | replace manager checkpoint ownership with composed creation plus node hosting fact; document anchor-binding creation shape |
| `ontology-join-plan.md` restart/persistence passages | replace local restart intent with the node hosting fact and event-driven exact-route join |
| `README.md`, `CLAUDE.md`, deploy comments, `config/quod.conf:46–60` | remove manual route allowlists/direct seeds and the private-arm config example; describe root-only bootstrap, discoverable/private hosting facts, and node-agent private-contact facts |
| `quod_namespace_manager`, `quod_ontology`, `quod_directory`, `quod_directory_control`, `quod_app`, and schema moduledocs/comments | make the one fact/projection/index ownership model explicit; rewrite `quod_directory`'s private-seed and confirmed-private reannouncement paragraphs around the derived local private projection; delete every description of superseded authority |

Historical descriptions may keep old behavior only when explicitly labelled
historical. Generated config examples and tests count as documentation and are
part of the same sweep.

## 14. Explicitly separate backlog

These items are not route-recovery work and must remain in this order after the
plan/review arc:

1. **Height-growth latency curve.** One-hop c4 p99 is 676 ms against the
   <=450 ms absolute gate. Per-request certified-history cost rose from about
   149 ms at height 80 to about 400 ms at the current height and reset on
   re-found. This is the next optimization milestone after route recovery.
2. **Cold-start re-verification.** The first request after restart at height
   about 7,000 took 34.6 s. A separate history-compaction plan, written after
   R2 review and before any implementation, owns this item: it will specify a
   committee-certified projection checkpoint plus verifiable suffix replay,
   archival, and committed Prolog policy for checkpoint creation.
3. **Small opportunistic fixes.** Pin `diff`, `read_check`, and `effects` empty
   in `valid_role_fields` for metadata roles; delete caller-less
   `verify_current/3`; restore the lost `verify_local` committee-era assertion.
4. **L2 / write-lanes Slices 6–8.** They remain gated until the release gate is
   green.

None of those changes belongs in this plan's commits, measurements, or review.

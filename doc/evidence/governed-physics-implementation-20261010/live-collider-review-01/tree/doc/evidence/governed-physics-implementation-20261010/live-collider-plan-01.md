# Automatic live collider updates: implementation plan

Prepared against commit `4631578cd74ac63f907df1288ec74d96115b36fc` for tracker
`task_1791574097686_paoo8v`. This is the next proposed implementation slice,
not evidence that it works. The preceding ordinary-view and retained-reader
work is committed; the ticket remains open.

## In plain language

An object keeps its shape in its owning ontology. A space admits that object
and gives it a simulation body. Entering, changing the shape and leaving each
update all affected owners in one transaction. The space's existing subscription
then supplies the committed shape to its physics owner automatically. If the
current shape or permission cannot be verified, that simulation pauses rather
than treating the object as absent.

This applies to any space. Gravity, access and resource allowances remain that
space's Prolog policy. There is no new physics ontology, compatibility route,
geometry mirror, polling service or message broker.

## Reuse and the concrete gaps

| Existing owner | Present behavior | Required extension |
| --- | --- | --- |
| [space.pl](../../../priv/ontologies/space.pl) | `space_place/3` and `space_withdraw/3` atomically change source assignment and destination admission; `space_physical_change/3` must succeed | Supply simulated admission/removal consequences and compose definition edits with their destination consequence |
| [quod_physics.pl](../../../priv/ontologies/quod_physics.pl) | Local body definitions, shared shape validation, structure revisions, control, checkpoints and activity custody | One body-description model supporting a live source reference; source grant/export; revision-checked lifecycle actions |
| [quod_foreign_log.erl](../../../src/quod_foreign_log.erl) and [quod_foreign_projection.erl](../../../src/quod_foreign_projection.erl) | Caller-owned retained follows and bounded shared MVCC snapshot reads | Authorize the runtime's current resource worker to read its exact follow; evaluate the narrow definition export in that worker |
| [quod_runtime.erl](../../../src/quod_runtime.erl) | Source notices update `source_views` and reactions; resource selection/fencing sees local changes | Feed source changes into resource invalidation and fence source results at selection and installation |
| [quod_resource_basis.erl](../../../src/quod_resource_basis.erl) | Observed local predicates and inputs, including failed selections | Record anchored source dependencies and source lifecycle observations |
| [quod_physics.erl](../../../src/quod_physics.erl) | One native owner per world, selected-state installation and scoped notices | Preserve valid worlds when another source is unavailable; install only current, complete body descriptions |

The retained snapshot reader is already implemented. It does not itself grant
physics access. `select_resource/4` deliberately uses a local, read-only policy
context: do not enable arbitrary foreign calls there. The directory's existing
raw-clause consumer also remains; it is not a physics authorization mechanism.

## References and ownership

Use existing anchored terms throughout:

- Source object: `entity_ref(SourceNs, SourceAnchor, Entity)`.
- Admitting space: `entity_ref(SpaceNs, SpaceAnchor, Space)`.
- Simulation: `world_ref(SpaceNs, SpaceAnchor, Space)` in that space's ontology.
- Authority: `agent_instance_ref(SpaceNs, SpaceAnchor, Authority)` with the
  existing hosted-agent epoch/key, run generation/token and local incarnation.
- Body: existing `body(Id, BodyRevision)` qualified by the simulation reference.
  Acting agents keep their existing anchored agent references and binding epochs.

This slice composes simulation into the admitting space's owner. A separate
physics domain is not necessary for this use case. It imposes no general rule
that spaces must share an ontology and supplies no inter-simulation handoff.

The source owns the explicit geometry/material definition and its revision,
the exclusive `physical_assignment/3`, and the installation delegation. The
destination owns `space_placement/3`, the source-to-body binding, authored body
placement/attachment intent, body identity, world structure and existing
authority/control/checkpoint/activity state. Definition-local geometry frames
and destination placement have distinct meanings; neither duplicates a pose
writer. Live simulation poses remain transient native state.

The destination binding names the source instance, assignment revision and
definition revision/digest; it contains no mutable copy of the source shape.
It is a current-version fence, not a pinned recipe. Body IDs use a Prolog-owned
monotonic allocator retained after deletion; unsigned-64-bit exhaustion is an
encoding error, while population and geometry allowances remain Prolog policy.
Existing authored IDs require explicit authorized allocator initialization
above them, not a request-time scan, silent migration or history rewrite.

Refactor the authored body relation into one shared description contract for
owned definitions and live references. Keep effective body queries derived
from that contract, and replace superseded writers/callers. Deliberately
materialized, versioned recipes remain explicit owned definitions. Their
semantics are different from live instances, not an old implementation path.

## Implementation order

### 1. Compose the Prolog transitions

Use the already reviewed source-owned delegation/export contract, with its
destination reference bound to the simulation above:

```prolog
physics_definition_delegate(Entity, WorldRef, AuthorityRef, AssignmentRevision).
physics_definition_projection(WorldRef, AuthorityRef, Entity,
                              DefinitionRevision, Definition).
```

The export checks the exact assignment and delegation. It reads only that
source's current committed definition. It does not impersonate a principal,
perform I/O, follow another ontology, or authorize arbitrary goals. Ordinary
user reads and mutations still require entry ACLs and domain policy at every
participating scope. Installation delegation does not grant user disclosure,
position/velocity access, control or hosting.

The destination must declare the source using the existing stored
`subscribes(SourceNs, SourceAnchor)` fact. Admission refuses a missing
subscription; authorized composition can declare it in the same transaction.
Do not turn derived `subscribes/2` rules into runtime declarations or add a
second subscription registry. Withdrawal does not erase a subscription that
other consumers may use; explicit unsubscribe invalidates dependent resources.

| Operation | Changes in the same existing atomic transaction |
| --- | --- |
| Admit | Source assignment/delegation; destination admission, monotonic body ID/binding and placement; structure revision; any authorized initial agent binding |
| Edit source definition | Source definition revision; exact assigned destination's body/structure revision and source fence; affected checkpoint invalidation and incompatible activity cleanup |
| Reposition | Destination authored placement and affected body/group revisions, with the same cleanup; source geometry remains source-owned |
| Withdraw or delete | Assignment tombstone and delegation removal; admission/body/binding removal; affected joints, checkpoints, controls and activities cleaned up together. Delete composes withdrawal before removing a live definition |
| Revoke active installation | The same withdrawal transition. Removing future-entry permission alone retains its existing meaning and does not erase an admission |

All callbacks verify staged counterpart state; calling one alone cannot commit
half a transition. Use existing savepoints and the ordinary atomic write lane.
Concurrent admission/edit/withdrawal/grant changes conflict through the current
per-predicate OCC and conservative world structure fence. Failure rolls back
every participant. Uncertain writes resolve the original signed operation.

Reuse the supported door/hinge group and rest cleanup rules. An edit cannot
leave half a constraint group at the old revision. Unsupported groups or
unresolved original activity custody refuse destructive edits until resolved;
do not discard custody to make removal succeed. A raw administrative edit
violating the revision contract produces invalid configuration, not silently
updated geometry under an old body revision.

### 2. Read live definitions through the retained source owner

Have the local Prolog selector emit explicit live-reference descriptors. The
same bounded resource runner resolves them using the fixed source export over
`quod_foreign_projection:read/4`. It then supplies complete native descriptions
to the existing installer. Both owned and referenced shapes use shared Prolog
validation: box, ball, capsule, convex, compounds and supported fixed surfaces.
Retain the adapter's explicit joint/profile restrictions.

The runtime grants access only to its current worker, exact caller-owned
follow, source identity and current hosted authority. Bind the grant/result to
the follow and materializer incarnation, source height/projection ID, assignment
and definition revisions/digest, observed predicates and original deadline.
Cancellation, owner death, replacement or withdrawal invalidates the result.
Proof evaluation stays out of the materializer receive loop. No new process
owner, source KB copy or caller-supplied-principal shortcut is needed.

Keep subscriptions and verified projections alive with their real consumers.
Keep selected immutable descriptions only as existing installed resource state.
Capture dependencies for missing definitions and denied exports too, so later
authorized enablement/grants can wake the selection without polling.

### 3. Connect source notices to invalidation and installation

Extend `handle_source_notice/5`, source removal and foreign-log owner loss to
update the resource basis independently of best-effort reaction publications.
Resnapshot/recovery must work with zero historical publications.

Namespace source predicate observations by exact identity. Retain the mapping
from those dependencies to affected worlds within the existing runtime resource
state. Local predicate invalidation can remain conservative; this work claims
no row-level precision. A missing definition must not disappear from a
`findall` result and become an apparently valid empty world.

Fence both `resource_selected` and `project_physics`: the worker, local
selection, source follows and verified revisions must still match. Atomic
participants can become locally visible at different times; mismatching source
and destination revisions wait for their existing notices, never initiate a
repair write. Install at the existing simulation boundary, then publish the
existing exact world/incarnation/structure installed notice.

Unknown or advancing source state suspends the affected simulation and its
controls/queries until the verified delta resolves it. An unrelated verified
predicate change can retain
the installed geometry without re-evaluating its definition or rebuilding it.
Duplicate/unchanged notices do no selection, native installation, history
replay, projection rebuild or storage write/sync. Source loss must not retire
another valid world's native owner. Remove the current all-world failure path
where an identifiable per-world source failure can be represented explicitly.

### 4. Preserve recovery and ordinary-view behavior

Recovery reads current assignments, definitions, grants, bindings and compatible
checkpoints; it never needs missed reactions. Host/authority replacement follows
existing agent custody and run-generation rules. A new authority needs matching
source delegation before installing; a stale host cannot reuse the prior grant.

Carry actual source/authorization dependencies into the existing signed view
selection, including denied/disabled cases. Preserve anchored marks, authored
parents, camera transforms and the one pose writer. A controlled body stays
controlled-but-unavailable when physics is unavailable; it never becomes an
observer as an error fallback.

Commit, installed geometry and mechanically fulfilled placement stay separate.
Exercise occupied initial placement, shape expansion around a body, reposition
and teleport using the existing mechanical checks and explicit blocked/failure
results. Do not report successful physical arrival from admission or an install
notice. Any durable fulfillment added here must use the existing authenticated
observation/custody transition, never a live-query proof exemption. Missing
collision coverage is unknown. Moving-door collision belongs in these checks;
the separately tracked durable real-door consequence acceptance remains separate.

### 5. Prove the path, cost and failure behavior

Extend production-owner tests using at least two distinct world identities,
including non-lobby worlds with different gravity/policy and a nonphysical
case. Cover competing admissions, edit versus withdrawal, denied entry/export,
rollback, deletion, grant revocation, stale source/body/structure fences, source
loss, authority replacement, reconnect and recovery without reaction replay.
Synchronize through deliveries and installation notices, not sleeps.

Commit a real signed source edit through the remote ontology/verified-projection
path; demonstrate changed collision at the subscribed installed native owner.
Observe exact affected resource selections and native geometry work. Separately
measure repeated unchanged checks and irrelevant-source changes: no history
replay, projection/geometry rebuild or disk writes/syncs attributable to checks.
Count legitimate simulation steps and actual durable changes separately. Retain
failed runs and true child exits. A fixture or direct injection alone does not
satisfy the remote-change obligation.

Review implementation and removed callers/exports, run the affected clean
sequential gates, freeze the tested tree and report the actual production delta.
This plan has been independently checked against the owners listed above using
the requested sequential-thinking and knowledge-graph MCP servers. It has not
received a new Claude review and is not implementation validation.

## Release and completion boundary

Deploy only through the existing coordinated single writer/release authority.
Participating validators and retained-projection consumers must run the same
approved behavior before enabling these definitions. Shared system registration
is the native interface; neither a class declaration nor package editing changes
founding provenance. There is no compatibility branch or automatic refound.

After integration, the ticket still needs the fresh signed personal-space
identity/history baseline, authorized deployment and real desktop collision
acceptance in that same space, preserving its console and openings. Those are
acceptance targets for this generic feature, not special implementation rules.
VR comfort/contact acceptance and durable real-door consequences remain their
separate tracked work. Keep this ticket open until its own acceptance is verified.

# Existing-world physics implementation plan

Historical proposal, superseded by the existing-model audit and shared system
registration. Its separate-domain/capability-epoch alternatives are not the
implementation plan and must not be reintroduced. Backward compatibility is
not required. See `system-registration-slice.md` for current local work.

Implementation proposal for the governed-physics tracker task. This is a
plan, not implementation, architecture approval or live acceptance evidence.
The existing agreed requirements in `doc/governed-physics-plan.md` remain
user-owned and are not rewritten by this proposal.

## Established constraints and missing capabilities

`space.pl` now supplies organizational membership, exclusive assignment at
the instance owner, atomic physical admission/withdrawal and a required
`space_physical_change/3` consequence. It allocates no simulator. Reuse these
transitions rather than another admission registry.

The current physics owner already retains native worlds, activation custody,
run generations, control registrations, samples and checkpoints. Its runtime
selector is deliberately a local, immutable policy evaluation with bridges
disabled. `physics_projection/2` reads local `physics_body/7` facts. Foreign
subscription notices advance verified source state, but only their reaction
publications enter dispatch. They do not invalidate resource selections.
`quod_foreign_log:projection_clauses/3` provides retained, generation-bound
clauses; it does not yet supply an authorized foreign physical projection to
the local resource selector. These are two demonstrable gaps, not grounds for
a new synchronization service.

The ordinary UI loads `lobby_view/2`; physics uses a separate Simulation menu
selection. Discovery is currently in the acting agent's ontology, and the
socket follows only agent and simulation scopes. All simulation marks must
currently have a body and no parent. This cannot preserve an ordinary mixed
lobby scene or wake a previously disabled association correctly.

Founding selects native modules. Both ordinary and prepared validation reject
changes to `external_predicate_modules/1`; the canonical reducer loads it only
at genesis. Source/class edits cannot add physics to an existing scope. The
pinned actor architecture requires a separately designed root-governed
installation/activation facility before native membership can become mutable.
The removed selection/reconciliation experiment is not a candidate patch.

## Ownership decision at the architecture gate

The recommended bounded implementation uses an explicitly designated simulation
domain, normally founded with physics capabilities, while retaining the visible
space and each definition at their current owners. The same association supports
co-location when the chosen owner already has the required founding capabilities.
There is one path with exact references, not separate lobby/new-world paths.

This boundary is justified only if the simulation domain owns its authority,
hosting, admission, control grants, aggregate resource budget, checkpoint custody
and recovery lifecycle independently of the visible space's source/appearance.
Several space instances may use that authority. A component created merely to
escape an old module layout, or a mandatory physics ontology per space, is
rejected. The live baseline must establish whether that independent authority
is the intended ownership arrangement for Yan's personal lobby.

If Yan requires all those truths to remain in the current personal-lobby
ontology and its retained manifest lacks physics, this recommendation does not
solve the missing capability. The alternate project is a new governed native
capability-evolution contract: immutable founding provenance, root-authorized
effective capabilities, coordinated installation/activation, proof-generation
fencing, withdrawal and canonical replay across every validator/consumer. That
foundational project needs an explicit architecture gate before implementation;
it must not be smuggled into a physics selector or package edit.

No live creation, hosting change, release, refound or ledger mutation is granted
by this plan. Select the ownership arrangement after the fresh signed baseline
and requested Fable review. Implementation can use production-owner fixtures;
real deployment remains under the existing release authority and one writer.

## Exact identities and authoritative relations

Use the existing terms consistently:

- Visible space: `entity_ref(LobbyNamespace, LobbyAnchor, SpaceInstance)`.
- Instance/geometry owner: `entity_ref(SourceNamespace, SourceAnchor, Instance)`.
- Acting human: `agent_instance_ref(UserNamespace, UserAnchor, UserInstance)`.
- Simulation domain: `world_ref(PhysicsNamespace, PhysicsAnchor, DomainInstance)`.
- Physics authority: the existing anchored hosted `agent_instance_ref/3`.
- Body: the simulation domain reference plus its explicit unsigned-64-bit body
  ID. A mark occurrence is neither a body nor another instance.

The space owner authors an exact space/domain association and retains admission
policy. The instance owner retains geometry and exclusive assignment. The
simulation ontology owns the admitted instance/body binding and native authority,
controls, activities and compatible checkpoints. Source geometry is a live
reference, not copied mutable `physics_body/7` data or an implicitly pinned recipe.
The original human remains the signed principal; a local physical agent in the
domain may be explicitly controlled by it. That does not migrate or impersonate
the human agent and does not assert generic foreign-agent embodiment.

Specify association and binding revisions in the final Prolog vocabulary. Each
association, agent/body/viewpoint definition and control binding must be exact
and unambiguous. Disabled association is a successful, dependency-bearing
selection. Absence of an association is nonphysical only after an authorized
read of the actual visible-world owner; failure is not absence.

## Admission, editing, withdrawal and recovery

Admission enters the existing instance-owner `space_place/3`. Its destination
callback checks source delegation, space admission policy and the exact domain
association. The required physical consequence calls the designated domain's
body-admission action in that same sealed proof. Assignment, admission, body
binding, structural revisions and any related cleanup commit atomically across
the real participants. A participant helper cannot independently create a body.
All scopes retain their own `can_invoke/4` and domain authorization.

The instance owner's geometry action uses expected definition revision and its
current exclusive assignment. Its destination/domain consequence updates affected
body/structure dependencies and invalidates incompatible checkpoints/activities
within the same transaction when those are durable consequences of that edit.
No manual re-adoption, post-commit repair, native-authorized durable update or
geometry copy is introduced. Source editing outside the physical action must
either preserve the definition contract or cause an explicit fenced/unavailable
installation; the final design must explain how ordinary authorized physical
edits reach all required consequences, rather than pretending raw arbitrary
source edits are automatically coherent domain transitions.

Withdrawal and curator eviction share `space_withdraw/3`. Its required callback
removes the domain binding/body, related constraints, invalid checkpoints and
incompatible pending activity, then releases assignment atomically. Unresolved
original physical operations or unsupported cleanup refuse the transition; a
missing source/receiver is unavailable, not unilateral release. Revocation of
future consent does not erase active delegation. Explicit active withdrawal or
control revocation follows its designated owner.

Competing admissions conflict at the existing instance assignment predicate.
Admission/edit/withdrawal proofs also depend on exact source definitions, space
association, body/structure revisions, control rights and run/host fences.
Retain current per-predicate OCC and conservative world fencing; no row-level
precision is claimed. Failed alternatives use normal savepoints; multiwriter
abort leaves all participants unchanged.

Recover committed assignments, bindings, verified source state and compatible
checkpoints through existing owners, without replaying reactions or controls.
Same-host restart and host/authority replacement keep fresh run generation and
incarnation requirements. Resolve uncertain writes by their original bytes and
signature. Independent-simulator transfer remains outside this slice.

## Subscription-to-install extension

Extend the current runtime's resource dependency capture to include exact
subscribed source identity and the physical/authentication predicates actually
read. Capture failed, disabled and missing selections as well as successful ones.
Keep subscription acquisition before source snapshot reads. The runtime retains
consumer references and revisions, not another foreign KB or collider store.

Extend the existing retained foreign projection owner to evaluate the narrow
committed physical-definition projection under its explicit installed delegation,
using the ordinary pure Prolog evaluator and current verified snapshot. A worker
may borrow a handle or obtain a bounded immutable selected result; the runtime
must not perform network policy reads, recreate projection workers or parse
history during selection. The precise API and authorization boundary need review:
`projection_clauses/3` alone is not a completed foreign authorization contract.

On a real source advance, use changed predicate heads and projection/incarnation
fences to invalidate only affected selections and registrations. Source readiness,
resnapshot, consumer withdrawal and owner replacement are dependency changes
even without reaction publications. A duplicate/unchanged notice does nothing.
This invalidation is independent of best-effort occurrence delivery and survives
recovery/overflow. Retain original cancellation/deadline behavior.

Before installation, fence the local selection, source snapshot/revisions,
admission/binding and native owner incarnation together. A source advance racing
selection invalidates the result before travel resumes. Install current geometry
and associated revisions at the existing step boundary, publish the existing
identity/owner-scoped installed notice, and preserve unaffected native bodies.
Do not rely on receiving every reaction or apply a stale checkpoint to a changed
shape. Missing geometry is unknown, never an empty collider.

## Geometry and ordinary signed view

Extract the current body validation into shared Prolog validation for authored
pose, kind, density and supported shapes: box, ball, capsule, convex, rigid parts
and fixed triangle surface. Keep aggregate geometry/body allowances in Prolog
policy, and native numeric/positive-volume constraints in the adapter. Preserve
the supported door joint restrictions. Do not replace visual GLBs with collision
authority or infer a box from a picking bound.

The ordinary view signs one coherent projection of the original visible space,
mixed decorative and body-bound marks, authored parents/local frames, explicit
body identities and camera position/orientation. Reuse the current simulation
socket and signed control lane; retire the separate all-body/no-parent path.
Its dependency set includes acting agent, visible space, simulation domain,
authorization, source geometry and selection even when disabled. Derive this
from actual proof dependencies or the selected exact projection, never a guessed
two-scope subscription list. Subscribe before reading, bind owner incarnations,
and invalidate stale registrations without polling. Keep the supported local
single-view restriction explicit; do not add remote frame forwarding.

Keep one transform writer. Compose authored parent/attachment transforms and
camera mount with accepted body poses instead of replacing the complete scene
from competing effects. Decorative marks retain their anchored targets. Observer
travel, signed body commands and tracked head offsets stay separate. A controlled
body pauses on denied, recovering or unavailable physics and never falls back to
observer travel. Nonphysical and disabled states are distinct authorized answers.

Occupied spawn/reposition/teleport returns installed/mechanical feedback separately
from the configuration commit. Durable fulfilled-placement claims require existing
authenticated observations and ordinary consequence commits. Moving-door contact
uses current mechanical state; durable obstructed-door acceptance remains its
separate tracker obligation. Author the real lobby's floor/openings, roof, console,
controlled agent and camera in Prolog after signed baseline and deployment approval.

## Validation and completion gates

1. Freeze this plan and relevant source inputs for the requested read-only Fable
   review. Check its recommendations independently. Settle the ownership and
   foreign-projection authorization questions before server semantics change.
2. Implement the selected generic production-owner path, with at least two exact
   worlds including non-lobby and nonphysical cases. Verify competing admission,
   edit and withdrawal, distinct principals, denial, rollback, replay, original
   operation resolution, revocation and stale source/body/structure/run fences.
3. Commit a real collider edit at a remote definition owner and demonstrate it
   reaches the retained subscribed installed native owner without another protocol.
   Measure affected invalidation and unchanged repeat work: no history replay,
   projection/native geometry reconstruction or check-caused write/sync. Count
   legitimate stepping and real durable updates separately.
4. Cover mixed marks/parents, authored camera rotation, disabled-to-enabled discovery,
   authority change/reconnect, occupied placement, collider deletion and moving
   doors through actual server/client seams. Use processing/install evidence to
   synchronize tests, never sleeps.
5. Freeze implementation and full true-exit validation logs for the second requested
   Fable review. Resolve findings independently; use required clean sequential
   release gates only at their real boundary and report the production-line delta.
6. Establish fresh signed user, personal-lobby anchor and history baseline before
   acceptance. The October 9 anchor and October 10 system lobby-vocabulary anchor
   are insufficient. Coordinate one server writer and explicit release authority.
   Perform signed desktop collision acceptance in that same normal lobby; compare
   identity/history and preserve console/openings. Keep this tracker open until
   its own acceptance passes. Vive/WebXR and durable blocked-door acceptance remain
   separately required by their existing items.

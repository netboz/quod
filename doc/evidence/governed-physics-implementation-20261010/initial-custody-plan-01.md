# Governed first key and complete space activation

Plan for the remaining setup work, 2026-10-11. Subject to the requested Fable
plan review before production edits. The task remains open through real signed
desktop and remote collider acceptance.

Yan clarified after the review packet was frozen that the current floor/ground
are drafts: do not spend significant effort matching their holes. Verify generic
engine support for genuine openings with simple explicit geometry, and use a
simple authored collision layout for the draft space.

## Existing owners and demonstrated gap

`agent_instance.pl` already owns initial assignment, replacement, key revocation
and recovery actions. `quod_agent` owns signed requests; `quod_runtime` owns
committed resource selection; `quod_agent_vault` alone owns encrypted private
keys. `quod_agent_predicates:sign_agent_request` provides the existing pattern
for a read-only, exact-scope, Prolog-authorized vault operation. The ordinary
signed client ingress and source editor already reach that scope locally,
including a retained local observer rather than routing custody to validators.

Recovery uses a reaction-only preparation descriptor, an authenticated node
worker, a committed `agent_custody` selection and `vault:prepare`. The selector
requires an existing host; the vault requires a positive previous epoch. Initial
`initialize_agent_host/3` accepts a public key but does not generate custody.
Tests bypass this gap with `vault:generate/1`, which has no production caller.

No new executor, service, ontology, subscription path or capability-evolution
contract is needed. The actual retained personal-world manifest already names
`quod_agent_predicates`. `quod_predicates:load_manifest/2` uses declared module
names from immutable founding provenance and the installed coordinated release;
the recorded BEAM digest is provenance, not a lifetime binary lock. A new bridge
in that existing module still requires a compatible cold release before use.
No hot registration or manifest mutation is proposed. Yan subsequently authorized a candidate refound if deployment needs it; see the clean release boundary below.

## One preparation contract

Add `prepare_agent_key_custody(AgentRef, OldHost, OldEpoch, Destination, Key)`
to the existing agent predicate module, as a live-service query. `AgentRef` is
exactly `agent_instance_ref(Namespace, GenesisAnchor, Instance)` for the executing
scope. `Destination` is the exact installed local node agent reference, not a
hostname or inferred validator. Inputs are ground; `Key` is a fresh output
variable. Wrong anchor, scope or destination fails before opening the vault.

Only a session founded read-only may call it. A staged grant, an action
prerequisite, reaction matching or policy verdict cannot generate custody.
Its live bridge dependency retains the existing no-material-diff rule. Bind
the authenticated caller through the existing principal bridge, then evaluate
the local committed preparation policy with governed calls disabled, as the
existing resource selector does. Preserve the original absolute deadline.

Concretely, perform context, read-only-session, argument/output, exact scope and
local destination checks first. Bind Caller in the original proof context.
Use `quod_erlog_db_local_prove:committed_state/1` to retain its pinned base;
install `policy_verdict_context/2` with the original chain via `with_chain/2`,
then `wrap_state/2` with read-only/read-set options and the original access guard.
Run the ground helper through `quod_ask:authorization_result/2`, absorb its reads
into the caller and always clean up its read-set table. Governed predicates,
including `current_principal` and `current_ontology_identity`, are forbidden
inside that pure policy; the bridge already validated/bound those inputs.
The ordinary signing bridge is the model for an authorized vault query, not
evidence that its own policy is already evaluated under this strict context.

Replace `can_prepare_agent_key/4` with
`can_prepare_agent_key(Caller, Instance, OldHost, OldEpoch, Destination)`.
There is no compatibility clause. Recovery policy restricts Caller and
Destination to the same authorized observer as today. A space administrator
may instead receive an explicit first-preparation grant for one exact agent and
destination. No class membership or world-view permission grants preparation.
An exact grant is the admission policy for this scarce resource; no Erlang
population allowance is added.

Share a pure Prolog eligibility helper between the public bridge and the
existing runtime recovery selector. `none,0` requires absent host and absent
key rows; positive epochs require the exact existing `agent_hosted/4` assignment.
The helper checks the new five-argument policy. Initial assignment reuses the
same absence guard while retaining its independent `can_assign_agent_host/6`
authorization. Recovery candidate publication keeps its existing destination
principal and positive-assignment requirements.

Extend the existing stable preparation slot to previous epoch zero. Network,
anchored agent reference and epoch remain its binding. Lost read replies and
vault restarts return the same public key. A later epoch preserves old custody
and prevents a stale epoch from creating another key. Remove `generate/1` and
its handler; migrate every fixture to the appropriate `prepare/2` epoch.
Preparation does not publish an active key, host an agent or start physics.
Unused prepared keys can remain encrypted after a lost assignment race. There
is no automatic deletion while a related operation may be uncertain; existing
operator custody deletion remains explicit and separate from domain revocation.

## Durability and unchanged work

Today `preserve_custody/2` syncs the directory even when both names already
identify the same encrypted inode. Replace that unchanged sync with an inode
check, while preserving a real sync after link creation. Sync the vault directory
at startup before accepting requests, covering a crash after a successful link
but before its directory sync.

The vault must retain whether an operation left directory durability uncertain.
A failed storage mutation marks that uncertainty; an expired reply cannot clear
it. The next preparation synchronizes it before returning success;
failed synchronization leaves the uncertainty set. This single durability flag
is not a key inventory or domain state. Normal unchanged preparation performs
no write, rename, link creation or file/directory sync. The implementation and
tests must account for errors from atomic slot publication as well as alias
creation and deletion. Never turn an I/O error into successful custody.

## Atomic activation and exact identities

The world identity remains `world_ref(Namespace, GenesisAnchor, Space)`.
Its dedicated authority is `agent_instance_ref(Namespace, GenesisAnchor,
physics_authority)`; its controlled avatar is a distinct authored agent instance
in that same world, explicitly bound to a stable body ID and camera mount.
The human retains their current anchored acting-agent identity. Body identity
is `(WorldRef, BodyId)` with monotonic structure/body revisions. Other spaces
use their own references, gravity, budgets and permissions.

Before native activation, publish inactive helper source using the previously
reviewed ordinary per-predicate editor procedure. Preserve existing source and
scene clauses. Author explicit preparation/assignment grants, then perform the
read-only key preparation on the intended destination. No broad node authority
or key export is required. The prepared public key is input to one complete
signed transaction that checks the exact world identity and expected inactive
configuration and commits:

- initial host/key assignment through `goal(agent_hosted(...))`;
- physical classification, enabled selection, initial run/structure/allocator;
- per-world gravity, timestep and body/geometry/control allowances;
- explicit collider shapes and baseline poses, including openings, roof and
  console for the first real acceptance world;
- avatar class/body definition, grounded movement, camera local pose/orientation;
- the human's view/control grants and exclusive initial control binding through
  `physics_control_agent/4`, plus narrowly scoped authority signing/entry grants.

Use existing shared shape validation for every body; visual GLBs and picking
bounds never provide collision authority. The complete configuration must be
measured against signed goal, parser, symbol, invocation, diff and sealed-plan
limits before any real submission. If it exceeds an admission allowance, fix
the policy ownership through the applicable gate; do not split this transition.
An authored configuration can use existing functions and source-edit operations;
do not add a general program loader or duplicate physics validation.

Initial committed placement is distinct from native installation and mechanical
settlement. Test occupied spawn and reposition against existing failure/status
semantics; do not infer durable free-space facts from a live query. Keep observer
travel separate from body commands and tracked head offsets. Controlled travel
stays unavailable until the exact installed run/body fences are ready.

Source-owned live colliders continue through `space_place/3`,
`physics_edit_definition/3`, `space_withdraw/3` and the already implemented
atomic source/destination consequences. No manual re-adoption, recipe pinning,
polling or extra propagation service. Current world fencing and per-predicate
OCC remain conservative.

## Failure and recovery

Read-only custody preparation may leave a reusable encrypted key after expiry
or cancellation; that key grants no domain authority. It may be read again at
the same exact epoch without creating a new key. This is not write resubmission.
Concurrent host initialization competes on the existing absent host/key predicate
versions; only one assignment commits. Concurrent revocation, assignment or
configuration changes invalidate ordinary proof dependencies. A successful key
read is not a reservation of later assignment permission.

Any uncertain activation/configuration write is resolved by its original signed
operation identity. Expiry and missing rows are not rejection. Failed atomic
configuration leaves no partial host or collider changes; encrypted staged
custody remains inert. Ontology/runtime recovery restores current committed
configuration and exact activation custody through existing owners, without
historical reaction replay. Disabling/revocation and body withdrawal use their
existing guarded transitions; no generic inter-simulation handoff is introduced.

## Verification and release boundary

First add failure-before coverage for initial signed preparation, unrelated
caller, wrong destination/history, missing/revoked permission, staged grant,
write/reaction/verdict contexts, duplicate output binding, stale epochs and
deadlines. Exercise the real vault and signed ingress, not a fake key service.
Measure repeated preparation with actual write/sync traces, positive controls
for a real key change, alias-only crash recovery and uncertainty after storage
failure. Retain failures and true child exits.

Then verify complete atomic activation from a never-physical existing world in
at least two distinct identities, including a non-lobby world and a nonphysical
control. Cover concurrent initialization/edit/withdrawal, rollback, permission
revocation, runtime recovery, signed normal views and stale body/run fences.
Existing focused regression suites continue to cover live collider sources,
controls, recovery and subscription invalidation. Fixtures do not establish real
desktop acceptance or remote-network unchanged-work evidence.

Have Fable review the implementation and exact test results; independently
resolve findings. Run the standing clean sequential release gates, freeze the
tree, and use the existing commit/release authority with one server writer.
Use the authorized candidate refound if deployment needs it. Establish the
signed identity/history baseline after release and retain before/after evidence.
Only the real ordinary signed view and a real committed remote collider change
can close the remaining acceptance, with full results recorded on the tracker.
Headset landing/contact/comfort and durable door consequence acceptance remain
the separately tracked tasks; this work does not claim them.

### Clean release boundary (Yan's clarification)

Yan explicitly requires a clean replacement and authorizes refounding the
candidate ledgers if needed. No compatibility branches, old/new policies or
migration machinery will be implemented. Deploy one compatible release through
the existing single release owner. If existing founded source requires a refound,
use that authorization and establish a fresh signed acceptance baseline afterward.
A package edit alone still does not change retained ontology source. Preserve the
current identity/history when a refound is unnecessary; do not wipe merely to
simplify a test. The separate main network remains outside the candidate scope.

Deployment inspection found the existing local vault disabled in Nomad's node
configuration. Enable it through that configuration and provision its separate
32-byte private unlock file before node startup, on the same durable node volume.
Use one shared prestart script for compute nodes and isolated cloud directories;
never replace a present key. Sync publication and reject insecure, malformed or
symlinked files. Keep the network vault provider disabled. No agent key, assignment
or physics authority is created by this infrastructure setup.

# Godot and seven-foundation contract

This is the M0 implementation contract for [QUO-60](nimbalyst://QUO-60) and
[QUO-61](nimbalyst://QUO-61). The shared tracker owns status and scheduling.
This document specifies the replacement; it does not claim that the seven
foundations, onboarding journey or recursive physics are installed.
The [source audit](evidence/godot-m0-20261027/ontology-audit.json),
[retirement map](evidence/godot-m0-20261027/retirement-map.md), and
[qualification evidence](evidence/godot-m0-20261027/README.md) freeze its inputs.

## Authority and exact identities

Keep Prolog as the domain and policy owner. Continue using signed goals,
instance assertion, committed operation guards, atomic multi-ontology
writes, reactions, direct-effect custody and existing recovery. Loading decided
state does not repeat creation or replay historical reactions. Godot renders
descriptors and submits operations; no client fact store or new executor is
authorized by this contract.

An ontology is the exact pair `ontology_ref(Namespace, GenesisAnchor)`. Actor
references add an instance. Keys prove control; they are neither the actor nor
its storage. Root is the configured bootstrap exception and is not a catalogue
row. The founded network is root plus seven catalogue entries: the six this
contract froze and `quod:names`, added on 2026-11-13 (Yan). The count is not a
limit: more system ontologies may be added, and reaching ten would not be a
problem (Yan, 2026-11-17).
Node identities, private user histories and independently selected storage
histories remain ordinary instances outside this shared count.

| Namespace | Sole domain owner | Source composition, in this order |
| --- | --- | --- |
| `quod:root` | Catalogue, foundation creation/admission, root resource policy | `quod_root.pl`; optional `root_licence.pl` |
| `quod:node` | Enrollment/allocation and execution/hosting policy | `quod_node.pl`; frozen `node_instance.pl` template |
| `quod:agent` | Agent class and hosting/recovery/action vocabulary | `quod_agent.pl`; the two hosting derivations remain in instance owners |
| `quod:gui` | Portable components, exact unit algebra, scenes, model composition and inspection vocabulary | `quod_gui.pl`, `gui_measure.pl`, `gui_scene.pl`, `gui_tools.pl`, optional `gui_materials.pl` |
| `quod:controllers` | Device descriptions, capabilities, roles and binding validation | `quod_controllers.pl` |
| `quod:space` | Space class, slots, extent, admission, entry and space forms/Eidolons | `quod_space.pl`; optional `space_physics.pl`, `space_terrain.pl`, `space_hinged.pl`, `space_environment.pl` templates |
| `quod:user` | Human/personal-agent classes, setup, instructions, signup policy and private receipts | `quod_user.pl`; signup returns facts, ACL clauses and reactions as terms |
| `quod:names` | Personal and world names: the name tables and drawing a name from them | `quod_names.pl`; founded through the ordinary lifecycle, then listed in root |

The required compositions are authoritative. Optional filenames describe
their later owner consolidation. The retirement map records the original
inputs; M1a evidence records the bytes actually installed. A composed file does not create another ontology. The generic startup
base is `common_predicates.pl`, `construction.pl`, `material_policy.pl`,
`gui_forms.pl` and `geometry_schema.pl` plus the existing governed predicate modules. The GUI file
compiles forms at their owners and binds offered operations; it installs
no application state, entry permission or lifecycle handler. The geometry file
validates supplied authored body data and coordinate allowances; it selects
no world, physical presence, budget or admission policy. Package
hashes for that base and runtime are part of every qualification, since they
are read by committed projections and are not fixed by a genesis anchor alone.
These are ordinary interpreted base clauses in each owner's versioned table:
complete source reads include them, and authorized local edits retain the
existing exact-baseline, transaction and recovery semantics. Moving a clause
does not pin it by a new ontology anchor or make it globally immutable. Changed
base text requires the exact runtime/package hashes during reconstruction;
old founded histories containing the former inline definitions are not a
compatible starting state. Qualification uses fresh foundations. This contract
does not authorize upgrading or refounding an existing network.

The qualified server build uses Rust/Cargo **1.90.0**, rebar3 **3.26.0** and
OTP **28.5.0.2**/ERTS **16.4.0.2**, with the exact local builder image identity and
generated dependency inputs in the [server toolchain receipt](evidence/godot-m0-20261027/server-toolchain.json).
The earlier focused host run used OTP28.0.2; its generated parser path
annotations are not the current container artifacts. M1a must use the qualified
inputs/toolchain or requalify affected evidence. The independent clean-client
Godot/.NET/toolchain pins remain in the qualification index.


Pin dependencies to the exact anchors returned by founding, never names alone:
`R`, `N`, `AClass`, `G`, `C`, `S`, `UClass` denote 32-byte anchors in the founding
receipt. `AClass` is the shared agent-class anchor; personal A below is a distinct
entity reference. These symbols are output slots, not invented genesis hashes. Random
genesis incarnations make future anchor bytes unknowable before founding.
The [actual M1a receipt](evidence/godot-m1a-20261027/founding-receipt.md) binds all
seven symbols to real bytes, with complete source/profile and private account
receipts. Subsequent founding records its own returned anchors before crediting
a fresh foundation. Old anchors from the frozen catalogue cannot be reused for
changed definitions.

| Consumer | Exact dependency binding in its founding terms |
| --- | --- |
| Every system/instance | Configured root `ontology_ref(<<"quod:root">>, R)` and identical hashed common/runtime artifact |
| Controllers | `gui_vocabulary(<<"quod:gui">>, G)` for its portable appearance descriptions |
| Space and space-capable storage | `measure_vocabulary(<<"quod:gui">>, G)`, `rendering_vocabulary(<<"quod:gui">>, G)`, `modelling_vocabulary(<<"quod:gui">>, G)`, `gui_vocabulary(<<"quod:gui">>, G)` |
| User class and private user instances | The preceding GUI pins, `controllers_vocabulary(<<"quod:controllers">>, C)`, `space_vocabulary(<<"quod:space">>, S)`, `agent_vocabulary(<<"quod:agent">>, AClass)` |
| Node instances | Class `ontology_ref(<<"quod:node">>, N)` and the existing exact root creation-policy delegation |

`convert/4`, `signature/2`, `sum/3`, unit/prefix facts and rational reduction
move intact from measure to GUI's exact value vocabulary. This preserves full
SI/exact arithmetic, including material units, rather than adding a second
length converter. Rendering validation and `model/2`, `place_model/5` move to
GUI's scene vocabulary. Public query selectors must be merged explicitly;
concatenating the old ACLs or old `acl_sovereign` declarations is invalid.
Controller/device classes and their Eidolons move from lobby to controllers;
private preferences call `controllers_vocabulary/2`, not lobby. Old
`quod:measure`, `quod:rendering`, `quod:modelling`, `quod:lobby`, lens and Prolog
tool catalogue lookups must all be rebound, including the common
`class_eidolon` source/inspection recipes. GUI's retained tooling uses the
existing source permission owner; moving a recipe grants no source access.
GUI has no reverse dependency on space or a private user, so this graph is acyclic.

## Private composition and disclosure

The user's ontology holds the qualified human `me` and personal agent
`personal` memberships, their slots and keys, the seven vocabulary pins, ACL
clauses, the completion reaction and the two hosting derivations. Signup returns
that exact authored term list through the existing creation owner. The human key
remains client-held; A's private key stays in the existing agent vault.

Class behavior resides at `quod:user`, `quod:agent`, `quod:gui` and `quod:space`.
The storing ontology's ACL governs their scoped reads and writes. Space creation
asserts `instance_of(quod:space:space, Id)` in the selected storing ontology;
slots remain there. The shared assertion hook reads class policy and slot
declarations at their owners. Class references identify those owners; moving an
instance reference does not move its storage. Changing U's slots or per-instance
ACLs cannot modify the space owner's class declarations. No source digest or
pasted class definition is involved.

The user foundation contains signup receipts and must therefore remain
source-restricted like current signup. Root's `system_source_access/2` must
exclude the exact user foundation as well as root for ordinary public readers.
Human vocabulary queries may be explicitly public; complete source reading
cannot be made public with a per-predicate filter. Do not copy the user's private state,
instruction, HUD, receipt or preference facts into GUI/controllers/catalogue.
User-instance source admission remains owner-governed. Shared device defaults
are public; actual settings, signed instruction associations and the user's ontology are
private. Runtime hardware samples remain transient.

M1a's production fixtures must use two unrelated humans, an unrelated agent
and a public system-source reader. They must refuse raw/source/lens reads and
writes of signup receipts, state in the user's ontology, U→A instruction associations,
pending HUD questions and controller preferences. Public GUI/controller/space
views must not contain those facts, keys, tokens or private target enumeration.
Wrong-anchor, alternate-principal and public-source wrapper probes must fail
before returning content. Revoke a source/view grant while subscribed and prove
that retained content is withdrawn, without an empty valid-scene fallback.

## Ordinary onboarding and storage

Normal signup has the following Prolog composition. U, A and S0 are stable
exact references, not lobby navigation aliases. S0 uses the ordinary space
class/defaults: name `<<"Space">>`, 10 metres per axis, owner U, no containing
space. A starts inside S0 at the authored origin. The interior is black with
available controllers and accessible GUI. No floor, sky, terrain, pilot body or
simulation is required. The eventual dedicated user-lobby subclass is outside
this slice. Every ordinary space may be parentless.

The onboarding recipe explicitly selects the now-existing private account
ontology `ontology_ref(UserNamespace, UserAnchor)` as S0's storage, and records
that exact selection in its pending/complete setup state. This is a deliberate
selection for automatic onboarding, not a universal space-storage default.
Signup policy authorizes that choice; show it in the account setup description.
After U's genesis is committed, that target is an existing ontology. Additional
spaces continue to offer the existing creation-storage discovery and explicit
exact-target selection. The current chooser supplies catalogue identities,
the selected human's ontology and exact ontologies from depicted device
subjects; a returned or selected exact subject can open its own target directly.
In the replacement this includes the account's composed storage and the
current space's storage when known. Permitted foreign targets retain the same
signed route and class discovery, rather than a same-ledger restriction.
Discovery is advisory and incomplete; a visible
catalogue row, host or owning U never grants creation. No new ledger is founded
for S0, S1 or S2 merely because they are spaces.

Replace `lobby_provisioning`, `provision_lobby`, `lobby_options`, lobby pins and
lobby-owned create grants with user-owned setup state and class policy in the
private composition. The create permission admits the exact instructed A and
default/explicit U ownership subject to target policy. Source `space_enter` and
destination `space_admit` remain independent committed checks. No blanket
`can_invoke(_, A, _, _)` grant or root-only Create route is introduced. The
existing user/agent instruction, form binder and selected storage proof must
all participate under their existing authority.

The existing lifecycle imposes two durable boundaries:

1. Signup/allocation creates U's exact history and records its receipt plus
   the executor-bound node hosting intention through root's existing action
   and atomic transaction. U genesis contains pending setup and the exact
   authored terms; loading does not execute setup. Resolve this original
   operation before beginning dependent setup; a lost reply never causes a new
   token, replacement U or new create request.
2. U's explicit setup preparation uses the existing custody read. It returns an
   executor-signed receipt binding exact A, prior assignment, destination and key.
   The class-owned setup form accepts that pair. Its goal executes in the user's
   ontology and verifies the receipt without a live vault lookup. In one
   transaction it hosts A through `quod:agent`, asserts S0 with owner U, runs
   `quod:space::goal(inside(S0, A, transform(0,0,0,0,0,0)))`, records the exact
   U/A/S0 result, marks setup complete and acknowledges the signup receipt.
   Preparation requires successful unplaced U and A reads; failed reads are not
   absence.

The source proof authenticates U and runs the setup form under its committed
ACL. Class/create, A-entry and S0-admission permissions are checked at their
owners. S0's newly asserted membership uses its original class policy until
commit, without staged per-instance overrides. Setup places the existing A
through the ordinary action; no constructor or initial-occupants part builds or
places instances. Each later creation uses the same assertion, slots and action
machinery under its selected storing ontology's ACL.

If private custody or any receiver cannot prepare, the existing transaction
rolls back the complete setup. A committed setup with an unavailable runtime
stays complete/recovering, rather than provisioning replacements. The client
durably retains the exact signed operation before dispatch. Recovery resolves
the original receipt/results after loss/restart, even if S0 was subsequently
removed; it does not run construction, resend an uncertain instruction or replay
historical reactions. Initial U creation and later setup cannot be fused across
the not-yet-existing U owner by inventing another founding framework.

## GUI and signed operations

Retain the portable `component/4`, `operation_view/9`, `gui_operations/2`,
`gui_operation_bind/7` and `gui_operation/6` contracts. M1b's offered operation
is controller-preference Save/Reset on U through distinct A. Keyboard/mouse
GUI operation belongs in M1b. New space creation uses the same panel in M2:

```prolog
gui_operations(entity_ref(UserNs, UserAnchor, me), Views).
gui_operation(entity_ref(UserNs, UserAnchor, me), controller_settings,
              Revision, controller_save, Fields, Results).

gui_operations(class_ref(StorageNs, StorageAnchor, space), Offers).
gui_operation(class_ref(StorageNs, StorageAnchor, space), create,
              Revision, space_create_submit, Fields, Results).
% Results = [result(space, entity_ref(StorageNs, StorageAnchor, GeneratedId)),
%            result(location, placed(S0, Transform)), result(owner, U)].
```

These are shapes; real revisions/fields are taken from the signed offered view,
never invented or prebound output IDs. The full fixture mapping records actual
production tests and public signing bytes. Preserve UTF-8 byte lengths,
base64url bytes, parser 3 and the existing mode tags. Deadlines are absolute
uint64 values; arbitrary Prolog integers remain exact term text/BigInteger,
not Godot `double` or signed-64 coercions. U signs the attempt-now instruction;
only governed custody can sign A's exact execute bytes. A's expiry cannot
exceed U's. Revoking U blocks new instructions; already accepted A work retains
its settled semantics. Cancel unsent/opening work through existing owners;
uncertain admitted work keeps its original identity and outcome resolution.

## Space exterior and recursive exposure

M2 creates S1 near A inside S0, renders its selected default exterior through
the shared scene path, and stays in S0. M3 enters S1 with the same A, creates
S2 using the same operation, then enters S2. Each entry atomically withdraws
the old assignment/admission and admits the new one with the existing slot
revision/conflict rules. Do not move the camera first and infer entry success.

Exterior is a viewing purpose, not a mesh type. The default recipe is the
shared fixed-size marker described in [spaces](spaces.md): half a metre
whatever the interior measures, finite or infinite. It is a representation; it
creates no floor, collision wall or simulation. The real size is shown from
inside by the interior walls: a real-size outline centred at the space's local
origin, with X/Y/Z extents equal to its finite interior dimensions. Resolve
exact unit conversion in Prolog. An infinite extent has no finite outline:
that choice must explicitly report unavailable and never invent a finite bound.
Sub-millimetre rational extents also must not be rounded. The shared edge-only
kinds `wire_box` and `corner_box` carry positive reduced integer/rational
millimetre dimensions until conversion at the render boundary. Each has twelve
edges independently of its dimensions, with no space-specific engine branch.
The shared scene path qualifies asymmetric extents, rotation, odd/rational
dimensions and picking.

For a contents exterior, a selected space exposes its contents recursively.
If S0 contains S1 and S1 contains S2 and both select contents, S2's contents
are visible from S0 without entry. Continue at every contents level. Mesh or
marker selection terminates expansion at that occurrence only. Do not fall
back to either when contents disclosure or a dependency is unavailable.

The D5 subset required in M3 is:

- The source's exact `entity_ref(Ns, Anchor, Id)` remains the depicted subject.
  Use a distinct occurrence path including the complete anchored edge path;
  two independent displays may show the same source. Deduplicate a direct
  placement/display duplicate, but do not globally collapse independent paths.
- Each contents exposure supplies its source frame, selected recipe/revision,
  allowed exposed subjects and local-to-parent transform. The space owner
  authorizes exposure; each source authorizes its view. Display/admission does
  not grant source read, invocation, ownership or physical presence.
- Preserve parent-before-child group/relative transforms. For column vectors,
  `T(S0←entity) = T(S0←S1) · T(S1←S2) · T(S2←entity)`.
  Use the existing right-handed millimetre/degree model, one conversion to
  engine metres, and the established rotation order at the adapter boundary.
  Do not add Euler angles or separately flatten positions. No implicit scale
  warps or conversion of infinite interior extent to exterior size is allowed.
- The signed view retains exact navigation, containment, recipe, source-access,
  model, physics-run and exposure dependencies at their verified heights.
  Subscribe before snapshot through existing view/runtime owners. Changed
  dependencies invalidate only affected consumers; revocation withdraws their
  exposed data. Missing/denied source does not become a successful empty space.
- Detect cycles using an ancestry stack of exact subject plus representation
  purpose at each expansion. A repeated ancestor produces an explicit cycle
  occurrence without recursively exposing it. Independent repeated branches
  remain valid. Resource limits remain Prolog policy; use explicit truncation/
  refusal under that policy, never a hardcoded one-level or depth cap.

The [recursive fixture](evidence/godot-m0-20261027/recursive-contract.json)
fixes asymmetric S0/S1/S2 transforms, exact subjects, independent appearances,
source denial/revocation, cycle and wireframe expectations. M0 qualifies the
portable nested scene contract; M3 must prove live recursive source expansion,
dependency changes and applicable physical behavior through production owners.
Broader ontology editing/D6 and other unimplemented D5 work stay open.

## Physics agreement and demonstrated gap

The `quod:space` placement and withdrawal actions, source definition
delegations, live body revisions, `quod_runtime` retained source readers,
`quod_physics` native owner, run/structure fences and authenticated control/
observation remain authoritative. Unsimulated ordinary spaces allocate nothing.

The M0/M2 baseline profile selects one physics actor and native world per independently
enabled space, binds a live body to its direct destination and assignment,
requires foreign-source subscriptions, and opens one visible-world viewer.
That baseline cannot compose independent S1/S2 worlds into S0 and provide
cross-boundary contacts. A visually flattened tree with independent colliders
does not satisfy the requested single-space behavior. This is a demonstrated
adapter gap, not a new domain/consensus problem.

M3a must extend the existing physical selection/binding model with an explicit
simulation-domain/frame mapping selected by Prolog. Spaces in one continuous
physical exposure component use one existing authority/native world, with
composed frame transforms and one body per exact physical entity/assignment.
Keep direct domain containment unchanged. A display-only copy is not another
physical body; require an explicit source delegation and destination physical
admission for physical exposure. A second decorative display does not duplicate
mass, contact or control. Dynamic body poses transform consistently into each
view; native contacts/control and displayed geometry use the same composed
frame and current revisions. Gravity, timestep, scale and body allowances must
agree for the selected domain; incompatible independently enabled runs require
an explicit governed transition or visible refusal, never visual-only success.

Exposure/admission changes must atomically bind/remove the corresponding
source delegates and destination body/structure consequences through existing
multiwrite. Update affected resources through exact installed-state notices.
Pause affected simulation while a required verified source advances; unrelated
changes reuse the native resource and reader. No polling, request-time rebuild,
shadow geometry owner or client collision authority is added.

Joining previously active independent simulations is not authorized by merely
selecting contents or editing membership: unresolved activation/rest/hinge
custody, controlled bodies, run generations and checkpoints must be resolved
under existing transfer protections first. M3 tests must include a shared-domain
S0/S1/S2 fixture with nonidentity transforms, a body traversing an exposed frame
boundary/contact, source definition update, revocation, stale run/control
rejection, restart and no duplicate physical body. Also test incompatible
independent runs refusing explicitly. This required adapter subset is part of
M3; general transfers between independent active simulations remain separate.

## Reproducible founding recipe

M0 records this sequence; M1a executes it from clean local genesis and M5 reuses
the resulting source manifest/recipe. Use existing `create_ontology/3` with
`source_file`/`terms`/`external_predicate_modules` options and root's governed
creation action. Source bytes, ordering, compiled predicate-module hashes,
runtime/common source hashes and lockfiles must all be retained. A filename or
catalogue row does not grant source execution or founding authority.

Private-account preparation uses ordered `source_file(Path,Sha256)` options.
The existing source preparation owner resolves its normal consult path, reads
one buffer, checks the raw SHA-256 and parses those same bytes. A mismatch
returns `source_hash_mismatch(Index)` before founding. This keeps a complete
private source program out of proof-answer transport while retaining the exact
reviewed source recipe and existing material policy. Recovery uses the decided
genesis; it never reopens these packaged files.

1. Load the exact root seed/common/runtime artifact with the existing create
   configuration into a new disposable directory. Record R, the node key's
   public identity and admitted root executor. This is clean genesis, never
   reset/recovery of old storage. M0 performs no network reset.
   Root's exact founding module profile is
   `[quod_directory_predicates, quod_ontology_predicates]`, as selected by the
   existing bootstrap owner, not a per-user native capability setting.
2. Through root, found node from its main source plus
   `node_identity_template(BytesOfNodeInstance)`. Use the existing
   `quod_agent_predicates` module profile. Verify the exact genesis and module
   manifest; atomically register `system_ontology(<<"quod:node">>, N)` and
   `ontology_creation_policy(<<"quod:node">>, N)` in root.
3. Let the existing namespace-manager/node-actor enrollment subscribe and bind
   its original allocation. Verify pointer, sole active key, exact Ref and
   self-hosting facts. Keep current deadlines and no-resubmission semantics.
   Node identity genesis uses the existing
   `external_predicate_modules([quod_ontology_predicates])` recipe, with
   `node_ontology`, `instance_of(node,me)`, the applicant's active key and exact
   node-class hosting delegation. This differs from the node class profile.
4. Found agent with `quod_agent_predicates`; found GUI from its ordered composed
   sources with `quod_agent_predicates` and `quod_gui_predicates`; found
   controllers with its exact G terms and `quod_agent_predicates`; found space
   with its exact G terms and `quod_agent_predicates`. Register each exact anchor
   in root only after verified ready. No obsolete seed is founded temporarily.
5. Found user with exact AClass/G/C/S and `signup_host` bound to the verified
   enrolled node, using `quod_agent_predicates`. Signup returns terms only:
   qualified memberships, slots, pins, ACL clauses, the completion reaction and
   the two hosting derivations. The creation policy validates the complete
   authored term list and options, including clause variables as clause data;
   names, remaining options and material admission retain their existing checks.
6. Atomically register the exact user catalogue/creation policy and node's exact
   `ontology_hosting_policy(<<"quod:user">>, UClass)` delegation. Keep the
   hosting write at the enrolled node, tied to the existing effect executor.
   Root administrator/source-edit authority alone is not a creator grant.
7. Verify root plus seven unique catalogue identities, zero rejected/conflicting
   anchors, readiness, module profiles and new node enrollment. Record endpoint,
   certificate SHA-256/CA, expected hostname, network R and all exact catalogue
   pins as public client configuration. No private key/unlock bytes enter it.
8. M1a runs normal signup/setup, privacy and GUI views through signed production
   clients. Resolve lost operations from original bytes, restart from the same
   histories, prove U/A/S0 identity stability and no constructor/reaction replay.

Foundation and instance module profiles inherit the existing registered common
bridges (construction, identity, ontology lifecycle, physics etc.); they are not
new per-foundation Erlang engines. Retain source-module hashes from ordinary
founding preparation. If the consolidated public component selections require
different ACL shapes, change their owning Prolog selectors and tests in M1a.

## Reduction and archival accounting

The recorded base has 50 Prolog sources, 8,595 physical lines and 6,508 nonblank,
non-whole-comment lines. The qualified prerequisite adds five physical policy
lines, of which one is noncomment. This physical metric is reproducible but is
not an AST statement count. M5 targets 24 active packaged production sources
plus seven test-only source fixtures; no more than 5,700 active production
nonblank/noncomment Prolog lines (at least 809 fewer than the integrated 6,509).
Keep independent optional material, naming, licence, terrain, physics, FIPA and
question obligations; source relocation alone cannot meet the line target.

Report active production, test fixtures, archived originals and total retained
lines separately. Archive superseded Prolog sources at
`outdated/ontologies/prolog/<old-basename>` and any superseded Erlang ontology
source at `outdated/ontologies/erlang/<old-path-under-src>`. Both roots are
outside compiler source dirs and `priv`. Do not place archives below `src` or
`priv`, since recursive compilation/resource packaging could reactivate them.
Release/Docker packaging must use the active manifest and exclude this archive;
the Erlang application module list and predicate-module manifests must contain
only active modules. Update founding component lists, every source loader and
all source-path fixtures before moving code. Reject archive paths in governed
packaged-source selection; absolute arbitrary source paths remain governed by
the existing creation authority, not an archive auto-loader. No M0 move occurs.

No whole Erlang ontology-domain implementation is presently demonstrated
superseded: the source map retains the existing runtime and governed bridges.
Do not archive a consensus, GUI, physics or lifecycle owner just because an old
namespace disappears. Later proven superseded Erlang sources require exact
callers/tests and the destination/exclusions above in the same replacement
scope. Archived sources are retained history, never an active alternative.

The former `quod_space.pl:space_entity_pose/4` helper is retained verbatim at
`outdated/ontologies/prolog/m3a-space-entity-pose.pl`. Recursive projection now
uses `space_subject_binding/3` and `space_scene_pose/6` for both direct and
independent appearances. Its only remaining caller was the body-binding test;
that test now queries the shared binding owner and retains missing, duplicate,
stale-assignment and authored-pose refusal checks. The fragment is outside
`src` and `priv`, absent from founding/loaders and release/Docker inputs.

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
assertion construction, committed operation guards, atomic multi-ontology
writes, reactions, direct-effect custody and existing recovery. Loading decided
state does not run constructors or replay historical reactions. Godot renders
descriptors and submits operations; no client fact store or new executor is
authorized by this contract.

An ontology is the exact pair `ontology_ref(Namespace, GenesisAnchor)`. Actor
references add an instance. Keys prove control; they are neither the actor nor
its storage. Root is the configured bootstrap exception and is not a catalogue
row. The target is root plus six catalogue entries, not seven total ledgers.
Node identities, private user histories and independently selected storage
histories remain ordinary instances outside this shared count.

| Namespace | Sole domain owner | Source composition, in this order |
| --- | --- | --- |
| `quod:root` | Catalogue, foundation creation/admission, root resource policy | `quod_root.pl`; optional `root_licence.pl` |
| `quod:node` | Enrollment/allocation and execution/hosting policy | `quod_node.pl`; frozen `node_instance.pl` template |
| `quod:agent` | Agent class and hosting/recovery/action vocabulary | `quod_agent.pl`; `agent_instance.pl` is composed in actual instance owners |
| `quod:gui` | Portable components, exact unit algebra, scenes, model composition and inspection vocabulary | `quod_gui.pl`, `gui_measure.pl`, `gui_scene.pl`, `gui_tools.pl`, optional `gui_materials.pl` |
| `quod:controllers` | Device descriptions, capabilities, roles and binding validation | `quod_controllers.pl` |
| `quod:space` | Space class, construction, extent, admission, entry and space forms/Eidolons | `quod_space.pl`; optional `space_physics.pl`, `space_terrain.pl`, `space_hinged.pl`, `space_environment.pl` templates |
| `quod:user` | Human class, signup/allocation policy and private signup receipts | `quod_user.pl`; frozen private `user_instance.pl` composition, optional `user_names.pl` |

The required compositions are authoritative. Optional filenames describe
their later owner consolidation. The retirement map records the original
inputs; M1a evidence records the bytes actually installed. A composed file does not create another ontology. The generic startup
base remains exactly `common_predicates.pl`, `construction.pl`,
`material_policy.pl` plus the existing governed predicate modules. Package
hashes for that base and runtime are part of every qualification, since they
are read by committed projections and are not fixed by a genesis anchor alone.

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

The private U ontology composes `user_instance.pl`, `agent_instance.pl`,
`quod_space.pl` and `gui_instance.pl`, with the exact pins above. It contains
human `me` and agent `personal`, with different active keys. The human key
remains client-held; A's private key stays in the existing agent vault. Hosting,
custody and the containing ontology do not merge those identities.

`quod_space.pl` in U is the reviewed executable schema and instance-operation
component from the pinned space recipe. It acts on the facts owned by that
storage ontology; it does not create a second catalogue foundation or copy
mutable state from S. The S pin selects the shared vocabulary/template revision
and its exact source hash; it is not a constructor import or class alias.
Stage 1 still constructs from locally composed class code in the selected
storage ontology. Thus its local `space` class has that storage's exact
`entity_ref(StorageNamespace, StorageAnchor, space)` identity, distinct from
`entity_ref(<<"quod:space">>, S, space)`. References to either class or its
Eidolon must retain the actual owner; matching predicate names do not merge
them. There is one authored implementation, with separately owned local class
and instance facts, rather than competing mutable copies of S's shared state.
M1a must check the original composed source against the pinned recipe, preserve
Stage 1 construction and foreign-storage operations, and show that changing U's
local facts cannot change S's class/template state. It must refuse missing or
mismatched source pins instead of substituting another implementation. Private
state remains with its actual owner, including when storage is foreign to U.

The user foundation contains signup receipts and must therefore remain
source-restricted like current signup. Root's `system_source_access/2` must
exclude the exact user foundation as well as root for ordinary public readers.
Human vocabulary queries may be explicitly public; complete source reading
cannot be made public with a per-predicate filter. Do not copy private account,
instruction, HUD, receipt or preference facts into GUI/controllers/catalogue.
User-instance source admission remains owner-governed. Shared device defaults
are public; actual settings, signed instruction associations and accounts are
private. Runtime hardware samples remain transient.

M1a's production fixtures must use two unrelated humans, an unrelated agent
and a public system-source reader. They must refuse raw/source/lens reads and
writes of signup receipts, user account state, U→A instruction associations,
pending HUD questions and controller preferences. Public GUI/controller/space
views must not contain those facts, keys, tokens or private target enumeration.
Wrong-anchor, alternate-principal and public-source wrapper probes must fail
before returning content. Revoke a source/view grant while subscribed and prove
that retained content is withdrawn, without an empty valid-scene fallback.

## Ordinary onboarding and storage

Normal signup has the following Prolog composition. U, A and S0 are stable
exact references, not lobby navigation aliases. S0 uses the ordinary space
class/defaults: name `<<"Space">>`, 100 metres per axis, owner U, no containing
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
   and atomic transaction. U genesis contains pending setup and frozen source,
   not a constructor occurrence to replay on load. Resolve this original
   operation before beginning dependent setup; a lost reply never causes a new
   token, replacement U or new create request.
2. U's explicit setup action prepares A's key using the existing custody read.
   The read also returns an executor-signed receipt binding the exact A, prior
   assignment, destination and key. Setup verifies this immutable receipt against
   its proof-bound executor without a live vault lookup. Then in one transaction
   it assigns A's host/key, constructs S0 through Stage 1
   with explicit owner U, places A in S0 through `space_place/3` during that
   active construction, stores exact U/A/S0 results and marks setup
   complete. It consumes the signup receipt in that same multi-owner transition.
   Setup requires successful unplaced U and A reads, not failed/missing
   locations interpreted as absence. The ordinary constructor's near-agent
   lookup sees its authenticated caller U at this step; explicit owner U avoids
   the ordinary A-only owner default. No second reaction queue is added.

The source proof authenticates U and uses a narrowly declared setup operation
guard permitting this specific construction on U's behalf; ordinary creation
through A retains the existing `personal_agent_owner/1` contract. This is
Prolog composition work in M1a, not a change to generic constructor semantics.
Key preparation is not enrollment or placement. A staged grant cannot authorize
its own proof: class/create, A-entry and S0-admission grants must already exist
in the committed template policy and authorize the `construction(...)` scope.

There is a concrete Prolog composition gap: the current space constructor has
no initial-occupants part, and placing A after S0's assertion returns would
lose its active construction authorization. M1a adds an optional declared
`initial_occupants` part to the shared space constructor, using existing
`have_part/2`, `build_plan_part/3` and `space_place/3`. Setup supplies the exact
existing A reference; this part does not construct another agent. It validates
the references and places them before the existing assertion context ends.
Absence means the ordinary empty-space behavior. This adds no subclass,
Erlang constructor executor, staged permission grant or replay hook. Preserve
ordinary Stage-1 inputs/defaults and all existing failure/rollback cases.

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

Exterior is a viewing purpose, not a mesh type. Retain the small solid cube as
one default recipe. Add a selectable **wireframe exterior**: a real-size box
centred at the space's local origin, with X/Y/Z extents equal to its finite
interior dimensions, transformed into the containing/displaying frame. The
100-metre default therefore spans −50 to +50 metres per axis, not half a metre.
It is a representation; it creates no floor, collision wall or simulation.
Resolve exact unit conversion in Prolog. An infinite extent has no finite box:
the wireframe choice must explicitly report unavailable for that extent and
offer the other actual Eidolons; it must never invent a finite bound or silently
substitute the cube. Sub-millimetre rational extents also must not be rounded.
The M0 integer-mm `mark/7` box plus `surface/5` vocabulary lacked an edge-only
box with arbitrary exact-rational dimensions. The shared `wire_box` kind carries
positive reduced integer/rational millimetre dimensions until conversion at the
render boundary. It has twelve edges independently of its dimensions, with no
space-specific engine branch. M2 qualifies asymmetric extents, rotation,
odd/rational dimensions and picking through that shared path.

For a contents exterior, a selected space exposes its contents recursively.
If S0 contains S1 and S1 contains S2 and both select contents, S2's contents
are visible from S0 without entry. Continue at every contents level. Mesh or
wireframe selection terminates expansion at that occurrence only. Do not fall
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

The existing `space_place/3`/`space_withdraw/3` callbacks, source definition
delegations, live body revisions, `quod_runtime` retained source readers,
`quod_physics` native owner, run/structure fences and authenticated control/
observation remain authoritative. Unsimulated ordinary spaces allocate nothing.

The current profile selects one physics actor and native world per independently
enabled space, binds a live body to its direct destination and assignment,
requires foreign-source subscriptions, and opens one visible-world viewer.
It cannot currently compose independent S1/S2 worlds into S0 and provide
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
5. Found user with exact AClass/G/C/S, the frozen private account source composition,
   `user_source_directory` pointing only at the packaged reviewed sources and
   `signup_host` bound to the verified enrolled node. Use
   `quod_agent_predicates`. Its creation-policy function must validate the full
   ordered options and private template, not caller-supplied arbitrary source.
6. Atomically register the exact user catalogue/creation policy and node's exact
   `ontology_hosting_policy(<<"quod:user">>, UClass)` delegation. Keep the
   hosting write at the enrolled node, tied to the existing effect executor.
   Root administrator/source-edit authority alone is not a creator grant.
7. Verify root plus six unique catalogue identities, zero rejected/conflicting
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

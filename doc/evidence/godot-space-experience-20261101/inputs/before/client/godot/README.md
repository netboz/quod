# Clean Godot client

This Linux .NET client adapts Quod's signed protocol and portable GUI model.
Identity creation/import happens offline. Connect authenticates the original key,
recovers original account/instruction results and opens the ordinary black S0.
Offered forms supply their controls, fields, revisions and binder; Save/Reset use
the existing human instruction → governed personal-agent execution route.

```sh
python3 client/godot-tools/run.py --bootstrap --build
python3 client/godot-tools/run.py -- --profile /absolute/private/profile
python3 client/godot-tools/run.py --export
client/godot/dist/quod.x86_64 -- --profile /absolute/private/profile
```

The launcher pins the M0-qualified Godot4.7.2 .NET engine/export templates,
BouncyCastle2.7.0, SDK10.0.112 and runtime10.0.12. It does not load the old Quod
Rust core or GDExtension. Build tools and package caches stay under the ignored
client build directory. Distribute the complete self-contained export directory.

Active keys use a private0700 directory,0600 file, one writer lease, atomic
replacement, file/directory sync and read-back. They are plaintext active keys;
normal restoration has no backup passphrase. Encrypted portable backups use the
existing PBKDF2-SHA256/AES256-GCM format and a separate passphrase. Import targets
an empty profile; a damaged or uncertain store is never replaced silently.

Enter an HTTPS origin and, when needed, an explicitly trusted CA PEM. Certificate
chain, validity and hostname checks remain enabled. Endpoint changes disconnect
the current consumer. An imported key without an account reference first checks
its retained signup receipt; lookup failure cannot provision a replacement.
The setup description names the policy-selected existing account storage for S0.

On first run, **Create my key** stores a local identity; **Connect** then discovers
its account. The current capability determines the highlighted next action:
**Create my account**, **Review starting space storage**, or **Create my agent
and starting space**. Storage review is a read, and setup remains a separate
explicit action. Existing accounts skip completed provisioning. An imported key
with no recovered account cannot register a replacement. Server, public identity,
storage details and encrypted backup controls remain explicitly inspectable.

The authenticated session's absolute expiry retires its signed views and input.
**Sign in again** explicitly authenticates the same key and checks original work;
it never renews silently or replays a submission. Unsent operation drafts stay in
their existing native owner for this window, separated by network, principal and
exact offered subject. Changing that identity also clears prior displayed outcomes
and returned-subject actions; it never deletes their original stored work.
Invalid numeric text remains visible with its error instead
of acquiring a guessed slider value. Source drafts retain their existing durable
store. A process restart restores those durable drafts and original work, not an
unwritten generic form. Signing in after mapping withdrawal, and backup/import
through the separate modal window, remain desktop actions.

Native controls support keyboard focus/editing and mouse interaction. Closing a
form cancels local/opening work and retains uncertain signed work. Only explicit
original-outcome reads follow uncertainty or restart; reconnect never dispatches
saved work. Source inspection subscribes to its existing Prolog authorization
before reading a cursor snapshot, and withdraws content on invalidation or denial.
An exact selected subject exposes its ontology-authored representation choices
as labelled native buttons, grouped into views and action forms. The selected
button is marked; unavailable actions remain disabled. **Current space** derives
its context from the accepted navigation identity. Full subject and recipe
identities remain inspectable in the explicit details disclosure.
Exterior, permitted contents, offered actions and source tools retain that same
namespace, genesis anchor and entity. Representation choice never enters a space
or grants permission. A view opens presentation; an action opens the existing
form, whose authored confirmation button alone submits it. The representation
chooser is the single selection route, without a competing operation dropdown.
Operation forms keep their existing draft and controls
when another representation is opened. Contents reuse the shared recursive
projection and scene resources; unavailable dependencies withdraw that consumer.
World and selected physical views return delivery credit only after the same
scene adapter accepts their projection/frame. A depicted ontology keeps the
catalogue's flat identity only when its namespace and history match the mark.

The ontology-authored **Workbench** representation shows direct authored local class
inheritance and instance membership, with attributes of the selected exact node.
Yellow boxes/links represent classes/inheritance; blue spheres/links represent
instances/membership. Node labels, scene picks and the native node catalogue use
the same anchored subjects as offered operations and source inspection. Inferred
closure and arbitrary Prolog relations are not a graphical source model.

Workbench inspection uses readable fact captions, retaining the exact anchored
subject and fact in explicit details. **New class**, **Add text attribute** and
**Edit selected fact** reveal only their relevant native fields; **Back to
inspection** hides them without replacing their controls or discarding local
text. The source owner's current state explains read-only access, work in
progress and the original draft/preview/outcome alongside inspection.

Preparation changes the same per-predicate source draft. Inspect that text,
then use the existing Preview,
Save or Cancel controls; opening, selecting and preparing never commits. Exact
fact replacement/removal uses the original committed baseline. Membership removal
removes that authored fact only: it neither cascades nor deletes an entity's
history. Instance construction uses the class's existing offered action and its
generated identity. There is no new founding, ontology-to-space cast, graphical
policy editor or caller-chosen durable ID. Read-only ontologies use the same
scene and controls with mutations disabled. Compatible same-scope field and
selection inputs survive control refresh; withdrawal disables all actions, and
opening another ontology clears those local inputs. Layout never assigns or
moves a domain object.

**Inspect storage source** opens the selected catalogue/storage ontology even
when it offers no class operation. Ontology identity is independent of spatial
membership. Source workspaces use the existing native editor and predicate
catalogue; policy/interface/route lenses use the same complete UTF8 cursor reader.
System source remains read only. An authorized edit keeps its original committed
baseline and local draft. **Preview changes** stages the existing guarded proof;
**Save changes** accepts that original cursor once. **Cancel preview** does not
commit. Stale baselines are refused without replacing the dirty draft. Pending
edits recover their original signed outcome without replay, and cannot discard
a newer local draft. A read-only view displays committed source while retaining
any separately saved local draft. Replacement/disposal fences late replies.
Deferred questions retain their existing preparation/HUD/answer lifecycle.

**Create / operations** selects an existing storage identity, its local class
and an offered form. Catalogue/account/current-space identities are advisory;
an exact namespace/anchor can open other existing storage. The server validates
composition and permission. Space forms offer finite, rational and infinite
extents, placement and exterior choices through the same generic binder. The
shared mark adapter draws solid boxes, exact finite edge boxes and groups,
and picking opens operations on the exact depicted subject. It creates no
collision or local simulation. Creation leaves A in the current space.

Submitted drafts stay locked; explicit defaults start another operation after
the original outcome is known. Changed schemas retain compatible draft fields
but require explicit adoption. Recovery displays original result bindings and
returned subjects through the existing signed outcome owners. **View result**
opens the exact returned subject for inspection without entering it; the received
original outcome remains distinct from any subsequently selected local draft.

Current location comes from the committed assignment's live navigation view;
the original account/S0 results stay unchanged. Current-space operations and
exact-subject selection use the ordinary offered Enter/Leave forms. Creation
retains its selected-storage path inside any current space and does not enter.
An explicitly unplaced agent keeps navigation subscribed without a scene.

Recursive parent-first marks, absolute body poses and decorative source-frame
poses share the scene adapter. Native samples retain world/run/structure and
registration fences; missing or unavailable sources withdraw presentation and
control. Physical WASD/QE positions move an observer camera; right-drag changes its viewing angle.
An explicitly selected controlled body instead uses the signed native control
lane and authoritative viewpoint. Focus loss releases local input. No collision
or domain simulation runs in the client.
Start the installed desktop OpenXR runtime with the pinned Vulkan renderer:

```sh
python3 client/godot-tools/run.py --xr -- --profile /absolute/private/profile
client/godot/dist/quod.x86_64 --xr-mode on --rendering-method mobile --rendering-driver vulkan -- --profile /absolute/private/profile
```

After connecting, **Start OpenXR** attaches the runtime's current controller
trackers. The signed controller projection supplies descriptions, roles,
bindings and appearance admission. Only the explicitly described Vive profile
and named facilities are mapped. Unknown profiles, missing facilities and
ambiguous roles remain visible and disabled. **Connected controllers** offers
session-only source choices; saved preferences still use ordinary account forms.
No source IDs or per-frame poses are written to an ontology.

Desktop and XR point at the same native Control tree and exact-subject scene
picker. The display texture owns no focus; native buttons/editors retain it.
Both use the shared opaque control palette, bounded editable fields and distinct
hover, focus, pressed and disabled states. The actual authored submission role
receives the primary-action treatment; its label and authority remain authored.
Completed account setup is collapsed behind **Connection / identity**. Required
first-run controls remain visible on desktop; **Inspection & settings** holds
the existing source/controller/runtime actions. Status and refusals stay visible.
**Appearance** adjusts the same controls without replacing their drafts.
Authored forms may also select a renderer-neutral `appearance(1, Tokens)` on
their container. The anchored GUI vocabulary validates unique RGB colour,
integer spacing/padding/corner and permille panel-opacity tokens. `inherit`
uses the enclosing appearance or the offline adapter defaults. Only panel
backgrounds may be translucent; text, controls, status and the keyboard stay
opaque. Local text size and Opaque preferences retain precedence.

An appearance update preserves native controls, draft values, caret/selection
and the semantic submission revision. Reauthorization still revokes input and
focus; appearance never grants either. Unchanged graph/scene resources remain
hidden while the same consumer refreshes. Stored-source reuse checks its exact
accepted dependency version; a committed source change refreshes the baseline
comparison. Computed inspection lenses re-evaluate their authored cursor on each
accepted refresh because target history cannot validate recipe or live-runtime
results. Identical text retains its native editor selection and caret. Denial or
consumer retirement clears the presentation.
The existing browser adapters support `inherit` and explicitly refuse authored
themes requiring this native adapter. They do not silently discard appearance.
The XR workspace uses the same controls and drafts in a reflowing 1200×800
surface, with connection/identity details collapsed behind a local action.
Verbose identity/controller references and retired setup controls remain in
that detail view; the working form keeps the primary surface. Appearance
controls expand locally from Appearance without replacing the form.
Its initial 26px text retains approximately the former 16px/496px nominal
angular size at the same 1m height and 2m distance. These are presentation trial
defaults, not physical readability or comfort qualification. Larger/smaller
text reflows the actual controls; tinted/opaque changes only the background.
Move/Place, Recenter, Hide and nearer/farther are local presentation actions.
Changing distance scales the panel proportionally (1m high at 2m), retaining its
central angular extent and text/target scale. Text size remains independently
adjustable. This is idealized presentation geometry, not a lens/comfort claim.
Initial placement and explicit repositioning use the current tracked head's
height and horizontal forward direction, with an upright panel. A vertical-only
direction waits for a measurable heading. The existing XR frame owner places
it once; ordinary head movement leaves the panel stationary.
Hide retains the controls/drafts. The mapped menu can summon the hidden workspace
from the current view. A live modal must be closed before hiding its workspace.
Stopping XR restores the same desktop tree, sizing and theme. Panel aspect,
ray bounds and visible ray endpoint use the same geometry. Resizing or moving
the panel cancels captures before neutral rearm.
Operation selectors constrain their displayed width to the current surface;
long exact identities remain the same selected values without widening every
field and Submit control beyond the workspace. Source workspace fields scroll
inside their existing native form. Column forms keep trailing actions in a
wrapping row outside that field scroll; authored rows, grids and column child
order remain intact, including interleaved actions. The authored task title and help are
rendered above the fields. An explicitly selected new action is revealed by the
existing scroll owner; automatic discovery and unchanged selections retain the
scroll position. Layout changes retain the same draft and controls.
Labels identify editor/catalogue/result fields; validation
messages consume space when present. Native form targets have a 44px minimum
height and choice items retain spacing at small text sizes.
Choice menus open on a completed press/release, so that opening release cannot
select a newly opened item under the ray. Storage captions name the actual
namespace (or the exact current account); their tooltip retains the full anchor.
Operation context and outcome status stay concise. Each received outcome stays
with its returned actions when a renewed offer updates the current draft status.
Returned-subject actions are
shown before the form; full exact identities and replies remain inspectable in
the bounded **Exact identity / outcome details** view. Opening details or a newly
returned subject action reveals it through the same native scroll owner.
The desktop mirror converts pointer positions/relative motion into that surface
once; XR ray hits already use surface coordinates. The mapped menu shows the
authored clockwise pad sectors as numbered directions beside the same numbered
native buttons. Hold the pad, slide the thumb towards a number, then release to
choose the visibly selected entry. Returning to centre and releasing cancels;
unavailable entries cannot activate. The same buttons also accept ray/trigger
selection, consuming the later pad release once. Instructions stay in the menu,
whose opaque shared palette separates it from the retained form beneath it.
Larger text scrolls the list and reveals the selection without shrinking text.
Editable text, numeric and source fields in the spatial workspace expose an
opaque adjacent AZERTY keyboard. Keys use the same native editor, caret,
selection, undo and draft events; Enter follows the field's native semantics
and never means Save. Shift also selects text with the arrow keys. Hide/Escape
closes this local surface while retaining the draft; clicking the field recalls
it. The keyboard extends downward at the workspace's existing text scale,
without moving the active field or duplicating its text, including masked text.
Focus/consumer replacement, read-only state, native popups, workspace hiding and
input eligibility loss revoke queued keys and captured presses. Unchanged focus
reuses the same controls. The fixed AZERTY subset follows the existing browser
adapter; hardware/platform input remains available for other characters and
locales. This is not a general locale/IME implementation. Main's separate
backup-file/passphrase window remains desktop-only. Software layout/ray checks
do not establish headset typing comfort or reachability for a particular user.
The black scene supplies neutral ambient illumination for authored shaded models.
XR input and controller models require a running, Focused OpenXR session,
current head/controller tracking, the visible desktop window and signed mapping.
Desktop focus loss cancels current pointer, menu and travel work without activation;
it does not keep XR input or models paused. Held controls cannot replay or resume:
neutral is required before a new gesture, even while desktop focus stays elsewhere.
Native focus/running loss, visibility loss, stale tracking, context changes and
source or signed-mapping withdrawal retain their cancellation and blocking gates.
GUI capture and menus suppress travel. The presentation menu stays summonable
while an ordinary working form is open;
pointer captures and visible native popups block it. A popup appearing during a
held menu cancels it without activation, requiring a fresh released gesture.
The current selected control association alone supplies movement abilities; the
existing signed sender and native physics
owner decide movement, snap, teleport path/support and collision. Tracking
contracts other than the authored `view_only` contract remain unsupported.

Controller appearances share digest-verified static GLB bytes and engine
templates while retaining independent source nodes. Authorization withdrawal
hides inert resources until source removal; unchanged reauthorization reuses
them. The complete export includes the model's MIT notice. **Stop OpenXR**
releases this consumer's sources, captures and render leases. Godot retains its
native session for the application lifetime; application close requests session
exit before uninitializing the engine interface. The scene owner releases the
stretched mono layout for XR, keeps the hidden stereo viewport rendering, and
restores the same mono viewport and desktop camera on pause. Failed exported
qualification also closes through this owner and retains its failing exit code.

Runtime discovery, injected engine tests and physical hardware observations are
separate qualification levels. A compatible runtime ABI and access to the
headset display are prerequisites independent of controller mapping. The pinned
engine's retained teardown diagnostics and native/physical acceptance limits
are recorded in the [M4-R2 evidence](../../doc/evidence/godot-m4-r2-20261029/README.md).
Process exit alone does not prove native resource retirement. Quest and Android
headset qualification are outside M4.
The legacy native viewer
retains its uncovered asset/XR obligations until their replacement qualifies;
it is not a dependency of this client. The shared [QUO-62](nimbalyst://QUO-62)
and [M1b evidence](../../doc/evidence/godot-m1b-20261028/README.md) retain the M1
qualification. [QUO-63](nimbalyst://QUO-63) and the
[M2 evidence](../../doc/evidence/godot-m2-20261028/README.md) track additional-space
qualification. The explicit `--qualification` application flag is used only by the
retained exported-application test driver; it supplies no domain permissions.

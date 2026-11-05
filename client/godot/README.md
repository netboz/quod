# Clean Godot client

This Linux .NET client adapts Quod's signed protocol and portable GUI model.
Identity creation/import happens offline. A saved active key signs in when the
client opens; creating a key continues into sign-in, and importing one continues
after the backup dialog closes. Authentication recovers original
account/instruction results and opens the current authorized space. A failed
sign-in leaves the saved key and an explicit Connect retry. First-time setup
starts in the ordinary empty black S0.
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

Enter the node address: a name such as `quod-0.service.consul` (port 443 by
default) or `IP:port`; `--node` sets it from the command line. A node serves
HTTPS with its own self-signed certificate, re-signed in place from one key, so
the first connection trusts and remembers that key per address, like SSH. Later
runs reconnect to the saved address and refuse any other key; "Forget this
node's key" accepts a deliberately re-founded node. Address changes disconnect
the current consumer. An imported key without an account reference first checks
its retained signup receipt; lookup failure cannot provision a replacement.
The setup description names the policy-selected existing account storage for S0.

The Quod logo appears on the opening screen. On first run, **Create my key**
stores a local identity and connects; **Import encrypted backup** restores an
existing key and connects when its dialog closes. Returning users with a saved
active key connect automatically. The current capability determines the
highlighted next action:
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
After ordinary account setup or Connect, the actual authorized interior and
permitted contents fill the window. The corner names the space from that same
signed view's authored `name` attribute. Missing names stay unnamed;
invalid/ambiguous names or unavailable views cannot masquerade as an empty
space. A left click opens the exact depicted subject's default view; current
place and selected subject stay distinct. Every other choice comes from the
pointed target's pie (below). Opened views and forms float on glass panels
docked away from their target, closed with Esc or Close; the panel keeps only
the content, its placement toggle and the exact identity on request. The
**This device** HUD command holds the local tools: text size, panel opacity,
VR, workspace placement, **Account and keys** (the login card), and Tools
(the storage/class catalogue, this account's source, account controls and
connected controllers). A same-profile reconnect retains the open subject and
durable work, without replay. Full subject and recipe identities remain
inspectable in **Details**. Layout never assigns or moves a domain object.

Exterior, permitted contents, offered actions and source tools retain that same
namespace, genesis anchor and entity. Representation choice never enters a space
or grants permission. A view opens presentation; an action opens the existing
form, whose authored confirmation button alone submits it. The pie is the single
selection route, without a competing operation dropdown.
Operation forms keep their existing draft and controls
when another representation is opened. Contents reuse the shared recursive
projection and scene resources; unavailable dependencies withdraw that consumer.
World and selected physical views return delivery credit only after the same
scene adapter accepts their projection/frame. A depicted ontology keeps the
catalogue's flat identity only when its namespace and history match the mark.

A visible pick retains the exact selected occurrence as well as its subject.
In spatial presentation, its authored action form appears above that occurrence.
**Personal workspace** moves the same form there; **Near this object** returns it
to the still-current occurrence. Native controls, unsent draft, caret/selection,
operation revision and received original outcome stay with the existing owner.
Choosing either placement performs no domain action. **Close** returns to current
space while retaining the form. Desktop presents it as a floating glass panel
docked to the side of the window farther from its target.

This also applies to an occurrence selected inside an offered visual preview.
Its signed visual consumer stays installed while that form uses it. The form has
one native surface, independent of the preview texture; it is not reconstructed
when moved. Refresh withdraws interaction until accepted. A removed occurrence
cannot be revived by reusing its ID; personal placement still requires the form's
own current authorization. Changing subject or terminal visual withdrawal retires
the previous visual consumer. Recipes may live in the same ontology as their class.

Solid primitives retain authored colour, metallic, roughness and emission values.
Neutral adapter lighting distinguishes solid faces against the ordinary black
background. Wire geometry remains unshaded and labels stay opaque. This supplies
no physical sun, collision geometry or measured headset readability guarantee.

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

A storage's pie (**Inspect**) opens its source even when it offers no class
operation. Ontology identity is independent of spatial
membership. Source workspaces use the existing native editor and predicate
catalogue; policy/interface/route lenses use the same complete UTF8 cursor reader.
System source remains read only. An authorized edit keeps its original committed
baseline and local draft. **Preview changes** stages the existing guarded proof;
**Save changes** accepts that original cursor once. **Cancel preview** does not
commit. Stale baselines are refused without replacing the dirty draft. Pending
edits recover their original signed outcome without replay, and cannot discard
a newer local draft. A read-only view displays committed source while retaining
any separately saved local draft. Replacement/disposal fences late replies.
**Your attention** shows the pending-question count. Open its list and choose one
request; arriving questions do not open another form or replace the chosen task.
Each item shows its authored title, source form, responsible agent and textual
state. **Info** opens a selectable, bounded reader of the full exact form,
responsible agent and question references within the same native surface. Toggle
it again to return to the retained form and draft. This personal
attention surface is separate from an object-associated Eidolon form.

The attention list and each question have separate signed authorizations. A list
refresh does not revoke an independently accepted question. Question withdrawal
hides and locks its fields, releases native capture/keyboard input and retains
its last-known outcome separately from the unavailable notice. Accepted question
recovery restores that same controller; it never clears an unknown write barrier.

**Later** and **Back** hide work locally; the same open-window controller retains
its unsent draft, native field and selection. **Cancel request** is a separate
signed domain action. A received input commit remains **Submitted**; removing a
question from the HUD does not establish application success. **Applied** requires
the existing authenticated application-outcome read. **Check original outcome**
resolves the original signed request after a lost reply, including after the
question was removed; it never sends a replacement answer. Reconnect discovers
questions still pending at their owner, without reconstructing a historical answer
archive or replaying work. An unwritten generic question draft is local to its
current controller, not a durable source draft.

The selected question keeps source/title, status and actions outside its bounded
column field scroll. Larger text and the adjacent opaque keyboard use the shared
native owners. Invalid input retains nearby errors; a focusable validation summary
and general fixed-grid reflow remain unimplemented. An authored schema change
keeps the old draft locked rather than silently applying it to a new contract.

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
control. Physical WASD/QE positions move an observer camera; middle-drag changes its viewing angle.
An explicitly selected controlled body instead uses the signed native control
lane and authoritative viewpoint. Focus loss releases local input. No collision
or domain simulation runs in the client.
The normal build starts in desktop 3D with the existing OpenGL renderer and
OpenXR enabled. If no supported runtime or headset initializes, the desktop
client continues without VR. After account sign-in with an initialized runtime,
F9 or **This device ▸ Enter VR** enters VR while the client is focused;
**This device ▸ Return to 3D** leaves it.
These actions change local presentation, not the current agent or space.
The runtime and headset must be available when Quod opens. Without them, Godot
may log an OpenXR initialization error while the desktop client continues.

Launch the normal client:

```sh
python3 client/godot-tools/run.py -- --profile /absolute/private/profile
client/godot/dist/quod.x86_64 -- --profile /absolute/private/profile
```

After entering VR, the client attaches the runtime's current controller
trackers. The signed controller projection supplies descriptions, roles,
bindings and appearance admission. Only the explicitly described Vive profile
and named facilities are mapped. Unknown profiles, missing facilities and
ambiguous roles remain visible and disabled. **Tools ▸ Connected controllers** offers
session-only source choices; saved preferences still use ordinary account forms.
No source IDs or per-frame poses are written to an ontology.

Desktop and XR point at the same native Control tree and exact-subject scene
picker. The display texture owns no focus; native buttons/editors retain it.
Both use the shared opaque control palette, bounded editable fields and distinct
hover, focus, pressed and disabled states. The actual authored submission role
receives the primary-action treatment; its label and authority remain authored.
Completed account setup is collapsed behind **Account and keys**. Required
first-run controls remain visible on the login card. Status and refusals appear
as one sentence in the HUD strip. Text size and opacity adjust the same
controls without replacing their drafts.
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
that detail view; the working form keeps the primary surface.
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
order remain intact, including interleaved actions. A selected representation's
authored title stays with its subject above the task scroll; authored groups
have section headings and help remains with the fields. Near-object placement
clears the selected solid's upper and near extents in the retained selection
view basis. It stays world-stable; it does not follow later head movement.
An explicitly selected new action is revealed by the
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
once; XR ray hits already use surface coordinates.

Menus are pies read from the pointed target's authored `menu` Eidolon
(`client_menu/2`): the pointed occurrence, else the space the agent is placed
in, else the agent itself. Right-click on desktop or the pad on the menu hand
opens it; direction, not distance, picks a wedge. Holding and releasing selects
(turbo), resting on a sub-pie opens it where its item was, the reserved back
wedge returns to the parent, and releasing in the centre cancels. Unavailable
wedges stay visible with their reason; a confirmed wedge asks for a second
press. On desktop, Backspace goes back, Enter commits, digits pick wedges and
the Menu key opens the pointed target's pie. In VR the pie has its own
world-locked surface at the device profile's reading distance; only the
controller that opened it steers it with its ray. A chosen action without
input fields runs at once; one with fields opens its form. The HUD strip
shows the human's `hud_commands/1` view, the one local "This device" command
and the last status sentence: along the bottom edge on desktop, and in VR on
its own surface 25° below eye level that follows the body only after a 35°
head turn. Agents the human already lets put questions before them may offer a command;
the offer waits until the human answers it through **Offered commands** in
their own pie. A strip click is committed by the same pie as any wedge, so a
command that asks for confirmation still asks.
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
them. The complete export includes the model's MIT notice. **Return to 3D**
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

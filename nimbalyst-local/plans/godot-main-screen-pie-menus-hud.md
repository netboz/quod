---
planStatus:
  planId: plan-godot-main-screen-pie-menus-hud
  title: Godot client — fullscreen main screen, recursive pie menus and HUD class
  status: in-review
  startDate: "2026-11-05"
  planType: system-design
  priority: high
  owner: Yan
  stakeholders: []
  tags:
    - godot-client
    - gui
    - ontology
    - vr
    - design
  created: "2026-11-05"
  updated: "2026-11-06T19:00:00.000Z"
  progress: 93
---

# Godot client — fullscreen main screen, recursive pie menus and HUD class

Design only. This plan describes the main screen shown after sign-in, for
desktop 3D and VR, with one interaction model for both. It replaces the current
header, sidebar, tools panel and list menu; it does not restyle them. The login
card (`client/godot/Main.cs`, `nimbalyst-local/mockups/godot-login.mockup.html`)
is the quality reference: house teal, the dodecahedron, one clear action at a
time, plain words.

Nothing here is implemented. Every predicate shape below is proposed; the
existing proof, transaction, signing and deployment contracts stay in force.
No deployment, refound or data wipe is authorized by this plan.

## Implementation checklist

- [x] **Phase 1 — Menu vocabulary in Prolog**
  - [x] Add `menu_item` to `quod:gui`, the `menu` Eidolon purpose and the default recipe that builds a pie from `entity_eidolons/2`.
    Shipped as `menu_tree/2` (one builder: purpose groups, fixed slots, overflow under "More") and `gui_menu_source/2` (target-side labels and availability). The item picture attribute is named `image`, like `button`. `client_menu/2` is the one signed read, through a new `menu` view kind (stopgap; see task_1793880364287_ygezmn).
  - [x] Add the space menu recipe in `quod_space.pl` (Leave space in a fixed slot, confirmed; Create here; Show as; Inspect).
    Leave sits on slot 5, the bottom of eight wedges. "Go to" lists contained spaces of the same storage only. "Where am I" is not built: there is no navigation Eidolon to point at yet. Fixed `lobby_instance.pl` forwarding, which filed the vocabulary's inherited `thing` choices under the requested class and hid the space menu.
  - [x] Production-seam tests: default pie for an instance, class override, unavailable items keep their reason, labels are plain words.
    `test/quod_gui_menu_tests.erl` (signed human reads); lobby choice lists updated for the menu choice.
- [x] **Phase 2 — One pie control for desktop and VR**
  - [x] `PieMenu.cs` fed by the existing `IControllerConsumer` menu calls (`OpenMenu`/`MoveMenu`/`CommitMenu`/`CancelMenu`) and by desktop right-click/keyboard.
    Pure navigation and decoding in `Core/Menus.cs` (checked in `client/godot-tests`). Desktop look-around moved from right-drag to middle-drag. Only the controller that opened the pie steers it with its ray; an idle pad does not override a moving ray.
  - [x] Recursion: sub-pie opens where its item was, parent becomes the back node, centre names the item, marking and turbo modes.
    The back wedge is reserved by `menu_tree/2` (opposite the parent item) and sent as `back`. Entering or leaving a level re-arms the navigator: the direction held at that moment points nothing until it leaves, as a held control needs neutral before a new gesture. Marking opens a sub-pie after a 300 ms rest (client timing constant); sharp-turn detection is not built. Digits are always shown faintly on desktop, not after a hold.
  - [x] Delete the list menu in `OpenXRInput.OpenMenu` and `Main.WorkspaceMenuEntries`.
    `ControllerChecks`/`WorkspaceChecks` rewritten for the pie; offline `controller-input` phase passes (84 checks). The `workspace` phase stops earlier on the uncommitted login-card layout (`workspaceShell` hidden offline), before its pie probes. Until the HUD's "This device" exists, a hidden VR workspace has no in-headset recall.
- [x] **Phase 3 — Target rule and feedback**
  - [x] Pointing at an occurrence targets it; pointing at nothing targets the containing space; unplaced targets your own agent.
    The agent's pie is `personal_menu` in `user_instance.pl` (Enter a known space, Create a space, Your account); the human, also an agent, keeps the default pie. "Your attention" stays a HUD command (Phase 5).
  - [x] Pre-press feedback: ray tip / cursor label naming the target; outline on the hovered occurrence.
    Outline is a local gold overlay tint (`ScenePanel.Outline`). The VR label sits at the pointed occurrence's depth along the ray, not the exact surface hit. No ring is drawn when nothing is hit; the label alone names the space.
  - [x] Placement, dismissal and desktop equivalents (right-click, Esc, Menu key).
    VR pie has its own world-locked quad (`pie-viewport`), sized with the workspace's existing text density; `DeviceProfile.Vive` holds the two decided numbers (1.5 m, 15°). Not built: the pie following the controller while held, and the thin line to a pulled-in object. Space does not open the pie (it types in fields); the Menu key does.
- [x] **Phase 4 — Fullscreen layout**
  - [x] Scene fills the window in both modes; remove header, account actions, tools panel and sidebar from `Main.cs`.
    Also removed: the VR mode button (F9 and This device ▸ Enter VR remain), the old "Space views & actions" path (the space's own pie is the way to the current space; the navigation journey check now reaches it through the operations panel's exact-subject route) and the `EidolonPanel` chooser groups and "Inspect storage source". Account and keys, the storage/class catalogue, account source/controls and connected controllers moved under This device. The corner (logo + space name) does not fade yet.
  - [x] Forms and views open as floating panels near the target or in the personal workspace (same `EidolonPanel`/`OperationsPanel`), closable with Esc / Back.
    Desktop panels dock to the side farther from the target; not draggable. Panel titles use the wedge's authored label. VR keeps the existing spatial surface; its Move/Recenter/Hide live in This device ▸ Workspace, not a per-panel pie.
  - [x] Status appears as one plain sentence in the HUD strip, never as a permanent panel.
    Offline `controller-input` (84) and `workspace` (40) phases pass; node-backed journeys were updated to the This device actions but not run here.
- [x] **Phase 5 — HUD class and contributions**
  - [x] `hud` class in `quod:gui`; one HUD instance per human in `user_instance.pl`; `hud_commands/2` signed view.
    Shipped as `hud_commands/1` (`hud(Tree)`, one `menu_tree/2` level whose wedges are `hud_allowance(my_hud, 12)`), with a stopgap `hud_commands` view kind. Commands are ordinary menu items; no separate `hud_command` class. "More" pies use the vocabulary's wedges, and a level that cannot place an entry is refused (`menu_wedges_too_few`).
  - [x] Contribution policy, acceptance through an ordinary question, withdrawal, failure display.
    Built and tested: direct contributors (human, personal agent, owner of the containing space), everyone else refused at admission (`can_invoke` names exactly the direct contributors), `hud_withdraw/2` admitted only to the human or that contribution's contributor, unreadable sources shown dimmed. `hud_contribution/4` records the contributor. Acceptance follows the approved draft below (offers admitted by the human's `gui_receiver_policy/2`): another agent's `hud_offer/2` waits as `hud_offered/4`, and the human's own **Offered commands** operation (`hud_answer_offer/3`) places or drops it; contributors may withdraw their offer. No count limit on waiting offers.
  - [x] `HudBar.cs`: body-locked strip in VR, bottom strip on desktop; icons from the recipe; click opens the command's Eidolon or sub-pie.
    Built: desktop bottom strip with initials, status sentence, click committed through the pie itself (opened on the strip's root at the clicked wedge, so confirmation and nesting are the pie's), sub-pies for Me/More. VR: own body-locked surface 25° below eye level, following after a 35° head turn (`DeviceProfile.Vive`, Yan 2026-11-06), clicked by the controller ray. Not built: auto-hide, rendering authored image icons (initials only), modifier+digit shortcuts.
  - [x] Move "Your attention" (QuestionHub) into the HUD as the first standing command; "This device" is the one client-authored command (decision 3).
    "Your attention" is a `attention` purpose Eidolon of the human opening QuestionHub; the old header button goes with Phase 4. "This device" holds text size, panel opacity, VR and workspace placement.
- [x] **Phase 6 — Space boundary seen from inside and outside**
  - [x] `interior` attribute on `space`, resolved by the same class-selected boundary recipes as `exterior`.
    `none | wireframe | matrix`; absence reads as `none`. `space_represent` is now `/7` (before/after interior beside exterior and pose); the space pie's **Show as** offers the interior choices as no-input operations through it.
  - [x] Interior projection places the space's own boundary occurrence at its origin.
    `space_boundary_parts/3` in `space_exposure_projection`, through the `space_interior_boundary/2` composition hook; it is not a contained subject and has no exposure row.
  - [x] `matrix` style: translucent grid walls; extend `surface/5` with opacity (rendering vocabulary change, flagged below).
    `surface(Colour, Metal, Rough, Emission, Opacity, Textures)` everywhere: ontologies, Godot `Scene.cs`, browser `marks.js`/`render-resources.js`, legacy `scene.rs`, regenerated contract corpus. Matrix = translucent near-black box (opacity 220) plus emissive green wire box; no grid texture, because the Godot client still refuses textured primitives.
- [ ] **Phase 7 — Acceptance**
  - [ ] Headless Godot checks, signed production-seam tests, then physical Vive session: open, nest, back, turbo-select, dismiss, HUD click, leave space.
    Done here: EUnit (460-test neighbour run, then the two updated suites green), xref, browser tests (295), legacy Rust tests, `client/godot-tests` (206), offline Godot `controller-input` (84) and `workspace` (40) phases. Headless journeys against a local node (2026-11-06, commits `1dba5194` + bump 0.7.279): `gui` 99 checks, `spaces` 29, `navigation` 21, each stopping only at its first step that needs real desktop input; they found and fixed three defects (pie never redrew, an always-advertised offer action hid the human's panel, no way to choose a class's creation form). Desktop-input preparation (2026-11-06, uncommitted): native clicks now map surface points to window points (`SpatialGui.WindowPoint`); the class pie read is granted in the foreign-storage fixture policy; two exit-time leaks fixed (orphan status label, unattached HUD device button). Rerun after it: headless journeys unchanged at `gui` 99 / `spaces` 29 / `navigation` 21, `client/godot-tests` 209, offline `controller-input` 84, `workspace` 44, `startup-new` 6, neighbour EUnit 461/0. `--desktop` journeys (2026-11-06, real Wayland input): `gui` passes every check (`M1B_EXPORT_PASS`; its exit leak — a panel-created preview with no owner — is fixed, rerun pending), `navigation` 170 checks, `spaces` 153. They found and fixed: foreign-storage policy missing the GUI's reads (`entity_eidolons`, `client_menu`, recipe callback `gui_menu_source`), preview lifetime, and test steps that clicked through the deliberate sign-in barrier or assumed a pre-selected action. **Open:** in `spaces`, a creation refused by destination admission reaches the client after more than 60 s, although the node alone refuses in 726 ms (new EUnit case); tracked separately. **Not done:** the physical Vive session; the `scene`/`presentation`/`menu` phases need a real renderer or desktop input.

## Sources read and what they already decide

| Source | What it fixes for this design |
| --- | --- |
| [gui-plan.md](../../doc/gui-plan.md) — Entities, Eidolons and marks; Shared questions and the HUD; VR ergonomics | An Eidolon is a recipe, a mark is one occurrence; the HUD lists pending questions without stealing focus; never head-lock a panel; VR is the primary target; plain opaque text on tinted glass. |
| [spaces.md](../../doc/spaces.md) | Placed instance has one containing space; S0 may be parentless; Enter/Leave are offered operations bound to the personal agent; `account_navigation/1` is the current location. |
| [godot-foundation-contract.md](../../doc/godot-foundation-contract.md) | `gui_operations/2`, `gui_operation/6`, `entity_eidolons/2` are the contracts; Prolog owns policy; Godot renders descriptors and submits operations. |
| [space-conceptual-architecture-review.md](space-conceptual-architecture-review.md) | "Menus and directly submitted goals use the same authoritative checks; discovery grants no authority." Menus display advisory availability. |
| [gui-examples.md](../../doc/gui-examples.md) | `icon`/`icon_button` carry `asset(Digest, <<"image/jpeg">>)`; `menu` is already a container class. |
| [vr-desktop-ergonomics-20261105.md](../research/vr-desktop-ergonomics-20261105.md) | Comfort zone, text and target sizes, body-locked HUD outside the central view, pie for up to about 8 items, reserved buttons. |
| [kando/README.md](../research/kando/README.md), [kando.menu](https://kando.menu), [kando.menu/usage](https://kando.menu/usage), [kando.menu/intro](https://kando.menu/intro) | Submenu opens where its item was; parent shrinks to the back node; centre names the item; whole wedge is the target; marking mode opens a submenu "when you stop moving the mouse" or on a sharp turn; turbo mode: "once you release the key, the currently dragged item will be selected"; hover mode "can also lead to accidental selections". |
| Pie menu evidence: Callahan et al., *An empirical comparison of pie vs. linear menus*, CHI 1988; Kurtenbach & Buxton, *The limits of expert performance using hierarchic marking menus*, CHI 1993 | Pie menus are faster and less error-prone than lists; marking menus degrade past about 8 items per level and about 2 levels of depth for blind selection; fixed item positions are what make paths learnable. |
| Microsoft [Comfort](https://learn.microsoft.com/en-us/windows/mixed-reality/design/comfort) and [Billboarding and tag-along](https://learn.microsoft.com/en-us/windows/mixed-reality/design/billboarding-and-tag-along) | Content 1.25–5 m, resting gaze 10–20° below horizon; HUD content should tag along (body-locked with a lag), never head-locked. |
| Meta [Raycasting best practices](https://developers.meta.com/horizon/design/raycasting_bp/) | Hover, press and idle feedback; a cursor at the hit point; snap to 3D objects; steady ray origin. |

## Current code this design extends or removes

Existing pieces to keep, with their file:

- **Gesture arbitration** — `client/godot/Core/Controllers.cs`. `ControllerInput.Frame` already turns the signed mapping into `select` and `menu` edges, owns `MenuOwner`, calls `OpenMenu(source, axes, threshold)`, `MoveMenu(axes, threshold)`, `CommitMenu()` and `CancelMenu()` on the consumer. The default binding `bind(menu, menu, pad, radial(240), local(menu))` in `quod_controllers.pl` is already "hold the pad, slide the thumb, release": that is turbo mode. Nothing in this contract changes.
- **Picking** — `ScenePanel.PickRay` / `Pick` resolve an occurrence and its exact depicted subject; `ScenePanel.Selection` keeps the installed occurrence identity, so a removed occurrence cannot revive a target.
- **Subject opening** — `EidolonPanel.Open`/`Choose` reads `entity_eidolons/2`, opens a chosen Eidolon (view, source, inspection or operation form), and `OperationsPanel` submits through the personal agent. A pie item is exactly one of these choices; selecting it calls the same code.
- **Questions** — `QuestionHub` already subscribes to `gui_pending_questions/1`, selects the receiver and owns provisional presentations. It becomes the first HUD command instead of a header button.
- **Appearance** — `SpatialGui.PaintAppearance` theme tokens (text `#F5F1EB`, panel `#192B32`, accent `#F9C80E`, edge `#848FA5`) and the 1200×800 spatial surfaces.
- **Recipe selection** — `class_eidolons/4` in `common_predicates.pl` with most-specific-class and local-override rules; `entity_eidolons/4`; `gui_operations/2` with advisory `Availability`.

Pieces this design replaces (delete in the same scope, no parallel path):

- `OpenXRInput.OpenMenu` … `CancelMenu`: the numbered list panel with eight direction labels (`xr-menu`, `xr-menu-directions`, `xr-menu-choice`). The pie control takes over the same four consumer calls.
- `Main.WorkspaceMenuEntries`: the hardcoded list of button names (`workspace-show`, `open-gui`, `create-operations`, `location-operations`, `inspect`, `local-controllers`, "Return to 3D", the attention caption). Its content comes from the ontology after this plan, so the list goes.
- The shell header (`Quod`, Account, Tools, Appearance), `accountActions` (Current space, Inspector, Create…, Space views & actions), `toolsPanel`, `workspaceControls`, `workspaceAppearance`, the scrolling `body` and the `contentsStatus` sentence. The login card and its `showConnection` overlay stay.
- `EidolonPanel` "Views & actions" / "More views & editors" button groups: the pie is the chooser; the panel keeps only the opened content, its placement toggle and Close.

## 1. The interaction model

One action set in both modes:

| Action | VR (Vive, current mapping) | Desktop | Meaning |
| --- | --- | --- | --- |
| Point | Controller ray | Mouse cursor | Chooses the target, continuously, before any press. |
| Select | Trigger (`select`) | Left click | Opens the target's default view, as today (`scene.Selected`). Never executes a domain action. |
| Menu | Pad press on the menu hand (`menu`) | Right mouse button, or Menu key / Space for the current target | Opens the target's pie. Holding it is turbo mode. |
| Choose | Thumb direction on the pad, or ray direction on the pie | Mouse direction, arrow keys, digits 1–8 | Picks a wedge by direction, not by precise aim. |
| Back | Move toward the back node | Backspace, or move toward the back node | Returns to the parent pie. |
| Dismiss | Release in the centre, pad press again, trigger on empty space | Esc, right-click on empty space, click outside | Closes every level. Never on head turn. |

**The target rule.** The ray or cursor picks the hit occurrence. If it hits
nothing, the target is the containing space: the space the account's agent is
placed in (`navigation.Space`, from `account_navigation/1`). If the agent is
unplaced, the target is the agent itself (`personal`), whose menu offers the
ways in: enter a known space, create a space, your account. This fallback
chain is the only client rule; what each target offers comes from Prolog.

**Feedback before the press.** The target must be legible before any button:

- Hovered occurrence: a thin gold outline on its mark (local emission tint in
  `ScenePanel`, no domain read) and a small label at the ray tip or beside the
  cursor with the occurrence's authored label ("Workshop", "likes/2").
- Nothing hit: the ray tip becomes a small ring and the label reads the space
  name ("Space · Home"). On desktop the same label follows the cursor.
- Unplaced: the ring and "You are nowhere yet".

Labels come from `attribute(Subject, name, _)` via the existing `client_subject_label/2`
and from the occurrence's `label/2`; the client never shows a Prolog term.

**Placement of the pie.**

- Desktop: centred on the cursor, clamped inside the window so every wedge is
  reachable. Keyboard-opened: centred on the hovered occurrence, or on the
  screen centre for the space.
- VR, instance: on a plane facing the user, at the hit point moved toward the
  user along the ray by the pie's own radius, so the pie floats just in front
  of the object. If the hit is beyond the comfortable reading distance, the pie
  is pulled in along the ray to that distance and a thin line keeps pointing at
  the object.
- VR, space: world-locked, along the controller ray at the comfortable reading
  distance, slightly below eye level.
- The pie never follows the head. It does follow the controller only while the
  button is held (turbo), so that sliding the thumb and sweeping the ray both
  work.

The "comfortable reading distance" and the "slightly below eye level" angle are
device-profile numbers, not constants in domain code. The research digest gives
Microsoft's 1.25–5 m zone and 10–20° resting gaze. Flagged: the first profile
will carry two such numbers; they belong in the client's device profile and are
listed in the open decisions.

**Dismissal and loss of target.** If the targeted occurrence is withdrawn while
its pie is open (scene update, revocation), the pie closes and the HUD strip
says "That thing is no longer here." A pie is never left pointing at nothing.

## 2. Fullscreen layout

Both modes show only the world. Chrome is reduced to:

- **Top-left corner:** the dodecahedron at 28 px and the current space name,
  fading out after a few seconds of no pointer movement, back on hover. This
  is the only permanent orientation cue.
- **Bottom strip (the HUD):** the row of HUD command icons, centred, plus the
  last status sentence on the left. See §6.
- **No** sidebar, header buttons, tools panel or scrolling body.

Panels (forms, source views, inspections, the attention list) are floating
glass panels over the scene, as the gui-plan prescribes. On desktop they open
docked to the side of the window that is farther from the target, sized to
content, draggable, closed with Esc or Close. In VR they use the existing
spatial surface (`SpatialGui`) placed near the occurrence or in the personal
workspace, with the existing Move / Recenter / Hide actions moved into the
panel's own small pie (long-press on the panel edge). One primary panel at a
time by default; opening another replaces it and keeps the previous draft, as
`OperationsPanel` already does.

The login card remains a centred card over the world when sign-in, setup or
an uncertain earlier action needs the user.

[Desktop main screen](../mockups/godot-main-screen.mockup.html "width=1200 height=860")

## 3. The recursive pie menu

### Structure

- Up to the wedge count the recipe declares per level (the research digest and
  Kurtenbach & Buxton put the usable ceiling at about eight). A recipe that
  declares more items than its wedge count must nest them; the client never
  silently truncates. **Flagged:** the default recipe proposes 8 wedges per
  level; this is an authored allowance in `quod:gui`, not a client constant.
- Each item is a leaf (one Eidolon choice for the subject) or a sub-pie.
- Items have fixed positions: a recipe can pin an item to a slot (`slot`),
  otherwise items fill clockwise from the top. Fixed positions are what make
  paths learnable (Kurtenbach & Buxton), so the space menu pins "Leave space".
- Unavailable items are drawn dimmed, not hidden, with the reason in the
  centre when pointed at ("Not allowed here", "Needs a value first"). Hidden
  items would make muscle memory wrong.

### Navigation (Kando's rules, adapted)

1. **Point and click:** click or trigger anywhere in a wedge.
2. **Marking mode:** hold the button and drag through wedges. A sub-pie opens
   where its item was when the stroke stops or turns sharply; the parent shrinks
   to a small node in the opposite direction, joined by a line. Moving into
   that node goes back. Zig-zag strokes select nested items without looking.
3. **Turbo mode:** while the opening button is held, movement browses and
   release selects the item under the pointer; release in the centre cancels.
   This is already what the Vive pad binding does.
4. **Hover mode:** not offered. Kando warns it causes accidental selections; in
   VR a resting hand would fire it.
5. **The centre** always names the item under the pointer, or the current menu
   when nothing is pointed at ("Workshop", "Create here").

In VR the two direction sources feed one `MoveMenu(axes)`:

- thumb on the pad: the pad vector as today;
- ray: the ray's intersection with the pie plane, relative to the pie centre,
  divided by the pie radius.

Whichever moved last wins. Direction, not distance, selects; the dead zone is
the existing `radial(240)` threshold from the mapping.

On desktop the mouse delta since opening is the vector; arrow keys and digits
1–8 pick wedges directly (digits are shown faintly on each wedge after a short
hold, so the mapping is learnable); Backspace goes back; Enter commits.

[Space pie menu, desktop and VR, with one nested level](../mockups/godot-space-pie.mockup.html "width=1200 height=2100")

### Ontology contract: where items come from

Menus are class-selected Eidolons with the purpose `menu`, like views and
operations. No client hardcoding of items or nesting.

Proposed vocabulary in `quod:gui` (`quod_gui.pl`), reusing the existing
`menu` container class:

```prolog
isa(menu_item, gui_component).
gui_attribute(menu_item, target, eidolon_choice, required).   % eidolon(Purpose, Style, recipe(Ns, A, Name))
gui_attribute(menu_item, icon, optional_image_asset, default(none)).
gui_attribute(menu_item, slot, optional_slot, default(auto)).  % fixed wedge index, or auto
gui_attribute(menu_item, confirm, boolean, default(false)).    % second press before executing
gui_attribute(menu, wedges, positive_integer, default(8)).     % authored allowance per level
```

A `menu` component's children are `menu_item`s and nested `menu`s; `label`
and `help` are inherited from `gui_component`. The tree is compiled by the
existing `gui_tree_schema/3`, so labels, appearance tokens and validation are
the ones forms already use.

Recipe selection:

```prolog
%% default pie for any thing: actions at the top level, views and inspection nested
class_eidolon(thing, menu, default, recipe(<<"quod:gui">>, G, default_menu)) :-
    quod:root::system_ontology(<<"quod:gui">>, G).

eidolon(default_menu, subject(Target, Entity), menu(Tree)) :-
    entity_eidolons(Entity, Choices),           % the subject's own offered Eidolons
    default_menu_tree(Choices, Tree).           % operations as leaves; playing/edition under "Show as";
                                                % prolog/inspection/workspace under "Inspect"
```

A class overrides the default by declaring its own `menu` recipe; the existing
most-specific-class rule in `class_eidolons/4` picks it. The client asks one
goal per target, `client_menu(Subject, Tree)`, which is `client_eidolon/3` with
the `menu` purpose: the same signed read as any Eidolon. Selecting a leaf
calls exactly what `EidolonPanel.Choose` calls today for that `eidolon/3`
choice: a view read or `gui_operations/2` → form → `gui_operation/6` through
the personal agent. Availability on operation leaves is the advisory
`Availability` of `operation_view/9`; the operation still rechecks on submit.

Operation forms with no input fields (Leave space, Enter space) execute on
selection, after the `confirm` second press when the item asks for it. Forms
with fields open the panel. The item's `help` text is the centre caption.

Labels: every `label` is a plain sentence fragment authored in the ontology
("Leave space", "Create a space here", "Show as wire box"). The client shows
nothing it computes from a term name.

## 4. The space menu

`quod_space.pl` declares the space's own pie, overriding the default:

```prolog
class_eidolon(space, menu, default, recipe(Ns, A, space_menu)) :- current_ontology_identity(Ns, A).
eidolon(space_menu, subject(ontology_ref(Ns, A), instance(Space)), menu(Tree)) :- ...
```

Content, clockwise from the top, with slot 4 (bottom) fixed:

| Slot | Item | Target | Notes |
| --- | --- | --- | --- |
| 1 | Create here ▸ | sub-pie: Create space / Create infinite space / Create space with exact lengths | the class(space) `create*` operations on the space's storage, placed near the agent |
| 2 | Show as ▸ | sub-pie: Permitted contents / Wire box / Matrix walls | `playing` Eidolons of the space, applied to the *interior* (see §7) |
| 3 | Inspect ▸ | sub-pie: Source / Policy / Interfaces / Routes / Workbench | the ontology Eidolons of the space's storage |
| 4 (fixed, bottom) | Leave space | `space_leave` operation, `confirm(true)` | the research digest: fixed slot, not the fastest one, confirmed |
| 5 | Go to ▸ | sub-pie of contained spaces, each a leaf on that child's `enter` operation | nested further when more than the wedge count |
| 6 | Where am I | the `account_navigation` text as a one-line panel | plain words: "Home, inside nothing" |
| 7, 8 | free | class authors may add | |

"Go to" is included because the research digest asks that every action also
has a visible path: a far child space is hard to point at.

The unplaced agent's pie (target = `personal`): Enter a known space ▸, Create a
space, Your account, Your attention.

## 5. The instance menu

Any instance without its own recipe gets the default pie: its offered
operations as leaves (Enter space, Edit settings…), "Show as ▸" with its
playing/edition views, "Inspect ▸" with source and inspection views, and
"Details" (exact identity, for the Details link the login card also has).
Classes with their own recipe put their verbs first; the human instance's
menu, for example, has "Controller settings" (already an offered operation)
and "Keys and backups".

[Instance menu on a contained space](../mockups/godot-instance-menu.mockup.html "width=1200 height=780")

## 6. The HUD class

### What it is

A `hud` is an ordinary class in `quod:gui`; each human account composes one
instance of it (`instance_of(hud, my_hud)` in `user_instance.pl`). The HUD
shows **commands**: each command is one Eidolon choice for one subject, drawn
as an icon with a label. Clicking a command does what selecting the same item
in a pie does. A command may itself be a sub-pie.

### Prolog contract

```prolog
%% quod:gui
isa(hud, thing).
isa(hud_command, menu_item).                       % same target/icon/confirm attributes
class_eidolon(hud, playing, strip, recipe(<<"quod:gui">>, G, hud_strip)) :- ...
eidolon(hud_strip, subject(Target, instance(Hud)), hud(Commands)) :-
    findall(C, hud_command(Hud, C), Commands).     % ordered, authored

%% user_instance.pl — the human's ontology owns the HUD instance and policy
instance_of(hud, my_hud).
hud_command(my_hud, Command) :- hud_standing(Command).         % the account's own commands
hud_command(my_hud, Command) :- hud_contribution(my_hud, _, Command).   % accepted contributions
hud_command(my_hud, Command) :- hud_context(Command).          % offered by the space you are in
hud_allowance(me, N).                                         % authored, like gui_pending_allowance/2
hud_commands(View) :- current_principal(Owner), human_user_owner(Owner), ... % the signed view
```

Standing commands of the account: **Your attention** (the pending-question
count, opening the existing QuestionHub list), **Me** (the human instance's
pie: controller settings, keys and backups, sign out), **This device** (text
size, opaque panels, enter/leave VR — the only client-local items, see open
decisions).

Contextual commands: the space the agent is placed in may declare
`class_eidolon(Class, hud, Style, Recipe)`; its recipe yields `hud_command`s
that appear while you are there and vanish when you leave. The lobby could
offer "Worlds" this way; S0 offers nothing.

### Who may contribute

Contribution is a reference the human's ontology stores, exactly like
`gui_pending/2` stores question references:

```prolog
hud_contribution(Hud, entity_ref(Ns, A, Entity), eidolon(Purpose, Style, Recipe)).
hud_contribution_policy(Hud, Contributor).   % who may ask
```

Default policy: the human, the personal agent and the owner of the space the
agent is placed in may contribute directly. Any other agent must ask: it opens
an ordinary GUI question ("Lighting assistant wants to add a button to your
HUD: *Adjust the atmosphere*. Accept?"), and the accepted answer's continuation
asserts the reference in the same transaction. The human can remove any
contribution from the HUD's own pie ("Remove from HUD"), which retracts the
reference; the contributor can withdraw its own. Both are governed transitions
through the existing atomic path; no new executor.

### Draft for review: asking to contribute (2026-11-06)

Not built. Yan asked for a design before implementation.

**The problem with the literal plan.** An ordinary GUI question is answered
in the asking agent's ontology: its continuation runs there. The human's
ontology would have to trust that foreign continuation to add the command
only on "yes". If the offer form lived in `quod:gui` instead, every asking
agent would write question state into a system ontology. Neither is
acceptable.

**Recommended: the offer waits in the human's ontology, and the human
accepts it with their own operation.**

```prolog
%% user_instance.pl: anyone may leave an offer, bounded like pending questions
hud_offer(my_hud, Contributor, Subject, Choice).          % stored reference
hud_offer(Subject, Choice) :-   % admitted only for gui_receiver_policy(me, P): agents the human already lets ask them questions
    current_principal(P),
    ... not already offered or placed ...,
    transaction(assertz(hud_offer(my_hud, P, Subject, Choice))).
%% the human's ordinary offered operation, one per waiting offer
class_eidolon(quod:gui:hud, operation(instance), answer_offer, ...)  % form: Accept / Decline
hud_answer_offer(Contributor, Subject, Choice, Accept) :-  % human only
    transaction((retract(hud_offer(...)),
                 (Accept == true -> assertz(hud_contribution(my_hud, Subject, Choice, Contributor)) ; true))).
```

- The acceptance is the human's own signed operation in their own ontology,
  so no foreign answer needs verifying.
- Waiting offers show in the HUD's own pie and in **Your attention**, with
  the contributor's name and the command's label read from its source, as
  contributions already are.
- The contributor can withdraw its own offer; a declined offer leaves
  nothing behind. Everything is one atomic transition through the existing
  path, with no new executor.
- Yan approved this draft (2026-11-06). Waiting offers have no count limit;
  they are not HUD commands and do not count against `hud_allowance`.
- Review fix (2026-11-06): the entry is not open. An agent may leave an offer
  only when the human's authored `gui_receiver_policy/2` already lets it put
  questions before them, the same trust that admits a question into
  `gui_pending/2`. Withdrawal is admitted only to the offer's own contributor.

### Composition and limits

`hud_commands/1` is a signed view the client subscribes to, like
`account_navigation`. Order: standing, then contextual, then contributions in
acceptance order. The authored `hud_allowance/2` bounds the number shown; past
it the strip ends with a "More ▸" sub-pie. **Flagged:** this is an allowance
the human's ontology declares, not a client cap; the default value is an open
decision.

### On click

A click (trigger or left click on the icon, or the strip's keyboard shortcut)
behaves like selecting a pie leaf: a leaf executes or opens its panel; a
sub-pie opens a pie anchored on the icon. The icon shows pressed feedback and
the HUD strip's status sentence reports the outcome in plain words
("Submitted. Waiting for the lighting assistant.").

### Failure and withdrawal

- A contribution whose source read fails (denied, unavailable) stays in place,
  dimmed, and its caption explains: "Unavailable: the assistant's space can't
  be reached." It is never silently dropped, because the human placed it.
- A contribution withdrawn by its contributor or removed by the human leaves
  the strip on the next view update; the status sentence says so once.
- A contextual command disappears with the space; nothing is said.
- The question-count icon shows "0" rather than vanishing.

### VR and desktop behaviour

- VR: a body-locked strip, below the central view (the research digest's
  20–30° below eye level), that tags along: it turns with the body only after
  the head has turned past a threshold, so it never sits in the centre of
  vision and never jitters with the head. Icons are large ray targets with
  labels under them. The strip hides while a pie is open in front of it.
- Desktop: a strip along the bottom edge, auto-hiding after a few seconds of
  pointer rest, back on mouse-to-bottom or any keypress; icons 40 px with
  labels on hover; digits with a modifier select commands.

[HUD with contributed commands](../mockups/godot-hud.mockup.html "width=1200 height=1720")

## 7. Space boundaries seen from inside and outside

Yan's addition (2026-11-05): a space's boundary Eidolon must be visible both
from outside the space and from inside it, and later as "Matrix" walls.

The wireframe exterior already builds a `wire_box` centred on the space's
local origin with the exact interior extents. Seen from outside, the parent
frame places it. Seen from inside, the interior frame *is* the space's own
frame, so the same mark at the origin is the room's walls. One recipe serves
both; what differs is only who selects it.

Proposal, no second Eidolon type:

- Add `have_attribute(space, interior, space_interior, default(none))` beside
  `exterior`, with values `none | wireframe | matrix`. `exterior` keeps its
  `solid | wireframe | contents` values.
- `space_projection/4` places, after the contents parts, the space's own
  boundary occurrence at the interior origin, depicting the space itself, when
  `interior` is not `none`. It uses the same `space_exterior_recipe/2` recipes,
  so a boundary style is authored once.
- The space pie's "Show as ▸" sets `interior` through an offered operation
  (`space_represent` already exists for exterior; add the interior field to the
  same operation rather than a second one).
- **Matrix walls** are a new style `matrix`: the same box with a translucent
  grid surface, emissive green glyph lines on near-black. Walls are drawn
  double-sided so they read from either side.

The concrete gap: `surface/5` has colour, metal, roughness, emission and
textures but no opacity, and the gui-plan already records that adding alpha to
a colour term is not supported. Extend the rendering vocabulary with one
`opacity` permille field (`surface/6`), validated in `gui_scene.pl` and
converted in `Scene.cs`. quod is greenfield: this is a clean format change, no
compatibility shim. The grid itself is a repeating `base_colour` texture, which
`texture_bindings/2` already supports.

## 8. Reused versus new

| | Reused as is | Changed | New |
| --- | --- | --- | --- |
| Client | `ControllerInput` and the `menu` binding; `ScenePanel` picking; `EidolonPanel.Choose`, `OperationsPanel`, `QuestionHub`, `SpatialGui` theme; login card | `OpenXRInput` (list menu → pie, pointer feedback, pie placement); `Main.cs` (fullscreen, chrome removed, HUD mount); `EidolonPanel` (chooser buttons removed) | `PieMenu.cs`, `HudBar.cs`, target resolver (small, in `Main`) |
| Ontologies | `class_eidolons/4`, `entity_eidolons/2`, `gui_operations/2`, `gui_tree_schema/3`, `menu` class, `icon` assets, `gui_pending/2` pattern, `space_represent/5` | `quod_gui.pl` (`menu_item`, `hud`, `hud_command`, `menu` purpose, default recipe), `quod_space.pl` (space menu, `interior`), `user_instance.pl` (HUD instance, policy, view), `gui_scene.pl` (`surface/6`) | `matrix` boundary recipe |
| Removed | — | `WorkspaceMenuEntries`, list menu, header/account/tools/appearance rows, `contentsStatus` | — |

Expected line count: the client loses the list menu and the header/tools
wiring (roughly 150 lines) and gains the pie and HUD controls; the net is
reported at implementation. The ontologies gain the menu/HUD vocabulary, which
replaces nothing but the client's hardcoded list.

## 9. Implementation sequence and verification

1. **Menu vocabulary (Prolog first).** `menu_item`, `menu` purpose, default
   recipe, space recipe. Tests through the signed production seam
   (`quod_gui_examples_tests.erl` style): a note instance yields the default
   pie; a space yields its own; an item on an unauthorized operation reports
   `unavailable` with the pie still complete; labels are binaries. Unchanged
   reads cause no history replay or write (existing tracing).
2. **Pie control.** `PieMenu.cs` drawn in a `SubViewport` so both modes share
   it. Desktop first (right-click, keyboard), then VR through the existing
   consumer calls. Delete the list menu and `WorkspaceMenuEntries` in the same
   change. Headless Godot checks: open, wedge selection by direction at the
   dead-zone threshold, sub-pie placement at the item's position, back node,
   release-in-centre cancels, target withdrawn closes.
3. **Target rule and feedback.** Hover outline and tip label; space fallback;
   unplaced fallback. Check: label text equals the authored name; no label for
   `unlabelled`; the pie opens on the space when the ray misses.
4. **Fullscreen.** Remove chrome; panels float; Esc order (pie → panel →
   nothing). Check the login card still overlays correctly and the question
   receiver still selects.
5. **HUD.** Prolog class, instance, allowance, policy, question-based
   acceptance, withdrawal; `hud_commands` view; `HudBar.cs`. Tests: standing
   commands appear; contextual command appears on entry and disappears on
   leave; a contribution request from an unrelated agent is refused directly
   and succeeds through an accepted question; removal retracts; denied source
   shows dimmed with a reason; allowance overflow nests under More.
6. **Boundaries.** `interior` attribute, interior occurrence, `surface/6`,
   `matrix` style. Tests: the interior wire box has the exact extents; the
   same recipe answers exterior and interior; infinite extent refuses wireframe
   and matrix with the existing reason; the scene validator rejects opacity
   outside 0–1000.
7. **Acceptance.** Sequential clean gates (EUnit, client tests, xref, Godot
   headless), then a physical Vive session for: hover feedback at 2 m, open on
   space, open on instance, nested select by marking without looking after
   three tries, back, confirm Leave, HUD click, strip tag-along without
   jitter. Record frame times. A simulator cannot establish comfort.

## 10. Decisions (Yan, 2026-11-05)

All twelve open questions were decided on 2026-11-05; the recommendations
were accepted except where noted. These are settled, not to be reopened
without new evidence.

1. **Unplaced fallback:** the agent's own pie (Enter a known space ▸, Create a
   space, Your account, Your attention). One model everywhere.
2. **Wedges per level:** authored default of 8 in `quod:gui`, overridable per
   menu recipe; more items nest. Flagged numeric default, accepted.
3. **Client-local commands:** one standing HUD command, "This device", is the
   only client-authored HUD entry for now. Modelling the device as an instance
   in the human's ontology is recorded as a separate to-do (tracker task
   "Model the client device as an instance so 'This device' comes from Prolog").
4. **VR placement numbers:** a client device profile starting at 1.5 m reading
   distance and 15° below eye level, to be measured on the Vive. The only
   numbers the client introduces.
5. **HUD allowance:** 12 commands before "More ▸", declared in
   `user_instance.pl` beside `gui_pending_allowance/2`.
6. **Direct contributors:** the human, the personal agent and the owner of the
   space the agent is placed in; everyone else through an ordinary question.
7. **Leave space confirmation:** a second press on the same wedge inside the
   open pie; the centre reads "press again". No dialog.
8. **Boundary model:** one recipe, two selectors (`exterior` and the new
   `interior` attribute). No inside/outside Eidolon type.
9. **Opacity:** `surface/5` becomes `surface/6` with a permille opacity
   field, as a clean break; validated in `gui_scene.pl`, converted once in
   `Scene.cs`.
10. **Vive control:** the pad press stays the menu action; no action-map
    change.
11. **Hover mode:** not offered.
12. **Icons:** optional image asset on `menu_item` and `hud_command`; the
    label's initials in a disc when absent.

Related, outside this plan: the lens refinement (class-owned lens Eidolons,
encoding as Style) is tracked separately and is not a prerequisite.

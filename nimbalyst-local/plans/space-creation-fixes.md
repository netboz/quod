---
planStatus:
  planId: plan-space-creation-fixes
  title: Space creation fixes after the 2026-11-13 VR test
  status: in-development
  planType: bug-fix
  priority: high
  owner: Yan
  stakeholders: []
  tags:
    - space
    - names-ontology
    - godot-client
    - vr
    - pie-menu
  created: "2026-11-13"
  startDate: "2026-11-13"
  updated: "2026-11-14T02:30:00.000Z"
  progress: 86
---

# Space creation fixes after the 2026-11-13 VR test

Yan's test of client 0.7.288 on the live network (nodes on 0.7.286) found four
things. This plan says what the code does today, what changes, and in what
order. Nothing here is built yet.

## Implementation checklist

- [x] **Phase 1 — New spaces keep their place (client + `quod:space`)**
  - [x] Client: a refresh of the space's view no longer re-anchors the VR world to the head.
  - [x] `quod:space`: "Near my agent" takes the first free place in front of the agent instead of always the same pose.
  - [x] Tests: two and three creations from the same standing point give three different poses and leave the earlier ones unchanged; a view refresh in VR keeps every thing where it was.
- [x] **Phase 2 — Names from `quod:names`**
  - [x] `quod:names`: a `place` kind built from the book's place elements (tables 4-1, 4-2) and its strange syllables (table 5-2); the file's licence note rewritten to say exactly which pages are used.
  - [x] `quod:space`: the `name` slot's default is drawn from `quod:names`, as `doc/proofs.md` already shows for `place`.
  - [x] Creation form: the name field is pre-filled with a drawn name (`gui_initial/3` calls `quod:names`).
  - [x] `quod:names` founded on the live network and listed in root as `system_ontology(quod:names, Anchor)`.
  - [x] Tests: the form opens with a drawn place name; a typed name is kept; a space asserted without a name gets a drawn one; creation fails plainly when `quod:names` cannot answer.
    Built: drawn name in the form and in a nameless assertion (creation, stage-1 and space tests); typed name kept (foreign lane). Not built: a test that creation fails when `quod:names` is absent.
- [x] **Phase 3 — The resize buttons**
  - [x] Reproduce with ray presses on the "−" and "+" of the Width (top) and Depth (bottom) rows of the real creation form.
  - [x] Fix the cause; test with the same presses.
    Not the scroll edges (refuted, 16 ray presses pass). Fixed instead: the panel no longer reaches under the HUD strip (0.7.288 defect); the strip waits while the keyboard is up. Per-press console lines added so the next test shows what a dead press reaches.
- [ ] **Phase 4 — Where the pie's delay goes**
  - [x] Nodes keep every trace (today 1 in 20) and the job file points at Tempo on conrad.
  - [x] Node: time the view's opening steps that have no timing today.
  - [x] Client: one console line per pie (opened, connected, answered, drawn, icons), no on-screen change.
  - [ ] Measure on the live network, name the slow step, and bring the fix back for a decision.
- [ ] **Phase 5 — Release**
  - [x] Server and client gates; docs (`doc/spaces.md`, client README).
  - [x] Commit(s) and version bump on Yan's go.
  - [x] Live: `quod:space` source edit by transaction, `quod:names` founding, client install.
    Done 2026-11-14: commits `a3c536c8` + `0f7aa3d5` (0.7.289), rolling upgrade, `quod:names` founded and listed (anchor `0D5869D9…E53E`), `quod:space` edited, all ten nodes verified (`doc/evidence/space-creation-fixes-20261113/live/report.md`). Client installed to `~/Games/quod` (rollback `~/Games/quod-before-spaces-20261114`).

## 1. A new space moved the ones already there

Two separate causes, both confirmed in the code.

**The VR world re-anchors itself.** When anything commits in the space you are
in, the node asks the client to refresh that space's view. The client treats a
refresh like a loss of the world: `Main.WithdrawWorld` calls
`OpenXRInput.InvalidateWorld`, which forgets the headset calibration. On the
next frame the calibration is taken again from where the head is and where it
faces. So after each creation the whole space jumps to sit in front of your
current gaze. Nothing moved in the ontology; the view did.

Fix: a refresh keeps the calibration. It is reset only when the agent's place
really changes (another space, or unplaced) and on the headset's own recenter.

**Every new space gets the same pose.** `placement_pose/2` in `quod:space`
puts a "Near my agent" space 2 m in front of the agent plus half the marker
(2.25 m), whatever is already there. Two spaces created from the same spot
have identical transforms. The `spaces` journey already met this on
2026-11-12 (`phase3-client-03-stop.md`) and it was only noted.

Fix, in `quod:space`: the same rule looks for a free place. Candidates are on
the same line 2.25 m ahead of the agent: straight ahead, then one step right,
one step left, two steps right, and so on. A place is free when no thing
placed in that space stands within one marker of it. The step is one and a
half markers (0.75 m with the 0.5 m marker), read from `marker_size/1`, so no
new number is stored. Existing spaces are never moved.

Not explained yet: Yan saw the new space "above" the old one. The ontology
has no rule that stacks, and the starting space is not physical. Phase 1 reads
the committed transforms after two creations (local fixture first) before
changing anything, so this is either explained or reported as still open.

## 2. Names from the names ontology

Today `quod:space` declares `have_attribute(space, name, binary,
default(<<"Space">>))`, and the creation form always supplies the name field,
pre-filled with that default.

`quod:names` exists in the repo (`priv/ontologies/quod_names.pl`). It builds
names from recipes over word and syllable tables, so names are generated, not
listed. For places it has one small pool today: culture `landscape`, kind
`world`, built from two of Quod's own word tables (12 × 12 = 144 names such as
"Amber Reach"). `doc/proofs.md` shows the intended use:

```prolog
have_attribute(place, name, binary, default_from(place_name)).
place_name(Instance, Name) :-
    quod:names::draw(<<"landscape">>, <<"world">>, <<"neutral">>, Instance, Name).
```

**Place names from the book (Yan, 2026-11-13: take the place chapter too).**
The Book of Names builds place names by combining elements: a description or
person plus a feature (table 4-1 and the element lists on pp. 151–154), and
for fantasy places a base name plus a vivid or fantasy element, or a fantasy
name alone (table 4-2, p. 160). The fantasy elements come from its strange
syllables (table 5-2, p. 183) and generic fantasy names (pp. 171–181).
`quod:names` gets those tables as `elements/2` facts and a new kind `place`
whose pools are recipes over them, with the recipe forms it already has
(`element`, `concat`, `join`, `one_of`, `rep`). Every name of a pool is equally
likely, so the book's dice weights are not kept.

As built: three pools of kind `place`. `british` joins a description, a
feature and a town ending from table 4-1's "Common" lists (1,040 names:
Greenhill, Ashton, Brookham). `vivid` puts one of the book's vivid example
words on such a base (962: Shadowton, Ravenford). `fantastic` is two strange
syllables, or one on such a base (54,800: Naldor, Targthorpe). A new
`draw(Kind, Salt, Name)` gives each pool of a kind the same chance, as the
existing personal draw does, so the large pool does not drown the others. The
longer per-language element lists of pp. 153–154 are not taken.

Licence, stated plainly: the book releases pages 168–192 and 202–203 as Open
Game Content. Tables 5-2 and the fantasy names are inside that; the place
chapter (pp. 151–161) is not. The header of `quod_names.pl` says today that
only released pages are used; it will be rewritten to list the place pages as
used on Yan's decision. The data is replicated to every node, the cloud ones
included.

Change in `quod:space`: the same two lines for `space`, drawing kind `place`.
The provider runs once in the proposer's proof and the drawn name is stored
as an ordinary slot write, so every validator sees the same name. A supplied
name bypasses the draw (existing rule). If `quod:names` cannot answer, creation
fails with `initial_default_failed(name, …)`; it does not fall back to "Space".

Change in the creation form (Yan, 2026-11-13: "the form should of course be
pre-filled"): the field's initial value is drawn the same way, one clause:

```prolog
gui_initial(space_create(_,_), space_name, Name) :-
    quod:names::draw(<<"landscape">>, <<"world">>, <<"neutral">>, Name).
```

A draw belongs to the proof that makes it, so each time the node re-reads the
form (after something commits, or when the view is renewed) the suggested name
is drawn again. A name the user typed is kept; an untouched suggestion can
change while the form is open.

**`quod:names` is not on the live network.** The network founded on
2026-11-10 lists six system ontologies: agent, controllers, gui, node, space,
user. `quod:names` must be founded through root's ordinary `create_ontology`
action and listed as `system_ontology(quod:names, Anchor)`; every node then
joins it. Known hazard: a node can fail to pick up a new system ontology until
it is restarted (the route-wait latch seen in September); the release phase
checks all ten nodes and restarts only those that did not join.

Existing spaces keep the name they have.

## 3. The resize buttons

In the creation form each length (Width, Height, Depth) is a text field with a
"−" and a "+" button. Yan: the top row's and the bottom row's buttons do
nothing; the middle row's work. The code behind the three rows is identical.
Suspect, to confirm by reproduction: the rows sit in a scroll area that
follows focus. Pressing a button focuses it; if its row is partly outside the
visible area (top or bottom), the area scrolls, the button moves away from the
ray, and the release lands elsewhere, so nothing is pressed.

Phase 3 starts by pressing each button with an injected controller ray on the
real form and fixes what that shows.

**Result of the reproduction (2026-11-14).** Presses on every "−" and "+",
whole or cut by the top or bottom edge of the scroll area, all change their
length in the `spaces` journey: the scroll suspect is refuted. What the
journey did show is a defect of 0.7.288: with the panel 15° below eye level it
spanned 1° to 29° below, and the command strip at 25° below sat in front of
its lower rows, drawn over them and taking every press there. Decided with
Yan: the panel is placed so its lower edge ends where the strip begins (centre
about 9° below eye level), and the strip waits while the keyboard is up. The
top row's failure is not explained; the client now writes one console line per
headset press (what it reached, and what was under the ray at release), so the
next test tells.

## 4. The pie's opening delay

What opening a pie does today:

1. The client opens a new WebSocket to the node (through the edge proxy, with
   TLS) for this one pie.
2. It sends one signed read: `client_menu(Subject, View)`.
3. The node checks the session and signature, then runs the read where the
   subject's ontology lives (forwarding it if another node holds it).
4. `client_menu` selects the subject's `menu` Eidolon. For a space that is
   `space_menu`: three `gui_menu_source` reads (the space, the class, the
   storage), each of which reads the caption of every offered operation, then
   `menu_tree`.
5. Because the pie is a live view, the node then subscribes to every ontology
   the read touched and takes a snapshot of each before it answers.
6. The client draws the pie, and fetches each icon it has not seen yet with one
   signed read per icon.

What is measured so far: almost nothing. The nodes were sending their traces
to the wrong host until 2026-11-13 21:25 (fixed by a job re-run). Since then
five client reads were caught, 6 to 126 ms each (their kind is not recorded,
so they may not be pie reads at all),
and one request that took 476 ms of which the read was 9 ms. Steps 1, 5 and 6
have no timing at all, on either side. The client already measures "opened to
drawn" (`pieReadyMs`) but only prints it in test mode.

Phase 4 makes every step visible, measures on the live network, and brings
back the slow step with a proposed fix. No fix is designed before the numbers.

## Files

| Where | Change |
| --- | --- |
| `client/godot/Main.cs`, `OpenXRInput.cs` | Keep VR calibration across a view refresh; pie timing line |
| `priv/ontologies/quod_space.pl` | Free-place rule in `placement_pose/2`; `name` default drawn from `quod:names`; empty name not supplied by the form |
| `priv/ontologies/quod_names.pl` | Place tables and the `place` pools; licence note |
| `src/quod_client_view.erl` | Timing of the view's opening steps |
| `deploy/quod.nomad` | Trace address default (conrad) and trace ratio as a job variable |
| `client/godot/FormPanel.cs` or `SpatialGui.cs` | Whatever Phase 3 finds |
| `test/…`, `client/godot/tests/…` | Tests named in the checklist |
| `doc/spaces.md`, `client/godot/README.md` | Placement and naming sentences |

## Going live

- `quod:space` is ledger content: its change goes in by the source-edit
  transaction used on 2026-11-12, not by a refound.
- `quod:names` is founded by a root action on one node.
- Both need commands run on a live node. The session's permission check
  refuses those from Claude; Yan either adds a permission rule for
  `nomad alloc exec` or runs the prepared scripts himself.

## Decided with Yan, 2026-11-13

1. The name field is pre-filled with a drawn name.
2. The place pool is built from the book's place chapter and its strange
   syllables.
3. A new space takes the next free place in front of the agent. Placing it
   where the user looks comes later (below).
4. The resize buttons are the "−" / "+" of the top (Width) and bottom (Depth)
   rows of the creation form.

## Later: place a new space where the user looks

Checked on 2026-11-13, for when this is taken up:

- No predicate gives the head's pose in a proof. `doc/player-movement-plan.md`
  keeps head tracking view-only: it is not the agent's movement.
- The physics ontology knows, for a physical space, each body's authored pose
  (`physics_body_definition/6`), the agent's body and motion
  (`physics_agent/5`) and the camera mount on it (`physics_viewpoint/6`).
  Moving poses stay in the simulation's frames; a proof sees one only through
  a signed `physics_sample`.
- Yan's starting space is a plain `space`, not a physical one. Its only
  position is the agent's stored `transform`, read with
  `quod:space::space_location/2`. "Near my agent" reads exactly that.
- So the head's pose exists only in the client and has to travel inside the
  signed goal. `goal(inside(Space, New, Pose))` already takes a pose; what is
  missing is a form input whose value the device supplies (`quod:gui` has no
  such kind), or the agent's `transform` following the headset.

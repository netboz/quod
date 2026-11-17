---
planStatus:
  planId: plan-eidolon-toolkit
  title: Eidolon toolkit — reusable recipes, modes, and the space seen from outside
  status: in-development
  planType: system-design
  priority: high
  owner: Yan
  stakeholders: []
  tags:
    - eidolon
    - ontology
    - godot-client
    - vr
    - design
  created: "2026-11-12"
  startDate: "2026-11-12"
  updated: "2026-11-12T20:22:49.000Z"
  progress: 91
---

# Eidolon toolkit — reusable recipes, modes, and the space seen from outside

Approved by Yan 2026-11-12 ("looks ok"). Nothing here is built yet. Worktree `pearl-stone`; no commit, release or
live ontology edit without Yan's go.

Yan's notes this answers (2026-11-11/12):

- The blue box for a space is ugly: see-through sides, solid corner lines that
  fade along the edges. The edit eidolon looks the same and allows resizing.
- Seen from outside, a space is a fixed-size 3D model you can handle (move
  etc.). It does not carry its inner size.
- The default space is 10 m × 10 m × 10 m.
- Eidolons should be reusable, or built from one toolkit used by most of them.
- One eidolon per mode: display, edition, selected. A whole eidolon just for
  "selected" may be too heavy, but the logic behind it, refined, could be useful.

[Space seen from outside: today and proposed](../mockups/eidolon-toolkit-space-marker.mockup.html "width=1180 height=560")

## Implementation checklist

- [x] Phase 0 — Yan approved the plan; defaults for the open points are listed at the end
- [x] Phase 1 — Shared recipe and helpers in the scene vocabulary (`gui_scene.pl`)
  - [x] `corner_box` mark shape: declaration, fields, `shape/3`, bounds
  - [x] a part may carry its pointed-at and selected surfaces
  - [x] shared `marker` recipe and `extent` subrecipe; colours named once
  - [x] eunit: well-formed scenes; existing recipes give the same marks
- [x] Phase 2 — Godot client
  - [x] draws `corner_box`; switches pointed-at / selected surfaces locally
  - [x] the hardcoded gold tint goes away
  - [x] one real render of the marker kept as evidence
- [x] Phase 3 — Space uses them
  - [x] space display eidolon is the shared marker; inside walls use `extent`
  - [x] default 10 m; placement 2 m plus half the marker's depth
  - [x] outside choice `wireframe` removed; create form loses that field
  - [x] `doc/spaces.md` sentences; Erlang and client tests
- [x] Phase 4 — One mode per shown thing
  - [x] the client shows another mode's eidolon for one thing, in place
  - [x] space edition eidolon: marker plus real-size line
  - [x] a class may offer a `selected` eidolon; none is required
- [ ] Phase 5 — Other recipes move over (predicate boxes, status marks)
- [ ] Phase 6 — Handling: move and resize (own design round, see below)
- [x] Gates, line delta, changed doc sentences, then release on Yan's go (live as 0.7.286 on 2026-11-12, phases 1 to 4)

## How eidolons work today

The design is written in `doc/outdated/client-world-direction.md` §4.1.1
(modelling and edition toolkit), §4.1.2 (ownership and reusable eidolons), §4.3
(selection) and §4.4 (edition). `doc/gui-plan.md` keeps a short summary. The
code follows it, under newer names.

- An eidolon is a recipe, not a drawn object. A class names its recipes with
  `class_eidolon(Class, Purpose, Style, recipe(Ns, Anchor, Name))`.
  **Purpose** is what the user is doing: `playing` (Yan's "display"),
  `edition`, and others already in use (`inspection`, `menu`, `operation`,
  `workspace`). **Style** is a look: `solid`, `wireframe`, `contents`.
- `eidolon(Name, Context, Result)` returns parts; `model/2` turns them into
  marks, the things actually drawn. One recipe may serve several classes, and a
  recipe may nest another through `place_model/5` (the docs' "reusable
  subrecipe").
- The docs' toolkit is the set of helpers a recipe author uses: shapes, named
  parts and groups, alignment, spacing and repetition, reusable surfaces. Built
  so far: `shape/3`, `align/6`, `place_model/5`, `model/2`, and surface recipes
  by material class. Not built: spacing and repetition, and any shared recipe
  for a plain "thing".
- The rendering contract and the modelling helpers were two ontologies in the
  docs. They are now two sections of `gui_scene.pl` inside `quod:gui`.
- A missing edition recipe means "not offered"; it never falls back to the
  display one (§4.1.2).

Where the code stops short of the docs:

- The space view is read in one mode for everything in it. The client always
  asks `playing`.
- §4.4 says edition may apply to one selected thing while the rest keeps its
  normal eidolon. Reading one thing's eidolon in a chosen mode already exists
  (the `eidolon_scene` view), but the client draws it as a picture in the side
  panel, not in place in the world.
- Only the lobby console has a real edition recipe. A space uses the same
  recipe for `playing` and `edition`.
- Each recipe writes its own literal parts. The same blue `#6A90D9` box is
  written three times (`quod_space.pl:448`, `common_predicates.pl:128`, the
  client's fallback colour).
- A mark has one colour and one opacity, so a line cannot fade along its
  length. The look when pointed at is a gold tint hardcoded in the client.
- The Godot client draws only `box`, `wire_box`, `sphere` and `group`; it
  rejects a view containing the vocabulary's other shapes.

## Modes: display, edition, selected

Yan's three modes fit the existing `Purpose` argument without a new idea:
`playing`, `edition`, and `selected` as one more purpose a class may offer.

"Selected" has two different jobs, and they should not cost the same.

1. **Showing what is pointed at or selected.** This must be instant, so it
   cannot wait for a read. The display eidolon already says how it looks in
   those two states: a part may carry a second and third surface. They travel
   with the marks, and the client only switches surfaces. The shared marker
   recipe includes them, so most classes get this for free, and the client's
   hardcoded gold tint disappears.
2. **Showing more once selected** — a size line, grips, a different shape.
   That is another eidolon for that one thing, read when asked and drawn in
   its place while everything else stays in display.

The logic worth keeping from "an eidolon per selected status" is the second
job made general: **each shown thing has a mode, display by default, and the
client can ask another mode for one thing.** Edition needs exactly this
(§4.4), so it is built once and serves both. A class that offers a `selected`
eidolon gets it shown on selection; a class that offers none keeps its display
eidolon with the instant look from job 1. Nothing forces every class to write
three recipes.

| | Read cost | Who writes it | Used for |
|---|---|---|---|
| Pointed-at / selected surfaces | none, sent with the display marks | the display recipe, or the shared marker | instant feedback |
| `selected` eidolon | one read per selection, only for classes that offer it | the class, if it wants one | extra parts on selection |
| `edition` eidolon | one read when editing starts | the class | grips and editable values |

## Shared recipe and helpers

Following §4.1.2: named looks are recipes, construction helpers stay helpers.
Both live in the scene vocabulary of `quod:gui`, next to `model/2`. No new
ontology and no new path.

- **`marker` recipe** — the fixed-size "thing" box: see-through sides, fading
  corner lines, its pointed-at and selected surfaces, a label. One recipe
  serving several classes: a class either names it directly in
  `class_eidolon/4` or nests it with `place_model/5`. First users: space seen
  from outside, predicate boxes, and a class with no recipe of its own (today
  it shows only the text "No matching eidolon").
- **`extent` subrecipe** — a real-size outline in the same corner style, for
  the walls of a space seen from inside.
- **Colours named once**, so recipes stop repeating hex literals.
- **`corner_box` mark shape** — same three fields as `box`. Each of the twelve
  edges is drawn from both corners and fades to nothing toward the middle. One
  mark at any size, like `wire_box`. It cannot be composed from existing
  shapes without about seventy small parts per box.

Spacing and repetition helpers from §4.1.1 are added when a recipe needs them,
not before.

## The space seen from outside

- Its display eidolon is the shared marker with the space's label. One size,
  whatever the space measures inside.
- The outside choice "Full-size finite wireframe" goes away. The create form
  loses its "Exterior representation" field. "Permitted contents" stays:
  ontologies shown as spaces and physics spaces use it.
- Inside a space, "Wire box walls" and "Matrix walls" keep the real size and
  use `extent`.
- Default dimensions become 10 m × 10 m × 10 m (`quod_space.pl:53`).
- Placement becomes 2 m in front of the agent plus half the marker's depth,
  replacing "plus half the new space's depth" (`quod_space.pl:88-107`,
  `doc/spaces.md:158`). With a 0.5 m marker a new space appears 2.25 m away.
- Its edition eidolon (Phase 4) is the marker plus a line giving the real size.

Existing spaces keep their stored `transform`: one created under the old rule
stays 52 m away until moved.

## Handling: move and resize (Phase 6, its own design round)

The marker never changes size, so grabbing a corner cannot mean "stretch this
box to 100 m". Two ways that work at any size:

1. **Corner grip on the edition eidolon.** Pulling a corner changes the inner
   size by proportion, and the size line shows the result ("10 m → 14 m"). On
   release the marker returns to its fixed size and the new dimensions are
   sent. Works for 1 m and for 100 km alike.
2. **From inside.** The walls are at real size; grab a wall corner with the
   ray. Natural for room-sized spaces, useless for very large ones.

Yan, 2026-11-12, after seeing that successive spaces created "near my agent"
land on the same spot: let the user place a new thing before it is created.
It appears kind of see-through in front of them, they move it with the stick,
and the trigger validates the position. He expects this to extend from spaces
to other physical classes, and layout managers for spaces to come later. To be
refined in this phase's design round; placing a new thing and moving an
existing one look like the same gesture.

Both need things that do not exist yet:

- an offered operation that changes a space's `dimensions` slot, with its ACL
  and checks;
- a move operation offered as a form (`space_represent` can change the pose
  today, but nothing offers it);
- a way for a part to say "dragging me fills this field of that operation".
  §4.4 describes it (a control declares its target and operation, and moving a
  handle changes only the draft) and `doc/gui-plan.md` names it as a gap.

## Order and release

1. Vocabulary: `corner_box`, state surfaces, the shared recipes. Existing
   recipes still produce the same marks.
2. Godot client learns them. It must reach the user before any ontology sends
   the new shape: an older client refuses the whole view.
3. Space recipes, default size and placement. Ontology content, delivered by
   the same live ontology edit as 0.7.282/283.
4. One mode per shown thing, then the space edition eidolon.

The browser client is behind already (no `wire_box`). This plan does not bring
it up to date; say if it should.

## Verification

- eunit for the shared recipes and for `well_formed_scene/1` with the new
  shape and state surfaces.
- `quod_lifecycle_single_path_tests` placement (`-52000` becomes `-2250`) and
  default size.
- Client journeys: scene counts and picks with the new parts; pointed-at and
  selected surfaces switch without any read; one real render looked at before
  calling it done.
- Unchanged renewals still rebuild nothing.
- Standing gates with full logs; failures reported, never rerun quietly.

## Defaults taken (Yan approved the plan 2026-11-12 without answering these)

Change any of them by saying so; none is built yet.

1. Marker size stays 0.5 m.
2. Colour: house gray-blue lines, gold when pointed at, as in the picture.
3. Spaces stored with the outside choice `wireframe` are shown with the marker;
   the choice is not kept alive (greenfield, no migration machinery).
4. Delivery: the Godot client is installed locally first so the look can be
   judged; the ontology change follows in one release on Yan's go.
5. On selection a space shows only its selected look; the real-size line
   belongs to the edition eidolon.

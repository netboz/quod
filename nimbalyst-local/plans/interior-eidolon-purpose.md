---
planStatus:
  planId: plan-interior-eidolon-purpose
  title: Eidolons without styles; who chooses which one is shown
  status: in-development
  startDate: "2026-11-16"
  planType: system-design
  priority: high
  owner: Yan
  stakeholders: []
  tags:
    - eidolon
    - quod-space
    - ontology
    - design
  created: "2026-11-15"
  updated: "2026-11-16T15:40:00.000Z"
  progress: 20
---

# Eidolons without styles; who chooses which one is shown

Worktree `pearl-stone` (branch `worktree/pearl-stone`; `/home/yan/src/quod`
master is stale). Read `AGENTS.md` first.

Yan approved the spec page on 2026-11-16 ("it looks right") and gave the go
to build ("let's do the planned changes following our discussion"). Commit,
release and live edits each still need his own go.

## Implementation checklist

- [x] Phase 0 — Yan approved the spec page
- [x] Phase 1 — The spec page replaces the old text
  - [x] `doc/gui-plan.md`, "Entities, Eidolons and marks"
  - [x] `doc/spaces.md`: the `space_represent` and `interior` paragraphs, "Direct depiction"
- [ ] Phase 2 — What I see: the viewer's own choice (`quod_user.pl`, `common_predicates.pl`)
  - [ ] the choice is stored in the user's ontology and changed through `quod:user`
  - [ ] one shared rule applies it wherever a thing is drawn
- [ ] Phase 3 — The inside of a space on the one path (`quod_space.pl`)
  - [ ] inside Eidolons declared with `class_eidolon/4`
  - [ ] walls drawn through `entity_eidolons/4`
  - [ ] no stored `none`; private interior tables removed
- [ ] Phase 4 — "Show as" from the class's list (`gui_forms.pl`, `quod_space.pl`, `quod_gui.pl`)
  - [ ] caption and icon declared with each Eidolon
  - [ ] one shared offer per Eidolon, plus "Default"
  - [ ] the space pie shows the list for what I am looking at
- [ ] Phase 5 — Godot client carries an offered action's name as a term
- [ ] Phase 6 — Tests
- [ ] Phase 7 — Gates, line delta, then Yan's go for the commit
- [ ] Phase 8 — Release, on Yan's go
- [ ] Phase 9 — On a separate go: remove what is left of "style" in the code

## Yan's rulings (2026-11-16)

1. A different look is a different Eidolon. There are no styles. Edition is
   an Eidolon like any other.
2. The class's creator decides which Eidolon is the default. An instance can
   change it.
3. A user, through their agent, can override that for what they themselves
   see. It is stored on the user's side, never on the instance.
4. The pie changes only what I see. The owner changing the instance for
   everyone is done from somewhere else, not designed here.
5. From outside, I point at a space, open its pie, and "Show as" lists its
   outside Eidolons. From inside, the pie of the space I am in lists its
   inside Eidolons. I change the Eidolon I am looking at.
6. Wedges: outside **Default, Solid, Contents**; inside **Default, Wire,
   Matrix**. Captions are one short word.
7. **Default** shows the Eidolon chosen by the instance, or by the class. It
   removes my own choice.
8. Dynamic: an Eidolon added to a class later appears in users' pies by
   itself.

## The spec page (approved)

> **Eidolon.** One way a thing looks. A different look is a different Eidolon.
> There are no styles.
>
> **A class lists its Eidolons.** Each has a name and says what it is for: the
> thing is seen from outside, it is edited, the viewer is inside it. Edition
> is an Eidolon like any other.
>
> **Which one I see.** My own choice if I made one, otherwise the instance's
> choice, otherwise the class's default. The default may be none.
>
> **Where each is stored.** The class default with the class. The instance's
> choice on the instance. My choice in my own ontology, never on the instance.
>
> **"Show as"** is in the pie of the thing I am looking at. It lists the
> Eidolons for what I am looking at, plus "Default". It changes only what I
> see.
>
> **A new Eidolon appears by itself.** An Eidolon added to a class shows in
> the pies with nothing else to change. A wedge has a caption, an icon and the
> name of its Eidolon. A caption is one short word.
>
> *Recipe* and *mark* are words of the code only, not concepts.

In `class_eidolon(Class, Purpose, Name, Recipe)` the third argument is the
Eidolon's name.

## Where the code differs from this page today

1. The third argument is called "style" and used as "which one".
2. The interior is a private table beside the Eidolon path
   (`quod_space.pl:237-243`, `:445-449`, `:480-489`).
3. Nothing lets a viewer choose what they themselves see.
4. "Show as" changes the instance, for everyone (`quod_space.pl:466-468`).
5. Only the inside is offered, and it is broken: creation stores
   `interior none`, the code believes "no fact means none", the first
   "Show as" leaves two facts and no walls are drawn (`quod_space.pl:56`,
   `:226`, `:237`).
6. Captions and icons of the walls sit in a list apart from the Eidolons
   (`quod_space.pl:457-462`).

## A space under the page

| I am | Purpose | The class's Eidolons | Class default | Wedges |
|---|---|---|---|---|
| outside | `playing` | `solid` (the marker), `contents` | `solid` | Default, Solid, Contents |
| editing it | `edition` | the marker with its size | that one | none |
| inside | `interior` | `wireframe`, `matrix` | none | Default, Wire, Matrix |

## Build steps

Predicate and fact names below are code names, mine. The builder may improve
them; no new concept comes with them.

### Phase 2 — What I see

**Stored** in the user's ontology, on the human instance, the way controller
settings are (`quod_user.pl:493`, `attribute(Instance, controller_preferences, …)`):
one fact per thing and purpose, holding the exact `entity_ref/3` of the thing,
the purpose and the Eidolon's name.

**Changed** through `quod:user`, modelled on `controller_preferences_set/5`
(`quod_user.pl:511`): the caller must be the human's own agent
(`personal_agent_owner/1`); one transaction replaces the fact, or removes it
for "Default". Admit the new goals in `signup_invocation/2`
(`quod_user.pl:54-80`).

**Read** by one shared rule in `common_predicates.pl`: for the current
viewer (`quod:user::personal_agent_owner/1`), a thing and a purpose, the name
they chose, if any. No viewer, or no choice, is an ordinary "no": it must
never fail a view.

**Applied** in the two places a thing's Eidolon is picked:

- `client_entity_scene/3` (`common_predicates.pl:202`), after the class has
  answered `appearance(Id, Name, Context, Layout, Eidolons)`: when the viewer
  chose a name for this thing and this purpose, and its classes list it, the
  name and the Eidolons are replaced by `entity_eidolons(Entity, Purpose, Mine, …)`.
- the walls of the space I am in (Phase 3).

A stored choice naming an Eidolon the class no longer lists counts as no
choice.

Reads stay where the facts live, one per drawn thing (Yan: ontology reads are
cheap; no parameter passed around to save a read).

### Phase 3 — The inside of a space

```prolog
class_eidolon(space, interior, wireframe, recipe(Ns, A, space_wireframe)) :- current_ontology_identity(Ns, A).
class_eidolon(space, interior, matrix,    recipe(Ns, A, space_matrix))    :- current_ontology_identity(Ns, A).
```

- The recipes `space_wireframe` and `space_matrix` do not change.
- Slot `interior`: declared without a default (`have_attribute/3`). Creation
  stores nothing. No fact means the class default, none.
- Valid names, one rule per slot, replacing the lists at `quod_space.pl:478-483`:

  ```prolog
  space_exterior(Name) :- class_eidolon(space, playing, Name, _).
  space_interior(Name) :- class_eidolon(space, interior, Name, _).
  ```

- `space_boundary_parts/5` (`quod_space.pl:593`): the name is my choice, else
  the space's `interior` fact, else nothing drawn. With a name, the recipe is
  found by `entity_eidolons(Space, interior, Name, …)` in the storing ontology
  and drawn with `space_entity_model/3` and `place_model/5`, as today.
- `space_represent/7` keeps its seven arguments and changes the instance. For
  the inside, `none` in an argument means "no fact". A changed inside removes
  the old fact and adds the new one. No pie entry calls it any more.
- Removed in the same change: `space_interior_recipe/2`,
  `space_interior_available/2`, `space_interior_of/2`,
  `space_interior_boundary/2`, `space_show_recipe/3`, `space_menu_shows/1`,
  `space_show_form/5` with its attributes and its `gui_form/3`, and
  `default(none)`.
- Walls need a finite size: their recipes already fail on an infinite space
  (`space_extent/4`). A chosen Eidolon that gives no model for this space is
  not offered and draws nothing.

### Phase 4 — "Show as"

**Caption and icon with the Eidolon.** Declared beside each
`class_eidolon/4`, with the two attributes a form already uses, `label` and
`image`, on the Eidolon's own term:

```prolog
attribute(eidolon(space, playing,  solid),     label, <<"Solid">>).
attribute(eidolon(space, playing,  contents),  label, <<"Contents">>).
attribute(eidolon(space, interior, wireframe), label, <<"Wire">>).
attribute(eidolon(space, interior, matrix),    label, <<"Matrix">>).
```

Icons the same way. `wireframe` and `matrix` exist (`quod_space.pl:461-462`).

**One shared offer per Eidolon** (`gui_forms.pl`, so it holds for any class):
for an instance and a purpose with several Eidolons, one offered action per
Eidolon, named `show(Purpose, Name)`, plus `show(Purpose, default)`. Each is a
form with no field and one submit, whose goal is the `quod:user` change of
Phase 2. Its label and image are read from the Eidolon's attributes; "Default"
carries its own. A wedge is not offered for the Eidolon I already see.

Because the offers are derived from `class_eidolon/4`, a new Eidolon with its
caption and icon appears with no other edit (ruling 8).

**The space pie** (`space_menu`, `quod_space.pl:415`): its "Show as" group
keeps its place (slot 2). It holds the offers for `interior` when my agent is
in this space, and for `playing` otherwise. The test is the one "Enter" and
"Leave" already use (`space_travel_context/3`, `quod_space.pl:354-361`).

**The default pie** (`quod_gui.pl:699`): its "Show as" group lists the same
offers for `playing`. Its `edition` entries stay as they are. The captions
`menu_caption(playing, …)` (`quod_gui.pl:664-665`) are superseded and removed.

### Phase 5 — Godot client

An offered action's name is read as a bare atom and sent back as one
(`client/godot/Core/Forms.cs:201`, `:204`; `Accounts.cs:72`;
`OperationsPanel.cs:184`, `:199`, `:209`, `:268`). `show(interior, matrix)` is
a term. Carry the name as a term end to end.

The open world view must redraw after my choice changes. The view names its
dependencies itself (`client_world_view/4`, `common_predicates.pl:34`;
`Main.cs:531`). Check that the user's ontology is among them when the space
is stored elsewhere; add it if not.

### Phase 6 — Tests

Through real production seams, signed requests, no hand-built shortcuts where
real creation exists.

- A space made through real creation stores no `interior` fact.
- Inside it, "Show as" lists Default, Wire, Matrix minus what I see. Matrix:
  walls drawn for me; the space's own facts unchanged. Default: no walls.
- A second user in the same space sees no walls while I see matrix.
- Pointing at it from outside: Default, Solid, Contents minus what I see.
  Contents: I see its contents; the other user still sees the marker.
- An infinite space offers no walls.
- `space_represent/7` on the instance: one `interior` fact after each change,
  none after `none`. Every viewer without a choice sees the change.
- A class given a new Eidolon with caption and icon: the wedge appears, with
  no other edit.
- A stored choice whose Eidolon was removed from the class: the instance's
  Eidolon is shown.
- A reflected ontology still opens, with no walls.
- A view with no viewer (node proofs) still works.
- Cost: opening a pie and reading a world view, before and after, measured.
- Update: `test/quod_gui_menu_tests.erl` (labels, `interior_walls…`),
  `test/quod_lobby_tests.erl:1180-1193` (expected Eidolon list),
  `test/quod_gui_operations_tests.erl:104`, `client/godot/tests/PieChecks.cs:16`.
- Line delta reported, production and tests apart.

### Phase 8 — Release

| What | How it ships |
|---|---|
| `common_predicates.pl`, `gui_forms.pl` | baked in the node image: cold coordinated release |
| `quod_space.pl`, `quod_user.pl`, `quod_gui.pl` | ledger content: one live edit each |
| Godot client | build, installed to `~/Games/quod` |
| tests, docs | with the commit |

With Quod closed:

1. Every existing space stores `interior none` from its creation. Each such
   fact is retracted by a transaction signed by the space's owner. The spaces
   are listed first. Harmless under today's code.
2. Cold release of the image.
3. The three live edits.
4. Client install.
5. Check with two users: one chooses Matrix inside a new space and sees
   walls; the other sees none.

Until this is released, a new space still breaks on its first "Show as".

## For the builder to bring back to Yan, not to decide

- **Icons.** None exists for Default, Solid and Contents. Every wedge of the
  space pie carries an icon today. Ask Yan before drawing or reusing one.
- **Physics.** Showing a space by its contents has a physical meaning today
  (`quod_physics.pl:79`, `:242`). My own choice changes only what I see;
  physics keeps following the instance. If a test shows a real conflict, stop
  and report it.
- **An Eidolon for one instance alone** does not exist and is not built here.
- **The owner changing the instance from the GUI** is "somewhere else"; build
  nothing for it.

## Still different from the page afterwards (Phase 9, separate go)

- The word "style" in code names and comments of files not otherwise touched.
- Edition crossed with the outside choice: an edition Eidolon named `solid`
  and one named `contents`, picked by the `exterior` slot
  (`quod_space.pl:474-477`, `:682-687`).
- The retired `wireframe` outside value still tolerated in `entity_scene/3`
  (`quod_space.pl:686`).
- The specs' world look (`eidolon_policy`) stays in the outdated document
  only; the ruling drops it.

## Not looked at in this plan

How Eidolons are written (shapes, textures, 3D models). Yan, 2026-11-16: "we
will come back on this later on." Known today: the Godot client draws only
box, wire box, corner box, sphere and group (`client/godot/Core/Scene.cs:75`),
no 3D model in the world, and no texture was found applied.

## Who builds it

Opus 5.5 (`claude-opus-5-5`), in the `pearl-stone` worktree, with
`/planning:implement nimbalyst-local/plans/interior-eidolon-purpose.md`.
Gates, builds and release steps: Opus or Sonnet. Review of the finished
change: Fable, on Yan's request.

---
planStatus:
  planId: plan-matrix-walls
  title: "Matrix walls: rain of the space class's real source, as a reusable texture"
  status: in-review
  startDate: "2026-11-16"
  planType: feature
  priority: high
  owner: Yan
  stakeholders: []
  tags:
    - eidolon
    - quod-space
    - godot-client
    - scene-vocabulary
    - vr
  created: "2026-11-16"
  updated: "2026-11-16T23:59:00.000Z"
  progress: 78
---

# Matrix walls: rain of the space class's real source

Worktree `pearl-stone` (branch `worktree/pearl-stone`; `/home/yan/src/quod`
master is stale). Read `AGENTS.md` first.

Yan approved the spec text and the six choices on 2026-11-16 (section
"Yan's decisions"). The approved text is in `doc/spaces.md` and
`doc/gui-plan.md`. Nothing else is built. The commit, the release and any live
edit each still need his own go.

Yan, 2026-11-16: "I asked for a matrix texture and got a black wall with green
borders." He wants the digital rain of the film, made of the space class's real
Prolog code, and "lovely". It must be reusable by any class's Eidolon.

Build model: **Opus 5.5** (`claude-opus-5-5`), with
`/planning:implement nimbalyst-local/plans/matrix-walls.md`.

## Implementation checklist

- [x] Phase 0 — Yan approved the spec text and answered the open questions
- [x] Phase 1 — Spec text in place (`doc/spaces.md`, `doc/gui-plan.md`)
- [x] Phase 2 — Measure before building (`doc/evidence/matrix-walls-20261116/phase2.md`)
  - [x] size and time of the whole-source read of `quod:space`: 83,185 bytes, 6 chunks, 22.8 ms; carries all shared rules
  - [x] world view and pie read times with today's matrix walls (baseline): pie 417 ms, world view 44 ms
- [x] Phase 3 — The `rain` texture in the scene vocabulary (`gui_scene.pl`)
  - [x] the binding and its checks
  - [x] tests in `test/quod_rendering_tests.erl` (`rain_texture_is_typed_and_unique_test`)
- [x] Phase 4 — The space's Matrix walls use it (`quod_space.pl`)
  - [x] recipe replaced; old translucent box removed (letter height 100 mm, to settle in Phase 8)
  - [x] tests: walls, infinite space, Show as; pie 413 ms and world view 43 ms after (417 and 44 before)
- [x] Phase 5 — Godot client reads the binding (`Core/Scene.cs`, `Core/Rain.cs`)
  - [x] decode, text to cells, tests in `client/godot-tests` (also: the world view now names its dependencies, see the report)
- [x] Phase 6 — Godot client draws rain (`ScenePanel.cs`, `rain.gdshader`, font)
  - [x] letter atlas, text texture, shader, material (engine MSDF via `FontFile`, JetBrains Mono NL Bold 2.304, OFL)
  - [x] named source read once through the existing source read (real client vs real server: once, 579 ms, 73,164 letters)
  - [x] engine tests and a captured image (`doc/evidence/matrix-walls-20261116/client-04-matrix-walls.png`)
- [ ] Phase 7 — Other decoders stay in step (the browser accepts rain and draws none)
  - [x] `client/src/marks.js` accepts rain, draws the surface black; test in `client/test/marks.test.js`
  - [ ] bundle in `priv/explorer` rebuilt — BLOCKED by a fault already at HEAD: `ui/src/World.tsx` still uses `EidolonChoice.style`, removed by 0.7.293
  - [x] `client/native` (Rust core, `scene.gd`): no gate builds them; unchanged, reported as dead
- [ ] Phase 8 — In the headset: frame time, letter size, screen glow on and off (needs Yan's headset)
- [ ] Phase 9 — Gates, line delta, report to Yan, then his go for the commit
  - [x] gates: client-04 all pass; server ct/xref/dialyzer pass, eunit 1 physics custody failure that passes alone (`report.md`)
  - [x] line delta: production +400 −18, tests +205 −4
  - [ ] Yan's go for the commit
- [ ] Phase 10 — Release, on Yan's go

## What happened

The 2026-11-05 plan (`godot-main-screen-pie-menus-hud.md` §7) said "emissive
green glyph lines on near-black". The build dropped the letters because the
Godot client draws no texture. Nobody told Yan. Live today (0.7.293),
`eidolon(space_matrix, …)` in `priv/ontologies/quod_space.pl:469` is a
translucent near-black box plus the green `extent` outline. That is all he
sees.

## What exists and is reused

| Need | Existing owner | Where |
| --- | --- | --- |
| The walls are an Eidolon of the space | `class_eidolon(space, interior, matrix, …)`, `eidolon(space_matrix, …)` | `quod_space.pl:453`, `:469` |
| The walls sit in the view | `space_boundary_parts/5`, `eidolon_seen/4`, `place_model/5` | `quod_space.pl:568` |
| The recipe runs in `quod:space` | `space_entity_model/3` calls `in_ontology(Ns, A, eidolon(…))` | `quod_space.pl:648` |
| A surface carries textures | `surface(Colour, Metal, Rough, Emission, Opacity, Textures)`, `texture_bindings/2` | `gui_scene.pl:222` |
| Reading an ontology's source | `prolog_introspection(chunks(Bytes), Chunk)`, `'$quod_source_chunk'/3` | `common_predicates.pl:469`, `quod_common_primitives.erl:362` |
| Who may read a source | `system_source_access/2`: public system ontologies are readable by anyone, `quod:root` and `quod:user` are not | `quod_root.pl:64` |
| The client reading a whole source | `SignedSession.ReadSource`, used by the Source panel | `client/godot/SourcePanel.cs:141` |
| A mark names content, the client fetches it once | `asset(Digest, Mime)` for pictures and models | `gui_scene.pl:229`, `client/godot/RenderModels.cs` |
| Text carried in a mark | `label(Text, Placement)`; `predicate_model` already puts source text in a label | `common_predicates.pl:128` |

## What is missing, said plainly

1. **The scene vocabulary has no texture made of text.** A texture today is a
   JPEG picture in one of three slots (`gui_scene.pl:229`). Owner of the fix:
   `gui_scene.pl`, in `quod:gui`.
2. **The Godot client draws no texture at all.** `SceneSurface.Decode`
   (`client/godot/Core/Scene.cs:53`) refuses every surface whose texture list
   is not empty. `ScenePanel.Look` (`client/godot/ScenePanel.cs:138`) builds
   only a plain `StandardMaterial3D`. Owner of the fix: these two.
3. **The Godot client has no code font.** It uses the engine's default font,
   whose letters have different widths.

Nothing else is missing. No new predicate in Erlang. No new read path.

After this plan the Godot client still draws no pictures (`base_colour`,
`normal`, `orm`). It still refuses them, as today. That is out of scope.

## Design

### 1. Rain, a texture of the scene vocabulary

One more binding in a surface's texture list, beside the pictures:

```prolog
texture(<<"rain">>, Text, glyph(Height))
```

- `Height`: the height of one letter, in millimetres.
- `Text` is one of:
  - `text(Binary)`: the text itself, carried like a label's text. For short
    texts.
  - `source(ontology_ref(Namespace, Anchor))`: the whole Prolog source of
    that ontology. The client reads it once with the read the Source panel
    uses, under the same source policy, and again only when that ontology
    changes. A viewer who may not read that source sees the surface with no
    rain.
- The surface keeps its own fields, with their meaning: `Colour` is the colour
  of the lit letters, `Emission` their brightness, `Opacity` how dark the
  surface is between the letters (1000 is black).
- Rain falls along the mark's own up-down axis. A face that looks up or down
  shows none.
- How the rain moves is the client's drawing of rain, the same for every user
  of it, as the fading of a `corner_box` line is. No shader code and no URL
  travel in a mark.

The word `rain` is new in the vocabulary. Yan chose it (decision 1).

**Why the source is named and not written into the recipe answer.** The
Show-as pie proves each offered Eidolon's recipe when it opens
(`gui_forms.pl:397`; 0.7.293 build notes: pie 425 ms, world view 19 to
42 ms). A recipe that formats the whole
source would do so again at every pie and every view read, although the source
did not change. Named, the recipe answer stays as small as today and the
source is read once. Yan chose this (decision 2).

### 2. The space's Matrix walls

`eidolon(space_matrix, …)` becomes one box at the space's size whose surface
carries rain of `quod:space`'s own source:

```prolog
surface(Green, 0, 1000, 1000, 1000,
        [texture(<<"rain">>, source(ontology_ref(Ns, A)), glyph(Height))])
```

with `current_ontology_identity(Ns, A)` read in the recipe, which runs in
`quod:space`. The translucent near-black box goes. Opacity is 1000: black,
never grey.

The whole source of `quod:space` as the node stores it is about 117 KB: the
40 KB of `quod_space.pl` and the shared rules every ontology carries
(`common_predicates.pl`, `construction.pl`, `material_policy.pl`,
`gui_forms.pl`, `geometry_schema.pl`). Read in the code, not yet run: the
node loads the shared rules into the same store
(`quod_committed_projection:load_common_predicates/1`) and the whole-source
read lists every stored predicate (`selected_source(all, …)`), so it returns
both and cannot tell them apart. Phase 2 confirms it and measures the size.
Yan chose the whole stored source, knowing this (decision 2).

### 3. How the Godot client draws rain

The technique is the film's own behaviour and the one of the best open
implementation.

- **The letters do not move; light falls.** "The 2D glyphs are in a fixed grid
  and don't move. The raindrops … are simply waves of illumination of
  stationary symbols" (Rezmason [1]). The film does the same: "Except for
  changing glyphs, they remain in place" (Newton [2]). In VR this matters:
  four walls of scrolling letters would give the feeling of moving upward.
  Still letters and falling light do not.
- **One shader, no geometry per letter.** Each pixel finds its cell from its
  place on the wall, in millimetres: column, row, and the place inside the
  cell (matrix-rain-webgpu [3]). The wall stays the one box it is today: one
  draw.
- **Each column has its own speed and start.** A random start moment and a
  speed between half and full, from a hash of the column number (Rezmason's
  `columnTimeOffset` and `columnSpeedOffset` [4]). Brightness is a sawtooth
  of time and row: one at the leading letter, falling behind it, with the
  length of the teeth varied "to keep things interesting" [1]. The fall-off
  has an exponent of about 1.5 so the head stays bright longer [3].
- **Each column shows its own stretch of the text.** White space is dropped,
  so no cell is empty. Column `c` starts at its own place in the text and
  each row below shows the next letter: read top to bottom, a column is real
  code. When the light reaches a cell again, the cell takes the letter of the
  next stretch, so the whole source passes over the walls. A letter changes
  only at that moment, when it is dark.
- **The text is a texture.** One byte or two per letter, built once from the
  text. The shader reads it with `texelFetch`. Any length the engine's
  largest texture holds; a longer text is refused with that reason.
- **The letters are a distance field.** Each letter of the text is drawn once
  into an atlas as a signed distance field: crisp edges at any size and a
  soft halo around the letter from the same sample (Rezmason uses MSDF from
  msdfgen [1]; matrix-rain-webgpu builds a plain distance field at start
  [5]). Godot's own fonts can render MSDF (the engine embeds msdfgen); use
  that first.
- **Colours.** The leading letter is the surface colour pushed almost to
  white. Behind it the surface colour, fading to dark, then to black
  (`trailColor = mix(trail, fade, k/tailLength)` [3]). The head is written
  brighter than 1 so a screen glow, if Yan turns it on, catches it [3].
- **Glow without a screen pass.** The halo comes from the distance field, in
  the wall's own shader. No post-process, so the VR frame keeps its cost and
  foveation stays possible (Godot: foveation "is disabled if post effects are
  used such as glow" [6]). Screen glow (`Environment` glow, available in the
  Mobile renderer [7]) is tried in Phase 8 and decided by Yan: it changes
  every lit thing in the view, not only the walls.
- **Far letters never flicker.** When a cell covers only a few pixels, the
  letter shape fades into a soft streak of the same brightness (edge width
  from `fwidth` [3]).
- **Same in both eyes.** Everything is computed from the place on the wall
  and the time. No screen-space noise.
- **Time.** Godot wraps the shader's `TIME` (project setting
  `rendering/limits/time/time_rollover_secs`, 3600 s by default). The rain
  must show no jump at the wrap and no stutter after hours: column speeds are
  whole multiples of one step so the wrap is seamless.

### 4. Cost

- **Node.** The recipe answer is as small as today. No work per frame. The
  source is read once per client and per change of `quod:space`.
- **Client.** One draw for the walls, as today. Per pixel: two texture reads
  and a little arithmetic. No work on the CPU per frame. No extra pass.
- **To measure, not to assume:** Phase 2 (reads) and Phase 8 (frame time in
  the headset). Numbers go to Yan.

### 5. No limits added

No count cap is introduced. The text's length is bounded only by the engine's
largest texture. The number of cells on a wall is not bounded: the shader
computes them, it stores none. An infinite space draws no walls, as today.

## Yan's decisions (2026-11-16)

Asked with the interactive tool, with the mockup. He took each recommended
choice and approved the spec text unchanged.

1. **The word is `rain`.**
2. **The whole stored source of `quod:space`, named in the recipe.** The
   client reads it once with the Source panel's read, and again when
   `quod:space` changes. It is not written into the recipe answer. He was
   told it is about 117 KB and carries the shared rules.
3. **Letters as written**, in a code font. Not mirrored.
4. **Floor and ceiling are black.**
5. **The green corner lines stay.** Both inside Eidolons keep nesting the
   shared `extent` outline; it keeps the space's name and the pointed look.
6. **Godot only now.** The browser client accepts the texture and shows
   black walls with no rain.

## Spec text (approved by Yan, 2026-11-16)

### `doc/spaces.md`, paragraph "Matrix walls"

> **Matrix walls.** The four walls inside the space are screens of code, the
> digital rain of the film *The Matrix*. The code is the real Prolog source
> of `quod:space`, read from `quod:space` itself: never invented text, never
> a copy kept in the client. It stands on a black wall in columns of letters,
> one letter above the other, so a column read from top to bottom is real
> code. The letters stay where they are; what falls is light. In each column
> a bright point runs down. The letter it reaches lights up, almost white
> green, and the letters behind it fade through emerald to dark, then to
> black. Each column has its own speed, its own starting moment and its own
> stretch of the source. Each new fall of light brings the next stretch, so
> the whole source passes over the walls. The lit letters glow. The rain
> never stops while the walls are shown. A letter has the same real size on
> every wall and in every space, and the walls stay at the space's exact
> size. Far away the letters melt into soft green streaks; they never
> flicker. Floor and ceiling are black. A wall with no light on it is black,
> never grey. The walls are the first user of [rain](gui-plan.md#rain).

### `doc/gui-plan.md`, new section "Rain" after "Eidolons"

> ## Rain
>
> A surface can show a text as rain. Any class's Eidolon can use it; the
> Matrix walls of a space are its first user.
>
> The text stands on the surface in columns of letters. The letters stay in
> place and light falls down each column. The surface's colour is the colour
> of the lit letters, its emission their brightness, its opacity how dark the
> surface is between them.
>
> In the code, rain is one more texture of a surface, beside the pictures:
> `texture(<<"rain">>, Text, glyph(Height))`. `Height` is the height of a
> letter in millimetres. `Text` is `text(Binary)`, the text itself, or
> `source(ontology_ref(Namespace, Anchor))`, the whole Prolog source of that
> ontology. The client reads a named source once, with the read the Source
> panel uses and under the same source policy, and again only when that
> ontology changes. A viewer who may not read the source sees no rain.
>
> Rain falls along the mark's own up-down axis. A face that looks up or down
> shows none.
>
> How the rain moves is the client's drawing of rain, the same for every
> user of it. No shader code and no URL travel in a mark.

## Build steps

Order matters: each phase leaves the tree green. The server phases come
first so the client has a real answer to draw.

### Phase 1 — Spec text (done)

- `doc/spaces.md`: the "Matrix walls" paragraph is the approved text. The
  paragraph above it is unchanged: both inside Eidolons nest `extent`.
- `doc/gui-plan.md`: the approved "Rain" section follows "Eidolons". It
  says "Not built yet"; remove those words when the build lands.

### Phase 2 — Measure before building

Evidence under `doc/evidence/matrix-walls-20261116/`.

- Whole-source read of `quod:space` through the existing read
  (`prolog_introspection(chunks(Bytes), Chunk)`): bytes, time on the node,
  and whether it carries the shared rules. Report the numbers.
- Baseline, same method as `doc/evidence/interior-eidolon-purpose-20261116/`
  (median of 41 signed reads, agent inside a finite room with Matrix walls):
  world view and space pie.

### Phase 3 — `rain` in the scene vocabulary

File: `priv/ontologies/gui_scene.pl` (`quod:gui`, ledger content).

- `texture_bindings/2`: one more clause for
  `texture(<<"rain">>, Text, glyph(Height))`. At most one per surface.
  `Height` a positive integer. `Text` is `text(Binary)` with a non-empty
  binary, or `source(ontology_ref(Ns, Anchor))` with a text namespace and a
  32-byte anchor (as `refers/1` checks an anchor). Rain does not join the
  picture slots of `texture_slot/1`.
- Header comment (lines 3 to 5 and 37 to 41) and the `texture_bindings`
  comment: say what rain is, in the words of the approved section.
- Tests, `test/quod_rendering_tests.erl`, beside
  `texture_bindings_are_typed_and_unique_test`: both forms are accepted; a
  second rain, an empty text, a non-binary text, a zero or negative height,
  a source with a short anchor and an unbound part are refused; a surface
  with a picture and rain is accepted (the slots differ).

### Phase 4 — The space's Matrix walls

File: `priv/ontologies/quod_space.pl` (`quod:space`, ledger content).

- Replace the `walls` part of `eidolon(space_matrix, …)` (line 467 to 474)
  as in Design 2. The letter height is one number in this recipe.
- The nested green `extent(W, H, D, Colour)` outline stays as it is
  (decision 5).
- Floor and ceiling need nothing: rain shows none on faces that look up or
  down (decision 4).
- Tests: `test/quod_space_tests.erl` and the Matrix cases of
  `test/quod_lobby_tests.erl:1195`, `test/quod_show_as_tests.erl`,
  `test/quod_gui_menu_tests.erl`: the walls are one box at the whole
  millimetres of the space's dimensions, with rain naming the exact
  `ontology_ref` of `quod:space`; the view is well formed; an infinite space
  draws no walls and offers none; Show as still lists Matrix and Wire.
- Repeat the Phase 2 reads. World view and pie must not cost more than the
  baseline. Report both sets of numbers.

### Phase 5 — The Godot client reads the binding

- `client/godot/Core/Scene.cs`, `SceneSurface.Decode`: the texture list is
  empty or holds exactly one rain binding. Pictures are still refused, with
  the same message as today. `SceneSurface` carries the rain (text or named
  source, letter height).
- New `client/godot/Core/Rain.cs`, no engine types: text to cells (UTF-8 to
  letters, white space dropped), the set of distinct letters, the index of
  each cell in that set. An empty result (a text of white space only) is
  refused.
- Tests, `client/godot-tests/Program.cs`: both forms decode; a picture, two
  rains, a bad height and a bad anchor refuse; cells and letter set for a
  small Prolog text with spaces, newlines and a non-ASCII letter.

### Phase 6 — The Godot client draws rain

- **Font.** Bundle one code font under an open licence, with its licence
  file beside it as `assets/vive-LICENSE.txt` is, and its origin recorded.
  Proposed: JetBrains Mono (SIL OFL 1.1). The package content check
  (`client/godot/tests/ExportChecks.cs`) lists it.
- **Letter atlas.** Built once per set of letters, when first needed. First
  try the engine's MSDF rendering of the font (`FontFile` with
  multichannel signed distance field; read the glyph images back through
  `TextServer`). Check the calls in the Godot 4.7 documentation before
  writing them. If the engine does not give the images back, draw each
  letter once and compute a plain distance field [5]; say which was used in
  the report.
- **Text texture.** One texel per cell, built once per text.
- **Shader.** New `client/godot/rain.gdshader`: spatial, unshaded, opaque
  when the surface's opacity is 1000. As in Design 3. The first shader file
  of the client: check that the export includes it.
- **Material.** `ScenePanel.Look` (`ScenePanel.cs:138`) returns the rain
  material when the surface carries rain, the plain material otherwise. One
  shader for all; one atlas per letter set; one text texture per text.
  Nothing is updated per frame.
- **Named source.** `ScenePanel` receives a reader from `Main`, as
  `RenderModels` receives its fetch (`Main.cs:160`). It calls the existing
  `SignedSession.ReadSource`; do not write a second source read. Read when
  the mark first appears; read again when the world view reports another
  version of that ontology in its dependencies. Until the text arrives, and
  if the read is refused, the surface shows no rain. A refusal goes to the
  trace, not to a new panel.
- **Tests**, `client/godot/tests/SceneChecks.cs`, on a rendered image of a
  box with rain of a known text:
  - the ground is exactly black; lit pixels are green; some are almost white;
  - two different times give different images; the same time gives the same
    image;
  - the top and bottom faces are black;
  - just before and just after the time wrap, the image is continuous;
  - a far wall (cells of two pixels) has no pixel brighter than its
    neighbours by more than the streak allows: no speckle.
  Keep one captured image as evidence, as `client-01-wire.png` is.

### Phase 7 — Other decoders

`git grep -ln base_colour` lists every decoder of a surface. For each one a
gate still builds:

- `client/src/marks.js` (browser): accept the rain binding and draw the
  surface black with no rain (decision 6). Test in
  `client/test/marks.test.js`. Rebuild the bundle in `priv/explorer`.
- `client/native/core/src/scene.rs`, `client/native/godot/scene.gd`: the old
  Rust core. If a gate still builds them, they accept the binding too. If
  none does, change nothing and report them to Yan as dead; do not delete
  them in this work.

### Phase 8 — In the headset

With Yan's headset, in a room of ordinary size and in a large one:

- frame time with Wire and with Matrix walls;
- the letter height that reads well at the middle of the room;
- screen glow off and on (`Environment` glow in `ScenePanel._Ready`), with
  the frame time of each. It stays off until Yan decides.

### Phase 9 — Gates and report

The standing clean sequential gates (server: eunit, ct, xref, dialyzer;
client: all steps), full logs kept under the evidence directory. Line delta
of production and test code. Growth is expected: this is a new capability.

## Release path

| File | Kind | How it ships |
| --- | --- | --- |
| `priv/ontologies/gui_scene.pl` | ledger content of `quod:gui` | Yan's choice: clean refound (as 0.7.293) or a live edit of the system ontology |
| `priv/ontologies/quod_space.pl` | ledger content of `quod:space` | the same |
| `client/godot/**` | client build | export, then the staged install to `~/Games/quod` |
| `client/src/marks.js` | browser bundle in `priv/explorer` | rebuilt bundle, baked in the image |
| Erlang | none expected | — |

The server side must be live before the new client matters: an old client
refuses a surface with rain, so the two ship together. The version bump is
its own commit, patch digit only.

## What to bring back to Yan

1. The Phase 2 numbers: size of the whole source, whether it carries the
   shared rules, read time.
2. The Phase 4 numbers: world view and pie, before and after.
3. A captured image of the walls, and the walls themselves in the headset.
4. Phase 8: frame times, the letter height, screen glow off and on. His
   decision on glow.
5. Which letter atlas method was used, and the font.
6. The film lights a white head on about one string in five [2]; this spec
   lights one on every column. Changing it is one number in the shader.
7. Dead decoders found in Phase 7.
8. The release path: refound or live edit.
9. Then his go for the commit.

## Mockup

[Matrix walls: animated mockup of the rain](../mockups/matrix-walls.mockup.html "width=1200 height=760")

Made from the real text of `priv/ontologies/quod_space.pl`. It shows the
look Yan chose from: its switches show decisions 3, 4 and 5 and their
alternatives. It is a browser drawing, not the Godot shader. Its font here is
DejaVu Sans Mono.

## Sources

1. Rezmason, *matrix*, README: fixed grid, falling illumination, sawtooth,
   MSDF glyphs, bloom then palette, cursor brightness.
   <https://github.com/Rezmason/matrix/blob/master/README.md>
2. Carl Newton, *An analysis of the behaviour of the digital rain in The
   Matrix*: glyphs remain in place; one string in five has a highlighted
   leading glyph. <https://carlnewton.github.io/digital-rain-analysis>
3. F. Chiarelli, *matrix-rain-webgpu*, "Glyph rendering": one fragment
   shader, pixel to cell, trail fall-off, head emission, `fwidth` edges.
   <https://chicio.github.io/matrix-rain-webgpu/how-it-works/glyph-rendering/>
4. Rezmason, *matrix*, `shaders/glsl/rainPass.raindrop.frag.glsl`: per-column
   time offset and speed, sawtooth brightness.
   <https://github.com/Rezmason/matrix>
5. *matrix-rain-webgpu*, "SDF glyph atlas": distance field built once at
   start, one layer per glyph.
   <https://chicio.github.io/matrix-rain-webgpu/how-it-works/sdf-atlas/>
6. Godot documentation, "OpenXR settings": foveation and post effects.
   <https://docs.godotengine.org/en/stable/tutorials/xr/openxr_settings.html>
7. Godot documentation, "Environment and post-processing": glow.
   <https://docs.godotengine.org/en/stable/tutorials/3d/environment_and_post_processing.html>
8. Godot documentation, "Spatial shaders": `unshaded`, `TIME`, `EMISSION`.
   <https://docs.godotengine.org/en/stable/tutorials/shaders/shader_reference/spatial_shader.html>
9. godotshaders.com, "Matrix Rain" (2D canvas shader with a character sheet;
   read, not used: it scrolls the letters).
   <https://godotshaders.com/shader/matrix-rain/>

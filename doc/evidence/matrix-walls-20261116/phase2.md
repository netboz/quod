# Phase 2: before building (tree 7b5a4d8c, uncommitted spec docs only)

Run: `quod_matrix_walls_cost_tests.erl` copied into `test/`, run alone
(`rebar3 as test eunit --module=quod_matrix_walls_cost_tests`), then removed.
Log: `cost-before.log`. The read source itself: `space-source.pl`.

## Whole-source read of quod:space

The Source panel's goal, as a cursor through the signed human path:
`quod:gui::prolog_source(ontology_ref(quod:space, A), Source)`.

| | |
|---|---|
| bytes | 83,185 (666 lines) |
| bytes that are not white space | 73,140 |
| chunks | 6 (16 KB each, `source_chunk_bytes(16384)` in quod:gui) |
| complete read, median of 21 (in-process, no HTTP) | 22.8 ms |

It carries the shared rules. Heads from every shared file are in it:
`system_prolog_introspection(` (common_predicates.pl), `with_build_plan(`
(construction.pl), `material_default_limit(` (material_policy.pl),
`gui_compile(` and `gui_component_tree(` (gui_forms.pl),
`physics_frame_path(` and `physics_native_scalar_limit(` (geometry_schema.pl),
`space_whole_mm(` (quod_space.pl). The test's own markers for gui_forms and
geometry_schema said `false` only because the node writes `name / arity`
with spaces.

The plan said "about 117 KB": that is the size of the six files on disk, with
their comments. The node stores clauses, not files: comments are gone,
variables are written `V0`, `V1`, … and the text is the node's own layout.
So the rain shows the code as the node holds it.

Fixture note: the menu fixture's root holds facts only, so the test adds
`system_source_access(ontology_ref(quod:space, A), read_only)` to stand for
quod_root.pl's rule (live, quod:space is a public system ontology).

## Baseline, the instance choosing Matrix walls (today's translucent box)

Median of 41 signed reads after 5 warm-ups, agent inside a 4 × 3 × 5 m room.

| read | median |
|---|---|
| space pie (`client_menu(room, V)`) | 417.4 ms |
| world view (`quod:space::world_view(Room, playing, M)`) | 44.3 ms |

For comparison, interior-eidolon-purpose `cost-after.log` (Wire walls, same
method): pie 411.4 ms, world view 41.8 ms.

## Phase 4: the same reads on the new recipe

Log: `cost-after.log`; source: `space-source-after.pl`.

| read | before | after |
|---|---|---|
| space pie | 417.4 ms | 413.1 ms |
| world view | 44.3 ms | 43.2 ms |
| whole source of quod:space | 83,185 B, 22.8 ms | 83,287 B, 23.2 ms |

The recipe answer stays the size it was; the source grew by the new recipe's
102 bytes.

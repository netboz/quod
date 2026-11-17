# Panel and form ontologies — review (Fable, 2026-11-11)

Read-only review of `quod_gui.pl`, `gui_forms.pl`, `gui_instance.pl`,
`gui_measure.pl`, `gui_tools.pl` and the form/menu parts of `quod_space.pl`.
Nothing was built or run for it. CONFIRMED = call path traced in code;
PLAUSIBLE = reasoned, not traced end to end. Nothing here has been changed.

Cost context: every open view is a full signed proof, and
`quod_client_view.erl:792` asks the client to re-read on any height change of
any dependency ontology. Each cost below is paid again whenever anything
commits in a dependency.

## Findings, most severe first

1. **Menu captions build the whole form tree and throw it away.** CONFIRMED.
   `gui_forms.pl:334-341` (`gui_form_caption/5`) calls `gui_component_tree/5`
   (`:102-116`), which walks every child and its attributes, then keeps only
   the root's label and icon. For the three create-space forms this re-derives
   the placement options (finding 3) and one icon ask each, per pie.
   Direction: read the root's own `instance_of`/`attribute` rows only.
2. **A space's pie reads complete menu sources to pick single items.**
   CONFIRMED. `quod_space.pl:370-395`: `gui_menu_source` three times in the
   storing ontology, then once in full per contained child space to keep only
   its `enter` item. Same pattern at `quod_gui.pl:1067-1071` and `:1157-1160`.
   Direction: ask for the one exact choice through `gui_menu_item/3`.
3. **The Placement options are a live list of every space in the storing
   ontology, inside the form schema.** CONFIRMED. `quod_space.pl:249-253`;
   options enter the revision at `gui_forms.pl:76-78`. Creating any space there
   changes the revision of all three create forms. This is the ontology-side
   cause of the grey Create button. Cost: 1 ask to list spaces + 1 per space
   for its name, per compile, ×3 forms, on caption and offer paths. The list
   also ignores `space_admit`, so it offers destinations submit will refuse,
   and an explicit destination uses pose `transform(0,0,0,…)`, exactly where an
   entering agent stands. Yan's call: keep stable choices (in front of me,
   nowhere yet, this space) and stop publishing the inventory as schema.
4. **Opening one operation compiles all of the subject's operations.**
   CONFIRMED. `gui_forms.pl:238-272`: the client asks `gui_operations/2` and
   filters by name locally; per operation the ontology repeats
   `gui_operation_subject`, the `class_eidolons` scan and three asks to the
   form owner. Direction: ask the per-operation owner `gui_operation_view/3`.
5. **Every submit compiles, binds and authorizes the form twice.** CONFIRMED.
   `gui_forms.pl:284-308`: `gui_operation/6` binds, then calls the returned
   goal whose guard binds again. Direction: bind once inside `gui_operation/6`;
   keep the guard only on the goal `gui_operation_bind/7` hands out.
6. **An authoring error makes an operation vanish with no reason.** CONFIRMED.
   `gui_forms.pl:244`, `:326` (`findall` swallows failure); `:113-114`,
   `quod_gui.pl:343-351`. A missing label or empty option list silently removes
   the operation from offers and pies.
7. **The vocabulary accepts a component kind the Godot client rejects.**
   CONFIRMED. `quod_gui.pl:66-67,139` (`image`, `icon`) vs
   `client/godot/Core/Forms.cs:17-23`. One such form would fail the whole
   operations projection for its subject. No authored form uses it today.
8. **Property values are validated by key against any class's type.**
   CONFIRMED. `quod_gui.pl:356-357`; the special case at `:303` exists because
   of it.
9. **Icons are fetched by a cross-ontology ask on every compile and caption.**
   CONFIRMED. `quod_space.pl:241-243, 340-341, 378, 414-416`;
   `common_predicates.pl:168-175`.
10. **Opening a question re-proves the same checks inside one transaction.**
    CONFIRMED. `quod_gui.pl:792-804`, `:723-728`, `:952-963`, `:1025-1031`.
11. **`quod:gui` hardcodes the personal agent's instance name.** CONFIRMED.
    `quod_gui.pl:1063, 1093, 1095`; the owner of that name is
    `quod_user.pl:295-298`.
12. **The storage chooser asks a remote identity for every foreign-owned class
    before checking whether it offers anything.** PLAUSIBLE.
    `gui_forms.pl:219-225`.
13. **Predicates with no production caller** (grep over `priv`, `src`,
    `client`, `ui`): `gui_schema/3`, `gui_values/3` (`gui_forms.pl:32, 147`),
    `gui_question_view/4` (`quod_gui.pl:826`). CONFIRMED.
14. Smaller: `common_predicates.pl:178-185, 221-225` recomputes
    `entity_eidolons` to validate a choice it just produced;
    `quod_gui.pl:298-300` recomputes the attribute contract per component;
    `gui_tools.pl:743` workbench link layout is quadratic;
    `quod_space.pl:66-69` three `convert` asks per dimensions check.

## Strings worth rewriting (all in `quod_space.pl` unless noted)

| Line | Current | Proposal |
|---|---|---|
| 244 | "The personal agent's human is the default owner, independently of the selected storage and placement. Creation does not enter the new space." | "You will own it. You stay where you are." |
| 246 | "The class default is supplied. Change it to use your own name." | drop |
| 252 | "Near my agent, or unplaced when my agent is unplaced" | "In front of me" |
| 253 | "Unplaced" | "Nowhere yet" |
| 255 | "Exterior representation" | "Looks like" |
| 257, 260 | "Small solid cube" / "Full-size finite wireframe" / "Permitted contents" | "Small cube" / "Full-size outline" / "What is inside" |
| 261-262 | wireframe / infinite help paragraphs | "Outline shows the real size." / "An infinite space has no outline." |
| 239 | "Create space with rational lengths" | "Create space (exact fractions)" |
| 269 | divisor help | "Length = number ÷ this." |
| 342-343 | travel help paragraph | drop |

The default create form shows seven controls where the name alone would do.

## Checked and found fine

Revision digest coverage (`gui_forms.pl:73-78`); submit re-validates values
and re-authorizes; `gui_bind_fields` determinism; `gui_value/3` families do not
overlap; menu slot arithmetic; `gui_measure` prefix parsing; no "account"
wording in user-visible strings in scope.

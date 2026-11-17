# Application forms

These examples use the shared GUI schema, field binding and question completion
rules. Their production-seam test opens forms through `gui_open/2`, submits
answers and lets the real hosted agent apply the bound continuation. The test
client acknowledges native presentation through the authenticated socket;
headset ergonomics still require hardware validation.

## Lobby atmosphere

Compose [lobby_atmosphere.pl](../priv/ontologies/lobby_atmosphere.pl) with the
ordinary lobby behavior and [gui_instance.pl](../priv/ontologies/gui_instance.pl).
Supply panorama choices, a current preset name and the application's policy:

```prolog
atmosphere_panorama(belfast_sunset_puresky, <<"Belfast sunset">>).
atmosphere_panorama(dusk, <<"Dusk">>).
attribute(personal_sky, preset_name, <<"Original">>).

gui_question_policy(atmosphere(personal_sky), Human, Actor) :-
    lobby_owner(Human), atmosphere_responder(Actor).
```

The panorama values must name assets available to the containing application.
The test's `dusk` choice exercises field binding, not asset loading.

The `atmosphere(personal_sky)` form contains Appearance and Lighting groups:
preset text, panorama selection, brightness slider and rotation knob. The
ordinary component instances provide labels, ranges and units. A submitted
answer binds the authored `atmosphere_entered/5` continuation, replacing the
sky's existing attributes together. Diameter, tint and sky identity remain in
their existing owner. Brightness is expressed in permille: `650` means 65%.

```prolog
gui_form(atmosphere(S),
    [field(preset(S), Name), field(panorama(S), Panorama),
     field(brightness(S), Brightness), field(rotation(S), Rotation)],
    submit(apply_atmosphere(S),
           atmosphere_entered(S, Name, Panorama, Brightness, Rotation))).
```

Removing a panorama choice changes the schema revision, so an old draft cannot
submit against the retired choices. Initial editable values remain a separate
projection: applying new values does not change the component schema.

## Independent instrument

Compose [instrument_configuration.pl](../priv/ontologies/instrument_configuration.pl)
with the same shared form behavior, then supply an ordinary component instance,
its current configuration and the authorized human/responder policy:

```prolog
instance_of(instrument, analyzer_a).
instrument_configuration(analyzer_a, <<"Baseline">>, hold, 20, 0,
                         false, [left], <<"">>).
gui_question_policy(instrument_settings(analyzer_a), Human, Actor) :-
    instrument_operator(analyzer_a, Human), instrument_responder(analyzer_a, Actor).
```

The seven inputs are run name, mode, gain, phase, enabled state, active channels
and notes, composed into General, Tuning and Channels tabs. Enabled is a toggle,
notes are multiline text, and the channel table binds stable IDs through ordinary
multiple selection. Choosing both rows binds `[left, right]`.
The continuation replaces the single current configuration. There is no world,
space, physics process or accumulating answer history.

## Shared lifecycle and presentation

[quod_gui.pl](../priv/ontologies/quod_gui.pl) owns question transitions, HUD
behavior and their recipes. The responsible actor's and human's storing
ontologies hold the rows, ACLs and completion reaction. The application grants its
normal domain authority through `gui_question_policy/3`. The shared committed
assertion reaction correlates accepted fields to the retained completion request;
neither example declares `react_on` or sends a client-provided executable goal.

Open either form from its application ontology:

```prolog
current_ontology_identity(Ns, Anchor),
quod:gui::gui_open(form_ref(Ns, Anchor, atmosphere(personal_sky)), Question).
current_ontology_identity(Ns, Anchor),
quod:gui::gui_open(form_ref(Ns, Anchor, instrument_settings(analyzer_a)), Question).
```

Each call returns an anchored `question_ref(ResponderNamespace, ResponderAnchor,
question(Id))`. It identifies that opening; it is not the eventual answer. The
human can leave it in the HUD and answer later. Accepted values reach the
authored continuation's variables in a later signed proof.

The responder authorizes the exact application form and human with
`gui_responder_policy(Instance, form_ref(SourceNamespace, SourceAnchor, Form), Human)`.
It supplies `gui_pending_allowance(Instance, Count)` and
`gui_completion_allowance(Instance, Milliseconds)`. The human supplies its own
pending allowance and selects its authenticated receiving connection. Agent-led
opening also requires the human's `gui_receiver_policy(HumanInstance, Actor)`.
The ordinary hosted actor must have the shared completion handler installed.
The `quod:gui` scope uses the governed `quod_gui_predicates` module through normal
ontology founding; source composition does not install runtime capabilities.
The human, application and responder scopes need the ordinary
`quod_agent_predicates` module for authenticated context. GUI completion uses
the shared question handler and requires no additional work predicate module.
Use the existing namespace manager and system
catalogue to serve the anchored GUI capability on a receiving node; an observer
replica suffices, and that node need not host the human or application ontology.

The source application receives all accepted fields together in a fresh signed
proof. Its consequences, question consumption and HUD removal share the existing
atomic transaction. A failed continuation preserves the submitted question.
Repeated questions replace current domain state; ledger history still records
committed changes.

Reopening or refreshing a submitted question automatically reads its completion
status. A certified rejected, aborted or expired completion can be cancelled
under the ordinary policy; an unknown outcome stays unresolved. Observation
never submits the retained completion again.

The same semantic tree feeds the desktop form and spatial workspace panel.
Numeric input and increment/decrement are alternatives to slider or knob
dragging. Presentation, local drafts, panel opacity and keyboard handling belong
to the existing client adapters; the application declarations contain none of
those client details. Tabs preserve one draft across the instrument sections. Selectable lists and tables
share the explicit multiple-selection contract below.

[Production-seam examples test](../test/quod_gui_examples_tests.erl)


## Additional input classes

`quod:gui:text_area` shares `text_box` byte limits and required/read-only behavior;
newlines remain text data. `number_input` shares sliders' integer `range(Min, Max,
Step)` and `unit`, with direct entry and increment/decrement controls.
`checkbox` and `toggle` bind Prolog `true` or `false`; `required(true)` requires
confirmation. `radio_group` binds one stable option ID. `selectable_list` binds
one ID by default, or a duplicate-free list when `multiple(true)` is declared:

```prolog
instance_of(quod:gui:selectable_list, channels).
attribute(channels, label, <<"Channels">>).
attribute(channels, multiple, true).
attribute(channels, required, true).
attribute(channels, options,
    [option(channel(left), <<"Left">>), option(channel(right), <<"Right">>)]).
```

Include `channels` in the form's children and `field(channels, Channels)` in its
`gui_form/3` bindings. The existing continuation receives, for example,
`Channels = [channel(left), channel(right)]`. No per-widget reaction is needed.
Multi-selection initially defaults to `[]`; required lists must be nonempty at
submission. Boolean defaults are `false`, text defaults to an empty binary, and
number inputs default to their minimum. Drafts stay local until submission.

## Composition, displays and local dialogs

`panel`, `group`, `row`, `column`, `grid`, `scroll`, `tabs`, `menu` and `dialog`
use ordinary `gui_children/2`. A grid has `columns` (default 2); a scroll has
`visible_rows` (default 6). Both must be positive integers. Tabs use each child's
label and identity. Their selection, and menu/dialog visibility, stay local.
Closing a dialog preserves the draft and restores focus; it neither submits
fields nor cancels the shared question. Explicit form submission still binds
all declared fields, including those in an inactive tab or closed dialog.

```prolog
instance_of(quod:gui:dialog, advanced).
attribute(advanced, label, <<"Advanced settings">>).
gui_children(advanced, [notes, channels]).

instance_of(quod:gui:table, channels).
attribute(channels, label, <<"Channels">>).
attribute(channels, multiple, true).
attribute(channels, headings, [<<"Channel">>, <<"Purpose">>]).
attribute(channels, options,
    [option(left, [<<"Left">>, <<"Reference">>]),
     option(right, [<<"Right">>, <<"Measurement">>])]).
```

A table uses the same stable-ID selection bindings as `selectable_list`; cell
counts must match headings. The application projects the bounded rows it wants
to expose. Desktop shows columns, and the spatial adapter shows readable rows
with a label for each cell in a bounded picker. Neither adapter queries or
stores another copy of domain records.

`label`, `status`, `help`, `error`, `separator` and `progress` are display-only.
They never appear in `gui_form/3` field bindings. A progress control has an
integer `percent` from 0 to 100. Display properties are part of the projected
schema; changing them changes its revision under the same stale-form rules.

`image` and its `icon` subclass accept an `image` attribute containing
`image(asset(Digest, Mime), resources(Transfer, Pixels))`, with PNG or JPEG
bytes stored as `gui_asset(Digest, Mime, Bytes)` facts in `quod:gui`. The client
reads each digest through the ordinary signed path, checks SHA-256 and the
authored byte/pixel allowances, and reuses the verified texture by digest.
Changing `gui_icon/2` refreshes dependent live views through their existing
installed-change subscriptions. Supply a descriptive `label`. An `icon_button` is an
ordinary button with that image attribute and a verb label; it uses exactly the
same activation and submission path. There are no image URLs or client
callbacks in the ontology. Godot reuses verified asset bytes; the existing
browser adapters have not adopted this image shape.

## Voxel world generation

Compose `voxel_world.pl` and `voxel_world_gui.pl` with the existing GUI instance
bundle. Classify a world slot with `instance_of(voxel_world, World)` and present
`voxel_generation(World)` through ordinary `gui_question_policy/3`.
Classification alone allocates nothing. Supply the usual vocabulary, responder
and permissions, plus world-specific physics/voxel allowances and initial
chunk selection. Creation and regeneration require their explicit domain ACLs.

The eight fields compile a preset into an authored field definition. Ownership
is assigned to the human in the question policy, while the authorized responder
performs the existing transaction. The form's exact world/patch basis becomes
part of its revision: digging invalidates a previously opened regeneration
form. Regeneration requires an empty physical world without persistent edits;
the help text directs the user to a new world to preserve an edited landscape.

Compose [voxel_world_view.pl](../priv/ontologies/voxel_world_view.pl) and the
ordinary space view to display terrain through its class-selected Eidolon.
Supply exact `modelling_vocabulary/2` and `rendering_vocabulary/2` references,
one `voxel_presentation/5` row, and the application's ordinary view permissions.
The same space may contain other admitted or decorative subjects.

Two further forms use the same question policy and responder:

- `voxel_excavation(World)` submits world coordinates and sphere radius in
  millimetres. Supply `voxel_brush_controls(World,CoordinateRange,RadiusRange)`
  using ordinary `range(Min,Max,Step)` terms, and grant the responder
  `can_edit_voxel_world/3` under the application's policy. Its exact definition
  and patch basis rejects intervening edits; completion commits the dig and
  consumes the question together.
- `voxel_view_settings(World)` changes viewing distance in metres. Supply
  `voxel_view_range(World,Range)` and `can_manage_voxel_world(World,Actor,view)`.
  Prefetch, retention and resource allocation remain authored presentation
  policy. Distance changes preserve physical revisions and existing digs.

Open these forms with `gui_open/2`. Pointer sculpting and moving a flying lobby
into the world remain separate integration work.

## Personal world library

Compose [lobby_worlds.pl](../priv/ontologies/lobby_worlds.pl), the terrain and
GUI sources with the ordinary personal lobby. The console's **My worlds**
workspace derives its rows from owned `voxel_world` instances. Creation uses
the same generation controls and an optional display name. A blank name draws
once from the pinned naming vocabulary's `landscape/world/neutral` pool and
saves that result with the world. Duplicate labels are allowed; exact anchored
space references identify selections.

Each world has its own physics authority and controlled pilot. Entering selects
that space through the shared signed view and physics initializer; returning
selects the exact personal lobby. The form responder uses the existing hosted
agent and accepted-question completion. A configured host declaration and
installed runtime readiness are distinct states.

The initial viewing distance and its prefetch/retained border scale with ground
detail, keeping a fine-detail world's initial chunk count bounded. Viewing
distance remains an ordinary form setting. A generated view that exceeds its
authored rendering allowance reports the resource, required amount and limit;
the user can return to the lobby and choose a smaller distance without changing
the saved terrain or disabling its physics owner.

Fresh human creation uses the exact terms authored by
[quod_user.pl](../priv/ontologies/quod_user.pl): qualified memberships, slots,
seven vocabulary pins, ACL clauses, a completion reaction and the two hosting
derivations. The existing creation owner freezes those terms into one genesis.
Shared behavior stays at the class owners; HUD allowances, pending references,
keys and hosting facts remain in the user's ontology. The personal actor uses
its own vault key independently of U's browser key. Setup asserts ordinary
parentless S0 in the selected storing ontology and places the same A there in
one transaction. It does not commission the optional physical lobby preset.
Existing human and lobby ontologies require authorized edits; opening the
workspace never installs or repairs source.

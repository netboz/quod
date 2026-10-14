# Application forms

These examples use the shared GUI schema, field binding and question completion
rules. Their production-seam test covers accepted questions through submission,
application and cleanup. Native `gui_open/2` admission is still unfinished; the
test supplies accepted rows explicitly and does not establish live-opening or
headset acceptance.

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
and notes, composed into General, Tuning and Channels groups. Boolean and list
values use ordinary selection options; they need no additional renderer or
serialization. For example, the Stereo option binds `[left, right]` directly.
The continuation replaces the single current configuration. There is no world,
space, physics process or accumulating answer history.

## Shared lifecycle and presentation

The responsible actor's ontology composes
[gui_question.pl](../priv/ontologies/gui_question.pl); the human's ontology
composes [gui_hud.pl](../priv/ontologies/gui_hud.pl). The application grants its
normal domain authority through `gui_question_policy/3`. The shared committed
assertion reaction correlates accepted fields to the retained completion request;
neither example declares `react_on` or sends a client-provided executable goal.

The source application receives all accepted fields together in a fresh signed
proof. Its consequences, question consumption and HUD removal share the existing
atomic transaction. A failed continuation preserves the submitted question.
Repeated questions replace current domain state; ledger history still records
committed changes.

The same semantic tree feeds the desktop form and spatial workspace panel.
Numeric input and increment/decrement are alternatives to slider or knob
dragging. Presentation, local drafts, panel opacity and keyboard handling belong
to the existing client adapters; the application declarations contain none of
those client details. Grouped controls are implemented here; this example does
not claim tabs or free-form channel multi-selection.

[Production-seam examples test](../test/quod_gui_examples_tests.erl)

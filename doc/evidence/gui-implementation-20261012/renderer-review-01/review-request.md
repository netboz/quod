# Common component renderer implementation review

Read `tree/AGENTS.md`; review this frozen tree, not concurrently changing files.
This is the user's explicitly requested Fable implementation review. Advice is
consultative; do not claim approval, test execution or headset acceptance.
Do not modify code, run commands/tests or start another agent. Save findings
to sibling `fable-review.md` with source references and concrete failures.

The existing Babylon workspace renderer now handles nested column/row groups,
sliders, rotary knobs, direct numeric entry, steps and background-only opacity.
Existing proof/source controllers stay the owners. The common component decoder
replaces the old flat form decoder; built-in ontology views now emit component/4
too. `text_box` and `selection` replace renderer input/choice aliases. The
dedicated source editor remains existing `editor`, not a duplicate editor.
The component instance helper is supplied as context; its signed foundation
gate passed 114 tests before the descriptor migration. A new impacted backend
gate is running; do not infer its result.

The real MCP browser exercises the same Babylon fixture and shared Node
assertions as the normal browser driver. It passed the complete common-control
case after a real scroll-height regression was found and fixed. The old flat
fixture's RAF stalled offscreen; it now drives actual completed scene frames.
Observer retirement checks use Babylon's public `hasObservers`, which ignores
already unregistered observers pending asynchronous array compaction.

Review protocol portability, malformed descriptors, callback authority boundaries,
exact integer grid behaviour, nested disabled/read-only state, pointer and
keyboard lifecycle, row layout/clipping, opaque controls/text, schema replacement
and existing proof/source behaviour. Question opening/lifecycle/HUD and a general
desktop DOM adapter are not implemented by this slice; do not mistake this
browser rendering test for those or for headset ergonomics.

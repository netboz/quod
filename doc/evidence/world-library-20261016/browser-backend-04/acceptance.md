# Isolated browser observations

The normal development app at loopback port 5128 uses a disposable factory
backend, its real authenticated endpoints, hosted responder, signed GUI
presentation and world stream. No live user ontology was changed. Fixture key
material stays in its owner-only temporary metadata file and is not evidence.

- Created `Wild Horizon` with a blank name and the meadow preset. The naming
  ontology supplied the saved label. Entered it and observed rendered green
  terrain and `Physical space ready.`
- Returned to the personal lobby and observed `Physical space ready.`
- Created `Highland Retreat` using an entered name and the highlands preset.
  Entered it and observed snowy terrain and `Physical space ready.` Both rows
  remained in the library with distinct exact references.
- Selected `Wild Horizon` from the second world. Opened its existing viewing
  distance form and submitted 24 metres. Ordinary signed reads confirmed the
  changed presentation distance and unchanged definition, terrain revision 1
  and physics structure 3; see `observations.json`.

Screenshots: `.nimbalyst/transcript-images/owned-world-ready-1792191854131.png`
and `.nimbalyst/transcript-images/highland-retreat-entry-1792192037013.png`.

Limitations: this is a headless browser. MCP pointer clicks did not consistently
activate controls, so actual DOM button click handlers and normal form change
events were used. No API results or controller state were fabricated. Chromium
refused pointer capture with `The root document of this element is not valid
for pointer lock.` Walking, slope traversal and cave travel are not claimed.
During a development hot update after an EOF-only source edit, the open form's
presentation closed; reloading and reopening the still-pending question
restored it without resubmitting the opening operation. Backend restart is
covered separately by real-owner integration, not this browser run.

Final return to the lobby reached `Physical space ready.` Re-entry to the
24-metre world remains stalled. A bounded, payload-free WebSocket observation
records a valid projection, outgoing terrain interest and frame acknowledgement,
then no incoming terrain manifest. See `reentry-wire-observation.json`. This is
being reproduced through the real runtime/physics owner; it is not dismissed as
a headless rendering issue. This record does not claim full acceptance.

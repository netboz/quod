# Final Vive acceptance

The software gates do not establish headset comfort. Run this final session on
the intended HTC Vive, through the configured HTTPS/WebXR path, with both base
stations tracking and charged controllers. The [hardware fixture](../../client/test/gui-hardware.fixture.js)
uses the production spatial adapter and records local input only; signed
lifecycle and authority checks are covered separately by the production-owner
suite. Do not launch it automatically while Yan is away.

- Enter VR from rest. The panel appears only after a tracked pose and remains
  stationary when looking away and back. Repeat hide/show and leave/re-enter.
- Check readable text and opaque controls against bright and dark backgrounds.
  Adjust opacity and larger text; confirm bounded scrolling without clipping.
- Use Move/Place, Recenter and distance controls while seated and standing.
  Confirm comfortable reach and no unwanted panel motion.
- In Instrument, type with the virtual keyboard, edit multiline notes, choose a
  mode, toggle Enabled, use slider and knob plus numeric alternatives, and scroll.
- In Tables, images and dialogs, select and deselect the last table row, open and
  close Settings and Tools, preserve edited notes, restore focus, and read images
  and their labels. Closing a transient must not submit the form.
- In Input alternatives, try direct number entry, checkbox, radio group and
  multiple selection. Confirm that targets remain readable and selectable with
  larger text and indirect controller input.
- Press Record control check. Confirm the recorded confirmation is readable
  inside the headset, and inspect the recorded values and error report.
- Record Yan's actual observations of legibility, reach, target selection,
  keyboard entry, transparency and comfort, with the exact tested source tree.

Earlier Vive observations remain evidence for their tested versions. New control
families, the tracking-placement correction and the in-panel Record feedback
still need final human confirmation. Do not mark the GUI ticket done before it.

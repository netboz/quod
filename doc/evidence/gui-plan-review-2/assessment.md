# Assessment of the available second review

This consultation has an incomplete retrieved report. The host exposed the opening
of the main review and the complete [visual addendum](fable-addendum.md). A request
to return the main report again was blocked by the provider with
`reasoning_extraction`; see [retrieval-error.md](retrieval-error.md). Do not treat
this evidence as a verified complete architectural review or implementation approval.

## Incorporated improvements

- VR is the primary design target. The graphical proposal describes a stable
  working panel, comfortable forward placement, a collapsible attention list,
  relaxed-arm indirect input and device-specific apparent target/text sizes.
- The panel background starts at 780-permille opacity. A transparency control
  compares 5–30% transparency; opaque mode remains available. Text, control marks,
  input wells and status remain opaque. World geometry behind the panel makes
  the requested visibility demonstrable in the mockup.
- Supporting text on translucent regions is at least body size and uses the
  main foreground color. Larger-text mode reflows the controls. This addresses
  the reviewer's legibility concern without claiming headset validation.
- Rail and panel remain adjacent rather than overlapping. The keyboard proposal
  uses an opaque surface that must not obscure the active field.
- Corrected stale source-whitelist wording against current shared source-access
  rules. Concurrent production changes were inspected but not edited.

## Recommendations qualified or not adopted

- No universal opacity floor, pixel-to-angle conversion or headset distance is
  approved by the review. The suggested values remain prototype comparisons.
- The review's proposed mandatory hover enlargement is not adopted: targets can
  have generous stable hit regions without moving or resizing the layout during
  aiming. Actual ray-target behavior needs adapter testing.
- A mandatory second press for every cancellation is not adopted. Confirmation
  should follow the domain consequence, not turn hiding or deferring a question
  into a destructive action.
- Body-anchoring the attention pill is a candidate placement, not a settled
  requirement. Its visibility, motion and accessibility require headset evidence.
- The review suggested labelling the adjustment as opacity. The mockup retains
  the user's requested term, transparency, while the technical token specifies
  opacity; 22% transparency is 780-permille opacity.

The unresolved create-question plus live-presence contract remains explicit in
the plan. Shared ontology state supplies question identity and concurrent-answer
validation; it cannot establish a connected receiver. The existing direct-effect
schema in [quod_effect.erl](../../../src/quod_effect.erl) currently admits ontology
create/join operations, so it is not an implemented generic GUI-delivery solution.
No new effect, executor or queue was implemented by this design work.

Browser checks and their limits are recorded in
[prototype-validation.json](prototype-validation.json). These establish only
local prototype behavior, not runtime delivery, consensus behavior or VR comfort.

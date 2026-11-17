# Build the general Quod GUI framework for VR and desktop

**Type**: task
**Issue Key**: QUO-24
**Status**: in-progress
**Priority**: medium
**Tags**: gui, vr, prolog, ontology
**Sync Status**: synced
**ID**: task_1791384819463_f2idgr
**Updated**: 2026-10-25T23:03:55.219Z

---

The common GUI software and deferred-question lifecycle described in the [GUI plan](/home/yan/src/quod/doc/gui-plan.md) have been delivered; physical-headset acceptance remains open. The current [space and interaction plan](/home/yan/src/quod/nimbalyst-local/plans/space-conceptual-architecture-review.md) governs the next direct-operation/Eidolon integration; do not restart the completed component implementation.

References:
- [Interactive visual concept](/home/yan/src/quod/doc/gui-concept.mockup.html)
- [Claude Fable review](/home/yan/src/quod/doc/evidence/gui-plan-review-3/fable-review.md)
- [Independent assessment and disposition](/home/yan/src/quod/doc/evidence/gui-plan-review-3/assessment.md)

Agreed requirements:
- Reusable GUI component classes instantiated through existing ontology semantics, usable by arbitrary components and applications, including non-lobby examples.
- Common controls in the first milestone: text inputs, buttons, selections, sliders, rotary knobs and composed forms.
- Convenient Prolog authoring and submitted field bindings. Genuine deferred questions use ontology events and authorized react_on continuations with shared registration/correlation. Ordinary Save/Create/Enter forms invoke existing authorized actions through the user's personal agent; they do not require a question or a form-specific responder.
- For a genuine deferred question, resolve the intended human through authenticated context or authorized question state; opening fails in Prolog without the required connected human or authorized responsible agent. This rule does not require every ordinary Eidolon or form to open a question. Direct-operation submission follows the agreed attempt-now personal-agent acceptance and original-outcome recovery rules.
- Accepted questions may remain in the HUD until the human chooses to answer. No proof remains suspended during editing, and opening does not guarantee continued connection until an answer.
- Shared ontology state owns question identity, status, cancellation and accepted answers; drafts stay local. Preserve existing transaction, authority, recovery and exact-outcome guarantees.
- Reuse Eidolons, marks, existing client controllers, actions, reactions and agent-work owners. No parallel GUI domain engine or shadow queue.
- VR-first ergonomics, moderate adjustable panel translucency with opaque readable controls/text, accessible input alternatives and desktop operation.

Delivery checklist:
- [x] Specify the executable form/component API and trace human/agent binding and presentation through existing owners. Resolve the live-observation/material-write integration internally without reopening the settled failure behavior or hiding partial writes.
- [x] Implement shared GUI ontology classes, composition, field/event binding and automatic authorized reaction behavior.
- [x] Implement authenticated presentation, HUD discovery and shared question lifecycle, including concurrent openings, stale revisions, duplicate responses, cancellation, disconnects and uncertain operation outcomes.
- [x] Extend the existing representation/controller path and deliver the common control suite with the agreed visual treatment.
- [x] Demonstrate an elaborate form both in the lobby and on an independent application component.
- [x] Verify behavior through production seams, including absence/refusal, event authority, agent loss, atomic question transitions and unchanged repeated-operation cost.
- [ ] Validate VR legibility, reach, target selection, keyboard entry, transparency and comfort on intended hardware; desktop mockup checks do not establish headset ergonomics.

Read AGENTS.md and the relevant architecture/proof/multiwrite specifications before implementation. Review advice is consultative: use the independent assessment, including its rejected recommendations.

## Relationship to ontology editing and optional physics
The GUI plan governs this common component/question-lifecycle scope. The later ontology/space decisions refine representation integration: [QUD.32](nimbalyst://QUD.32) unifies ordinary ontology-instance Eidolons and ACL reflection, [QUD.34](nimbalyst://QUD.34) supplies the dedicated highlighted text editor, and [QUD.35](nimbalyst://QUD.35) supplies the 3D ontology-editing application. Reuse controls and existing lenses/encodings/marks across these consumers; do not build duplicate editors or presentation engines.

An ontology can have several views of one authoritative content/history. The new plan makes ontology a specialized space of predicates; the existing foundations in [QUD.33](nimbalyst://QUD.33) are adapted by the staged plan. Storage, location and ownership stay distinct, and ontology representation does not enable physics. General GUI work must function in nonphysical contexts. These application tickets need not wait for this entire broad GUI milestone if existing controls suffice. No backward-compatibility shims; replace superseded dispatch paths. Keep the absent-human/agent failure behavior for genuine deferred questions and all original lifecycle/hardware acceptance above. Stages 1 and 2 own the shared direct-operation and instance-Eidolon adaptations; this ticket retains the delivered GUI foundation and its outstanding hardware acceptance.

## Software acceptance — 2026-10-14

The software delivery checklist is complete. Final sequential validation: 177 client tests pass, production build passes, and 30 production-owner tests pass (true exit 0). Windowless browser checks pass: 67 spatial assertions plus existing detailed checks, 36 desktop checks, and hardware-fixture startup with zero XR entries. The exact tested source manifest is unchanged.

[Independent review and validation](doc/evidence/gui-implementation-20261012/remaining-controls-01/self-review.md) · [Executable examples](doc/gui-examples.md) · [Final Vive checklist](doc/gui-hardware-acceptance.md)

Actual HTC Vive acceptance remains outstanding, including new controls, tracking-stable placement and visible Record feedback. Earlier hardware observations remain evidence only for their exact tested versions. Status stays in progress until that human validation is completed. Changes are uncommitted; no deployment was needed for the software checks. All failed evidence is retained; the original uncertain test operation was not resubmitted.

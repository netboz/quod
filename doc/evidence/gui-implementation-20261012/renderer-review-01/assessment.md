# Independent renderer assessment

This is a partial implementation assessment for QUD.25. The three Fable
reports are consultative source reviews. The parent checked their findings
against production code and exercised the actual Babylon controls through
the browser MCP. No report establishes headset ergonomics or completion of
the question lifecycle.

## Disposition

- R1: accepted. Built-in proof/source workspaces now compile through the same
  ontology component schema. `catalogue_selection` explicitly names the
  existing source controller's catalogue capability; ordinary selections
  require authored options. Common submitted forms refuse controller-owned
  editor, bindings and catalogue controls, including in a nonphysical source.
- R2: accepted. The portable decoder checks kind-specific properties, ground
  identities, proper lists, duplicate identities/options and safe integer
  numeric ranges. The old flat descriptor parser is replaced.
- R3: accepted. Actions use a bounded scroll viewport. The actual renderer
  fixture checks 22 actions, reaching the final action and keeping the
  focused input's keyboard inside the texture.
- R4: accepted. Invalid or missing numeric drafts remain visible as entered
  text, are passed back to the existing controller and receive inline errors.
  Their position indicator is hidden. Quantization follows the ontology's
  Min-relative grid, and unchanged values emit no edit.
- R5: accepted. Real canvas PointerEvents now exercise Babylon picking,
  stepping, rotary dragging and release outside the panel. A temporary trace
  identified a fixture error: pointer moves incorrectly used button 0 rather
  than -1, causing extra Babylon button transitions. The failed results and
  trace are retained in `../foundation-validation/pointer-diagnostics-01.json`.
  The rotary subclasses Babylon's Slider and reuses its pointer capture,
  cancellation and dual-controller filtering. Tests are desktop evidence.
- R6: accepted. Captions/help wrap. Input, selection and disabled control
  surfaces remain opaque; only panel background opacity is adjustable.
- R7: accepted. Unknown current selection values select the first offered
  option in either direction.
- R8: accepted. Text controls display required and UTF-8 byte-limit feedback;
  numeric controls display range/grid feedback. Immediate required feedback
  is intentional and does not prevent an empty local draft.
- R9: accepted. Existing controllers memoize immutable views. The renderer
  skips serialization when the same descriptor object is supplied.

The suggested load-time assertions for Babylon private hooks are rejected.
The package already pins Babylon to exactly 9.18.1, and real pointer tests
exercise the subclass hooks and cancellation. Assertions that methods merely
exist would not verify their semantics. Future dependency upgrades must run
these behavior checks.

The parent's final console audit found an additional production bug that the
first browser assertions missed: replacing a focused editor disposed it
without clearing the texture's focus. A subsequent canvas pointer move threw
inside Babylon focus management. Rebuilding now blurs the input before
disconnecting its keyboard and disposing controls. The fixture captures window
errors and unhandled rejections across a delivered task boundary, asserts none
occurred, and checks focus retirement. The original error result and failing
assertion log are preserved as `spatial-error-audit-01`. The corrected browser
run is `spatial-final-result-02`, with repeated client/build verification.
The final follow-up also blurs disabled focused inputs and clears focus on
panel disposal. Its fixture checks that a physical keyboard event cannot
change a locked input. `spatial-final-result-03` passes these checks.

Fable's concern that the virtual keyboard must remain permanently visible is
rejected: the plan explicitly specifies a focus-driven keyboard, and Babylon's
`VirtualKeyboard.connect` already hides it while rebuilding connections. The
fixture now checks it is hidden when the old focused editor is retired. It
appears again when an editable input receives focus. No duplicate keyboard or
permanent visibility override is introduced.

## Evidence and limits

The component foundation's earlier five-module gate passed 114 tests; its
exact hashes and logs are in `../foundation-validation/reviewed-receipt-01.json`.
That gate predates descriptor migration and is not presented as testing the
final renderer. Renderer-specific runs and their exact source hashes are in
`../foundation-validation/renderer-receipt-03.json`. Receipt 01 is historical:
its original browser assertions did not check uncaught DOM event errors, and
it must not be treated as a clean browser-error gate.

Retained failures include backend descriptor test expectations left in the
old shape, the real row-layout scroll regression, and pointer fixture errors.
Each has a separately labelled correction and run. No failure was discarded
or converted into a passing assertion about a different behavior.

This slice implements class instances, schemas, field binding and the common
spatial control suite through existing owners. It does not implement
`gui_open`, authenticated presentation preparation, shared questions/HUD,
automatic response reactions, cancellation or uncertain-operation recovery
for those questions. The lobby and independent application examples currently
exercise signed schema/binding proofs; they are not live opening demos.
There is no completed general desktop DOM adapter, deployed founding update,
headset acceptance, full release gate or commit.

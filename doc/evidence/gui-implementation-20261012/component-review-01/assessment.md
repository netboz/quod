# Independent disposition of the component review

The parent checked Fable's source findings against the implementation and real
signed proof seams. The review is consultative; it does not approve deployment
or establish a test result. Earlier reports and failed logs remain unchanged.

## Component findings

| Finding | Disposition and evidence |
| --- | --- |
| C1: atom unit backtracking raises | Fixed with an exclusive atom/binary choice; malformed continuation tests exercise the former error path. |
| C2: nonbinary submitted text raises | Fixed with the pure `binary/1` type test before conversion. Integer and atom submissions fail normally. |
| C3: colon data invokes a foreign ontology | Shared descriptor/binding helpers use `no_follow`; local form/control IDs reject owner-qualified names. Signed tests assert no spurious foreign dependency. Structured option values remain data. |
| C4: class helper followers and grouping | Internal class helpers use `no_follow`; direct parent and ancestor comparisons normalize owner grouping. Both spellings pass signed reads. Public `isa/2` argument-following semantics are retained; this slice does not redefine all open qualified taxonomy queries. |
| C5: duplicated attributes; unknown attributes | Consolidated into `gui_attribute/4`. Rejected blanket refusal of application attributes: arbitrary domain components legitimately have non-GUI attributes. Explicit validation context records domain state relevant to binding. |
| C6: invalid frozen required value | Schema compilation strictly validates frozen values; required frozen empty text fails. Editable required text may begin empty. |
| C7: repeated scopes and heap exhaustion | Batched vocabulary calls and deterministic unique field/tree lookup. Actual signed 32-field form: 1 vocabulary scope call for schema, 2 for bind, 2 for defaults. No runtime resource limit was increased. |
| C8: schema-only authority | Added a separate ontology granting schema/default reads and refusing binding/private compilation through signed ingress. Broader owner grants intentionally remain broader. |
| C9: delete semantics | Checked erlog's actual inverse-insert implementation. Unique exact identities justify `once/1`; duplicate submissions still fail. No private list implementation added. |
| C10: callable semantics | Checked `quod_action_predicates`' atom/compound callable test. This is a shape check, not authority. A continuation comes only from the authored template; future execution must enter normal ACLs. |
| C11: duplicated owner parsing | Lobby vocabulary classification now uses the common owner/name helpers; both groupings tested. |
| C12: anchored vocabulary traversal | Source class discovery uses existing `isa`; final vocabulary projection checks the configured anchor. No schema accepts a mismatched anchor. |

The clean sequential five-module gate on frozen delta-03 passed **114 tests**,
zero failures, in 225.012 seconds, true child exit 0. The immutable receipt is
`../foundation-validation/reviewed-receipt-01.json`. It covers the component
foundation, not the later spatial renderer/descriptor edits. Repeated signed
reads are traced for history/projection rebuilds and file I/O; a real update
is still observed. Registration-count assertions await actual lifecycle
registration: no GUI registration exists in this foundation to measure.

## Opening advice

Rejected the initial control request + separately signed material request:
it added another custody handoff and did not solve partial-write disclosure.
Rejected bind-time failure as a substitute for failure inside Prolog alternatives.
Rejected substituting committed actor facts for actual installed capable actor
acceptance; that requirement was already settled.

Native ontology lifecycle preparation does inspect the real world before
sealing; `quod_ontology:prepare_create/3` and `prepare_join/3` demonstrate it.
Thus preparing a real hidden client presentation, later released by the existing
effect journal, is a possible same-original-operation seam. It is not permission
to label arbitrary live observations as prepared effects. A disconnected view
must make release terminally expired, never hold up the journal waiting for
reconnection. Committed HUD discovery remains the authoritative pending state.

The parent verified the routing gap reported in addenda 4 and 6: ordinary `::`
chooses/reuses a validator scope, not necessarily the nominated native host.
A host constraint would extend the existing ask, nested relay and scope reuse
contract; it is not an API already implemented. A reused scope cannot move.
The standalone discarded live-query proposal is rejected. The proposed second
actor effect is also not accepted: an already installed shared handler has no
independent per-question activation, and same-host actor/receiver actions would
occupy the same single-effect scope. A second handler registry is not authorized.
Actual remote actor feasibility must be part of preparing the one real external
presentation through existing owners before runtime implementation proceeds.

No opening, question transition, reaction registration, HUD discovery or headset
acceptance is claimed by this receipt.

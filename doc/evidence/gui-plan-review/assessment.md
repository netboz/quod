# Independent assessment of the Fable GUI review

The review is complete. Its **not ready for implementation** verdict is justified:
the proposal states the intended guarantees but does not yet specify the admission
and response lifecycle that establishes them. Calling admission/correlation merely
an internal implementation detail understated the architectural work remaining.

This assessment checks the consultative [Fable report](fable-review.md) against
the existing owners and source. The [reviewed plan](reviewed-plan.md) is preserved
unchanged. No production code was changed, built or tested for this review.

## Findings to carry into the design

1. **Specify the human receiver and the acceptance signal (B1).** Authentication
   establishes identity, not a live GUI receiver. The signed physics socket in
   [quod_client_simulation.erl](../../../src/quod_client_simulation.erl) is a reuse
   candidate, not an already available general GUI channel. Socket delivery,
   client receipt and presentation acceptance are different observations; define
   which one completes opening. Bind it to the exact human, connection incarnation,
   form and responsible agent. Preserve failure for established absence/refusal
   and distinguish infrastructure errors. A transport owner must not become the
   owner of domain policy or durable interaction state.

2. **Identify an authorized hosted handler (B2, D4).** The current personal lobby
   has no hosted actor, as the [authority test](../../../test/quod_reaction_authority_tests.erl)
   explicitly checks. The browser identity cannot simply be treated as a hosted
   application agent: [agent_instance.pl](../../../priv/ontologies/agent_instance.pl)
   constrains its active signing key and host binding. Shared GUI behavior must
   install an effective reaction in the responsible agent's ontology, with explicit
   authority. Instantiating a GUI class does not itself install runtime reactions.
   Application authors should still receive automatic shared behavior rather than
   write a reaction per widget or prompt.

3. **Define what identifies one interaction (B3, B4).** A form instance identifies
   a reusable component; it does not necessarily identify one opening or question.
   Opening the same form twice, cancelling and reopening it, or receiving a duplicate
   response must have specified behavior. The runtime's committed reaction snapshot
   has no existing GUI admission metadata. Assign each necessary piece of state to
   one owner and make response validation available through governed existing paths.
   Do not duplicate domain pending work in a private Erlang interaction inventory.

4. **Separate event occurrence from completion (D1, D3).** A committed event is
   neither proof of its claimed human author nor a guarantee that its reaction will
   finish. The [runtime](../../../src/quod_runtime.erl) has refusal, queue-loss and
   restart paths. Where completion must survive those paths, reuse durable domain
   pending state and existing agent work. The [FIPA transitions](../../../priv/ontologies/fipa_request.pl)
   show how acceptance and pending state, then consumption and related consequences,
   belong in their respective atomic transactions. This does not require a GUI outbox
   or historical event replay. Handlers must enforce domain authority and preconditions.

## Corrections to the proposed remedies

- **B1:** Physics is not the only live WebSocket: [quod_explorer_ws.erl](../../../src/quod_explorer_ws.erl)
  also streams committed/runtime notices. It is not an authenticated GUI receiver,
  so this correction does not close the admission gap. Registering a socket by human
  identity alone also leaves agent-initiated selection among multiple tabs unresolved.
  Sending a presentation from a live-observation query needs an explicit effect and
  proof contract; classification alone does not establish safe acceptance semantics.

- **B2:** Do not require a hosted application agent in every ontology containing a
  GUI. The existing subscribed reaction path wraps source events as
  `from(Namespace, Anchor, Event)` and dispatches in the receiving ontology. A
  separately hosted responsible agent is therefore a design option, subject to
  subscription and authorization. The requirement is an identified capable handler,
  not one new agent per GUI-bearing ontology.

- **B3/B4:** Do not drop interaction identity merely to simplify matching. Transient
  transport correlation is not inherently a shadow domain database; duplicate
  ownership is the problem. A matching clause and a live agent process also do not
  establish the requested acceptance contract. Current queue capacity cannot reserve
  capacity for an answer that may arrive much later. Define what the agent agrees
  to hold and how cancellation, disconnection and restart release or recover it.

- **D1:** Removing `Human` from an event does not solve provenance or prevent an
  agent from exercising its authority on a forged request. A signed submission can
  establish `current_principal` at its governed entry point; later event fields are
  claims unless tied to verified evidence or authorized committed state. Checking
  that some signed operation committed is insufficient: any such check must bind
  the exact operation, payload, form and intended handler. The sample generic
  dispatcher is not yet a complete authorization/idempotency design.

- **D2:** Hosting visibility is not a confidentiality guarantee. The
  [routing contract](../../lifecycle-and-routing.md) explicitly distinguishes private
  route publication from confidentiality across authorized hosts. Submitted values
  placed in committed events enter history and feed paths. Specify the applicable
  disclosure policy and avoid promises that visual privacy or a private hosting
  flag can enforce it.

- **D4:** Founding-time source composition is a concrete reuse path, but it is not
  the only way ontology code can change. Ordinary authorized source edits also
  exist. Define installation and upgrades for the target ontology; do not prescribe
  the system-ontology administrative wrapper as a universal application migration.

- **D5:** Direct-class Eidolon discovery needs explicit integration with the GUI
  classes. Verify anchored lookup and precedence for derived classes before assuming
  one forwarding clause is sufficient. Keep representation recipes (Eidolons),
  visual occurrences (marks) and component instances distinct.

- **D6:** Reading an already available draft snapshot within a deadline is not the
  same as suspending a proof until the human supplies input. The optional draft
  accessor can be deferred to simplify the first release; it is not inherently
  forbidden. If retained, its live-observation restrictions still apply.

- **D7:** Ground events do not replace schema validation. For example, an event
  `clicked` remains ground even when a required field omitted from its payload is
  missing. Required fields, types, ranges and permitted controls need validation.
  Also, ordinary optimistic concurrency checks protect the submission proof through
  commit, not the time between displaying a form and starting that proof. Compare
  an explicit expected schema/version or relevant baseline. The existing
  [source-edit path](../../../priv/ontologies/quod_prolog.pl) performs such an expected
  source comparison; it does not rely on ordinary OCC to detect a stale editor.

- **D8/D9:** Agree with replacing the fixed client form-role path with one generic
  descriptor path, preserving existing behavior. GUI appearance is a reasonable
  initial home for translucency; a future rendering extension requires a demonstrated
  need, rather than a blanket conclusion that mark surfaces can never be involved.

## Next design step

Resolve the public opening/submission contract with concrete lifecycle examples:
connected and absent human; available and unavailable handler; concurrent openings;
cancel/reopen; duplicate and late response; schema change during editing; disconnect;
and restart after accepted work. Map each transition to its existing owner and
transaction, identifying only demonstrated missing capabilities. Then specify the
shared behavior installation and convenient authoring API. These are design tasks;
the review does not authorize replacing them with the reviewer's tentative code.

The review preserves the intended scope: general class-based GUI components,
common controls including sliders and rotary knobs, forms emitting ontology events,
shared automatic reactions, reuse of Eidolons/marks, and restrained VR translucency.
This code review does not validate headset ergonomics or runtime behavior.

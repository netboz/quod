# Independent disposition of the fresh Fable review

The complete [Fable report](fable-review.md) was saved directly to disk. The
review completed without the earlier retrieval failure. It remains consultative;
the plan is not implementation-ready, but several proposed remedies conflict
with Yan's stated requirements or overstate existing guarantees.

## Incorporated

- **P1-2, scoped:** distinguish local presentation activity, directly opened
  domain forms and durable questions. A widget or form opening need not create
  a durable unanswered question. Domain submissions still emit ontology events
  handled by authorized agents, including for directly opened forms.
- **P1-3:** make the `me/1` ownership guard explicit. Runtime matching considers
  eligible hosted actors; the guard must select the intended responsible one.
  Document founding/source-edit installation and per-source anchored subscription
  declarations. This remains automatic shared behavior for the form author.
- **P1-4:** HUD discovery and grants are a concrete missing contract. Record a
  candidate human-owned set of exact references to authoritative questions, with
  atomic changes when reference and question form one transition. Do not copy
  question schemas, answers or status into another mutable inbox. The current
  [human template](../../../priv/ontologies/human_user_instance.pl) requires new
  narrow grants before an application agent can install a reference there.
- **P1-5:** retain the existing pending-state/agent-work path for workflows that
  promise recovery. The plan already requires completion and related consequences
  in one transaction. A reaction occurrence alone provides no completion guarantee.
- **P2-1/P2-4:** clarify revision coverage and request identity obligations.
  Ordinary OCC does not cover human editing time; finite `proof_draw/3` values
  alone provide no uniqueness guarantee.
- **P2-2/P3-1:** an identity-only wake event can read accepted answer state,
  but that state must itself be authorized. An application agent cannot assume
  access to the human's private ontology at reaction time.
- **Graphics:** add the missing Disconnected preview and increase separation
  between cancellation and deferral. Retain opaque foreground, adjustable
  translucency, larger text, stable spatial placement and headset verification.

## Rejected or qualified

1. **Direct domain goals (P1-2, section 5.5) contradict the requested API.** Yan
   explicitly chose ontology events handled with `react_on` instead of direct
   GUI goals, and required a capable responsible agent. Reinstating the outdated
   direct-action proposal is not an authorized simplification. An agent need not
   be hosted in every ontology containing GUI components: anchored subscribed
   reactions already permit another authorized receiving ontology.

2. **Offline offer and preflight-read race (P1-1) are not adopted.** A live check
   followed by an independent durable write does not fulfill the same operation's
   no-human failure guarantee. The existing [sealing check](../../../src/quod_dtx.erl)
   rejects material diffs with live dependencies. The plan must resolve creation
   versus presentation without silently accepting offline questions or returning
   ordinary failure after a hidden partial write. This remains an architecture
   decision, not an implemented fix.

3. **An `observed(...)` wrapper is not a ready-made GUI delivery protocol.** The
   [physics path](../../../priv/ontologies/quod_physics.pl) uses owner-specific
   metadata, authority, expiry and signed-request custody. A GUI extension would
   need its own demonstrated ownership and failure contract. It would not make
   network receipt and consensus atomic or provide a synchronous answer to the
   original caller merely by reusing a reaction clause.

4. **A local registry miss is not global human absence (P2-3).** The report's
   proposal to classify humans connected elsewhere as absent weakens the stated
   requirement. An explicit receiver scope or a routing limitation must remain
   distinguishable from authoritative absence. A key indexed only by HumanRef
   also leaves simultaneous tabs/devices unresolved.

5. **Committed rows do not eliminate forgery (P2-2).** The broad owner grants in
   [lobby_instance.pl](../../../priv/ontologies/lobby_instance.pl) permit arbitrary
   goals, including writes to a proposed question row. Replacing an event payload
   with a row lookup is useful but cannot justify “nothing else needs protecting.”
   Handlers retain domain authorization and any required origin evidence.

6. **Resource budgets are not encoding constraints (P3-2).** The agent pending
   count and total pending bytes in [quod_runtime.erl](../../../src/quod_runtime.erl)
   are capacity limits. Calling them encoding constraints does not settle their
   policy ownership. Follow AGENTS.md: distinguish actual format bounds from
   configurable budgets, and report the resource exceeded.

7. **Generic recipe discovery does not already traverse the full class closure
   (F9).** [common_predicates.pl](../../../priv/ontologies/common_predicates.pl)
   supplies direct instance classes plus a class-self case to `class_eidolon/4`.
   `most_specific_classes/3` exists, but its integration into generic GUI recipe
   discovery must still be specified and verified. Do not infer automatic reaction
   or graphical behavior inheritance from class membership alone.

8. **Agent work is not an unconditional retry guarantee.** The runtime advances
   a work pass after unsuccessful/unknown outcomes; a changed dependency or hosted
   incarnation permits a new pass. Domain pending state and guarded completion
   are reusable, but failure visibility, exact outcome resolution and continuation
   policy still need to be stated. No timer-based retry executor is warranted.

9. **Graphical recommendations are proposals.** The current panel dimensions
   support angular-size calculations, not a universal no-head-turn threshold or
   a proven 35–40 degree optimum. Hide/close already exists in the spatial adapter;
   generalized Move/Recenter remains to be designed. Appearance recipes are a
   reasonable home for opacity, but “never extend surface/5” is too absolute for
   future object-associated surfaces. Supporting text on translucent regions has
   already been changed to opaque cream; the report's muted-color concern describes
   a possible theme combination rather than the current default.

## Verification and remaining scope

Parent independently inspected the cited runtime, reaction, agent-work, signup,
human/lobby policy, FIPA, effect and rendering paths. Manifest hashes were checked
before incorporating changes; the frozen plan and mockup remain intact. The
reviewer had no command tool, so its own claims of hash verification or invoking
the notifier are not execution evidence. Parent checks are recorded separately.

The remaining design work is a concrete presentation/creation contract, receiver
scope, authorized HUD discovery, form/request schema and behavior installation.
The user's event semantics, class instances, VR priority and translucent panels
are settled requirements, not questions to reopen. No production code, builds,
runtime tests or headset tests are part of this review delivery.

# Fable review 3: Quod GUI architecture and graphical design

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-07. Consultative only.
Basis: `reviewed-plan.md`, `reviewed-mockup.html`, AGENTS.md, the four
architecture docs, `system-ontology-acls.md`, the listed ontologies, Erlang
sources, client sources, tests and the earlier `gui-plan-review-2` material.
Every file in `source-manifest.json` matched its recorded hash at review time.
No build, test, headset or browser run was performed; every statement below is
source and design inspection. Line numbers refer to the manifest tree.

## 1. Readiness verdict

**Not ready to implement. Ready for a one-page API decision.** The plan now
names every real gap honestly, and nothing in it contradicts the proof,
transaction or runtime contracts. What blocks implementation is that four
load-bearing choices are still open, and two of them are stated in a way the
code cannot satisfy as written:

1. Durable question creation is described as if it could fail on a live
   "human connected" check. The sealing contract forbids that in one proof
   (section 3, fact F4). The plan must say which operation fails live and which
   commits blind.
2. Every "presented interaction" is required to have a responsible agent, which
   would forbid a human opening a plain settings form on an object whose
   ontology hosts no agent. Direct forms and agent-initiated questions need
   separate contracts (finding P1-2).
3. "Shared react_on once in the owning agent ontology" is correct, but the
   ownership guard, the composition path and the single-ontology constraint
   that make it *one* clause are not specified (findings P1-3, P1-4).
4. Where the question row lives, and how a human's HUD discovers it under the
   existing per-ontology ACLs, is unresolved (finding P1-4).

With the recommendations in section 5 adopted, the first vertical slice could be
specified in one page and would reuse FIPA Request, the agent-work owner and
the simulation projection channel almost unchanged.

## 2. What is a fact, a proposal, or an open choice

- **Facts** (section 3) are verified against source and cited.
- **Design proposals** are the plan's own text and my suggested changes
  (sections 4 to 6); none is implemented.
- **Unresolved choices** are listed in section 7; they are Yan's decisions.

## 3. Source facts the design must rest on

F1. **Reaction audience is every hosted agent, not one.** For an ordinary
domain event the runtime tries each `react_on/2` clause once per hosted actor in
that ontology (`src/quod_runtime.erl:1857-1862`, `:1325-1331`). The node actor
joins the audience only inside the node's own ontology (`:1842-1853`). The
selected actor is exposed to the guard by `me/1`
(`src/predicates/quod_runtime_predicates.erl:48-57`); the only authored
precedent guards with it (`priv/ontologies/node_execution.pl:73-79`). A clause
without a `me/1` constraint enqueues its goal for every hosted agent.

F2. **The catalogue is per ontology and read from authored clauses.** The
runtime reads `react_on/2` and `subscribes/2` from the ontology's own stored
clauses (`src/quod_runtime.erl:2649-2656`). A rule kept in `quod:gui` is
invisible to an application ontology's runtime. A remote pattern must be the
literal `from(Ns, Anchor, Pattern)` with a 32-byte anchor (`:2724-2733`) plus a
ground `subscribes(Ns, Anchor)` fact (`:2688-2700`). Shared behaviour reaches an
ontology today only through founding source composition, as `fipa_request.pl`
is composed with `agent_instance.pl`, or through an ordinary source edit.

F3. **A reaction goal executes as the selected agent, through ordinary signed
ingress.** `run_reaction` queues the bound goal (`quod_runtime_predicates.erl:198-242`);
`quod_agent` signs it with the agent's key (`src/quod_agent.erl:231-236`). The
submitting human's authority never reaches the handler.

F4. **A live observation vetoes sealing a material diff.** Live-observation
bridges are recorded in proof contexts (`src/quod_predicates.erl:371-377`) and
the veto is reused even for caught errors (`quod_runtime_predicates.erl:106-111`);
`doc/proofs.md:30-31` states the rule. One proof cannot both check "receiver
connected" and commit a question.

F5. **Humans are not reaction executors.** Signup founds a personal ontology
with `instance_of(human_user, me)` and `agent_key(me, Key, active)` but no
`agent_host/4` (`priv/ontologies/quod_signup.pl:107-114`), so `agent_hosted/4`
(`agent_instance.pl:6-9`) never holds and no `quod_agent` is started for a
human. The personal ontology admits only its own human principal
(`human_user_instance.pl:6-7`); a personal lobby admits only its owner
(`lobby_instance.pl:4`). An application agent therefore cannot read
`instance_of(human_user, _)` in a human's ontology, and cannot read a question
stored in that human's lobby, without new policy clauses there.

F6. **Reactions are not durable work.** The runtime recovers current
obligations without replaying reactions (`src/quod_runtime.erl:11-14`,
`doc/runtime-and-agents.md:5-7`). Enqueue refusal (`:1981-1985`, limits at
`:38-40`) surfaces as `{failed, {reaction_submission, _}}` and is dropped. The
only durable continuation owner is the agent-work projection
(`:2534-2537`), used by `fipa_request.pl:70-83`.

F7. **No GUI push channel exists.** Browser routes are HTTP signed goals plus
one websocket bound to the literal goal `physics_client_view(View).`
(`src/quod_client.erl:106-112`, `src/quod_client_simulation.erl:39-54`). That
websocket is the reusable pattern: signed read, `quod_reg:subscribe({runtime, Ns})`,
refresh on `applied_live` (`:138-142`), local authority required (`:44-51`).
A client session proves key control only and expires (`src/quod_client_auth.erl:2-7`,
`:45`); nothing registers "human H has a live HUD".

F8. **Rendering has no opacity, and the panel is not a mark.** `surface/5` has
colour, metallic, roughness, emission and textures (`priv/ontologies/quod_rendering.pl:224-226`).
The spatial form is a Babylon `AdvancedDynamicTexture` on a 1.8 × 1.7 m plane
with an opaque `#192B32` background, placed once at 1.6 m along the camera ray
(`client/src/workspace-panel.js:17-20`, `:168-174`); the keyboard is always
present in the same stack (`:51-65`). The panel exists only in immersive mode
(`client/src/world-scene.js:358-366`). Marks use PBR without alpha
(`client/src/scene.js:187-204`).

F9. **Discovery is class-driven already.** `entity_eidolons/2` walks
`instance_of` and `isa` closure to `class_eidolon/4`
(`priv/ontologies/common_predicates.pl:14-19`); `most_specific_classes/3`
(`:72-78`) resolves inheritance; the lobby uses it for recipes and menus
(`priv/ontologies/quod_lobby.pl:77-86`, `:97-103`). `discoverable` in hosting
requests is routing visibility (`node_execution.pl:60-62`), not confidentiality.

F10. **The console holds an open proof; forms must not.** The proof console
locks while a signed cursor is open (`ui/src/Console.tsx:47`) and the cursor
retains a snapshot (`doc/system-ontology-acls.md`, cursor paragraph). This is
correct for backtracking a Prolog goal and wrong as a template for forms.

## 4. Prioritized findings

Each finding states the defect, the evidence, and the smallest fix.

### P1-1. Creation versus live presentation is still written as one operation

Plan lines 25-27, 367-372 and 488-491 require opening to fail without a
connected human, while lines 410-414 and 480-487 require the question to be
durable shared state. F4 makes a single operation impossible, and the plan
says so itself (line 480) without choosing.

**Fix.** Split by contract, and name the operations:

- `gui_offer(Question)`: ordinary durable transaction, no live precondition.
  It may commit while the human is offline. This is the only writer of the
  question row.
- `gui_present(QuestionRef)`: read-only governed live operation that fails
  plainly when the receiver owner reports absence, errors when the owner is
  unreachable, and otherwise attaches the question to the live HUD. It never
  writes.

An agent that must not ask absent humans runs `gui_present`-style availability
as its own read before offering; the race is documented as accepted (plan line
388 already accepts it). If Yan insists that *creation itself* be gated by
presence, the only existing seam is the owned-observation tier: a receiver
owner injects `{observed, gui_receiver_accepted(...)}` which content cannot
mint (`src/quod_runtime.erl:1286-1291`), and a `react_on(observed(...), gui_offer(...))`
clause with `me/1` commits the question, exactly as `quod_physics.pl:165` does.
That is a larger extension of the runtime owner and should be a separate slice.

### P1-2. Direct forms and agent questions are conflated

Plan lines 10-12 and 367-369 require a responsible agent for every presented
interaction. A human opening the settings of a lamp in an ontology with rules
but no hosted agent (F5, and the brief's own "do not assume every GUI ontology
must host an agent") would be refused. It also forces the detour
"signed submit → event → reaction → agent → second transaction" for a change
the human is already authorized to make, reintroducing the partial-success
window that `doc/outdated/client-world-direction.md` §6.1 was written to
avoid.

**Fix.** Define three interaction kinds, with different contracts:

| Kind | Initiator | Durable state | Submission | Agent needed |
| --- | --- | --- | --- | --- |
| Direct form | Human opens a form on an entity | None before submit | One signed goal as the human, authorized by the owning ontology's `can_invoke/4`; the domain action commits consequences and may `trigger_event/1` | No |
| Question | Agent needs an answer | Question row + pending row (P1-4) | Human answers with one signed goal; consumption and event in one transaction | Yes, responsible agent bound at creation |
| Passive control | Human adjusts view, hides, defers | None | None | No |

"Emit ontology events for submitted input" stays true: a direct form's domain
action emits the domain's own events; the generic `gui_submitted/3` envelope is
needed only for questions. The responsible-agent conjunction then applies where
it is meaningful.

### P1-3. The shared `react_on` is one clause only if it is guarded and local

Plan lines 278-285 and 299-304 are right that the clause must live in the
agent's ontology. Two consequences are missing. By F1, without `me(Agent)` and
an ownership fact the handler runs once per hosted agent in that ontology. By
F2, if the question row lives in another ontology the clause must be a
`from/3` pattern with a literal anchor, one per source ontology, plus a
`subscribes/2` fact each: no longer "one clause".

**Fix.** Specify the single composed clause and keep the question local to the
agent's ontology:

```prolog
%% composed into every ontology that hosts a responding agent, once
react_on(gui_answered(Id), gui_respond(Id)) :-
    me(Agent),
    gui_question(Id, Agent, _Human, _Form, _Revision, submitted).
```

`gui_respond/1` is shared framework behaviour that reads the committed row and
calls the author's one domain predicate (for example `gui_response/2`). The
plan should state that the composition path is founding-source composition
(as `fipa_request.pl`) or one source-edit transaction for existing ontologies,
and that "installed response handling" means exactly: this clause is present in
the stored catalogue, the agent is `agent_hosted/4` here, and a policy
predicate grants capacity.

### P1-4. Question location, HUD discovery and ACLs are unresolved together

Plan lines 416-424 put the row in "an authorized application ontology" and let
the HUD "project questions from several authorized ontologies". There is no
directory of ontologies holding questions for a human, personal ontologies
admit only their owner (F5), and application ontologies would each need a
clause admitting that human to read its questions. The HUD cannot discover what
to read.

**Fix.** Reuse the FIPA Request shape exactly, with roles reversed. One atomic
multi-ontology transaction creates the question row in the agent's ontology and
a pending row in the human's personal ontology
(`fipa_request.pl:13-24` is the template). The HUD then reads one ontology, the
human's own, which it is already authorized for and already connected to by its
signup host. The answer is one signed goal in the human's ontology that consumes
its pending row and, through `::`, consumes the question row and triggers
`gui_answered(Id)` in the agent's ontology, one atomic group
(`fipa_request.pl:40-54` reversed). Cancel is the same shape with the other
terminal state. This also gives the concurrency rule for free: two answers, or
answer versus cancel, conflict on the two rows; at most one transition commits.

Required policy additions, both Prolog: the human template admits
`gui_offer/…` from agents the human accepts (a `fipa_request_allowed/3`
equivalent in the user template), and the agent ontology admits the human
principal's `gui_receive_answer/…` for a question that names that human.

### P1-5. Handler durability must come from the agent-work owner

Plan lines 346-351 and 446-453 say a workflow promising completion needs a
durable obligation. F6 shows this is the rule, not the exception: a handler
refused at enqueue, or an answer committed while the agent's runtime is down,
is never re-dispatched.

**Fix.** Make the `react_on` clause a wake only, and drive `gui_respond/1`
from the existing work projection as `fipa_request.pl:70-83` does:

```prolog
agent_work_goal(Agent, Cursor, Id, gui_respond(Id), Budget) :-
    gui_work_budget(Agent, Budget),
    findall(K, (gui_question(K, Agent, _, _, _, submitted),
                agent_work_after(Cursor, K)), Ks),
    sort(Ks, [Id|_]).
```

`gui_respond/1` requires the row still to be `submitted` and commits
completion with the domain consequence, so a duplicate wake is harmless. This
removes any need for an outbox, a retry timer or a second executor.

### P2-1. Revision and OCC are correctly distinguished but the revision is undefined

Plan lines 459-461 and 800-801 are right: OCC protects reads inside the submit
proof, not the interval between display and submit. What the "revision" is
remains unstated. Ontology height is too coarse (any unrelated commit
invalidates every open form).

**Fix.** Give the question row its own integer revision, bumped by every
authorized change to its form reference, schema or initial values. The answer
goal carries the displayed revision; the rule compares equality and fails
closed. The simulation view's `structure`/`generation` tokens
(`src/quod_client_simulation.erl:64-69`) are the precedent.

### P2-2. The event envelope carries too much

Plan lines 235-249 propose `gui_submitted(RequestRef, Submission, Event)` with
the bound domain event inside, then require handlers not to trust its fields
and the ACL to prevent raw `trigger_event/1` forgery. `trigger_event/1` is a
staging predicate callable from any admitted proof
(`src/predicates/quod_transaction_predicates.erl:42-52`); a lobby owner is
admitted for any goal (`lobby_instance.pl:4`), so forgery is cheap wherever
such a policy exists.

**Fix.** Trigger `gui_answered(Id)` only. The handler reads fields, human,
submission reference and revision from the committed row. A forged event with
no matching `submitted` row fails the guard; nothing else needs protecting.

### P2-3. "Connected" needs a named owner and a node-local scope

Plan lines 388-392 ask for an observation point. F7 shows none exists and that
presence is only observable where the HUD socket terminates.

**Fix.** The HUD websocket process is the receiver owner. After a signed read
proves the human's `agent_instance_ref`, it registers
`{gui_receiver, HumanRef}` through `quod_reg`; `gui_present` asks
`quod_reg:where/1`, monitors the registration, and treats "no registration"
as absence and an owner that does not answer as an error. State explicitly
that presence is node-local in the first slice: a human connected to another
node is reported absent. Cross-node presence is a later routing question, not
a GUI one.

### P2-4. Question identity minting is unspecified

`fipa_request.pl:14-15` requires a caller-supplied ground 32-byte `Id`. A
question created inside an agent's reaction goal has no caller to supply one,
and reaction matching has no randomness.

**Fix.** Derive the id deterministically from committed facts in the offering
proof: the agent reference, the triggering operation reference and a per-agent
counter row, or `proof_draw/3` salted by those. Specify one and test
uniqueness across retries.

### P2-5. The cursor model must not leak into forms

F10. The plan's "shared controller" (lines 55-59, 590-591) generalizes the
console and editor, whose controller keeps a signed proof cursor open while
locked. Forms end the projection before editing (plan line 404).

**Fix.** State that the form controller owns a draft and a submit function
only; the `useProofCursor` hook stays with the Prolog tools.

### P3-1. Human classification is readable only by the human

Plan lines 261-266 are correct for the open-form path. By F5 the read succeeds
only while the principal is the human. Add one sentence: at reaction time the
human is read from the question row, never from the human's ontology.

### P3-2. Capacity constants versus policy

`?MAX_AGENT_PENDING` and byte limits (`src/quod_runtime.erl:38-40`) are
queue encoding constraints. The plan's "capacity to own the interaction"
(line 27) must be a Prolog predicate in the agent's ontology
(`gui_capacity(Agent, Open)` checked at offer time), and the runtime refusal
must surface as the resource actually exceeded, per AGENTS.md.

## 5. Suggested plan improvements (architecture)

1. Replace the opening paragraph's "each presented interaction has a
   responsible agent" with the three-kind table of P1-2.
2. Add a section "Questions are FIPA Requests to a human" with the two atomic
   transitions of P1-4, the composed clause of P1-3 and the work goal of
   P1-5. Delete the sentence "may project questions from several authorized
   ontologies" (line 423) and the broadcast caveat it needs.
3. Rewrite "Human connection and failure" around `gui_offer` (blind, durable)
   and `gui_present` (live, read-only, fails plainly), with the node-local
   presence owner of P2-3.
4. Reduce the envelope to `gui_answered(Id)` (P2-2) and define the row:

   ```prolog
   gui_question(Id, Agent, Human, form_ref(Ns, Anchor, Form), Revision, State).
   %% State: awaiting | submitted | completed | cancelled | failed(Reason)
   gui_answer(Id, Fields, Submission).   %% written once, with submitted
   ```

   The human's ontology holds `gui_pending(Id, Agent, form_ref(...), Revision)`
   until a terminal state removes it in the same atomic group.
5. Direct forms: keep §6.1 of the outdated direction as the contract, with the
   current `gui_view/2` descriptor generalized to a component tree. The
   submission is `goal(DesiredState)` or a declared action; no GUI envelope.
6. Component discovery: add purpose `gui` to `class_eidolon/4` and resolve
   with `most_specific_classes/3` (F9). No new discovery predicate.
7. Verification obligations to add: a clause without `me/1` runs once per
   hosted agent (negative test); an answer committed during runtime downtime
   is handled after restart through the work projection; an offer to an
   offline human commits and presents later; `gui_present` to an absent
   human fails without a row change; forged `gui_answered(Id)` with an
   `awaiting` row does nothing.

## 6. Graphical and VR design review

The mockup matches the plan's appearance rules: only `.glass` carries alpha
(`reviewed-mockup.html:40`), the status strip and request items are opaque
(`:64`, `:44`), supporting text inside the scene is the main cream colour
(`:26`), the default is 22 % transparency (`:9`, `:88`), and the dial is
decorative with a numeric alternative (`:59`). Larger-text mode reflows to one
column (`:79`).

Concrete improvements:

- **Panel angular size.** The current plane is 1.8 m wide at 1.6 m, about 59°
  of visual angle, with 1.7 m height about 56°. That is well beyond a
  no-head-turn field. Express the width token as a visual angle (suggest 35
  to 40°, so about 1.1 m at 1.6 m) and let height follow content. These are
  derived from F8, not headset measurements.
- **Target and text sizes at the current mapping.** 1440 px over 1.7 m is
  1.18 mm per texture pixel, so a 58 px button is about 68 mm (2.4°), a 48 px
  target about 57 mm (2.0°), and 24 px body text about 28 mm (1.0°). These are
  plausible starting tokens, but the keyboard's 48 px keys at 70 px width sit
  at the lower edge of the panel where aim is worst. Move the keyboard to its
  own plane (also fixing the always-present keyboard of F8).
- **Opacity ownership.** Do not extend `surface/5`. The panel is a GUI
  appearance recipe, not a mark. Define `gui_appearance/2` tokens in
  `quod:gui:eidolons` (opacity permille, surface colour, text colour, text
  scale permille) and allow a personal override fact in the human's ontology.
  The adapter applies alpha to the dynamic texture background only. The
  mockup's `--alpha` on the rail *and* panel is consistent with that.
- **Separate the attention pill.** Keep it a small body-anchored plane with
  its own texture so arrival updates never re-layout the working panel, and so
  it exists outside immersive mode too (the current panel is immersive-only).
- **Move, Recenter, Hide.** None exist yet (F8). Specify them as controller
  actions on the panel's own frame, with the world-stable pose stored
  client-side only.
- **Missing states in the mockup.** Add "Disconnected" to the status messages
  (`:125-131`) and to the rail item states (`:137`); the plan requires it at
  line 676.
- **Cancel placement.** "Cancel request" sits in the footer row with 12 px
  gaps (`:66`). Separate it by at least one target width from "Later" and keep
  a second-press confirmation only when the domain says cancellation is
  destructive, as the assessment decided.
- **Legibility measurement.** Keep the plan's bright, dark and moving scene
  tests; the prototype's `#C9D2DB` on 22 % translucent `#192B32` over a bright
  world is the first thing to measure.

## 7. Unresolved choices for Yan

1. Does "a GUI query with no connected human fails" apply to presentation
   only (recommended), or must creation be gated through the
   owned-observation tier (larger runtime extension)?
2. Are direct forms allowed to commit domain changes without an agent and
   without the GUI envelope (recommended, restores §6.1)?
3. Question row in the agent's ontology plus a pending row in the human's
   ontology (recommended), or questions kept entirely in the agent's ontology
   with per-application read grants and a yet-to-be-designed HUD directory?
4. Node-local presence for the first slice, with cross-node presence deferred?
5. Appearance tokens as a `quod:gui:eidolons` recipe with personal overrides,
   leaving `surface/5` untouched?

## 8. Unverified claims

- Headset legibility, comfort, mis-selection and arm fatigue: not measured.
- Whether `AdvancedDynamicTexture` background alpha composes correctly over
  world geometry in the current Babylon build: not run.
- Whether the agent-work projection wakes on a `gui_question` state change
  without an extra dependency declaration: the dependency-tracking comment at
  `agent_instance.pl:11-12` suggests yes; not traced through the runtime.
- Whether the HUD channel can be opened against a personal ontology hosted on
  a different node than the one the browser reached: the simulation channel
  requires local authority (F7); a GUI channel would inherit that limit.
- Contrast ratios of the mockup palette at 780 permille over bright scenes.

## 9. Next design step

Write the one-page API decision resolving section 7, then the executable
examples the plan's step 1 asks for, in this order:

1. A direct form on a lobby entity: `gui_view` generalized to a component
   tree with a textbox, slider and knob; submission is one signed domain
   goal; no agent.
2. A question from a hosted "lighting assistant" agent: `gui_offer` as the
   atomic pair, `gui_present` as the live read, the composed `react_on` with
   `me/1`, the `agent_work_goal` continuation, answer, cancel, restart.
3. The HUD channel as a copy of `quod_client_simulation` reading
   `gui_pending/4` from the human's ontology with `applied_live` refresh.

Each example should state its policy clauses (`can_invoke/4` additions in the
user template and the agent ontology) before any Erlang is touched.

# Universal Prolog editing eidolon

Status: implementation candidate; not committed or deployed.
The shared clause-editing path, text/cards eidolon and runtime changes are included
in the frozen integration validation recorded in `WORK-IN-PROGRESS.md`. Deployed
acceptance and stored-policy activation remain open.
Reaction ownership and resource restoration follow the correction specified in
[event-reaction-refinement-plan.md](event-reaction-refinement-plan.md); that plan
supersedes the physical-node restoration design, not the editor's other work.
Tracking: [Forgejo issue #9](http://forgejo.service.consul/quod/quod/issues/9).
Repository rules remain in `AGENTS.md`.

## 1. The intended model

The Prolog editor is an **eidolon**, selected through `class_eidolon` like any
other way of depicting an entity. It is not a special action added to each
object. Classes, instances, agents, materials, worlds, GUI components and
eidolon recipes must all be accessible through it. An ontology browser makes
definitions without a visible scene object accessible too.

An authorized author can edit actual code: add/remove `isa` declarations,
create/change/remove predicates, reorder clauses, and edit actions, reactions
and eidolon recipes. A shared definition is edited at its owner; deriving a
subclass does not copy parent code into its instances.

Existing `can_invoke/4` policy governs these goals. Drop the proposed
`can_declare_runtime` permission layer and editor-specific framework protection.
The actual signed editing goal carries its proposed changes; existing identity,
authorization, read-dependency and commit checks remain authoritative.
Being able to select an eidolon does not itself grant write permission.

The ordinary entry policy is checked before the editing goal runs and is
verified by the existing admission path. Editing that policy in the same goal
does not authorize a previously refused request. Retain this existing guarantee
without adding per-clause approval flags or another authorization database.

## 2. Verified gaps in the starting tree

| Area | Current implementation | Correction |
| --- | --- | --- |
| Reactions | `quod_runtime` activates only founding declarations; `quod_runtime_predicates:reaction_result/2` rejects staged writes. | Remove the founding lock and use the ordinary authenticated goal/transaction path. |
| State handlers | Five `state_handler/4` declarations maintain local resources and pending work. | Drive the existing typed resource owners from committed selectors and owner lifecycle notices; do not execute arbitrary reactions as the node. |
| Inheritance | Shared `isa/2` is transitive, reflexive and cycle-safe; lobby eidolon/workspace lookup uses exact class. | Fix selection in Prolog; do not build another class hierarchy. |
| Clause order | `quod_erlog_db_local_prove:functor_ops/4` flattens `asserta` and `assertz`; `quod_diff:apply_op/3` appends. | Preserve ordering through the common durable mutation path and replay. |
| Duplicates | Identical clauses are silently deduplicated on apply, not rejected. | Do not promise duplicate preservation or call this rejection. Surface edits that cannot be saved faithfully. |
| Introspection | `quod_diff:interpreted_clauses/2` returns stored compiled clauses; proof-level `clause/2` can include generated following clauses. | Reuse stored-clause access and decode bodies; omit generated routing from authored code. |
| Parser | `quod_client_goal_parser` reads one complete term in a frozen grammar, not an entire source file. | Reuse it with proper clause boundaries and per-clause variables; add readable formatting. |
| Client | Existing console has signed goals, drafts, cursors, Accept and Stop; `world.js` accepts only the proof-console view. | Generalize the GUI adapter and share the existing lifecycle. |

## 3. One reaction concept

A reaction says: **when this event matches, run this Prolog goal for this
agent**. Prolog unification binds the pattern variables used in that goal.
An agent owns its reactions; ordinary class relations establish eligibility.
The catalogue currently reads locally authored reactions; it does not enumerate
remote inherited reaction declarations:

```prolog
react_on(door_requested(Door), open_door(Door)) :-
    me(agent_instance_ref(_, _, Self)),
    instance_of(ConcreteClass, Self),
    isa(ConcreteClass, caretaker),
    responsible_for(Self, Door).
```

The runtime indexes event patterns first, then checks each matching originating
clause for locally hosted actors of that ontology. The body is a read-only
existence proof against current committed state. `me/1` binds the selected full
actor identity; it grants no signed proof authority to the guard. Multiple
inheritance paths that prove the same clause's eligibility run it once for that
actor. Distinct matching clauses retain their stored order. The selected goal
then enters that actor's existing queue and ordinary signed `can_invoke/4` path.
Remote guard calls that require authenticated proof authority fail explicitly;
discovery cannot impersonate the selected actor.

The hosted agent supplies its authenticated identity and current assignment.
An event's author is not the reaction's principal: if a user changes a door,
the door agent reacts under its own rights. Nodes are actors too; only the
node's own behavior scope receives its verified logical-node binding. Typed
resource restoration does not depend on arbitrary node reaction goals.
Reuse `quod_agent` and its existing signed-request queue. No new agent executor,
private reaction knowledge base, or durable event queue is needed.
Its goal uses the existing proof, ACL, multi-ontology transaction and outcome
machinery. Related ontology changes commit together. Read-only goals need no
ledger entry. Reuse BBS's matching-and-calling pattern, not its private reaction KB.

Remove the special public `submit_agent_goal`/`submit_node_goal` detour and
read-only reaction execution once ordinary reactions use the existing signing
and submission machinery directly. Reuse that machinery internally: removing
an executor parameter does not remove the need to select the current host,
prevent stale-host writes or resolve an uncertain submitted operation.

### Restore current state through existing resource owners

[event-reaction-refinement-plan.md, section 4](event-reaction-refinement-plan.md#4-restore-resources-through-existing-owners)
owns the replacement contract for all five duties: hosted agents, observations,
ontology hosting/contacts, custody capacity and pending agent work. Use the same
committed selectors and owners at startup, after owner restart and after relevant
policy changes. Retain observed dependencies, including failed and absent reads;
no physical-node fallback, manual list of helper predicates or second scheduler.

The affected ontology supplies validated recovery data bound to its authenticated
observation. The logical node's own Prolog handler constructs a permitted report,
with the original deadline and identical report/request expiry. Generic reaction
metadata lives in the universal runtime bridge; `recovery_observation/1` verifies
the selected data against private owner metadata, so a matching public event term
cannot impersonate a recovery notice. Signing and vault work keep their existing
owners. Direct-context policy applies to every alternative node grant through
the existing ontology call path; it introduces no agent delegation chain.
The detailed contract and removal order are maintained in the reaction plan.

Live events remain notifications. Durable assignments and domain obligations,
including pending FIPA conversations, survive crashes through existing ontology
and transaction recovery. Resource restoration does not replay historical events
or introduce a persistent copy of each occurrence.

### Timing must remain explicit

A transaction cannot undo a socket write or another external action already
performed. Being harmless to repeat does not make an action harmless when the
transaction fails. A hosting command derived from a new host fact must follow
that fact's commit. Local operations against already committed state may remain
direct. Reuse current reconciliation and effect owners where applicable; the
existing `quod_effect` covers ontology create/join, not arbitrary external calls.
Do not invent a generic effects subsystem for the editor.

The proposed activation contract follows the handoff: transaction T is matched
against the declarations installed before T; changes made by T govern later
transactions, including T+1 in the same block. Adding a reaction and emitting an
event in T does not make the new reaction consume that event. Removing a reaction
does not erase work already matched; subsequent transactions cannot select it.
An already submitted goal keeps the existing transaction/cancellation rules.

The working-tree implementation retains these transaction/catalogue boundaries.
The later block-final activation proposal in the work notes is a separate decision;
this ownership correction preserves current ordering. Keep the derived index on
the existing apply path; do not add a history scan, another reducer or a copied
ontology. Declaration order follows stored clause order, not term sorting.

Matching an event is not a historical-state proof. A queued goal executes against
the normal committed snapshot available when its ordinary proof starts; its reads
and writes use the usual conflict checks. The event carries the matched values,
not a promise that the entire ontology still has its event-time state. Define
inherited reaction order explicitly when finalizing class declaration syntax;
do not imply a global order between different agents or independent ontologies.

Inheritance must not execute the same originating reaction twice through two
parent paths. Selecting one eidolon and running all matching reactions are
different operations; a blanket “nearest class wins” rule cannot define both.

## 4. Faithful code editing

Text and visual cards share one ordered clause draft. Variables are scoped per
clause, anonymous variables stay distinct, and cuts, alternatives, lists and
operators retain their meaning. Display canonical source when original comments
or spelling were not retained; do not claim to recover lost source text.

Capture the opened predicate versions, compare that baseline on submission,
then stage changes through the ordinary proof overlay. Existing read checks
cover races after submission. Conflicts preserve the draft. Accept and unknown
outcomes use the console lifecycle and operation journal, without resubmission.

Fix durable ordering first, including replay and proof rollback. Use the
smallest exact editing operation that preserves the selected clause sequence;
ordinary `retract` can remove an earlier, more general unifying clause. Do not
create an editor-only persistence path or a second reducer. An unchanged edit
must produce no mutation. Optimize clause-list rewrites only after correctness.

For example, after storing `choose(general).`, inserting `choose(specific).`
with `asserta` must give `specific` first both before and after commit/restart.
Editing one declaration must preserve unrelated clauses in the same predicate.
The editor submits data to the shared mutation path, not direct store writes.

Initially retain existing unique-clause semantics and report a draft that would
silently collapse on save. Supporting duplicate occurrences would be a separate
explicit change to the stored program model, not a feature to pretend exists.

Show authored code separately from generated following clauses. Shared-base
origin is information, not another permission check. The common Prolog file is
loaded into each ontology's base: editing a clause in one ontology does not
update it globally. Always show the exact ontology being changed.

Arbitrary helper predicates cannot be assigned to a class by guessing from
argument names. The class view links known relationships and any explicit
domain grouping; the ontology view keeps all remaining authorized code accessible.

## 5. Inheritance and editor ownership

An instance of `smart_console`, with `isa(smart_console, prolog_console)`, should
inherit the console eidolon and controls unless Prolog provides another choice.
Reuse the material ontologies' existing more-specific recipe selection as the
starting point, generalizing it into shared Prolog rather than client dispatch.

Expose the applicable eidolons through the class hierarchy. Where a default is
needed, Prolog can prefer a strictly more-specific applicable recipe, reusing the
material selector's idea. Incomparable alternatives remain choices or require an
explicit Prolog preference; incidental ordering must not decide. Cycles do not
imply strict specificity. Remove the lobby's exact-one-class assumption. Ordinary
predicate/action search retains its existing Prolog semantics.

Attach the editing eidolon through this shared selection, without per-object
boilerplate. Use `prolog` as the proposed purpose, distinct from `edition`, which
currently depicts a device's construction. `class_eidolon` supplies the editor's
recipe as ordinary ontology data. A target with no visible mesh remains selectable
through the ontology's eidolon. All supported code targets need a generic recipe.

- `quod:prolog`: code views, editing actions and validation vocabulary.
- `quod:prolog:eidolons`: editor recipes, including generic clause cards.
- Existing `quod:gui`: reusable semantic controls and workspaces.
- Owning ontology: the program, class relationships and `can_invoke/4` policy.
- Client: draft manipulation, input and GUI rendering.

Text first, then structural cards on desktop and planar VR boards. Reuse the
existing GUI vocabulary; no parallel Blockly integration in this plan. The
ontology descriptions remain independent of Babylon.

Remove both client assumptions: the fixed `playing`/`edition` mode list and the
`proof_console`-only workspace/form decoder. The client renders supported semantic
GUI components and reports an unavailable capability explicitly. It does not
evaluate Prolog, decide inheritance or add a bespoke editor for each class.

### Editing interface and outcome recovery

`quod:prolog` supplies three ordinary read queries:

- `prolog_predicates(ontology_ref(Name, Anchor), Indicators)` lists the local
  interpreted predicates.
- `prolog_source(ontology_ref(Name, Anchor), Indicator, Source)` reads canonical
  authored clauses in their stored order, excluding generated following clauses.
- `prolog_edit_goal(ontology_ref(Name, Anchor), Indicator, Expected, Draft, Goal)`
  returns the explicit ordinary transactional goal. Preparing it writes nothing.

A direct administrative grant does not authorize inspection through a foreign
editor/helper. The target must separately permit that authenticated reader's
named source-inspection operation in its calling context, with the exact target
guard. This read grant supplies no mutation authority or blanket helper trust.
The compiler returns data; the separately submitted editing goal uses the
caller's ordinary direct authorization.

The generated goal binds `current_ontology_identity/2` inside the existing
`Name::(...)` scope, compares the current source with the opened baseline, and
uses ordinary clause staging. The common exact-retraction primitive selects
one alpha-equivalent authored clause; it does not unify away an earlier general
rule. The unchanged prefix is retained. Replacement clauses use `assertz/1`,
and the saved program is checked against the proposed program before success.
The normal read set covers conflicts after proof starts. A no-op edit stages no
write. Existing unique-clause semantics are reported rather than silently
collapsing duplicate rules.

The common `'$quod_predicate_source'/2` query formats the actual local ordered
program through the shared source formatter. A bound source argument checks
that exact canonical text. The compiler uses these bound checks before and
after its explicit mutations, so no temporary copies of the program escape as
answer bindings. The generated ordinary transaction must also compose correctly
inside another transaction or action; inspection introduces no collector or
additional savepoint. Read dependencies and exact mutation checks remain those
of the shared engine, with no result-budget increase or editing executor.

Program text is parsed by the same current server grammar as signed goals,
with independent variables per clause. Grammar version 3 distinguishes a
numeric `-3` from the unary expression `- 3` and preserves negative zero.
The existing signed parser-version field selects that contract; historical
version-1/2 request bytes retain their original meaning. This is a shared
language correction, with no editor-only numeric conversion or execution path. Parsing a draft does not allocate
callable atoms. The generated signed goal exposes its assertions to existing
symbol admission and resource policy. Reading an absent cold predicate returns
an empty baseline without allocating it.

The editor and console share one proof cursor lifecycle, including explicit
Accept and Stop. Desktop and spatial renderers use that same owner and draft.
An ontology selects semantic GUI components; the Babylon adapter has no Prolog
interpreter, inheritance policy or additional transaction path. Clause cards
split each clause into its head and body, and rearrange the same ordered source
draft. Switching explicitly to cards asks the existing parser for terms;
typing, moving and deleting cards are local operations. Switching to text keeps
the resulting source. The first structural change regenerates canonical text,
so comments entered in a draft are not falsely claimed to survive that change.
Both desktop and planar VR controls use this model.

Before Accept sends a request, the existing browser operation journal retains
its exact signed request and a workspace context: acting agent, target scope,
predicate, opened source and draft. Reopening the same workspace discovers that
row and disables a new proof until its outcome is resolved. Outcome lookup uses
the saved operation only. It never signs the edit again, invents a commit height,
or treats a missing answer as failure. Other accounts and exact targets keep
separate contexts. A positive committed answer advances the editing baseline;
a refused or unknown result preserves the draft.

## 6. Updating Erlang predicates

The installed coordinated release supplies each declared Erlang module's
implementation. Remove the comparison with its founding BEAM digest. Keep the
single committed `external_predicate_modules([{Module, FoundingDigest}, ...])`
shape unchanged: module names select code; digests remain historical provenance.
This preserves existing genesis bytes, anchors and ledgers, without a second
decoder or a re-found. It does not claim a names-only stored format.

The loader still requires a module shipped in Quod's own release directory,
the expected exports and marker, and a successful `load/1`. Conflicting
predicate ownership fails. Each ontology receives only its declared modules;
the common bridge set remains explicit. The module registration list remains
immutable until a real live registry activation mechanism exists.

Activation is a cold coordinated release, not an Erlang hot-code update:

1. Stop new requests and let admitted work finish where practical. Stop all old
   validators, proof engines, hosted agents and projection consumers before any
   new release participates. There is no rolling mixed-release interval.
2. Install the same supported artifact on every participating node, retaining
   ledgers and keys. Startup builds fresh engine registries from installed code
   through the canonical committed projection; no proof spans both releases.
3. Verify replay, pending-operation recovery and existing ontology identities.
   Keep ordinary traffic closed while committing the targeted stored-policy
   updates in `event-reaction-refinement-plan.md` §8. Check exact anchored targets
   and ordered before/after definitions through normal authorized transactions;
   preserve unrelated reaction, ACL and work-selector clauses. Source templates
   do not rewrite stored programs. Reopen traffic after migration and applicable
   acceptance checks. A stopped or lagging node must install this release
   before rejoining. Interrupted requests retain their existing operation
   identities and outcome resolution; uncertain writes are not resubmitted.

The current protocol does not negotiate native release versions or fence an old
validator automatically. Deployment must keep old instances stopped and verify
the artifact of every participant. One ontology's block number cannot establish
a network-wide activation boundary.

Validators verify signed plans, authorization, read dependencies and selected
protocol proofs; they do not rerun every arbitrary goal. Native consistency
matters to those checks and to future proofs nonetheless.

A future root code-update action uses ordinary Prolog authority, without a new
permission layer. Its compilation, distribution and activation protocol is a
separate design; none is implemented by removing the lifetime digest check.

## 7. Short implementation sequence

1. **Repair the common foundation.** First reproduce and fix durable clause
   ordering and exact edits through the existing console. Then demonstrate one
   live ordinary reaction, followed by migration of the five handler duties
   through existing owners. Verify the transaction activation rule above and
   finalize class/instance reaction syntax with one inherited example. Remove
   superseded declaration/submission paths; do not ship permanent old/new modes.
2. **Implement inheritance and the editing eidolon.** Share Prolog eidolon
   selection, fix the lobby, introduce the two editing ontologies and generalize
   the existing GUI/console lifecycle. Text first, then cards on the same draft.
3. **Verify and deploy the workflow.** Shared-class edits, explicit subclass
   specialization, live reaction add/change/remove, same-block ordering,
   ordinary ACL refusal, concurrent edits, interrupted Accept, host transfer
   and restart. Verify current-state recovery and no unchanged disk writes.
   Record exact release and test evidence in issue #9.

## 8. Acceptance through the existing paths

| Scenario | Required result |
| --- | --- |
| Select a console's `prolog` eidolon | The generic editor appears through ordinary eidolon selection; no console-specific edit command. |
| Make a subclass, then select its eidolons | Parent recipes remain available; an explicit preference can choose a subclass recipe. |
| Edit a shared class used by two devices | Both use the changed definition on subsequent reads; no copied instance code. |
| Insert a rule first, commit, restart | The first answer and stored clause order remain the same. |
| Add/remove a reaction in T, emit again in T+1 | T uses its prior declarations; T+1 uses the edit, even in the same block. |
| Match a reaction for another agent | Its ordinary ACL sees the owning agent, not the event author. |
| Stop an edit or lose Accept's reply | Stop leaves no write; an unknown submitted write is resolved through its existing operation identity. |
| Another author changes the opened code | Submission reports a conflict and retains the local draft. |
| Restart or transfer a host | Existing assignments/pending facts restore resources through current owners; old effects are not replayed. |
| Fail a transaction requesting new hosting | No process is started from its rejected staged host fact. |
| Repeat an unchanged read or readiness observation | No history rebuild, broad wakeup or unnecessary disk write. |

Use focused checks while developing each part, then the required sequential
release gates once for the frozen integration. Verify real owners and reducers;
do not duplicate their implementation in test-only substitutes.

Update the superseded sections of `agent-fipa-plan.md`,
`event-reaction-refinement-plan.md` and the runtime documentation with the
implementation. Follow `ontology-actor-architecture.md`, `inter-ontology.md`,
`client-world-direction.md` and `multiwrite-architecture.md` where unaffected;
identify genuine conflicts explicitly. The working tree now implements parts
of this plan. Deployment requires the final integrated tree, source migration
of existing declarations, and the applicable release gates.

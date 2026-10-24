# Claude architecture review — checked notes

17 October 2026. Claude Fable (`claude-code:fable`), session `6f1eb8ff-0f57-4309-9bdf-a95af8d4fb20`, reviewed the [architecture discussion draft](/home/yan/src/quod/nimbalyst-local/plans/space-conceptual-architecture-review.md). Its full response appears below.

**Subsequent clarification:** Yan now specifies ontology as a specialized space, one containing space per placed instance, and class declarations for all new offered operations. Mandatory placement and nested-space display rules remain open. The assessment below records the earlier review; the linked discussion draft contains the current decision status.

**Scope:** automatic approval review rejected broader repository source access for the Claude session, citing source-code sharing beyond the requested document review. A narrower document-only review was approved. Claude's advice is therefore conceptual; the code checks below were performed separately by the parent agent. No production code, tests, configuration or deployed data were changed. That review initially left the discussion draft and diagram unchanged; the later clarification is recorded separately above.

**Recommendation:** use the review to clarify authority, embodiment and the first implementation slice. Several proposed shortcuts conflict with the current code or with decisions still reserved for Yan.

## Useful ideas to carry into the next discussion

1. **Specify the actor contract before implementing entry.** Space can remain the first domain. Settle what U authenticates, what A accepts, what A signs, and what the target authorizes before implementing its first operation. Distinct U/A identities do not themselves prescribe a durable conversation for every interaction. Equally, a synchronous shortcut must demonstrate how A genuinely becomes the acting identity. The original draft already conditions the two-transition example on an *asynchronous* instruction; Claude overstates it as universal.

2. **Identify what moves.** Distinguish A's logical containing space, its physical embodiment, the client's selected view and A's runtime host. Entering should not silently substitute a new identity. Decide whether the existing pilot becomes an embodiment of A or is replaced; do not equate either option with merely changing the camera. A real human being outside the world does not settle whether the represented `human_user` account instance has a containing space.

3. **Make `enter` the first shared offered operation.** Define the minimal target/operation/parameter contract alongside the initial empty-space example, before building full recursive views. Reuse the existing action and transaction paths. The concrete metadata gap is a common class/subject operation contract: [interface descriptions](/home/yan/src/quod/priv/ontologies/quod_prolog.pl:18), [class menus](/home/yan/src/quod/priv/ontologies/quod_lobby.pl:140) and [form bindings](/home/yan/src/quod/priv/ontologies/gui_instance.pl:143) currently supply separate pieces. Discovery remains advisory; execution rechecks authority and revisions.

4. **State exposure composition plainly.** Parent display policy can restrict what the child exposes, and the actual viewer must still be authorized. Parent visibility cannot enlarge the child's disclosure grant. Whether outer bounds clip a representation or constrain an interior is a separate spatial-policy choice; it does not automatically require independent simulators.

5. **Turn responder retirement into explicit conditions.** The replacement must preserve authorized creation, stable operation/instance identity, validation, exact outcomes and feedback. Only then can world-specific question policies, continuation coupling and setup dependencies retire. The shared deferred-question capability remains useful. Existing pending work and keys are not authorized for deletion by this review. Creation currently derives its identity from the question occurrence and verifies that occurrence's active application, so replacing the helper is more than deleting an agent declaration: [creation guard](/home/yan/src/quod/priv/ontologies/lobby_worlds.pl:76), [continuation](/home/yan/src/quod/priv/ontologies/gui_instance.pl:206).

## Corrections and limits from the local code check

| Claude's recommendation or claim | Checked conclusion |
| --- | --- |
| U can sign once, call through A's ontology, and thereby achieve the proposed direct-agent path. | **Not sufficient.** The engine retains the original principal; the policy call chain contains ontology namespaces, not agent instances. This would still be U acting unless another verified contract establishes A's acceptance and signing. [Authorization boundary](/home/yan/src/quod/src/predicates/quod_ask.erl:1518), [policy arguments](/home/yan/src/quod/src/predicates/quod_ask.erl:1809). Existing signing is a governed read-only operation with hosted-key policy, not an identity switch inside a write proof. [Signer](/home/yan/src/quod/src/predicates/quod_agent_predicates.erl:182), [hosted policy](/home/yan/src/quod/priv/ontologies/agent_instance.pl:267). |
| Location has no designated owner; make destination admission authoritative and assignment a mirror. | **The owner is already designated.** The instance's ontology owns its exclusive assignment and revision, preventing concurrent admission into two destinations. The destination owns its admission and physical consequences. These are coordinated obligations, not two interchangeable copies. Preserve this ownership unless a demonstrated defect warrants changing it. [Assignment owner](/home/yan/src/quod/priv/ontologies/space.pl:56), [admission check](/home/yan/src/quod/priv/ontologies/space.pl:82), [concurrency contract](/home/yan/src/quod/doc/spaces.md:71). |
| `terrain(W)` is just a mark and cannot be the basis of a terrain domain instance. | **Factually incorrect.** It already has derived `instance_of(voxel_ground, terrain(W))` membership and an anchored space reference. Render marks separately depict that subject. Its generator state currently belongs to W; separating that state does not require discarding the existing subject identity. [Terrain subject](/home/yan/src/quod/priv/ontologies/voxel_world_view.pl:3), [depiction](/home/yan/src/quod/priv/ontologies/voxel_world_view.pl:23), [definition owner](/home/yan/src/quod/priv/ontologies/voxel_world.pl:17). |
| “Enter world” creates a pilot and switches the view rather than transferring the personal agent. | **The core claim is confirmed, with a first-use qualification.** Entry prepares/initializes the selected world's physics if needed, using its authored world-specific pilot; subsequent entry can return `ready`. The client then selects that world's view. It is not a same-agent transfer. [Entry](/home/yan/src/quod/client/src/space-library.js:129), [preparation](/home/yan/src/quod/client/src/space-entry.js:23), [placement/control](/home/yan/src/quod/priv/ontologies/quod_physics.pl:35), [pilot](/home/yan/src/quod/priv/ontologies/lobby_worlds.pl:156), [navigation](/home/yan/src/quod/ui/src/World.tsx:58). |
| Replace universal containment with optional placement for nonlocated classes. | **An alternative requiring Yan's decision, not a correction.** It changes the requested direction. Root spaces are a normal foundation for a containment tree; transient proof terms not being instances is a scope definition. The genuine unresolved contracts include represented accounts/classes, eviction and removal of a space containing live instances. |
| A parent should depend only on a child's signed projection revision. | **Investigate before adopting.** Existing views enumerate direct subjects, and nested model transforms already exist. Fine-grained projection dependency behavior still needs a concrete measurement through existing owners. Never drop source authorization/revocation dependencies or invent another snapshot/signing owner to reduce invalidations. [Current view](/home/yan/src/quod/priv/ontologies/space_view.pl:3), [model composition](/home/yan/src/quod/priv/ontologies/quod_modelling.pl:151), [retained runtime state](/home/yan/src/quod/doc/runtime-and-agents.md:36). |
| Instances must never add operations; additions require changing the class. | **Unagreed restriction.** Existing class selection supports multiple applicable classes. Operation identity, conflict resolution and permitted refinements need an explicit contract; the review gives no evidence for imposing this blanket rule. [Class selection](/home/yan/src/quod/priv/ontologies/common_predicates.pl:61). |

The existing FIPA Request does provide two atomic transitions for genuine deferred actor work: accepted pending state, then effect plus completion. It is a reusable candidate for that case, not proof that every GUI interaction must use it. [Request lifecycle](/home/yan/src/quod/priv/ontologies/fipa_request.pl:13).

## Suggested staging adjustment for discussion

Define authority, the located identity and containment scope on paper first. Then make a minimal empty-space `enter` operation exercise shared operation metadata and the chosen U/A path. Build recursive exposure after that contract works. Normalize terrain and retire the form-specific responder only after the replacement satisfies its still-valid obligations. This changes the sequencing proposal; it does not authorize implementation or settle the remaining choices.

The reviewed draft's SHA-256 was `f7e9481086233802649e801870d09d6a7aba333f8e2da5d7299eee7773c975fb`; source checks used the current working tree at base `6404ec95b4703203b5bd08a82b0b4d4b5f98961f`. No tests or live-state validation were run.

---

## Claude's full returned response

I'll read AGENTS.md as the standing agreement, then deliver the review from the document alone.

Review of the space and interaction model draft. Scope: the document only, plus AGENTS.md. Everything marked "verify" is a code claim I could not check here.

## 1. Ranked inconsistencies, missing contracts, questionable assumptions

**1. The U→A acceptance path turns every direct user action into a deferred request (diagram, "Identity and authority", example 1).** The diagram routes "request authenticated as U" through "Personal agent acceptance ACL" to A, then A signs a goal. Read literally, that is two commits per form submit: U's accepted instruction plus A's pending work, then A's effect. That is structurally the same responder-backed question workflow the document wants to retire for `world_responder`. It would also require A's hosted process, with vault signing, to be awake for a human clicking Save. The document already describes a cheaper mechanism: within one proof the original principal is preserved and each target checks `can_invoke` against the ontology call chain. Acceptance can therefore be a synchronous rule evaluated in A's ontology as the first hop, with the target verifying "principal U, chain via A". One transaction, no new actor wake. Asynchronous acceptance should be reserved for autonomous or long-running work (reactions, example 3). The document should state which of the two models applies to direct operations instead of drawing the async one as the universal path. Verify: whether the call chain identifies A as an instance, or only A's namespace; if an ontology hosts several agents, a chain of namespace names cannot name A.

**2. Staging has a prerequisite reversed ("Smallest staged normalization").** Stage 1 implements `enter` with "the agent owner's travel policy", and the first example moves "one agent". Stage 3 later decides who the signing actor is. Whatever actor stage 1 uses will be replaced in stage 3, leaving a direct-U path beside a via-A path, which the agreement forbids. The fix is not to demote space: it is to settle item 1 on paper before stage 1 code, and to make `enter` the first operation expressed in the stage 3 metadata. Space stays the foundational concept; the acceptance decision is a one-paragraph prerequisite, not a slice.

**3. Which identity is located? (Space section, "Confirmed mismatches".)** The document says agents enter spaces and that U and A are distinct, but never says whether U has a spatial location. The clean answer is that U has none: U is a human outside the world, A is the located instance, and U's client views the space containing A. This also explains the pilot: if "Enter world" today creates a world-specific pilot and switches the view (verify), the pilot is playing A's role without being A. The proposal must say what becomes of the pilot: A's embodiment in that space, or retired in favour of A. Leaving this unstated is the biggest gap between the current client and the model.

**4. Location truth has two facts and no named owner (Space section).** "Source owner and destination admission commit atomically" means the instance's ontology holds an assignment and the space's ontology holds an admission. Atomic commit prevents divergence on the write path, but recovery and projection need one authoritative side. Recommend: the containing space's admission is authoritative for "what is here" (projection reads one ontology), the instance's assignment is the mirrored pointer. State it either way.

**5. Universal containment is contradicted by its own exception list (Space section, "Open decisions").** Roots have no parent, class definitions and ontology self-instances need "an explicit placement convention", proof terms and marks are excluded, and the JSON design's unplaced document "conflicts" with compulsory containment. That is four exceptions to a universal rule. The simpler invariant: containment is mandatory for located classes (anything with a frame or body) and optional elsewhere. A document is located only when someone places it. This honours "instances exist in spaces" for everything a user can see or enter without forcing ontologies to be placed somewhere at bootstrap.

**6. Exposure composes three policies without precedence (Space section, paragraph on child exposure).** Child disclosure, viewer permission and parent display policy are listed as all applying. Say explicitly: intersection, child decides first, parent can only subtract. Also decide now that outer finite extent clips presentation only; constraining a child's interior requires the child's simulator to know the parent, which is the cross-simulation transfer the document correctly excludes.

**7. Recursive projection through ontology-scoped dependencies will fan out (Space section).** A parent view depending on every child ontology means any unrelated child commit invalidates the parent. Stage 2's "signed retained projections" is the right answer; the document should state the rule: a parent composes the child's retained signed snapshot and depends only on that snapshot's revision, not the child ontology.

**8. Operation refinement authority is undefined (Interaction section).** "Instance refinements need explicit precedence and the defining owner's authority" names the problem, not the rule. Proposed rule: a class offers operations; an instance's owning ontology may relabel, default, hide or restrict, never add. Adding an operation is a class change in the class's ontology.

**9. `world_responder` retirement conditions are stated as an order, not as checks ("Why world_responder exists", stage 4).** Make them explicit: no form policy names it as responder; world creation is an offered operation of the space-library class executed via A; HUD/question consumption for that form is gone; the key provisioning in library initialisation is gone; physics authority and pilot are separately justified and stay. Also note that this revises the GUI contract document, which chose responder-backed submissions deliberately.

**10. "Terrain" vs `voxel_ground` (Terrain section, inventory).** The derived `terrain(W)` visual subject is a mark, not a domain instance, per the earlier "marks are not entities" decision. The new `terrain` domain class must not be built on it. Terrain and space separation is otherwise sound.

## 2. Strongest constructive ideas

- **Synchronous acceptance in-proof.** Reuses principal preservation, `can_invoke`, and the existing atomic transaction. A re-signs only when it acts on its own initiative. Missing capability, if any: making the agent instance, not just the namespace, visible to the target's policy (verify).
- **A is the avatar.** U unlocated, A located, client views A's space. Pilot becomes A's embodiment or disappears. This removes a concept rather than adding one.
- **Located-class containment.** Mandatory frame for located classes, optional placement elsewhere. Dissolves the bootstrap, class-definition and unplaced-document exceptions.
- **Admission is the location owner.** Projection reads one ontology; assignment is the mirror.
- **Child snapshot dependency.** Parent depends on the child's signed retained projection revision, matching the unchanged-repeat rule in the agreement.
- **Offered operation = declarative `offered(Class, Op, Params, Goal)` plus `can_invoke` precheck on current state.** No mutation to decide visibility, consistent with the document's own rule against enumerating `action/3`.

## 3. Document and staging improvements

- Add a paragraph deciding direct-vs-autonomous acceptance, and relabel the diagram edge "request authenticated as U" to "U-signed goal, first hop A's acceptance rule" when the synchronous model is chosen. One diagram, same shape.
- Add one edge for A asking U a deferred question, since that interaction type is explicitly retained.
- Insert a "Stage 0, paper only" line: acceptance model, located identity, location owner, containment scope. Then stage 1 unchanged in intent but with `enter` expressed as an offered operation submitted via A.
- Replace "universal containment" with "located-class containment" and delete the exception list.
- In "Confirmed mismatches", separate "verified in source" from "inferred from client code" for the Enter-world claim.
- Terrain: say creation of a world is one composed operation: create space, create terrain, admit, atomically.

## 4. Decisions only Yan can make

1. Direct user operations: U signs with acceptance checked in-proof, or A re-signs asynchronously.
2. U has no spatial location; A is the located instance; pilot folds into A.
3. Containment mandatory only for located classes, or truly universal with a bootstrap placement.
4. One home space plus reference occurrences (the draft's preference) confirmed.
5. Admission in the space's ontology is the authoritative location fact.
6. Instance refinements can hide and restrict but never add operations.

Not done here, per the parent's instruction to run no commands: the AGENTS.md stop notification script. The parent should invoke it when this review is consumed.


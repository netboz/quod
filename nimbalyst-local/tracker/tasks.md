# Tasks

Implementation tickets for the [space architecture plan](/home/yan/src/quod/nimbalyst-local/plans/space-conceptual-architecture-review.md). Stage 0 is complete. Stage 1 remains in progress; S1.1 is completed and committed, and S1.2 is completed and committed (`6db307c5`); stages 2 and 3 remain unstarted. Dependency order is 1 → 2 → 3.

- Stage 1 — One empty space through the user's agent #task[id:tsk_01M5PY8TEX7NP119X8SXNN3HNB status:in-progress priority:medium created:2026-10-24 tags:architecture,space]
  Plan: [Space and interaction architecture](/home/yan/src/quod/nimbalyst-local/plans/space-conceptual-architecture-review.md#smallest-staged-normalization). Implements stage 1 and confirmed decisions D1–D4/D8–D10; the plan remains authoritative. Read [AGENTS.md](/home/yan/src/quod/AGENTS.md) and [multiwrite architecture](/home/yan/src/quod/doc/multiwrite-architecture.md) before implementation.
  
  Status: in progress; S1.1 is completed and committed (`671e1f76`), S1.2 is completed and committed (`6db307c5`), S1.3 is completed, verified and committed with this change, and S1.4–S1.9 remain unstarted. Parent work item for S1.1–S1.9; completion depends on S1.9 [tsk_01M5Q1YXC21Z70NX4DJXSZHD1X](nimbalyst://tsk_01M5Q1YXC21Z70NX4DJXSZHD1X) and its prerequisites. Stage 0 is complete. Blocks stage 2. [Execution map and checklist ownership](/home/yan/src/quod/nimbalyst-local/plans/space-conceptual-architecture-review.md#stage-1-implementation-tickets).
  
  **Outcome**
  
  An authenticated human U instructs their distinct personal agent A to create one empty ordinary space in an explicitly selected existing ontology. A signs the operation. Creation returns a system-generated anchored instance reference, remains recoverable after a lost reply and needs no form helper.
  
  **Implementation checklist**
  
  - [x] Connect the governed U→A attempt-now instruction, A's existing signing/hosting path and target authorization. Associate the original instruction with the exact A-signed operation and provide U's authorized outcome access. An unavailable A must not accept unsubmitted work for later restart; retain deadlines and distinguish refusal from an accepted operation whose reply is missing.
  - [x] Expose original selected result bindings through ordinary outcome lookup, matching the existing atomic-group behavior. Recover the generated reference using the original indexed transaction evidence, including from another authorized device. Keep results recoverable while the original history is retained; do not add a separate retention system or repeat uncertain creation.
  - [ ] Implement generic assertion-triggered construction through the existing assertion hooks and proof/action savepoints. Reading `instance_of/2` remains a query. Creation via `assert/asserta/assertz` allocates and binds a full system-generated ULID and calls `constructor(Class, Instance, BuildPlan)`; callers do not choose IDs. Return `entity_ref(Namespace, GenesisAnchor, InstanceId)`; reject overwriting a live collision without a deleted-instance registry.
  - [ ] Add scoped temporary `with_build_plan` inputs; resolve supplied values before most-specific and inherited defaults, validate and stage attributes before constructors. Automatically run ancestors before descendants once per creation attempt on one ID, using `constructor_order(Class, Parents)` for direct-parent order. Reject cycles, invalid order and unresolved inherited-default conflicts before constructor bodies run. Missing own constructors are allowed; they do not skip parents. Each required part describes its own contents and receives its own ID through the same creation path.
  - [x] Apply all compulsory inherited class checks and target ontology admission. Permit owners/authorized policy administrators to adjust default grants only within those checks. Missing/conflicting grants deny access. Menus and direct goals use the same authorization; a write cannot authorize itself through staged policy changes.
  - [ ] Preserve complete rollback of construction, parts, bindings, events and effects, including caught failures and alternative proof branches. Ensure already-true membership cannot make `goal/1` skip required construction. Preserve surviving ground memberships during source replacement/reordering; loading, commit apply and recovery must not regenerate IDs/names or rerun constructors/reactions. Keep ontology founding integration outside this stage.
  - [ ] Implement ordinary empty-space creation in the explicitly selected existing ontology, normally owned by U. Use finite dimensions of 100 × 100 × 100 metres centered at its origin by default; support `infinite` and positive unit-bearing `box(q(W,Unit),q(H,Unit),q(D,Unit))` through existing measurement rules. Exterior model size is separate; creation adds no terrain, walls, sky or physics.
  - [ ] Generalize existing authorized placement for the ordinary-space case: show its defined 3D Eidolon near A when A is placed, otherwise allow unplaced creation when no destination was supplied. Preserve one containing space and multiple display references. Check explicit destination authority; denied placement must not silently fall back to unplaced creation.
  - [ ] Adopt standard mutable, nonunique `name` separately from identity. Supplied names win; class policy supplies an appropriate ordinary default or supported naming-pool choice, stored once. Update affected `display_name` declarations/readers/writers together within the replacement scope.
  - [ ] Add the minimum shared class-operation metadata and exact-subject GUI/Eidolon binding for creation, reusing existing labels, typed controls, defaults and result handling. A class-level Create affordance submits the construction assertion without an existing instance; it does not introduce a separate creation executor.
  - [ ] Replace only the old route this stage fully covers and remove its unused support after checking callers and runtime reachability. Preserve still-valid test obligations, user-owned changes and data. Terrain continuations and helper duties replaced only by stage 3 remain until that replacement.
  
  **Acceptance checks**
  
  - [ ] Through signed production seams, U instructs A and receives one empty space with the expected owner, selected storage, generated reference, name, dimensions and placement. Exercise explicit placement, near-A placement, unplaced A, missing own constructor, explicit finite dimensions and `infinite`.
  - [ ] Exercise denied actors, unavailable A, changed permissions, stale revisions, missing/conflicting grants, compulsory checks from every parent, owner changes to default grants and direct-call/menu parity. Denial or constructor/part failure leaves no partial creation or placement, including when failure is caught.
  - [ ] Verify construction on a non-space class too: parent/subclass share one ID; parts get separate IDs; shared ancestors run once per attempt; declared parent order holds; default conflicts, cycles and invalid order fail safely. Scoped overrides do not leak; constructor ordering does not change existing Eidolon selection or GUI defaults.
  - [ ] Verify all assertion spellings, stable names/defaults, renaming without identity change, independent replacement IDs, live-ID collision protection, derived membership reads, surviving source reorders and replay/loading boundaries. Restoring committed state does not rerun construction or historical reactions.
  - [ ] Lose the first creation reply in both ordinary and atomic transaction lanes. Recover the original reference and outcome from another authorized device, after clearing the browser journal and after deleting the instance while retaining history. No creation resubmission, duplicate identity allocation or unauthorized result disclosure occurs.
  - [ ] Preserve atomic multi-ontology conflict/rollback, cancellation and revocation behavior through existing owners. Measure unchanged repeats for history reads, projection rebuilds and disk writes; a real update must still reach relevant views.
  - [ ] Record the relevant existing test results, caller/reachability evidence, preserved obligations and production-line delta. Do not claim delivery before implementation and verification.
  
  **Boundaries**
  
  Keep domain state, policy, authorization and constructors in Prolog. Reuse `goal/1`, `action/3`, atomic transactions, recovery, reactions and runtime owners. No new executor, helper queue, generic final-state validator, tombstones or temporary U-signed creation route. Stage 2 owns same-agent entry and broader space views; stage 3 owns terrain separation and full helper retirement. JSON, outbound HTTP, ontology founding, live subclass specialization and ownership GUI remain later work. This ticket does not authorize deployment, commits or data deletion.

- Stage 2 — Same-agent entry and space Eidolons #task[id:tsk_01M5PY8TEXKG858WBZJ1RHC6EW status:to-do priority:medium created:2026-10-24 tags:architecture,space]
  Plan: [Space and interaction architecture](/home/yan/src/quod/nimbalyst-local/plans/space-conceptual-architecture-review.md#smallest-staged-normalization). Implements stage 2 under the confirmed model and existing code retention/retirement map.
  
  Status: unstarted. Depends on [tsk_01M5PY8TEX7NP119X8SXNN3HNB](nimbalyst://tsk_01M5PY8TEX7NP119X8SXNN3HNB) (stage 1). Blocks stage 3.
  
  **Agreed scope**
  
  - Build same-agent entry on stage 1's generalized assignment/admission. Preserve A's identity and exclusive containing-space assignment; authorize movement before client navigation, using existing atomic transitions and both affected owners' policy.
  - Present a space through its exterior, contents and GUI Eidolons with exact subject binding and existing view owners. Keep direct-reference displays separate from exclusive location.
  - Resolve the already-recorded D5/D6 details before recursive contents and ontology predicate views. Reuse the existing predicate catalogue and guarded source editor; do not create another mutable copy of predicates.
  - Retire only the entry/discovery/view routes this replacement covers. Preserve physical preparation and pilots until applicable D7 choices and replacement obligations are covered.
  
  **Completion checks**
  
  - [ ] Entry moves the same A, and navigation follows its committed location. Denied, stale or conflicting entries leave no partial move or duplicate containing-space assignment; permissions of both affected owners remain enforced.
  - [ ] Exterior, GUI and contents views bind to the exact subject. Private contents, revocation, recursion cycles and reconnect work through the existing view/subscription owners; display references remain usable.
  - [ ] D5/D6 details required for recursive and ontology views are recorded within their planned scope. Predicate edits use the existing guarded source editor and source permissions.
  - [ ] Replacement behavior and valid test obligations cover each retired caller. Physical protections, useful editor/GUI behavior and user data survive; unchanged view reuse does not rebuild or replay history unnecessarily.
  
  Read [AGENTS.md](/home/yan/src/quod/AGENTS.md) and [multiwrite architecture](/home/yan/src/quod/doc/multiwrite-architecture.md) before implementation. Keep policy and authorization in Prolog and reuse existing actions, transactions, recovery and runtime owners. No speculative subtasks or additional architecture gates are introduced by this ticket. Implementation remains unstarted; no deployment, commit or data deletion is authorized.

- Stage 3 — Terrain separation and obsolete-helper retirement #task[id:tsk_01M5PY8TEXWW97YYRVFRG3GRPY status:to-do priority:medium created:2026-10-24 tags:architecture,space]
  Plan: [Space and interaction architecture](/home/yan/src/quod/nimbalyst-local/plans/space-conceptual-architecture-review.md#smallest-staged-normalization). Implements stage 3 and the plan's code retention/retirement conditions.
  
  Status: unstarted. Depends on [tsk_01M5PY8TEXKG858WBZJ1RHC6EW](nimbalyst://tsk_01M5PY8TEXKG858WBZJ1RHC6EW) (stage 2).
  
  **Agreed scope**
  
  - Resolve the applicable existing D7 terrain/physical-entry choices. Separate terrain identity, settings, patches and revisions from space; retain voxel generation as its implementation and preserve physical binding.
  - Bind terrain construction and edits through the shared constructors, personal-agent operations and existing generation GUI. Compose a landscape preset from space and terrain; ordinary empty-space creation stays empty.
  - Retire replaced `world_responder` declarations, helper-only hosting/setup/grants, active-question and question-derived identity coupling, UI setup gating and unused support together once all callers and obligations are covered.
  - Keep generic hosting, questions/FIPA for genuine deferred or inter-actor work, shared physics setup, physical authority and useful embodiment roles. Neither `world_authority` nor `world_pilot` is automatically dead because the form helper is removed. Rebind the existing generation form rather than replacing it with a duplicate.
  
  **Completion checks**
  
  - [ ] Terrain has its own identity and state; shared construction/edit operations and the landscape preset work through the personal agent. Existing generation controls and feedback remain available.
  - [ ] Ownership, revisions, generation validation, edited/occupied-terrain refusal, physical consequences and atomic rollback retain their protections after separation.
  - [ ] Replacement covers every helper caller and its acceptance, authorization, operation correlation, uncertainty, cancellation and result feedback. Existing pending questions, key custody and user state are accounted for before retirement.
  - [ ] Caller and runtime reachability checks justify removals, including helper-only exports, UI gating and obsolete fixtures. Preserve still-valid test obligations and document the actual production-line delta.
  - [ ] Shared physics setup, generic questions/FIPA, useful physical authority/embodiment and current terrain arithmetic remain where still required. Authored or founded rules are not silently rewritten, and no user data is deleted.
  
  Read [AGENTS.md](/home/yan/src/quod/AGENTS.md) and [multiwrite architecture](/home/yan/src/quod/doc/multiwrite-architecture.md) before implementation. Keep domain policy/state in Prolog and reuse existing actions, atomic transactions, recovery, reactions and runtime owners. No gameplay, rendering, fog or further voxel feature work is included. Implementation remains unstarted; this ticket authorizes no deployment, commit or data wipe.

- S1.1 — Recover original result bindings through ordinary transaction outcomes #task[id:tsk_01M5Q1YXC2H4S1BERCY9ERXWJQ status:done priority:medium created:2026-10-24 tags:architecture,space,stage-1]
  Parent work item: [tsk_01M5PY8TEX7NP119X8SXNN3HNB](nimbalyst://tsk_01M5PY8TEX7NP119X8SXNN3HNB). Plan: [Space and interaction architecture](/home/yan/src/quod/nimbalyst-local/plans/space-conceptual-architecture-review.md#stage-1-implementation-tickets). Status: completed; implemented, verified and committed as `671e1f76a3919c2aa3a0c80bce1878781d918cf2`, including the ordinary foreign-only recovery correction. Other stage-1 tickets remain unstarted.
  
  Dependencies: none. Implementation remains within the agreed stage-1 scope.
  
  **Scope and ownership**
  
  Extend the existing outcome owner so ordinary committed-operation lookup returns the original selected bindings, as atomic-group lookup already does. Read the exact retained transaction result through the index; retain the current compact index and evidence/permission checks. Results remain recoverable while that history is retained, including after the created instance is deleted. This item owns result retrieval, not the U-to-A instruction association (S1.2).
  
  **Inspected code and verification seams**
  
  [src/quod_outcome.erl:1120](/home/yan/src/quod/src/quod_outcome.erl:1120) · [src/quod_prolog.erl:5303](/home/yan/src/quod/src/quod_prolog.erl:5303) · [src/quod_client_result.erl:439](/home/yan/src/quod/src/quod_client_result.erl:439) · [test/quod_outcome_tests.erl:1](/home/yan/src/quod/test/quod_outcome_tests.erl:1) · [test/quod_outcome_endpoint_tests.erl:1](/home/yan/src/quod/test/quod_outcome_endpoint_tests.erl:1)
  
  **Acceptance checks**
  
  - [x] Lose a successful reply and recover identical named bindings through ordinary origin-local, ordinary foreign-only and atomic lanes; anonymous/internal variables remain excluded. Certified remote receipts also recover the original named bindings.
  - [x] Restart the outcome owner and resolve again, including after instance deletion with retained history. Missing/unavailable evidence stays uncertain; no rerun or forced multiwriter transaction.
  - [x] Wrong scope/anchor or unauthorized lookup is denied. Repeated unchanged reads do not scan ledger prefixes, rebuild projections or write/sync storage.
  
  **Replacement and documentation:** Replaced ordinary status-only result assembly, the empty-binding aggregate HTTP reconstruction and the committed-without-bindings fallback. Reused the existing exact transaction/claim readers, receipt verification, durable result decoder and HTTP result rendering; no new execution or recovery owner. Kept compact certification snapshots and pending/rejected/aborted semantics. Updated the [outcome contract](/home/yan/src/quod/doc/proofs.md:60). Recovery requires retained history and compatible validators; U-to-A instruction association remains S1.2.
  
  **Existing-ticket boundary:** Reuse current outcome recovery. [QUD.18](nimbalyst://QUD.18) retains durable physics-impact occurrences; do not transfer that domain into this ticket.
  
  Read [AGENTS.md](/home/yan/src/quod/AGENTS.md) and [multiwrite architecture](/home/yan/src/quod/doc/multiwrite-architecture.md). Kept domain state/policy in Prolog and reused existing transaction, recovery and runtime owners. **Verification:** 346 targeted EUnit tests and `rebar3 xref` pass (both exit 0). The former foreign-only gap is covered by the real-owner lost-reply, deletion, restart, authorization and unchanged-read tests. Remote-receipt tests use the production exact-history and certificate verifiers with fixture transport. Three unchanged ordinary origin-local or foreign-only lookups perform three exact indexed reads and three read-only snapshot opens; atomic lookups perform none. No traced prefix scans, projection rebuilds, writes or syncs occur. See the [review and correction disposition](/home/yan/src/quod/nimbalyst-local/plans/space-s1.1-claude-review.md) and [verification, retained failed runs and limitations](/tmp/quod-s1.1-verification.md). Production delta against the original user-owned starting tree: +92 / −31 lines, net +61, for exact result retrieval and boundary/deadline checks. No full release, Common Test, Dialyzer or multi-node QUIC gate was run. No deployment, commit, data deletion or agent spawning is authorized by ticket creation.

- S1.2 — Submit immediate user instructions as the distinct personal agent #task[id:tsk_01M5Q1YXC2ZWGX69MZGQH2YQZS status:completed priority:medium created:2026-10-24 tags:architecture,space,stage-1]
  Parent work item: [tsk_01M5PY8TEX7NP119X8SXNN3HNB](nimbalyst://tsk_01M5PY8TEX7NP119X8SXNN3HNB). Plan: [Space and interaction architecture](/home/yan/src/quod/nimbalyst-local/plans/space-conceptual-architecture-review.md#stage-1-implementation-tickets). Status: completed; implemented, verified and committed (`6db307c5`). Session: `043acb2c-4ea8-4d1a-90d8-08159b4ec301`.

  **Review follow-up (implemented and verified):** Requested Claude Fable review completed, session `cd5a7336-89f0-4e26-9679-fe5c0480ddce`. Both confirmed findings are corrected: definite refusals check the existing association before reporting unsent, and authorization uses verified authority fields without historical request decoding. Current revocation remains enforced; duplicates retain their original uncertain operation. [Correction evidence](/tmp/quod-s1.2-refinement-verification.md) · [Full review](/tmp/quod-s1.2-claude-review.md). No additional review or deployment occurred.
  
  Dependencies: S1.1 [tsk_01M5Q1YXC2H4S1BERCY9ERXWJQ](nimbalyst://tsk_01M5Q1YXC2H4S1BERCY9ERXWJQ). These are implementation dependencies, not additional design approvals.
  
  **Scope and ownership**
  
  Connect the authenticated U-to-A relationship, attempt-now acceptance, existing hosting/vault signing and target submission. Target ontology is explicit; A signs the domain operation under committed Prolog policy. Retain an authenticated association between U's instruction and A's exact request through existing owners, and authorize U to recover S1.1 results from another device even when A's first reply was lost. Include the minimal account/agent discovery and provisioning adaptation needed to obtain distinct A through existing lifecycle mechanisms.
  
  **Inspected code and verification seams**
  
  [priv/ontologies/human_user_instance.pl:6](/home/yan/src/quod/priv/ontologies/human_user_instance.pl:6) · [priv/ontologies/agent_instance.pl:267](/home/yan/src/quod/priv/ontologies/agent_instance.pl:267) · [src/predicates/quod_agent_predicates.erl:181](/home/yan/src/quod/src/predicates/quod_agent_predicates.erl:181) · [src/quod_client_goal_ingress.erl:168](/home/yan/src/quod/src/quod_client_goal_ingress.erl:168) · [src/quod_agent.erl:1](/home/yan/src/quod/src/quod_agent.erl:1) · [client/src/signed-client.js:46](/home/yan/src/quod/client/src/signed-client.js:46) · [test/quod_agent_hosting_tests.erl:355](/home/yan/src/quod/test/quod_agent_hosting_tests.erl:355)
  
  **Acceptance checks**
  
  - [x] A's authenticated identity is the target actor; routing a U-signed request through A's namespace cannot substitute for A-signing. Target authorization still applies.
  - [x] Unavailable A refuses before submission and restart does not execute the unsubmitted instruction. Lost replies after possible submission retain exact original bytes/identity and never cause resubmission.
  - [x] With the browser journal cleared, a second authorized device resolves the original instruction, A-signed operation and bindings. Another human cannot read or sign that operation; staged grants cannot authorize signing.
  - [x] Exercise cancellation, revocation, host restart and existing absolute deadlines. Repeated lookups reuse existing custody/outcome state; no new queue or duplicate request/status owner.
  
  **Replacement and documentation:** Replace direct-U submission only for the domain route this stage delivers; adapt callers and authorization together. Preserve human authentication and existing genuine deferred/FIPA work. Document acceptance-versus-commit behavior.
  
  **Existing-ticket boundary:** [QUD.21](nimbalyst://QUD.21)'s intermediate call-chain hardening is separate and is not a prerequisite. Do not add arbitrary FIPA goal/answer generalization.
  
  Read [AGENTS.md](/home/yan/src/quod/AGENTS.md) and [multiwrite architecture](/home/yan/src/quod/doc/multiwrite-architecture.md). Keep domain state/policy in Prolog and reuse existing transaction, recovery and runtime owners. Implementation and verification followed these rules; delivery evidence is recorded below. No deployment, commit, data deletion or agent spawning is authorized by ticket creation.

  **Delivery evidence:** Implemented the Prolog-owned U→A policy and authenticated association, immediate dispatch through the existing hosted actor/custody/vault path, and authorized lookup through S1.1’s outcome owner. Added explicit-target client submission, cross-device discovery/recovery and personal-agent provisioning through the shared account/resource initializer. No new queue, executor or request/status owner. New signing goals reuse the lossless readable formatter; retained request bytes remain exact. Removed duplicated HTTP test routes and reused production routes.

  **Verification:** Final sequential gates passed: 372 EUnit tests; 234 client tests across 22 files; TypeScript; production xref. Real-owner checks cover foreign/atomic target denial, rollback, cancellation before custody and during the target proof, U/A revocation, unavailable/busy refusal, restart without replay, absolute expiry, second-device/key-rotation access, original bindings and no resubmission. Three unchanged personal lookups perform three indexed reads and no replay, rebuild, writes or syncs, also after outcome-owner restart; a real update is still applied. Three authorization checks perform no signed-request verification, typed-request decoding or source parsing, also after twelve real instruction updates; current key revocation still denies. Endpoint tests distinguish fresh refusal from a retained duplicate after U revocation. [Full evidence, retained failures and limitations](/tmp/quod-s1.2-refinement-verification.md).

  **Contract and limits:** [Immediate personal instructions](/home/yan/src/quod/doc/runtime-and-agents.md#immediate-personal-instructions) and [request/result contract](/home/yan/src/quod/doc/proofs.md). Immediate dispatch requires A installed at the receiving node; existing ontologies require authorized source composition. An interrupted association without a transaction claim stays uncertain and is never replayed. Later space/class GUI integration remains outside S1.2. No deployment or data migration performed.

  **Production delta:** +416 lines net against the starting working tree, excluding tests/docs and existing user changes: 112 Prolog, 204 Erlang, 100 client/declaration lines. Review corrections account for +54/−15, net +39 lines. Growth supplies the new authenticated association/submission contract while reusing lifecycle owners. The plan link succeeded; the ticket-link API reports success with zero linked sessions, so the current session is recorded explicitly above. Earlier collaborative body updates failed. The final detailed-description sync was rejected by automatic approval review as a sensitive payload to an insufficiently trusted destination; detailed evidence remains local. Status/progress metadata is handled separately.

  **Commit and isolation verification:** `6db307c5f94f395bc1c30ff96817aa147920614f` includes S1.2 and the necessary pre-existing account/setup prerequisites explicitly approved by Yan. The isolated tree passes 370 backend tests, all 196 client tests in its 19 files, TypeScript, xref and scoped whitespace checks. Its production delta against HEAD is +526/−72, net +454 lines, including those prerequisites; the S1.2-only delta above remains +416. All 34 working source/test/doc files were restored byte-for-byte after committing; unrelated physics/voxel work remains uncommitted. [Commit verification, exact tree and retained preparation failures](/tmp/quod-s1.2-commit-verification.md). Ticket metadata is completed and linked to the commit; stage 1 and the plan remain open.

- S1.3 — Enforce shared class requirements and instance permission overrides #task[id:tsk_01M5Q1YXC2JDBWR3AKXAB7RPQN status:completed priority:medium created:2026-10-24 tags:architecture,space,stage-1]
  Parent work item: [tsk_01M5PY8TEX7NP119X8SXNN3HNB](nimbalyst://tsk_01M5PY8TEX7NP119X8SXNN3HNB). Plan: [Space and interaction architecture](/home/yan/src/quod/nimbalyst-local/plans/space-conceptual-architecture-review.md#stage-1-implementation-tickets). Status: completed; implemented and verified with review corrections, committed with this change.
  
  Dependencies: none; delivered within the agreed stage-1 scope. These are implementation dependencies, not additional design approvals.
  
  **Scope and ownership**
  
  Implement the confirmed shared Prolog policy for creation and offered operations: all compulsory requirements from applicable parents, default grants with most-specific precedence, and explicit owner/authorized-administrator overrides within those requirements. Keep target ontology admission and committed-policy evaluation authoritative. Expose one guard for constructor execution, direct goals and advisory menu availability; constructor order does not select permission precedence.
  
  **Inspected code and verification seams**
  
  [priv/ontologies/common_predicates.pl:138](/home/yan/src/quod/priv/ontologies/common_predicates.pl:138) · [src/predicates/quod_ask.erl:1518](/home/yan/src/quod/src/predicates/quod_ask.erl:1518) · [src/predicates/quod_agent_predicates.erl:160](/home/yan/src/quod/src/predicates/quod_agent_predicates.erl:160) · [priv/ontologies/lobby_instance.pl:4](/home/yan/src/quod/priv/ontologies/lobby_instance.pl:4) · [test/quod_class_semantics_tests.erl:45](/home/yan/src/quod/test/quod_class_semantics_tests.erl:45)
  
  **Acceptance checks**
  
  - [x] Owners/authorized administrators can widen or withdraw default grants but cannot waive compulsory checks from any parent; missing/ambiguous grants deny.
  - [x] A staged ACL edit cannot authorize its own write or constructor; concurrent committed-policy changes conflict through existing read tracking.
  - [x] The same exact actor, target and parameters get the same authorization through direct goals and operation invocation. Advisory discovery executes no mutations and may require later parameter checks.
  - [x] Keep cycle-tolerant class queries and existing ontology admission behavior; no second Erlang/JavaScript policy engine or generic final-state validator.
  
  **Replacement and documentation:** Factor affected ad-hoc policy checks into the shared guard only when equivalent obligations are covered; retain terrain/helper grants until stage 3 replaces their callers.
  
  **Existing-ticket boundary:** [QUD.20](nimbalyst://QUD.20)/[QUD.32](nimbalyst://QUD.32) are completed admission/reflection foundations. This is the new class-default/instance-override contract, not another system ACL review.
  
  Read [AGENTS.md](/home/yan/src/quod/AGENTS.md) and [multiwrite architecture](/home/yan/src/quod/doc/multiwrite-architecture.md). Keep domain state/policy in Prolog and reuse existing transaction, recovery and runtime owners. Implementation and verification followed these rules; evidence is recorded below. No deployment, commit, data deletion or agent spawning is authorized by ticket creation.

  **Implementation and verification:** Shared Prolog `operation_authorized/2` and governed `set_instance_permission/3` enforce the four acceptance groups. The former custody-only committed-policy evaluator is now shared; its old implementation was removed. Final sequential gates passed: **368 targeted EUnit tests, zero failures**, and **production xref**. Signed production ingress verifies exact actors/subjects/parameters, direct/offered parity, owner/admin edits, staged ownership/administrator/grant/creation-policy refusal and unchanged target admission. Sealed-plan read checks conflict on grant, requirement, hierarchy, membership, callback, owner and administrator changes. Three unchanged signed advisory checks perform no history reads, builds, writes or syncs; a real committed withdrawal changes the result. [Final correction evidence, frozen tree and retained failures](/tmp/quod-s1.3-refinement-verification.md); [initial verification](/tmp/quod-s1.3-verification.md).

  **Review corrections:** The reserved Prolog grant-edit branch now requires an instance before any default can authorize it. The shared evaluator classifies forbidden foreign scope hops as invalid policy, preserving typed owner fences. Added coverage for equal unrelated-parent defaults, ground-input administrator rules, staged administrator self-grants, forbidden ancestry/callbacks and ontology self-membership refusal. No-I/O measurement now waits for actual source receipts through the existing subscribed helper; assertions remain unchanged. The proposed administrator enumeration was rejected because authored rules need not enumerate their authorized actors. Review corrections add two net production lines. [Requested Fable review](/tmp/quod-s1.3-review/claude-review.md).

  **Contract, scope and delta:** [Shared operation permissions](/home/yan/src/quod/doc/proofs.md#class-and-instance-operation-permissions). Policy callbacks, derived memberships and consulted ancestry are strictly local committed Prolog. Foreign ancestry and the current ontology self-instance are explicitly refused; ontology-operation integration remains later work. Creation is verified at the shared guard boundary; S1.5 retains constructor/assertion integration, S1.8 retains GUI binding, and stage 3 retains terrain/helper replacement. No final-state validator or second policy engine. Production **+130/−18, net +112 lines**; growth supplies the new shared policy contract and guard while reusing existing owners. Committed with this change following Yan’s explicit approval; no deployment or data migration. Session `147aa5a9-2b18-4157-8d81-76831d21abe7` is linked to both this ticket and the plan, independently confirmed in session metadata. Stage 1 and the plan remain open.

  **Tracker sync limitation:** Status/progress and the local body snapshot were saved. The initial collaborative body writes and the final correction-body write failed; detailed evidence and checked acceptance remain in this local ticket and the linked verification reports.

- S1.4 — Define generic constructor inputs, inheritance, defaults and names #task[id:tsk_01M5Q1YXC2V8G59WR1KA7E8NND status:to-do priority:medium created:2026-10-24 tags:architecture,space,stage-1]
  Parent work item: [tsk_01M5PY8TEX7NP119X8SXNN3HNB](nimbalyst://tsk_01M5PY8TEX7NP119X8SXNN3HNB). Plan: [Space and interaction architecture](/home/yan/src/quod/nimbalyst-local/plans/space-conceptual-architecture-review.md#stage-1-implementation-tickets). Status: unstarted.
  
  Dependencies: none; ready to start within the agreed stage-1 scope. These are implementation dependencies, not additional design approvals.
  
  **Scope and ownership**
  
  Implement Prolog-owned construction rules over existing isa/2 and attribute metadata: constructor(Class, Instance, BuildPlan), scoped with_build_plan inputs, once-resolved validated initial attributes, and constructor_order/2. Schedule ancestors before descendants with shared ancestors once per attempt; supplied values outrank most-specific then inherited defaults. Distinguish missing own code from declared code that fails. Standardize mutable nonunique name and class-appropriate ordinary/naming-pool defaults. Each class describes its required parts and explicitly passes supported overrides; parts get their own construction scopes. S1.5 owns live assertion integration and proof rollback.
  
  **Inspected code and verification seams**
  
  [priv/ontologies/common_predicates.pl:138](/home/yan/src/quod/priv/ontologies/common_predicates.pl:138) · [priv/ontologies/animals.pl:24](/home/yan/src/quod/priv/ontologies/animals.pl:24) · [priv/ontologies/quod_gui.pl:201](/home/yan/src/quod/priv/ontologies/quod_gui.pl:201) · [priv/ontologies/quod_names.pl:103](/home/yan/src/quod/priv/ontologies/quod_names.pl:103) · [test/quod_class_semantics_tests.erl:45](/home/yan/src/quod/test/quod_class_semantics_tests.erl:45) · [test/quod_gui_components_tests.erl:1](/home/yan/src/quod/test/quod_gui_components_tests.erl:1)
  
  **Acceptance checks**
  
  - [ ] A diamond runs its shared ancestor once in the declared parent order; missing, duplicate, extra or contradictory parent-order entries and constructor cycles fail before bodies run.
  - [ ] Unrelated conflicting defaults require caller/subclass resolution. Invalid supplied values fail instead of falling back; changing a class default does not rewrite existing instances.
  - [ ] Absent own constructor still runs parents; failing own/parent/part code is not swallowed. Verify on non-space classes as well as the space consumer.
  - [ ] Names can duplicate and change without changing identity; class-selected naming pools are used only for supported kinds. Nested part inputs do not inherit unrelated outer overrides.
  
  **Replacement and documentation:** Reuse/refactor existing default/type selection rather than inventing a parallel slot schema. Preserve current GUI default and Eidolon selection behavior. Migrate name readers/writers together only in the replaced scope; terrain-specific display_name migration remains with stage 3.
  
  **Existing-ticket boundary:** Existing class/GUI primitives are foundations, not an already-installed constructor. Do not reopen live subclass specialization or composed-part deletion.
  
  Read [AGENTS.md](/home/yan/src/quod/AGENTS.md) and [multiwrite architecture](/home/yan/src/quod/doc/multiwrite-architecture.md). Keep domain state/policy in Prolog and reuse existing transaction, recovery and runtime owners. Verification is required during implementation, not claimed here. No deployment, commit, data deletion or agent spawning is authorized by ticket creation.

- S1.5 — Integrate assertion construction with ULIDs, rollback and source recovery #task[id:tsk_01M5Q1YXC2AWGSJT9CJ86R13W8 status:to-do priority:medium created:2026-10-24 tags:architecture,space,stage-1]
  Parent work item: [tsk_01M5PY8TEX7NP119X8SXNN3HNB](nimbalyst://tsk_01M5PY8TEX7NP119X8SXNN3HNB). Plan: [Space and interaction architecture](/home/yan/src/quod/nimbalyst-local/plans/space-conceptual-architecture-review.md#stage-1-implementation-tickets). Status: unstarted.
  
  Dependencies: S1.3 [tsk_01M5Q1YXC2JDBWR3AKXAB7RPQN](nimbalyst://tsk_01M5Q1YXC2JDBWR3AKXAB7RPQN); S1.4 [tsk_01M5Q1YXC2V8G59WR1KA7E8NND](nimbalyst://tsk_01M5Q1YXC2V8G59WR1KA7E8NND). These are implementation dependencies, not additional design approvals.
  
  **Scope and ownership**
  
  Wire all three assertion spellings into the existing Erlog hook, writable proof overlay and action/savepoint machinery. Allocate and bind a full secure-random ULID before constructor dispatch, preserving it in sealed material and selected results. Run S1.3 committed-policy checks and S1.4 construction inside the original proof. Own the whole lifecycle distinction: live creation, existing/derived membership, guarded source replacement, loading/founding compilation, commit apply and recovery. Keep these together so installing the hook cannot accidentally execute constructors while loading source.
  
  **Inspected code and verification seams**
  
  [_build/default/lib/erlog/src/erlog_int.erl:477](/home/yan/src/quod/_build/default/lib/erlog/src/erlog_int.erl:477) · [src/quod_erlog_db_local_prove.erl:135](/home/yan/src/quod/src/quod_erlog_db_local_prove.erl:135) · [src/quod_proof_savepoint.erl:44](/home/yan/src/quod/src/quod_proof_savepoint.erl:44) · [src/predicates/quod_action_predicates.erl:45](/home/yan/src/quod/src/predicates/quod_action_predicates.erl:45) · [priv/ontologies/quod_prolog.pl:215](/home/yan/src/quod/priv/ontologies/quod_prolog.pl:215) · [src/quod_committed_projection.erl:613](/home/yan/src/quod/src/quod_committed_projection.erl:613) · [src/quod_diff.erl:284](/home/yan/src/quod/src/quod_diff.erl:284) · [test/quod_action_savepoint_tests.erl:1](/home/yan/src/quod/test/quod_action_savepoint_tests.erl:1) · [test/quod_prolog_ontology_tests.erl:114](/home/yan/src/quod/test/quod_prolog_ontology_tests.erl:114)
  
  **Acceptance checks**
  
  - [ ] assert/asserta/assertz with the creation output variable bind one generated ID; query/derived membership and membership rules allocate nothing. Normal creation rejects caller-selected new IDs; live collisions never overwrite an instance.
  - [ ] Parent and subclass constructors share one ID; each new part gets another. Concurrent creations use distinct generated IDs without a per-ontology counter or deleted-instance catalogue.
  - [ ] Caught failure, exception, backtracking or failed required part restores membership, attributes, part state, events, effects and bindings through existing savepoints. Already-true membership cannot skip construction through goal/1's shortcut.
  - [ ] Surviving ground memberships remain stable across source reorder/replacement; source round-trip checks remain meaningful. Additional classification is not implicit live specialization.
  - [ ] Loading, founding compilation, apply, restart and projection rebuild restore decided facts without running constructors, drawing names or regenerating IDs. Validators consume sealed generation results rather than independently drawing them; strict read-only assertions still fail.
  
  **Replacement and documentation:** Use one assertion/lifecycle path and existing owners; remove replaced registration/dispatch duplication within this scope. Update affected source/action/recovery documentation and retain current savepoint/transaction tests. No new executor, reaction-based constructor or automatic final-state validator.
  
  **Existing-ticket boundary:** Ontology founding integration remains outside stage 1; this item prevents accidental constructor execution during existing founding/source loads rather than making ontology creation an ordinary constructor.
  
  Read [AGENTS.md](/home/yan/src/quod/AGENTS.md) and [multiwrite architecture](/home/yan/src/quod/doc/multiwrite-architecture.md). Keep domain state/policy in Prolog and reuse existing transaction, recovery and runtime owners. Verification is required during implementation, not claimed here. No deployment, commit, data deletion or agent spawning is authorized by ticket creation.

- S1.6 — Generalize exclusive placement to ordinary nonphysical spaces #task[id:tsk_01M5Q1YXC2AQK9YP4GRXM4FYBV status:to-do priority:medium created:2026-10-24 tags:architecture,space,stage-1]
  Parent work item: [tsk_01M5PY8TEX7NP119X8SXNN3HNB](nimbalyst://tsk_01M5PY8TEX7NP119X8SXNN3HNB). Plan: [Space and interaction architecture](/home/yan/src/quod/nimbalyst-local/plans/space-conceptual-architecture-review.md#stage-1-implementation-tickets). Status: unstarted.
  
  Dependencies: S1.3 [tsk_01M5Q1YXC2JDBWR3AKXAB7RPQN](nimbalyst://tsk_01M5Q1YXC2JDBWR3AKXAB7RPQN). These are implementation dependencies, not additional design approvals.
  
  **Scope and ownership**
  
  Adapt the existing instance-owned assignment and destination-owned admission transition for ordinary spaces, retaining one containing space, revisions and atomic consent of both owners. Separate location from the existing many-to-many display references. Carry the existing transform/depiction vocabulary through nonphysical placement without requesting physics or copying instance state. S1.7 selects explicit versus near-A versus unplaced creation; same-agent enter and recursive views remain stage 2.
  
  **Inspected code and verification seams**
  
  [priv/ontologies/space.pl:56](/home/yan/src/quod/priv/ontologies/space.pl:56) · [priv/ontologies/space_view.pl:3](/home/yan/src/quod/priv/ontologies/space_view.pl:3) · [priv/ontologies/quod_modelling.pl:151](/home/yan/src/quod/priv/ontologies/quod_modelling.pl:151) · [priv/ontologies/quod_rendering.pl:34](/home/yan/src/quod/priv/ontologies/quod_rendering.pl:34) · [test/quod_space_tests.erl:91](/home/yan/src/quod/test/quod_space_tests.erl:91)
  
  **Acceptance checks**
  
  - [ ] Place an existing nonphysical instance into an ordinary space through both owners' authorized atomic transition, including different ontologies; refusal or conflict leaves no half-assignment.
  - [ ] Competing destinations cannot create two containing spaces; withdrawal retains the existing revision protection. Preserve current physical consequence checks when a physical transition is used.
  - [ ] Two display references can depict one instance without creating two locations or changing storage/ownership. Removing a display reference does not delete the instance.
  - [ ] Ordinary placement supplies a usable local transform/depiction without physics allocation. Repeated unchanged projection does not copy state, replay history or rebuild retained resources.
  
  **Replacement and documentation:** Generalize the designated assignment owner and its projection instead of adding a second ordinary-space registry. Remove physical-only assumptions only where replacement behavior is covered; retain physics setup and meaningful display membership.
  
  **Existing-ticket boundary:** Reuse the completed [QUD.33](nimbalyst://QUD.33) foundation. Do not reopen it or absorb [QUD.3](nimbalyst://QUD.3)/[QUD.26](nimbalyst://QUD.26) physical simulation and hardware work.
  
  Read [AGENTS.md](/home/yan/src/quod/AGENTS.md) and [multiwrite architecture](/home/yan/src/quod/doc/multiwrite-architecture.md). Keep domain state/policy in Prolog and reuse existing transaction, recovery and runtime owners. Verification is required during implementation, not claimed here. No deployment, commit, data deletion or agent spawning is authorized by ticket creation.

- S1.7 — Create one empty space with explicit storage and optional placement #task[id:tsk_01M5Q1YXC2X7DBYHA09GX2BK0Y status:to-do priority:medium created:2026-10-24 tags:architecture,space,stage-1]
  Parent work item: [tsk_01M5PY8TEX7NP119X8SXNN3HNB](nimbalyst://tsk_01M5PY8TEX7NP119X8SXNN3HNB). Plan: [Space and interaction architecture](/home/yan/src/quod/nimbalyst-local/plans/space-conceptual-architecture-review.md#stage-1-implementation-tickets). Status: unstarted.
  
  Dependencies: S1.2 [tsk_01M5Q1YXC2ZWGX69MZGQH2YQZS](nimbalyst://tsk_01M5Q1YXC2ZWGX69MZGQH2YQZS); S1.5 [tsk_01M5Q1YXC2AWGSJT9CJ86R13W8](nimbalyst://tsk_01M5Q1YXC2AWGSJT9CJ86R13W8); S1.6 [tsk_01M5Q1YXC2AQK9YP4GRXM4FYBV](nimbalyst://tsk_01M5Q1YXC2AQK9YP4GRXM4FYBV). These are implementation dependencies, not additional design approvals.
  
  **Scope and ownership**
  
  Supply the space class defaults/constructor as the first domain consumer of shared construction. The instruction chooses an existing target ontology; normally U owns the new space while A signs. Default dimensions are a 100-metre cube centered at the origin; accept infinite or three strictly positive unit-bearing lengths through existing exact measurement rules. Compose optional placement and instance facts atomically. An explicit destination is authorized; otherwise place the defined 3D-model Eidolon near placed A or create unplaced when A is actually unplaced. Extent and exterior model size remain distinct.
  
  **Inspected code and verification seams**
  
  [priv/ontologies/space.pl:3](/home/yan/src/quod/priv/ontologies/space.pl:3) · [priv/ontologies/quod_measure.pl:114](/home/yan/src/quod/priv/ontologies/quod_measure.pl:114) · [priv/ontologies/common_predicates.pl:46](/home/yan/src/quod/priv/ontologies/common_predicates.pl:46) · [priv/ontologies/space_view.pl:3](/home/yan/src/quod/priv/ontologies/space_view.pl:3) · [test/quod_space_tests.erl:1](/home/yan/src/quod/test/quod_space_tests.erl:1) · [test/quod_gui_examples_tests.erl:12](/home/yan/src/quod/test/quod_gui_examples_tests.erl:12)
  
  **Acceptance checks**
  
  - [ ] Through A's signed production route, create an empty space in the selected existing ontology with correct U ownership, full anchored reference, stable name and default/overridden dimensions.
  - [ ] Exercise explicit placement, near-A placement and unplaced A. Failed location lookup is not proof of absence; denied explicit placement rolls back creation rather than silently falling back.
  - [ ] Reject non-length, zero/negative or malformed dimensions; exact compatible-unit conversion works. Infinite extent does not allocate infinite resources.
  - [ ] Space creation allocates no terrain, sky, walls or simulation. Ownership, storage and containing space remain independent; replay preserves reference/name/state.
  
  **Replacement and documentation:** Reuse shared space and naming primitives; do not add a special create_space executor or make empty creation call the landscape helper. Preserve the existing terrain creation route until stage 3 replaces it. Update ordinary-space behavior documentation.
  
  **Existing-ticket boundary:** [QUD.33](nimbalyst://QUD.33) stays completed for the old foundation; [QUD.31](nimbalyst://QUD.31) remains the broader terminology reconciliation task, not a stage-1 prerequisite.
  
  Read [AGENTS.md](/home/yan/src/quod/AGENTS.md) and [multiwrite architecture](/home/yan/src/quod/doc/multiwrite-architecture.md). Keep domain state/policy in Prolog and reuse existing transaction, recovery and runtime owners. Verification is required during implementation, not claimed here. No deployment, commit, data deletion or agent spawning is authorized by ticket creation.

- S1.8 — Describe and bind class operations through the shared Prolog GUI model #task[id:tsk_01M5Q1YXC2YVTBAC8RRBK73RXY status:to-do priority:medium created:2026-10-24 tags:architecture,space,stage-1]
  Parent work item: [tsk_01M5PY8TEX7NP119X8SXNN3HNB](nimbalyst://tsk_01M5PY8TEX7NP119X8SXNN3HNB). Plan: [Space and interaction architecture](/home/yan/src/quod/nimbalyst-local/plans/space-conceptual-architecture-review.md#stage-1-implementation-tickets). Status: unstarted.
  
  Dependencies: S1.3 [tsk_01M5Q1YXC2JDBWR3AKXAB7RPQN](nimbalyst://tsk_01M5Q1YXC2JDBWR3AKXAB7RPQN); S1.5 [tsk_01M5Q1YXC2AWGSJT9CJ86R13W8](nimbalyst://tsk_01M5Q1YXC2AWGSJT9CJ86R13W8). These are implementation dependencies, not additional design approvals.
  
  **Scope and ownership**
  
  Combine existing interface descriptions, class-selected recipes and typed form binding into the minimum shared offered-operation contract: labels/help, class or exact instance subject, input/default metadata, authored bound goal, named result and advisory availability. A class Create affordance prepares assertion-triggered construction without an existing space instance. Generalize binding to preserve intentional result variables while validating submitted fields; do not turn internal outputs or arbitrary client continuations into executable authority. S1.9 owns client presentation/dispatch.
  
  **Inspected code and verification seams**
  
  [priv/ontologies/quod_prolog.pl:18](/home/yan/src/quod/priv/ontologies/quod_prolog.pl:18) · [priv/ontologies/common_predicates.pl:46](/home/yan/src/quod/priv/ontologies/common_predicates.pl:46) · [priv/ontologies/gui_instance.pl:34](/home/yan/src/quod/priv/ontologies/gui_instance.pl:34) · [priv/ontologies/gui_instance.pl:145](/home/yan/src/quod/priv/ontologies/gui_instance.pl:145) · [priv/ontologies/quod_gui.pl:201](/home/yan/src/quod/priv/ontologies/quod_gui.pl:201) · [src/quod_client_goal.erl:520](/home/yan/src/quod/src/quod_client_goal.erl:520) · [test/quod_gui_components_tests.erl:1](/home/yan/src/quod/test/quod_gui_components_tests.erl:1)
  
  **Acceptance checks**
  
  - [ ] Describe class creation and an instance operation through the same contract, including inputs/defaults and a named creation output. No instance is required just to discover class creation.
  - [ ] Wrong anchors/subjects, unexpected fields, stale definitions and altered fixed parameters are refused; direct invocation enforces S1.3 checks again.
  - [ ] Discovery is read-only/advisory and cannot mutate state or grant access. Parameter-dependent permission is rechecked after input; not every action/3 becomes a public operation.
  - [ ] Reuse authored GUI controls, type checks and recipes; retain genuine deferred-question validation and continuation tests.
  
  **Replacement and documentation:** Factor shared compilation/binding from question-specific admission without duplicating it or removing questions. Replace only operation-description special cases covered here; preserve source/inspection Eidolons.
  
  **Existing-ticket boundary:** [QUD.25](nimbalyst://QUD.25) retains delivered controls and outstanding headset acceptance. [QUD.32](nimbalyst://QUD.32) retains ontology reflection; [QUD.35](nimbalyst://QUD.35) remains the later graphical workbench.
  
  Read [AGENTS.md](/home/yan/src/quod/AGENTS.md) and [multiwrite architecture](/home/yan/src/quod/doc/multiwrite-architecture.md). Keep domain state/policy in Prolog and reuse existing transaction, recovery and runtime owners. Verification is required during implementation, not claimed here. No deployment, commit, data deletion or agent spawning is authorized by ticket creation.

- S1.9 — Deliver the bound Create-space interface and verify the complete stage-1 flow #task[id:tsk_01M5Q1YXC21Z70NX4DJXSZHD1X status:to-do priority:medium created:2026-10-24 tags:architecture,space,stage-1]
  Parent work item: [tsk_01M5PY8TEX7NP119X8SXNN3HNB](nimbalyst://tsk_01M5PY8TEX7NP119X8SXNN3HNB). Plan: [Space and interaction architecture](/home/yan/src/quod/nimbalyst-local/plans/space-conceptual-architecture-review.md#stage-1-implementation-tickets). Status: unstarted.
  
  Dependencies: S1.7 [tsk_01M5Q1YXC2X7DBYHA09GX2BK0Y](nimbalyst://tsk_01M5Q1YXC2X7DBYHA09GX2BK0Y); S1.8 [tsk_01M5Q1YXC2YVTBAC8RRBK73RXY](nimbalyst://tsk_01M5Q1YXC2YVTBAC8RRBK73RXY). These are implementation dependencies, not additional design approvals.
  
  **Scope and ownership**
  
  Connect class-operation discovery and exact-subject GUI/Eidolon opening to the existing ordinary/spatial panel controllers and S1.2 personal-agent submission. Present the explicit target-ontology selection and class Create form; display the committed reference and actual refusal/uncertainty/outcome. Preserve existing draft behavior and cancellation. Own the final integrated stage-1 acceptance over the eight underlying changes, not a second implementation of their mechanisms.
  
  **Inspected code and verification seams**
  
  [client/src/world.js:97](/home/yan/src/quod/client/src/world.js:97) · [ui/src/World.tsx:318](/home/yan/src/quod/ui/src/World.tsx:318) · [ui/src/World.tsx:367](/home/yan/src/quod/ui/src/World.tsx:367) · [ui/src/GuiForm.tsx:11](/home/yan/src/quod/ui/src/GuiForm.tsx:11) · [client/src/workspace-panel.js:23](/home/yan/src/quod/client/src/workspace-panel.js:23) · [client/src/signed-client.js:157](/home/yan/src/quod/client/src/signed-client.js:157) · [client/test/space-library.test.js:53](/home/yan/src/quod/client/test/space-library.test.js:53) · [test/quod_gui_examples_tests.erl:12](/home/yan/src/quod/test/quod_gui_examples_tests.erl:12)
  
  **Acceptance checks**
  
  - [ ] Use the normal UI through signed production seams: select storage, supply/omit name and dimensions, create through A, and show the exact created subject near A or unplaced as specified. No form helper or question is required.
  - [ ] Verify ordinary and spatial adapters use the same Prolog operation, exact subject and permission checks; a second non-space class/instance exercises the shared binding rather than a space-only branch.
  - [ ] Lose the first result in ordinary and atomic lanes, clear local journal state and recover the original reference from another authorized device, including after deletion with retained history. Never resubmit creation.
  - [ ] Exercise unavailable A, denied policy/placement, revocation, stale fields, conflicting writes, wrong anchors, cancellation and restart. Report uncertainty distinctly; preserve usable unsent drafts through existing behavior.
  - [ ] Collect underlying constructor/source/replay acceptance evidence, unchanged-repeat work counts, real-update view propagation, relevant sequential gates and actual production-line delta. Hardware headset acceptance remains separately labeled under QUD.25.
  
  **Replacement and documentation:** Replace the stage-1 discovery/opening/submission route in shared controllers and retire only branches whose callers and behavior are covered. Preserve console/source tools, terrain continuations, physical setup and stage-2 navigation until their replacements. No permanent old/new executor.
  
  **Existing-ticket boundary:** Keep full same-agent entry/recursive Eidolons in stage 2 and terrain/helper retirement in stage 3. No new architecture review or approval gate is added.
  
  Read [AGENTS.md](/home/yan/src/quod/AGENTS.md) and [multiwrite architecture](/home/yan/src/quod/doc/multiwrite-architecture.md). Keep domain state/policy in Prolog and reuse existing transaction, recovery and runtime owners. Verification is required during implementation, not claimed here. No deployment, commit, data deletion or agent spawning is authorized by ticket creation.



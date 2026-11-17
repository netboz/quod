# Tasks

Implementation tickets for the [space architecture plan](/home/yan/src/quod/nimbalyst-local/plans/space-conceptual-architecture-review.md). Stages 0–2 are complete for their agreed local software scope; Stage 3 remains unstarted. Stage-1 implementation and agreed local acceptance are complete; S1.1–S1.8 are committed; S1.9 is committed as `948b3c20`, and its ticket and fully verified stage-1 parent are completed. Dependency order is 1 → 2 → 3.

- Stage 1 — One empty space through the user's agent #task[id:tsk_01M5PY8TEX7NP119X8SXNN3HNB status:done priority:medium created:2026-10-24 tags:architecture,space]
  Plan: [Space and interaction architecture](/home/yan/src/quod/nimbalyst-local/plans/space-conceptual-architecture-review.md#smallest-staged-normalization). Implements stage 1 and confirmed decisions D1–D4/D8–D10; the plan remains authoritative. Read [AGENTS.md](/home/yan/src/quod/AGENTS.md) and [multiwrite architecture](/home/yan/src/quod/doc/multiwrite-architecture.md) before implementation.

  Status: completed, implemented, verified and committed (`948b3c20`); 100%. Every agreed stage-1 local acceptance obligation is complete. Yan authorized the commit and closure; the commit closing references marked this ticket done. S1.1–S1.8 are completed, verified and committed: `671e1f76`, `6db307c5`, `a4ea2d3a`, `ebf7248e`, `ff92986b`, `1f759530`, `bbc13893`, `faed7e01`. S1.9 [QUO-45](nimbalyst://QUO-45) has completed the normal UI integration, requested Claude Fable review and final corrected-tree gates. Parent work item for S1.1–S1.9; the verified completion dependency is S1.9 [QUO-45](nimbalyst://QUO-45) and its committed prerequisites. Stage 0 is complete. Blocks stage 2. [Execution map and checklist ownership](/home/yan/src/quod/nimbalyst-local/plans/space-conceptual-architecture-review.md#stage-1-implementation-tickets).

  **Outcome**

  An authenticated human U instructs their distinct personal agent A to create one empty ordinary space in an explicitly selected existing ontology. A signs the operation. Creation returns a system-generated anchored instance reference, remains recoverable after a lost reply and needs no form helper.

  **Implementation checklist**

  - [x] Connect the governed U→A attempt-now instruction, A's existing signing/hosting path and target authorization. Associate the original instruction with the exact A-signed operation and provide U's authorized outcome access. An unavailable A must not accept unsubmitted work for later restart; retain deadlines and distinguish refusal from an accepted operation whose reply is missing.
  - [x] Expose original selected result bindings through ordinary outcome lookup, matching the existing atomic-group behavior. Recover the generated reference using the original indexed transaction evidence, including from another authorized device. Keep results recoverable while the original history is retained; do not add a separate retention system or repeat uncertain creation.
  - [x] Implement generic assertion-triggered construction through the existing assertion hooks and proof/action savepoints. Reading `instance_of/2` remains a query. Creation via `assert/asserta/assertz` allocates and binds a full system-generated ULID and calls `constructor(Class, Instance, BuildPlan)`; callers do not choose IDs. Return `entity_ref(Namespace, GenesisAnchor, InstanceId)`; reject overwriting a live collision without a deleted-instance registry.
  - [x] Add scoped temporary `with_build_plan` inputs; resolve supplied values before most-specific and inherited defaults, validate and stage attributes before constructors. Automatically run ancestors before descendants once per creation attempt on one ID, using `constructor_order(Class, Parents)` for direct-parent order. Reject cycles, invalid order and unresolved inherited-default conflicts before constructor bodies run. Missing own constructors are allowed; they do not skip parents. Each required part describes its own contents and receives its own ID through the same creation path.
  - [x] Apply all compulsory inherited class checks and target ontology admission. Permit owners/authorized policy administrators to adjust default grants only within those checks. Missing/conflicting grants deny access. Menus and direct goals use the same authorization; a write cannot authorize itself through staged policy changes.
  - [x] Preserve complete rollback of construction, parts, bindings, events and effects, including caught failures and alternative proof branches. Ensure already-true membership cannot make `goal/1` skip required construction. Preserve surviving ground memberships during source replacement/reordering; loading, commit apply and recovery must not regenerate IDs/names or rerun constructors/reactions. Keep ontology founding integration outside this stage.
  - [x] Implement ordinary empty-space creation in the explicitly selected existing ontology, normally owned by U. Use finite dimensions of 100 × 100 × 100 metres centered at its origin by default; support `infinite` and positive unit-bearing `box(q(W,Unit),q(H,Unit),q(D,Unit))` through existing measurement rules. Exterior model size is separate; creation adds no terrain, walls, sky or physics.
  - [x] Generalize existing authorized placement for the ordinary-space case: show its defined 3D Eidolon near A when A is placed, otherwise allow unplaced creation when no destination was supplied. Preserve one containing space and multiple display references. Check explicit destination authority; denied placement must not silently fall back to unplaced creation.
  - [x] Adopt standard mutable, nonunique `name` separately from identity. Supplied names win; class policy supplies an appropriate ordinary default or supported naming-pool choice, stored once. Update affected `display_name` declarations/readers/writers together within the replacement scope.
  - [x] Add the minimum shared class-operation metadata and exact-subject GUI/Eidolon binding for creation, reusing existing labels, typed controls, defaults and result handling. A class-level Create affordance submits the construction assertion without an existing instance; it does not introduce a separate creation executor.
  - [x] Replace only the old route this stage fully covers and remove its unused support after checking callers and runtime reachability. Preserve still-valid test obligations, user-owned changes and data. Terrain continuations and helper duties replaced only by stage 3 remain until that replacement.

  **Acceptance checks**

  - [x] Through signed production seams, U instructs A and receives one empty space with the expected owner, selected storage, generated reference, name, dimensions and placement. Exercise explicit placement, near-A placement, unplaced A, missing own constructor, explicit finite dimensions and `infinite`.
  - [x] Exercise denied actors, unavailable A, changed permissions, stale revisions, missing/conflicting grants, compulsory checks from every parent, owner changes to default grants and direct-call/menu parity. Denial or constructor/part failure leaves no partial creation or placement, including when failure is caught.
  - [x] Verify construction on a non-space class too: parent/subclass share one ID; parts get separate IDs; shared ancestors run once per attempt; declared parent order holds; default conflicts, cycles and invalid order fail safely. Scoped overrides do not leak; constructor ordering does not change existing Eidolon selection or GUI defaults.
  - [x] Verify all assertion spellings, stable names/defaults, renaming without identity change, independent replacement IDs, live-ID collision protection, derived membership reads, surviving source reorders and replay/loading boundaries. Restoring committed state does not rerun construction or historical reactions.
  - [x] Lose the first creation reply in both ordinary and atomic transaction lanes. Recover the original reference and outcome from another authorized device, after clearing the browser journal and after deleting the instance while retaining history. No creation resubmission, duplicate identity allocation or unauthorized result disclosure occurs.
  - [x] Preserve atomic multi-ontology conflict/rollback, cancellation and revocation behavior through existing owners. Measure unchanged repeats for history reads, projection rebuilds and disk writes; a real update must still reach relevant views.
  - [x] Record the relevant existing test results, caller/reachability evidence, preserved obligations and production-line delta. Do not claim delivery before implementation and verification.

  **Boundaries**

  Keep domain state, policy, authorization and constructors in Prolog. Reuse `goal/1`, `action/3`, atomic transactions, recovery, reactions and runtime owners. No new executor, helper queue, generic final-state validator, tombstones or temporary U-signed creation route. Stage 2 owns same-agent entry and broader space views; stage 3 owns terrain separation and full helper retirement. JSON, outbound HTTP, ontology founding, live subclass specialization and ownership GUI remain later work. This ticket does not authorize deployment, commits or data deletion.

  Evidence reconciliation (S1.9): S1.1/S1.2 verify original signed outcomes, no resubmission, authorized cross-device recovery and revocation. S1.3 verifies compulsory checks, committed policy and conflicts. S1.4/S1.5 verify generic constructors, independent part IDs, all assertions, source preservation, replay and rollback. S1.6/S1.7 verify ordinary-space placement, explicit/near-A/unplaced creation and repeated-work/view propagation. S1.8 verifies the shared Prolog binding contract. Their retained verification reports are linked from the plan; current HEAD contains each delivery. Normal UI creation, generic binding, original-result recovery and all integrated failure cases pass browser-17 through the signed production route. Final sequential gates pass 346 EUnit tests, 244 client tests, production xref, TypeScript and the production bundle build. The requested Claude Fable review is complete and its confirmed corrections are verified. Six unchanged retained-view renewals do no history/rebuild/write/sync work; real changes reach both views. Authored production delta +546/−158 = net +388 lines; generated bundle separately net +1 minified line / +10,482 bytes. Covered discovery/opening support and the duplicate panel wrapper are removed; console/source/terrain/physics obligations remain covered. [Final evidence, frozen tree, retained failures and limits](/tmp/quod-s1.9-verification.md); [review and disposition](/home/yan/src/quod/nimbalyst-local/plans/space-s1.9-claude-review.md). Hardware headset is unrun, explicitly separate from local software-spatial acceptance. Yan confirmed that U-key revocation blocks new instructions but accepted A-signed work may finish under A's current key/target permissions. Uncertain originals are never resubmitted. S1.6's independently reproduced source-editor heap-limit failure remains recorded, not relabeled as passing. Stages 2–3 remain unstarted.

- Stage 2 — Same-agent entry and space Eidolons #task[id:tsk_01M5PY8TEXKG858WBZJ1RHC6EW status:done priority:medium created:2026-10-24 tags:architecture,space]
  Plan: [Space and interaction architecture](/home/yan/src/quod/nimbalyst-local/plans/space-conceptual-architecture-review.md#smallest-staged-normalization). Implements stage 2 under the confirmed model and existing code retention/retirement map.
  
  Status: implemented and verified for agreed local software scope; **4/4 local completion checks (100%)**, source-reconciled closeout 2026-11-04. Depends on stage 1; blocks stage 3. The inline item is visible through `tracker_get` with status `done`, but its synced custom progress still reads 50% and `tracker_update` cannot resolve its ID; no duplicate item was created. [Closeout and exact evidence](../../doc/evidence/stage2-closeout-20261104/STATUS.md).
  
  **Agreed scope**
  
  - Build same-agent entry on stage 1's generalized assignment/admission. Preserve A's identity and exclusive containing-space assignment; authorize movement before client navigation, using existing atomic transitions and both affected owners' policy.
  - Present a space through its exterior, contents and GUI Eidolons with exact subject binding and existing view owners. Keep direct-reference displays separate from exclusive location.
  - Resolve the already-recorded D5/D6 details before recursive contents and ontology predicate views. Reuse the existing predicate catalogue and guarded source editor; do not create another mutable copy of predicates.
  - Retire only the entry/discovery/view routes this replacement covers. Preserve physical preparation and pilots until applicable D7 choices and replacement obligations are covered.
  
  **Completion checks**
  
  - [x] Entry moves the same A, and navigation follows its committed location. Denied, stale or conflicting entries leave no partial move or duplicate containing-space assignment; permissions of both affected owners remain enforced.
  - [x] Exterior, GUI and contents views bind to the exact subject. Private contents, revocation, recursion cycles and reconnect work through the existing view/subscription owners; display references remain usable.
  - [x] D5/D6 details required for recursive and ontology views are recorded within their planned scope. Predicate edits use the existing guarded source editor and source permissions.
  - [x] Replacement behavior and valid test obligations cover each retired caller. Physical protections, useful editor/GUI behavior and user data survive; unchanged view reuse does not rebuild or replay history unnecessarily.
  
  Read [AGENTS.md](/home/yan/src/quod/AGENTS.md) and [multiwrite architecture](/home/yan/src/quod/doc/multiwrite-architecture.md) before implementation. Keep policy and authorization in Prolog and reuse existing actions, transactions, recovery and runtime owners. No speculative subtasks or additional architecture gates are introduced by this ticket. The accepted implementation is local software only; no deployment, data deletion, hardware test or user-store migration is implied.

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

- S1.4 — Define generic constructor inputs, inheritance, defaults and names #task[id:tsk_01M5Q1YXC2V8G59WR1KA7E8NND status:done priority:medium created:2026-10-24 tags:architecture,space,stage-1]
  Parent work item: [tsk_01M5PY8TEX7NP119X8SXNN3HNB](nimbalyst://tsk_01M5PY8TEX7NP119X8SXNN3HNB). Plan: [Space and interaction architecture](/home/yan/src/quod/nimbalyst-local/plans/space-conceptual-architecture-review.md#stage-1-implementation-tickets). Status: completed, implemented and verified with optional review corrections; committed with this change. Session: `fa91ccf2-fe5c-4dbc-bdcd-d584e368ae46`.
  
  Dependencies: none; delivered within the agreed stage-1 scope. These are implementation dependencies, not additional design approvals.
  
  **Scope and ownership**
  
  Implement Prolog-owned construction rules over existing isa/2 and attribute metadata: constructor(Class, Instance, BuildPlan), scoped with_build_plan inputs, once-resolved validated initial attributes, and constructor_order/2. Schedule ancestors before descendants with shared ancestors once per attempt; supplied values outrank most-specific then inherited defaults. Distinguish missing own code from declared code that fails. Standardize mutable nonunique name and class-appropriate ordinary/naming-pool defaults. Each class describes its required parts and explicitly passes supported overrides; parts get their own construction scopes. S1.5 owns live assertion integration and proof rollback.
  
  **Inspected code and verification seams**
  
  [priv/ontologies/common_predicates.pl:138](/home/yan/src/quod/priv/ontologies/common_predicates.pl:138) · [priv/ontologies/animals.pl:24](/home/yan/src/quod/priv/ontologies/animals.pl:24) · [priv/ontologies/quod_gui.pl:201](/home/yan/src/quod/priv/ontologies/quod_gui.pl:201) · [priv/ontologies/quod_names.pl:103](/home/yan/src/quod/priv/ontologies/quod_names.pl:103) · [test/quod_class_semantics_tests.erl:45](/home/yan/src/quod/test/quod_class_semantics_tests.erl:45) · [test/quod_gui_components_tests.erl:1](/home/yan/src/quod/test/quod_gui_components_tests.erl:1)
  
  **Acceptance checks**
  
  - [x] A diamond runs its shared ancestor once in the declared parent order; missing, duplicate, extra or contradictory parent-order entries and constructor cycles fail before bodies run.
  - [x] Unrelated conflicting defaults require caller/subclass resolution. Invalid supplied values fail instead of falling back; changing a class default does not rewrite existing instances.
  - [x] Absent own constructor still runs parents; failing own/parent/part code is not swallowed. Verify on non-space classes as well as the space consumer.
  - [x] Names can duplicate and change without changing identity; class-selected naming pools are used only for supported kinds. Nested part inputs do not inherit unrelated outer overrides.
  
  **Delivery and verification:** Final sequential gates passed: **704 EUnit tests**, including **45 constructor tests**, and **production xref**; `git diff --check` passed. Covers standalone/non-space classes, diamonds/order/cycles, conflicts, failures, nested inputs, real naming rules and signed-owner persistence. Three unchanged owner reads perform no history reads, projection builds, writes or syncs; real updates remain visible. GUI type validation now reuses metadata; superseded validators are removed. The world-library recovery test now awaits all restarted physics activations and their publication before its unchanged no-I/O assertion. Production delta: **+291/−40, net +251 lines** (+11 net for optional review corrections). [Current verification, frozen tree, retained failed runs and scope limitations](/tmp/quod-s1.4-optional-verification.md). Live assertion/IDs/rollback remain S1.5, production empty-space defaults remain S1.7, and terrain name migration remains stage 3.

  **Requested Claude review:** Claude Fable found no blocking findings. Yan subsequently requested the optional findings be addressed. Prolog preflight now rejects unknown part roles via class-owned `have_part/2` declarations and reports malformed inputs, unknown attributes, missing keys and failed defaults. Scope return carries only a reference and shares boundary lookup with read-only checks. Added tests cover inherited/nested part roles, retained reasons, absent declarations, required/default conflicts, universal name reflection, validator limitations, interleaved scopes and real cross-ontology naming. The type/reflection contracts are explicit; S1.5 rollback coverage remains out of scope. All final checks passed; no additional review was run. [Review and parent disposition](/home/yan/src/quod/nimbalyst-local/plans/space-s1.4-claude-review.md).

  **Tracker sync:** Metadata and local body snapshot saved; collaborative body storage failed twice. This local ticket is the complete delivery record.

  **Replacement and documentation:** Reuse/refactor existing default/type selection rather than inventing a parallel slot schema. Preserve current GUI default and Eidolon selection behavior. Migrate name readers/writers together only in the replaced scope; terrain-specific display_name migration remains with stage 3.
  
  **Existing-ticket boundary:** Existing class/GUI primitives are foundations, not an already-installed constructor. Do not reopen live subclass specialization or composed-part deletion.
  
  Read [AGENTS.md](/home/yan/src/quod/AGENTS.md) and [multiwrite architecture](/home/yan/src/quod/doc/multiwrite-architecture.md). Keep domain state/policy in Prolog and reuse existing transaction, recovery and runtime owners. Implementation verification is recorded above; combined stage-1 acceptance remains S1.9. No deployment, commit, data deletion or agent spawning is authorized by ticket creation.

- S1.5 — Integrate assertion construction with ULIDs, rollback and source recovery #task[id:tsk_01M5Q1YXC2AWGSJT9CJ86R13W8 status:done priority:medium created:2026-10-24 tags:architecture,space,stage-1]
  Parent work item: [tsk_01M5PY8TEX7NP119X8SXNN3HNB](nimbalyst://tsk_01M5PY8TEX7NP119X8SXNN3HNB). Plan: [Space and interaction architecture](/home/yan/src/quod/nimbalyst-local/plans/space-conceptual-architecture-review.md#stage-1-implementation-tickets). Status: completed, implemented and verified, committed with this change. Session: `6fbe3af3-4223-4cc3-be17-38de27535f88`.
  
  Dependencies: S1.3 [tsk_01M5Q1YXC2JDBWR3AKXAB7RPQN](nimbalyst://tsk_01M5Q1YXC2JDBWR3AKXAB7RPQN); S1.4 [tsk_01M5Q1YXC2V8G59WR1KA7E8NND](nimbalyst://tsk_01M5Q1YXC2V8G59WR1KA7E8NND). These are implementation dependencies, not additional design approvals.
  
  **Scope and ownership**
  
  Wire all three assertion spellings into the existing Erlog hook, writable proof overlay and action/savepoint machinery. Allocate and bind a full secure-random ULID before constructor dispatch, preserving it in sealed material and selected results. Run S1.3 committed-policy checks and S1.4 construction inside the original proof. Own the whole lifecycle distinction: live creation, existing/derived membership, guarded source replacement, loading/founding compilation, commit apply and recovery. Keep these together so installing the hook cannot accidentally execute constructors while loading source.
  
  **Inspected code and verification seams**
  
  [_build/default/lib/erlog/src/erlog_int.erl:477](/home/yan/src/quod/_build/default/lib/erlog/src/erlog_int.erl:477) · [src/quod_erlog_db_local_prove.erl:135](/home/yan/src/quod/src/quod_erlog_db_local_prove.erl:135) · [src/quod_proof_savepoint.erl:44](/home/yan/src/quod/src/quod_proof_savepoint.erl:44) · [src/predicates/quod_action_predicates.erl:45](/home/yan/src/quod/src/predicates/quod_action_predicates.erl:45) · [priv/ontologies/quod_prolog.pl:215](/home/yan/src/quod/priv/ontologies/quod_prolog.pl:215) · [src/quod_committed_projection.erl:613](/home/yan/src/quod/src/quod_committed_projection.erl:613) · [src/quod_diff.erl:284](/home/yan/src/quod/src/quod_diff.erl:284) · [test/quod_action_savepoint_tests.erl:1](/home/yan/src/quod/test/quod_action_savepoint_tests.erl:1) · [test/quod_prolog_ontology_tests.erl:114](/home/yan/src/quod/test/quod_prolog_ontology_tests.erl:114)
  
  **Acceptance checks**
  
  - [x] assert/asserta/assertz with the creation output variable bind one generated ID; query/derived membership and membership rules allocate nothing. Normal creation rejects caller-selected new IDs; live collisions never overwrite an instance.
  - [x] Parent and subclass constructors share one ID; each new part gets another. Concurrent creations use distinct generated IDs without a per-ontology counter or deleted-instance catalogue.
  - [x] Caught failure, exception, backtracking or failed required part restores membership, attributes, part state, events, effects and bindings through existing savepoints. Already-true membership cannot skip construction through goal/1's shortcut.
  - [x] Surviving ground memberships remain stable across source reorder/replacement; source round-trip checks remain meaningful. Additional classification is not implicit live specialization.
  - [x] Loading, founding compilation, apply, restart and projection rebuild restore decided facts without running constructors, drawing names or regenerating IDs. Validators consume sealed generation results rather than independently drawing them; strict read-only assertions still fail.
  
  **Replacement and documentation:** Use one assertion/lifecycle path and existing owners; remove replaced registration/dispatch duplication within this scope. Update affected source/action/recovery documentation and retain current savepoint/transaction tests. No new executor, reaction-based constructor or automatic final-state validator.
  
  **Existing-ticket boundary:** Ontology founding integration remains outside stage 1; this item prevents accidental constructor execution during existing founding/source loads rather than making ontology creation an ordinary constructor.
  
  Read [AGENTS.md](/home/yan/src/quod/AGENTS.md) and [multiwrite architecture](/home/yan/src/quod/doc/multiwrite-architecture.md). Keep domain state/policy in Prolog and reuse existing transaction, recovery and runtime owners. Verification is required during implementation, not claimed here. No deployment, commit, data deletion or agent spawning is authorized by ticket creation.

  **Delivery:** The writable overlay's existing assertion hook runs the S1.3 committed guard, a full secure ULID allocation, S1.4 planning and constructor bodies in the original proof/savepoint. Parent constructors share the ID; part assertions allocate independently. All material and bindings roll back on construction failure/exception and failed alternatives. Successful construction releases its savepoint like an action; enclosing actions/transactions retain responsibility for later caller failure. Explicit source clauses and additional classification create nothing. The existing source editor, direct founding compiler and materializer preserve decided identities and names without regeneration.

  **Verification:** Final sequential gates passed **907 EUnit tests** across 26 modules (94 + 813), **production xref** and `git diff --check`. All 28 source/test/contract files match the frozen passing post-review tree. Signed ordinary, foreign-only and atomic tests trace exactly one allocation/name draw during creation and zero generation during restart/rebuild; original references survive instance deletion. Unchanged outcome reads cause no rebuild, write or sync; real updates remain visible. The original founding hash/size golden values pass unchanged. [Full verification, retained failures and frozen tree](/tmp/quod-s1.5-verification.md).

  **Cleanup and scope:** Principal registration is owned once by the common runtime vocabulary. Existing terrain actions retain stored memberships as explicit clauses for their governed identities; terrain construction/naming stays stage 3. Test source seeding reuses one explicit-clause helper and production compilation, retiring repeated fixture paths and the S1.3 construction probe. Production delta **+96/−36, net +60 lines** supplies the new shared hook/allocation composition without a second executor. Ontology founding integration, live specialization and S1.6–S1.9 remain outside this ticket. Committed with this change; no deployment or user-data deletion.

  **Requested review:** Yan explicitly authorized Claude review in this session; the review is complete. Confirmed founding/terrain corrections and dead-handler cleanup are verified. Added coverage pins transaction-internal rollback, asserta order, derived-only classification and founded/live clause equivalence. Optional diagnostic and overlay-query suggestions retain existing conventions; non-co-hosted CT remains unrun. [Review and parent disposition](/home/yan/src/quod/nimbalyst-local/plans/space-s1.5-claude-review.md). Stage 1 and the plan remain incomplete.

- S1.6 — Generalize exclusive placement to ordinary nonphysical spaces #task[id:tsk_01M5Q1YXC2AQK9YP4GRXM4FYBV status:done priority:medium created:2026-10-24 tags:architecture,space,stage-1]
  Parent work item: [tsk_01M5PY8TEX7NP119X8SXNN3HNB](nimbalyst://tsk_01M5PY8TEX7NP119X8SXNN3HNB). Plan: [Space and interaction architecture](/home/yan/src/quod/nimbalyst-local/plans/space-conceptual-architecture-review.md#stage-1-implementation-tickets). Status: completed, implemented and verified; requested Claude Fable review and corrections complete. Committed as `1f759530`. The unrelated baseline source-editor failure is documented below. Session: `2a83b30e-d5ad-4650-8831-95725a4615f9`.
  
  Dependencies: S1.3 [tsk_01M5Q1YXC2JDBWR3AKXAB7RPQN](nimbalyst://tsk_01M5Q1YXC2JDBWR3AKXAB7RPQN). These are implementation dependencies, not additional design approvals.
  
  **Scope and ownership**
  
  Adapt the existing instance-owned assignment and destination-owned admission transition for ordinary spaces, retaining one containing space, revisions and atomic consent of both owners. Separate location from the existing many-to-many display references. Carry the existing transform/depiction vocabulary through nonphysical placement without requesting physics or copying instance state. S1.7 selects explicit versus near-A versus unplaced creation; same-agent enter and recursive views remain stage 2.
  
  **Inspected code and verification seams**
  
  [priv/ontologies/space.pl:56](/home/yan/src/quod/priv/ontologies/space.pl:56) · [priv/ontologies/space_view.pl:3](/home/yan/src/quod/priv/ontologies/space_view.pl:3) · [priv/ontologies/quod_modelling.pl:151](/home/yan/src/quod/priv/ontologies/quod_modelling.pl:151) · [priv/ontologies/quod_rendering.pl:34](/home/yan/src/quod/priv/ontologies/quod_rendering.pl:34) · [test/quod_space_tests.erl:91](/home/yan/src/quod/test/quod_space_tests.erl:91)
  
  **Acceptance checks**
  
  - [x] Place an existing nonphysical instance into an ordinary space through both owners' authorized atomic transition, including different ontologies; refusal or conflict leaves no half-assignment.
  - [x] Competing destinations cannot create two containing spaces; withdrawal retains the existing revision protection. Preserve current physical consequence checks when a physical transition is used.
  - [x] Two display references can depict one instance without creating two locations or changing storage/ownership. Removing a display reference does not delete the instance.
  - [x] Ordinary placement supplies a usable local transform/depiction without physics allocation. Repeated unchanged projection does not copy state, replay history or rebuild retained resources.
  
  **Replacement and documentation:** Generalize the designated assignment owner and its projection instead of adding a second ordinary-space registry. Remove physical-only assumptions only where replacement behavior is covered; retain physics setup and meaningful display membership.
  
  **Existing-ticket boundary:** Reuse the completed [QUD.33](nimbalyst://QUD.33) foundation. Do not reopen it or absorb [QUD.3](nimbalyst://QUD.3)/[QUD.26](nimbalyst://QUD.26) physical simulation and hardware work.
  
  Read [AGENTS.md](/home/yan/src/quod/AGENTS.md) and [multiwrite architecture](/home/yan/src/quod/doc/multiwrite-architecture.md). Keep domain state/policy in Prolog and reuse existing transaction, recovery and runtime owners. Implementation and verification evidence is recorded below. No deployment, commit, data deletion or agent spawning is authorized by ticket creation.

  **Delivery:** Ordinary and physical placement share the existing instance-owned assignment, destination admission and atomic transaction. The four space operations call S1.3's unchanged committed authorization guard. Display references remain independent of assignment, storage and ownership. Existing Eidolons/transforms depict ordinary placement without physics resources; physical consequences and exact live body-pose checks remain required. Obsolete physical-only assignment naming and separate permission callbacks are removed.

  **Verification:** The final corrected-tree run completed **647 EUnit tests across 22 modules: 646 passed, one unrelated source-editor heap-limit failure**. That HTTPS failure is independently reproduced on the starting revision and occurs before its no-I/O check; no assertion, budget or deadline was weakened. All S1.6 acceptance checks pass, and **production xref passed without warnings**. Signed checks cover both owners, distinct principals, same/foreign ontology placement, refusal, policy conflicts, competing destinations, revisions and recovery. Real retained views perform six unchanged renewals without history replay, projection rebuilding, writes/syncs or physics allocation; real source updates refresh both displays. Reclassification tests require physical cleanup, retain rollback on refusal, and verify later readmission. Outdated physics fixture assertions use S1.5's existing source-clause helper. [Full evidence, baseline reproduction and retained failures](/tmp/quod-s1.6-verification.md).

  **Scope and review:** Production delta **+68/−58, net +10 lines**, all in existing Prolog files; no new owner, registry, executor or Erlang production code. Claude Fable's confirmed physical cleanup finding is corrected and tested; all seven additional shared-helper caller modules were exercised with the baseline failure retained. [Review and parent disposition](/home/yan/src/quod/nimbalyst-local/plans/space-s1.6-claude-review.md). S1.7 still owns creation-time class consent and explicit/near-agent/unplaced pose selection; later stages own entry and recursive views. Existing founded-source adoption is not performed. S1.7 and later tickets remain unstarted; the stage and plan remain incomplete. Yan authorized commit and completion; implementation commit `1f759530`. No deployment, migration or user-data deletion.

- S1.7 — Create one empty space with explicit storage and optional placement: [QUO-43](nimbalyst://QUO-43). Status: completed and committed with this change. Scope, acceptance checks, verification and dependencies are in the full tracker item.

- S1.8 — Describe and bind class operations through the shared Prolog GUI model: [QUO-44](nimbalyst://QUO-44). Status: completed and committed with this change; 342 tests and production xref pass, requested review findings addressed. Scope, acceptance checks and dependencies remain in the existing tracker item (original ID `tsk_01M5Q1YXC2YVTBAC8RRBK73RXY`).

- S1.9 — Deliver the bound Create-space interface and verify the complete stage-1 flow #task[id:tsk_01M5Q1YXC21Z70NX4DJXSZHD1X status:done priority:medium created:2026-10-24 tags:architecture,space,stage-1]
  Parent work item: [QUO-46](nimbalyst://QUO-46). Plan: [Space and interaction architecture](/home/yan/src/quod/nimbalyst-local/plans/space-conceptual-architecture-review.md#stage-1-implementation-tickets). Status: completed, implemented, verified and committed (`948b3c20`); 100%. Every agreed stage-1 local acceptance obligation is complete. Yan authorized the commit and closure; the commit closing references marked this ticket done. Requested Claude Fable review and final corrected-tree verification are complete. All earlier failures are retained. Overall plan remains incomplete; stages 2–3 are unstarted.

  Dependencies: S1.7 [QUO-43](nimbalyst://QUO-43); S1.8 [tsk_01M5Q1YXC2YVTBAC8RRBK73RXY](nimbalyst://tsk_01M5Q1YXC2YVTBAC8RRBK73RXY). These are implementation dependencies, not additional design approvals.

  **Scope and ownership**

  Connect class-operation discovery and exact-subject GUI/Eidolon opening to the existing ordinary/spatial panel controllers and S1.2 personal-agent submission. Present the explicit target-ontology selection and class Create form; display the committed reference and actual refusal/uncertainty/outcome. Preserve existing draft behavior and cancellation. Own the final integrated stage-1 acceptance over the eight underlying changes, not a second implementation of their mechanisms.

  **Inspected code and verification seams**

  [client/src/world.js:97](/home/yan/src/quod/client/src/world.js:97) · [ui/src/World.tsx:318](/home/yan/src/quod/ui/src/World.tsx:318) · [ui/src/World.tsx:367](/home/yan/src/quod/ui/src/World.tsx:367) · [ui/src/GuiForm.tsx:11](/home/yan/src/quod/ui/src/GuiForm.tsx:11) · [client/src/workspace-panel.js:23](/home/yan/src/quod/client/src/workspace-panel.js:23) · [client/src/signed-client.js:157](/home/yan/src/quod/client/src/signed-client.js:157) · [client/test/space-library.test.js:53](/home/yan/src/quod/client/test/space-library.test.js:53) · [test/quod_gui_examples_tests.erl:12](/home/yan/src/quod/test/quod_gui_examples_tests.erl:12)

  **Acceptance checks**

  - [x] Use the normal UI through signed production seams: select storage, supply/omit name and dimensions, create through A, and show the exact created subject near A or unplaced as specified. No form helper or question is required.
  - [x] Verify ordinary and spatial adapters use the same Prolog operation, exact subject and permission checks; a second non-space class/instance exercises the shared binding rather than a space-only branch.
  - [x] Lose the first result in ordinary and atomic lanes, clear local journal state and recover the original reference from another authorized device, including after deletion with retained history. Never resubmit creation.
  - [x] Exercise unavailable A, denied policy/placement, revocation, stale fields, conflicting writes, wrong anchors, cancellation and restart. Report uncertainty distinctly; preserve usable unsent drafts through existing behavior.
  - [x] Collect underlying constructor/source/replay acceptance evidence, unchanged-repeat work counts, real-update view propagation, relevant sequential gates and actual production-line delta. Hardware headset acceptance remains separately labeled under QUD.25.

  **Replacement and documentation:** Replace the stage-1 discovery/opening/submission route in shared controllers and retire only branches whose callers and behavior are covered. Preserve console/source tools, terrain continuations, physical setup and stage-2 navigation until their replacements. No permanent old/new executor.

  **Existing-ticket boundary:** Keep full same-agent entry/recursive Eidolons in stage 2 and terrain/helper retirement in stage 3. No new architecture review or approval gate is added.

  Read [AGENTS.md](/home/yan/src/quod/AGENTS.md) and [multiwrite architecture](/home/yan/src/quod/doc/multiwrite-architecture.md). Keep domain state/policy in Prolog and reuse existing transaction, recovery and runtime owners. Verification is recorded below. Yan subsequently requested one Claude review; that read-only Fable review is complete. No deployment or user-data deletion was performed. Yan authorized the implementation commit, completed as `948b3c20`.

  Delivery evidence: [S1.9 verification](/tmp/quod-s1.9-verification.md). Final corrected-tree gates pass: 346 EUnit tests, 244 client tests, production xref, browser-17 complete normal World UI/signed TLS acceptance, TypeScript and the production bundle build. Browser acceptance covers ordinary/atomic lost replies, journal clearing, another authorized device, deletion with retained history, restart, default/supplied/infinite forms, explicit/near-A/unplaced results, real spatial keyboard input, unavailable A, denied policy/placement, revocation, schema changes, OCC conflict, cancellation and generic note creation/instance rename. Exactly 12 deliberate UI submissions; zero recovery resubmissions. The fixture verifies 11 retained associations including signed placement setup; unavailable/pre-custody refused instructions retain none. Four new signed EUnit integrations include six zero-work view renewals and real updates reaching both views; prior S1.1–S1.8 reports reconcile constructor/source/replay obligations. Obsolete discovery/opening branches and duplicate panel wrapper removed after caller/test review; console/source/terrain/physics preserved. Authored production +546/−158 = net +388 lines across19 files; generated bundle separately net +1 minified line / +10,482 bytes. Hardware-headset acceptance is unrun, separately retained under the existing GUI ticket. Fresh-consumer history enumeration and unresolved-outcome limits remain documented; no uncertain creation is resubmitted.

  Confirmed by Yan (2026-10-25): disabling the human sign-in key blocks new instructions; work already accepted and signed by the distinct personal agent may finish under that agent’s current key and target permissions. Browser-16’s failed stronger-cancellation expectation is retained; the acceptance now checks the explicitly chosen boundary. [Review and disposition](/home/yan/src/quod/nimbalyst-local/plans/space-s1.9-claude-review.md).


# S1.7 empty space Claude Fable review

Yan requested this consultative, read-only review of [QUO-43](nimbalyst://QUO-43).
Claude Fable session: `9eaa4c2e-2e99-4a14-9fe3-615a0dd6aca0`.
The review is complete. The parent checked its findings against the code and
validation evidence; the disposition below governs the final implementation.

## Parent disposition

1. **Stale documentation: confirmed and corrected.** The physical-placement
   section still described constructor consent and near-agent selection as future
   S1.7 work. It now points to Empty creation and distinguishes committed class
   policy during construction from committed instance policy afterward.
2. **Initial regression failures: corrected and verified.** The signed authoring
   fixture now passes source through the existing parser with clause-local scratch
   bindings, in one atomic transaction with exact baseline checks. The shared-recipe
   test checks preservation of its actual local baseline. All 349 tests and
   production xref passed on that corrected tree; earlier failures are retained.
3. **Physical lobby and actor pose: confirmed later integration limits.**
   The existing lobby requires its own admission and physical body definition;
   an empty constructor supplies neither and does not bypass those checks.
   The production entry flow does not yet write A's ordinary transform. A and the
   existing physical pilot are distinct identities; viewing a lobby is not proof
   that A is placed there. Signed ordinary placement is exercised now, while
   same-agent entry and physical embodiment remain in the already agreed later scope.
4. **Owner delegation for grant edits: confirmed outside S1.7.** The existing
   reserved grant-edit operation compares the actor with the stored owner or a
   committed administrator. U ownership does not make A that owner. S1.8/S1.9
   integration must retain the agreed authorized-agent ownership semantics;
   this ticket does not broaden grant-edit authority.
5. **Explicit-owner policy coverage: added.** A signed test checks refusal of a
   valid but unauthorized owner, refusal of a permission staged by the same
   operation, success under the committed authored policy, and malformed-owner
   rejection. Final verification passed all 350 tests and production xref, as recorded below.
6. **Optional changes not adopted.** Missing/ambiguous ordinary pose already
   refuses construction without a fallback; a separate reason term is not needed
   for this scope. Rendering offsets and rotations have their own limits, while
   domain placement currently accepts integer transforms; projection still requires
   a renderer-compatible pose. Those presentation limits are not imposed as
   space-extent limits. The ground subject-shape disjunction has only one matching
   branch; its failing alternative does not weaken authorization or add a second
   result. No extra cut or alternate authorization path was introduced.

The shared construction-scope extension received no confirmed defect finding.
The parent independently checked its committed-policy boundary, hook-only context,
original inputs, exact identity matching and restoration against the code and tests.

## Reviewer boundary correction

Despite the read-only instruction, the reviewer updated its stage-1 memory note
and the corresponding memory index line. The parent stopped further edits and
restored both from captured pre-edit content, with hash guards and a read-back
check. The restoration preserves the other index entries; the implementation
tree was untouched. Restoration evidence is retained in
[/tmp/quod-s1.7-memory-restoration.json](/tmp/quod-s1.7-memory-restoration.json).
The reviewer used shell commands for inspection and ran no builds or tests.
Its own stop notification failed; the parent reports its notification result
separately at delivery.

## Review scope and evidence

The review covers empty-space defaults and construction, exact dimensions,
human ownership under personal-agent signing, atomic placement, committed class
authorization during construction, result recovery and the existing runtime owners.
S1.8/S1.9 operations and GUI, later entry/recursive views and terrain replacement
remain outside this change.

The original reviewed implementation is frozen in the
[regression 01 manifest](/tmp/quod-s1.7-regression-01-tree.json).
The parent corrected three lobby-test fixture failures without changing that
production implementation. The
[corrected tree manifest](/tmp/quod-s1.7-regression-02-tree.json) records all
17 implementation, test and documentation files used by the pre-review gate.

The final reviewed tree is frozen in the
[regression 03 manifest](/tmp/quod-s1.7-regression-03-tree.json), including the
documentation correction and explicit-owner policy test. Its 17 implementation
files remained unchanged through validation.

The parent ran **350 EUnit tests with zero failures**, followed sequentially by
**production xref**, which passed without warnings. These are parent-run results;
the reviewer is not authorized to execute tests or edit files. The
[verification report](/tmp/quod-s1.7-verification.md) retains every failed run,
the corrections, full-log references and the limits of the checks.

Production delta: **+135/−24, net +111 lines**, across five existing files.
Yan subsequently authorized S1.7 commit and completion. S1.7 is completed and
committed with this change; the stage and plan remain incomplete. No deployment
or user-data deletion is included.

## Original reviewer report

The report below is preserved as received. Its frozen-tree findings and historical
memory-write disclosure are resolved or bounded by the parent disposition above.

Review of S1.7 (QUO-43), read-only, against the frozen tree `/tmp/quod-s1.7-regression-01-tree/` (16 files, all SHA-256 recomputed and matching; the production files were byte-identical to the working tree when I read them). The parent's later messages are incorporated: the two lobby `invalid_term` failures were the signed-goal token bound on the test's whole-file goal, the third was a stale fixture assumption, and regression-02 passed 349/0 with production unchanged. I ran no tests; all gate results are the parent's.

**Boundary disclosure first.** Before message 4 arrived I edited two files in my own Claude memory directory, nothing in the repo or /tmp:
- `/home/yan/.claude/projects/-home-yan-src-quod/memory/quod-space-stage1-arc.md` was overwritten with an S1.7 summary (previous content covered S1.1/S1.2 only; I can restore it on request, I have the prior text).
- `/home/yan/.claude/projects/-home-yan-src-quod/memory/MEMORY.md`: the one index line for that note was replaced.
No repo, doc, tracker, plan or /tmp file was touched. The AGENTS stop notifier failed (`notify-send` symbol lookup error, exit 127); no notification was delivered.

## Findings, highest priority first

**1. Stale documentation contradicting the delivered behaviour. Confirmed defect, low severity, fix in scope.**
Frozen [doc/spaces.md:271-274](/tmp/quod-s1.7-regression-01-tree/doc/spaces.md:271) still says "Placement here requires an existing committed instance. Creation-time consent must use committed class policy, and near-agent placement must choose a pose owner; those are S1.7 integration work." The new "Empty creation" section and doc/proofs.md say the opposite. Rewrite or delete that paragraph in the same scope.

**2. The three regression failures were test-side, as the parent concluded. Verification gap, now closed by the parent.**
My static accounting agreed with the token-bound diagnosis: the whole-file goal in `quod_lobby_tests.erl:81-99` is the only route that submits a complete source file in one signed goal; production composition goes through the per-predicate editor goal. The third failure follows from the lobby fixture composing space_view.pl (`quod_lobby_tests.erl:1537-1538`), which now carries `eidolon/3` ([space_view.pl:9-11](/tmp/quod-s1.7-regression-01-tree/priv/ontologies/space_view.pl:9)). No production change was needed, consistent with the corrected gate.

**3. The realistic production destination is untested and currently unreachable. Verification gap plus later-scope limitation, flag for Yan.**
Every creation test places into ordinary fixture rooms. The only existing production destination is the lobby, which is physical: `lobby_instance.pl:71` routes `space_physical_change` to `physics_space_change(W, Subject, admitted)` (`quod_physics.pl:108-121`), which requires a `physics_admission` and a delegated body definition for the subject, and the lobby's committed `space_admit` grant (`lobby_instance.pl:60-63`) requires `lobby_admission(W, Entity, _, _)`. A freshly constructed empty space has neither, so "create a space near me in my lobby" would be refused through [space.pl:197-198](/tmp/quod-s1.7-regression-01-tree/priv/ontologies/space.pl:197). This matches the documented "physical destinations retain their mandatory hook", so it is not an S1.7 defect, but S1.9's complete flow depends on it. Decide where it lands (stage 2 entry or S1.9) rather than discovering it there.

**4. Owner-gated operations break for U-owner plus A-actor. Later-scope limitation, first concrete appearance here.**
Spaces store U as owner ([space.pl:10](/tmp/quod-s1.7-regression-01-tree/priv/ontologies/space.pl:10), proved via `personal_agent_owner/1`), but the S1.3 grant-edit rule compares the stored owner with the acting principal (`common_predicates.pl:122-125`). A acting for U is never the owner, so A cannot change the space's grants. D8's "owner acting through an authorized agent" needs a delegation rule in S1.8/S1.9.

**5. Bare refusal when a placed agent has no pose. Low, optional.**
[space.pl:51-52](/tmp/quod-s1.7-regression-01-tree/priv/ontologies/space.pl:51) fails plainly when a placed A lacks exactly one `transform` attribute, unlike `ambiguous_space_assignment`, which carries a reason. Suggest `fail_with_reason(agent_pose_unavailable(Entity))`, following the S1.5 F4 precedent. Related limitation: nothing in production writes A's transform yet (only space.pl reads or writes transforms), so near-A placement becomes reachable only with stage 2 entry.

**6. Small cleanups, optional.**
- `space_transform/1` ([space.pl:33-34](/tmp/quod-s1.7-regression-01-tree/priv/ontologies/space.pl:33)) duplicates the shape of `placed(transform(...))` in `quod_rendering.pl:231-233` without its offset and turn bounds, so an out-of-range explicit placement is stored and fails only later at `well_formed_scene`. Different owner, so acceptable; bounding it would be cheap.
- `operation_authorized/2` at [common_predicates.pl:83](/tmp/quod-s1.7-regression-01-tree/priv/ontologies/common_predicates.pl:83) leaves a choicepoint on the subject-shape disjunction; `once/1` avoids spurious re-entry.
- The explicit `owner` input path has no test, and the fixture's `creation_permission` ignores inputs, so nothing pins that an authored policy can refuse a foreign owner.
- Fixture admission is a blanket `can_invoke(_, A, _, _) :- storage_open` (`quod_space_creation_tests.erl:141-142`); invocation policy is exercised only as a toggle. Acceptable, just stated.

## The construction-scope extension: no defect found

I checked the points you listed against the frozen code.
- **Forgery.** The context lives in proof bindings under a non-variable key (`quod_common_primitives.erl:83, 226-233`). Only `assert_instance` pushes an entry, and only for an unbound instance (lines 136-146); `with_build_plan_2` preserves the existing entries and cannot add one (183-188); `operation_authorized/2` rejects a caller-supplied `construction(...)` subject. Matching is by exact ground deref'd ID (152-157), so a committed instance or sibling part can never borrow another construction's subject. The generic test covers forgery through the public wrapper (`quod_assertion_construction_tests.erl:135-167`).
- **Committed evaluation.** The check runs on the committed base (`quod_ask.erl:1873-1884`); `operation_classes(construction(...))` requires absence of the identity there and expands the original class's parents (common_predicates.pl:101-102); `operation_override(construction(...), _, [])` excludes staged instance grants; the reserved `set_permission` branch still demands `instance(_)`.
- **Inputs.** Captured at hook time with the original build plan, even though `'$quod_run_constructors'` resets the input scope to `[]` (`construction.pl:170-171`), so callbacks see original inputs, not staged attributes. Nested parts push their own entry and keep the enclosing ones.
- **Restoration, cut, backtracking, errors.** Return restores the previous context and pushes a redo choicepoint that re-enters with the active context (erl:203-214); failure restores the boundary bindings (216-217); erlog errors restore before propagating (219-224); the savepoint rollback restores entry bindings (`quod_proof_savepoint.erl:118-126`).
- **Staged membership.** Membership is staged before constructors (construction.pl:14-16), so `space_place/3`'s live `instance_of` check passes while the committed check uses the class subject. This is exactly the S1.6 review finding 3 resolution.
- **Alias, foreign, principal.** `::` scopes run in their own states, so a destination's `space_admit` check sees no context and classifies the destination normally; same-ontology destinations still match by ID only. The two personal self-queries are admitted only when the principal's namespace and anchor equal the target's (`personal_agent.pl:13-15`), so another user's personal agent cannot probe. Design note: the call chain is ignored, so any ontology in which A executes a goal can learn U's identity and A's location. That is inherent to computing near-A placement inside the target's constructor; the chain argument is the place to narrow it if Yan wants.

Signed-route check: `create/3` in the new test builds A's execute request, has U sign the acceptance read, submits through `quod_client_goal_ingress:instruction`, then recovers the outcome from a fresh session and after owner restart and instance deletion, with zero generation during replay. That is the real production route. Scope compliance: all policy is Prolog, the Erlang change is a context carrier, no `create_space` executor, no landscape call, terrain route untouched, the retired S1.4 synthetic test's obligation is covered by the signed default-name/dimension checks.

## What I checked and limits

Read: AGENTS.md, doc/multiwrite-architecture.md, the complete plan, QUO-43, the S1.5 and S1.6 reviews and dispositions, all 16 frozen files plus their diffs against HEAD, construction.pl, quod_proof_savepoint, the action state check, quod_ask committed check and scope routing, quod_measure conversion and reduction, lobby policy and physics hooks, the parser and encoder bounds, and the regression-01 log tail. Not done: no execution of any kind, no client code, no inspection of the corrected lobby fixture or the regression-02 tree beyond your messages. Deployment reachability is outside scope but worth one sentence: existing lobbies freeze their composed sources at provisioning (`quod_lobby.pl:36-40`), so they receive the new space behaviour only through authorized source composition.

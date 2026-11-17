# M3 — Enter and reopen the same space with the same agent in Godot

**Type**: task
**Issue Key**: QUO-64
**Status**: in-review
**Priority**: high
**Tags**: godot, ontology, architecture, milestone
**Linked Commit**: f716ddf5e578df957a5b18421a0727a32c634f87
**Sync Status**: pending
**Source**: inline
**progress**: 13
**share**: {"status":"team","body":"team"}
**dependsOn**: [{"itemId":"tsk_01M5YNM08XQG5GVZGTJNYFKHKQ"}]
**blocks**: [{"itemId":"tsk_01M5YNM08XZDSB9AERHSBMCPYZ","issueKey":"QUO-65","title":"M4 — Operate Godot spaces with desktop and OpenXR controls","trackerType":"task","relationshipTypeKey":"blocks","direction":"out"},{"direction":"out","relationshipTypeKey":"blocks","itemId":"tsk_01M5YNM08XVHPEWS88F3VKT2FC","issueKey":"QUO-66","title":"M5 — Package Godot, retire superseded paths and replace the network","trackerType":"task"}]
**ID**: tsk_01M5YNM08XYDABJXFR89HJV6YK
**Updated**: 2026-10-29T00:45:26.658Z

---

Plan: [QUO-60](nimbalyst://QUO-60). Milestone: M3. Dependencies: [QUO-63](nimbalyst://QUO-63).


**Outcome and scope**

Deliver the end-to-end entry/leave/reopen journey by integrating the existing Stage 2 space-entry work with the clean Godot view adapter. Reuse the same A and existing atomic assignment/admission, actions, reactions and live-view owners. Render the exact space subject and contents, with the navigation, picking and GUI interactions needed for this journey.

**Acceptance**

- [ ] The same agent enters and leaves an existing created space; client navigation follows committed location. Denied/stale/conflicting entry creates no partial move or duplicate assignment.
- [ ] Exact-subject contents/GUI views enforce permissions and revocation, apply ordered updates and reject stale owner-incarnation notices.
- [ ] Disconnect, client restart and server recovery reopen the same space with the same identities, without duplicate construction or enrollment.
- [ ] Measure unchanged repeated view use through real owners: no history replay, projection rebuild or unchanged-state writes/syncs; real changes still propagate and persist.

**Existing work:** the existing Stage 2 ticket in the [space task list](/home/yan/src/quod/nimbalyst-local/tracker/tasks.md) remains owner of server entry/Eidolon semantics. This ticket owns Godot integration and journey acceptance. Broader recursive ontology editing/workbench scope is deferred; do not duplicate or silently close that existing ticket.

**Review refinements — additional acceptance**

- [ ] M3a: implement and credit the required subset of existing Stage 2 item tsk_01M5PY8TEXKG858WBZJ1RHC6EW (tracker_get accepts its stable ID), leaving broader recursive ontology editing/D6 and remaining unimplemented D5 obligations open while preserving contents-displaying exteriors.
- [ ] M3b: provide the minimal desktop navigation/picking required by the first journey, then ordered live views and same-identity recovery. M4 expands controls/XR rather than blocking basic desktop entry.

- [ ] Through the GUI, enter S1 from parentless S0, create S2 in S1 through M2's shared operation, enter S2 and return with the same A. Default exteriors bind exact subjects; denied/stale/conflicting transitions and restart/recovery leave no duplicate identities or partial moves. Contents-displaying exteriors remain valid without entry; record actual D5 exposure/frame/cycle coverage and keep broader ontology editing/D6 open.

- [ ] With S0 containing S1 containing S2 and both nested spaces selecting contents exteriors, render their recursively composed contents in S0 without entering them. Verify composed transforms and applicable physical behavior as one continuous space, source revocation and real nested updates, with no artificial one-level cutoff. Repeated unchanged use reuses existing owners; broad ontology editing remains open.

**Boundary with M2 — reconciled 2026-10-28**

M2's creation/default and finite-wireframe exterior integration is the predecessor, not proof of this ticket's recursive contents-exterior/continuous-physics acceptance. The unchecked recursive S0/S1/S2 criterion above remains M3 delivery through M3a's existing Stage 2 projection/physical-domain owners and M3b's Godot integration. Preserve full identities, transforms, source authorization/revocation, dependency ordering, cycles and authoritative physical continuity without entry or an artificial one-level cap. Mesh/wireframe-only evidence never credits this criterion. Broader ontology editing/D6 and remaining unfinished D5 work stay open; no duplicate phase ticket is created.

**Execution**

[Coordinator](nimbalyst://session/ed9cd520-b2a4-4607-a8f5-ff99d08f3e46) supplies the next applicable checkpoint with current prerequisite evidence. The initial branch base below is provenance, not an instruction to reset later work.

### M3a launch prompt

```text
/planning-implement QUO-64

Checkpoint: M3a. Select GPT-6.1 Sol (openai-codex:gpt-6.1-sol), reasoning xhigh, in the session launcher; this text cannot switch models.
Work only in /home/yan/src/quod_worktrees/pearl-stone, branch worktree/pearl-stone. Initial branch base: f6c29fe925e666dd68ee7fa68c0e03f5d03391a2. Verify current HEAD/status and the coordinator's latest prerequisite handoff before edits; never reset to the initial base or edit the dirty main checkout.

Read AGENTS.md, relevant specs and doc/multiwrite-architecture.md in this worktree. Call work_radar for QUO-64 and affected linked items. Read full QUO-60 and QUO-64 through tracker_get and link this session to the existing ticket. These shared items are authoritative: adapt planning-implement bookkeeping to tracker updates; do not create frontmatter plans, synthetic fm:plan items or duplicate tickets. Follow QUO-60's checked review refinements and execution workflow.

Dependencies: QUO-63 with verified evidence on this tree.
Scope: Implement the needed unstarted Stage2 same-agent entry/leave and direct space views, then connect the Godot scene adapter; keep the broader recursive ontology workbench deferred.
This checkpoint: Implement the needed server entry and recursive contents-exterior projection subset through existing Stage 2 owners. Fetch Stage 2 by stable ID tsk_01M5PY8TEXKG858WBZJ1RHC6EW. Preserve its deferred recursive scope.
Required outcome evidence: Same A and space survive entry/leave, client/server restart and recovery; denied/stale/conflicting entry leaves no partial move; exact subject and revocation enforced; unchanged owner reuse performs no history replay/rebuild/unchanged writes and real updates still apply.
Onboarding/nesting requirement: Verify S0 → S1 → S2 and return through the ordinary GUI: enter existing S1 with the same A, create S2 inside S1 through M2's shared operation, and enter it. S0 remains parentless; all other spaces may also be unplaced. Navigation follows committed assignments; denial/conflict/restart/lost replies preserve original identities. Reuse M2's direct exterior adapter. Contents exteriors compose recursively: when S0 contains S1 containing S2 and S1/S2 select contents Eidolons, their contents render in S0 as one continuous space, subject to physics. This applies at every contents-exterior level without entering nested spaces or imposing a one-level limit. Preserve exact identities, source disclosure/revocation, composed transforms, dependencies, cycle handling and authoritative physical behavior. Mesh-only or visually flattened but physically incompatible scenes do not satisfy this contract; the default cube remains one mesh recipe. Scope D5 integration from selected exterior recipes; broader recursive ontology editing/D6 remains deferred.
Read and satisfy the full existing ticket checklist and review refinements, not just this brief.

Use existing Prolog authority, actions, atomic writes, recovery and runtime owners; preserve U/A separation, exact signing/values, caller deadlines and original-result recovery. No old Quod Rust core reuse, implicit storage change, second domain engine or uncertain-write resubmission. Carry out only this checkpoint; no parallel implementation writer, automatic next milestone, unrequested Claude review or unauthorized commit.

Update existing acceptance/status as work lands. Preserve full logs and true exits for focused behavioral checks and applicable README/.forgejo/workflows/gates.yml release gates. Retain failures and unrun hardware cases. Freeze reproducible scoped source evidence, including untracked sources, before handoff; hashes alone are insufficient. Leave partial work unchecked and implemented/uncommitted work in-review.

Return the source/evidence manifest, actual model/effort, branch/HEAD, changed scope, tests, failures and remaining acceptance to coordinator session ed9cd520-b2a4-4607-a8f5-ff99d08f3e46. Use send_prompt messageKind=report once if reporting to that session. Do not close broader contributing tickets. Invoke AGENTS.md's stop notifier before ending.
```

### M3b launch prompt

```text
/planning-implement QUO-64

Checkpoint: M3b. Select GPT-6.1 Sol (openai-codex:gpt-6.1-sol), reasoning xhigh, in the session launcher; this text cannot switch models.
Work only in /home/yan/src/quod_worktrees/pearl-stone, branch worktree/pearl-stone. Initial branch base: f6c29fe925e666dd68ee7fa68c0e03f5d03391a2. Verify current HEAD/status and the coordinator's latest prerequisite handoff before edits; never reset to the initial base or edit the dirty main checkout.

Read AGENTS.md, relevant specs and doc/multiwrite-architecture.md in this worktree. Call work_radar for QUO-64 and affected linked items. Read full QUO-60 and QUO-64 through tracker_get and link this session to the existing ticket. These shared items are authoritative: adapt planning-implement bookkeeping to tracker updates; do not create frontmatter plans, synthetic fm:plan items or duplicate tickets. Follow QUO-60's checked review refinements and execution workflow.

Dependencies: QUO-63 with verified evidence on this tree.
Scope: Implement the needed unstarted Stage2 same-agent entry/leave and direct space views, then connect the Godot scene adapter; keep the broader recursive ontology workbench deferred.
This checkpoint: First verify M3a's exact source and passing evidence. Integrate Godot live views, minimal desktop navigation/picking and restart/recovery. Do not close deferred Stage 2 work.
Required outcome evidence: Same A and space survive entry/leave, client/server restart and recovery; denied/stale/conflicting entry leaves no partial move; exact subject and revocation enforced; unchanged owner reuse performs no history replay/rebuild/unchanged writes and real updates still apply.
Onboarding/nesting requirement: Verify S0 → S1 → S2 and return through the ordinary GUI: enter existing S1 with the same A, create S2 inside S1 through M2's shared operation, and enter it. S0 remains parentless; all other spaces may also be unplaced. Navigation follows committed assignments; denial/conflict/restart/lost replies preserve original identities. Reuse M2's direct exterior adapter. Contents exteriors compose recursively: when S0 contains S1 containing S2 and S1/S2 select contents Eidolons, their contents render in S0 as one continuous space, subject to physics. This applies at every contents-exterior level without entering nested spaces or imposing a one-level limit. Preserve exact identities, source disclosure/revocation, composed transforms, dependencies, cycle handling and authoritative physical behavior. Mesh-only or visually flattened but physically incompatible scenes do not satisfy this contract; the default cube remains one mesh recipe. Scope D5 integration from selected exterior recipes; broader recursive ontology editing/D6 remains deferred.
Read and satisfy the full existing ticket checklist and review refinements, not just this brief.

Use existing Prolog authority, actions, atomic writes, recovery and runtime owners; preserve U/A separation, exact signing/values, caller deadlines and original-result recovery. No old Quod Rust core reuse, implicit storage change, second domain engine or uncertain-write resubmission. Carry out only this checkpoint; no parallel implementation writer, automatic next milestone, unrequested Claude review or unauthorized commit.

Update existing acceptance/status as work lands. Preserve full logs and true exits for focused behavioral checks and applicable README/.forgejo/workflows/gates.yml release gates. Retain failures and unrun hardware cases. Freeze reproducible scoped source evidence, including untracked sources, before handoff; hashes alone are insufficient. Leave partial work unchecked and implemented/uncommitted work in-review.

Return the source/evidence manifest, actual model/effort, branch/HEAD, changed scope, tests, failures and remaining acceptance to coordinator session ed9cd520-b2a4-4607-a8f5-ff99d08f3e46. Use send_prompt messageKind=report once if reporting to that session. Do not close broader contributing tickets. Invoke AGENTS.md's stop notifier before ending.
```

# Stage 2 — Same-agent entry and space Eidolons

**Type**: task
**Issue Key**: This item has no key until it is published.
**Status**: in-review
**Priority**: medium
**Tags**: architecture, space
**Sync Status**: pending
**Source**: inline
**progress**: 25
**dependsOn**: [{"itemId":"tsk_01M5PY8TEX7NP119X8SXNN3HNB"}]
**blocks**: [{"itemId":"tsk_01M5PY8TEXWW97YYRVFRG3GRPY","title":"Stage 3 — Terrain separation and obsolete-helper retirement","trackerType":"task","relationshipTypeKey":"blocks","direction":"out"},{"direction":"out","relationshipTypeKey":"blocks","itemId":"task_1791635396029_xqsm4f","title":"Complete the 3D ontology workbench using space stage 2","trackerType":"task"}]
**ID**: tsk_01M5PY8TEXKG858WBZJ1RHC6EW
**Updated**: 2026-10-28T21:13:27.118Z

---

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
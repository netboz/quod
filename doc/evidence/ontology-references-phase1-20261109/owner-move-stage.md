# Partial owner moves — Phase 1

Phase 1 remains incomplete. No phase boundary, commit, label bump, deployment,
refound or live edit has occurred. The preserved diff is
[owner-move-stage.patch](owner-move-stage.patch).

## Focused checks

- `owned-space-action-03.log`: exit 0, one signed creation/placement test.
  Qualified class creation, idempotence, admission rollback, movement and withdrawal pass.
- `owned-agent-actions-01.log`: exit 1, two tests, one test-helper `badarg`.
  The helper treated signed evidence as an operation reference. Custody passed.
- `owned-agent-actions-02.log`: exit 0, two tests. The helper uses the existing
  operation-reference decoder. Hosting, stale moves, ACL withdrawal and local
  custody restrictions pass.
- `owned-agent-recovery-01.log`: exit 1, one test. Empty recovery state returned
  `{fail, Diagnostics}` rather than the asserted bare `fail`.
- `owned-agent-recovery-02.log`: exit 0, one test. Direct empty-inventory checks
  confirm report replacement and cleanup when the hosting epoch changes.

All logs are retained beside this report; exact commands and child exits are
in [results.jsonl](results.jsonl). The full clean sequential EUnit, CT,
Dialyzer, xref and client gates have **not run for this partial tree**. These
focused successes do not claim a clean phase. Many old fixtures and callers
still use the removed local rules and require migration.

## Pending signing decision

`quod_agent_predicates:sign_typed/4` checks that the native signing call runs
in the exact storing ontology. `authorize_sign/6` then proves the local
`can_sign_agent_request/3` rule. The plan moves that rule to `quod:agent` and
`quod:user`; there will be no local rule to prove. The generic rule also
requires the caller to be the node, while the user's class owner supplies the
existing human-instruction rule. Neither grant may be lost or broadened.

Yan's instruction requires a stop on a code/plan conflict. A decision is pending
on refactoring the existing signing lookup through the instance's class owner,
while retaining exact identity, ACLs, read-only execution and original deadlines.
No native signing-lookup change has been written. The class-owner rulings are
not reopened. The question is about the necessary engine adjustment.

## Measured production lines

[owner-move-delta.json](owner-move-delta.json) compares actual files against the
reconstructed pre-Phase-1 tree: **+1,470 / -1,084, net +386**. Against HEAD:
**+1,625 / -1,271, net +354**. Measurement exits 0 in
[owner-move-measurement-01.log](owner-move-measurement-01.log).
Tests, documentation and evidence are excluded. This is an incomplete move:
agent actions and space behavior are now scoped, while the user's rules and GUI
lifecycle have not yet been removed from their former compositions. The final
phase delta must be remeasured after completing those deletions.

## Documentation

No normative documentation sentence changed during the hosting/custody step.
The current cumulative documentation diff is retained in
[owner-move-doc-diff.patch](owner-move-doc-diff.patch); it includes the earlier
approved reader changes and Phase 0's placement sentence. The implementation
checklist remains at 5/17: the partial owner moves are not marked complete.

Yan approved the signing lookup change on 2026-11-09. Implementation resumed;
this report remains evidence of the preceding partial tree.

# Phase 1: committed guard frame gap

Source inspection on 2026-11-09, before any Phase 1 production edits, in
`worktree/pearl-stone` at `7e6809e46ea290a53ffff910a53e0386d75b966f`.
Yan authorized Phase 1 after the retained Phase 0 browser failure.
The plan's rulings remain final.

## Finding

The plan requires class ACL reads at the class owner to use committed state,
retain ordinary dependencies and forbid writes and live observations. A staged
ACL edit must never authorize another operation in the same transaction.

The existing implementation does not provide that combination across scopes:

- `src/predicates/quod_ask.erl:1877`: `committed_authorization_result/2`
  wraps the local committed base with read capture and a strict policy context.
  Its wrapper options omit proof/session authority. Merely changing the context
  would leave foreign selection without an anchored proof session.
- `src/predicates/quod_ask.erl:309`: `open/5` requires that session authority,
  publishes the current invocation and uses the existing origin-owned scope map.
- `src/quod_proof_session.erl:207`: ordinary invocations start from the
  session's current staged revision. Re-entrant calls deliberately share it.
  Giving the guard ordinary selector authority alone would not select a foreign
  committed base or forbid mutations in that foreign invocation.
- `src/quod_erlog_db_local_prove.erl:512`: `enter_read_only/1` changes the local
  overlay and removes local mutation hooks. It neither discards its staged view
  nor carries that restriction into another ontology's invocation.
- `src/quod_transaction_scope.erl:26`: the current selection carries rollback
  lineage and ordinary/atomic/independent write intent, with no committed-guard
  restriction. Local and remote scope openings consume that same selection.
- `src/quod_predicates.erl:404`: ordinary proof contexts admit live queries;
  strict policy contexts prohibit bridges and following. Just switching to the
  ordinary context would also lose the guard's prohibition on live observations.
- `src/predicates/quod_agent_predicates.erl:177`: custody uses the same committed
  authorization function. Its strict local behavior must remain intact.

These are source findings, not a claimed runtime reproduction. Existing code
currently refuses foreign policy reads; this report does not claim an existing
authorization bypass. The unsafe cases concern an insufficient implementation
of the planned change.

## Proposed implementation scope for Yan

Refactor the existing proof/session/scope machinery so the operation guard can
retain the current signed proof authority while using each participating
ontology's pinned committed base. Carry its read-only and no-live-observation
restrictions through nested local and remote calls, without publishing that
guard frame as the transaction's staged revision. Retain consulted reads,
including failed alternatives, in the existing dependency owners.

Keep invocation ACL, custody and committee verdict checks strictly local.
Keep one existing scope per exact identity, the current transaction owner,
savepoints, cancellation and absolute deadlines. Add no separate execution
path, process, registry, policy store or resource limit. Any required transport
change belongs to the already required cold coordinated release, prepared only.

Verify through existing signed seams: foreign committed class policy succeeds;
staged foreign grants cannot authorize; foreign guard mutations and live
observations refuse; real policy changes conflict; re-entry preserves staged
domain work; local verdict checks still refuse following. Then continue the
remaining Phase 1 checklist.

This is a concrete missing capability in the existing owner, not a request to
reconsider any class ownership, slot, placement or ACL ruling. Work paused under
Yan's instruction to stop before writing anything that appears to need new
machinery. No Phase 1 production code or tests have been changed.

## Verification and changes at this stop

No gates were run in this source-inspection turn; there are no new gate exit
codes or gate logs. The completed Phase 0 campaign remains in
[gate-repairs.md](../ontology-references-phase0-20261109/gate-repairs.md): EUnit
1 for the retained browser rejection; CT, Dialyzer, xref and all reported client
checks 0. This is a blocker stop, not the Phase 1 completion boundary.

Production delta for this turn: +0 / -0. Re-measured cumulative uncommitted
production delta against HEAD: +158 / -190, net -32 physical lines. Existing
Phase 0 edits and evidence remain untouched. No commit, version bump, deployment,
refound or live edit occurred.

Read-only search failures were reported during the turn:

```text
exit 2: rg: src/predicates/quod_actions.erl: No such file or directory (os error 2)
exit 2: rg: src/quod_action*: No such file or directory (os error 2)
```

A subsequent search across `src` found `src/predicates/quod_action_predicates.erl`
and exited 0. A later targeted test-name search returned exit 1 with no matches;
that means no matched text, not a test failure. No tests were silently rerun.

Documentation changed in this turn consists of this new evidence report and
the following exact addition to the plan (plus its updated timestamp):

> **Phase 1 paused before code:** Yan authorized continuation on 2026-11-09.
> Source inspection found that the existing committed guard frame cannot open
> foreign scopes, while ordinary foreign invocations use the transaction's
> staged view. Preserving committed-only, read-only authorization across those
> calls requires a change to the existing scope machinery beyond switching the
> guard's local frame. No Phase 1 production code has been written. The evidence
> and proposed scope are in the
> [Phase 1 blocker report](guard-frame-blocker.md).

No normative documentation sentence was changed.

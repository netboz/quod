# Working agreement

## Shared engineering rules

These are Yan's standing rules for this repository, not optional suggestions.
Read this file before starting work. When delegating, require each agent to
read it and pass on the relevant scope, invariants and verification requirements.
Keep these rules in one place; task handoffs should reference them, not maintain
divergent copies. Read the relevant specs and `doc/multiwrite-architecture.md`
before changing architecture or semantics. Flag conflicts rather than guessing.

### Architecture and Erlang processes

- Prolog ontologies are the core of the system. Domain state, policy, actions,
  authorization and protocol/conversation rules belong there. External Erlang
  predicates are the governed interface to the real world and runtime services;
  they must not become a second domain engine or private knowledge base.
- Do not hardcode resource budgets or population ceilings in Erlang. Resource
  allocation is Prolog policy, including future pricing of scarce resources.
  When an existing numeric cap blocks ordinary work, fix its policy ownership
  and related enforcement paths; do not silently raise the constant or split
  domain transactions to evade it. Distinguish actual encoding constraints from
  configurable budgets, and report the resource that was actually exceeded.
- Build every new domain, including FIPA, on Quod's existing actions,
  multi-ontology transactions, ontology recovery and reaction framework. This
  is a foundational rule, not an optional optimization. Before proposing new
  machinery, trace the use case through those paths and identify a concrete
  missing capability. Commit related domain changes and receiver consequences
  in one existing atomic transaction where they form one transition; do not
  artificially separate them and then build messaging, acknowledgements or
  recovery to reconnect them. Preserve event-pattern unification and distinguish
  restoring ontology state from replaying reactions. Extend the existing owner
  only for a demonstrated gap; do not duplicate guarantees already provided.
- Refactor to the domain concept: one authoritative implementation and one
  owner for each mutable truth. Reuse existing functions and lifecycle
  machinery; extract shared algorithms into pure modules when appropriate.
  A module does not need its own process.
- Prefer asynchronous messages for cross-process work. Use the existing
  gproc/`quod_reg` pub/sub facilities for shared local events; use direct
  messages when the recipient is already owned or known. Do not add a broker,
  second executor, shadow inventory or queue merely to connect existing owners.
- Publish meaningful installed-state changes, scoped to the affected identity
  and owner incarnation. Wake only work whose dependencies changed, not all
  pending work. Preserve subscription/snapshot ordering, cancellation and
  absolute caller deadlines; stale or duplicate notices must be harmless.
- No polling, sleeps or recurring retry timers to discover readiness when the
  owning process can notify it. Protocol-required expiry/failure detection is
  distinct from readiness polling. Do not block a state owner on network I/O.
- Share verified results, references and deltas, not another mutable copy of
  the truth. Do not copy Prolog state between nodes during proofs or re-read
  ledger prefixes on ordinary requests. Recovery and rebuilds need explicit
  lifecycle reasons, not hidden request-time repair paths.

### Simplification and maintenance

- "No Akira code": no ad-hoc special cases, exception-driven workarounds,
  hidden fallback behavior or clever patches that obscure the architecture.
  Fix the underlying abstraction instead of layering around the symptom.
- Replace the old path when introducing its replacement. Do not keep parallel
  old/new implementations, permanent fast-path forks or compatibility shims.
  New behavior belongs in the shared model, not an alternative execution path.
  Clean format breaks still require the applicable review/deployment authority;
  this rule alone never authorizes a data wipe.
- Remove superseded code, unused exports, duplicate validation and stale
  comments/docs in the same scope. Verify callers and runtime reachability;
  neither Dialyzer/xref alone nor absence from one trace proves code is dead.
  Preserve user-owned files and pinned document prefixes.
- Aim for fewer production lines and fewer concepts after a refinement. Report
  the actual delta and explain unavoidable growth; do not achieve a smaller
  count by compressing formatting, hiding code elsewhere or deleting coverage.
- Keep comments about current invariants and intent. Put run logs, historical
  status diaries and review narration in handoffs, not implementation docs.

### Diagnosis and verification

- Understand the causal chain before optimizing. Use traces and deterministic
  reproductions to distinguish computation, mailbox residence, I/O and protocol
  waits. Add bounded, redacted, removable tracing when needed; observation must
  not change authority, mask errors or require another execution engine.
- Preserve consensus, authorization, custody, proof/backtracking/cut and
  commit guarantees. Performance goals do not authorize weaker checks, extended
  deadlines, uncertain-operation resubmission or changed client semantics.
- Test the behavior and the failure it prevents, using real production seams.
  Retire obsolete tests by identifying where their still-valid obligations are
  covered; do not preserve obsolete machinery just to satisfy its old fixtures.
  Synchronize tests with delivery/processing evidence, not sleeps or send traces.
- At required release/review boundaries, use the standing clean sequential
  gates, full logs and true child exits. Retain and triage failures before
  trusting a run; no silent reruns or weakened assertions. Freeze each scope's
  exact tree and evidence, keep label bumps separate, and report partial work
  honestly. Do not turn routine edits into unnecessary review rounds.

## Continuity

Yan's standing instruction (2026-09-24): do not initiate Claude reviews or
consultations unless Yan explicitly requests one. Review the work independently.
When explicitly requested, use the Fable model; its advice remains consultative
and must be checked against the code and architecture.

Yan's standing instruction (2026-09-10): keep progressing through authorized
work without stopping at routine intermediate steps, including while Yan is
away. Use the authority already granted for the current workflow; do not ask
again for an unchanged, already-authorized operation.

Stop only for a genuine blocker, an unresolved safety/correctness question,
a required architecture or review-before-commit gate, or a material expansion
of scope requiring a user decision. Explain the concrete reason. This is not
permission to bypass review, resubmit uncertain writes, alter deadlines to
hide failures, or broaden destructive operations beyond the authorized scope.

Preserve user-owned changes. Keep failed measurements and stop markers intact;
an explicitly authorized new campaign must be separately labeled, not replace
or silently resume a failed campaign. Report actual results, including failures.

## Stop notifications

Yan requested a desktop notification whenever work finishes or pauses
(2026-09-10). Before ending a main-agent turn, invoke
`/bin/sh /home/yan/.codex/notify-stop.sh` when available, and state any actual
blocker in the final response. The local notifier deliberately omits conversation
and source content. If notification delivery fails, report that failure rather
than claiming delivery. A Codex `notify` hook is also configured for future turns;
neither mechanism guarantees an alert after an abrupt process or host failure.

# Fable review addendum 2: withdrawal of the two-operation sequence, candidate verdict, heap hypotheses

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-12. Consultative only.
`fable-review.md` and `fable-review-addendum-01.md` are left unchanged. This
addendum records what the parent's three updates change, states the candidate
verdict in one place with no second operation, and offers code-reading
hypotheses for the 32-field heap exhaustion. No command, build or test was
run. Line numbers refer to `tree/`.

## 1. Corrections to the first report

- **C1 is closed.** The parent reproduced the atom-unit backtracking error,
  fixed it in delta-01, and explained the run history: the 97-test pass
  preceded the malformed-continuation case. There is no error-to-failure
  mapping question left; the "unresolved" item 1 in section 8 of the first
  report is withdrawn.
- **Sections 6 and 7 of the first report are withdrawn.** The sequence there
  introduced a control request R0, a custody transaction and a second
  material request R2, and a separate "presentation" flavour. Both contradict
  the settled single `gui_open/2` lifecycle and the no-second-operation
  requirement. They should not be used. Section 5 of that report (verified
  owner facts I1 to I8) stands and is reused below.

## 2. Candidate verdict, same original operation, no R2

The full audit is in addendum 1, sections 2 to 4. The verdict, restated:

**Mechanically consistent.** One original signed execute whose proof seals
the question row in the responder ontology, the HUD reference in the human
ontology, and an empty-diff effect plan in the receiver node's ontology forms
one atomic group (`src/quod_dtx.erl:473-474`, `src/quod_prolog.erl:4626-4645`).
Validators and replay check only the effect's shape and never run it
(`quod_dtx.erl:292, 952`; `src/quod_effect_journal.erl:993-997`). Group rows
bind before vote activation and retire through existing resolution
(`quod_prolog.erl:5340-5396, 785-830`). No custody transaction, no R2.

**Where acceptance may happen.** The existing owner performs native
preparation after sealing, not inside the action transition: the single lane
reserves and stages the journal row at submission
(`quod_prolog.erl:5062-5111`), and the group lane stages and binds through
each scope session between vote reservation and activation
(`quod_prolog.erl:5340-5363`). Proof-time work for a lifecycle effect is
deterministic data from committed policy (E7 in addendum 1). Therefore:

- Acceptance obtained inside the proof, before sealing, makes the question
  and HUD diffs depend on a live yes/no. That is the condition the sealing
  veto names (`quod_dtx.erl:38-44`), placed in a scope whose empty diff hides
  it from the per-scope check. Not acceptable.
- Acceptance obtained by the receiver node's scope session immediately
  before `bind_group`, against sealed content, with the caller's remaining
  deadline, is an admission gate of the same class as `not_in_charge` or
  `busy` (`quod_effect_journal.erl:1618-1630`). Refusal cancels the vote and
  leaves nothing durable. Acceptable, and it keeps every settled requirement:
  no human or no capable agent means no shared rows; success only after the
  certified group; later disconnection changes nothing.

**Three verified gaps that make it executable** (details in addendum 1,
sections 3.3 to 3.6):

1. A bind refusal reported before activation must become Prolog failure with
   a reason; today the group lane returns it as an error
   (`quod_prolog.erl:5355-5363`), and only the control lane has the
   refusal-to-fail mapping (`:4425-4436`).
2. A runtime read usable from a scope session that answers whether the
   selected responder is hosted at the expected epoch and key and has policy
   capacity; `agent_request/6` is not usable because it accepts only the
   runtime's own event runner (`src/quod_runtime.erl:376-391`). Capacity
   thresholds stay Prolog policy.
3. Receiver registration keyed by human and connection incarnation, done by
   the view owner after its verified signed open; `quod_client_simulation`
   registers nothing today (`src/quod_client_simulation.erl:69-93`). The
   receiver scope itself must be selected from committed state; absence on
   that scope is authoritative, elsewhere is not routed.

**Post-commit execution must be terminal on first run.** The journal runs one
released row at a time, lowest height first, and a `{retry, _}` row is
re-selected first every reconciliation (`quod_effect_journal.erl:520-529,
1004-1020, 1749-1757`). A presentation handler that waits for a disconnected
receiver would block every later lifecycle effect on the node. Since every
durable truth already exists at apply and the HUD discovers it, the handler
is `ok` with an optional local notification, never retry. The
lifecycle-specific postcondition in `execute_row/1` (`:1022-1103`) must be
replaced by the closed handler dispatch the candidate already lists.

**Residual cost to accept knowingly.** Each opening consumes one node-wide
custody slot and prepared bytes from root's `effect_custody_limits` until the
group applies (`:303-317, 560-585`), and one serialized journal run with no
obligation. A reserved vote whose worker dies before activation leaves
`group_pending` rows that retire only when resolution observes an abort;
whether that is guaranteed for a never-activated vote is unverified here
(`quod_prolog.erl:826-830`) and the lifecycle lane has the same exposure.

**Agent-originated openings.** `start_request/5` retains no request bytes
(`src/quod_agent.erl:95-131`), so a lost reply is resolvable only by domain
idempotency on the question rows, not by operation evidence, unless the agent
submits through the custodied mode. Say which in the plan.

## 3. Heap exhaustion with 32 fields: hypotheses from code reading

The parent reports that batching the per-field scope calls alone does not
stop the exhaustion. These are hypotheses to check against the trace, not
findings.

H1. **Open scoped invocations are retained until an enclosing cut.** Every
`Ns::(…)` in `gui_initial_field/4` and `gui_bind_fields/4`
(`priv/ontologies/gui_instance.pl:97-100, 126`) is a streamed ask whose
invocation stays open as a choice point until the proof either backtracks
into it or a cut discards it. `gui_definition/5` cuts its compile with
`once/1`, but `gui_values/3` and `gui_bind/5` have no cut around the per-field
asks, so a 32-field bind holds roughly 32 to 64 open remote invocations plus
their origin-side stream state simultaneously. Check: count open invocations
per read in the trace; wrap each deterministic ask in `once/1` (or compute
through one `findall` per form, which also closes them) and compare heaps.
Batching per field without closing the batch's invocation would not help,
which is consistent with the parent's observation.

H2. **Follower asks inside the class closure.** For every component declared
through a local subclass, `isa/2` enumeration issues the denied follower asks
described in C4 (`'$quod_isa_path'/3` and `member_eq/2` lack `no_follow/1`,
`priv/ontologies/common_predicates.pl:182-186, 292-296`). Each denied ask
still opens a scope invocation and records a dependency and failure
diagnostics. With 32 such components this multiplies H1. Check: whether the
32-field fixture uses local subclasses, and the per-read count of denied
invocations.

H3. **Tree traversal choice points per field.** `gui_tree_component/5`
(`gui_instance.pl:65-67`) walks the tree with `member/2` and is called once
per field in `gui_field_declarations/4`, `gui_initial_field/4`,
`gui_fixed_values/4` and `gui_bind_fields/4`, each call leaving up to one
choice point per sibling until the enclosing predicate completes. For N
fields that is O(N²) live choice points during bind. Cheap individually, but
they pin every binding environment reachable from them, including the
`Tree`, `Values` and `Properties` terms crossing the asks. Check: heap before
and after replacing the walk with a one-pass index built once per compile.

H4. **Whole-term shipping on each ask.** `Properties` for a selection carries
the full `options` list and is sent on every default and validation ask;
with large option lists this multiplies the per-ask copy on both sides.

If H1 holds, the fix is also the C7 fix: one closed vocabulary ask per form
for schema, one for initial values, one for bind validation, all under
`once/1` or `findall/3`.

## 4. Unverified

Everything in sections 2 and 3 beyond the cited lines, including
`quod_scope_session`, `quod_dtx_coordinator`, `quod_atomic`, the lifecycle
codecs in `quod_ontology`, erlog's ask stream buffering, and the parent's
112-test and 32-field runs.

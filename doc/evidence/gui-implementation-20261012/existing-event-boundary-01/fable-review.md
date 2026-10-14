# Fable review: existing event admission regression (existing-event-boundary-01)

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-13. Consultative only.
Basis: `review-request.md`, `manifest.json`, the frozen `tree/` (AGENTS.md
unchanged; runtime equals the source-notice-01 copy; runtime predicates equal
the dispatch-provenance-01 baseline; `quod_diff` and the transaction
predicates equal HEAD), the new test diffed against HEAD, and the host
fixture in `quod_agent_hosting_tests.erl`. No command or test was run; the
parent's gate is the evidence.

## 1. Verdict

The test pins the right owners and proves the property through production
seams. No production delta remains from the provenance experiment. Nothing
required.

## 2. Refusal boundary (verified)

- Proof admission: `trigger_event_1/3` calls `quod_diff:valid_event/1` and
  raises `domain_error(event, Term)` for a ground reserved wrapper
  (`quod_transaction_predicates.erl:43-56`). The test asserts exactly that
  error through the signed request path for `assert/1`, `retract/1` and
  `from/3`.
- Canonical validation: `valid_op({event, Term})` uses the same
  `valid_event/1`, so a hand-built diff carrying such an event is refused by
  every validator (`quod_diff.erl:190-209`). The test asserts
  `valid_ops/1` is false for the same three wrappers.
- Consequence: a matched `assert(Fact)` or `retract(Fact)` occurrence can
  only come from an applied clause operation, and a `from/3` occurrence
  only from the follower's own wrapping of a certified foreign publication.
  This is the provenance the abandoned proposal tried to add.

## 3. Identical composition (verified)

The fixture composes the identical `react_on` clause twice in the genesis
diff. `apply_op/3` treats a present clause as `unchanged`
(`quod_diff.erl:280-284`), so one clause is installed. The test does not
inspect the catalogue; it proves the effect: one assertion yields one ping
and one executed reaction. Two installed clauses would have produced two
pings and a count of six, since `dispatch_candidates/7` runs every matching
clause. A later identical source edit takes the same reducer path.

## 4. Processing and count assertions (verified)

- The repeated `assertz(accepted_input(original))` is deduplicated at apply,
  so it carries no occurrence. The following `asserta(next)` is a real
  change and yields one ping.
- The barrier is an ordinary explicit event handled by the fixture's
  `do_work/1` owned reaction. Local envelopes are queued and folded in
  height order, so the barrier's reaction cannot run before the preceding
  envelopes were processed. An actor starts a queued request only after
  `agent_release` from `events_finished/2`, which also updates
  `reactions_executed`, so `finished/1` for the barrier implies the counts
  for all three batches are already in the stats. The `Before + 3`
  assertion and the ordered ping list therefore rest on processing, not on
  the absence of a second fact.
- `finished/1` is consumed once per real reaction (next, barrier). The
  deduplicated commit produces no request, so no stray result is left for
  a later receive.

## 5. In the manifest, not the requested focus

`quod_agent_hosting_tests.erl` renames one test and extends it to read
`current_request_operation/1` inside a foreign `::` scope and compare it with
the operation reference returned by ingress. That matches the propagation
contract from the request-context review and does not touch the boundary
above.

## 6. Optional

A single assertion that a real `retract` of `accepted_input(original)` yields
no ping would document that the assert pattern does not match retraction
occurrences; the boundary already guarantees it, so this is documentation
only.

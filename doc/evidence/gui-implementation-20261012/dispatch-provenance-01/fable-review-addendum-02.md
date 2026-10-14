# Fable review addendum 02: provenance gap withdrawn

Reviewer: Claude Fable 5.1, 2026-10-13. Source reading only; no command run.

## Withdrawn: section 3 of the first report and R1 of section 5

I concluded that no existing owner distinguishes an actual assertion from an
explicit `trigger_event(assert(Fact))`, and endorsed a reducer-side origin
with a reaction-only accessor. That was wrong. The admission owner already
exists: `quod_diff:valid_event_pattern/1` refuses the reserved wrappers
`assert/1`, `retract/1` and `from/3` (`quod_diff.erl:201-209`), the staging
predicate raises `domain_error(event, Term)` for them
(`quod_transaction_predicates.erl:55`), and `valid_op({event, _})` applies the
same check at canonical validation on every validator. An explicit event can
therefore never unify with `react_on(assert(Row), ...)`. A matched
`assert(Row)` occurrence is by construction an applied assertion of a
committed clause.

I verified the rejection in source after the parent's gate showed it. My
trace of `diff_to_events/1` stopped at the reducer and did not look at what
reaches it; the candidate shared that gap and I did not challenge it.

Consequences for the first report:

- The "provenance gap" does not exist. No occurrence origin, no
  `committed_assertion/1`, no accessor. The parent has withdrawn that delta
  and I do not endorse reinstating it.
- R1 is withdrawn. The regression the parent is adding on the existing
  boundary (reserved wrapper refusal) and on identical composition is the
  right coverage.
- R2 through R6 stand as written, with R4 already narrowed in addendum 01.
- The at-most-once trace in section 2, as corrected in addendum 01, stands.

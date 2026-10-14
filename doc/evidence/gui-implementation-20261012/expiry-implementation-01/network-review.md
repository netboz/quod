# Fable review: trusted network context for negative-evidence validation (expiry-implementation-01)

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-13. Architecture
consultation only. Basis: `network-integration.md`, AGENTS.md, and the live
owners read-only: `quod_commit_validation`, `quod_committed_projection`,
`quod_prolog` (validation requests, parked verdicts, apply dependency wait,
read-plan certification), `quod_transaction`, `quod_atomic`, `quod_dtx`,
`quod_selection_basis`, and the engine's verdict handling in `quod_simplex`.
No command, test or production edit was run. No negative wire or result is
proposed as enabled.

## 1. Verdict

The constraint document is right on every point I could check, and the
minimal flow is smaller than it suggests: one acquisition point for every
plan-shaped path, one captured field for content, and four existing
unavailable mappings reused unchanged. Section 3 gives the flow, section 4
the counter-cases that drove it.

## 2. What the owners do today (verified)

- Network truth is the root anchor, read through
  `quod_ontology:network_identity(Required, Target)`; it is never stored in
  `#context{}` (`quod_commit_validation.erl:28-34`). `content/4` asks once per
  call and threads the value as a parameter; `vote_request/4` asks again per
  vote.
- Unavailability is already typed by mode: `dependency_verdict/3` yields
  `abstain` in `check` and `{unavailable, network_identity, Reason}` in
  `{claim, _}` (`:195-200`). The projection turns the latter into
  `{wait, network_identity, Reason, Projection}` for content (`:177-179`) and
  for control batches (`:416-418`); `quod_prolog` then monitors the root
  owner and re-drives a rebuild, retaining no entry
  (`wait_for_apply_dependency/2`, `resume_apply_dependency/1`). In check
  mode the engine simply does not support the candidate
  (`on_content_foreign_verdict`, `apply_dtx_verdict(abstain, ...)`), and a
  parked verdict is reaped to `abstain` on parent timeout.
- `outcome_error` is reserved for index failure: `commit_validation_result/2`
  restarts the owner on it (`quod_prolog.erl`). `quod_diff:validate/3` returns
  only `ok | {conflict, F} | {outcome_error, R}`, so network absence cannot
  be surfaced from inside it: `conflict` would reject a valid transaction
  as `conflict_retry`, `outcome_error` would restart the owner.
- The second ordinary OCC runs in the projection after `content/4` succeeded
  for the whole entry (`apply_prepared_content_entry/5` then
  `apply_ordinary_transaction/4`), with `{Outcomes, Applied}` only.
- Direct remote application is reached from the same entry apply through
  `apply_remote_application/4`, which calls `remote_application/2` without
  going through `content/4`'s acquisition, and maps `abstain` to an error
  (`future_parent`). Read-only certification enters
  `read_only_plan/2 -> validate_prepared_plan/2` from `validate_read_plan`,
  whose caller receives `{error, Reason}` as a typed reply, not a verdict.
- In certified-vote verification (`dtx/4`, claim mode) a `wait` from
  `validate_vote_choice/5` becomes `abstain`, which `validate_dtx_batch`
  treats as an invalid committed control. That path is unreachable today
  because a certified vote carries its own plan, but it means a new wait
  cause must not be expressed as `wait` in claim mode.
- `requires_network_identity/1` looks only at `request_auth` and
  `auth_transcript` (`quod_transaction.erl:746-752`); the atomic variant looks
  only at the group request. Neither sees read checks.

## 3. Minimal flow

**A. One captured field.** Add `network = none :: none | <<_:256>>` to
`#context{}`. Add `ensure_network(Required, Context)`: `false` or already set
returns the context; otherwise `quod_ontology:network_identity(true, Target)`
and store. Replace the two existing per-call acquisitions (`content/4`,
`vote_request/4`) with it so the parameter threaded through
`validate_content_transactions` is the context's field. Nothing else about
those paths changes; the value is immutable for the life of the context
and identical to what the per-call reads returned.

**B. One acquisition point for plan-shaped paths.** The decoded read check
exists in exactly one place for all four plan paths:
`validate_prepared_plan_material/3`, reached by `validate_prepared_plan/2`
(read-only certification), `prepared_application_material/4` (remote
application, direct and via content), and `own_vote_choice/4` (vote
selection and certified-vote verification). Call `ensure_network/2` there
with `Required = has_negative_reads(ReadCheck)`, a key scan for the new kind
over the already-materialized map: no second decode, no history. On
`{error, Reason}` return a distinguished
`{unavailable, network_identity, Reason}`, never `outcome_error` and never
`{error, _}` (the latter is mapped to a refused vote in `own_vote_choice`,
which would fabricate a deterministic refusal from a live condition).

**C. Four existing mappings, one new value each.**

- Read-only certification: `read_only_plan/2` returns
  `{error, {unavailable, network_identity, Reason}}`; `validate_read_plan`
  already forwards `{error, Reason}` to the caller as a typed reply. The
  caller treats it like `not_ready`.
- Vote selection and verification: `own_vote_choice/4` returns the new
  value as its choice after `quod_selection_basis:note(parent, Est)`, which
  is exactly what `vote_request/4` does on the same failure today (`:523`),
  so the selection is re-evaluated on the next parent advance without any
  subscription. `validate_vote_choice/5` and `prepare_observed_vote/3` map
  it through `dependency_verdict(Mode, Reason, Context)`: `abstain` in check,
  `{unavailable, network_identity, Reason}` in claim. The claim form already
  becomes `{wait, ...}` in `validate_dtx_batch` and the root-owner monitor in
  `quod_prolog`. Do not reuse `wait` for this, because of the claim-mode
  `abstain` error noted above.
- Remote application: `classify_remote_prepared/1` maps the new value to
  itself. In `validate_content_transactions` it becomes the existing
  `{ok, {unavailable, network_identity, Reason}, Context}` in claim mode and
  `abstain` in check mode. In the direct `apply_remote_application/4` add
  the one clause returning `{wait, network_identity, Reason, Projection}`
  beside the existing `abstain -> error` clause, since that path never ran
  `content/4`'s acquisition.
- Content second OCC: `content/4` in claim mode now captures the network
  into the context (A); `set_validation_context/2` copies the whole context,
  or the projection grows a `network` field, so `apply_ordinary_transaction`
  passes `{Outcomes, Applied, Target, Network}` to `quod_diff:validate/3`.
  Because `content/4` succeeded, the network is present; the second OCC can
  never observe absence, which is what keeps `quod_diff:validate/3` free of
  a network error class.

**D. `requires_network_identity` over read checks.** For content, extend the
unsigned clause (`request_auth = none, auth_transcript = none`) to also
return true when `has_negative_reads(Change#transaction.read_check)`. The
read check is a field of the record, so this is a key scan, not a decode.
Signed transactions already require it. For votes, nothing is needed at
`vote_request/4`: the plan's reads are checked at B, after the one material
decode, and the group request already forces acquisition when present.

**E. `quod_diff:validate/3` context.** Accept `{Outcomes, Parent, Target,
Network}`; the negative kind dispatches to `quod_outcome` with all four,
and with `Network = none` or a two-tuple context it returns `{conflict, Key}`
exactly as an unknown kind does now. That is correct only because A to D
guarantee the network is present on every path that can carry the kind;
state that invariant beside the clause.

## 4. Cases that shaped the flow

- An unsigned own-plan transaction carrying the negative kind, applied on a
  node whose root is not ready: D makes `content/4` ask, A stores or returns
  the existing claim-mode unavailable, the projection waits, the owner
  monitors the root and rebuilds. Without D it would reach the second OCC
  with `none` and be rejected as a conflict.
- A certified prepared vote whose own plan carries the kind, on the same
  node: B returns the new value, C maps it to the claim-mode unavailable and
  the batch waits. Expressed as `wait` it would have been an invalid
  committed control.
- Selection of the same vote before the root is ready: C maps to `abstain`
  with the parent noted, so the next parent advance re-selects. No timer,
  no service, no fabricated refusal.
- A read-only certification request before the root is ready: typed
  `{error, {unavailable, network_identity, _}}` to the caller; nothing is
  parked and nothing restarts.
- Direct remote application on a node whose root is not ready and whose
  entry has no signed transaction: today `content/4` would not ask; with D
  it asks only if a read check needs it, and the direct path has its own
  wait clause regardless.

## 5. Explicitly not proposed

No subscription from the validator, no retry timer, no second queue of
entries, no `outcome_error` for network absence, no refused vote from an
unavailable network, no re-decode of signed plans to rediscover the
requirement, and no change to the positive query's mismatch behaviour.

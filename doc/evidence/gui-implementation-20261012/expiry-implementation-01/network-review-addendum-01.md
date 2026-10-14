# Fable review addendum 01: direct remote application and the pre-batch invariant

Reviewer: Claude Fable 5.1, 2026-10-13. Source reading only; no command run.
Scope: the one correction the parent raised against section 3C of
`network-review.md`. Live owners read: `quod_committed_projection`,
`quod_commit_validation`, `quod_transaction` (`remote_application_material/3`,
`semantic_id/2`, `valid_id/2`).

## 1. Correction accepted

My proposed `{wait, network_identity, ...}` clause in
`apply_remote_application/4` is withdrawn. That function runs inside the
`apply_transactions/3` fold, which accepts only `ok` or `error` and may have
already applied earlier transactions of the same entry into the projection's
MVCC and staged outcome state; a wait there would be a partial-batch wait
with no projection to hand back. Network absence at that point must be
unreachable, as the parent states.

## 2. Verified: no direct apply path bypasses content prevalidation

`apply_remote_application/4` has exactly one caller, `apply_transaction/3`,
reached only from `apply_transactions/3`, reached only from
`apply_prepared_content_entry/5` after `content/4` returned `valid` for the
whole entry. Both the hosted owner (`quod_prolog.erl:6604`) and the foreign
projection (`quod_foreign_projection.erl:322`) enter through
`apply_entry/3`. There is no other production path to the inner remote
check. `content/4` itself already runs `remote_application/2` on every
remote-application record in the entry, in both modes, so the inner call is
a second evaluation of the same checks, like the ordinary second OCC.

## 3. Verified: the record's read check is trustworthy input for the scan

`remote_application_material/3` builds the expected record with
`read_check = maps:get(read_check, Material)` from the claim's own plan
(`quod_transaction.erl:179-213`). The ledger record is bound to that content
in two places, both evaluated before any OCC or network-dependent step in
`remote_application_checked/6`:

- the expected `tx_id` is `semantic_plan_id/7` over the plan's read-check
  bytes and must equal the record's `tx_id`;
- `valid_id/2` recomputes `semantic_id/2` from the record's *own* fields,
  which hash `quod_read_set:encode(ReadCheck)` (`:790-805`).

A record whose `read_check` was altered or stripped therefore fails
deterministically, on every validator, before the plan material is checked.
So extending `requires_network_identity/1` to scan the unsigned record's
`read_check` for the negative kind is sound: whenever the inner check could
need the network, the scanned field contains the kind, and `content/4`
acquires it before the batch.

## 4. The invariant and what carries it

- `content/4` in claim mode captures the network into the context (A) when
  the entry needs it (D, now including remote-application records).
- `set_validation_context/2` must copy the captured network into the
  projection alongside the outcomes, and `validation_context/1` must put it
  back into every context built from that projection. Today it copies only
  outcomes (`quod_committed_projection.erl:577-583`); a context built inside
  the fold is otherwise fresh and would re-ask the root.
- The acquisition point in `validate_prepared_plan_material/3` (B) must treat
  a present network as authoritative and never re-ask. With the two points
  above, every inner evaluation during apply sees the value `content/4`
  obtained, and absence is unreachable there. The removed clause is replaced
  by nothing; the existing `abstain -> error(future_parent)` stays as the
  only non-apply outcome of the inner call, which is likewise unreachable
  after a valid `content/4`.

## 5. Must a plan-only acquisition return its updated context?

Not for the invariant. The paths where B can actually acquire are read-only
certification and vote selection or verification, each a fresh context per
request or per control, and each pre-apply: their wait or abstain is
already typed at a boundary with nothing applied. For the content batch, B
never acquires because A and D ran first. Returning the context from
`validate_prepared_plan_material/3` is still worth doing, for one reason: in
`validate_dtx_batch/7` several controls share one entry, and without it each
control's vote would re-read the root. That is a cost, not a correctness
gap; three call sites change, and `own_vote_choice/4` already returns its
context.

## 6. Net change to section 3

3C, remote application: delete the direct-path wait clause; keep the
content-path mapping (`abstain` in check, the existing claim-mode
unavailable) and the `classify_remote_prepared/1` value. 3A/3D: add the
projection field and its two copy points as stated above. Everything else
in the review stands.

# Fable review: certified expiry dependency contract (expiry-dependency-01)

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-13. Architecture
consultation only. Basis: `review-request.md`, `candidate.md`, the frozen
`tree/` (all files equal to the latest reviewed copies or live), and
read-only lookups in the live tree for `quod_simplex` timestamp rules,
`quod_ontology:network_identity/2`, and the current
`committed_operation_outcome` predicate. No command, test or production edit
was run. Nothing here authorizes an implementation.

## 1. Verdict

The future-row distinction is correct, and it is necessary, not merely
sufficient. I found no lane, era or epoch that can admit a claim of the
original bytes above a certified prefix whose time exceeds the signed
expiry. The network and scope context the validator needs already flows
through `quod_commit_validation` for signed transactions; the candidate must
reuse that gate rather than the token's own fields, and must extend the
"requires network identity" test to read checks. Required points are in
section 6.

## 2. Future-row challenge

Facts the argument rests on:

- One row per `{operation, Ns, Anchor, Agent, Id}`; a later claim with a
  different digest for an existing key is `outcome_index_conflict`, never a
  second row (`quod_outcome.erl:669-690`). A different request reusing the
  same agent and id can therefore claim later only if the original never
  claimed, which is exactly the case the theorem is about.
- Claim rows are permanent across reopen; the DTX subset and floor are
  cleared and rebuilt by replay (moduledoc). During replay a retained row
  with `first_slot > Parent` is treated as clear for claim checks
  (`quod_commit_validation.erl:617-622`).
- Every lane installs the claim at the slot of the certified block whose
  timestamp admitted it: content and remote claims via `validate_context` at
  block time, atomic prepared votes bounded by the manifest deadline which
  is at most the request expiry, with refusal after it. Block timestamps
  are non-decreasing along a history (`valid_parent_transition/3`), empty
  carriers inherit their parent's time and produce no ledger entry, and a
  new era's engine carries the prior root timestamp rather than resetting it
  (`quod_simplex.erl:524, 923`; confirm the value passed is the certified tip
  time, section 8).

Consequence: a row whose digest equals the original bytes can only have
`first_slot = S` with `time(S) <= E`. If `time(P) > E` for the captured
prefix height P, monotonicity gives `S < P`. So a same-digest row above P
cannot exist on this history, and any row above P is either a different
request's legitimate later claim or a retained future row of a different
request. Ignoring rows above P is sufficient.

It is also necessary. A validator that required absence of every future row
would answer differently before and after a reopen that retained such a
row, so the same block would validate live and fail on replay. The
dependency must be a pure function of rows with `first_slot <= P`, the
height P time row, and the token.

Cases that must block expiry, and do under the rule:

- Any row with `first_slot <= P`, whatever its digest and state, including
  an unresolved prepared group whose O vote was certified at or before P.
  A different digest there is not expiry; it is a conflict, and the
  existing positive read with digest mismatch is the terminal answer for
  the original bytes. The candidate's "reject" is right; name the result
  so it is not read as unavailable forever.
- A pending local vote not yet certified has no row and does not block,
  which is consistent: if it is certified later its block time exceeds the
  deadline and it is refused.

Admission timestamp notes:

- Future skew of up to the configured bound means expiry can be certified
  before wall-clock E. Admission uses the same block times, so once any
  certified block exceeds E no later block can admit. Safe.
- Hosting epochs and key rotation change the bytes, hence the digest; the
  key identity is unchanged, so the conflict rule above applies.

No counterexample.

## 3. Network and scope context

The token's embedded network, namespace and anchor are untrusted input.
The validator already has trusted values:

- `#context{target}` is the exact scope identity, and
  `quod_ontology:network_identity(Required, Target)` returns the network
  from the validator's own root anchor, waiting (not failing) while it is
  unavailable (`quod_commit_validation.erl:139-144, 200`).
- `quod_diff:validate/3` receives `{Outcomes, Parent}` from
  `quod_commit_validation.erl:747` and `quod_committed_projection.erl:292`.
  Extend that context to `{Outcomes, Parent, Target, Network}` and dispatch
  the new kind to `quod_outcome` with all four. `validate/2` in
  `quod_prolog.erl:1895` carries no context and must keep failing closed
  for any outcome kind, as it does today.
- `requires_network_identity/1` inspects transactions only
  (`quod_transaction.erl:746-752`). An unsigned application transaction
  whose read check carries the new key would otherwise be validated with
  `Network = none`. The test must also return true when any read check
  contains the key, so the block waits for the identity exactly as a signed
  transaction does.

## 4. Index and timestamp row

- `advance_applied/2` is called once per applied ledger slot, which are
  material heights; non-material carriers never reach it. Storing the
  entry timestamp there, validated non-decreasing against the previous row,
  gives exactly the time the admission lanes used.
- Visibility is already floor-gated: the staged floor is not observable
  until the same flush (`mark_flushed/2`). A time row staged in the same
  block cannot be read before its claims.
- Reopen: decide whether the time rows are permanent (like claims) or
  rebuilt (like the DTX subset). Either is correct because reads are
  floor-gated. If permanent, replay must compare and treat inequality as
  corruption, matching `terminal/4`'s refusal to overwrite.
- Cost: one compact row per material height on disk, in the existing
  bounded cache. Reads of an unchanged dependency hit the cache or one
  DETS lookup; no replay, rebuild or write.

## 5. Read-set codec

- Key `{2, Agent, Id}` sorts after `{1, _, _}` keys and all predicate pairs;
  existing bytes are unchanged.
- `pair_key/1` must decode the bytes with `quod_client_goal:decode/1`, which
  allocates nothing, and check: execute mode, canonical agent blob equal to
  `Agent`, operation id equal to `Id`, `Timestamp > not_after_ms`, positive
  height and time, and the request size bound. `at_height/2` must add
  `PrefixHeight =< Height` for the new kind. `kind/1` returns a distinct kind.
- The dependency is evidence, not a reservation: it must stay out of atomic
  reservation keys exactly like the positive kind.
- The validator recomputes everything from the index and the bytes; the
  token is matched, never believed.

## 6. Required

R1. Absence through P only, with rows above P ignored for the verdict and
the result a pure function of the retained index at or below P.

R2. A row at or before P with a different digest yields a conflict result,
not expiry and not unavailable.

R3. Context extension as in section 3, including `requires_network_identity`
over read checks and the fail-closed `validate/2`.

R4. Time row written only at the ordered `advance_applied` boundary, with
monotonic validation, and floor-gated reads.

R5. Negative answer only after the read-set entry has been absorbed; every
unavailable, unready, lagging or storage case keeps the live-bridge veto.

R6. Evidence additions to the candidate's list: validation of the same
block before and after a reopen that retained a different-digest future
row; an unsigned application transaction carrying the key waits for network
identity rather than validating against `none`; an era boundary with the
expiry straddling it.

## 7. Noted

The signature-free `committed_operation_outcome/2` already exists in the
live `quod_runtime_predicates`, registered as a committed-snapshot query
with the live-bridge veto on unavailability. It is not in this manifest and
was not reviewed here; the negative branch would extend it, not add a
sibling.

## 8. Unverified

That `eng_new/3` passes the certified tip timestamp as the new era's root
timestamp (`quod_simplex.erl:923`), which the monotonicity step across eras
depends on. The on-disk growth rate of per-height rows for long histories.

## Bounded consultation, final response

### 1. Re-weighing against the documented trust posture

The parent's evidence holds and changes my characterization. `src/quod_relay.erl:4-7` states that consensus payloads keep the trusted-committee atom posture, and `:28` decodes the inner consensus term with an unrestricted `binary_to_term/1` before any strict decoder runs; only relay metadata uses `[safe]` (`:106`, `:115`). The HEAD copy carries the same header and the same call, so this predates the refactor. Any admitted peer could therefore always make an honest node allocate arbitrary atoms at the frame boundary, before `materialize_symbols/1` or its old 512 quota were reached. The quota never protected honest nodes from a faulty admitted peer; its real content was the per-envelope consistency contract whose warm-founder versus cold-reader inconsistency the refactor removed. `doc/outdated/distributed-proof-plan.md:1026-1031` already states that committees verify author, transcript, OCC tokens, shape, encoding limits and phase rules and do not claim Byzantine-correct semantic execution by a malicious validator.

So I withdraw the "trust-model regression" label from my review-02 report. The accurate statement is: material admission is proposer-side policy, consistent among honest participants because the sealed plan carries the policy reads and validators enforce them through OCC, and its only exposure is to a faulty admitted node, which sits inside the documented boundary and is already exposed at the frame level. Validator-side admission would not create a new guarantee. It would be consensus ingress hardening, and it would only be meaningful together with hardening the frame decode itself. That is a separate decision, not part of the authorized shared-admission refactor, and I do not recommend folding it into this release.

### 2. The seams, for the record

Fresh material becomes atoms at exactly these points in the current source; `quod_relay.erl`, `quod_commit_validation.erl` and `quod_transaction.erl` are identical in the review-02 freeze, the frozen04 tree and the live tree.

- Lane 1, one writer: validators decode proposals materialized at `quod_relay.erl:56-57` through the one-argument `quod_ledger:decode_block/1` (`src/quod_ledger.erl:198-199`); the leader decodes relayed submissions materialized at `src/quod_simplex.erl:14527-14533` through `quod_transaction:decode_verified_submission/2` (`src/quod_transaction.erl:1331-1340`). Both happen before `content/4` runs in check mode (`src/quod_prolog.erl:7461-7465`), and the same decoded block becomes the committed entry (`src/quod_simplex.erl:552`).
- Lane 2, atomic: plans stay opaque until `quod_commit_validation:materialize_prepared_plan/1` (`src/quod_commit_validation.erl:758-759`), reached from `own_vote_choice`, `validate_prepared_plan`, `prepared_material` and `read_only_plan`. Allocation already waits for the validation owner here.
- Lane 3, independent: the claim decodes wrapped (`src/quod_transaction.erl:333-354`); allocation is `remote_application_material/3` at `:197`, reached from `remote_application_checked` (`src/quod_commit_validation.erl:454-456`) in both modes and from the endpoint's `decode_claimed_application` (`src/quod_simplex.erl:6436-6447`).
- Same posture, outside the lanes: `certified_block_bytes` decodes materialized at `quod_relay.erl:64-66` before `ingest_certified_block` checks the persisted certificate.
- Certified and local paths that stay policy free: own ledger replay (`src/quod_ledger_store.erl:161`), catch-up, which decodes wrapped, verifies certificates and only then materializes (`src/quod_catchup.erl:454`, `:747`, `:993`, `:1038`), foreign caches, the recovery endpoint, own sealed plans and admitted founding input.

If hardening is ever authorized, the smallest coherent shape is unchanged from my previous message: make `quod_commit_validation` the single materialization point keyed by its existing mode (`src/quod_commit_validation.erl:9-12`), decode proposals, certified blocks and relayed submissions wrapped, and share one `quod_dtx` measurement between `admit_core` (`src/quod_dtx.erl:309-333`) and validation. It belongs in a deferred-decisions record with the posture citation, not in this scope.

### 3. Self-lock: what frozen04 settles

The frozen04 sealer matches the distinction I drew. `validate_update/4` (`src/quod_material_admission.erl:20-33`, identical in frozen04 and live) refuses a plan whose diff touches any predicate in the selected policy's captured dependencies, helper predicates included, unless the resulting state still selects valid limits; the sealer calls it at `src/quod_dtx.erl:198-208`. Its reads are deliberately not OCC tokens, which is right: admission belongs to the published parent policy. Malformed policy is treated as a structural invariant, the same class as `policy_self_seal_forbidden` for an entry policy with no clauses (`src/quod_diff.erl:149-158`, `:353-358`). Zero allowances remain valid, the same class as a `can_invoke/4` clause that denies everyone. No recovery budget is invented and no authority is bypassed. This closes the lockout defect I reported for honest proposers.

Two small notes, neither a defect:

- `validate_update(plan, ...)` selects only the `plan` kind, so a root plan that leaves the `founding` rows malformed is not refused. That is not a lockout: root's plan lane stays valid, so root can repair it, and creation is merely refused with `invalid_material_policy` until then. Validating both kinds when their dependencies are touched would be a one-line completion if wanted.
- Validator and apply parity for the malformed-policy invariant stays proposer-only, consistent with the posture above. If parity is ever wanted, the seam is `validate_prepared_candidate` (`src/quod_commit_validation.erl:792-798`) and `apply_ordinary_transaction` (`src/quod_committed_projection.erl:290-306`), reusing `validate_update/4` with a distinct `invalid_material_policy` reason added to `remote_rejection_reason`.

### 4. Decision summary

- No architectural decision is needed to ship the authorized refactor as frozen in frozen04: admission is proposer-side, honest-consistent through OCC, and the trust boundary is unchanged.
- Validator-side material admission and the frame-decode posture are one deferred decision, outside the authorized feature. Record it rather than implement it now.
- Recommended documentation line, in `doc/multiwrite-architecture.md` next to the admission paragraph: material admission is enforced by the sealing proposer under the trusted-validator execution boundary; validators enforce the sealed policy reads, encoding bounds and VM headroom. That sentence would have prevented my own mis-weighing.

I did not run anything; the gates for frozen04 are the parent's evidence.

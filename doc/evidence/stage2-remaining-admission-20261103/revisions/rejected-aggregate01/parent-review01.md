# Parent review of remaining proposal

Preparation only. Production source remains the frozen `applied-carrier02` slice. This review does not authorize applying the remaining proposal or changing dependency pins/storage format.

## Required correction

The initial `proposals/remaining-owners.patch` changes `quod_catchup:transfer_page/2` to drain the entire selected history and always return `done`, while range selection grows to the snapshot tip. This discards existing page continuation for the producer. A history composed of individually representable frames can then exceed one complete frame and fail to synchronize; ordinary acquisition also materializes the entire selection before delivery. Preserve the existing cursor, lookahead, grant and continuation lifecycle while removing arbitrary quotas. Frame accounting must include the complete envelope. An actual unrepresentable frame must retain its specific failure attribution rather than becoming generic `server_error`.

This is a source finding on an unapplied proposal, not an observed regression in the applied worktree. Sent to the implementation child for revision before approval.

Existing obligations are concrete: `era_paged_transfer_verifies_once_then_appends_the_complete_staged_group_test_` checks partial groups cannot install, continuation preserves the verifier and complete finality survives restart; `era_server_continuation_retains_one_reader_and_rejects_stale_or_foreign_tokens_test` checks one captured reader, token/source binding and retirement; `era_server_idle_continuation_expires_at_its_original_deadline_test` checks the original deadline. Former quota-based fixture sizes may change, but these obligations must remain covered.

## Evidence qualifications

- `remaining-effect04` constructs its actor with `quod_agent_ref:from_text/4`, uses short namespaces, validates the singleton effect, and reaches `{error,{too_large,effects}}` in the real `quod_dtx:encode_material/5` owner. This isolates the byte quota from the malformed actors in earlier fixtures and the long namespace in effect03. Earlier failures remain retained.
- The queue baseline calls the real pure ingress owner 65 times with one fixture transaction. It demonstrates the per-author queue counter refusal; it does not demonstrate 65 distinct signed admissions through consensus.
- The namespace baseline demonstrates an already shape-admitted 192-byte name failing the current base64 directory representation. Supporting arbitrary admitted names requires a storage-format decision. No migration, cleanup or silent fallback is authorized by this review.
- The proposed atom headroom check is not an atomic reservation against every allocator in the Erlang VM. It must not be represented as a complete memory-safety guarantee. Actual atom representation constraints are separate from the removed vocabulary budgets.
- Proposed Erlog changes require the actual dependency workflow; an edited build checkout is not a delivered pinned dependency correction.

The proposal compiler checks source syntax only. It neither installs nor executes the proposed modules and is not runtime acceptance.

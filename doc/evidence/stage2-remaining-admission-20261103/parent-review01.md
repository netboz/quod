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

## Namespace preservation and representation follow-up

The namespace format proposal must cover read-only outcomes as well as writer opens. `quod_outcome:lookup_live/3` derives a path directly for stopped ontologies. `quod_foreign_log:load_history_dir/2` currently returns plain `error` for a directory/key mismatch, which startup silently skips: changing `ns_dir/2` alone would hide valid old caches. Both require explicit old-layout refusal.

`quod_simplex:init_store/3` opens the ledger root before restoring the signing journal from the separately configurable data root. Both roots must be checked before mutation, so an old signing journal cannot be discovered only after a replacement ledger has been created.

Two existing ETS name constructors also concatenate the raw namespace before allocating an atom: `quod_simplex:genesis_table_name/1` and `quod_feed:digest_table_name/1`. Removing namespace quotas alone would expose the VM's atom-name representation limit there. Preserve the existing owners/readers and derive representable table names; do not add a new registry. These are source findings, not runtime acceptance.

The parent has directed preparation of the concrete namespace format/refusal proposal and its tests, without migration, user-store access, deployment or production application. The authentication-table and opening-link-buffer population ceilings and two-endpoint restriction are also part of consolidated preparation; actual field widths and existing deadlines remain distinct.

The first namespace guard draft enumerates the entire root directory for each namespace check, including ordinary outcome reads and each manifest in startup. This introduces population-dependent repeated work (quadratic catalogue enumeration at startup). Review requires checking the exact legacy path, or reusing the real startup owner's existing listing, without a new mutable cache. The draft also accidentally inserted type-union syntax into unrelated executable outcome-error clauses through an overly broad text replacement; those clauses and their irrelevant specification changes must be corrected before the conditional overlay can compile. Neither draft was installed or executed.

## Confirmed compiler input mismatch

`parent-include-resolution01` runs only Erlang preprocessing on immutable `proposal-compile07` source. True child exit0 and both EOF are recorded; no proposed module was loaded or executed. With the existing Erlog application on the code path and the snapshot header directory supplied as an include path, Quod's `include_lib("erlog/src/erlog_int.hrl")` resolves to the old installed header (12 `est` fields), while proposed `erlog_int`'s local include resolves to the new snapshot header (10 fields). The full resolved include paths and record forms are retained in the log.

The proposal compiler's Docker recipe likewise selects the old Erlog application under `/work`; merely copying and hashing the new header does not prove it was used. Earlier successful compilation therefore cannot establish a coordinated record layout. Bind isolated proposed application metadata for include resolution, verify both consumers' resolved record forms, and compile the normal production and test configurations before claiming that compatibility. This finding concerns validation provenance; the mismatched beams were not installed or executed.

## Final source-review disposition

The revised proposal addresses the findings above: streaming includes terminal-frame lookahead; namespace checks use the exact legacy path; both configured roots are preflighted; stopped outcomes and retained caches refuse the old layout; existing namespace-derived ETS names use the shared representable key. The source and test replacements also cover the final proof/scope-worker defaults, authentication tables and outbox ceilings. The independent same-event membership/batch-seal fixture preserves the drain re-evaluation obligation instead of claiming that the renamed all-collect case does so.

The compiler now observes the proposed header and checks matching Quod/Erlog record forms. `proposal-production04` and `proposal-compile13` both record true exit0 and both EOF for the corrected final module; preceding complete overlay checks and unchanged input hashes remain separately labelled. `proposal-compile11` and12 failures remain failures. This is compilation and source review, not runtime acceptance. `production-unchanged-final02` records no production change or proposal-preimage mismatch.

Reviewed patch SHA256 values:

- `remaining-owners.patch`: `20df667750c420a6a3f95600531cca6c025b964ac39fe5197a75d07b69807ea3`
- `namespace-admission-CONDITIONAL.patch`: `c901aa315e1a06d312021c6764412bfa2bbb026d0a49e8ec6c254a4386d3b235`
- `erlog-diagnostics.patch`: `365222a87f7bce76d6c51e3de92656be805b60bb937f2bb76dc28b7dd33e1eb3`

No remaining blocking source finding from this parent review. Broader application authorization, coordinated dependency delivery, runtime tests and the existing signed renewal-performance failure remain open. No approval, migration, deployment, commit or whole-task completion is implied.

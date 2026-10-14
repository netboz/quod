# Shared-workspace cleanup

Yan requested cleanup after client acceptance work expanded into concurrent server changes.

## Scope

The unfinished, undeployed external-predicate-selection experiment has been removed from runtime source. Its exact patch and file hashes are retained here; complete before/after snapshots are retained at `/tmp/quod-movement-cleanup-20261009-01`. No ledger, network identity, deployed server, account or browser profile is changed by this cleanup.

The experiment touched ten source/test files. Three overlap the failure-reasons follow-up: `src/quod_predicates.erl`, `src/quod_prolog.erl`, `src/quod_erlog_db_local_prove.erl`. The cleaned result for each is byte-identical to that owner's `release-05/commit-owned` bytes. Only the added configuration block is removed from shared `priv/ontologies/common_predicates.pl`; the ontology-inspection feature is retained.

## Preserved work and owners

- Failure reasons: session `d4e7f432-f4dd-45be-97e3-9545e2c90b92`, continuing stopped parent `769410b1-49a8-4b17-8c2d-6e36436db24f`. Its failure-taxonomy changes and frozen release evidence remain owned by that session.
- Ontology inspection: session `e2890529-4e4f-4618-9e54-2dcd54aa8b8c`. Its source-chunk feature, policies, lenses, editor and deployed .254 baseline are preserved.
- Native client: session `4cd508b0-4546-43b7-ac89-3c2327d4215f`. Its client-only implementation and evidence are preserved.
- Movement: session `58fae0ee-a4fe-403a-a9e9-152ded57c07f`. Already committed movement foundations, WebXR tools, plans and evidence are preserved.
- GUI planning artifacts and unattributed changes are preserved.

These groupings describe ownership, not approval to commit or deploy all remaining changes.

## Retained experiment diagnostics

- dev-01: 64 tests passed before later experiment changes.
- dev-02: 66 tests, two failures (unsupported retractall).
- dev-03: one failure and three cancelled tests, including timeout.
- dev-04: compile failed (unquoted reserved Erlang atom).
- dev-05: one failure and three cancelled tests, including timeout; true command exit 1.

None of these diagnostics establishes acceptance in the live lobby or on the Vive. Current lobby movement and intended-hardware acceptance remain open.

## Status

Removal completed after the failure-reasons owner confirmed staging inactive and held the shared files. The three shared files match its frozen task-only bytes. Twenty-six other failure-owned files were unchanged by removal, including the existing source-chunk baseline and the owner's later singleton correction. Five selection-only tracked files match HEAD again; the configuration block and experimental test were removed, with all removed source retained in `experiment.patch`. The stale compiled experimental test was moved out of the test build to ignored `client/_build/cleanup-20261009`.

`git diff --check` passed. A search of source, ontologies and tests found no remaining experimental selection symbols. No new builds, behavioral tests, reviews, commits, deployments or domain writes were started for this cleanup. Runtime acceptance remains open; structural restoration is not a claim of movement acceptance.

Two cleanup commands encountered quota failures: a sandbox mount setup and copying the stale binary into `/tmp`. Both are recorded in the receipt. The binary was subsequently archived by same-filesystem rename, without deleting source or failed-run evidence.

`remaining-files.json` groups the retained dirty files and records their hashes. The checkout intentionally still contains the other sessions' uncommitted work. Commit/deployment are held; the latest failure-reasons correction must be qualified in its owner's exact frozen tree, separately from the already deployed inspection baseline. No other session's changes were reverted.

Further client validation should remain read-only against the deployed server. Any demonstrated missing server capability needs its own explicit architecture contract and one server-editing owner before implementation resumes.

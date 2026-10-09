# Workspace consolidation — 2026-10-09

The checkout is reconciled and recoverable. Yan subsequently authorized committing
the qualified inspection and failure-handling scopes in that order. Inspection
is committed as `465ad808a1165607be76145868a3e1528fc5c1a9`; this evidence accompanies
the following failure-handling commit. See [inspection-commit.json](inspection-commit.json)
for the committed manifest and verified restoration of the full qualified bytes.
This is not a declaration that player movement acceptance is complete. No
deployment, ontology write, runtime feature change or new review was performed
during consolidation or commit preparation.

Yan assigned session `58fae0ee-a4fe-403a-a9e9-152ded57c07f` as the consolidation
owner. The other implementation sessions were instructed to pause shared edits,
staging and deployment. The failure-reasons owner explicitly confirmed its pause,
empty staging area and absence of running validation drivers in its tracker
handoff. Keep a single writer through commit/deployment. Do not resume an old
session merely because its implementation was preserved here.

## What is preserved and qualified

- The original movement and hot-controls foundation is already committed at
  `61ce04b`. Current HEAD is `3970f5ff0b6f1c38845eacf9e0a944067881551b`.
- The source-inspection implementation was deployed as .254 and is now committed
  as `465ad808`. Its exact source manifest, original validation and deployment
  evidence remain in [ontology-source](../ontology-source/README.md).
- Failure handling is reviewed and qualified; deployment remains outstanding.
  All 34 owned live files match `release-10-final/tree`. Its source manifest is
  identical to reviewed release-08 and release-09. The preserved
  [qualification](failure-reasons/qualification.json) records 3,805 passing EUnit
  tests, 146 passing Common Tests, native tests/clippy, client tests, UI build/lint,
  xref, Dialyzer and production release assembly.
- Those checks span two explicitly labeled campaigns: release-09 passed the
  first nine gates, then hit storage quota during the final production gate;
  release-10-final passed a fresh production assembly with identical source and
  browser hashes. There is **no single-full-campaign pass claim**. Original
  failures, empty receipts, child exits and full gate logs are preserved in
  [campaign-receipts.tar.gz](failure-reasons/campaign-receipts.tar.gz).
- The browser package now contains the exact 176 files from that qualified
  release, checked by SHA-256. Before replacement, all old files were verified
  against the inspection manifest and archived. Only superseded generated files
  were removed. See [asset reconciliation](asset-reconciliation.json).
- The external-predicate-selection experiment remains removed, undeployed and
  recoverable in [cleanup evidence](../player-movement/cleanup-20261009/README.md).
  It is not an accepted architecture or a prerequisite silently restored here.
- Native Godot, Linux WebXR diagnostics and GUI planning remain separate,
  preserved workstreams. Their presence in the checkout does not qualify them
  for the server release or establish hardware acceptance.

## Architecture assessment

The retained source-inspection and failure-handling changes follow the ownership
direction in [AGENTS.md](../../../AGENTS.md), [world.md](../../world.md) and
[multiwrite-architecture.md](../../multiwrite-architecture.md). Inspection keeps
access and lens policy in Prolog and reads the existing signed, retained snapshot.
The external primitive formats source; it does not maintain a second source
inventory or knowledge base. Existing production-seam evidence checks retained
reads rather than recreating history or disk indexes for each continuation.

Failure handling uses the existing proof/error and transaction finalization
paths. Valid Prolog denial and bound-output mismatch remain ordinary failure;
malformed required arguments use errors; definite runtime refusal carries a
reason. An uncertain transient outcome still suspends control and is not
resubmitted as a new operation. No new domain process, simulation authority,
Erlang policy budget or lobby-specific execution branch was added by these
changes. The existing Fable review is retained as evidence; this consolidation
also independently checked the code and contracts.

One narrow integration inconsistency remains: the preserved source-chunk
primitive uses ordinary failure for malformed size arguments. Its correction is
tracked separately below; valid ontology-authored inspection requests are not
known broken. The reviewed candidate was not modified to conceal that gap.

Movement is a separate incomplete integration. Existing lobby source lacks the
authored physical/control definitions and appropriate founded bridge, and the
ordinary client view does not yet connect the existing simulation protocol.
Resolve that through existing ontology composition, lifecycle, action and
recovery owners before proposing a capability extension. Keep agent shape and
camera position/orientation ontology-defined. Explicit physical geometry must
support the intended noncubic world/chunk shapes; visual meshes and picking
bounds must not become collision authority. Do not refound the lobby or use a
disposable scene to claim acceptance.

## Exact boundaries for subsequent commits

The following source patches were applied sequentially to copies of the HEAD
files, with `git apply --check` before each application. The resulting 63 source
paths match the live checkout byte-for-byte. The real checkout/index was not
temporarily replaced or staged. See [source reconciliation](source-reconciliation.json).

1. [Inspection source](01-inspection-source.patch): 29 changed paths, using the
   original qualified inspection bytes. Its generated baseline is identified by
   [assets-before.json](assets-before.json). Include its existing inspection
   evidence when preparing that commit; do not include GUI or native work.
2. [Failure-handling source](02-failure-reasons-source.patch): 34 changed paths
   applied **after** inspection. Only `quod_ask.erl` and
   `quod_common_primitives.erl` overlap the inspection source manifest. The patch
   preserves those earlier hunks. Its generated package is identified by
   [assets-qualified.json](assets-qualified.json), already installed locally.
3. Consolidation/movement evidence and Linux WebXR diagnostics remain distinct
   from server source. Review the diagnostic artifacts before any tooling commit;
   screenshots or stereo fixtures do not close movement acceptance.
4. Native client source/evidence remains parked for its own qualification and
   commit. GUI plan/mockup/reviews, including the `doc/README.md` link, belong to
   the separate GUI planning scope.

The source patches intentionally exclude generated assets and other evidence;
they are not complete release commits by themselves. Recoverable baseline source
is in [inspection-source-baseline.tar.gz](inspection-source-baseline.tar.gz).
The qualified and task-only failure snapshots are in
[owned-source-snapshot.tar.gz](failure-reasons/owned-source-snapshot.tar.gz).
The original owner's task-only patch is retained under `failure-reasons/`; it is
not the same ordering as the two integration patches above. Do not apply both.

Commit proposals use Nimbalyst's atomic commit tool. The inspection staging window
restored all 63 source paths and all 176 qualified browser files byte-for-byte;
no unrelated working files were reset. Keep release label changes separate.
Deployment remains held; the commit authorization does not authorize a data reset
or claim deployed .254/.255 was replaced.

## Unfinished work and restart order

1. Finish the authorized inspection-then-failure commit sequence, preserving
   unrelated files. The first commit and restoration are verified above. Existing
   inspection/hot-controls trackers retain commit and deployment bookkeeping.
   Reuse exact-source receipts; a changed candidate requires validation of the
   actual delta. Deployment/live signed checks remain outstanding for failure
   handling.
2. [Existing-world integration follow-up](follow-ups/QUD.27.md): resolve the
   general architecture contract, then implement through normal ontology and
   client owners. The actual existing lobby is the first acceptance world.
3. Complete the original movement ticket's real desktop and separate physical
   Vive/WebXR acceptance. Preliminary headset pixels do not prove collisions,
   landing, tracked-head contact or reconnect behavior. Keep that ticket open.
4. [Optional native-client qualification](follow-ups/QUD.28.md) stays parked;
   WebXR remains Yan's preferred client. OpenXR shutdown failures are retained.
5. [Naming timeout diagnosis](follow-ups/QUD.29.md) remains unresolved despite
   later exact-source success. Do not increase its timeout or erase the failure.
6. [Source-chunk argument contract](follow-ups/QUD.30.md) is a narrow future fix,
   separate from this frozen candidate.

The four new tracker items and local bodies exist. Collaborative body storage
failed on creation and one retry, so the complete descriptions are preserved in
`follow-ups/`. Existing movement, inspection and hot-controls tracker comments
were updated successfully. No completed-status claim was made for unfinished
movement or uncommitted work.

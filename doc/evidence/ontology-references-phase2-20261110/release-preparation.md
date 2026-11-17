# Phase 2 release preparation

Preparation only. No fleet inspection, signing, live edit, deployment, refound,
client installation or version bump is authorized or executed by this file.

The 36 `gui_asset(Digest, Mime, Bytes)` facts in `quod_gui.pl` hold 100,690
bytes. Each digest is the lowercase SHA-256 of its exact bytes. The corresponding
`gui_icon/2` facts retain the authored transfer and pixel allowances. The node
package no longer contains `priv/explorer/assets/icons`; Godot uses signed reads.

The existing 0.7.282 operator module `quod_source_release` now exposes
`terms(Namespace, Terms, DryRun)`. Supply the reviewed binary facts directly as
terms. A dry run returns the exact anchored transaction without executing it.
Execution uses the existing root proof/signing owner and target source-edit gate,
with one `assertz` per term in the same transaction. Normal target ACLs, material
policy, conflict checks and uncertain-outcome handling remain authoritative.
Do not resubmit an uncertain operation.

For activation, inspect the exact target and existing definitions under the
maintenance authority. Prepare the `gui_query/1` admission and binary facts,
and any reviewed `gui_icon/2` name/digest changes, as one ordinary transaction
using the existing source compiler and terms step. Preserve unrelated definitions
and refuse a changed baseline. No live baseline, signed request or successful
application is claimed here. The local test checks dry-run absence, refusal
without root source authority, and exact binary insertion with that authority.

After a separately authorized applied release, read back every exact binary
through a signed `quod:gui::gui_asset/3` request and verify all digests. Verify
that an icon change refreshes dependent views through existing subscriptions,
and that unchanged consumers reuse their verified digest with no additional
fetch. Retain the original operation, outcome and readback evidence in the
existing live-release evidence directory. Phase 1 still requires its prepared
cold coordinated activation before this client and ontology composition is used.

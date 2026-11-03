# Namespace admission and preservation proposal

Historical consolidated02 proposal state is preserved below. The later explicitly authorized application and current validation are recorded in [APPLIED-RESULTS.md](APPLIED-RESULTS.md).

The recommended format correction is concrete and unapplied. It is not a request
for Yan to design a filename algorithm. `namespace-admission-CONDITIONAL.patch`
builds on `remaining-owners.patch` and includes source, spec and test changes.

Current owners impose128-byte lifecycle and255-byte generic/client policies.
The retained real-owner baseline proves a192-byte namespace passes directory
shape but its raw-base64url filename fails `enametoolong`. Signed request raw
namespace and the separate ETF-encoded link channel each use a uint16 length;
these are distinct actual representations, not interchangeable policy quotas.

The shared `quod_ledger_store:namespace_key/1` derives `ns.` plus SHA256 hex from
the exact namespace. The dot makes the new component disjoint from the old
base64url alphabet. `ns_dir/2` remains a pure constructor; the same key makes the
existing Simplex genesis and feed digest ETS names representable. Namespace and
genesis remain in authenticated records and all existing identity checks. There
is no name registry, client reference change or reverse-lookup fallback.

`check_namespace_layout/2` checks the exact old path with `read_link_info`.
Existence, including a dangling symlink, refuses explicitly. `enoent` means
absent; `enametoolong` means this OS cannot represent the old raw-name path. All
other I/O failures remain explicit. It does not enumerate the root on every
lookup or introduce a replacement numeric quota. Store entry checks happen at
existing lifecycle boundaries; retained readers keep their handles.

The proposed preservation coverage is:

- Ledger mutable and read-only opens refuse legacy layout before file creation
  or scan. Simplex preflights **both** ledger_dir and data_dir before either
  mutable store opens, including the existing restoration test seam.
- Signing initialize/recover, outcome open and phase-index open/cleanup use the
  same check. Stopped `lookup_live` returns the layout error before it can report
  an old retained outcome missing.
- Foreign startup first inspects all retained manifests, then performs its
  existing projection cleanup and launches initialization. A valid legacy
  manifest cannot be silently ignored because its directory key changed.
  `ensure_manifest` also checks before creating new cache metadata. Projection
  storage remains under its existing root/projections owner; no new lifecycle.
- Existing tests propose no-write refusals with a journal only in the separate
  durable root, both layouts present, stopped outcomes and all store entry
  owners. A valid version7 foreign manifest and a projection marker verify that
  startup refuses before cleanup. Large1024-byte exact reopen and distinct-name
  cases use isolated fixture roots. Browser/native signed boundary checks retain
  exact UTF-8 bytes and checked uint16 refusal.

These tests compile; **none ran against the proposed runtime**. Compile receipts
bind actual inputs and the final proposed Erlog record header. Current runtime
and user stores are unchanged.

Format-code approval remains part of the consolidated review. Deployment and a
preservation/cutover procedure are separate authority: identify all configured
roots and exact namespace/genesis pairs; preserve ledger, signing duties,
outcomes, phase material and foreign manifests together; verify the new tree
before an explicitly authorized cutover. This packet performs no migration,
renaming, deletion, old/new operational fallback, replacement founding or
user-store access. It intentionally refuses old layout until a separately
approved preservation process has made the selected root coherent.

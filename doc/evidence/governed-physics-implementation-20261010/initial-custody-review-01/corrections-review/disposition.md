# Independent disposition

Fable accepted all four corrections and approved proceeding to final exact-tree
verification. The invocation used `claude-fable-5-1`, exited 0 and retained all
40 frozen input hashes unchanged. No implementation defect remains in its report.

Both required evidence points are adopted:

1. The corrected production inputs, all tests and the planned 0.7.258 label are
   frozen for a separate complete sequential gate campaign. The final commit's
   input bytes will be compared with that manifest before building/publishing.
   The earlier incomplete campaign is preserved as superseded, never passed.
2. The image publication driver now requires a real network-disabled container
   boot using the Nomad-rendered configuration and its actual prestart script.
   The probe verifies a ready root, a live vault child and provider `none`.
   Final release-version boot evidence is required before pushing that image.

The provisioning format deliberately requires mode 0600. It is an operator
creation contract; the vault remains more permissive of owner-only modes. The
cleanup trap is already armed before generation and stays armed through removal
of the temporary link. An uncatchable process or host failure can leave an extra
private temporary link; it grants no agent authority and does not replace the
stable unlock file. No key inventory or automatic deletion mechanism is added.

Remaining repeated positive-epoch checks express independent recovery-action and
policy restrictions and are cheap pure checks. Signing-policy changes remain
outside this custody slice, as agreed in the review. No additional compatibility
or migration path is introduced.

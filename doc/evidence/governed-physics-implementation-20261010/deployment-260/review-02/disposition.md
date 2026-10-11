# Final deployment review disposition

Fable returned conditional go after one operator correction and two preflight
checks. The application image and all job bodies remain unchanged.

The ingress bodies had already passed Nomad's server-side canonical parse;
registration still supplies additional defaults. The listed empty NodePool,
Identity, DiskMB, LogConfig.Enabled and service fields are present in the
packet, so strict post-registration dictionary equality was unsafe. The
operator now asks Nomad for a no-op plan against the accepted job and requires
the same JobModifyIndex and Diff.Type=None. A real no-op plan against candidate
version63 demonstrated this comparison. The lost-response observation uses
the same check, records any observation failure and never resubmits. The
pre-submission comparison still compares two server GET records at the exact
recorded index. The original script and manifest are preserved here.

Only mutate_once.py changed in the mutation manifest. The four candidate
bodies were not deleted or rewritten: their original exact bytes remain
frozen. correction-hashes.json binds the corrected operator and manifest.
Independent inspection confirmed the review's correction and original
operation handling; no second Fable verdict on the corrected bytes is claimed.

Both historical block URLs were fetched through the actual browser origin
on259 and matched the frozen human350 and world176 records exactly. The
revoke/restore goals pass the production parser. A signed read of their exact
anchor, principal, control selection and grant guards succeeded, proving the
adjacent binary escapes represent the intended identities. An initial read
had an expired authentication session; that definitive failure is retained,
and the separately labelled authenticated read passed. No grant was changed.

The optional installation deadline increase is not adopted. A timeout will
retain its evidence and require a separately labelled read-only observation,
never deletion of an earlier failure or extension of its deadline. Existing
root anchors, historical records and full node identities are checked. The
current jobs use host networking; the CNI teardown suggestion is inapplicable.

The live maintenance plan predicts only Stop8, with no failed placements or
warnings. Main and global ingress jobs remain excluded. This clears the
review conditions for the existing authorized candidate upgrade. It does not
close the feature ticket or explain the retained historical I/O observation.

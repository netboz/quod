# Fable review addendum 01: followup01 (format refusal and timestamp reason)

Reviewer: Claude Fable 5.1, 2026-10-13. Source reading only; no command run.
Basis: `followup01/manifest.json` and its four files diffed against the
reviewed `tree/`.

## Verdict

Both notes from the first report are resolved by the smallest possible
change. Nothing further.

## Checked

- **Format refusal.** The guard is now `Version =/= ?FORMAT` for any integer
  header, so a newer file (10) is closed and refused as
  `{unsupported_format, 10}` exactly like an older one, with no reset or
  deletion. The test runs the same byte-preservation fixture for versions 8
  and 10. The generic reset branch still handles only non-integer or
  malformed headers, which are corruption, not a recognised format. A
  same-format file with a different anchor still reaches that branch; that
  is unchanged pre-existing policy and outside this correction.
- **Timestamp reason.** A valid slot with a non-integer or out-of-range
  timestamp now returns `outcome_index_bad_timestamp` from its own clause,
  ahead of the catch-all gap clause; the test pins negative, float, atom and
  2^64. The new reason and the already-used `outcome_index_missing_timestamp`
  are added to the error type.
- **Doc.** The format sentence now says other integer versions, matching the
  code.

## Deployment note, as stated by the parent

Binaries already deployed carry the previous policy, under which a header
newer than their own format would be reset. Nothing here authorises a
deployment or a downgrade; that boundary needs its own authority.

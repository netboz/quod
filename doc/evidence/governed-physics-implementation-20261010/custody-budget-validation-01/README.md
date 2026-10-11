# Governed custody byte-budget validation

Scope 03 passed 172 focused EUnit tests and all 14 client test files. Source
hashes were unchanged during the run. Individual JavaScript case counts are
not inferred from the file-level reporter. Full command logs and true exits
are retained. The focused scope does not replace clean release gates or live
remote/desktop acceptance.

Scope 01: eight resource installation trace failures after the owner function
changed from arity 3 to 4. Corrected the actual trace arity and argument matcher;
no assertion was weakened. Scope 02: one new test used an unsupported arity-zero
abolish indicator; corrected its fixture helper to arity 1. Both failed scopes,
exact patches, stop markers and triage remain preserved.

Coverage includes committed root policy and ACLs, staged-policy rollback,
malformed/absent/duplicate/interrupted selection withdrawal and restoration,
byte-only durable changes, unchanged selection/configuration/history/I/O checks,
reservation/staging interleavings, post-stage tightening, large native and atomic
custody recovery, version-7 rejection, and signed single/atomic/independent byte
refusal with unchanged ledgers and no residual reservations. The ordinary full
agent/space/physics composition is created and recovered above the removed
256 KiB cap. This is generic fixture evidence, not real-client acceptance.

Production delta is +44 lines across the policy, existing owners and error
boundary: the second policy dimension, unavailable-policy withdrawal, durable
paired limits and typed client error replace the single count API and compiled
byte ceiling. There is no old/new compatibility path, new process or broker.

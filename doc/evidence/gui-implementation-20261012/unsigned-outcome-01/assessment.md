# Independent assessment

Accepted: exact-byte positive lookup uses the same SHA-256 digest and canonical
agent identity as ingress, requires matching scope, captures the existing immutable
dependency before mismatch/unification, and preserves unknown/error sealing veto.
The signed HTTP resolver and governed signing are unchanged. No Prolog /3 shim
or obsolete physics helper remains. Fable reviewed source only.

Gate03: 307 tests, zero failures, true exit0, 157.301s. Original failed gate01 and
fixture retained; corrected focused gate02 passed. Repeated reads retain their
existing real-owner no-I/O assertions. New tests cover altered network, key,
expiry, unparsed goal text, source anchor/namespace and read mode. Existing lower-
snapshot test covers unavailable evidence and monotonic veto. Optional additional
unknown-id example is not required to establish this unchanged owner behavior.

Reviewer note6 assumes random operation ids; the common request format only
requires a 32-byte id. GUI intent may derive correlation deterministically, so
confidentiality must rest on the containing ontology ACL, never id secrecy.
No new expiry outcome, recovery dispatch, data format or deployment is enabled.

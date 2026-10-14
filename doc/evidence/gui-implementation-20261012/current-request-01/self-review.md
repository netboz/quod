# Current signed request self-review

Implementing Codex agent's self-review, not a Claude review. Scope is the frozen
tree plus followup01, compared with before/. All actual callers were searched in
src/, priv/ontologies/ and test/; no arity2 implementation or live caller remains.

The physics-specific current_signed_request(Bytes, Signature) has been replaced
by common current_signed_request(Bytes). The original request binding is already
verified by ingress and every foreign scope owner. Matching canonical request
bytes to that digest is sufficient; re-verifying a separately retained signature
cannot add authority to the same executing proof. Unsigned contexts and different
bytes fail. The shared request_identity selector performs bounded atom-safe identity
decoding without goal execution. Reaction and policy contexts remain prohibited;
no live observation is introduced and no scope/proof owner's trust invariant changed.

Both physics activation/rest and hinged completion use the common check. Signature
custody in their request rows is unchanged because their other signing/resolution
owners still need it. Only unused binding names at the migrated checks changed.
The old exported physics predicate and registration were removed, without a shim.

Actual hosted ingress coverage retains the exact request bytes in a fact, consumes
them through the shared check and verifies returned signed evidence. A fresh request
for the same authored goal is rejected and cannot add another consequence. Existing
proof-context tests also reject changed expiry and trailing bytes, and an unsigned
proof cannot manufacture a matching request. The full physics and scope-session
suites provide regression coverage for the migrated owners.

Production delta: +31/-24, net7 lines including the hinged caller correction.
The new common guard is explicit about proof context and unsigned refusal, while
the redundant signature-specific implementation is removed. No new engine or
persistent state. No automatic GUI lifecycle or hardware completion is claimed.

The first focused gate found a test tuple syntax error (preserved source). The
first broad gate found the missed hinged caller, was stopped after diagnosis and
is not passing evidence. followup01 carries that correction; final gate/source
results are recorded separately in receipt.md. No review, commit or deployment
approval from Claude is asserted.

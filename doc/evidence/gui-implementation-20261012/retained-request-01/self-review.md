# Retained request implementation self-review

Implementing Codex agent's self-review; no Claude review claimed. Compared exact
before/ and tree/ owners against the accepted recovery-contract-02 disposition.
The later current-request-01 packet adds the shared proof check and migrates its
existing physics consumers; its final integration gate covers the combined tree.

use_agent_request/1 is reaction-only metadata on the existing matcher. It selects
canonical execute bytes, then compares their exact actor and ground goal with the
selected reaction. Metadata is ordinary bindings, so abandoned alternatives do
not retain preparation. It refuses node recovery and private physics metadata;
the physics custody prerequisite cannot be bypassed through the new selection.
The existing current guard cap and queue deadline are bounded by retained expiry.
They never rewrite that expiry. No signature, key access or submission occurs in
matching.

The same hosted actor queue and worker execute the selected goal. Normal requests
and retained requests share governed signing. The latter decodes its own fixed
fields, requires the current binding's exact key, and reuses the existing
agent_hosted/sign_agent_request read and ordinary ingress. No new queue, process,
store transaction or recovery executor. Timeout identity is selected before the
worker starts from the stored operation id and the already matched actor; a killed
worker cannot lose that correlation. The signed request retains its deadline even
if this live queue's execution budget is shorter.

Focused production tests cover byte-for-byte returned evidence, original operation
reference, changed-key refusal and forced worker timeout with the exact reference.
Metadata tests cover goal/actor mismatch, malformed bytes, context refusal,
backtracking and a shorter guard cap. Existing hosting, vault and physics callers
are included in the final integration gate. No automatic GUI completion or retry
is enabled by this primitive alone. GUI rules must use the actual submitted-row
assertion once; arbitrary repeated authored occurrences would still be separate
explicit dispatch instructions, not an engine-granted retry permission.

Production delta for this packet: +76/-8, net68 lines in existing owners. Additional
code is exact identity/goal selection and reuse of the one governed signer. The
vault test helper was subsequently isolated in a fresh measurement process after
a real cross-module trace contamination failure; this changes no production code
or no-I/O assertion. Its regression retains an unrelated caller trace and proves
it is neither counted nor consumed. A real changed vault write must still report
all required durability calls.

No blocking correctness finding in the primitive itself. Question intent storage,
retirement/recovery invalidation, live opening and headset acceptance remain work
in progress; they must not be inferred from passing agent tests.

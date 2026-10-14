# Signed request context review

Review the current_request_operation/1 delta only, in the frozen tree and changes.diff.
The GUI component test file includes the already-reviewed foundation; its new scope
is the first operation-identity checks in exercise/2. The scope session fixture
correction uses the production shared committed base for read-certificate tests;
it does not weaken certification.

Original verified signed request evidence supplies the operation reference. Root
proof and admitted cohosted/remote scopes expose it as proof_bound metadata. No
wire format, new request, request counter, custody, outcome or live-observation
rule changes. Reactions and validator policy contexts must not fabricate one.
Check authentication provenance, context restrictions, identity preservation and
any accidental authority or lifetime changes. Read AGENTS.md and relevant proof
and multiwrite specs. Review is consultative; write your report in this directory.
Do not edit production or tests and do not run commands or tests.

Verification: gate-01 failed (four test-fixture defects); gate-02 passed 54 tests,
0 failures, exit 0. Gate-03 passed the changed metadata tests but the full hosting
module has two EPERM socket failures; its full log is retained. Gate-04 reruns the
same second module set with local network permission and is still pending.

Opening, presentation and the question lifecycle are NOT implemented by this
slice. It only supplies the existing original operation identity to ordinary
ontology proofs. No claim of GUI completion or deployment.

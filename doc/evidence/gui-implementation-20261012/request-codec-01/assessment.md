# Independent assessment

Accepted: the shared codec replaces the signer's private conversion and retains
all existing scope, read-only and signing-policy checks. The new primitive only
constructs inert bytes and can be used inside material proofs. The production
signed-ingress and governed-vault tests establish byte equality and sealability.
Gate02: 57/0, exit0; gate01 EPERM cancellation retained.

Section 6 is confirmed by prior evidence: component-review-01/assessment.md C2
and fable-review-addendum-05.md explicitly record the binary/1 primitive and its
malformed-text fix. It predates this codec delta; there is one compiled definition.
The older base frozen tree predates that addendum. No missing-primitive window
is introduced by this change.

Optional additional malformed-instance cases do not block this change; shared
agent-reference parser coverage remains in place. The codec intentionally does
not validate goal syntax or expiry at construction, and grants no authority.
No automatic dispatch or negative-expiry classification is enabled.

The scoped production delta is +45/-23 lines (net +22), measured against the
prior frozen owners and the component correction delta03. Growth is the common
pure bridge/API; the signer's duplicate conversion was removed. The separate
source-notice fix adds five lines and replaces one argument, reusing retained
frontier state rather than adding a deduplication inventory.

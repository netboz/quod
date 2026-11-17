# Proof answer allocation

The old refusal was an Erlang allocation decision: `answer_disposition/1`
measured `external_size` against 65,536 and the scope codec repeated that limit.
The retained real selected-worker baseline fails with an 80,000-byte binding.
That number was not an intrinsic codec constraint.

The existing material selector now requires both `heap_bytes` and `answer_bytes`
for a proof. The authored bootstrap policy explicitly supplies `unlimited`, as
it already does for proof memory and canonical material. Ordinary authorized
`material_limit_override(proof, answer_bytes, Limit)` facts can select a finite
nonnegative allocation. There is no Erlang numeric default or environment
override. Missing, invalid or ambiguous committed selections fail closed.
This change does not rewrite any founded/live ontology.

The actual proof session selects once from its committed snapshot and retains
the allowance plus read dependencies. It admits each computed solution before
exposing it. The existing nested-answer consumer independently admits the
received solution before unification, using its own proof's policy. A remote
allowance grants no local allocation. Self-selection uses that same origin
proof owner. Internal committed-policy selectors keep their existing process-free
evaluation; recursively allocating their own policy would not establish an
independent committed authority.

The measured quantity is the deterministic canonical atom-safe answer payload,
not UTF-8 display length, heap occupancy or complete packet length. The signed
remote fixture's 80,000-byte binding occupies 80,041 canonical answer bytes.
Atom and opaque-symbol encodings measure identically. Refusal carries exact
resource, actual quantity and allowance through the signed read envelope and
HTTP error. The desktop Transport now preserves those fields in its message
without floating-point conversion or changing uncertain-operation handling.

Scope wire version 14 replaces the former answer allocation bound with the
existing complete carrier bound. Versions 1–13 are refused. Complete envelope,
transport-frame, safe-term decoding, client aggregate reply and durable-result
constraints remain separate. The codec still refuses payloads that cannot fit
their carrier; this is not a claim that those existing protocol capacities are
fundamental mathematical limits. No compatibility lane, multi-frame domain
transaction, write splitting or protocol deployment is introduced.

The scope envelope is derived from the existing operation-submission, DTX-body,
top-level-goal and fixed-metadata owners, with a compile-time requirement that
it fit below the 1 MiB transport frame. The current client result owner separately
limits aggregate read replies to 512 KiB, and the retained durable-result carrier
is 16 KiB. Those unchanged enclosing contracts can still refuse an answer or
result even when material policy allows it. Their allocation/format rationale
is not newly certified by this proof-answer correction.

Policy dependencies join existing sealing/OCC validation. A staged policy raise
cannot enlarge its own proof. A concurrent committed dependency change conflicts
through the original read set; accepted plan decoding does not re-admit history
against a later allowance. Existing access/incarnation guards and cancellation
retire the same continuations. No process, subscription inventory or executor
was added.

The focused real-owner checks include exact boundaries and zero, invalid and
ambiguous selections, pinned staged raise, OCC conflict, cancellation, bad
encoding and carrier refusal. Twenty unchanged invocations measure one material
selection and zero named history/projection rebuild/write/sync calls. The remote
signed case additionally changes the producer allowance through an ordinary
authorized action, observes the larger result through local and remote routes,
changes the receiver's allowance, and observes its independent refusal before
an ordinary explicitly intended restoring action. That case does not replay a
failed write.

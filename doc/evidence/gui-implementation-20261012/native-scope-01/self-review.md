# Independent review of native scope transport

Reviewed by the implementing Codex agent, not Claude. This slice is a private transport seam; GUI opening/native presentation is not yet enabled.

The helper uses existing scope authentication, route resolution, invocation, nested-call relay and cleanup. It is not registered as a Prolog selector. Its temporary context is read-only and independently owned, retaining the original authenticated principal, request bytes/digest/signature and absolute request bound. It selects only the exact node and anchor from confirmed routes; observers may serve this native scope but gain no plan signer. Normal material/read selector routing is unchanged. No new wire message, execute request, durable store or owner was added.

Scope workers retain the already verified authentication only for their lifetime. Constructor invariants bind it to the original digest and request binding. The private native helper additionally verifies the original signature before scope admission. Shared scope advancement preserves the prior early-error behavior; target replies retain ordinary cancellation/proxy accounting.

The native result must be consumed by actual private preparation/reconciliation and must never serve as an ordinary material ontology read dependency. A successful read alone establishes no GUI acceptance. Source code has no production GUI caller yet: the native action integration remains required.

Validation: gate04 EUnit131/0 true exit0 (ask, scope sessions, scope targets, declared actions and GUI questions). Gate06 real-node CT3/0 true exit0 proves exact observer selection, nested normal reads, no observer signing key, write refusal, wrong anchor and unchanged ordinary validator selection. Gate10 final GUI4/0 true exit0,10.752s, adds actual target-worker DOWN after caller death and deadline, with existing timeout races preserved. Repeated unchanged native reads use the existing no-I/O measurement. No hardware validation claimed.

Failures retained: gate02 fixture incorrectly expected observer signer (fixed before gate03). Gate05 had two nonexistent case names (corrected command gate06). Gate07 omitted governed test-beam installation. Gate08 used a nonexistent fixture cleanup API and contaminated later tests. Gate09 assumed only the parent timeout rather than the existing target scope_expired race. Separate assessments/frozen failing test sources are retained. No production change or weakened worker-lifetime checks was needed for those fixture corrections.

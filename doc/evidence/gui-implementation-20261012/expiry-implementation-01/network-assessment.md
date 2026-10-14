# Network-context review disposition

Accepted: capture the trusted immutable network reference in existing validation
context; acquire before ordinary content apply and in the shared decoded-plan
boundary; preserve check abstention, claim-mode root-ready wait and typed read
certificate unavailability. Never use outcome_error for network absence. It
means index failure and restarts the owner. Preserve membership exclusions and
pure diff/outcome validation with explicit trusted context.

The original report proposed adding wait inside
apply_remote_application. That lives inside apply_transactions, whose fold only
accepts ok/error and may already have applied an earlier transaction. A new wait
there cannot simply escape as if no work happened. The remote application record
already carries the own plan's read_check (quod_transaction:remote_application_material),
so the proposed requires_network_identity scan should acquire before the entire
batch. The captured context must then reach both second OCC paths.

Addendum01 accepts that correction. Independently verified: apply_transactions
has exactly one caller after successful content validation; both hosted and
foreign owners enter the shared projection. remote_application_checked verifies
the expected semantic id and the actual record's id before own-plan validation,
so stripping its read check cannot bypass pre-batch acquisition. No inner wait
will be added. Plan-only acquisitions should return context to reuse immutable
trust across a control batch, though this is not needed for the content invariant.
The safety question is resolved. The first implementation slice captures the
existing content/vote acquisition and preserves it in projection context; negative
read kinds and plan-specific acquisition remain to be implemented and tested.

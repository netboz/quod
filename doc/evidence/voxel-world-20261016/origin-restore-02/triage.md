The new recovery fixture failed during its initial activation, before it wrote
or restored a checkpoint. Its inherited 64-chunk policy could not admit the
125 chunks required by the existing conservative dynamic-body sweep at a
16.667 ms step. The resource worker correctly refused that selection.

The focused fixture uses a 1 ms step and zero gravity to isolate restoration
at a missing destination within its original allocation. Production admission
and the restore assertions remain unchanged. The native recovery test separately
covers unsupported-rest gravity with complete conservative sweep coverage.
The existing signed chair recovery regression passed in this run.

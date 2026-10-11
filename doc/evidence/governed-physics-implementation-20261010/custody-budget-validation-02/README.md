# Deadline and governing-scope correction

Focused scope 04 passed 173 EUnit tests and all 14 client test files, with true
child exits 0 and unchanged source hashes. It includes the prior governed
budget coverage and a deterministic post-selection deadline regression.

Scope probe 01 failed in the new test fixture before reaching its assertion:
Erlang requires the suspending process to resume its worker. Probe 02 used the
existing runtime-owned resume helper and reproduced the production defect:
a foreign ontology's expired resource request changed root journal limits
from `{7,500000}` to `unconfigured`.

The final correction routes expiry through the existing interrupted completion,
retains the conservative wake dependency for internal persistent selectors,
explicitly restricts withdrawal to root, and logs a failed withdrawal. It adds
no polling or new synchronization path. The failure and correction use real
runtime/journal owners, the original absolute deadline and existing sys
instrumentation. Earlier scope evidence is preserved, not replaced.

Fable correction review and the complete clean release gate remain separate
requirements. This local evidence does not establish remote or desktop acceptance.

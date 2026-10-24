# Diagnostic result

419 tests passed, one failed. Signed ingress, commit validation, atomic origin
and historical read-set golden checks now pass using the shared production
base and complete policy dependencies. Capacity parking fixtures now use the
shared encoding ceiling and preserve author ordering.

The remaining old compound Simplex test assumed a transaction could be valid
under its own canonical bound yet exceed the enclosing one-item block. The
common envelope sizing now guarantees the opposite. Replacing that payload
with an invalid fake transaction exercises earlier semantic rejection, not
the claimed block seam, and correctly did not produce the old expected reply.
Retire that obsolete segment; retain its pipeline parking/coalescing cases.
Oversized-material refusal remains covered by the shared ingress boundary
truth table, relay envelope rejection and transaction encoding limits.

The prior campaign's remaining unprinted failures still require the next full
verbose run. No claim is made that these 420 cases cover the entire suite.

# Focused admission result

The retained run exits 1: 130 tests, three failures. The new policy/refusal
tests, genesis boundaries, cold transaction/plan decoding and scope envelope
tests pass. The three failed DTX assertions expected the old absence of policy
reads, or a read count containing only the application dependency.

Inspection confirms the added dependencies are required: an origin claim now
depends on its committed admission policy and participates as a read scope when
another target writes. Update those assertions to require the policy reads and
their existing certified-read routing, while retaining the original outcome
read and lane checks. Do not remove the dependency to satisfy the old fixture.

The compiler also reports the old transaction test's unused `wire_list/1`
helper. Its only consumer was replaced by the valid cold-material round trip;
remove that helper. This run is not a passing gate and will not be overwritten.

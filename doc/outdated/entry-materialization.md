# Exact-entry materialization

The ledger codec owns one canonical entry/block envelope parser and one
transaction decoder. Full ingress, replay and apply materialize the whole
payload. Exact history readers select a unique item using bounded opaque
metadata, then authenticate that item's material. Controls retain their
whole-wave ordering check. No wire, ledger or journal format changes.

A point selection is a distinct private read-only value, not a full entry:
it cannot be encoded, appended or passed to the applier. It carries the
selected record, index, full block hash, certificate and original item count.
The item count preserves singleton genesis binding. Duplicate or missing
selection keys yield no record. Metadata selection grants no authority.

The shared certified-reference verifier checks index, slot, complete block
hash, record identity and historical committee/domain. All unselected bytes
remain covered by that hash. Each supplied finality proof is checked; honest
replicas may retain different quorum signature subsets. Implicit child
certificates keep the full child decoder and their existing eligibility rules.

Within transaction decoding, nested evidence has already crossed the same
authenticated decoder. Canonical reconstruction retains those exact evidence
bytes for that call rather than encoding and authenticating them again.
The authenticated claim view also retains the verified client claim, bound to
the exact request authentication and goal as well as the original bundle
inputs. Native encoders still validate the entire view against signed bytes;
changing a field cannot reuse another view's authentication.

Readers remain in their existing callers under the captured owner identity,
historical prefix and absolute deadline. A newly fetched page still undergoes
full verification and durable installation before its retained entry supplies
exact evidence. There is no cross-caller cache, sharing owner, timer or queue.

Measure full versus selected decoding separately from finality verification,
I/O and protocol time. Count signature calls and compare identical fixture
bytes; a reduction in authentication work is not an end-to-end latency claim.

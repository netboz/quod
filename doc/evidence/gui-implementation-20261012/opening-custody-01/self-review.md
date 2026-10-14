# Existing source custody at dispatch

The real remote preactivation crash regression passes with two new checks.
While the remote private effect is durably bound and source activation is held,
the source signing journal's unsigned missing-material row contains the exact
original request bytes and signature, with their SHA-256 digest. Its sequence is
still zero and no source Vote envelope exists. The existing agent-work custody
snapshot already includes that exact group for the authenticated agent. These
checks use the actual signing journal and asynchronous source-owner API.

The test then kills source Prolog and Simplex, observes that the caller does not
claim committed success, restarts, and observes certified abort plus retirement
of the remote effect. Neither the source fact nor the external ontology creation
is applied. Gate01: 1 Common Test case passed, true child exit0. Complete CT logs
are retained beside the command log. No production change was necessary.

This closes the narrower concern that an atomic native opening needs another
raw-request store before dispatch: build_and_register_group/admit_group reserves
source responsibility before binding private effects, then activation and foreign
Vote delivery follow. The compact group already carries the exact original
request. Before reservation, only the proof and provisional native preparation
exist; losing them has dispatched no material plan. After reservation, source
custody survives proof or hosted actor death through the existing protocol.

This does not claim a pre-proof hosted request is durable, that a caller always
receives its result, or that a new incarnation may retry. A lost caller observation
remains unknown and domain work must not manufacture another attempt. It also does
not prove GUI native preparation/release, which is still unimplemented. The test
uses a signed request through the same ingress as hosted execute, but does not
pretend to be a full hosted GUI opening test. Accepted-answer completion custody
remains the separate already-implemented retained-bytes transition.

Self-review only. No separate store, new source lane, queue, deadline extension,
transaction split or uncertain-write resubmission is needed for this boundary.

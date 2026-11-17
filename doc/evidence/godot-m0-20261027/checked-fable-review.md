# Checked Fable review

Yan authorized one post-implementation review. The [creation receipt](fable-session-created.json)
and [complete session result](fable-session-result.json) identify
`f88942ed-05f0-4674-8db3-1259feb25d99`, provider `claude-code`, model
`claude-code:fable`, read-only tools, no edited files and no pending question.
The [unaltered report](fable-review.md) includes the review's progress messages.
The exact [request](fable-review-request.md) points to immutable snapshot03,
whose `snapshot.json` SHA-256 is
`c2707706e34907cc63de3042c6ad21722ef1634039d9b1a73414bb9c088b17d9`.
The reviewer disclosed reading cached upstream packages outside that tree;
the writer independently checked the exact locked old/new source copies below.
No second review was requested or launched. Advice was checked against source.

## 1. Complete-frame depth mismatch: accepted and fixed

The sender admitted bindings with a structural depth counted from the binding
list, while the receiver counted the entire `{Inner, Hints}` frame. A nested
binding accepted by the wire-value owner could therefore be emitted and then
refused remotely. The [clean red regression](logs/review-depth-red-03.json)
exits1 with 23 passing tests and precisely the new boundary assertion failing.
Red01 also exposed missing helper paths; red02 stopped on a module-precedence
assertion before tests. Those failed harness receipts and full logs remain.

The [worker patch](inputs/worker-review-depth.patch) validates complete encoded
inner bytes through existing `quod_safe_term:validate_canonical/2` before
emission. Receiver limits, canonicality, fixed control shapes, correlation,
certification and deadlines are unchanged. Producer refusal uses the same
existing representation rule; no limit is raised and no policy cap is added.
The regression proves depth59 round-trips, and depth60/depth62 values accepted
by the bindings codec are refused before producing an undecodable frame.
[Green04](logs/review-depth-green-04.json) passes all24 endpoint tests, including
unknown-symbol safety and malformed/noncanonical/control-shape rejection.
[Exact source hashes](inputs/worker-review-depth-source.json) distinguish this
post-review correction from the earlier decoder patch. It changes no state
owner or shared-state lifecycle.

Campaign04 remains valid for its frozen pre-review tree. Campaign05 passed the
new codec regression but exposed the separate fixture issue recorded below.
The separately labeled clean campaign06 passes all five gates on the final
source, followed by release02. Its full results are recorded in the evidence
index and handoff. No old receipt is relabeled.

## 2. HTTP repair mechanism: accepted and corrected

The observed passive receiver with unlimited flow and no active stream was
correct. The earlier attribution to `active_n=1` was too narrow and incorrect.
The [source excerpts and full-source hashes](inputs/http-upstream-flow-mechanism.json)
show Cowboy2.12's `stream_next` only rearming in its queued-successor branch,
and selected Cowboy2.19's `stream_terminate` rearming even without a successor.
That difference directly addresses the retained terminal state. The writer
verified both exact qualified source copies, independently of the reviewer's
intermediate-version comparison. No claim about the first fixing release is
needed. The dependency selection and its real fixture checks remain valid.

The current provenance, evidence index and handoff now name this mechanism.
Snapshot03 and `superseded_inference_in_review_snapshot_03` retain the original
incorrect explanation. No code, deadline, assertion or retry changed for this
documentation correction.

## 3. Opaque rejection reason: traced, no demonstrated defect

This was explicitly a hypothesis. The production caller of
`quod_outcome:terminal/4` is
[committed projection](../../../src/quod_committed_projection.erl:361).
Ordinary rejection selects fixed `conflict_retry` or
`policy_self_seal_forbidden` at `apply_ordinary_transaction`. Remote rejection
passes the closed runtime-owned
[reason mapping](../../../src/quod_commit_validation.erl:509):
`signer_not_admitted`, `conflict_retry`, `policy_self_seal_forbidden`,
`invalid_membership`, `not_authorized`. The vocabulary is defined by runtime
code, rather than taken from a Prolog-authored failure symbol. This establishes
its owner; it does not claim mixed-version control-vocabulary compatibility.

The separate [submission-result mapping](../../../src/quod_prolog.erl:6433)
also selects fixed runtime atoms. A Prolog/operator error can be returned as a
local immediate error, but is not stored as an arbitrary atom in the certified
transaction outcome. Distributed abort reason stacks already have their own
wire-term representation. Keep `is_atom` and fixed-control refusal; no need to
broaden the rejection protocol for this unestablished path.

## 4. Private composed space source: accepted clarification

The [private composition contract](../../godot-foundation-contract.md#private-composition-and-disclosure)
now distinguishes the pinned space vocabulary/template owner from executable
schema/instance operations composed into actual storage. S owns the shared
recipe; U or selected foreign storage owns its local class and instance facts.
The S pin is not a class alias or a foreign constructor dispatch: existing
Stage1 explicitly requires local class code. Local/shared class references
retain their distinct owning namespace/anchor even when they use the same
authored source. M1a must verify source hashes/pins and ownership isolation,
without inventing another foundation or changing Stage1 semantics. This is a
contract clarification, not M1 implementation.

## Limits retained

The reviewer inspected receipts and source; it ran no tests. The writer's
post-review tests are separate. The reviewed snapshot has a local builder image
ID rather than a published repository digest. SIGKILL recovery does not prove
power-loss durability. Interactive desktop, automated XR and physical Vive are
unrun; Quest is not qualified. The17 Reset captures have a separate Node
encoder check; the exported probe verifies the original83. No integrated
seven-foundation journey or recursive physical delivery is claimed. Existing
imported CT outcome polling is retained provenance outside this codec change;
no runtime readiness loop was introduced. The reviewer's unavailable notifier
on its host does not establish delivery or failure of the writer's required
local stop notification, which is invoked separately before handoff.

The writer also closed the review's parser-copy evidence limit: all three exact
host originals were found by their previously recorded hashes and retained
beside the compiled-generated sources. The [post-review comparison](inputs/generated-dependencies-post-review-check.json)
contains each full hash, actual diff and retained original path. Removing only
`-file` annotations makes each pair byte-for-byte identical. This does not
replace current dependency hashes or claim the reviewer checked those copies.

## Subsequent independent fixture correction

The [post-review full campaign05](r1-gates-05-result.json) has one EUnit failure
among4,247 tests and leaves CT/xref/Dialyzer unrun. Its bootstrap result was
correct; an unchanged fixture assumed that concurrently spawned probe callbacks
arrive in spawn order. Both its source and the real foreign-log collector
matched the passing campaign04. The writer checked `current_evidence` through
`parallel_probes` and `start_current_probes`; each candidate runs in its own
linked monitored child, so spawn order cannot establish callback order.

The [test-only patch](inputs/worker-bootstrap-fixture.patch) preserves public
`current/3`, the original5,000ms deadline and every original result/order/count
assertion. Existing controlled delivery and a real collector-state trace now
prove Wrong's `{error,retry}` was processed before releasing Right's valid
proof. [Twenty repeats](logs/bootstrap-fixture-repeat-02.json) pass. The first
standalone compile missed an include library and ran no tests; both failed and
corrected compiler receipts remain. No runtime machinery, polling, sleep or
weaker assertion was added. Campaign06 freezes and verifies this final source.
This is the writer's checked correction after the one Fable review, without a
second consultation or any claim that Fable reviewed that later test patch.

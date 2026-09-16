# Multiwrite timing observations

## Boundaries and limits

| Observation | Meaning | Limit |
|---|---|---|
| `consensus.proposal_created` span | Local content/DTX proposal installed before broadcast; slot, parent, block hash and batch count | Point boundary, not queue residence |
| `consensus.proposed` event | A content proposal's per-waiter notification | Request-level event, not another proposal or consensus round |
| `quod.consensus.parent_request_queued` event | Parent-verdict request sent by the consensus owner | Send-to-verdict includes dispatch, work and scheduling; the event can be absent under an ended or unsampled ambient parent |
| `consensus.parent_verdict_received` span | Correlated content/DTX parent verdict accepted for processing | Verdict receipt, not commitment; stale/unmatched callbacks do not mark this boundary |
| `consensus.control_admission_decoded` owner event | Exact semantic control digest available in submit admission, before retention/signing | Admission begins between this callback's entry and the event; not network arrival or a proposal |
| `quod.operation.exact_evidence` span | Sufficient-capture reuse or exact-reference resolution | Capture reuse can be nearly instantaneous; this adds no recapture |
| `quod.operation.certificate_verify` span | Verification of a supplied operation certificate | Not verification of a newly collected certificate |
| `quod.dtx.quorum.collect` span | Quorum collection, including child launch, receive and cancellation | Wall duration, not CPU; its probes are children |

Proposal/verdict spans use the local proposal's existing parent and links.
They can outlive that parent without extending it. A relayed block without
caller ancestry uses the opt-in owner diagnostic context, including existing
asynchronous validation requests. No caller is invented, unsampled callers
keep their sampling decision, and no proof state or new trace carrier moves.

Opt-in owner-turn/step spans measure synchronous occupancy separately from
request traces. Their context never becomes ambient request context. Duration
includes descheduling; reductions are not CPU time. Deferred OTP actions,
internal event queues and time outside the callback are excluded. For target
admission-to-proposal, join the decoded control digest to its exact proposed
block. Report the interval bounded by callback entry and decoded admission;
do not substitute the later signature timestamp or mix clocks across hosts.

## Measurement method

Record effective sampling and sampled/recording flags; retain the independent
attempt-start denominator. Correlate atomic Vote/Resolve proposals, parent validation,
support/notarization, finality and durable boundaries by allocation, namespace,
slot and block hash. Use shared-block links instead of counting a batched block
as several rounds. Leave time before the first available boundary unassigned.

For independent writes, compare source claim, target application, exact
evidence, quorum collection and complete-vector notification. Inspect remote
proof opening separately. Report the first four concurrent requests separately
from the fifth request that follows one worker.

Do not infer queue residence from a long span, or idleness/dead code from
missing spans. O-A1/O-A2 apply: retain every expected coordinator, list excluded
identities and reasons, and exclude ambiguous timestamp ties or spans with
stored event drops from interval attribution. Cancelled children, ended-parent
events and retired-owner stages can remain missing; never fabricate closure
or silently shrink the denominator.

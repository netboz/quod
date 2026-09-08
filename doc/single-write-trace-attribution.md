# Single-write trace attribution

Status: base instrumentation deployed in 0.7.146; aggregate ledger-open scan
profiling deployed in 0.7.147. The temporary deep diagnostic hierarchy is
implemented for the next coordinated deployment before the retained/clean
ledger comparison.
Baseline: 0.7.145, HEAD `8fdd2d2`, retained N=4 development fleet.

## Why this work

The retained serial benchmark completed 100/100 writes, mean 4,088.90 ms;
the c=4 run completed 100/100, mean 6,794.27 ms. These are all-request means,
not success-only numbers. Their existing stage counters do not fully explain
the request wall time. No measured bottleneck percentage or improvement is
claimed by this instrumentation.

Tempo already holds a sampled serial write, trace
`7192b9e0076837ab83fa90a51792a898`: `quod.prolog.prove` lasts 4,116.19 ms,
while its source `quod.transaction` lasts 72.20 ms. The old trace contains
consensus and journal children but not the surrounding proof/result phases.
This is one sample, not a substitute for the benchmark distribution.

Raw benchmark and pre-change trace evidence are archived locally at
`/tmp/quod-h1-145.vPDphR`; deployment inventory at
`/tmp/quod-145-deploy.VuDrEi`. Tempo retention is finite: keep exported JSON
alongside the raw TSVs and driver stdout.

## Existing owners, explicit boundaries

| Span family | What its elapsed time covers |
|---|---|
| `quod.client.request` | Signed HTTP dispatch, including body admission and response formatting; not client-side network transit |
| `quod.client.http_body` → `json_decode` → `dispatch` → `response_encode` | Request-body delivery, JSON parsing, application dispatch, and response serialization as separate HTTP-owner costs |
| `quod.client.session_admission` / `decode_and_bind` / `gateway_signature_verify` | Browser-session admission, signed envelope decode/binding, and the gateway trust-boundary check |
| `quod.client.local_target_lookup` / `gateway_route_lookup` / `forward_attempt` | Local ownership decision, directory lookup, and the exact forwarded attempt including its result handoff |
| `quod.client.request_decode` / `request_crypto_verify` / `goal_decode` / `goal_materialize` / `target_execute` | Target-side trust-boundary decode, signature/network validation, atom-safe goal materialization, and entry into the one proof engine |
| `quod.prolog.public_proof` | Source engine request, admission/scheduling, worker and result handoff |
| `quod.prolog.prove` | Existing source proof worker lifetime |
| `quod.prolog.pin_origin` / `context_start` / `origin_scope_open` | Immutable origin identity lookup, proof-context allocation, and origin session allocation |
| `quod.prolog.authorization` → `agent_key_check` / `acl_check` | Signed-agent key verification and the ontology's ordinary `can_invoke` proof, kept below the one authorization owner |
| `quod.prolog.invocation` → `quod.proof_session.*` → `quod.erlog.*` | Session open/advance/publication, actual Erlog step, result interpretation, exposure guard, and binding materialization. External predicates such as `::` remain children of the Erlog step. |
| Remaining source proof children | Sealing, read certification, attestation, checkpoint/release, source claim and operation-result wait |
| `quod.outcome.admission` | Existing durable outcome-index admission before the transaction span starts |
| `quod.prolog.apply` | One execution of the shared committed-block reducer for the exact locally parked writes |
| `quod.outcome.flush` / `quod.mvcc.publish` | Outcome-index persistence versus publication of the committed state, inside the existing reducer |
| `quod.ask.open` / `quod.ask.stream_next` | Remote scope opening and actual answer wait (not merely invoke acknowledgement) |
| `quod.ask.directory_resolve` / `route_wait` / `verify_target_committee` | Directory read, event-driven route parking, and certified target-committee verification |
| `quod.ask.remote_scope_open` / `invoke_open_request` / `bind_answer` | Remote scope transport open, invocation request, and returned-variable unification against the retained caller goal |
| `quod.scope.authenticate` / scope invocation children | Target authentication and execution under the incoming request's trace context |
| `quod.scope.authentication_material` | Reuse or construction of the signed agent authentication material carried to a foreign scope |
| `quod.identity.certificate_collect` → route/build/open/collect children | Identity statement construction, route selection, signer opening, and quorum collection; no identity or peer value becomes a trace attribute |
| `quod.operation.recover` and children | Existing operation worker, claim evidence, application request, terminal outcome resolution and asynchronous source receipt |
| `quod.evidence.ledger_open` / `quod.evidence.read_at` | Existing full read-only ledger open versus the subsequent exact-slot read, distinguished as claim/application evidence |
| `quod.ledger.file_open` / `quod.ledger.index_scan` / `quod.ledger.read_at` | File-descriptor open, full integrity/index scan, and exact sparse-index read. The single scan span reports entry/byte counts and aggregate framing/decode time; it deliberately does not emit one span per historical entry. |
| `quod.dtx.endpoint.serve` / `quod.dtx.quorum.probe` | Existing target endpoint worker and parallel committee probes |
| `quod.foreign.current` → `owner_request` → `verification_worker` → `quod.foreign.<stage>` | The parked owner request crosses the gen_server and worker boundary with one context. Exclusive `owner_request` time identifies mailbox/park/wake delay; cache, ledger, projection, phase-index, page-fetch and quorum work are nested below the verifier. |
| `quod.ledger.append_batch` → `datasync` | Canonical entry encoding/write time (aggregate attributes) and the authoritative ledger durability barrier |
| `quod.proof_context.finalize` / `quod.proof_context.cleanup` | Proof-resource cleanup after the result is determined |

The HTTP carrier is extracted at the HTTP owner. It crosses the existing
proof request, scope opening and endpoint request as transient W3C metadata.
Callbacks attach and restore context; worker starts capture it explicitly.
Source operation projection takes ancestry from the exact transaction's
already-existing parked write, never from the engine's ambient context.
Replay cannot reconstruct a historical trace; late recovery has its own trace.

One block can release several requests. Its reducer span is emitted **once**,
parented to a recording participating request when one exists, with ordinary
SDK links to the other exact parked request spans. It does not repeat apply or
multiply its cost by the batch size. Without a live parked context, local
replay invents no request span; foreign publication can inherit its existing
certified-history worker context. Controls are not decoded again for tracing.
The append's existing `queued`/`proposed`/`append_result` events delimit queue,
batch and consensus time; the new reducer boundaries separate subsequent
mailbox delay, apply, outcome flush and publication. Transaction completion,
proof completion and HTTP completion bound the remaining result handoff.

Scope wire V11 and DTX endpoint V10 are clean transport breaks. Update all
nodes together after review; no old-shape branch. Transaction V13, canonical
block/entry V1 and ledger V5 are unchanged: no purge or re-found is required.
No authentication, certificate threshold, consensus, deadline, sampling
configuration, capacity policy, transaction result or retry behavior changes.
`quod_trace` remains the sole instrumentation boundary; no new exporter,
collector, polling process, verifier, cache, metric family or dashboard panel.
Grafana's existing Tempo Explore is the visualization.

## Measurement and acceptance

1. Verify real SDK parentage, unsampled-parent behavior, exception cleanup and
   unchanged request results. Verify ordinary remote scope traces across two
   actual Erlang nodes. Pin metadata-only codec round trips and old-shape
   rejection; no carrier may alter signed evidence or request correlation.
2. Run focused tests, then full sequential EUnit, ask CT, xref, dialyzer and
   diff-check. Review before committing consensus/DTX-touching instrumentation.
3. After the coordinated tracing deployment, submit a small set of fresh
   signed requests with sampled W3C traceparents; preserve IDs, TSVs, driver
   stdout and exported Tempo JSON. Do not resubmit uncertain operations.
   Use the existing load driver's opt-in `--trace`; its shared HTTP sender
   adds the header outside the signed body. Trace IDs are appended as TSV
   column 10 only in trace mode. No second driver or retry path is added.
4. Partition each source request using non-overlapping intervals on that
   source's clock. Use target spans to explain source waits, not as additional
   sequential costs. Do not sum sibling replica work or asynchronous receipts.
   Report means and residuals; marginal quantiles cannot be subtracted.
5. The H1 >=95% increase-in-means gate still requires comparable low/high
   fixtures. One complete trace is not that gate. No H2, finality or L2 work
   is included here.

### Exit condition for this latency diagnosis

For **both a local write and a one-hop remote write**, retain a per-request
partition from client submission to delivered result. Report each named
stage's mean and the residual: the sum of non-overlapping stages must explain
at least 95% of the all-request mean. Keep failed/pending requests and their
observed durations visible; a successful-only distribution is not this gate.
The driver's elapsed time is the client boundary; HTTP/server spans alone
cannot account for network transit or client work. Use durations and explicit
source-side event boundaries, not cross-node clock subtraction.

Classify each measured stage as required by the current protocol, configured
policy, avoidable overhead, or unresolved. "Required by the current protocol"
does not mean physically irreducible or immune to a later architectural
change. Once this table meets the attribution gate, open a bounded work item
for each demonstrated avoidable cost; do not extend the measurement campaign
for unrelated small costs. This diagnostic exit does not waive correctness,
the absolute latency/throughput gates, or H1's separate height-growth gate.

The published table and conclusions belong in this document, not exclusively
in `/tmp`; retain/export the supporting raw evidence before its temporary
location or Tempo retention expires. Keep the 0.7.145 lifecycle-fixed baseline
separate from the earlier run with pending replies. Do not compare across the
future finality re-found as though they were the same baseline.

The batching hypothesis remains a hypothesis. The source currently defaults
`batch_window_ms` to 25; existing `consensus.queued` and `consensus.proposed`
events expose actual leader waiting. Neither that default nor a prior local
mean explains the seconds outside the source transaction in the retained
remote trace. No immediate-proposal policy change is part of instrumentation.
The F1 implementation/specification work and carried small debts stay in
their existing plans; this trace cut does not start another design arc.

The code audit identifies repeated `open_ro` scans at the claim/application
evidence seam and current-origin-history verification at scope opening as
measurement candidates, not established causes. Resource-finalization calls
and verifier-worker cleanup also need their measured intervals. The traces
exist to distinguish these costs before choosing the architectural rewrite.

## Separate safety finding — not repaired by tracing

The audit reproduced a pre-existing live-result authentication discrepancy:
endpoint application-response correlation accepts the same inclusion evidence
with either `committed` or `rejected` status. The live operation worker forwards
that status, while terminal recovery uses the existing current-view outcome
verifier. Inclusion evidence does not itself authenticate an OCC outcome.
The isolated negative test is
`/tmp/quod-result-auth-audit.Z63tSQ/quod_result_auth_audit_tests.erl` and fails
at its intended assertion. This needs its own reviewed correction at the
shared result authority; tracing changes neither behavior nor authorization.
Do not describe the live-result security contract as closed in the meantime.

## Validation — 2026-09-08

The frozen source passes clean-build sequential EUnit **1704/0**,
`quod_ask_SUITE` **26/26**, `quod_quic_SUITE` **25/25**, xref, dialyzer and
`git diff --check`, all with exit 0. Client tests pass (four test files), and
rebuilt client assets match an independent fresh build byte-for-byte.
The live cross-node CT proves remote authentication/invocation parentage and
keeps the existing foreign-symbol-isolation assertion intact. The shared
apply tests prove single execution, correct request links, mixed sampling,
publication order, unchanged outcomes and no invented replay ancestry.

The gate archive `/tmp/quod-tracing-gates/GATES.md` retains the initial
failures and corrections, not just the green rerun: a partial root-fixture
setup leaked state; the initial tracing CT incorrectly crossed a
non-distributed peer boundary and loaded caller vocabulary on the target;
and an existing two-peer test's five-second wrapper was shorter than its
existing boot bounds. Test-owned lifecycle fixes correct these mechanisms;
no production deadline was changed. One intermediate two-gateway CT run also
timed out during its final observer-local status read after durable completion.
Its exact local error was not retained; the unchanged test passed subsequent
full runs, but that does not establish the intermittent cause as closed.

Review request: `/tmp/quod-tracing-gates/CLAUDE-REVIEW.md`. No live measurement
with this instrumentation has run yet. The retained 0.7.145 measurements above
remain the pre-instrumentation baseline, not a claimed performance gain.

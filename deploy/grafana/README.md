# quod observability — Prometheus + Grafana

quod exposes Prometheus metrics at `GET /metrics` on the node's `metrics_port`
(default `14568`, mapped to a dynamic host port by Nomad and registered as the
`quod-metrics` Consul service, tagged `prometheus`).

## Transaction traces (Tempo)

The Nomad deployment enables sampled OpenTelemetry traces and exports them to
the OTLP/HTTP endpoint configured by `otel_exporter_otlp_endpoint` (the qengho
default is `http://192.168.1.11:4318`, reachable from home and cloud
allocations). The qengho observability role runs Tempo beside Loki and
provisions it as Grafana's `Tempo` data source. In Grafana, open **Explore**,
select **Tempo**, and search for `quod.client.request` (signed HTTP request) or
`quod.prolog.public_proof` (source-engine admission through result handoff).
`quod.transaction` is one nested append, not the duration of a remote write.
The source trace separates authorization, ordinary remote invocation, sealing,
read certification, attestation, source claim, result wait and final cleanup.
Outcome admission, committed-block apply, outcome-index flush and state
publication are also separate intervals. A batched block has one apply span
linked to its participating requests, not one duplicate execution per trace.
Recovery workers and remote scope/endpoint workers explicitly retain the
request context across Erlang messages and QUIC; the target's transaction and
its consensus/journal/ledger spans remain on the same trace.

Production uses the `parentbased_traceidratio` sampler at 5%. A browser or
other caller may send a sampled W3C `traceparent` header to retain a specific
request end to end. Only `traceparent` and `tracestate` cross signed HTTP,
validator relay, scope-open and DTX endpoint boundaries. Trace context is
transient and is never included in signed transaction bytes, scope
authentication digests, blocks, or the ledger. No baggage, goals, bindings,
private keys, evidence blobs or arbitrary failure payloads are exported by these spans.

The existing `scripts/signed-goal-loadtest.mjs --trace` option creates a fresh
sampled traceparent for each measured request and records its trace ID in
stdout and TSV column 10, including failed requests. Without `--trace`, the
headers, TSV shape and deployment sampling behavior are unchanged. Add the
option to the same fixture command; do not replace the workload or retry it.

The scope V11 / DTX endpoint V10 tracing cut requires a coordinated node
update, not a rolling mixed-version fleet. It changes no ledger format and
requires no re-found. Until deployed, older nodes still have the partial trace
coverage described in [the attribution note](../../doc/single-write-trace-attribution.md).

An operation reconstructed after restart has no historical trace context; it
starts a new recovery trace with its existing public operation id. A recovery
already running when a late caller joins keeps its original parent. There is
no trace lookup cache and no invented ancestry. Source receipts may finish
after the HTTP response. Likewise, scope invocation spans may outlive the
opening span whose context they inherit. Use source-side critical-path spans
for per-request attribution: do not add nested spans, replicas' concurrent
work, or background receipts to HTTP latency. Cross-node clocks may be skewed;
use each span's own duration, not unchecked timestamp subtraction across nodes.

Quod JSON logs emitted inside active spans contain `otel_trace_id` and
`otel_span_id`. The provisioned data sources expose **View trace** links from
Loki results and **Logs for this span** from Tempo. Tracing is disabled by
default outside the Nomad deployment; enable it with standard `OTEL_*`
variables when running elsewhere.

Every series carries a constant **`node_id`** label — the node's stable identity
(`kp_<hex>`, the Ed25519 pubkey short form), so a fleet-wide Prometheus tells
nodes apart by identity rather than a volatile host:port. Per-namespace series
also carry a **`namespace`** label.

## Scrape config (Prometheus, Consul service discovery)

The Nomad job registers `quod-metrics` on every homogeneous `quod-node` allocation. Point
Prometheus at Consul and keep the `prometheus`-tagged instances:

```yaml
scrape_configs:
  - job_name: quod
    metrics_path: /metrics
    consul_sd_configs:
      - server: '192.168.1.10:8500'      # your consul address
        services: ['quod-metrics']
    relabel_configs:
      - source_labels: [__meta_consul_tags]
        regex: '.*,prometheus,.*'
        action: keep
      # node_id is already a metric label; keep the consul node name too if useful:
      - source_labels: [__meta_consul_node]
        target_label: consul_node
```

(Static targets work just as well: `static_configs: [{ targets: ['host:port', ...] }]`.)

## Import the dashboard

Grafana → **Dashboards → New → Import** → upload `quod-dashboard.json` (or paste
its contents) → select your Prometheus data source when prompted.

The dashboard has `$datasource`, `$node`, and `$namespace` template variables at
the top (all default to *All*); scope any panel to a single node or namespace
with them.

## Panels (what to look at)

| Row | Panel | Answers |
| --- | ----- | ------- |
| Overview | Nodes up · Consensus height | How many nodes are live; is any node lagging (slot vs applied)? |
| Consensus recovery | Finality watchdog · Recovery activity | Which phase the oldest unfinished block is in; whether a quorum is connected; are retries or outage pauses accumulating? |
| Transactions | Incoming rate · Commit & apply rate | Submit throughput; are commits/applies keeping up? |
| Transactions | **Processing time (submit → commit)** | p50/p95/p99 write latency (`quod_tx_commit_latency_ms`) |
| Transactions | Committed by author · Write size · In-flight | Who's writing; diff sizes; pending/parked (writes-not-committing symptom) |
| Transaction authentication | Signature check time · Invalid signatures | Ed25519 verification cost; whether corrupted or dishonest transaction input was rejected |
| Prolog execution & memory | Active queries · KB memory & retained history | Query saturation; ETS growth; whether frozen queries are temporarily retaining old data |
| Rejections & failures | Append rejections by reason · Failed writes | Overload/wrong or closed target slot/skip vs OCC conflicts and request timeouts |
| Signed remote operations | Client-visible uncertain write outcomes | Which target or gateway boundary returned `pending`; the matching warning log carries its exact cause and stable reference. |
| Dissemination feed | Feed activity · Dropped blocks | Gossip push/ingest/pull health; gap-drop bursts |
| Brahms overlay | View/sample/links · estimated population N | Overlay connectivity plus each node's bounded estimate of total live population |
| Runtime P tier | Runtime · Ontology subscriptions and certified follows | Whether local projections are healthy; counts of compiled `subscribes/2`, authorized `react_on/3`, source interests, per-runtime source-view states, and node-wide shared follower health. |

## Metric reference

See the `quod_metrics` module doc (`-moduledoc`) for the full metric list, types,
and labels. Cumulative counts are exposed as gauges set to the running total —
wrap them in `rate()` / `increase()` (the dashboard already does).

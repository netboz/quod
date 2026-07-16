# quod observability — Prometheus + Grafana

quod exposes Prometheus metrics at `GET /metrics` on the node's `metrics_port`
(default `14568`, mapped to a dynamic host port by Nomad and registered as the
`quod-metrics` Consul service, tagged `prometheus`).

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
| Transactions | Incoming rate · Commit & apply rate | Submit throughput; are commits/applies keeping up? |
| Transactions | **Processing time (submit → commit)** | p50/p95/p99 write latency (`quod_tx_commit_latency_ms`) |
| Transactions | Committed by author · Write size · In-flight | Who's writing; diff sizes; pending/parked (writes-not-committing symptom) |
| Prolog execution & memory | Active queries · KB memory & retained history | Query saturation; ETS growth; whether frozen queries are temporarily retaining old data |
| Rejections & failures | Append rejections by reason · Failed writes | Backpressure/redirect/skip (flow control) vs OCC conflicts + park timeouts (real failures) |
| Dissemination feed | Feed activity · Dropped blocks | Gossip push/ingest/pull health; gap-drop bursts |
| Brahms overlay | View/sample/links · n̂ | Overlay connectivity + recently reachable population estimate |

## Metric reference

See the `quod_metrics` module doc (`-moduledoc`) for the full metric list, types,
and labels. Cumulative counts are exposed as gauges set to the running total —
wrap them in `rate()` / `increase()` (the dashboard already does).

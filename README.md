# quod

A **Prolog/Brahms** P2P node over **QUIC** — no broker, no EMQX.

Transport is QUIC via the pure-Erlang [`quic`](https://hex.pm/packages/quic)
library (no NIF, no msquic). Membership is [Brahms](https://www.cs.technion.ac.il/~idish/ftp/brahms.pdf)
byzantine-resistant peer sampling, one instance per **namespace** (ontology).
This re-bases onbrater's L1: where onbrater used an in-VM MQTT broker, quod uses
QUIC streams + Brahms gossip for fan-out.

## Architecture

```
quod_brahms (gen_statem, one per namespace Ns) ── view V + min-wise sampler
   │   gossips on channel Ns; open_link / quod_link:send / monitor(LinkPid)
   ▼
quod_quic (gen_server, singleton) ──────────────── server + dialer + authority
   │   one connection per pool key (no dial race within a pool); pure-Erlang QUIC
   ▼
quod_conn (one process per QUIC connection) ────── OWNS that connection
   │   demuxes {stream_data, StreamId, ..} to the right link
   ▼
quod_link (one process per (peer, channel)) ────── framing + publish + send
       publishes to {channel, Channel}; its death is the disconnect signal
```

| module | role |
| ------ | ---- |
| `quod_brahms` | per-namespace membership statem (push/pull/reconstruct rounds) |
| `quod_brahms_sampler` | secret-keyed min-wise uniform sampler (HMAC-SHA256) |
| `quod_quic` | QUIC server + dialer; serializes ordinary, pinned, and identity-discovery pools |
| `quod_conn` | per-connection owner; routes stream data to links |
| `quod_link` | per-(peer, channel) stream: header handshake + length-prefixed frames |
| `quod_reg` | gproc nomenclature (`{channel,Ns}`, `{quod_brahms,Ns}`, `{quod_ns,Ns}`, …) |
| `quod_app` | env-driven boot (config from the orchestrator) |
| `quod_simplex` | per-namespace BFT ordering, batching, failover, and recovery |
| `quod_transaction` | namespace-bound canonical transaction signing and relay envelopes |
| `quod_relay` | one-pass relay/consensus wire dispatch and bounded relay-result caching |
| `quod_prolog` | committed Prolog state, optimistic validation, reads, and ordered apply |
| `quod_diff` / `quod_committed_projection` | one canonical fact/outcome transition for live apply and certified foreign materialization |
| `quod_runtime` | per-ontology rebuildable P state, durable subscription catalogue, and P-before-E ordering |
| `quod_foreign_log` / `quod_foreign_projection` | shared certified foreign history and demand-driven subscribed projection |
| `quod_ledger_store` | append-only durable block log; one fsync per committed batch |
| `quod_catchup` / `quod_feed` | verified historical catch-up and live dissemination |

The target actor and system-startup model is specified in
[`doc/ontology-actor-architecture.md`](doc/ontology-actor-architecture.md):
nodes, agents, human-facing users, and services are classed instances in exact
containing ontologies; Prolog actions own policy and governed Erlang external
predicates bridge committed truth to the live node and network.
Explicit ontology subscriptions and their shared certified projections are
specified in
[`doc/ontology-subscription-plan.md`](doc/ontology-subscription-plan.md); the
implemented single applied-operation-to-`react_on/3` path above them is specified
in
[`doc/event-reaction-refinement-plan.md`](doc/event-reaction-refinement-plan.md).

**Identity.** A node's id is its **Ed25519 public key** (`node_id`), generated on first
boot and persisted; the address `{Host, Port}` is demoted to a resolvable routing hint.
The first frame on a stream is a header announcing the opener's `{Pubkey, Addr}` + channel,
and **mutual TLS** binds the connection to that key (`quic:peercert/1` must match the
claimed pubkey). The committee is identified by pubkeys; Brahms discovery still works in
addresses (it reads the `Addr` from the header). Consensus shares, finality
certificates, and every non-genesis transaction are Ed25519-signed. Consensus
signatures are bound to the ontology namespace and its pinned genesis hash, so
an overlapping committee cannot replay a vote or certificate from another
ontology or differently anchored chain. The sole founder records a fresh,
queryable `consensus_incarnation/1` nonce in slot 1, so wiping and re-founding
the same namespace produces a new signature domain. A write sent
to a non-leader validator is transparently relayed to the proposer of its exact
earliest usable slot using the signed canonical bytes; signatures authenticate
authors but never replace target `can_invoke/4` authorization. Signed goals use
the deployed generic anchored agent principal: the canonical
`agent_instance_ref/3` identifies the actor, and its containing ontology proves
the active signing key.
For a signed write with one foreign writer, the agent ontology first
commits a batchable operation claim, the target commits one ordinary
application under its normal ACL/OCC path, and the agent ontology records the
completion asynchronously. Any read-only ontologies contribute f+1 snapshot
certificates, not Prepare/Finalize records. Only two or more writers use the
five-record atomic DTX protocol; their read-only dependencies remain
participants of that atomic group for now.
The canonical consensus signature contract is
[`doc/consensus-signatures.md`](doc/consensus-signatures.md).

**Message contract.** A consumer of channel `Ns`:

```erlang
quod_reg:subscribe({channel, Ns}),
receive {quod_message, {Peer, LinkPid}, Ns, Payload} -> ... end,  %% inbound gossip
quod_link:send(LinkPid, Reply),                                   %% reply on the same stream
erlang:monitor(process, LinkPid)  %% -> {'DOWN', ...} is the disconnect
```

## Build & run

Pure Erlang — no C toolchain, fast build.

```bash
./scripts/gen-cert.sh        # once: self-signed dev cert in priv/certs/
rebar3 compile
rebar3 shell                 # QUIC listener on :14567
```

Join a namespace from the shell, or via env (see below):

```erlang
quod_brahms:start_namespace(<<"ont:test">>, #{
    node_id    => {"127.0.0.1", 14567},
    seed_peers => [{"127.0.0.1", 14568}, {"127.0.0.1", 14569}]}).
quod_brahms:view(<<"ont:test">>).     %% the converged peer view
quod_brahms:sample(<<"ont:test">>).   %% a uniform sample
```

`rebar3 eunit` (unit) and `rebar3 ct` (real loopback QUIC) cover the stack.

## Configuration

Each release reads its HOCON configuration file (normally `config/quod.conf`,
rendered by the orchestrator). Scalar settings may be overridden with `QUOD_`
environment variables using `__` for nesting; content namespaces remain file
configured because `content` is a list. See `config/quod.conf` for the current
configuration surface.

Prometheus metrics are served at `GET /metrics` on `metrics_port` (default
`14568`): `quod_up` and per-namespace `quod_brahms_{view_size,sample_size,links,rounds}`.

The **web explorer** has two entry points. `explorer.enabled` exposes the
optional unauthenticated, read-only ledger viewer, loopback-bound by default
(`explorer.ip`/`explorer.port`, default `14569`). The TLS client listener serves
the same UI at `/explorer`; after challenge-response login its backtracking
console submits ordinary signed goals. Frontend source lives in `ui/`; its
built bundle is committed under `priv/explorer/` — see `ui/README.md`.

Explorer history uses the running ontology's committed snapshot. Stopped-ledger
inspection requires `?mode=offline` on `/api/txs`, `/api/tx/:ns/:id`, or
`/api/block/:ns/:slot`; it refuses a running ontology. Live-owner failure returns
HTTP 503, never an automatic disk scan. `explorer.read_budget_ms` configures one
read deadline (default 30 seconds), including WebSocket Finalize enrichment.
Synchronous disk I/O is not forcibly interrupted: if it finishes after the
deadline, the read is refused and its handle closed. This is not a hard bound on
HTTP completion time.

> #### `+Q` is not optional in a container {: .warning }
>
> The BEAM sizes its port table from `ulimit -n`. Container runtimes default
> `nofile` to ~1e9, which preallocates **~1.5 GB** of `port_table`. `config/vm.args`
> caps it with `+Q 65536` (KB-sized table). Without it a node uses ~2 GB instead
> of ~100 MB.

The release also caps BEAM at four normal/dirty CPU schedulers, two dirty-I/O
schedulers, and four async threads. Nomad grants each Quod task 500 MHz; inheriting
all 16 host CPUs created 58 scheduler/async threads and made a normal recovery peak
near the 512 MiB task limit. Raise the VM thread counts together with task CPU when
deploying on substantially larger dedicated resources.

## Deploy (Docker + Nomad)

```bash
set -euo pipefail

TAG=0.7.152
REGISTRY=192.168.1.11:5000
NODE_COUNT=8
docker build -t "$REGISTRY/quod:$TAG" .
docker push "$REGISTRY/quod:$TAG"

# 0.7.152 changes the catch-up channel to page-credit frames. Stop every home
# and cloud allocation before the upgrade; never mix the old/new wire.
# Persisted ledger formats are unchanged: preserve the anchored volumes.
nomad job stop quod

# STEADY-STATE REDEPLOY — use this only when the release declares no persisted
# format break and the network has already been founded with the current
# generation. If a release declares a break, use the clean founding procedure
# below exactly once; subsequent deploys resume its anchored volumes.
nomad job run -var image_tag="$TAG" -var image_registry="$REGISTRY" \
  -var node_count="$NODE_COUNT" -var cloud_node_count=0 \
  -var genesis_hash="$GENESIS_HASH" deploy/quod.nomad

# ---------------------------------------------------------------------------
# FOUNDING A NEW NETWORK — only when the release breaks the persisted format,
# which each such release states explicitly. It destroys all ledger history.
# Everything below is skipped by a routine upgrade.
#
# Stop the fleet, then delete every
# dynamic compute volume named quod-node-local[N]. Obtain and verify the IDs
# before deleting them; /quod/data is the allocation mount, not the host path.
nomad job stop -purge quod
nomad volume status -type host
nomad volume status -type host -json |
  jq -r '.[] | select(.Name | test("^quod-node-local\\[[0-9]+\\]$")) | .ID' |
  while IFS= read -r volume_id; do
    nomad volume delete -type host "$volume_id"
  done
[ "$(nomad volume status -type host -json |
       jq '[.[] | select(.Name | test("^quod-node-local\\[[0-9]+\\]$"))] | length')" -eq 0 ]

# Recreate one empty mkdir-plugin host volume per allocation index, distributed
# deterministically across the ready compute nodes.
mapfile -t COMPUTE_NODE_IDS < <(
  nomad node status -json |
    jq -r '.[] |
      select(.NodeClass == "compute" and
             .Status == "ready" and
             .SchedulingEligibility == "eligible") |
      .ID' |
    sort
)
[ "${#COMPUTE_NODE_IDS[@]}" -gt 0 ]
COMPUTE_NODE_COUNT="${#COMPUTE_NODE_IDS[@]}"
for i in $(seq 0 $((NODE_COUNT - 1))); do
  node_id="${COMPUTE_NODE_IDS[$((i % COMPUTE_NODE_COUNT))]}"
  sed -e "s/quod-node-local\\[0\\]/quod-node-local[$i]/" \
      -e "s/__COMPUTE_NODE_ID__/$node_id/" \
    deploy/volumes/quod-node-local.hcl | nomad volume create -
done
nomad volume status -type host
[ "$(nomad volume status -type host -json |
       jq '[.[] |
         select((.Name | test("^quod-node-local\\[[0-9]+\\]$")) and
                .PluginID == "mkdir" and .State == "ready")] |
         length')" -eq "$NODE_COUNT" ]

# Founding is explicit: one allocation creates a fresh random incarnation.
nomad job run -var image_tag="$TAG" -var image_registry="$REGISTRY" \
  -var bootstrap=true -var cloud_node_count=0 deploy/quod.nomad

# Copy the logged genesis anchor, then expand the same homogeneous group.
read -r -p "Genesis anchor (64 hexadecimal characters): " GENESIS_HASH
[[ "$GENESIS_HASH" =~ ^[0-9A-Fa-f]{64}$ ]]
nomad job run -var image_tag="$TAG" -var image_registry="$REGISTRY" \
  -var node_count="$NODE_COUNT" -var cloud_node_count=0 \
  -var genesis_hash="$GENESIS_HASH" deploy/quod.nomad

# The new allocations join as observers. Once each is caught up, submit one
# admit(Pubkey, Host, Port) transaction from a validator, until N validators
# are present.
```

The complete persistence and wipe contract is
[`doc/consensus-signatures.md`](doc/consensus-signatures.md). If cloud
satellites have previously run, wipe their `quod-node-cloud` allocation
subdirectories too before they join the new anchor. The founder is only the
first event: after the anchor is supplied, every allocation belongs to the same
`quod-node` task group and runs with `mode=join`; new nodes remain observers
until explicitly admitted. Each compute allocation has its own dynamic host
volume mounted at `/quod/data`. A single task group makes `max_parallel=1`
fleet-wide, and Nomad waits for consensus recovery before advancing an ordinary
anchored rolling update.
Health gates must also inspect Erlang supervisor restart logs/metrics: child
restart loops do not increment Nomad's task-restart counter.

## Status / next steps

- **Done:** pure-Erlang QUIC transport, Brahms membership, Prolog content, the
  DispersedSimplex ordering layer, quorum certificates, trustless catch-up, live
  member recovery, bounded per-ontology transaction micro-batches, depth-one pipelining with
  implicit predecessor finality, signed transaction relay, inter-ontology asks,
  retained-custody ingress, the signed fact-backed live ontology directory
  with committed private host knowledge, runtime projection, durable multi-ontology transactions,
  generic agent-signed goals, root-owned ontology creation, root-driven system
  ontologies, engine-local external-predicate ownership, explicit durable
  ontology subscriptions, shared certified foreign projections, local and
  subscribed `react_on/3` dispatch, explicit `trigger_event/1`, durable effects
  in ordinary and multi-ontology transactions, the source-claimed batchable
  remote-singleton transaction path, metrics, and durable
  Docker/Nomad deployment.
- **Next:** measure and optimize only the remaining genuine multi-target DTX
  work in `doc/dtx-latency-optimization-plan.md`. Physical-node identity Slices 2--4
  and ontology-backed hosted-agent/FIPA delivery remain planned work.

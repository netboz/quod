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
   │   one connection per peer (no dial race); pure-Erlang QUIC
   ▼
quod_conn (one process per peer) ───────────────── OWNS the QUIC connection
   │   demuxes {stream_data, StreamId, ..} to the right link
   ▼
quod_link (one process per (peer, channel)) ────── framing + publish + send
       publishes to {channel, Channel}; its death is the disconnect signal
```

| module | role |
| ------ | ---- |
| `quod_brahms` | per-namespace membership statem (push/pull/reconstruct rounds) |
| `quod_brahms_sampler` | secret-keyed min-wise uniform sampler (HMAC-SHA256) |
| `quod_quic` | QUIC server + dialer + one-connection-per-peer authority |
| `quod_conn` | per-peer connection owner; routes stream data to links |
| `quod_link` | per-(peer, channel) stream: header handshake + length-prefixed frames |
| `quod_reg` | gproc nomenclature (`{conn,NodeId}`, `{channel,Ns}`, `{quod_brahms,Ns}`, …) |
| `quod_app` | env-driven boot (config from the orchestrator) |

**Identity.** A node's id is its **Ed25519 public key** (`node_id`), generated on first
boot and persisted; the address `{Host, Port}` is demoted to a resolvable routing hint.
The first frame on a stream is a header announcing the opener's `{Pubkey, Addr}` + channel,
and **mutual TLS** binds the connection to that key (`quic:peercert/1` must match the
claimed pubkey). The committee is identified by pubkeys; Brahms discovery still works in
addresses (it reads the `Addr` from the header). *(No-identity/test boots use the address
as the id, transitionally.)* Per-message/block signing + quorum certificates are Phase B.

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

A release reads its config from the environment (so a node is configured by its
orchestrator, no custom `sys.config`):

| env var | effect |
| ------- | ------ |
| `QUOD_PORT` | QUIC `listen_port` (and the port of this node's `node_id`) |
| `QUOD_NODE_IP` | `node_id = {QUOD_NODE_IP, QUOD_PORT}` — the dialable id |
| `QUOD_NAMESPACE` | ontology namespace to join on boot |
| `QUOD_SEEDS` | space/comma-separated `ip:port` bootstrap peers |

Prometheus metrics are served at `GET /metrics` on `metrics_port` (default
`14568`): `quod_up` and per-namespace `quod_brahms_{view_size,sample_size,links,rounds}`.

> #### `+Q` is not optional in a container {: .warning }
>
> The BEAM sizes its port table from `ulimit -n`. Container runtimes default
> `nofile` to ~1e9, which preallocates **~1.5 GB** of `port_table`. `config/vm.args`
> caps it with `+Q 65536` (KB-sized table). Without it a node uses ~2 GB instead
> of ~100 MB.

## Deploy (Docker + Nomad)

```bash
docker build -t quod:0.2.1 .                 # multi-stage; cached deps layer
docker tag quod:0.2.1 <registry>/quod:0.2.1 && docker push <registry>/quod:0.2.1
nomad job run deploy/quod.nomad              # 3 nodes, host net, static UDP 14567
```

`deploy/quod.nomad` pins one instance per server, host-network, a static UDP
port (so seeds are predictable), a static seed list (each node filters itself
out), and a Consul service. quod is **stateless** (in-memory view/sampler, cert
in the image) — no CSI volume.

## Status / next steps

- **Done:** pure-Erlang QUIC transport, Brahms membership per namespace, env
  boot, Docker/Nomad deploy. Verified full-mesh on a 3-node cluster (~100 MB/node).
- **Next:** the application layer — wire `erlog` so a namespace's gossip carries
  **ontology facts / distributed Prolog queries**, not just node ids.
- **Deferred:** PUSH over QUIC datagrams; per-block quorum certificates + signed
  changes (Phase B); Brahms gossiping the address hint (sparse-seed move-survival).

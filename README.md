# quod

A Prolog/Brahms P2P node over **QUIC** — no broker, no EMQX. Transport is QUIC
via [`quicer`](https://hex.pm/packages/quicer) (Apache-2.0).

This re-bases onbrater's L1 transport: where onbrater used an in-VM MQTT broker
(rooms = topics, `mod_onia_*` hooks), quod uses QUIC connections + a thin channel
layer, with **Brahms gossip doing fan-out** instead of a broker.

## Layout

```
src/
  quod_app.erl        application entry point
  quod_sup.erl        supervision tree (transport; Brahms/Tendermint go here)
  quod_quicer.erl     QUIC transport — listener + dialer; events + wire framing
  quod_reg.erl        gproc registration nomenclature (names + event properties)
include/quod.hrl      inbound event messages (quod_peer_up/down, quod_message)
config/               sys.config, vm.args
scripts/gen-cert.sh   self-signed cert for the QUIC listener (TLS 1.3 required)
```

## Concept mapping (onbrater MQTT -> quod QUIC)

| onbrater (MQTT/broker) | quod (QUIC) |
|---|---|
| peer connection | one QUIC connection per Brahms-sampled peer |
| connect / disconnect | `quod_peer_up` / `quod_peer_down` |
| room / topic | a `{Channel, Payload}` frame on the peer's QUIC stream |
| subscribe / unsubscribe | `quod_reg:subscribe/1` `unsubscribe/1` on `{channel, Name}` |
| publish a message | `quod_quicer:send(Peer, Channel, Payload)` |
| **broker fan-out** | **Brahms/gossip** — send to sampled peers, who forward |

## Build & run

```bash
./scripts/gen-cert.sh        # once: dev TLS cert for the QUIC listener
rebar3 compile               # first build compiles the msquic NIF (heavy, ~minutes)
rebar3 shell                 # starts the node; QUIC listener on :14567
# or a release:
rebar3 release && _build/default/rel/quod/bin/quod console
```

> First `rebar3 compile` clones + builds msquic + OpenSSL from source (~600 MB,
> several minutes). Subsequent builds reuse it.

## Status / next steps

- `quod_quicer` is the starting skeleton — verify the exact quicer active-message
  patterns and accept/handshake/ownership handoff against quicer's examples.
- Wire `quod_peer_up/down` into a `quod_brahms` peer-sampling process.
- Add Tendermint total-order broadcast and the Prolog evaluator as `quod_sup`
  children.

# Quod

Quod is a distributed virtual-reality and simulation system built around
executable Prolog ontologies. Its goal is to host persistent shared worlds in
which people and autonomous agents can perceive, reason, communicate, act, and
change a simulated environment through the same semantic model.

An ontology describes what exists, what it means, who may change it, and which
consequences follow. Each ontology is a Prolog knowledge base backed by its own
signed, consensus-ordered history. Authorized goals read or change that
knowledge through normal Prolog proofs; committed changes drive scenes,
interactions, simulations, agent behavior, and rebuildable runtime projections.

The system is written in Erlang/OTP and communicates over pure-Erlang QUIC. It
does not require a message broker. Its current release is declared in
`src/quod.app.src`.

## Product direction

Quod is intended to support:

- persistent multi-user worlds presented through immersive WebXR or ordinary
  desktop clients;
- shared semantic scene graphs, composable models, spatial interfaces, and
  ontology-selected presentations;
- server-authoritative real-time simulation with bodies, joints, collision,
  materials, energy, anatomy, ecology, devices, and environmental processes;
- editable procedural and voxel worlds whose meaningful edits survive restart
  while generated geometry and per-frame motion remain transient;
- human, autonomous, and FIPA agents represented by the same anchored identity
  and authorization model;
- explanations derived from ontology rules: physics measures an interaction,
  while Prolog determines its meaning and durable consequences;
- multiple renderers and device profiles consuming the same bounded semantic
  projections, from VR controllers and hand tracking to keyboard, mouse, and
  flat displays.

World facts and semantic consequences belong in durable ontology state.
Per-frame transforms, interpolation, visibility, scene indexes, meshes, and
physics working state are rebuildable or transient. This separation lets Quod
provide responsive simulation without putting every frame into consensus.

The client/world architecture is described in
[`doc/client-world-direction.md`](doc/client-world-direction.md). The intended
simulation consequence model is recorded in
[`doc/world-consequence-direction.md`](doc/world-consequence-direction.md).
These layers are the product goal; substantial parts remain architectural
direction while the distributed ontology and agent substrate is implemented
first.

## Current foundation

- **Durable Prolog ontologies.** Facts, policy, actions, and authorization live
  together in an anchored ontology history.
- **Byzantine fault tolerant ordering.** Each ontology has its own committee,
  DispersedSimplex ordering process, signed transactions, finality certificates,
  verified catch-up, and live feed.
- **Authenticated agents.** A stable `agent_instance_ref/3` identifies an actor
  inside an exact ontology history. Active keys and permissions are proved from
  committed state before a signed goal can execute.
- **Cross-ontology proofs and writes.** Read dependencies use certified
  snapshots. A single foreign writer uses the source-claimed independent lane;
  changes to several writers use the atomic DTX lane.
- **Deterministic reactions.** Applied diffs become events. `react_on/3` patterns
  match them with ordinary Prolog unification, so bindings flow into the
  reaction goal. `trigger_event/1` records an event without asserting it as a
  permanent fact.
- **Generic agent hosting.** Committed host assignments select one local Erlang
  process per agent epoch. The process and its transient queues are disposable;
  its durable state remains in its ontology. Host moves rotate the signing key,
  and ontology policy decides recovery from authenticated failure reports.
- **Browser and machine clients.** The TLS client endpoint uses
  challenge-response authentication and one predicate-neutral signed-goal API.
  The Explorer provides ledger inspection and an authenticated Prolog console.

FIPA agents are another protocol layer above this substrate. FIPA ontologies
will define ACL envelopes, conversations, AMS/DF behavior, and the durable
obligations they need. They reuse Quod actions, reactions, hosted processes,
and signed-goal delivery rather than introducing another executor or message
ledger.

## The execution model

Quod separates a committed change into three ordered layers:

1. **D — durable state.** Consensus commits a transaction and applies its fact
   diff to the ontology knowledge base.
2. **P — projection.** The runtime installs the derived state required by the
   change, such as subscriptions and hosted-agent bindings.
3. **E — effects and reactions.** Live commits may publish events and schedule
   bounded external work. Historical replay rebuilds state without re-emitting
   effects.

An Erlang process is never a second durable owner. It may hold sockets, working
state, timers, and references to secret custody, but it must reconstruct from
committed ontology state after restart. Cross-process readiness uses the
existing `gproc`/`quod_reg` notifications and direct messages; owners do not
poll one another.

```text
signed goal
    │
    ▼
proof + ACL + staged diff ── foreign reads/writes ── certified ontology scopes
    │
    ▼
per-ontology consensus ── signed block history ── catch-up/feed
    │
    ▼
committed Prolog state (D)
    │
    ├── rebuildable runtime projection (P)
    └── unified events, reactions, and governed effects (E)
```

The settled contracts are in
[`doc/content-layer-design.md`](doc/content-layer-design.md),
[`doc/multiwrite-architecture.md`](doc/multiwrite-architecture.md), and
[`doc/agent-fipa-plan.md`](doc/agent-fipa-plan.md).

## Ontologies and system bootstrap

`quod:root` is the only ontology pinned in node configuration. After root is
ready, the node proves its committed `system_ontology/2` catalogue and starts or
joins each exact anchored history through the ordinary lifecycle. System status
is therefore network state, not an Erlang allowlist or a property inferred from
a source filename.

The bundled system vocabulary includes node, agent, and human-user policy. The
current domain system ontologies also include:

| ontology | purpose |
| --- | --- |
| `quod:names` | name pools, recognition, and deterministic proof-bound drawing |
| `quod:licence` | licence families, compatibility, obligations, and release reach |
| `quod:measure` | quantities, units, dimensions, and conversion |
| `quod:lens` | reusable selections and presentation encodings |
| `quod:present` | bounded renderer-neutral presentation marks |

The naming and licence sources and tests live at
[`priv/ontologies/quod_names.pl`](priv/ontologies/quod_names.pl),
[`priv/ontologies/quod_licence.pl`](priv/ontologies/quod_licence.pl),
[`test/quod_names_tests.erl`](test/quod_names_tests.erl), and
[`test/quod_licence_tests.erl`](test/quod_licence_tests.erl). They become system
ontologies only when their exact genesis anchors are registered in root. The
deployed 0.7.236 network has both entries and hosts both histories on every
node.

The full bootstrap and actor model is specified in
[`doc/ontology-actor-architecture.md`](doc/ontology-actor-architecture.md).

## Runtime components

| component | responsibility |
| --- | --- |
| `quod_ns` / `quod_simplex` | one ontology's supervised lifecycle and ordering owner |
| `quod_ledger_store` | append-only durable block storage |
| `quod_prolog` | MVCC Prolog state, proof staging, validation, and apply |
| `quod_runtime` | ordered projections, subscriptions, reactions, and hosted children |
| `quod_foreign_log` / `quod_foreign_projection` | shared verified foreign history and subscribed projections |
| `quod_client_goal*` | parsing, authentication, routing, custody, and outcome resolution for signed goals |
| `quod_agent` / `quod_agent_vault` | hosted process lifetime and governed private-key custody |
| `quod_node_actor` / `quod_system_ontology` | node identity, lifecycle actions, and root-driven system startup |
| `quod_quic` / `quod_conn` / `quod_link` | authenticated QUIC connections, prioritized streams, and framed channels |
| `quod_brahms` | Byzantine-resistant peer sampling per ontology |

Transport connections are shared by peer identity, while streams remain scoped
to their protocol channels. Consensus traffic receives higher stream priority
than bulk catch-up and application traffic. Peer identity is an Ed25519 public
key bound to mutual TLS; endpoint addresses are routing hints rather than actor
identity.

## Build and test

Quod requires a recent Erlang/OTP installation and `rebar3`. The QUIC stack is
pure Erlang, so a C toolchain is not required.

```bash
./scripts/gen-cert.sh       # create local development certificates once
rebar3 compile
rebar3 shell
```

The default example in [`config/quod.conf`](config/quod.conf) founds
`quod:root` on first use. A production node instead receives its exact root
anchor and persistent data directory from the orchestrator.

Useful verification commands are:

```bash
rebar3 as test eunit
rebar3 as test ct
rebar3 xref
rebar3 dialyzer
rebar3 as prod release
```

Common Test opens real loopback peers and QUIC connections. Run stateful suites
sequentially when collecting release evidence; concurrent `rebar3` commands
must not share the same `_build/test` tree.

## Configuration and interfaces

The node reads HOCON from `config/quod.conf` by default. Set `QUOD_CONF` to use
another file. Scalar settings can be overridden with `QUOD_` environment
variables using `__` for nesting; the `content` list is rendered as a whole by
the deployment.

The main listeners are:

| listener | default | role |
| --- | ---: | --- |
| QUIC | `14567` | consensus, feed, catch-up, discovery, and internal requests |
| Prometheus | `14568` | `/metrics` |
| Explorer | `14569` | optional loopback read-only ledger viewer |
| TLS client | `14570` | authenticated client, Explorer, and signed-goal API |

The browser client source is under [`client/`](client/) and the Explorer source
under [`ui/`](ui/). Built assets are committed in `priv/client/` and
`priv/explorer/`.

Container deployments must retain the VM limits in `config/vm.args`. In
particular, `+Q 65536` prevents the BEAM from sizing an enormous port table from
a container runtime's unusually high `nofile` limit. Scheduler counts and
Nomad CPU allocations should be changed together.

## Deployment

The Docker image builds the production release, and
[`deploy/quod.nomad`](deploy/quod.nomad) defines the fleet. Validate both the
release and the rendered Nomad job before rollout:

```bash
rebar3 as prod release
docker build -t REGISTRY/quod:VERSION .
nomad job validate deploy/quod.nomad
```

Routine upgrades preserve every anchored ledger and use the existing root
genesis hash. Founding a network and purging ledgers are separate operations;
purging destroys ontology history and must never be part of an ordinary
redeploy. The persistence and signature-domain rules are documented in
[`doc/consensus-signatures.md`](doc/consensus-signatures.md).

## Project map

- [`priv/ontologies/`](priv/ontologies/) — shipped Prolog founding sources
- [`src/`](src/) — Erlang/OTP runtime and protocol implementation
- [`test/`](test/) — EUnit and Common Test coverage
- [`doc/ontology-actor-architecture.md`](doc/ontology-actor-architecture.md) — actor identity, bootstrap, hosting, and recovery authority
- [`doc/hosted-agent-runtime.md`](doc/hosted-agent-runtime.md) — current hosted-process and event contract
- [`doc/client-world-direction.md`](doc/client-world-direction.md) — VR clients, semantic scenes, presentation, physics, and editable worlds
- [`doc/world-consequence-direction.md`](doc/world-consequence-direction.md) — simulation meaning, materials, ecology, combat, and durable consequences
- [`doc/inter-ontology.md`](doc/inter-ontology.md) — proved scopes and cross-ontology behavior
- [`doc/write-lanes-plan.md`](doc/write-lanes-plan.md) — read, independent-write, and atomic-write lanes
- [`doc/performance-roadmap.md`](doc/performance-roadmap.md) — measured performance state and deferred work
- [`AGENTS.md`](AGENTS.md) — repository engineering rules

The distributed ontology, signed-goal, reaction, and generic hosting substrate
is deployed through release 0.7.236. FIPA conversations and the VR/world
runtime are the next product layers. Presentation experiments already exist,
but the complete scene projection, client synchronization, physics authority,
and editable-world milestones remain to be implemented and validated.
Performance investigations remain deferred unless they reveal a concrete
correctness or availability blocker.

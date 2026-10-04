# Quod

Quod is a distributed virtual-reality and simulation system built around
executable Prolog ontologies. An ontology defines domain facts, policy,
actions and authorization. Its own committee orders signed changes into a
durable history; local Prolog state applies that history. Erlang/OTP provides
consensus, proof workers, authenticated pure-Erlang QUIC transport and
runtime services without becoming a second domain engine.

## Architecture

Start with the [architecture documentation](doc/README.md):

- [Ownership and request flow](doc/architecture.md)
- [Consensus and certified history](doc/consensus-signatures.md)
- [Prolog proofs and foreign scopes](doc/proofs.md)
- [Atomic and independent writes](doc/multiwrite-architecture.md)
- [Ontology lifecycle and routing](doc/lifecycle-and-routing.md)
- [Runtime, effects and agents](doc/runtime-and-agents.md)
- [Client and world direction](doc/world.md)

The previous detailed plans and measurement records are preserved in the
[archive](doc/outdated/README.md). The [working agreement](AGENTS.md) governs
architectural changes and verification.

## Current foundation and direction

The implemented substrate includes anchored ontology histories,
DispersedSimplex ordering, signed agent goals, cross-ontology proofs and
writes, committed event reactions, hosted agents, internal FIPA Request
transitions, a TLS client endpoint and Explorer. `quod:root` supplies a
committed catalogue of exact system ontologies. An agent is a classed
instance in one ontology; its hosted process is rebuildable.

The browser and ontology sources also include early rendering, modelling,
material, environment and lobby work. The full shared-world simulation,
scene synchronization, physics authority, editable world and external FIPA
platform remain product direction. See [world direction](doc/world.md) for
that boundary. The source release version is in [`src/quod.app.src`](src/quod.app.src).

## Build and verification

A recent Erlang/OTP and `rebar3` are required. The QUIC stack is pure Erlang.
The example configuration in [`config/quod.conf`](config/quod.conf) founds
`quod:root` on first use; a production node receives its exact root anchor
and persistent data directory from deployment. `QUOD_CONF` selects another
HOCON file.

```sh
./scripts/gen-cert.sh
rebar3 compile
rebar3 shell
```

Useful checks are:

```sh
rebar3 as test eunit
rebar3 as test ct
rebar3 xref
rebar3 dialyzer
rebar3 as prod release
```

Stateful Common Test suites open real loopback peers. Run release gates
sequentially so concurrent `rebar3` commands do not share `_build/test`.

Build the browser shell and shared client assets with:

```sh
npm --prefix client ci
npm --prefix ui ci
npm --prefix ui run build
```

## Repository map

- [`priv/ontologies/`](priv/ontologies/) — shipped Prolog founding sources
- [`src/`](src/) — Erlang/OTP runtime and protocols
- [`client/`](client/) — world renderer and signed-client helpers
- [`ui/`](ui/) — browser shell and Explorer
- [`test/`](test/) — EUnit and Common Test coverage
- [`deploy/`](deploy/) — deployment files

Routine upgrades retain every anchored ledger and the existing root genesis
hash. Founding a new network or purging history is a separate operation, never
an ordinary redeploy. The [consensus contract](doc/consensus-signatures.md)
describes the signature domain and history authority. Container releases keep
the VM port-table limit in [`config/vm.args`](config/vm.args); deployment is
defined in [`deploy/quod.nomad`](deploy/quod.nomad).

# Architecture documentation

Start with [the architecture map](architecture.md). It describes the current
implementation and names each state owner. Follow only the subject you need:

| Subject | Current document |
| --- | --- |
| Consensus, history, signatures and recovery | [Consensus](consensus-signatures.md) |
| Prolog proofs, authorization and foreign scopes | [Proofs](proofs.md) |
| Atomic and independent multi-ontology writes | [Multiwrite](multiwrite-architecture.md) |
| Ontology bootstrap, creation and routes | [Lifecycle and routing](lifecycle-and-routing.md) |
| Projections, events, effects, agents and internal FIPA | [Runtime and agents](runtime-and-agents.md) |
| Client and simulated-world direction | [World](world.md) |

The previous 83 Markdown documents, the Simplex PDF and figures are in the
[archive](outdated/README.md). They are preserved as design, review and measurement
records, including pinned text. Some contain still-relevant protocol rulings,
but their old “current” and “next” statements are dated. For a change to a
protocol, read the relevant archived ruling and implementation before editing;
flag any conflict instead of silently selecting one version.

The repository [working agreement](../AGENTS.md) governs architecture and
verification. The current source is the final check for what is implemented.

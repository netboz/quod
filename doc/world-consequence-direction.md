# Quod world consequence engine — combat, energy ecology, and criticals

**Status:** non-normative direction. Nothing here is approved for implementation.
It records a unified consequence model for combat, materials, energy, devices,
physiology, and ecology, corrected against Quod's actual execution model.

This document supersedes the standalone "Quod virtual world — combat, energy
ecology, and critical consequence system" brainstorm. Every substantive idea from
that draft is retained below; the corrections are marked with
`> **Correction.**` blockquotes so the delta stays visible.

**Prerequisites.** This work sits *after* milestone C2 in
[`doc/client-world-direction.md`](client-world-direction.md): it presumes a
running physics authority with epochs, contact events, and a
handle→semantic-identity map in P. C2 is itself behind C1 (client projection and
GUI), which is behind Slice 3 (reactions and outbox) of
[`doc/agent-fipa-plan.md`](agent-fipa-plan.md), which is not built. Read this as a
target, not as next-up work.

The normative substrate rules remain in `doc/agent-fipa-plan.md` (D/P/E,
predicate classes, actions, handlers, reactions) and `doc/inter-ontology.md`
(cross-ontology asks). The ordering and validation contract is
`doc/content-layer-design.md`. Where this document and those disagree, they win.

---

## 0. Core objective

Build one consequence engine where:

- Erlang, Rust, physics, and runtime systems provide quantitative observations;
- Prolog determines meaning, causality, affordance, transformation, injury,
  failure, and critical consequence;
- durable state D stores semantically important world facts;
- projection state P stores rebuildable fast-changing derived state;
- external effects E are emitted only from committed live state;
- the same architecture handles combat, ecology, materials, energy, crafting,
  devices, physiology, and environmental hazards.

Explicitly **not** a collection of independent damage systems for swords, fire,
bullets, cold, and poison. Model physical and energetic exposure and
transformation, then derive consequence.

---

## 1. Fundamental model

A Quod world consists of:

**Entities** — creatures, players, plants, tools, weapons, machines, structures,
projectiles, fluids, gases, terrain, and energy-harvesting creatures such as
lucioles.

**Materials** — wood, steel, bone, flesh, leather, ceramic, glass, water, air,
resin, plant tissue, composites, and fictional or exotic materials.

**Energy forms / physical channels** — mechanical, thermal, electrical, chemical,
radiative, pressure, acoustic, respiratory/environmental, biological, and
optional fantasy channels.

**Processes** — collision, cutting, fracture, penetration, combustion, cooling,
conduction, electrical discharge, corrosion, poisoning, digestion, metabolism,
photosynthesis, decomposition, recharge, generation, storage, reproduction,
healing, and machine operation.

**Exposures** — the quantitative physical interaction delivered to a target.

**Consequences** — material deformation, breakage, ignition, injury, bleeding,
loss of function, unconsciousness, death, equipment damage, ecological change,
and secondary events.

**Criticals** — a semantic phase transition, or an unusually important
consequence, arising from a physically plausible event.

---

## 2. Design principle: physics measures, Prolog interprets

The physics and runtime layer must not decide:

```text
damage = 37
critical = C
target_dead = true
```

It provides observations: relative velocity, contact point, surface normal,
tangential velocity, normal impulse, tangential impulse, effective mass, contact
area, body position, angular velocity, temperature, heat flux, electrical
current, pressure, gas composition, radiation dose, material state, and exposure
duration.

Prolog decides: what interaction occurred, what material process applies, what
transformed, which layer failed, which anatomical structure was affected, what
function was lost, whether a critical threshold was crossed, and what secondary
event should be created.

> **Correction — this boundary is a code-organisation boundary, not a trust
> boundary.** Quod records the diff, not the goal: **only the proposer runs the
> proof; every other member re-checks the OCC read set and applies the staged
> asserts and retracts** (`doc/content-layer-design.md`, "We record the diff, not
> the goal"). Nothing in consensus verifies that the interpretation was correct.
>
> Two consequences follow, and both must be stated in any implementation plan:
>
> 1. **The world's physics authority is a trusted oracle for every injury,
>    critical, ignition, and death in that world.** A malicious or buggy authority
>    can commit any consequence its write ACL permits. This is acceptable for a
>    single-operator world; it is not the trustless property the rest of Quod
>    has, and it must be an explicit, documented decision per world.
> 2. **Determinism across validators is not required for safety**, because they
>    do not re-run the proof. A proposer-local Rapier read cannot fork the
>    committee, and float non-determinism between nodes is not a consensus
>    hazard here.
>
> Determinism is still worth paying for, for a different reason: see §18.

---

## 3. Quod external predicates

Use governed Erlang external predicates of **`query`** class as the read-only
bridge to runtime and physics state (`doc/agent-fipa-plan.md` §5).

The class contract is absolute:

- a `query` predicate may read runtime reality;
- it must not stage durable state D;
- it must not mutate P;
- it must not perform external effects E.

Candidate module and registration:

```erlang
%% src/predicates/quod_physics_predicates.erl
registry({physics_contact, 2}) ->
    {query, quod_physics_predicates, physics_contact_2}.
```

Preferred binding direction:

```prolog
physics_contact(+ContactRef, ?Snapshot)
```

Unbounded enumeration is forbidden. This must not enumerate every world contact:

```prolog
?- physics_contact(Contact, Snapshot).
```

> **Correction — the read is proposer-local by construction.** Only the world's
> current authority node holds the live physics world, and only that node
> proposes contact resolutions. Other members never call the predicate for that
> contact; they apply the diff. Registration must therefore pin the allowed
> execution context to the proposing path, and the predicate must fail closed
> when the local node is not the current authority for `WorldId` — otherwise a
> non-authority proposing a resolution silently reads an empty or ghost world.

---

## 4. Immutable runtime snapshots

One semantic resolution must observe one immutable runtime snapshot. A proof must
never independently sample velocity at tick N, position at tick N+1, and a
collision normal at tick N.

Identity:

```prolog
contact_ref(WorldId, AuthorityEpoch, Tick, ContactId)
```

The physics authority freezes all relevant data for that event. Conceptual
snapshot:

```prolog
contact(
    world(WorldId),
    epoch(Epoch),
    tick(Tick),

    entity_a(EntityA), surface_a(SurfaceA),
    entity_b(EntityB), surface_b(SurfaceB),

    point(X, Y, Z),
    normal(Nx, Ny, Nz),

    relative_velocity(Vx, Vy, Vz),
    normal_speed(Vn),
    tangent_speed(Vt),

    normal_impulse(Jn),
    tangent_impulse(Jt),

    effective_mass(Me),
    contact_area(Area),

    angular_velocity_a(...),
    angular_velocity_b(...)
).
```

> **Correction — fixed point is mandatory, not "ideally".** Every value crossing
> the Prolog boundary is quantized to integers or explicit fixed-point. Not for
> consensus safety (§2), but because a float in a committed diff is
> un-re-derivable, defeats §18's audit story, and makes threshold comparisons in
> §16 unstable across releases. The quantization scale is part of the snapshot
> schema and is versioned.

> **Correction — the epoch is a prerequisite, not decoration.**
> `AuthorityEpoch` exists so a resolution from a superseded authority fails
> closed. Every resolution action carries
> `current_authority_epoch(WorldId, Epoch)` in its prerequisite list, matching the
> old-epoch rejection rule in `doc/client-world-direction.md` §2 and §8.

---

## 5. Semantic identities, not physics handles

Rapier and native handles remain implementation details.

Bad:

```prolog
collider_handle(1298)
```

Good:

```prolog
entity(sword_123)
component(blade)
surface(cutting_edge)
```

P maintains the mapping `ColliderHandle -> Entity -> Component ->
SemanticSurface`. The external predicate exposes only semantic identities. This
is the same rule as "no volatile endpoint is stored as part of identity"
(`doc/agent-fipa-plan.md` §11).

---

## 6. Material model

Objects are made of components, which have surfaces, which are made of
materials.

```prolog
object(sword_123).
isa(sword_123, longsword).

component(sword_123, blade).
component(sword_123, guard).
component(sword_123, pommel).

surface(blade, cutting_edge).
surface(blade, flat).
surface(blade, point).

material(blade, tempered_steel).
```

Candidate material properties:

```prolog
density(Material, Value).
hardness(Material, Value).
yield_strength(Material, Value).
fracture_toughness(Material, Value).
elastic_modulus(Material, Value).
thermal_conductivity(Material, Value).
heat_capacity(Material, Value).
ignition_temperature(Material, Value).
electrical_conductivity(Material, Value).
corrosion_resistance(Material, Value).
```

No finite-element realism. The properties exist to choose a meaningful failure
mode, not to compute one accurately.

---

## 7. Physical and energy channels

```prolog
channel(mechanical).
channel(thermal).
channel(electrical).
channel(chemical).
channel(radiative).
channel(pressure).
channel(acoustic).
channel(respiratory).
channel(biological).
```

- **Mechanical subchannels:** compression, tension, shear, cutting, penetration,
  torsion, bending, abrasion.
- **Thermal:** heating, cooling, heat extraction.
- **Electrical:** current, voltage-driven discharge, electrochemical effects.
- **Chemical:** corrosive, toxic, irritant, oxidizing, solvent.
- **Radiative:** ionizing, microwave, optical, laser.
- **Pressure:** overpressure, underpressure, decompression.
- **Acoustic:** impulse noise, sustained noise, vibration.
- **Respiratory:** hypoxia, hypercapnia, smoke, toxic gas.

Fantasy channels are added explicitly and honestly:

```prolog
channel(arcane).
channel(psionic).
channel(spiritual).
```

Do not disguise a fantasy effect as a physical channel unless it really is one.

---

## 8. Exposure as the universal interface

```prolog
exposure(ExposureId, Source, Target, Channel, Magnitude, Geometry, Duration).
```

Typed exposure terms may be preferable in implementation:
`mechanical_exposure/…`, `thermal_exposure/…`, `electrical_exposure/…`,
`chemical_exposure/…`, `pressure_exposure/…`, `radiative_exposure/…`.

A fire attack is not one damage number. It may produce thermal radiation, hot
gas, smoke, oxygen depletion, and chemical combustion products. An explosion may
produce overpressure, fragments, thermal exposure, and acceleration or a fall.

---

## 9. Material layers

Targets support layers. An armour stack:

```text
projectile -> outer cloth -> ceramic plate -> backing -> soft armor
           -> clothing -> skin -> bone -> organ
```

```prolog
layer(Target, Index, Layer).
material(Layer, Material).
thickness(Layer, Value).
covers(Layer, Region).
```

```prolog
resolve_impact(Impact, Target) :-
    target_layers(Target, Layers),
    initial_load(Impact, Load),
    propagate_layers(Impact, Layers, Load).
```

Each layer may absorb, reflect, deform, fracture, conduct, distribute, transmit,
transform, or fail.

> **Correction — this is the expensive part; give it a budget.** Layer
> propagation, the anatomy closure of §10, and the micro-outcome selection of §17
> are interpreted erlog running on the proposing node inside a bounded proof. A
> per-resolution inference and wall-clock budget is a hard requirement
> (`doc/agent-fipa-plan.md` invariant 10), must be declared before implementation
> — a first target of a few milliseconds per contact is a reasonable starting
> hypothesis — and must be measured in milestone 2, not discovered in production.
> Deep layer stacks and deep anatomies are where this blows up.

---

## 10. Anatomy

Anatomy is an ontology, not a hit-location table.

```prolog
part_of(left_hand, left_forearm).
part_of(left_forearm, left_arm).
part_of(left_arm, body).

contains(chest, heart).
contains(chest, left_lung).
contains(chest, right_lung).
contains(chest, major_vessels).

isa(radial_artery, artery).
isa(achilles_tendon, tendon).
isa(femur, long_bone).

vital(heart).
vital(brain).
```

The physics location identifies the initial body region. Rules determine the
underlying structures and the possible micro-outcomes.

---

## 11. Structured injury model

Do not store only hit points or prose.

```prolog
injury(injury_881, impact_427, bob, left_forearm, muscle, laceration, severe).

bleeding_source(injury_881, 3).
motor_impairment(injury_881, left_hand, severe).
pain_source(injury_881, severe).
tendon_severed(injury_881, flexor_tendon).
```

The player-facing critical description is generated from the semantic facts, not
stored as text.

---

## 12. Identity of damage events

Every important event and injury has a stable identity. Two identical wounds are
two wounds.

Bad:

```prolog
bleeding(bob, 2).
```

Good:

```prolog
wound(w_8831, a_4711, bob, left_arm, deep_cut).
bleeding(w_8831, bob, 2).

wound(w_8832, a_4712, bob, left_arm, deep_cut).
bleeding(w_8832, bob, 2).
```

> **Correction — the justification is OCC, not deduplication.** Quod does not
> collapse identical facts; the real hazards are that an unkeyed `retract`
> removes an arbitrary matching clause, and that unkeyed aggregate state forces a
> read-modify-write.
>
> Promote this to a hard rule: **no read-modify-write on shared combat state.**
> A proof shaped as `current_hp(Bob, X), Y is X - 7, retract/assert` reads a
> contended key and conflicts with every concurrent hit, so twenty players on one
> boss produce nineteen OCC rejections and retries per round — against a budget
> (§21) that cannot afford them. Keyed, append-only wound and exposure facts read
> almost nothing and therefore almost never conflict. Aggregates such as total
> blood loss are derived in P (§37), not maintained in D.

---

## 13. Criticals — core definition

> A critical is a qualitative state change, or an unusually important
> consequence, produced by a physically plausible event.

Examples: artery severed, tendon severed, bone fractured, ignition, blade
snapped, ceramic plate fractured, dielectric breakdown, vessel rupture, loss of
consciousness, organ failure, ecosystem tipping point.

This generalizes Rolemaster-style *coups critiques*. Criticals are not limited to
living targets.

---

## 14. Critical families

- **Mechanical / combat:** slash, puncture, crush, fracture, structural, edge
  damage.
- **Energy / environment:** thermal, cold, electrical, chemical, pressure,
  acoustic, radiation, respiratory.
- **Biological:** vascular, neurological, skeletal, organ, toxic, infection.
- **World / system:** equipment, structure, ecological.
- **Fantasy:** arcane, psionic, spiritual.

---

## 15. A/B/C/D/E grades

Retain A–E as player-facing severity language. Do not derive the grade from raw
damage. Use multidimensional severity:

```prolog
critical_dimension(C, structural,    b).
critical_dimension(C, functional,    d).
critical_dimension(C, physiological, e).
critical_dimension(C, immediacy,     e).
critical_dimension(C, reversibility, d).
```

Player-facing output summarizes this to `PUNCTURE CRITICAL E` or `THERMAL
CRITICAL C` depending on the most relevant interpretation. The summary is a
projection; the dimensions are the durable truth.

---

## 16. Threshold is not severity

Crossing a threshold creates a critical *opportunity*. How far beyond it the
event goes may affect severity.

```text
Stress <  FailureThreshold          -> no critical
Stress ~= 1.01 * FailureThreshold   -> Structural Critical A, small crack
Stress ~= 1.4  * FailureThreshold   -> Structural Critical C, major fracture
Stress ~= 3.0  * FailureThreshold   -> Structural Critical E, fragmentation
```

But topology and anatomy may produce a severe result from a modest force:

```text
small penetrating wound + major artery -> physiological Critical E
```

---

## 17. Rolemaster randomness, reinterpreted

Keep controlled randomness; never let dice violate physics. Physics and anatomy
establish the set of plausible *unresolved* micro-outcomes; randomness selects
among them.

```prolog
possible_micro_outcome(Event, muscle_laceration, 50).
possible_micro_outcome(Event, tendon_damage,     25).
possible_micro_outcome(Event, arterial_damage,   15).
possible_micro_outcome(Event, nerve_damage,      10).
```

The meaning is "among the physically plausible unresolved details, something
especially unfortunate happened". Never permit a tiny harmless impact plus a high
roll to produce an impossible decapitation.

---

## 18. Randomness and reproducibility

Never call uncontrolled randomness inside a committed proof. Derive stable
randomness from `WorldSeed`, `EventId`, context, and optional entropy, or pass it
explicitly:

```prolog
resolve_attack(..., AttackRoll, CriticalRoll).
```

> **Correction — the reason is audit, not consensus.** Because validators apply
> the diff rather than re-proving (§2), a non-deterministic roll cannot fork the
> committee. Seeded, re-derivable randomness buys something else, and it is the
> only lever this design has against §2's trusted oracle: **any party holding the
> committed contact snapshot, the ruleset version, and the seed can recompute the
> outcome and detect a proposer that cheated.** That makes the authority
> *accountable* even though it is not *verified*.
>
> For this to be worth anything, the committed transaction must carry everything
> the recomputation needs: the fixed-point snapshot, the ruleset/ontology version
> the proposer used, and the seed inputs. Design for that from the start; it
> cannot be retrofitted onto diffs that omit the inputs. A future strengthening —
> a validator-side re-derivation check on a sampled fraction of resolutions — is
> then a pure addition.
>
> Adversarial multiplayer randomness (commit-reveal, threshold VRF, or similar)
> remains explicitly out of scope for the first version, per §43.

---

## 19. Critical cascades

Criticals create secondary events:

```text
luciole discharge -> tinder ignition -> resin vaporization -> flash ignition
                  -> pressure rise -> vessel rupture -> fragment impact
                  -> puncture injury -> bleeding
```

Causality is recorded (§40).

> **Correction — a cascade has two distinct implementations and the draft
> conflates them.** In Quod, a reaction-driven hop is one consensus round: at
> ~5.7 slots/s (§21) a six-deep chain resolved through `react_on` takes seconds
> of wall clock. That is correct for ecology and wrong for an explosion.
>
> - **Instantaneous cascades** — everything that must appear simultaneous to a
>   player — resolve **inside one proof**, in one transaction, with an explicit
>   depth and fuel budget. Only the semantically durable endpoints and the causal
>   links are committed; intermediate arithmetic is not. An exhausted budget is a
>   loud, counted failure that rejects the resolution, never a silent truncation
>   of the chain.
> - **Deferred cascades** — combustion spreading over seconds, ecological
>   response, decomposition, population change — advance one hop per
>   world-tick transaction or through `react_on`, and are allowed to take
>   consensus time.
>
> Which class a cascade edge belongs to is a property of the rule and must be
> declared, not inferred at runtime.

---

## 20. Event resolution pipeline

```prolog
resolve_event(EventRef) :-
    runtime_snapshot(EventRef, Snapshot),
    derive_exposures(Snapshot, Exposures),
    combine_compatible_exposures(Exposures, AggregateExposures),
    resolve_material_interactions(AggregateExposures, MaterialEffects),
    resolve_anatomy_and_physio(MaterialEffects, BiologicalEffects),
    stage_ordinary_consequences(MaterialEffects, BiologicalEffects),
    detect_critical_triggers(EventRef, CriticalOpportunities),
    resolve_criticals(CriticalOpportunities, CriticalEffects),
    stage_critical_consequences(CriticalEffects),
    spawn_secondary_events(CriticalEffects, SecondaryEvents),
    mark_event_resolved(EventRef).
```

This runs inside `transaction/1`, whose semantics are already defined
(`doc/agent-fipa-plan.md` §6): semidet, first complete inner solution kept, full
restoration of staged asserts and retracts on failure.

`spawn_secondary_events/2` obeys §19's two classes: an instantaneous edge
recurses within this same transaction under the shared budget; a deferred edge
stages a durable pending-event fact for a later tick.

---

## 21. Significance filter — the primary constraint

The physics system generates a very large number of contacts. Most must never
reach semantic resolution. A cheap runtime filter in P decides significance from
relative velocity, impulse, heat flux, current, pressure, collision category, and
target sensitivity. The filter never decides injury; it only decides whether an
event is worth resolving.

> **Correction — this is the design's binding constraint, and filtering alone is
> not sufficient.** Measured behaviour of the live fleet: roughly 5.7 slots/s and
> a ~15 tx/s baseline (`doc/client-world-direction.md` §9), with **no headroom
> above moderate concurrency** and a documented congestion collapse under
> sustained burst load (`doc/deferred.md`, "Latency tail under burst load"). Four
> combatants swinging once a second already consume most of a world's durable
> budget if each swing is a transaction.
>
> Three rules follow:
>
> 1. **One transaction per world-tick, not per contact.** The authority
>    accumulates the tick's significant contacts and submits a single
>    batched resolution transaction. All of them resolve inside one proof. This
>    caps durable consequence at roughly the block rate — about five world-ticks
>    per second of committed consequence — independently of how busy the fight is.
> 2. **A world is a namespace** (§21.1). Sharding worlds across committees is the
>    only way this scales past one fight.
> 3. **The per-tick batch is bounded**, and overflow is an explicit, counted,
>    loudly-reported drop of the least significant contacts — never an unbounded
>    proof and never a silent loss.
>
> Everything a player perceives as instant — hit flashes, sparks, sounds, recoil
> — is a client cue emitted from P by the authority and is **never evidence that
> anything committed** (`doc/client-world-direction.md` §5). The durable
> consequence lands a few hundred milliseconds later and reconciles the client.

### 21.1 Namespaces, ownership, and cross-ontology boundaries

> **Correction — the draft never mentions namespaces, and for Quod that is the
> largest omission.** Consensus, committees, ACLs, throughput, and OCC conflicts
> are all per namespace. The design is not implementable until these are decided:
>
> - **One world is one namespace with its own committee.** Its throughput budget,
>   its physics authority, its contact resolutions, and its voxel overlays are
>   local to it. Two forests do not contend.
> - **Shared vocabulary is separate, mostly-static ontologies** — materials,
>   channels, anatomy, critical families, species. They change rarely, are read
>   by many worlds, and must not be founded per world. Worlds reference them.
> - **Player-owned state** (inventory, character, private preferences) lives in
>   user-owned ontologies, not in the world. A consequence that must change both
>   — a hit that destroys a carried item — crosses an ownership boundary and is a
>   distributed transaction under `doc/inter-ontology.md` rules, with the target
>   ontology executing an action request, never accepting a foreign ready-made
>   diff (`doc/agent-fipa-plan.md` invariant 6).
> - **A DTX per sword swing is not affordable.** Design the common combat path to
>   stay inside one namespace, and make cross-ontology consequence a deliberate,
>   rare, low-rate case.

### 21.2 Authorization

> **Correction — the draft does not say who may submit a resolution.** The
> submitter is the world's current physics authority, acting as a node principal.
> Today that shape uses the same typed action executor as signed client goals;
> the trusted node route derives its engine-owned principal, while signed goals
> carry their verified principal. Delegated FIPA authority remains future work.
> Until then, a world's resolution action is a node-principal action, and the write ACL for injury, critical, and
> death facts must be restricted to the authority for that world — otherwise any
> writer to the namespace can assert an arterial laceration.

---

## 22. Durable state D, projection P, effects E

**D — durable semantic causes and results:** `impact/…`, `exposure/…`,
`injury/…`, `equipment_damage/…`, `ignition/…`, `birth/…`, `death/…`,
`reproduction/…`, `depletion/…`, `critical/…`, `causes/…`, `contact_resolved/…`.

**P — rebuildable fast-changing projections:** current blood loss, oxygenation,
hunger, current luciole charge, body temperature, motor capability, population
estimates, nearby resource indexes, current behavioural goal, and the
physics-handle mapping.

**E — irreversible external behaviour:** animation, particles, audio, client
notification, localized critical text, UI effects.

Replay must not replay E.

> **Correction — P here is built by `state_handler` declarations, and those are
> currently genesis-only.** Section 8.1 of `doc/agent-fipa-plan.md`, as built in
> Slice 2, activates a handler only when its provenance is a full-term match
> against the founding block; dynamic declarations are refused and counted. Every
> physiological projection in §37 and every population index in §38 is such a
> handler. So either a world's handlers are fixed at founding, or
> `can_declare_runtime` and validator-side write authorization must land first.
> This blocks milestones 3 and 8 as written, and the plan must say so.

---

## 23. Lucioles — core ecological model

A luciole is a living organism that stores only a **small** quantity of usable
specialized energy. This is intentional.

- one luciole is weak;
- many lucioles can combine;
- devices can accumulate their output;
- players must be inventive.

Leverage comes from engineering, timing, geometry, storage, catalysts, and
cascades — not from collecting bigger batteries.

---

## 24. Luciole energy model

A luciole has an ordinary metabolism, a specialized reservoir, and a biological
transducer.

A fire luciole does not store high-temperature heat:

```prolog
reservoir(L, fire_charge, biochemical_potential, Capacity).

transducer(L, pyrogenic_organ, biochemical_potential, thermal_flux, Efficiency).
```

A cold luciole does not store cold; it spends internal potential to remove heat
from a target or move heat elsewhere. Electric lucioles use electrochemical
storage and discharge. Light lucioles convert stored chemical energy to
radiation. Mechanical lucioles store and release elastic, pressure, or impulse
energy.

---

## 25. Luciole individual identity

A charged luciole and its depleted soot form are the **same individual**. Never
delete a `fire_luciole` and spawn a `soot_creature`.

```prolog
species(l_492, fire_luciole).

phenotype(L, charged) :-
    reservoir_fraction(L, specialized, F), F >= ChargedThreshold.

phenotype(L, depleted) :-
    reservoir_fraction(L, specialized, F), F =< DepletedThreshold.
```

The individual retains age, injuries, genetics, learned behaviour, temperament,
ownership or taming relationship, and reproductive history.

> **Note — this is also the OCC-friendly choice.** Delete-and-respawn churns
> identity in D, invalidates every reference, and turns a phenotype change into a
> contended read-modify-write. A derived phenotype over an append-only reservoir
> history costs nothing in consensus.

---

## 26. Depleted "soot" form

On depletion the glow may disappear, flight may weaken or stop, the phenotype
becomes dark and soot-like, hunger and recharge need dominate, behaviour may
become irritable and opportunistic, and the creature may bite if compatible
energy or material can be obtained from a living target.

Do not hardcode `depleted -> aggressive`. Prefer:

```text
reservoir deficit -> high recharge need -> choose best available affordance
                  -> flower / fungus / resin / mineral / bite / ...
```

---

## 27. Resource is a relationship

Not an intrinsic object category.

Bad:

```prolog
resource(flower).
```

Good:

```prolog
usable_as(Flower, Luciole, food).
usable_as(Wood, Combustion, fuel).
usable_as(Wood, Player, structural_material).
usable_as(Corpse, Fungus, food).
```

One object is a resource for several processes at once.

---

## 28. Transformation processes

```prolog
process(Process).

requires(Process, material(Material, Quantity)).
requires(Process, energy(Form, Quantity)).
requires_condition(Process, Condition).

produces(Process, material(Material, Quantity)).
produces(Process, energy(Form, Quantity)).

byproduct(Process, Something).
limited_by(Process, Something).
catalyzed_by(Process, Something).
```

- **Combustion:** wood + oxygen -> gases + ash + thermal energy + radiation.
- **Photosynthesis:** CO2 + water + sunlight -> biomass + oxygen.
- **Luciole feeding:** nectar or resin -> digestion -> metabolic intermediates ->
  specialized reservoir + waste + heat.

---

## 29. Luciole recharge

```prolog
can_recharge(L, Resource, Pathway) :-
    affords(Resource, L, feed(Pathway)),
    pathway_yields(Pathway, specialized_reservoir, Yield),
    Yield > 0.
```

Species differ by pathway, not by colour. Every species answers the full chain:

```text
input resource -> internal conversion -> energy carrier / reservoir
               -> transducer -> output -> waste -> ecological niche
```

---

## 30. Combining many small lucioles

**A. Direct coherent combination.** Several lucioles discharge at one target.
Variables: timing, spatial overlap, orientation, coupling efficiency, heat loss,
electrical phase, mechanical geometry.

**B. Accumulation and storage.** Many lucioles slowly charge a store that is
released rapidly. Possible stores: capacitor, hot stone, pressure tank, flywheel,
spring, chemical intermediate, raised mass.

**C. Cascade and leverage.** A few lucioles cross a threshold that releases a much
larger environmental reservoir. The canonical case: fire lucioles ignite tinder,
tinder ignites wood, and the wood supplies most of the fire's energy. This should
be a major gameplay principle.

> **Note — B and C are also the throughput answer.** Direct combination (A) is
> the per-tick, high-frequency case and is bounded by §21's batch. Accumulation
> (B) is naturally low-rate in D: charge level lives in P and only crosses into D
> at semantic thresholds. Cascade (C) commits one ignition fact and lets the
> deferred cascade of §19 carry the rest. The gameplay principle and the
> consensus budget point the same way.

---

## 31. Criticals plus lucioles

Because each luciole is weak, criticals arise from accumulation,
synchronization, concentration, storage, coupling, threshold crossing, and
cascades.

```text
one fire luciole      -> small temperature increase       -> no critical
ten focused lucioles  -> dry tinder crosses ignition      -> THERMAL CRITICAL A

tinder fire -> resin vaporization -> flash  -> THERMAL CRITICAL C
                                            +  PRESSURE CRITICAL B
pressure exceeds container strength         -> STRUCTURAL CRITICAL D
fragment hits player                        -> PUNCTURE CRITICAL C
```

That is a causal critical cascade, and per §19 its early hops are deferred
(seconds of burning) while the container rupture and the fragment impact are one
instantaneous group.

---

## 32. Criticals as semantic phase transitions

> A critical is a semantic phase transition in the world.

Solid structure -> fractured structure. Unlit fuel -> burning fuel. Intact artery
-> severed artery. Operational capacitor -> dielectric failure. Healthy
consciousness -> unconsciousness. Stable ecosystem -> collapse or migration
regime.

This unifies Rolemaster-style drama with simulation causality, and it is also the
practical D/P dividing line: **a phase transition is exactly the kind of event
worth a durable fact**, while everything between transitions is P.

---

## 33. Devices

A device constrains, accumulates, redirects, or transforms exposure and energy.

- **Lantern:** luciole radiant output -> transparent enclosure -> illumination.
- **Heater:** fire luciole -> heat exchanger.
- **Steam machine:** fire lucioles -> heat -> water -> steam pressure -> piston ->
  mechanical motion.

A technology tree emerges from discovered transformations rather than arbitrary
unlock levels.

---

## 34. Player capture

The English term for *filet à papillons* is **butterfly net**. The net is
physically modelled:

```prolog
component(net_1, handle, stick).
component(net_1, hoop, flexible_branch).
component(net_1, mesh, woven_fiber).
```

Physics determines whether a flying creature enters and cannot escape the mesh
volume. Prolog determines semantic capture, ownership, and containment.

---

## 35. Ecology

```text
sunlight -> plant -> nectar/resin -> luciole -> player technology
```

Additional paths: luciole -> predator; corpse -> decomposer; decomposer -> soil
nutrients; soil nutrients -> plants.

Unsustainable harvesting alters the ecosystem. The intended emergent chain:

```text
mass use of lucioles -> many depleted soot-creatures discarded
                     -> strong recharge pressure -> resin/flower depletion
                     -> infestation / bites / migration
                     -> predator population response -> ecological cascade
```

This must arise from ordinary rules, not scripted quests.

---

## 36. Creature physiology

```prolog
physiological_store(L, metabolic_energy,     Current, Capacity).
physiological_store(L, hydration,            Current, Capacity).
physiological_store(L, repair_material,      Current, Capacity).
physiological_store(L, reproductive_reserve, Current, Capacity).
physiological_store(L, specialized_charge,   Current, Capacity).
```

Needs are derived:

```prolog
need(E, nutrition,    Urgency).
need(E, recharge,     Urgency).
need(E, shelter,      Urgency).
need(E, safety,       Urgency).
need(E, reproduction, Urgency).
```

Behaviour chooses actions from current needs and available affordances.

> **Correction — `physiological_store/4` as written is a read-modify-write and
> must not be durable.** Continuous stores live in P, derived from durable
> intake, expenditure, and injury events. Only threshold crossings — starvation,
> depletion, exhaustion — become durable facts.

---

## 37. Physiological projection

Durable causes in D: `wound/…`, `bleeding_source/…`, `burn/…`,
`toxin_exposure/…`, `lung_damage/…`.

Derived in P: current blood loss, oxygenation, body temperature, pain, fatigue,
motor capacity, consciousness risk.

Commit durable semantic transitions when important thresholds occur:
`unconscious/…`, `organ_failed/…`, `dead/…`.

This is the correct shape, and it is the same shape as §36. It depends on
`state_handler` declarations, subject to the §22 correction.

---

## 38. Population and semantic level of detail

Do not simulate millions of minor organisms as individual D entities.

```prolog
individual(luciole_418827).

population_cohort(forest_17, fire_luciole, adult, 8432).
```

Aggregate state: `cohort_biomass/…`, `cohort_reservoir/…`,
`cohort_age_distribution/…`.

Entering a region materializes some cohort members into individuals; leaving
aggregates them back where safe. Maintain approximate conservation of population
count, biomass, specialized stored energy, and reproductive state.

> **Correction — materialize/aggregate is the same identity hazard as §12.**
> Every transition needs a stable operation ID and an idempotent desired state,
> or a retried materialization duplicates biomass and a racing aggregate destroys
> it. Both directions are durable transactions with `ExpectedRevision`-style
> conflict detection on the cohort, exactly as voxel edits use
> `ExpectedRevisions` (`doc/client-world-direction.md` §7.2). The conservation
> invariant is testable and should be asserted in a test, not merely intended.

---

## 39. Transactional contact resolution

```prolog
resolve_contact(ContactId) :-
    physics_contact(ContactId, Sample),
    valid_contact_sample(Sample),
    classify_contact(Sample, Interaction),
    resolve_interaction(ContactId, Sample, Interaction, Consequences),
    assert_consequences(Consequences),
    assertz(contact_resolved(ContactId)).
```

The operation is idempotent. Action shape:

```prolog
action(resolve_contact(ContactId),
       [physics_contact_exists(ContactId),
        may_resolve_contact(ContactId)],
       contact_resolved(ContactId)).
```

> **Note — this is already the established Quod idiom**, identical in shape to
> `apply_voxel_edit/4` reaching `voxel_edit_applied/4`
> (`doc/client-world-direction.md` §7.2): a non-idempotent operation made
> idempotent by naming its own completion as the desired state, so `goal/1`'s
> read-only pre-check short-circuits an exact retry. Include the request identity
> in the desired state so a different operation reusing the same ID is not
> mistaken for success.

> **Correction — the committed unit is the tick batch, not the contact.** Per
> §21, the real entry point is one action per world tick:
>
> ```prolog
> action(resolve_tick(WorldId, Epoch, Tick, ContactIds),
>        [current_authority_epoch(WorldId, Epoch),
>         may_resolve_world(WorldId),
>         bounded_contact_batch(ContactIds)],
>        tick_resolved(WorldId, Epoch, Tick)).
> ```
>
> `resolve_contact/1` becomes an internal step inside that proof. `tick_resolved`
> gives exact retry idempotence for the whole batch, keeps one OCC read set per
> tick rather than per contact, and makes the per-tick budget of §9 and §19
> enforceable in one place.

---

## 40. Event causality

Every major consequence retains its cause links.

```prolog
caused_by(injury_981,        impact_77).
caused_by(impact_77,         vessel_rupture_12).
caused_by(vessel_rupture_12, pressure_event_9).
caused_by(pressure_event_9,  resin_flash_5).
caused_by(resin_flash_5,     ignition_4).
caused_by(ignition_4,        luciole_discharge_1).
```

This enables explanation, debugging, replay analysis, player-facing narrative,
simulation validation, and agent reasoning — and, given §18, it is also the
audit trail that makes a cheating authority detectable.

---

## 41. Conservation and accounting

Transformations account for input matter, output matter, input energy, output
energy, waste, heat, and losses. Not laboratory-grade, but resistant to arbitrary
creation or destruction of resources. Fictional channels declare their exceptions
explicitly.

---

## 42. Implementation milestones

> **Correction — the whole sequence sits after C2** (`doc/client-world-direction.md`
> §10), and every milestone below acquires two standing acceptance criteria:
> *it reports p50/p95/p99 commit latency and sustained transaction rate for its
> workload*, and *it states its per-resolution inference budget and shows the
> measurement*. `doc/agent-fipa-plan.md` §14.12 already requires the first of
> these from every slice.

**M0 — prerequisites and decisions** *(new)*. Decide the world-namespace layout
(§21.1), the authority trust statement (§2), the authorization principal (§21.2),
and whether `can_declare_runtime` must land first (§22). No code.

**M1 — contact bridge.** `quod_physics_predicates`, `physics_contact/2`, the
immutable snapshot, semantic IDs, fixed-point values, the authority-and-epoch
gate, and the per-tick batch action of §39. Tests: sword edge into wood, sword
edge into flesh, blunt object into flesh — plus a stale-epoch contact that fails
closed, and an exact retry of a tick that is a no-op.

**M2 — material interaction.** Material ontology, surface geometry classes,
mechanical channels, fracture/cut/penetration rules, structured material
consequences. Measure the layer-propagation cost against the M0 budget.

**M3 — anatomy and injury.** Human anatomy, wound IDs, structured injuries,
bleeding, loss of function, critical families, A–E presentation. **Gated on the
§22 handler-declaration decision.**

**M4 — critical micro-outcomes.** Seeded selection among plausible outcomes,
causal links, secondary event spawning, and the §19 instantaneous/deferred split
with its fuel budget. Include the §18 re-derivation test: recompute a committed
outcome from the snapshot, ruleset version, and seed, and assert it matches.

**M5 — thermal and ignition.** Temperature and heat-flux queries, heating and
cooling, ignition thresholds, combustion, thermal criticals. First real deferred
cascade.

**M6 — luciole species.** One species: `fire_luciole`. Small specialized
reservoir, depleted phenotype, recharge pathway, small thermal discharge, capture
with a simple net, individual identity, recharge-need behaviour.

**M7 — energy combination.** Exposure aggregation, synchronization,
concentration, a storage device, ignition by combined output. Demonstrate the §30
note: that accumulation and cascade are cheap in D while direct combination is
bounded by the tick batch.

**M8 — ecology.** Plant resource, feeding and recharge, soot-form behaviour, the
predator and decomposer loop, cohort LOD with the §38 conservation test.

**M9 — additional channels.** Electrical, pressure, chemical, respiratory,
ballistic armour, cold and heat extraction.

---

## 43. Non-goals for the first version

Do not build: full finite-element material simulation; exact cellular physiology;
every organ in 3D; millions of fully individualized insects; cryptographically
perfect multiplayer randomness; complete chemistry; all Rolemaster critical
tables; every possible energy channel.

Build a coherent architecture with a small number of representative cases.

> **Added non-goals.** Do not build a validator-side re-simulation of physics; do
> not attempt trustless combat in the first version (§2); do not put continuous
> physiological or charge values in D (§36); do not make the ordinary combat path
> cross an ontology boundary (§21.1).

---

## 44. Guiding principles

1. Physics and runtime measure.
2. Prolog interprets.
3. Durable D stores semantic causes and consequences.
4. P stores fast rebuildable projections.
5. E is emitted only from committed live state, and never from replay.
6. Every important event has identity.
7. Important consequences retain causality.
8. Criticals remain physically plausible.
9. Randomness selects unresolved plausible detail.
10. Resource is contextual, not intrinsic.
11. Energy is small, composable, transformable, and often leveraged.
12. Lucioles are organisms, not batteries.
13. Charged and depleted forms are the same individual.
14. Devices create leverage through accumulation and transformation.
15. Criticals are semantic phase transitions.
16. Combat and ecology use the same consequence engine.
17. Prefer emergent events over scripted exceptions.
18. Avoid logging every hot physics update.
19. Use significance thresholds before semantic resolution.
20. Design for explanation: the world should know *why* something happened.

> **Added principles.**
>
> 21. The world's physics authority is a trusted oracle; say so, and make its
>     output re-derivable so it is at least accountable.
> 22. The committed unit is the world tick, not the contact.
> 23. No read-modify-write on shared state; append keyed facts and derive
>     aggregates in P.
> 24. A cascade edge is either instantaneous-in-proof or deferred-across-ticks,
>     and the rule declares which.
> 25. Every bound — batch size, cascade depth, inference budget — fails loudly
>     and is counted. Nothing is silently truncated.
> 26. A world is a namespace.

---

## 45. One-sentence architecture

A Quod world is a causal network of matter, energy, organisms, processes,
exposures, transformations, and semantic consequences, where Erlang and Rust
observe quantitative reality on one authoritative node, Prolog decides what that
reality means, and consensus records the meaning — one world tick at a time — as
facts that anyone holding the same inputs can re-derive.

# Parent assessment of the Fable consultation

Fable's report is consultative. The parent checked its central claims against
the source after the review. This is a design assessment, not executed
verification. No server, client, live ontology, commit or deployment was changed.

## Accepted direction

- Keep ontology as an authenticated Prolog code/state/history boundary. Give it
  a first-class reflective representation without making an editable contact
  field an authority grant or a new lifecycle mechanism.
- Distinguish class membership, spatial containment, code location, state
  ownership, simulation authority and visual occurrence.
- Withdraw effective native-capability evolution as the default prerequisite
  for physics. Evaluate ordinary founding and explicit composition first.
  Preserve the original space subject and ontology history.
- Reuse the existing atomic transaction, adopted-description, resource,
  authority-fence and recovery machinery. Generalize mixed scene projections.

## Corrections and qualifications

1. **Generic foreign embodiment is not already implemented.** The existing
   adoption action is specifically for doors and validates boxes
   (`priv/ontologies/quod_physics.pl:323-360`). It is a useful production seam,
   not a general placeable-object implementation. Control configuration requires
   a local agent instance and builds its reference from the containing ontology
   (`:106-133`). Removing the foreign `depicts` restriction does not supply
   foreign-agent control, placement ownership or a complete adoption protocol.

2. **Read-only consent does not establish exclusive placement.** Two independent
   spaces can read the same unchanged `can_be_placed` fact and both commit their
   own body. OCC need not reject either. If the object's policy requires one
   active physical embodiment, an existing authoritative object owner must
   serialize its assignment/epoch in the same atomic transition as admission
   into the simulation domain. That assignment and the domain's accepted body
   describe different responsibilities, not two competing position stores.
   Multiple embodiments require explicit policy and distinct body identities.

3. **Live occupancy is not a durable proof input.** An authored baseline may
   commit and then be found occupied at installation. The client must distinguish
   accepted configuration from usable physical placement. A durable claim that
   placement was physically fulfilled needs the existing signed-observation
   and committed-consequence pattern; a live query cannot authorize a write
   (`doc/proofs.md:27-32`, `doc/world.md`, oracle boundary).

4. **Atomic facts alone do not finish a live simulator transfer.** The source
   and destination need an explicit assignment fence, checkpoint/frame mapping,
   retirement/activation ordering, installation evidence and treatment of
   old in-flight controls. A partitioned old owner may show stale motion until
   it learns the new state (`doc/world.md:226-233`). Do not claim immediate
   global quiescence or seamless crossing from a two-ontology diff. Keep transfer
   between independent simulations outside the first lobby slice. Rooms sharing
   one simulation authority do not require that transfer.

5. **An existing reference is not the entire composition contract.** The client
   currently asks the acting agent's ontology for `physics_client_world/1`
   (`client/src/simulation.js:14-24`). Adding that rule only to the lobby does
   not automatically make it discoverable there. The endpoint subscribes to
   the source and simulation scopes (`src/quod_client_simulation.erl:41-57`);
   a distinct visual-space owner introduces dependencies that must be retained
   too. An exact link from the original space subject to the simulation domain
   and its visual/body mapping is still required.

6. **Runtime selectors cannot consult a foreign grant on demand.** They use a
   local policy-verdict proof. Foreign admission belongs in an ordinary action
   with certified dependencies, producing an explicit committed delegation.
   That delegation's revocation must update its actual owner; changing a source
   permission for future admission cannot silently revoke already-admitted use.

7. **Reflection must not invent a complete ontology registry or public API.**
   `system_ontology/2` lists system ontologies, not every private ontology.
   `public_source_query/1` describes discovery/source query shapes and is not a
   complete exported-method catalogue or an invocation grant. Expose derived,
   authorized metadata about exact known references. Do not mirror root or
   routing state as mutable ontology-object fields.

8. **No universal one-space/one-ontology rule follows.** The runtime's physics
   projection accepts distinct world rows (`src/quod_physics.erl:615-621`), while
   the documented first client/control profile is narrower. Spatial rooms can
   share a simulation domain. Choosing an ontology boundary remains a governance
   and lifecycle decision, not a consequence of `isa(physical_space, space)`.

## Revised recommendation

Use the class/instance distinction and reflective ontology model now. Model
spatial containment separately from physical participation and simulation
assignment. Prefer the existing immutable bridge/lifecycle path for the first
physical integration, with a normally founded linked domain where the current
ontology lacks the bridge, but treat its ownership/projection mapping as real
design work. Do not advertise this as only two small Prolog edits. Keep live
cross-simulation transfer and fully general foreign-agent embodiment outside
the first slice unless they are necessary for the actual lobby acceptance.

The revised current proposal is [governed-physics-plan.md](../../governed-physics-plan.md).
The pre-review proposal remains byte-for-byte in the frozen review tree.

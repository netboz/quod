# Assessment of the ontology representation followup review

The [Fable followup report](review-03/fable-review.md) supports reusing ontology
instances, lenses, encodings, Eidolons, marks and existing authorized actions.
It explicitly corrects the earlier claims about generic adoption, exclusive
placement, live occupancy and simulator transfer. The following assessment is
based on independent source inspection, not executed behavioral tests.

## Retained conclusions

- Derive an ontology's class/instance description from its own anchored identity,
  not root's partial system catalogue. Generic membership is not fully wired now.
- Reuse existing representations and editing. Do not create another ontology
  registry, presentation engine, ACL store or mutation owner.
- Expose policy through authorized reads. Policy text, source access, invocation
  and policy editing remain distinct. A displayed verdict grants no later action.
- Location and state ownership remain separate under applicable ACLs and domain
  policy. Exclusive assignment changes through its actual owner atomically with
  admission when exclusivity is required.
- Ordinary founding and explicit composition remain the linked-physics candidate;
  mutable native membership is not the default prerequisite. Independent simulator
  transfer stays outside the first acceptance slice.
- Do not introduce a domain class called subject. Use class, instance or ontology
  where intended. A wider terminology document remains separate work; no new
  ticket was created.

## Corrections and qualifications

1. **Two declarations are not complete integration.** Self-membership clauses
   can close a classification gap. Retiring ontology_eidolons/1 also requires
   updating public read shapes, target construction, dispatch, callers and tests.
   [world.js](../../../client/src/world.js), lines 120-155, currently selects the
   separate ontology lookup and verifies exact workspace target preservation.
   Foreign instance queries still require the target's ACL; declarations grant
   no new permission.

2. **Query-shape helpers are not universally public catalogues.**
   [quod_lens.pl](../../../priv/ontologies/quod_lens.pl), lines 59-86, uses
   lens_query/1 to admit listed goals but does not expose lens_query/1 itself.
   Source-query helpers likewise are not automatically callable catalogues.
   [quod_root.pl](../../../priv/ontologies/quod_root.pl), lines 48-74, explicitly
   exposes particular reads, not complete universal ACL introspection. Curated
   ACL views need governed disclosure, not inferred public access.

3. **Interactive 3D Eidolons are not generally recipe-only today.** An anchored
   read-only lens can reuse marks, but [World.tsx](../../../ui/src/World.tsx),
   lines 250-261, opens every selected Eidolon workspace as a code form. General
   3D interaction needs a bounded extension of that existing path. The existing
   guarded edit compiler is reusable; semantic gestures still need explicit
   mappings to authorized actions. A general menu refactor is a candidate after
   tracing callers, not automatically a prerequisite for every source/ACL view.

4. **Space is not yet the general class contract described in the report.**
   The code declares lobby below thing with concrete membership/placement facts.
   Yan's nonphysical organizing spaces need not require physical frames.
   Inheritance alone would not force durable layout or physics activation.
   Keep spatial representation independent of mandatory ontology-to-space
   ancestry. The report's suggestion to await a second implemented space class
   is not an established rule or acceptance condition.

5. **Linked physics still needs the original-lobby contract.** A user-side
   physics reference and B-owned colliders do not by themselves specify the
   original selected space, exact instance/body bindings, or their edit,
   deletion, withdrawal and recovery dependencies. Explicit B-owned physical
   definitions can be legitimate; an undocumented geometry snapshot cannot.
   Generic foreign-chair transfer can be deferred, but the identity, permission
   and revision obligations needed for actual lobby acceptance cannot.

6. **Locality and founding restrictions need precise scope.**
   [quod_client_simulation.erl](../../../src/quod_client_simulation.erl), lines
   41-58, checks user and simulation scopes for local availability. A third lobby
   dependency is missing, not already governed by a three-scope co-hosting rule.
   Explicit co-hosting may be a bounded first profile; no remote-stream expansion
   is authorized here. The delegated lobby creation policy cannot found a physics
   sibling, but root also has separately authorized node/administrator creation
   paths. Select a governed path, without borrowing elevated authority.

## Implementation boundary

Settle exact ontology instance/target handling, authorized ACL reads and the
original-lobby/user/physics association through existing owners. Define the
physical bindings and their change/withdrawal dependencies. Then implement
bounded owner/client changes, explicit geometry and camera/control definitions.
Generic tests, unchanged-repeat measurements, exact invalidation and real signed
normal-lobby acceptance remain required.

This review changes no production behavior and does not approve deployment or
complete the tracker. The current plan was not rewritten during this review;
the [latest requirements](followup-request.md) and this assessment qualify wording
that predates Yan's refinements. The parent's checks also inspected the existing
client world/edit adapters, which were not transmitted in the Fable bundle.

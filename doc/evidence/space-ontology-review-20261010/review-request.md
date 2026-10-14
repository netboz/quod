# Fable consultation: spaces, objects and ontology ownership

Yan explicitly requests this Fable review and elaboration. It is consultative,
read-only architecture work. Read the frozen AGENTS.md first. Do not edit any
file, run commands/builds/tests, delegate, start another review or access live
systems. Use only Read/Grep/Glob on this frozen tree. Return your report as the
final response; the parent captures it. Do not invoke the stop notifier: the
parent owns user notifications and your tools are deliberately read-only.

The working directory is a frozen review tree. source-manifest.json beside it
records the exact inputs. Paths below are relative to this tree. The private
repository sources and this task are the authorized payload for this requested
review. Do not inspect credentials, personal files or unrelated project work.

## The latest question supersedes the earlier recommendation

Yan: "the issue is that we are mixing ontologies which are a container for
prolog code with classes which are real virtual objects. Shouldn't we have so
a class space that contains other classes ? An ontology would just be a class
like ano other one having its contact address of code as fields. ? Just thinking"

Parent clarification, still exploratory: distinguish classes, instances,
spatial containment, shared code definitions and authoritative state ownership.
A space instance contains instances, possibly owned by different ontologies.
Ontology can be a first-class domain object exposing code/interface/contact
metadata, while its runtime remains the authenticated proof/state/history
boundary. Moving through a space need not migrate the object's identity or
code. Classes themselves may have inspectable/visible representations.

The earlier doc/governed-physics-plan.md recommends keeping physical state in
the same ontology and introducing governed effective native-capability changes.
THAT RECOMMENDATION IS NOW PROVISIONAL. Do not endorse it merely because it is
written. Review whether it solved a modelling confusion with unnecessary native
module machinery. Do not assume a separate physics component is already the
answer either; trace each option through existing owners.

## Required review and elaboration

1. Give a clear conceptual model for class, instance, space, physical space,
   ontology and agent. Separate spatial containment, code lookup, mutable-state
   ownership, physics authority and visual representation. Explain whether
   "ontology is an ordinary class/object" is useful reflection or a deeper
   runtime change, and what minimum privileged bootstrap remains.
2. Ground the model in actual isa/2, instance_of/2, anchored references, :: proof
   scopes, Eidolons, lifecycle, runtime selection and multiwrite behavior. Mark
   existing support, proposed vocabulary, missing implementation and decisions
   distinctly. Class inheritance must not magically execute foreign behavior,
   install native predicates or grant rights.
3. Address the important missing case: an object whose durable owner is in one
   ontology is placed in a physical space owned by another. Which owner holds
   containment, adopted collider/revision, transient pose, control grants and
   recovery checkpoint? Explain authorization and changes without shadow KBs,
   per-tick cross-ontology writes, request-time rebuilds or a second simulator.
   Distinguish a future general model from the smallest supported first slice.
4. Evaluate existing immutable bridge membership fairly: same-world capability
   evolution versus a normally founded, explicitly linked simulation authority
   versus an existing bridge path, if one actually suffices. Identify a concrete
   missing capability and the least conceptual expansion. Preserve actual world
   identity/history; no refound, global bridge loading or hidden native fallback.
5. Walk a chair entering/leaving a room, changing physical form, crossing two
   physical spaces, owner/authority failure, revocation and uncertain writes.
   Require existing atomic domain transitions and recovery owners where these
   form one transition. Explain how late frames and stale proofs are fenced.
6. Explain ordinary client views: mixed decorative and body-bound marks,
   observer/body/head movement, authored camera mount, physical/nonphysical
   spaces, occupied placement, moving doors and explicit unavailable states.
7. Recommend a concrete conceptual direction and a bounded implementation
   sequence. Identify which earlier plan claims should be withdrawn, retained
   or revised. Do not declare architecture approval or runtime acceptance.

## Reading order (stay focused)

- AGENTS.md; doc/proofs.md; doc/lifecycle-and-routing.md;
  doc/runtime-and-agents.md; doc/multiwrite-architecture.md.
- doc/world.md (authority, revisions, recovery and owner path);
  doc/physics-native.md; doc/governed-physics-plan.md.
- priv/ontologies/common_predicates.pl (isa/2, class/ontology Eidolons),
  quod_agent.pl, agent_instance.pl, quod_environment.pl, quod_lobby.pl,
  lobby_instance.pl, quod_physics.pl.
- src/quod_agent_ref.erl; src/quod_committed_projection.erl;
  src/quod_predicates.erl; src/quod_commit_validation.erl;
  src/quod_runtime.erl (local resource selection/physics installation only);
  src/quod_physics.erl (world identity/selection boundary only).
- ui/src/World.tsx; client/src/simulation.js;
  src/quod_client_simulation.erl (normal-view integration limits).
- If needed: doc/outdated/ontology-actor-architecture.md section 3 for the
  founding-module contract; doc/evidence/player-movement/live-lobby-20261009/README.md
  and cleanup-20261009/README.md for the removed, unaccepted experiment.

The recorded October 10 candidate-network refound makes the October 9 personal
lobby anchor historical; fresh signed identification is still required before
live acceptance. A system lobby vocabulary is not the personal lobby. This is
not a live deployment review.

Please return a substantive but focused report, roughly 1,500–2,500 words.
Lead with your recommendation, include the strongest objections/tradeoffs,
use small illustrative Prolog examples, cite file:line evidence for crucial
implementation claims, and conclude with concrete unresolved decisions.

# Fable review of ontology representations and governed physics

Yan explicitly requests another Claude review of the complete discussion,
using Fable under AGENTS.md. This is a fresh read-only consultation. Read
AGENTS.md first. Use only Read/Grep/Glob on this frozen tree. Do not edit files,
run commands/builds/tests, delegate, contact live services, or invoke a notifier.
The parent captures your final report and owns notification. No implementation,
deployment, refound or tracker closure is authorized.

The frozen sources and this brief are the review payload. Do not inspect
credentials, personal files or unrelated project data. The manifest beside
this tree identifies exact source bytes. Earlier evidence is consultative;
check its claims independently rather than treating it as accepted design.

## Latest user requirements

These refinements supersede conflicting wording in doc/governed-physics-plan.md,
which has not yet been updated to include them:

- An ontology is an instance of the ontology class and should reuse the ordinary
  Eidolon, lens, encoding, mark and authorized interaction machinery. Refine
  existing mechanisms where necessary; do not invent a parallel presentation
  system or a new registry of ontology objects.
- An ontology object should expose its ACLs, as well as its identity, source,
  interfaces and contacts. ACL exposure itself remains governed. Source read,
  policy read, action invocation and policy editing are distinct authorities.
- Location and ownership are independent only subject to applicable ACLs and
  domain policy. Seeing a representation does not grant physical admission,
  editing rights or permission to change another ontology.
- Quod is not only a way to enter simulated rooms. Users must be able to see
  ontology contents in 3D and interact with them to edit and build ontologies.
  A space may be nonphysical and organize information/classes/instances.
- Yan asks whether every ontology should systematically be a space. The
  parent's tentative distinction is universal authorized spatial exploration
  through existing representations, not necessarily isa(ontology, space).
  Evaluate this distinction; do not invent an abstract container hierarchy to
  avoid answering the question. A class diagram, workbench and ACL inspection
  are purposes of existing representations, not new architectural categories.
- Avoid unexplained new domain terms such as "subject". Existing subject/2 in
  the editor is a target term, not proof of a new domain class. Use precise
  existing terms (class, instance, ontology, Eidolon, mark, lens, encoding).
  A terminology document may deserve a separate task; do not broaden this
  review into a terminology rewrite or create that task.

## Original physics obligations still apply

The integration is generic, not a lobby special case. Prolog explicitly decides
whether physics exists/enables, grants controls and allocates resources. Keep
one existing physics authority and one owner per mutable truth. Preserve the
existing lobby identity/history. The removed experimental native-membership
implementation was never deployed and is not an accepted design.

The current proposal favors ordinary founding of a physics-capable ontology
and an explicit association where the existing ontology lacks the immutable
founding bridge, rather than native effective-membership changes. This is a
candidate, not an implemented composition contract or permission to refound.

Keep explicit supported body shapes and authored camera mounts, ordinary signed
views with mixed decorative/body marks, and distinct observer/body/head motion.
Do not derive colliders from GLBs, picking bounds or Eidolons. Preserve actual
lobby openings/roof/console geometry. Future noncubic chunks use the same
geometry, resource-policy and revision contract, without requiring terrain
streaming now. Handle disabled/unavailable, occupied placement, edits/deletion,
moving doors, revocation, reconnect and authority/recovery fences.

Generic owner tests, unchanged-repeat work measurements, exact invalidation and
real signed normal-lobby desktop acceptance remain required. Vive/WebXR physical
acceptance is separate. No tests or live acceptance have happened in this review.

## Review questions

1. Is the refined ontology-instance model coherent with existing source? Identify
   what already exists versus declaration/lookup gaps. In particular, inspect
   ontology_eidolons/1 versus entity_eidolons/2, instance_of/2, exact anchored
   references and the actual editor target accepted by the existing Eidolon.
2. Trace ontology code/class/ACL inspection and editing through current lenses,
   encodings, Eidolons, marks and action owners. Do not assume a fixed linear
   pipeline if the code does not have one. Identify the smallest missing seam
   for the proposed 3D representations; distinguish recipe work from runtime work.
3. How should ACLs be exposed without another mutable ACL store, leaking private
   policy or claiming arbitrary Prolog permissions can be completely enumerated?
   Treat effective permissions as contextual, not transferable preflight grants.
   Preserve principal and actual calling-path semantics. No probing that executes
   proposed actions or exposes an arbitrary privileged authorization oracle.
4. Recommend whether ontology should inherit from space, or have ordinary
   spatial representations, using a concrete definition of space. What would
   inheritance require beyond rendering? Do not equate nonphysical with nongraphical.
5. Detail governed transitions using a chair defined/owned in A and admitted
   to a space/physics owner in B: authorization, exclusive placement, revisioned
   edits, active withdrawal, rollback, recovery and uncertain outcomes. Related
   durable state changes use existing ordinary/atomic actions. Read-only foreign
   dependencies are not writers. Ordinary layout changes and transient movement
   are not automatically distributed durable transactions.
6. Reassess the linked-physics candidate under this reuse constraint. Is there a
   concrete smaller path? Account for actual normal-view discovery, dependencies,
   local controlled-agent assumptions and immutable native bridge membership.
   Do not hide a second world identity behind a view or silently restrict required
   existing identity/history preservation. Distinguish explicit mapping from refound.
7. Flag the strongest contradictions or overclaims in the parent's explanation
   and your earlier report. Classify blockers versus refinements and give a
   bounded sequence that does not absorb every generalization into the lobby task.

The previous parent disposition corrects four important earlier overclaims:
door adoption is not generic foreign embodiment; read-only consent cannot
serialize exclusive placement; live occupancy cannot validate a durable diff;
atomic facts alone do not implement safe live transfer between simulations.
Check these, and do not silently reintroduce them. Independent-simulation
transfer is deferred unless demonstrably required by actual acceptance.

## Sources and report

Read AGENTS.md, doc/proofs.md, doc/multiwrite-architecture.md,
doc/lifecycle-and-routing.md and doc/runtime-and-agents.md. Use doc/world.md
and doc/physics-native.md for authority, oracle, revision and recovery contracts.
Read the current proposal and previous parent disposition. The earlier report
is included for comparison, not as an authority.

Prioritize priv/ontologies/common_predicates.pl, quod_lens.pl, quod_prolog.pl,
quod_prolog_eidolons.pl, quod_rendering.pl, quod_root.pl, quod_lobby.pl,
lobby_instance.pl and quod_physics.pl. Then inspect focused sections of the
frozen Erlang owners and client files as necessary to establish actual gaps.

Return a focused report of about 1200-1800 words. Lead with a verdict and the
most important corrections. Cite file:line evidence. Separate existing support,
proposed refinement and unresolved decisions. Include a compact terminology
clarification only where needed; avoid adding architectural names. Finish with
a short user-facing explanation and concrete prerequisites for implementation.

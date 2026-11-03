# Ontology instances through existing Eidolons

Implement the ontology representation refinement through existing owners and
signed reads/actions. This scope changes packaged source and clients; it does
not authorize deployment, refounding, history deletion or a version bump.

1. Derive `instance_of(ontology, ontology_ref(Namespace, Anchor))` from the
   executing owner's `current_ontology_identity/2`, and declare ontology below
   space for ordinary predicate-contents display (Yan’s 2026-11-03 clarification). `ontology_ref/2` is data, not a qualified name;
   keep ordinary `instance_of/2` and `isa/2` following intact. Replace
   `ontology_eidolons/1` and the client-only
   ontology selection kind with `entity_eidolons/2` everywhere, including signed
   acceptance tests. An ontology selected from the system catalogue, an owned
   ontology, or an anchored mark has the same exact instance term. The catalogue
   continues to contain only its existing system identities.

2. Extend the existing governed `prolog_inspect/3` and source-lens path with
   separately named ACL-policy and explicit-interface selections. ACL text uses
   the target's source-read authorization and snapshot; showing it does not
   authorize invocation or editing. Interface declarations are explicit ordinary
   authored facts, not inferred from `*_query/1` helpers. Return bounded answers
   using the existing cursor/formatting machinery, extending its chunk selector
   for predicate lists and already selected terms. Explicit interface facts in
   this scope belong to the Prolog tools and lens APIs; other targets accurately
   return an empty declaration set. Routes are
   live observations from the directory's existing exact-identity lookup through
   the selected owner, with no arbitrary-target directory enumerator and no
   persistence. Extend the existing runtime-predicate owner with an argument-free
   target identity read delegating to `validator_routes/2`; do not broaden root's
   public directory API. Private routes remain visible only through authorized
   target inspection. Missing/conflicting routes report availability accurately.

3. Correct recipe admission so opening any source view checks the real target's
   read path rather than merely its identity. System source modes continue to
   come from root's exact anchored policy. For non-system targets, use explicit
   authored presentation mode rules sharing existing ownership predicates;
   absence of an editable declaration must never imply editable. Such modes
   are advisory; every submitted edit retains actual `can_invoke/4`, exact
   baseline comparison, normal transaction/conflict checks and outcome recovery.
   Do not evaluate mutations to classify access. Policy edit and content edit
   remain separately identifiable operations; no invocation summary claims a
   universal permission verdict. No privileged arbitrary-goal oracle is added.

4. Associate policy/interface/route inspection with the ontology class through
   ordinary class Eidolons. Retain the existing source workspace as one supported
   result and add a bounded lens result to the same recipe consumer, so selecting
   a non-code representation does not force `codeForm`. Keep the exact target and
   instance in every result and validate them in the client. Preserve exact
   anchors through generated ontology marks/lens subjects. A view occurrence
   remains presentation; it creates no ontology, owner, assignment or physics.

5. Verify through real signed production seams: system read-only and administrator
   access, owned non-system access, private/other-owner refusal, wrong target
   anchors, policy-source disclosure without invocation, forbidden policy edits,
   stale presentation permissions, baseline races, exact committed outcomes,
   retained cursor snapshots and restart history. Reuse and extend the existing
   no-I/O tracing to prove unchanged inspections do no replay, rebuild, write or
   sync; a real edit must remain observable through all relevant views. Run
   applicable clean sequential Erlang/client/type-check gates with full logs and
   actual child exits. Preserve failures rather than silently rerunning them.

Review the frozen plan and source with the explicitly requested Claude Fable,
check findings independently, then implement. Freeze and review the final scope
with Fable again after verification. Preserve all existing workspace changes;
record this session's production delta against its start baseline. Update the
tracker to in-review when complete and uncommitted.

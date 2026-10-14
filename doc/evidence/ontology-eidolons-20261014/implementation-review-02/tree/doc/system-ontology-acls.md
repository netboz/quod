# Ontology source access

Source-read permission covers the complete current stored knowledge of an exact
ontology identity. It is independent of permission to invoke its predicates or
change its state. Public API selectors govern execution only; there is no
per-predicate source whitelist.

## Authority

Root's `system_source_access/2` classifies an exact namespace and genesis anchor.
Ordinary authenticated principals can read catalogued public system ontologies,
including `quod:node` and `quod:modelling`. Root and signup state remain restricted
to root administrators. A personal ontology continues to admit reads and writes
through its own `can_invoke/4` ownership policy.

System targets admit only the anchored `system_prolog_introspection/2` wrapper
and the anchored `(system_prolog_edit, transaction(Body))` edit wrapper. Reading
rechecks root's source permission; editing rechecks root's administrator
permission. Call-chain names confer neither. A missing retained target wrapper
refuses the read rather than falling back to a subset. Wrong anchors fail before
content is returned. Root itself is pinned to its bootstrap identity by node
configuration.

The source tool selects the system wrapper when root grants system access;
otherwise the target's ordinary admission governs `prolog_introspection/2`.
These operations only enumerate or format stored source. Parsing or compiling
an edit remains read-only. Its separately signed goal must pass the target's
edit gate, compare its exact baseline, stage the ordinary transaction and pass
commit conflict checks. A source-read grant authorizes no arbitrary meta-goal,
mutation, private API invocation or personal-ontology access.

## Current state and lenses

The default `prolog_source(Target, Chunk)` uses the `ontology_source` lens in
`quod:lens`. Its textual encoding returns all stored interpreted facts and rules
from one proof's existing owner snapshot. Shared Quod rules, policy, dollar-named
helpers and the stored `isa/2` semantics are included. Compiled engine procedures
and generated following clauses are not stored interpreted knowledge and are
omitted by engine classification, not by a name filter.

The existing signed cursor retains that snapshot through every chunk. The lens
owns the chunk-size policy; chunks have `more` or `done` markers and never discard
content. The client assembles bytes with streaming UTF-8 decoding and displays
only a complete result. Cancellation closes the cursor; expiry or transport
failure reports an incomplete read. Refresh opens a new snapshot. There is no
request-time ledger replay, second knowledge base or per-predicate assembly of
the complete view. Canonical formatting is performed for each requested read;
unchanged reads require no state rebuild, history scan or file writes.

`predicate_source` is an explicitly selected narrower lens. The source tool's
`prolog_source/3` delegates to it, including when opening an editing baseline.
The existing lens `view/3`, `rows/3` selection and `laid_out/4` encoding path also
continues to serve graphical lenses. Clients render their answers; they do not
own a visibility allowlist. The default editor selection is complete state, with
the target's genesis anchor displayed. Editing uses an explicit predicate lens
and retains the existing signed preview, Accept, recovery and conflict workflow.

## Ontology instances and inspection representations

Each executing owner derives `instance_of(ontology, ontology_ref(Ns, Anchor))`
from its existing proof-bound identity. The instance uses ordinary
`entity_eidolons/2` selection. Catalogue entries and anchored marks carry that
same term; a mark id remains an occurrence. Ontology membership is independent
of space membership, spatial placement, ownership and physics policy.

The source recipe checks authorized target introspection before returning its
workspace. Non-system presentation modes are advisory projections of existing
ownership predicates; undeclared modes are read-only and ambiguous modes refuse
selection. Systems retain root's exact source classification. A displayed
editable mode never replaces admission of the separately signed edit.

The ontology class also offers `lens_view/5` results for `ontology_policy`,
`ontology_interfaces` and `ontology_routes`. These are inspection consumers,
with no code-workspace assumption. Policy text selects the ACL entry rules
`can_invoke/4`, `can_join/3` and `acl_sovereign/1`; referenced helper definitions
remain available in complete source. Interface text selects explicitly authored
`ontology_interface/2` declarations. Declaration absence means no declared
interface, rather than an inferred catalogue from query-shape helpers.

Both selections use the target's source-read admission and existing snapshot
cursor. The common chunker accepts `all`, `predicates(Indicators)` and
`terms(SelectedData)` selections. Its selection and byte allowance are supplied
by Prolog. Inspection does not execute source or permission probes. Source read,
policy read, invocation, content edit and policy edit remain separate operations;
the target's current ACL governs actual invocation and every edit.

Route inspection derives only the executing owner's namespace and anchor and
reads the existing directory's exact confirmed-validator lookup. Private
contacts remain behind target inspection admission; root's system catalogue and
public directory API gain no personal-ontology enumeration. Results identify
live availability or anchor conflict and carry endpoint and route-generation
provenance. An endpoint is a route, not ontology identity or a committed field.
The governed live dependency blocks a durable diff using that observation.
Repeated unchanged inspection reads retained state and route indexes without
history replay, projection rebuilding, file writes or syncs.

This packaged refinement changes the common chunk primitive's arity and the
authored selection/recipe/lens definitions. Activating it in retained histories
requires the existing coordinated compatible-artifact procedure and authorized
exact-baseline policy/source transition. Package editing authorizes no such
deployment, history deletion or refounding.

## Retained-history activation

Package files alone do not update deployed ledger policy. This change authorizes
no re-founding, deletion, ledger rewrite or deployment. Use the existing cold
coordinated release procedure for the changed common primitive and common Prolog
helpers: no proof or validator may span incompatible artifacts. Keep exact
namespace/anchor identities, keys, ledgers and pending-operation custody.

Prepare the policy transition while the current authorized maintenance principal
can still inspect every affected exact target. Retain ordered canonical baselines
and compile the following replacements through the existing source compiler:

- Root: replace `root_public_goal/1` and `system_source_access/2`; remove obsolete
  `system_prolog_predicates/2` and `system_prolog_source/3` relays. Preserve other
  catalogue, administrator and target-specific policy clauses.
- `quod:prolog`: replace source dispatch/query declarations; install
  `prolog_inspect/3` and both source lens delegates; remove superseded dispatch.
- `quod:lens`: add the two source lenses, textual encoding, source rows and
  chunk-size policy while preserving existing graphical lenses and order.
- `quod:prolog:eidolons` and `quod:gui`: replace source-view selection and labels.
- Catalogued system targets: remove `public_prolog_predicate/1` declarations.
  Retain their execution APIs and exact source-wrapper admission. Install that
  narrow gate only where the retained target lacks it, using its pre-existing
  maintenance authority. Do not bootstrap authority through the proposed gate.

Collect these exact-baseline target goals into **one existing atomic
multi-ontology transaction**: the dispatch, lens and access policy form one
transition. The public `quod:present` name in older deployments has no authored
source in this tree; inventory and authorize its retained policy separately,
without treating it as `quod:gui`. Do not broaden private targets as a shortcut.

Before submitting, verify the complete frozen before/after definitions and
candidate compatibility with the authorized operator. Retain the exact signed
request, signature, operation identity and any returned group reference. Resolve
an uncertain result through existing outcome lookup; never resubmit it as a new
operation. A baseline conflict requires a new inspection and reviewed delta.

After certified applied success, read back every changed definition and run
ordinary-user complete-source, explicit-lens, wrong-anchor, personal-target,
invocation-refusal and administrator-conflict probes. Restart from the same
retained ledgers, resolve pending atomic obligations, and repeat those probes.
Verify an unchanged repeat causes no replay, rebuild, write or sync before
reopening traffic. Record identities, exact baselines, signed operation/outcome,
readback and recovery evidence in the deployment handoff.

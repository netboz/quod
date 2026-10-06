# System ontology source ACLs

System ontologies are shared knowledge, not shared mutable state. Their public
query APIs and the definitions needed to use those APIs are readable by an
ordinary registered principal. Mutation remains governed by the target
ontology, with root administrators using root's existing administrator fact and
every target call retaining its exact genesis anchor. Root is named without an
anchor by choice: the engine resolves `quod:root` to the one bootstrap identity
pinned in node configuration and reports an anchor conflict for any second
history of that name, so repeating root's anchor in every read goal would add
nothing the configuration does not already guarantee.

## Policy model

Each public system ontology declares `public_prolog_predicate/1` facts for the
supported predicates whose complete definitions may be inspected. The common
`public_prolog_predicates/1` and `public_prolog_source/2` helpers enumerate and
read only those declarations. `ontology_eidolons/1`, `entity_eidolons/2` and the
two public source helpers are discovery queries. Merely using read mode does
not authorize any other goal.

The `quod:prolog` tool distinguishes three authorities in this order:

1. A root administrator may fully inspect a catalogued system ontology and
   compile an edit wrapped by the exact target, which re-checks root's
   administrator fact before mutation.
2. A principal already authorized by a target keeps that target's existing full
   inspection and editing rights.
3. Other registered principals may enumerate and read only the target's public
   declarations.

An administrator whose catalogued target does not yet admit the wrapper falls
through to that third path and sees the public declarations; the editor view
stays administrative and a save reports the target's refusal.

The target still checks every entered scope. It admits only exact
`system_prolog_introspection/2` and `system_prolog_edit/1` wrapper shapes. Each
wrapper re-enters root and checks the authenticated principal against root's
administrator fact before reading non-public source or starting a transaction;
intermediate call-chain names are provenance, never authority. The edit
compiler's baseline comparison is retained. Compiling or previewing an edit is
read-only; the separately signed generated goal must still pass target
admission and root's principal check.

## Reviewed catalogue policy

The current candidate catalogue contains the following eighteen authored
system ontologies. “Public source” lists the supported API definitions, not
every implementation helper or fact in the ontology.

| Ontology | Supported public source | Retained restriction |
| --- | --- | --- |
| `quod:agent` | `isa/2` | agent keys, hosting and operational state |
| `quod:environment` | `isa/2`, `have_attribute/3` | mutations |
| `quod:environment:eidolons` | `class_eidolon/4`, `eidolon/3`, `panorama_asset/3` | mutations |
| `quod:gui` | `gui_view/2`, `isa/2` | mutations |
| `quod:human_user` | `isa/2` | private user state is not stored here or exposed |
| `quod:lens` | the existing `lens_query/1` API | mutations and non-API helpers |
| `quod:licence` | the existing `licence_query/1` API | mutations and non-API helpers |
| `quod:lobby` | the existing `lobby_query/1` API | mutations and non-API helpers |
| `quod:material` | the existing `material_query/1` API | mutations and non-API helpers |
| `quod:material:eidolons` | the existing `eidolon_query/1` API | mutations and non-API helpers |
| `quod:measure` | the existing `measure_query/1` API | mutations and non-API helpers |
| `quod:modelling` | `model/2`, `shape/3`, `align/6`, `place_model/5` | mutations and non-API helpers |
| `quod:names` | `name/4`, `count/4`, `name_nth/5`, supported `draw` arities | mutations and non-API helpers |
| `quod:node` | `isa/2` | node keys, hosting policy and operational facts |
| `quod:prolog` | its four source-tool/compiler predicates | compiler helpers and mutation authority |
| `quod:prolog:eidolons` | `eidolon/3`, `class_eidolon/4`, `isa/2` | view-selection helpers and mutations |
| `quod:rendering` | the existing `rendering_query/1` API | mutations and non-API helpers |
| `quod:signup` | none | signup keys, pending state and policy remain confidential |

`quod:root` is the catalogue and administrator authority rather than a
catalogued child. Its full source is root-administrator-only. Existing public
catalogue and resource-policy queries stay public, but root administrator facts
and other privileged operational definitions do not become source-readable.

The older retained production catalogue also contains `quod:present`, for which
this tree has no current authored source. It remains restricted and must not be
blanket-enabled or inferred equivalent to `quod:gui`; it needs a separate
definition inventory before any migration.

## Mutation and escalation refusals

Public source admission does not include `assertz/1`, `retract/1`, ACL clauses,
transactions, source-edit application or arbitrary meta-goals. The ordinary
authorization walk still governs qualified calls, conjunctions and `call/1`.
The public declarations cannot name `can_invoke/4`, root administrator facts,
private user state, node keys or signup state. Supplying root or source-tool
names in a call chain confers no authority: the narrow target wrapper asks root
to check the authenticated principal. A wrong genesis anchor fails before
content is selected.

The source UI is ontology-authored. `quod:gui` supplies distinct editable and
two-field read-only forms; the client renders the selected form and does not
compute permissions. Existing result handling separately reports denied access,
no available eidolon/tool, and temporary request failures.

## Fresh founding and retained histories

The files in `priv/ontologies` affect fresh founding only. Common helpers are
installed in projections by the supported artifact, but an existing ontology's
stored `can_invoke/4`, public query selector and public declaration facts do not
change when the package changes.

For each retained exact namespace and anchor:

1. Use its existing authorized maintenance principal to read the complete
   ordered definitions of `can_invoke/4` and its public query selector. Preserve
   target-specific grants and clause order.
2. Prepare exact-baseline source edits adding only the narrow system-source
   wrapper admission clause, the `public_source_query/1` selector clause and
   reviewed `public_prolog_predicate/1` declarations. Root itself and the
   source, GUI and eidolon tool ontologies require their corresponding narrowly
   reviewed definitions as well.
3. Compile with `quod:prolog` and apply through the existing signed action and
   atomic transaction path under that pre-existing authority. Do not use the new
   wrapper to bootstrap a target that has not yet committed its target gate.
4. Resolve the operation's actual outcome, read the definitions back, restart
   from the retained ledger and repeat the signed positive and negative probes.
   A baseline conflict is re-inspected; an uncertain write is resolved by its
   original operation identity and is never automatically resubmitted.

There is no ledger reset, re-founding, manifest rewrite, blanket ACL clause or
JavaScript/Erlang permission fallback in this migration.

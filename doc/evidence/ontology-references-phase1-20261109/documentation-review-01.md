# Phase 1 documentation changes — review 01

Exact changed text below compares the Phase 1 starting tree (`before.patch` applied to HEAD) with the current working documents. Context is included so every changed sentence can be read in place. This is a review snapshot, not the final frozen phase report.

## doc/godot-foundation-contract.md

```diff
--- phase1-start/doc/godot-foundation-contract.md
+++ current/doc/godot-foundation-contract.md
@@ -9,13 +9,13 @@
 [qualification evidence](evidence/godot-m0-20261027/README.md) freeze its inputs.
 
 ## Authority and exact identities
 
 Keep Prolog as the domain and policy owner. Continue using signed goals,
-assertion construction, committed operation guards, atomic multi-ontology
+instance assertion, committed operation guards, atomic multi-ontology
 writes, reactions, direct-effect custody and existing recovery. Loading decided
-state does not run constructors or replay historical reactions. Godot renders
+state does not repeat creation or replay historical reactions. Godot renders
 descriptors and submits operations; no client fact store or new executor is
 authorized by this contract.
 
 An ontology is the exact pair `ontology_ref(Namespace, GenesisAnchor)`. Actor
 references add an instance. Keys prove control; they are neither the actor nor
@@ -26,22 +26,22 @@
 
 | Namespace | Sole domain owner | Source composition, in this order |
 | --- | --- | --- |
 | `quod:root` | Catalogue, foundation creation/admission, root resource policy | `quod_root.pl`; optional `root_licence.pl` |
 | `quod:node` | Enrollment/allocation and execution/hosting policy | `quod_node.pl`; frozen `node_instance.pl` template |
-| `quod:agent` | Agent class and hosting/recovery/action vocabulary | `quod_agent.pl`; `agent_instance.pl` is composed in actual instance owners |
+| `quod:agent` | Agent class and hosting/recovery/action vocabulary | `quod_agent.pl`; the two hosting derivations remain in instance owners |
 | `quod:gui` | Portable components, exact unit algebra, scenes, model composition and inspection vocabulary | `quod_gui.pl`, `gui_measure.pl`, `gui_scene.pl`, `gui_tools.pl`, optional `gui_materials.pl` |
 | `quod:controllers` | Device descriptions, capabilities, roles and binding validation | `quod_controllers.pl` |
-| `quod:space` | Space class, construction, extent, admission, entry and space forms/Eidolons | `quod_space.pl`; optional `space_physics.pl`, `space_terrain.pl`, `space_hinged.pl`, `space_environment.pl` templates |
-| `quod:user` | Human class, signup/allocation policy and private signup receipts | `quod_user.pl`; frozen private `user_instance.pl` composition, optional `user_names.pl` |
+| `quod:space` | Space class, slots, extent, admission, entry and space forms/Eidolons | `quod_space.pl`; optional `space_physics.pl`, `space_terrain.pl`, `space_hinged.pl`, `space_environment.pl` templates |
+| `quod:user` | Human/personal-agent classes, setup, instructions, signup policy and private receipts | `quod_user.pl`; signup returns facts, ACL clauses and reactions as terms |
 
 The required compositions are authoritative. Optional filenames describe
 their later owner consolidation. The retirement map records the original
 inputs; M1a evidence records the bytes actually installed. A composed file does not create another ontology. The generic startup
 base is `common_predicates.pl`, `construction.pl`, `material_policy.pl`,
 `gui_forms.pl` and `geometry_schema.pl` plus the existing governed predicate modules. The GUI file
-interprets local form declarations and binds offered operations; it installs
+compiles forms at their owners and binds offered operations; it installs
 no application state, entry permission or lifecycle handler. The geometry file
 validates supplied authored body data and coordinate allowances; it selects
 no world, physical presence, budget or admission policy. Package
 hashes for that base and runtime are part of every qualification, since they
 are read by committed projections and are not fixed by a genesis anchor alone.
@@ -96,47 +96,38 @@
 existing source permission owner; moving a recipe grants no source access.
 GUI has no reverse dependency on space or a private user, so this graph is acyclic.
 
 ## Private composition and disclosure
 
-The private U ontology composes `user_instance.pl`, `agent_instance.pl`,
-`quod_space.pl` and `gui_instance.pl`, with the exact pins above. It contains
-human `me` and agent `personal`, with different active keys. The human key
-remains client-held; A's private key stays in the existing agent vault. Hosting,
-custody and the containing ontology do not merge those identities.
-
-`quod_space.pl` in U is the reviewed executable schema and instance-operation
-component from the pinned space recipe. It acts on the facts owned by that
-storage ontology; it does not create a second catalogue foundation or copy
-mutable state from S. The S pin selects the shared vocabulary/template revision
-and its exact source hash; it is not a constructor import or class alias.
-Stage 1 still constructs from locally composed class code in the selected
-storage ontology. Thus its local `space` class has that storage's exact
-`entity_ref(StorageNamespace, StorageAnchor, space)` identity, distinct from
-`entity_ref(<<"quod:space">>, S, space)`. References to either class or its
-Eidolon must retain the actual owner; matching predicate names do not merge
-them. There is one authored implementation, with separately owned local class
-and instance facts, rather than competing mutable copies of S's shared state.
-M1a must check the original composed source against the pinned recipe, preserve
-Stage 1 construction and foreign-storage operations, and show that changing U's
-local facts cannot change S's class/template state. It must refuse missing or
-mismatched source pins instead of substituting another implementation. Private
-state remains with its actual owner, including when storage is foreign to U.
+The user's ontology holds the qualified human `me` and personal agent
+`personal` memberships, their slots and keys, the seven vocabulary pins, ACL
+clauses, the completion reaction and the two hosting derivations. Signup returns
+that exact authored term list through the existing creation owner. The human key
+remains client-held; A's private key stays in the existing agent vault.
+
+Class behavior resides at `quod:user`, `quod:agent`, `quod:gui` and `quod:space`.
+The storing ontology's ACL governs their scoped reads and writes. Space creation
+asserts `instance_of(quod:space:space, Id)` in the selected storing ontology;
+slots remain there. The shared assertion hook reads class policy and slot
+declarations at their owners. Class references identify those owners; moving an
+instance reference does not move its storage. Changing U's slots or per-instance
+ACLs cannot modify the space owner's class declarations. No source digest or
+pasted class definition is involved.
 
 The user foundation contains signup receipts and must therefore remain
 source-restricted like current signup. Root's `system_source_access/2` must
 exclude the exact user foundation as well as root for ordinary public readers.
 Human vocabulary queries may be explicitly public; complete source reading
-cannot be made public with a per-predicate filter. Do not copy private account,
+cannot be made public with a per-predicate filter. Do not copy the user's private state,
 instruction, HUD, receipt or preference facts into GUI/controllers/catalogue.
 User-instance source admission remains owner-governed. Shared device defaults
-are public; actual settings, signed instruction associations and accounts are
+are public; actual settings, signed instruction associations and the user's ontology are
 private. Runtime hardware samples remain transient.
 
 M1a's production fixtures must use two unrelated humans, an unrelated agent
 and a public system-source reader. They must refuse raw/source/lens reads and
-writes of signup receipts, user account state, U→A instruction associations,
+writes of signup receipts, state in the user's ontology, U→A instruction associations,
 pending HUD questions and controller preferences. Public GUI/controller/space
 views must not contain those facts, keys, tokens or private target enumeration.
 Wrong-anchor, alternate-principal and public-source wrapper probes must fail
 before returning content. Revoke a source/view grant while subscribed and prove
 that retained content is withdrawn, without an empty valid-scene fallback.
@@ -179,45 +170,31 @@
 
 The existing lifecycle imposes two durable boundaries:
 
 1. Signup/allocation creates U's exact history and records its receipt plus
    the executor-bound node hosting intention through root's existing action
-   and atomic transaction. U genesis contains pending setup and frozen source,
-   not a constructor occurrence to replay on load. Resolve this original
+   and atomic transaction. U genesis contains pending setup and the exact
+   authored terms; loading does not execute setup. Resolve this original
    operation before beginning dependent setup; a lost reply never causes a new
    token, replacement U or new create request.
-2. U's explicit setup action prepares A's key using the existing custody read.
-   The read also returns an executor-signed receipt binding the exact A, prior
-   assignment, destination and key. Setup verifies this immutable receipt against
-   its proof-bound executor without a live vault lookup. Then in one transaction
-   it assigns A's host/key, constructs S0 through Stage 1
-   with explicit owner U, places A in S0 through `space_place/3` during that
-   active construction, stores exact U/A/S0 results and marks setup
-   complete. It consumes the signup receipt in that same multi-owner transition.
-   Setup requires successful unplaced U and A reads, not failed/missing
-   locations interpreted as absence. The ordinary constructor's near-agent
-   lookup sees its authenticated caller U at this step; explicit owner U avoids
-   the ordinary A-only owner default. No second reaction queue is added.
-
-The source proof authenticates U and uses a narrowly declared setup operation
-guard permitting this specific construction on U's behalf; ordinary creation
-through A retains the existing `personal_agent_owner/1` contract. This is
-Prolog composition work in M1a, not a change to generic constructor semantics.
-Key preparation is not enrollment or placement. A staged grant cannot authorize
-its own proof: class/create, A-entry and S0-admission grants must already exist
-in the committed template policy and authorize the `construction(...)` scope.
-
-There is a concrete Prolog composition gap: the current space constructor has
-no initial-occupants part, and placing A after S0's assertion returns would
-lose its active construction authorization. M1a adds an optional declared
-`initial_occupants` part to the shared space constructor, using existing
-`have_part/2`, `build_plan_part/3` and `space_place/3`. Setup supplies the exact
-existing A reference; this part does not construct another agent. It validates
-the references and places them before the existing assertion context ends.
-Absence means the ordinary empty-space behavior. This adds no subclass,
-Erlang constructor executor, staged permission grant or replay hook. Preserve
-ordinary Stage-1 inputs/defaults and all existing failure/rollback cases.
+2. U's explicit setup preparation uses the existing custody read. It returns an
+   executor-signed receipt binding exact A, prior assignment, destination and key.
+   The class-owned setup form accepts that pair. Its goal executes in the user's
+   ontology and verifies the receipt without a live vault lookup. In one
+   transaction it hosts A through `quod:agent`, asserts S0 with owner U, runs
+   `quod:space::goal(inside(S0, A, transform(0,0,0,0,0,0)))`, records the exact
+   U/A/S0 result, marks setup complete and acknowledges the signup receipt.
+   Preparation requires successful unplaced U and A reads; failed reads are not
+   absence.
+
+The source proof authenticates U and runs the setup form under its committed
+ACL. Class/create, A-entry and S0-admission permissions are checked at their
+owners. S0's newly asserted membership uses its original class policy until
+commit, without staged per-instance overrides. Setup places the existing A
+through the ordinary action; no constructor or initial-occupants part builds or
+places instances. Each later creation uses the same assertion, slots and action
+machinery under its selected storing ontology's ACL.
 
 If private custody or any receiver cannot prepare, the existing transaction
 rolls back the complete setup. A committed setup with an unavailable runtime
 stays complete/recovering, rather than provisioning replacements. The client
 durably retains the exact signed operation before dispatch. Recovery resolves
@@ -321,11 +298,11 @@
 dependency changes and applicable physical behavior through production owners.
 Broader ontology editing/D6 and other unimplemented D5 work stay open.
 
 ## Physics agreement and demonstrated gap
 
-The existing `space_place/3`/`space_withdraw/3` callbacks, source definition
+The `quod:space` placement and withdrawal actions, source definition
 delegations, live body revisions, `quod_runtime` retained source readers,
 `quod_physics` native owner, run/structure fences and authenticated control/
 observation remain authoritative. Unsimulated ordinary spaces allocate nothing.
 
 The M0/M2 baseline profile selects one physics actor and native world per independently
@@ -405,15 +382,16 @@
 4. Found agent with `quod_agent_predicates`; found GUI from its ordered composed
    sources with `quod_agent_predicates` and `quod_gui_predicates`; found
    controllers with its exact G terms and `quod_agent_predicates`; found space
    with its exact G terms and `quod_agent_predicates`. Register each exact anchor
    in root only after verified ready. No obsolete seed is founded temporarily.
-5. Found user with exact AClass/G/C/S, the frozen private account source composition,
-   `user_source_directory` pointing only at the packaged reviewed sources and
-   `signup_host` bound to the verified enrolled node. Use
-   `quod_agent_predicates`. Its creation-policy function must validate the full
-   ordered options and private template, not caller-supplied arbitrary source.
+5. Found user with exact AClass/G/C/S and `signup_host` bound to the verified
+   enrolled node, using `quod_agent_predicates`. Signup returns terms only:
+   qualified memberships, slots, pins, ACL clauses, the completion reaction and
+   the two hosting derivations. The creation policy validates the complete
+   authored term list and options, including clause variables as clause data;
+   names, remaining options and material admission retain their existing checks.
 6. Atomically register the exact user catalogue/creation policy and node's exact
    `ontology_hosting_policy(<<"quod:user">>, UClass)` delegation. Keep the
    hosting write at the enrolled node, tied to the existing effect executor.
    Root administrator/source-edit authority alone is not a creator grant.
 7. Verify root plus six unique catalogue identities, zero rejected/conflicting
```

## doc/gui-examples.md

```diff
--- phase1-start/doc/gui-examples.md
+++ current/doc/gui-examples.md
@@ -64,22 +64,24 @@
 The continuation replaces the single current configuration. There is no world,
 space, physics process or accumulating answer history.
 
 ## Shared lifecycle and presentation
 
-The responsible actor's ontology composes
-[gui_instance.pl](../priv/ontologies/gui_instance.pl); the human's ontology
-composes [user_instance.pl](../priv/ontologies/user_instance.pl). The application grants its
+[quod_gui.pl](../priv/ontologies/quod_gui.pl) owns question transitions, HUD
+behavior and their recipes. The responsible actor's and human's storing
+ontologies hold the rows, ACLs and completion reaction. The application grants its
 normal domain authority through `gui_question_policy/3`. The shared committed
 assertion reaction correlates accepted fields to the retained completion request;
 neither example declares `react_on` or sends a client-provided executable goal.
 
 Open either form from its application ontology:
 
 ```prolog
-gui_open(atmosphere(personal_sky), Question).
-gui_open(instrument_settings(analyzer_a), Question).
+current_ontology_identity(Ns, Anchor),
+quod:gui::gui_open(form_ref(Ns, Anchor, atmosphere(personal_sky)), Question).
+current_ontology_identity(Ns, Anchor),
+quod:gui::gui_open(form_ref(Ns, Anchor, instrument_settings(analyzer_a)), Question).
 ```
 
 Each call returns an anchored `question_ref(ResponderNamespace, ResponderAnchor,
 question(Id))`. It identifies that opening; it is not the eventual answer. The
 human can leave it in the HUD and answer later. Accepted values reach the
@@ -249,20 +251,16 @@
 distance remains an ordinary form setting. A generated view that exceeds its
 authored rendering allowance reports the resource, required amount and limit;
 the user can return to the lobby and choose a smaller distance without changing
 the saved terrain or disabling its physics owner.
 
-Fresh human creation uses the ordered hash-guarded composition of
-[user_instance.pl](../priv/ontologies/user_instance.pl),
-[agent_instance.pl](../priv/ontologies/agent_instance.pl),
-[quod_space.pl](../priv/ontologies/quod_space.pl) and
-[gui_instance.pl](../priv/ontologies/gui_instance.pl) authored by
-[quod_user.pl](../priv/ontologies/quod_user.pl). The ordinary creation owner
-checks each source hash and freezes the parsed contents into one genesis.
-The private user behavior owns the HUD allowance, receiving and pending
-references. The personal actor uses
-its own vault key and the existing hosting lifecycle, independently of U's
-browser key. Signup's subsequent authorized setup creates ordinary parentless
-S0 in the explicitly selected account storage and places that same A there;
-it does not commission the optional physical lobby preset. Existing human and lobby
-ontologies need explicit authorized source composition; opening the workspace
-never installs or repairs source.
+Fresh human creation uses the exact terms authored by
+[quod_user.pl](../priv/ontologies/quod_user.pl): qualified memberships, slots,
+seven vocabulary pins, ACL clauses, a completion reaction and the two hosting
+derivations. The existing creation owner freezes those terms into one genesis.
+Shared behavior stays at the class owners; HUD allowances, pending references,
+keys and hosting facts remain in the user's ontology. The personal actor uses
+its own vault key independently of U's browser key. Setup asserts ordinary
+parentless S0 in the selected storing ontology and places the same A there in
+one transaction. It does not commission the optional physical lobby preset.
+Existing human and lobby ontologies require authorized edits; opening the
+workspace never installs or repairs source.
```

## doc/gui-implementation-plan.md

```diff
--- phase1-start/doc/gui-implementation-plan.md
+++ current/doc/gui-implementation-plan.md
@@ -89,13 +89,13 @@
 
 settings_entered(Name, Level, Angle) :-
     goal(object_settings(Name, Level, Angle)).
 ```
 
-`gui_open(settings, Question)` is the convenient local entry supplied by shared
-GUI behavior. It captures the exact owning ontology, form and authorized
-responsible agent. The default human comes from authenticated context;
+`quod:gui::gui_open(form_ref(Ns, Anchor, settings), Question)` opens the exact
+form at its owner through the shared GUI behavior. The class owner selects the
+authorized responsible agent. The default human comes from authenticated context;
 agent-originated questions obtain their human from authorized application state.
 No caller-supplied human string confers authority.
 
 `Question` is a correlation reference, not the future answer. The field
 variables are freshly instantiated from `gui_form/3` when the answer is
@@ -479,19 +479,19 @@
 participate in admission, move their policy ownership and enforcement together;
 do not rename them, raise constants or split transactions to evade them.
 
 ## 6. Questions and bounded current state
 
-The implemented transition layer is composed from
-[`gui_instance.pl`](../priv/ontologies/gui_instance.pl) in the responsible
-ontology and [`user_instance.pl`](../priv/ontologies/user_instance.pl) in the human ontology.
-The application uses the same shared instance source
-and declares `gui_question_policy(Form, HumanRef, ResponsibleRef)`.
+The transition layer lives at [`quod:gui`](../priv/ontologies/quod_gui.pl).
+The responsible actor's and human's storing ontologies hold question rows,
+ACL clauses and the completion reaction. The application declares
+`gui_question_policy(Form, HumanRef, ResponsibleRef)` and admits the class
+owner's exact scoped calls through its ACL.
 `gui_submit/4`, `gui_complete/1` and `gui_cancel/1` use the
 ordinary signed request and transaction owners. `gui_pending_questions/1`
 returns the authenticated human's exact references. In the referenced scope,
-`gui_question_view(Id, FormRef, Revision, State)` reads the authoritative row
+`quod:gui::gui_question_view(QuestionRef, FormRef, Revision, State)` reads the authoritative row
 for that human; it exposes either `awaiting` or
 `submitted(OriginalSubmitOperation, Control, Fields)`. These read interfaces
 do not grant another human or responder access to the accepted fields.
 
 `gui_question_form(Id, Projection)` follows the exact source under that human's
@@ -615,11 +615,11 @@
 Creation must also reject a late repeat after cleanup. Absence of the current
 question row alone is insufficient: the admission contract must retain the
 same exact material operation identity through existing outcome machinery,
 rather than allowing another operation to recreate a consumed Question.
 
-`gui_submit(Question, Revision, Control, Fields)` replaces awaiting with submitted
+`quod:gui::gui_submit(Question, Revision, Control, Fields)` replaces awaiting with submitted
 state and exact completion intent atomically. The committed assertion is the
 correlated event; the shared reaction dispatches its exact request once. Recovery
 observes retained outcome evidence through the existing question controller
 rather than invoking the continuation again. `agent_work_goal/5` cannot query
 outcomes in its pure policy context. Domain consequences, consumption
@@ -809,11 +809,12 @@
 knob with degree entry. The panorama list comes from the authorized domain
 projection. The form can stay beside the sky or move to the personal workspace.
 
 ```prolog
 open_atmosphere(Sky, Question) :-
-    gui_open(atmosphere(Sky), Question).
+    current_ontology_identity(Ns, Anchor),
+    quod:gui::gui_open(form_ref(Ns, Anchor, atmosphere(Sky)), Question).
 
 gui_form(atmosphere(Sky),
     [field(preset(Sky), Preset),
      field(panorama(Sky), Panorama),
      field(brightness(Sky), Brightness),
@@ -858,11 +859,12 @@
     instance_of(instrument, Instrument).
 attribute(phase(Instrument), unit, degrees) :-
     instance_of(instrument, Instrument).
 
 open_instrument(Instrument, Question) :-
-    gui_open(instrument_settings(Instrument), Question).
+    current_ontology_identity(Ns, Anchor),
+    quod:gui::gui_open(form_ref(Ns, Anchor, instrument_settings(Instrument)), Question).
 
 gui_form(instrument_settings(Instrument),
     [field(run_name(Instrument), Name), field(mode(Instrument), Mode),
      field(gain(Instrument), Gain), field(phase(Instrument), Phase),
      field(enabled(Instrument), Enabled), field(channels(Instrument), Channels),
@@ -896,11 +898,12 @@
 attention item without opening a modal. The human can answer later, including
 after reconnecting, while the original opening proof has already ended.
 
 ```prolog
 ask_review(Work, Question) :-
-    gui_open(review(Work), Question).
+    current_ontology_identity(Ns, Anchor),
+    quod:gui::gui_open(form_ref(Ns, Anchor, review(Work)), Question).
 
 gui_recipient(review(Work), Human) :- work_reviewer(Work, Human).
 gui_responder(review(Work), Agent) :- work_responder(Work, Agent).
 
 gui_form(review(Work),
```

## doc/lifecycle-and-routing.md

```diff
--- phase1-start/doc/lifecycle-and-routing.md
+++ current/doc/lifecycle-and-routing.md
@@ -4,13 +4,18 @@
 as the existing source forms. Policy approves the complete descriptor; ordinary
 preparation reads each file once, verifies the exact 32-byte SHA-256 hash, and
 compiles those same bytes. A mismatch refuses preparation with
 `source_hash_mismatch(Index)` and creates no ontology. The prepared genesis
 remains the recovery input; applying or recovering it does not reopen a source
-file. This lets an authored recipe pin packaged components without carrying
-their complete buffers through every cross-owner proof answer. Paths and hashes
-grant no creation, source-read or module authority.
+file. Paths and hashes grant no creation, source-read or module authority.
+
+The `terms(Clauses)` option accepts authored facts and rules, including their
+clause variables. The creation name, the clause list and all other request
+fields must be fixed before admission; variables inside a clause are source
+data. Policy approves the exact request before the existing compiler checks
+reserved heads and material allowances and freezes the genesis. Later caller
+bindings cannot change that prepared source.
 
 `quod:root` is the one ontology pinned in node configuration. When it is
 ready, `quod_system_ontology` proves the committed `system_ontology/2`
 catalogue and returns exact `{Namespace, GenesisAnchor}` identities.
 `quod_namespace_manager` merges that catalogue with committed local
```

## doc/physics-native.md

```diff
--- phase1-start/doc/physics-native.md
+++ current/doc/physics-native.md
@@ -178,12 +178,13 @@
 Existing activation, hinge, control, rest and custody protections still fence
 frame edits and branch removal. A source representation change and dependent
 body/structure revisions commit atomically; body IDs remain stable on updates.
 
 Geometry, frame and delegation dependencies share the same resource selector
-and retained foreign readers. The selector can inspect owner-bound immutable
-identity metadata but cannot perform live queries, scope calls or writes.
+and retained foreign readers. The selector reads committed snapshots and can
+call class owners through ordinary signed scopes with their ACLs; live queries
+and writes remain forbidden.
 Revocation or missing verified input parks only consuming simulations. Unrelated
 changes retain native resources and controls. Required geometry, delegation and
 frame-membership/export failures are explicit results for the consuming world;
 they preserve the selector's failure reason and missing-read dependencies while
 the owner continues reconciling other worlds. A real committed repair wakes the
```

## doc/player-movement-plan.md

```diff
--- phase1-start/doc/player-movement-plan.md
+++ current/doc/player-movement-plan.md
@@ -16,13 +16,14 @@
 
 [The agent vocabulary](../priv/ontologies/quod_agent.pl) defines
 `isa(agent, thing)`; [the human vocabulary](../priv/ontologies/quod_user.pl)
 defines `isa(human_user, agent)`. The shared vocabulary is not a global table
 of humans. [Signup](../priv/ontologies/quod_user.pl) creates a concrete
-human instance and active key in its own ontology; the
-[instance template](../priv/ontologies/user_instance.pl) provides ownership and
-personal-agent behavior. Its setup constructs ordinary nonphysical S0; optional
+human instance and active key in the user's ontology;
+[quod:user](../priv/ontologies/quod_user.pl) owns personal-agent behavior and
+reads ownership through the storing ontology's ACL. Setup asserts ordinary
+nonphysical S0 and places A in the same transaction; optional
 physical presets and later recursive entry/physics delivery retain their own scope.
 
 [Agent identity](../src/quod_agent_ref.erl) is the exact
 `agent_instance_ref(Namespace, GenesisAnchor, Instance)`. Identity, keys,
 permissions, physical bodies and hosted processes are different concepts.
```

## doc/proofs.md

```diff
--- phase1-start/doc/proofs.md
+++ current/doc/proofs.md
@@ -129,11 +129,11 @@
 committed policy read-only and retains every consulted predicate in the normal
 OCC read set, including absent grants and failed checks. A staged ownership,
 class, requirement or grant edit cannot authorize itself or the next operation
 in that proof. Concurrent changes to those dependencies conflict normally.
 
-Classes author these local declarations:
+[Class owners author these declarations.]{decided by="yan.guiborat" on="2026-11-08"}
 
 ```prolog
 class_requirement(document, edit, document_edit_requirement).
 class_permission(document, edit, check(document_editor)).
 class_permission(public_document, edit, allow).
@@ -148,24 +148,24 @@
     assertz(document_value(Document, Value)).
 ```
 
 Declare the usual `isa/2` edges and `instance_of/2` memberships as well. Every
 applicable class's `class_requirement(Class, OperationName, Check)` is compulsory;
-`Check` names a local predicate receiving `(Actor, Subject, Operation)`. Checks
-must be pure committed Prolog: they cannot write, consult live services or open
-foreign scopes. Derived memberships and the entire ancestry consulted by the
-guard follow the same rule: a foreign-qualified parent is refused, not partially
-evaluated. Compose class policy into its target ontology, as for other local
-authorization. Missing or failing checks deny; attempted mutations or forbidden
-bridges raise `invalid_committed_policy`. Actual owner fences retain their typed
+[`Check` names a predicate at the declaring class owner receiving the original
+`(Actor, Subject, Operation)`. Checks must be pure committed Prolog: they cannot
+write or consult live services. The class tree, derived memberships and class ACL
+declarations follow a qualified class into its owner, as `isa/2` does; those reads
+enter the proof's dependencies. The class owner declares the class's ACL defaults
+and compulsory requirements; the storing ontology declares per-instance ACL
+facts. `can_invoke/4`, custody and committee verdicts cannot follow.]{decided by="yan.guiborat" on="2026-11-08"}
+Missing or failing checks deny; attempted mutations or forbidden bridges raise
+`invalid_committed_policy`. Actual owner fences retain their typed
 pending/rebuilding errors.
 
-The built-in ontology self-membership uses `current_ontology_identity/2`, which
-the strict policy context refuses. Consequently this guard does not yet support
-`instance(ontology_ref(Namespace, Anchor))`; ontology-operation integration must
-supply committed membership without weakening that boundary. Ordinary ontology
-membership queries and cross-ontology class queries keep their existing behavior.
+The ordinary operation guard can read `current_ontology_identity/2` for the
+built-in ontology self-membership. Strict local verdict contexts still refuse
+that bridge; the operation guard does not change their admissible predicates.
 
 `class_permission(Class, OperationName, Grant)` supplies a default: `allow`,
 `deny`, or `check(Predicate)` with the same three callback arguments. The most
 specific applicable declarations win. Equivalent cyclic classes and unrelated
 parents remain alternatives; differing grants deny unless a subclass or instance
@@ -192,74 +192,65 @@
 Discovery may call the public guard with complete inputs; it performs no operation
 and grants no authority to a later submission. Incomplete inputs fail without
 binding choices. Actual execution checks the exact actor, target and parameters
 again. Ontology `can_invoke/4` admission remains a separate prerequisite.
 
-The assertion hook uses this guard for creation; offered GUI operations use it
-at their own mutation boundary. During an active constructor, an operation on
-its new `instance(Id)` is checked as `construction(Class, Id, Inputs)`. The
-assertion hook alone supplies this scoped context; callers cannot supply that
-subject to the public guard or forge it with build inputs. Policy still runs
-over committed state, requires absence of that identity there, expands every
-parent of the original class, and uses class grants without staged instance
-overrides. Callbacks receive the original inputs, not staged attributes. This
-allows atomic initial placement before the membership commits. Nested parts
-have their own contexts; completion, rollback and errors restore the enclosing
-context. Existing-instance operations continue to use committed memberships.
+[The assertion hook uses this guard for creation; offered GUI operations use it
+at their own mutation boundary. An instance whose membership was asserted in the
+current transaction is checked as `construction(Class, Id, Inputs)` by its class
+policy, without staged instance overrides, until it commits. The assertion hook
+supplies that context; callers cannot supply it to the public guard or forge it
+with build inputs. Policy runs over committed state, requires absence of the new
+identity there, follows the original class's ancestry and receives the original
+inputs rather than staged slots. This permits atomic initial placement after the
+assertion. The context follows the transaction through foreign calls and is
+restored with rollback; existing instances use committed memberships.]{decided by="yan.guiborat" on="2026-11-08"}
 The reserved grant-edit operation still requires a committed instance.
 The authenticated-principal bridge is installed
 once by the common runtime vocabulary. Terrain/helper and placement
 checks retain their existing callers and protections. Authorized arbitrary source
 rewrites remain outside the narrower operation contract. There is no generic
 final-state validator. Packaged common rules do not rewrite founded ontologies;
 activation requires the existing authorized compatible-artifact/source procedure.
 
-## Constructor inputs, defaults and inheritance
-
-The shared [construction rules](../priv/ontologies/construction.pl) use
-`constructor(Class, Instance, BuildPlan)` for every class. Classes author their
-own bodies and required parts. Bare `assert(instance_of(Class, Id))`, `asserta`
-and `assertz` request creation with an output variable. The existing assertion
-hook runs the committed class guard, allocates and binds the ID, resolves inputs,
-stages membership and initial attributes, then calls constructors in the original
-proof under the shared savepoint. It does not call `goal/1` to test the newly
-staged membership: that already-true shortcut would skip construction.
-Calling the input wrapper alone does not create anything.
+## Creation inputs, defaults and inheritance
+
+[The shared [construction rules](../priv/ontologies/construction.pl) initialize
+slots when a bare `assert(instance_of(Class, Id))`, `asserta` or `assertz`
+requests creation with an output variable. The existing assertion hook checks
+committed class policy, allocates the ID, resolves inputs, and stages membership
+and initial slots under the shared savepoint. Constructors do not build instances
+or parts; a `constructor/3` body at a class owner refuses creation. Parts are
+asserted like any other instance.]{decided by="yan.guiborat" on="2026-11-08"}
+The hook does not call `goal/1` to test the newly staged membership: an
+already-true state would skip slot initialization. Calling the input wrapper
+alone creates nothing.
 
 The ID is a full 26-byte Crockford ULID: 48-bit Unix milliseconds plus 80 bits
-from `crypto:strong_rand_bytes/1`. Every creation, including each required part,
-draws independently; all inherited constructors share their instance's ID. A
-collision with a live direct or derived membership refuses the attempt before
-constructors or attributes can overwrite it. Normal creation accepts no
-caller-chosen new ID. There is no counter or deleted-instance catalogue.
-The exact reference is `entity_ref(Namespace, GenesisAnchor, Id)`; a named output
-in the signed goal is retained by the ordinary selected-result machinery.
-
-`with_build_plan(Inputs, Goal)` supplies temporary inputs during `Goal`. Inputs
-are a ground list of `attribute(Key, Value)` and `part(Role, PartInputs)` entries;
-keys and roles are atoms, unique within their respective categories. Nested
-wrappers replace the current inputs, restore the enclosing scope on exit and
-preserve ordinary Prolog alternatives and cut. Inputs are private proof bindings,
-never stored facts, authority or a second knowledge base. They do not implicitly
-cross ontology calls. Each constructor body receives its original BuildPlan,
-while the ambient inputs are empty: nested parts receive only what their owning
-class explicitly passes through a new wrapper. `build_plan_part/3` selects one
-role's overrides, returning `[]` when absent. Classes declare supported override
-roles with `have_part(Class, Role)`; preflight accepts roles declared anywhere in
-the constructor ancestry and refuses unknown roles before bodies run. Each part's
-own preflight validates its nested inputs. The declaration does not create a part:
-class code still constructs its required parts and explicitly passes overrides;
-the caller does not repeat the internal tree.
-
-The internal `'$quod_constructor_plan'(Class, Instance, Inputs, Order, Attributes)`
+from `crypto:strong_rand_bytes/1`. Every creation draws independently; inherited
+slot declarations initialize the same instance. A collision with a live direct
+or derived membership refuses the attempt before slots can overwrite it. Normal
+creation accepts no caller-chosen new ID. There is no counter or deleted-instance
+catalogue. The exact reference is `entity_ref(Namespace, GenesisAnchor, Id)`; a
+named output in the signed goal is retained by the ordinary selected-result
+machinery.
+
+[`with_build_plan(Inputs, Goal)` supplies a ground list of `attribute(Key, Value)`
+entries during `Goal`; keys are unique atoms. Nested wrappers replace the inputs,
+restore the enclosing scope on exit and preserve ordinary alternatives and cut.
+Inputs are private proof bindings, never stored facts or authority, and do not
+implicitly cross ontology calls. Part inputs and `have_part/2` declarations are
+removed. A goal that creates several instances supplies each instance's slots
+through its own wrapper.]{decided by="yan.guiborat" on="2026-11-08"}
+
+[The internal `'$quod_constructor_plan'(Class, Instance, Inputs, Order, Attributes)`
 requires a bound identity and performs read-only preflight through the existing
-state-check machinery. It validates the full constructor order and resolves all
-initial attributes before writes or bodies. It reuses `isa/2` declarations,
-most-specific selection and `have_attribute(Class, Key, Type[, Default])`.
-Class definitions and constructors are composed locally, like shared permission
-policy; a foreign-qualified parent is refused rather than silently skipped.
-Ordinary cross-ontology ancestry queries retain their existing behavior.
+state-check machinery. It validates the inheritance order and resolves all
+initial slots before writing. Class declarations follow a qualified class into
+its owner, including parents, `constructor_order/2`, slot declarations, selected
+default providers and type checks. It reuses `isa/2`, most-specific selection and
+`have_attribute(Class, Key, Type[, Default])`.]{decided by="yan.guiborat" on="2026-11-08"}
 
 A supplied value wins over class defaults. Otherwise most-specific default
 providers win over inherited providers; equal unrelated defaults agree, while
 conflicting defaults require a caller or subclass choice. `required` and an
 unrelated parent's `default(Value)` also conflict: neither silently wins.
@@ -274,22 +265,21 @@
 ordinary unary Prolog predicates, with `term` accepting any ground value.
 Type names must be atoms naming executable unary checks visible in the owning
 ontology. Descriptive metadata such as `quantity(Unit)` or an undefined `degrees`
 is not an executable validator; classes using it must supply validation when
 adopting construction. Such supplied/default values fail validation, not fall
-back to an unchecked value. Refusals identify unknown attributes/parts, missing
+back to an unchecked value. Refusals identify unknown attributes, missing
 required keys, invalid resolved values and failed default providers. Malformed
 input lists report `invalid_build_inputs`.
 GUI property validation uses these same declared types; GUI-specific selection
 and field constraints retain their existing behavior.
 
 ```prolog
 isa(chair, thing).
 class_permission(chair, create, allow).
 have_attribute(chair, name, binary, default(<<"Chair">>)).
 have_attribute(chair, legs, positive_integer, default(4)).
-constructor(chair, Chair, _Inputs) :- attribute(Chair, legs, _).
 
 isa(place, thing).
 have_attribute(place, name, binary, default_from(place_name)).
 place_name(Instance, Name) :-
     quod:names::draw(<<"landscape">>, <<"world">>, <<"neutral">>, Instance, Name).
@@ -301,55 +291,53 @@
 has an authored class declaration or membership. Classes choose their own
 ordinary or computed default; no universal personal-name draw is installed.
 A supplied name bypasses the computed provider. A selected naming pool must
 support the requested kind; absence fails instead of drawing another kind.
 Resolved values are stored once by `'$quod_initial_attribute_writes'/2`, then
-read normally by every constructor and view. Changing defaults does not rewrite
+read normally by operations and views. Changing defaults does not rewrite
 instances. Names are mutable and nonunique; renaming changes neither identity
 nor other instance facts. Terrain's `display_name` migration remains stage 3.
 
 `constructor_order(Class, Parents)` lists every direct parent exactly once.
 Zero or one parent needs no declaration; multiple parents require one ground
 proper list. Duplicate, missing or extra parents, multiple declarations,
-inheritance cycles and contradictory order constraints fail before bodies run.
+inheritance cycles and contradictory order constraints fail before slot writes.
 The order combines all ancestor-before-descendant and declared parent constraints;
 a stable topological traversal uses the authored branch order for independent
-choices. Shared ancestors run once per attempt, on the same instance as their
+choices. Shared ancestors are selected once per attempt, for the same instance as their
 descendants. Constructor order never chooses attribute defaults or permissions.
 
-`'$quod_run_constructors'/3` invokes that prepared order. Declaration inspection
-is separate from execution: absent own code succeeds without skipping parents;
-declared code that fails, including an explicitly called required part, fails
-the construction. The assertion savepoint selects the first complete construction
-answer. Failed alternatives, required parts and caught constructor errors restore
-memberships, attributes, events, effects and bindings together; read dependencies
-remain monotonic. Commit intent is inherited. As with successful actions, a
-successful construction releases its own boundary before the caller continues.
-Use an enclosing `transaction/1` or action when later caller failure/backtracking
-must also discard that completed construction. Cuts and ordinary staging keep
-their existing meanings. There is no generic final-state validator.
+[The assertion savepoint selects the first complete initialization answer.
+Failed alternatives and caught errors restore membership, slots, events,
+effects, creation context and bindings together; read dependencies remain
+monotonic. Commit intent is inherited. Successful creation releases its own
+boundary before the caller continues. Use an enclosing `transaction/1` or action
+when later caller failure or backtracking must also discard the completed
+creation.]{decided by="yan.guiborat" on="2026-11-08"}
+Cuts and ordinary staging keep their existing meanings. There is no generic
+final-state validator.
 
 ## Membership source and recovery
 
 Membership queries and derived memberships create nothing. A bare ground
 assertion can repeat or add a classification to an existing identity without
-running constructors; it refuses a new caller-selected identity. This is not
+initializing slots; it refuses a new caller-selected identity. This is not
 live specialization and does not initialize the additional class's defaults.
 
 An explicit clause, including `instance_of(Class, Id) :- true`, authors source
-instead of requesting construction. It stores its variables as clause variables.
+instead of requesting creation. It stores its variables as clause variables.
 The guarded source editor already emits this form, so replacing/reordering a
 suffix preserves surviving identities and attributes without a temporary identity
 registry. Its exact source round-trip check remains unchanged. Authorized source
-addition/removal edits facts as written; it does not promise constructor validity
+addition/removal edits facts as written; it does not promise initialized slots
 or prevent deliberate identity reuse by an author with broad source authority.
 Strict read-only overlays still reject both facts and explicit clauses.
 
 Founding compilation and common loading compile clauses directly. Commit apply,
 restart and projection rebuild restore decided facts and results through the
 existing materializer. Validators consume the sealed IDs/names and existing
-read dependencies; they do not rerun constructors or draw replacements. Historical
+read dependencies; they do not initialize slots again or draw replacement identities. Historical
 reactions are not replayed. Ontology founding remains its own governed lifecycle,
 outside ordinary instance construction. Existing terrain actions store their
 decided terrain/sky memberships as explicit clauses. Their governed construction
 and identity scheme remain with the terrain integration stage.
 
```

## doc/runtime-and-agents.md

```diff
--- phase1-start/doc/runtime-and-agents.md
+++ current/doc/runtime-and-agents.md
@@ -5,10 +5,13 @@
 governed effects (**E**) act on them. Replay reconstructs D and P without
 re-emitting old reactions. The direct-effect journal independently recovers
 committed work whose private custody is still pending.
 
 ## Reactions and resources
+
+[A reaction is an agent's behaviour: an ontology without a hosted agent can hold
+`react_on/2` clauses but nothing executes them.]{decided by="yan.guiborat" on="2026-11-08"}
 
 `trigger_event/1` places an occurrence in a committed diff; it does not
 assert that term as a permanent fact. Editable `react_on/2` clauses match
 applied events with normal Prolog unification. Eligibility is read-only.
 The selected goal enters the matching hosted actor's bounded queue and then
@@ -47,20 +50,22 @@
 but does not replay its old reactions, including after an occurrence was dropped
 by backpressure.
 
 Governed external predicates are classified as query, staging or reaction
 operations. Their execution context distinguishes normal proofs, validator
-policy checks, local installed-resource selection and read-only reaction matching; an invalid context fails
+policy checks and read-only reaction matching; an invalid context fails
 closed. A live observation cannot silently become a replayable proof input.
 
-The resource selector remains local and read-only. When resolving a retained
-source it may use `resource_selection` context with that owner's exact namespace,
-anchor and snapshot height. Only proof-bound metadata queries are permitted;
-live queries, scope calls, staging and reaction commands are forbidden. This
-lets a source recipe identify its own anchored frame without network I/O or an
-authenticated principal. Committed `policy_verdict` checks retain their stricter
-bridge prohibition.
+Physics and agent-host selection run committed, read-only proofs over their
+retained snapshots in the existing bounded resource worker. The node signs the
+proof identity for ordinary class-owner calls, which retain the target's ACL.
+Physics installation reads retain their existing source delegation independently
+of display access. Live queries, staging and reaction commands remain forbidden.
+The runtime retains precise read dependencies and follows certified source
+progress before installing the selected resources. Unchanged checks do not
+rebuild history or write storage. Other local resource selectors and committed
+`policy_verdict` checks retain their stricter bridge prohibition.
 
 Common Prolog mechanics provide `in_ontology(Namespace,Anchor,Goal)` for the
 ordinary anchored scope conjunction, `unique_solution/1` for an exact singleton
 query with fresh outputs, and `term_hex_digest/2` for portable digest spelling.
 They retain the existing invocation, dependency and backtracking owners. Domain
@@ -122,36 +127,38 @@
 It grants no assignment authority and does not replace current committed
 assignment policy. Operational loss of custody remains a visible service failure.
 
 ## Immediate personal instructions
 
-[user_instance.pl](../priv/ontologies/user_instance.pl) composes with the human
-instance and shared agent hosting rules. The human U and hosted instance
-`personal` (A) have distinct references and keys in the same containing ontology.
-`personal_agent/2` discovers A and its current public key. Preparation and initial
-assignment use `prepare_agent_key_custody/6` and the existing `agent_hosted/4`
-action. Signup creates U and retains its original receipt and hosting intention.
-An authorized `account_setup_preparation/1` read prepares the same existing A's
-custody and returns `prepared_key(Key, Receipt)` in the preparation. The
-`setup_account/4` input carries that pair; setup verifies the receipt before it
-assigns A's host/key, constructs ordinary S0
-owned by U in the explicitly selected existing account storage, places A while
-construction authorization is active, records the complete result, and consumes
-the signup receipt in one atomic transition. A complete setup read returns its
-original references and pins without another preparation or write. Existing ontologies require authorized source
-composition; opening an account never rewrites its ontology.
-
-For [empty-space construction](spaces.md#empty-creation), A can query its exact
-account's `personal_agent_owner/1` and `space_location(personal, Location)`.
-The owner is the unique existing human-user reference. Location reuses the
-composed space vocabulary and exclusive assignment; there is no copied personal
-location or ownership registry. Both are anchored reads admitted only for A
-(alongside U's existing account authority). A missing space composition or failed
-location query refuses creation rather than declaring A unplaced.
+[quod_user.pl](../priv/ontologies/quod_user.pl) owns the human and personal-agent
+classes and their shared behavior. The human U and hosted instance `personal`
+(A) have distinct references and keys in the user's ontology. That ontology
+stores their memberships, slots, ACL clauses, reaction and hosting facts, plus
+the two local hosting derivations. `quod:user::personal_agent/2` discovers A and
+its current public key. Signup writes terms only and retains U's original
+receipt and hosting intention.
+
+An authorized `quod:user::account_setup_preparation/1` read uses the existing
+`prepare_agent_key_custody/6` and returns `prepared_key(Key, Receipt)`. The
+human class's `setup` form accepts that pair as inputs. Its goal executes in the
+user's ontology: verify custody and host A through `quod:agent`, assert ordinary
+S0 with U as owner, place A with `quod:space::goal(inside(S0, A, Origin))`, record
+the complete result, and acknowledge the signup receipt in one transaction.
+S0's first admission uses its class policy while its membership is staged. A
+complete setup read returns the original references and pins without another
+preparation or write. Existing ontologies change only through authorized edits.
+
+For [empty-space creation](spaces.md#empty-creation), the form asks
+`quod:user::personal_agent/2` for the exact personal-agent reference and uses
+`quod:space::space_location/2` for its location. The default owner is the unique
+human reference read by the user class owner. These ordinary scoped reads use
+the storing ontology's ACL; a denied or failed location query refuses creation
+rather than declaring A unplaced. Explicit unplaced creation requires no
+personal-location lookup.
 
 `personalGoal` takes an explicit target ontology reference and goal. U signs a
-read request `personal_instruction_accept(Bytes, Signature)` enclosing A's exact
+read request `quod:user::personal_instruction_accept(Bytes, Signature)` enclosing A's exact
 unsigned execute request, including its operation ID, goal, key and expiry. The
 committed Prolog policy checks the U-to-A relationship; `sign_agent_request/2`
 uses the existing governed vault to produce A's signature. A normal read only
 returns that signature. The explicit `POST /api/agents/instructions` transport
 then attempts the work through the installed local runtime and its existing
@@ -179,13 +186,13 @@
 node-signed read of the source's association under hosting policy. Only a
 confirmed absence produces HTTP 409 with `submitted: false`; a retained
 association or an unavailable check preserves the original pending operation.
 This read shares the original deadline and creates no recovery state.
 
-`personal_instructions/1` lets an authorized U discover associations without a
+`quod:user::personal_instructions/1` lets an authorized U discover associations without a
 browser journal. `POST /api/agents/instructions/outcomes` takes a fresh U-signed
-read `personal_instruction_lookup(Id, Bytes, Signature)` and resolves the exact
+read `quod:user::personal_instruction_lookup(Id, Bytes, Signature)` and resolves the exact
 stored A request through the existing outcome owner, including original named
 bindings. Lookup still requires current U authority, but does not require A's
 key to remain active or the write expiry to remain valid. A missing transaction
 claim stays uncertain, including an association interrupted before submission;
 lookup never dispatches it. The existing history-retention requirements apply.
```

## doc/spaces.md

```diff
--- phase1-start/doc/spaces.md
+++ current/doc/spaces.md
@@ -8,29 +8,30 @@
 predicate instances. Its class-selected contents Eidolon uses the same exposure
 and scene projection as other spaces. This reflection grants no entry, placement,
 founding, ownership or physical permission; those operations retain their
 explicit authored policy.
 
-[quod_space.pl](../priv/ontologies/quod_space.pl) defines the shared space
-foundation and is composed into the ontologies owning individual spaces through
-ordinary founding or authorized source editing. Each selected storage owns its
-local class and instances; the shared foundation's exact pin and source hash
-certify the composition without becoming a remote constructor or class alias.
+[quod_space.pl](../priv/ontologies/quod_space.pl) defines the space class at
+`quod:space`. A storing ontology holds `instance_of(quod:space:space, Id)`,
+its slots and its ACL facts. Shared behavior reads and writes that exact storing
+ontology through `::` under its ACL.
 The [ordered founding recipe](godot-foundation-contract.md#reproducible-founding-recipe)
 does not rewrite existing histories or grant deployment authority.
 
 ## Classes and dispatch
 
 The vocabulary declares `isa(space, thing)` and
 `isa(physical_space, space)`. Shared `isa/2` rules compute reflexive/transitive
 ancestry, including authored multiple inheritance. `instance_of(Class, Entity)`
 is class-first, remains authored, and does not itself expand ancestry.
-`space_instance(Entity, Class)` explicitly combines membership with ancestry.
+`quod:space::space_instance(EntityRef, Class)` combines membership in the
+storing ontology with ancestry at the class owners.
 Neither declaration imports behavior or grants invocation rights. The existing
 lobby likewise explicitly expands its device classes before recipe selection.
-For the same class, purpose, style and recipe name, a local Eidolon recipe
-replaces an imported copy; differently named recipes remain separate choices.
+Class-selected Eidolon recipes run at their declared owners; the ordinary
+most-specific selection applies, and differently named recipes remain separate
+choices.
 Ontology reflection specializes space for display; it does not change lobby classes.
 
 An `entity_ref(Namespace, GenesisAnchor, Entity)` refers to an existing entity
 in its owning ontology. It is a reference term, not a new object registry or
 class. The owner establishes class or instance identity using existing `isa/2`
@@ -41,25 +42,21 @@
 
 [Normal-user signup provisions a distinct personal agent A and an ordinary empty
 space S0 for human U; S0 is the initial personal lobby, has no containing space,
 and initially contains A.]{decided by="yan.guiborat" email=yan.guiborat@gmail.com on=2026-10-27 over="a dedicated lobby subclass for this delivery"} [Y](https://console.nimbalyst.com/app/cite/ed9cd520-b2a4-4607-a8f5-ff99d08f3e46/prompt/80fe5d70d8db7a67f1cc071ad91cced3 "by=yan.guiborat email=yan.guiborat@gmail.com at=2026-10-27T14:04:14.517Z quote='some points before starting :%0A- I would like to clarify new users onbording. These should only prolog if possible:%0A%2A When a normal user is created atm we will create for it a simple empty space. It will be later the user lobby %28 we will create a dedicated subclass for it %29 but for now we will use a simple space class. So I guess when registering a new user, we should create a space and an agent…'")
 
-The user-owned setup composition uses the existing `space` class and defaults,
-including its 100-metre box extent, after signup has allocated the exact account.
-A dedicated user-lobby subclass is later work. S0 is a space instance, not the
-root ontology, a shared lobby foundation or a new ontology per room.
+The setup form uses `quod:space:space` and its defaults, including the 100-metre
+box extent, after signup has allocated the user's ontology. S0 is an ordinary
+space instance; a dedicated user-lobby subclass is later work.
 
 The [M0 contract](godot-foundation-contract.md#ordinary-onboarding-and-storage)
-selects the existing private account ontology explicitly for automatic S0
-provisioning and records that exact selection. Additional spaces still use
-explicit selected storage, including permitted foreign storage; this is not a
-universal account-storage default. Its Prolog setup transaction binds A's
-host/key, constructs S0 and places the existing A inside it. An optional
-initial-occupants part must run during S0 construction so the committed class
-guard can authorize the new destination; placing A after that context ends
-cannot use staged S0 membership as authority. The normal empty-space defaults
-and existing constructor/placement machinery remain the foundation.
+selects the user's existing ontology explicitly for S0 and records that exact
+selection. Additional spaces use explicit selected storage, including permitted
+foreign storage. The setup transaction binds A's host/key, asserts S0 and runs
+`quod:space::goal(inside(S0, A, transform(0,0,0,0,0,0)))`. S0's staged membership
+uses its class policy until commit. No constructor or initial-occupants part is
+involved; both membership and placement commit in the same transaction.
 
 Having a containing space is optional for every ordinary space. S0 is unplaced
 while A is placed inside it; these are different assignments. Other spaces may
 also remain unplaced. A placed instance has at most one containing space, with
 independent display references still allowed. No synthetic outer space, second
@@ -90,11 +87,11 @@
     S1 -->|contains placed space| S2["S2: ordinary space"]
 ```
 
 Signup composition, ownership, initial placement, offered operations and grants
 belong in Prolog. Reuse existing governed founding, key custody, actions,
-construction, atomic writes and recovery; Godot renders descriptors and sends
+assertion, atomic writes and recovery; Godot renders descriptors and sends
 authenticated instructions. The onboarding composition must explicitly select
 and record its authorized storage after any required existing founding step;
 automatic onboarding does not introduce an implicit storage default for later
 Create operations. M0 specifies the exact lifecycle and permissions. Related
 instance facts and admission changes forming one transition commit together;
@@ -110,117 +107,110 @@
 mesh-only exterior or require entry before a contents-displaying exterior works.
 
 ## Empty creation
 
 U instructs the distinct personal agent A through the existing immediate signed
-route, selecting an **existing** ontology explicitly. Compose `quod_space.pl` into
-that storage owner and A's ontology, and `quod_space.pl` where space exteriors
-or contents are projected. Finite dimensions use the storage owner's exact
-`measure_vocabulary(Namespace, Anchor)` reference to the measurement ontology.
-No automatic lobby storage selection or ontology founding occurs.
+route, selecting an **existing** ontology explicitly. The space class owner
+holds the forms, recipes, validators and `measure_vocabulary(Namespace, Anchor)`
+pin used for finite dimensions. The storing ontology admits the requested
+assertion and the class owner's scoped reads and writes through its ACL. No
+automatic lobby storage selection or ontology founding occurs.
 
 The shared assertion mechanism creates the instance. A goal inside the selected
 anchored scope can return both durable outputs:
 
 ```prolog
 with_build_plan([attribute(name, <<"Workshop">>)],
-                assert(instance_of(space, Space))),
+                assert(instance_of(quod:space:space, Space))),
 current_ontology_identity(Ns, Anchor),
 Ref = entity_ref(Ns, Anchor, Space),
 attribute(Space, name, Name).
 ```
 
 The default name is `<<"Space">>`; supplied names override it. Names are stored,
 mutable and nonunique. The generated ULID and anchor form the identity. Named
 outputs `Ref` and `Name` use the ordinary selected-result machinery: a lost
 reply is recovered from the original operation, including after restart or
-later instance deletion. Recovery does not run construction again.
+later instance deletion. Recovery does not create the instance again.
 
 `dimensions` defaults to `box(q(100, <<"m">>), q(100, <<"m">>),
 q(100, <<"m">>))`: X, Y and Z lengths centred on the local origin, extending
 50 metres in each direction. It also accepts `infinite` or three strictly
 positive exact length quantities. Existing measurement conversion validates
 compatible units and rational values without floats or rounding. Malformed,
-unitless, non-length, zero and negative dimensions fail construction. Supplied
+unitless, non-length, zero and negative dimensions fail creation. Supplied
 quantities remain stored as supplied; interior extent does not impose a resource
 budget, allocate geometry or establish collision boundaries.
 
-The default `owner` is U, proved by A's anchored `personal_agent_owner/1` query.
-An explicit owner is a construction input subject to the storage/class policy.
-Ownership, storage and containing space remain independent. The bundle supplies
-no invocation or class permission grants: authors admit A's exact request and
-declare `create` and `space_enter` policy. The destination separately enforces
-`space_admit` and its invocation policy. During a constructor, the shared guard
-checks committed class policy using the scoped
-`construction(Class, Id, Inputs)` subject; staged instance grants cannot supply
-permission. See [construction authorization](proofs.md#class-and-instance-operation-permissions).
-
-An optional `attribute(placement, at(DestinationRef, transform(X,Y,Z,RX,RY,RZ)))`
-chooses an exact destination and exterior transform, using existing integer
-millimetres/degrees. The constructor consumes this input; it stores no second
-location record. Omission or explicit `near_agent` reads A's `space_location/2`. A successful
-`unplaced` result creates an unplaced space; `placed(Destination, Transform)`
+The default `owner` is U, read through `quod:user`. An explicit owner is a slot
+input subject to the storing ontology's ACL and class policy. Ownership, storage
+and containing space remain independent. `quod:space` supplies class ACL defaults;
+the storing ontology may declare per-instance ACLs. The shared guard checks a
+new instance using its original class and inputs until the transaction commits;
+staged instance grants cannot supply permission. See
+[creation authorization](proofs.md#class-and-instance-operation-permissions).
+
+After assertion, `quod:space::goal(inside(DestinationRef, Ref, Pose))` chooses an
+exact destination and transform, using existing integer millimetres/degrees.
+The action stores the pose in the instance's `transform` slot. The creation
+form's placement choice is an input to this action, not a stored slot.
+`near_agent` reads A's exact location at `quod:space`; a successful `unplaced`
+result leaves the new space unplaced. A `placed(Destination, Transform)` result
 places it in front of A along that frame's −Z axis: 2 m from A's position plus
 half the new space's depth, so its near wall opens at arm's reach plus a step
 (Yan, 2026-11-07); an infinite space uses half-depth zero. This is one-time placement,
 not following A. A denied, unavailable, ambiguous or incomplete location read
 fails creation. A placed agent needs its ordinary `attribute(Agent, transform,
 Transform)`; missing pose does not prove absence. Physical-pilot entry and live
 body poses remain the separate physical/entry integration.
-Explicit `attribute(placement, unplaced)` skips that location lookup and requests
+The explicit `unplaced` form choice skips that location lookup and requests
 no admission. It is distinct from treating a failed near-agent read as absence.
 
-Creation and placement use the existing assertion savepoint and `space_place/3`
-transaction. Refused explicit placement rolls back the instance and all admission
-writes; it never tries another destination or unplaced creation. Physical
+Creation asserts the space and runs `goal(inside(…))` in the same transaction.
+Refused placement rolls back the instance and all admission writes; it never tries another destination or unplaced creation. Physical
 destinations retain their mandatory physical hook and checks. Creation does not
 prepare a simulation, terrain, sky or walls. The defined solid Eidolon uses a
 half-metre cube independently of finite or infinite interior extent, through the
 existing scene/model/rendering path. Contents remain empty. The landscape/terrain
 creation route is unchanged.
 
-Compose `quod_space.pl` and `gui_instance.pl` in the storage
-owner to offer **Create space** and **Create infinite space**. The existing
-`gui_vocabulary/2` must pin the component vocabulary. The forms initialize name
+The space class owner offers **Create space** and **Create infinite space**
+through its recipes and forms. Its `gui_vocabulary/2` pins the component
+vocabulary. Forms compile at that owner and their goals run in the selected
+storing ontology. The forms initialize name
 and finite dimensions from class defaults; leaving those fields unchanged uses
 the defaults, while edits supply explicit values. Finite controls accept positive
 integers in mm, cm, m or km (1–1,000,000 per axis); the domain model still accepts
 the wider exact measurement contract above. The placement selector supplies
-`near_agent` and authored exact destinations. Storage authors may replace its
-options with permitted local or foreign references. Submission returns both
-`result(space, entity_ref(...))` and the committed `result(location, ...)`.
+`near_agent` and authored exact destinations. The class owner authors its options for each selected storing ontology,
+including permitted local or foreign references. Submission returns both
+`result(space, entity_ref(...))`, the committed `result(location, ...)` and
+`result(owner, ...)`.
 The [shared operation panel](gui-implementation-plan.md#offered-class-and-instance-operations)
 displays these bindings and can open the returned subject's offered operations.
 Source composition in an already founded ontology requires its existing owner
 authority; installing client files does not rewrite ontology data.
 
 The shared form also offers **Create space with rational lengths**, with a
 positive integer numerator/divisor per axis and an explicit length unit. The
 ordinary finite form retains its integer defaults; both use the same Stage 1
 assertion and binder. Names may be empty binary values; leaving the supplied
 default unchanged keeps `Space`. Every form selects placement and an exterior
-recipe. Creation and form definition check the unique anchored
-`space_vocabulary/2` plus `space_source_digest/1` against the shared source's
-`space_template_hash/1`; missing, ambiguous or mismatched composition refuses.
-This certifies the original composition without aliasing the target's class.
-
-The account composition separately authorizes its personal A's new-space
-constructor to place a newly constructed space, and that A's admission into
-completed U-owned destinations for other source subjects. These are committed
-class and destination policies. They grant no later A entry/leave permission
-and no blanket invocation. Foreign storage independently authorizes the exact
-operation and source assignment callback. Its owner, U and destination remain
-distinct.
+recipe. The creation subject is `class_ref(<<"quod:space">>, Anchor, space)`;
+its class identity is independent of the selected storing ontology. Each storing
+ontology separately authorizes the acting principal's request and the class
+owner's scoped callbacks. Class defaults and per-instance ACLs remain subject to
+the committed guard.
 
 ## Relations and owners
 
 | Relation | Sole owner | Assertion |
 | --- | --- | --- |
 | `space_member(Space, EntityRef)` | Space ontology | Independent display reference, possibly many-to-many |
 | `space_assignment_state(Entity, Revision, DestinationRef)` | Entity ontology | Exclusive admission assignment, or `none` after withdrawal |
 | `space_placement(Space, EntityRef, Revision)` | Space ontology | Admission corresponding to that assignment revision |
-| `space_contains(Space, EntityRef)` | Derived query at space ontology | Direct view subjects: display references or placed instances |
+| `space_contains(SpaceRef, EntityRef)` | Derived query at `quod:space` | Direct view subjects: display references or placed instances |
 
 The assignment and placement facts express the entity's exclusive assignment
 and the space's admission. They contain no duplicate pose, body, code or geometry.
 Their transition is one existing atomic transaction. Assignment absence means
 revision zero and `none`; after first use the empty slot retains its revision,
@@ -242,70 +232,65 @@
 Persisting a display reference or changing containing-space assignment requires
 an authorized action. Hot controls retain their existing transient path.
 
 ## Governed transitions
 
-`space_contain(Space, EntityRef)` executes at the destination and checks both
-owners' committed operation policy in `display` mode. Only the destination
-writes `space_member/2`. `space_remove/2` removes that reference when destination
-policy allows removal or the entity owner allows withdrawal. Display grants
-provide no placement, disclosure or ownership authority.
-
-`space_place(Entity, ExpectedRevision, DestinationRef)` executes at the entity
-owner. It checks that owner's `space_enter` permission in `placement` mode,
-an empty slot at the expected revision and the destination's `space_admit`
-permission. It stages the next assignment and calls `space_accept_placement/3`,
-which checks `space` membership and reads the staged assignment back through
-the existing re-entrant proof scope before admitting the entity. This supports
-ordinary and physical spaces, in the same ontology or different ontologies.
-Two completed proofs from the same empty slot conflict at the single assignment
-owner. Refusal, stale revision and conflict leave no partial assignment.
-
-`space_withdraw(Entity, ExpectedRevision, DestinationRef)` is the common entry
-for instance withdrawal and destination revocation. It stages the next empty
-assignment and calls `space_release_placement/4`. Destination policy must allow
-removal, or the instance owner must allow that principal to leave. The callback
-checks the new empty slot, performs any required physical consequence and removes
-the exact old admission. Both owners commit together or neither changes.
-Changing a future-entry grant alone does not revoke existing membership; compose
-that policy edit with the withdrawal/removal action when immediate revocation is
-required. Neither a missing owner nor a timeout authorizes unilateral release.
-If either required ontology is unavailable, this transition remains unavailable;
-there is no offline eviction or invented successful withdrawal.
-
-Participant entries cannot create or release a slot. Invoking them alone in a
-valid committed state fails: admission lacks a matching new assignment or
-already exists; release lacks the next empty assignment. Failed candidates use
-ordinary transaction savepoints. No handoff process, transfer ledger or second
-executor is introduced.
+`quod:space::goal(shown_in(SpaceRef, EntityRef))` uses the `show` action to
+check both owners' committed operation policy in `display` mode and write
+`space_member/2` in the destination's storing ontology. `goal(not_shown_in(…))`
+uses `hide` when destination policy allows removal or source policy allows
+withdrawal. Display grants provide no placement, disclosure or ownership
+authority.
+
+`quod:space::goal(inside(SpaceRef, EntityRef, Pose))` uses the `place` action.
+Its `goal(unplaced(EntityRef))` prerequisite withdraws the entity first if needed;
+`placement_pose/3` binds an omitted pose. Source `space_enter` and destination
+`space_admit` checks use committed policy. The action writes the next source
+assignment, its pose and the matching destination admission through their
+storing ontologies' ACLs, with the required physical consequence. An already
+satisfied desired state writes nothing. Two completed proofs from the same
+assignment conflict at its sole owner; refusal and conflict leave no partial
+assignment.
+
+`quod:space::goal(unplaced(EntityRef))` uses `withdraw` and requires source
+`space_leave` permission. It writes the next empty assignment, performs the
+required physical consequence and removes the exact old admission in one
+transaction. Changing a future-entry grant alone does not revoke existing
+membership; compose the policy edit with the applicable action when immediate
+revocation is required. Neither a missing owner nor a timeout authorizes
+unilateral release. An unavailable required ontology makes the transition
+unavailable.
+
+Participant entries cannot create or release a slot independently: `place`
+requires an empty assignment and the exact destination; `withdraw` removes the
+matching assignment and admission together. Failed candidates use ordinary
+transaction savepoints.
 
 ## Same-agent travel
 
-`space_travel(Entity, ExpectedRevision, Before, After, Revision)` moves the
-existing entity through the same withdrawal and admission actions. `Before` is
-the exact destination reference or `none`; `After` is `placed(Destination,Pose)`
-or `unplaced`. A placed-to-placed move consumes a withdrawal and an admission
-revision. The new source pose is staged before destination admission so its
-physical consequence sees the same transform as the committed assignment.
-Source leave/entry permission, both destination consequences and pose changes
-form one existing atomic transaction. A refusal or conflict restores all owners.
+The same `goal(inside(…))` and `goal(unplaced(…))` actions move the existing
+personal agent. A placed-to-placed move consumes a withdrawal and an admission
+revision. Its pose is staged before destination admission so the physical
+consequence sees the same transform as the committed assignment. Source leave
+and entry permission, destination consequences and pose changes form one atomic
+transaction; refusal or conflict restores all owners.
 
 The offered Enter and Leave forms bind the existing personal agent and its
 exact assignment revision. Their ordinary U-to-A instruction executes this
 operation; navigation reads the resulting assignment. Leave may explicitly make
 the agent unplaced. Storage and display references do not supply an inferred
-parent or destination. Completed-account travel grants are separate from the
-constructor's initial-placement grant.
-
-The account's owner-authorized `account_navigation/1` returns
+parent or destination. A newly asserted instance uses its class policy; later operations use its
+committed membership and per-instance ACLs.
+
+The user class owner's `quod:user::account_navigation/1` returns
 `navigation(AssignmentRevision, Location, Modes)` from the same assignment and
 location queries, including an explicit `unplaced`. Its signed `navigation` view
 uses the existing view owner and retained dependency lifecycle. Setup's original
 S0 result remains immutable. A client retires scene/control on invalidation and
 opens only the current exact placed space; an unplaced client keeps navigation
 subscribed and may open an explicitly selected existing subject's ordinary Enter
-offer. `account_navigation/2` remains the placed-location query for world reads.
+offer. `quod:user::account_navigation/2` remains the placed-location query for world reads.
 
 The signed `client_world_view/4` result is
 `world_view(ExactSpace,Name,Marks,Selection)`. `Name` is the selected owner's
 single binary `attribute(Space,name,Name)`, or `unnamed` when absent; conflicting
 or non-binary names refuse the view. The existing endpoint checks the exact
@@ -313,12 +298,12 @@
 the projection. It has the same retained read dependencies and authorization;
 it is neither a naming service nor a second current-location record. Ordinary
 solid/wireframe space recipes use the same authored name in their scene label.
 An empty permitted scene remains black; its context belongs to the GUI chrome.
 
-`space_represent(Space, BeforeStyle, BeforePose, BeforeInterior, Style, Pose,
-Interior)` checks the exact source values and committed `space_represent`
+`quod:space::space_represent(SpaceRef, BeforeStyle, BeforePose, BeforeInterior,
+Style, Pose, Interior)` checks the exact source values and committed `space_represent`
 instance policy. A changed exterior or pose invokes the admitting destination's
 physical consequence in the same transaction. An unchanged representation
 performs no state mutation.
 
 `interior` (`none`, `wireframe` or `matrix`; absent means `none`) shows the
@@ -329,31 +314,24 @@
 both finite boundaries with the existing `space_exterior_unavailable` reason.
 The space's pie offers the interior choices under **Show as**.
 
 ## Invocation policy
 
-The bundle installs no `can_invoke/4` clauses. Entry ACLs and domain grants are
-separate requirements. The authenticated principal is unchanged through `::`;
-calling from a space does not impersonate the entity owner. Expose only exact
-needed shapes, with appropriate principals and authenticated call paths:
-
-| Owning scope | Shapes required by the composition |
-| --- | --- |
-| Space | Public `space_contain/2`, `space_remove/2`; anchored `space_accept_placement/3`, `space_release_placement/4` for admitted callers |
-| Entity | Public `space_place/3`, `space_withdraw/3`; anchored `space_consent/4`, `space_withdrawal_consent/4`, `space_assignment/3` |
-| Caller whose operation enters another scope | The exact outer `Namespace::Goal` request permitted by its own entry policy |
-
-An anchored shape is `(current_ontology_identity(Namespace, Anchor), Goal)`.
-A curator evicting an entity needs the entity owner's invocation grant for
-`space_withdraw/3` as well as the space's removal policy. Otherwise it is denied
-even if that curator may edit the space. Conversely, a publisher's delegation
-does not grant destination invocation or admission. Read disclosure remains
-subject to the owning scope's policy. Helpers, raw assertions/retractions and
-lifecycle callbacks are not end-user entries. An unrestricted administrative
-ACL already authorizes arbitrary source/state editing and is not constrained
-by these domain actions. Revision/configuration conflicts return reasoned
-failures; denied operation policy remains ordinary Prolog failure.
+The class owner admits its public reads and desired-state goals through
+`can_invoke/4`. Each storing ontology separately admits the actor's scoped reads
+and writes, including the exact operation guard. The authenticated principal is
+unchanged through `::`; the call chain identifies the class owner. Calling from
+a space does not impersonate the entity owner.
+
+An anchored call has the shape `(current_ontology_identity(Namespace, Anchor),
+Goal)`. Placement needs both storing ontologies' ACLs and operation permissions;
+disclosure remains subject to each source's ACL. A curator's destination grant
+does not supply the entity's `space_leave` or invocation permission. Raw
+assertions and retractions remain governed by the storing ACL. An unrestricted
+administrative ACL authorizes source and state editing independently of these
+domain actions. Configuration conflicts return reasoned failures; denied
+operation policy remains ordinary Prolog failure.
 
 ## Shared operation authorization
 
 All four permissions use [the shared committed guard](proofs.md#class-and-instance-operation-permissions).
 The operation inputs are `space_enter(SourceRef, DestinationRef, Mode)`,
@@ -362,24 +340,23 @@
 `space_remove(DestinationRef, SourceRef, Mode)`. `Mode` is `placement` or
 `display`. The executing owner supplies its own exact reference; the other
 reference comes from the requested transition. Placement requires instance
 subjects; display consent also accepts class subjects.
 
-Authors declare `class_permission/3`, `class_requirement/3` and governed
-`instance_permission/3` overrides. The bundle grants no default permission.
-Each owner checks its own committed memberships, ancestry and policy. A live
-constructor supplies its original class and inputs through the shared assertion
-scope before the new membership commits; this does not read staged grants or
-weaken destination checks. Staged grants cannot authorize the current transition. Compulsory requirements from
-every applicable parent survive overrides. Policy reads participate in the
-existing conflict checks. Scope invocation remains separately required.
-
-Callbacks use only local committed policy. Exact identities are already operation
-inputs, so callbacks need neither the identity bridge nor a foreign scope call.
-The lobby's `lobby_admission/4` supplies its local admission definitions to both
-permission checks and the existing anchored physics projection. Physical
-consequences retain their checks independently of default permission overrides.
+The class owner declares `class_permission/3` defaults and compulsory
+`class_requirement/3` checks; the storing ontology declares `instance_permission/3`
+overrides. `space` allows creation, entry, admission, leave, removal, visit and
+representation by default. Each operation checks committed membership, ancestry
+and policy through the shared guard, following qualified classes to their owners.
+A membership asserted in the current transaction uses its original class and
+inputs without staged instance overrides. Compulsory requirements survive
+overrides, and policy reads enter the ordinary conflict checks. Scope invocation
+remains separately required.
+
+The lobby's `lobby_admission/4` supplies its instance ACL checks and the existing
+anchored physics projection. Physical consequences retain their own checks
+independently of the class defaults or per-instance ACL overrides.
 
 ## Direct depiction
 
 [A space's exterior Eidolon may display its contents instead of a mesh.]{decided by="yan.guiborat" email=yan.guiborat@gmail.com on=2026-10-27} [Y](https://console.nimbalyst.com/app/cite/ed9cd520-b2a4-4607-a8f5-ff99d08f3e46/prompt/0ed00d8751e1d31d9ff931cbc71dfcc9 "by=yan.guiborat email=yan.guiborat@gmail.com at=2026-10-27T14:14:39.228Z quote='please remember that a space, can have an external eidolon pourposed to display its content instead of a mesh, I wish you remember taht%0A%3CNIMBALYST%5FSYSTEM%5FMESSAGE%3E%0AThe user is currently looking at this document. They are not necessarily asking you about this document, but they may be. Use your best judgement to decide if they are making a general request or asking specifically about this…'")
 
@@ -421,13 +398,12 @@
 admits a continuous component into one existing simulation domain. Independently
 enabled runs cannot join through contents selection. Empty ordinary spaces
 allocate no physics solely because they are spaces; admission, custody and
 transfer guarantees still apply.
 
-The shared projection in `common_predicates.pl` projects the union of placement and display
-references, deduplicating each exact subject within that view. It asks the source
-owner for `entity_scene/3` and uses the existing Eidolon, `place_model/5`, local
+The shared projection at `quod:space` projects the union of placement and display
+references, deduplicating each exact subject within that view. It resolves `entity_scene/3` through the existing source and class owners and uses the existing Eidolon, `place_model/5`, local
 `transform/6` and anchored `depicts/3` contracts. Ordinary placement uses the
 scene's local transform. Display references use that same presentation path;
 no domain facts, ownership or storage move to the viewing space.
 
 `space_projection(Space,Mode,scene(Marks,Exposures))` supplies the same marks as
@@ -475,12 +451,12 @@
 definition and does not withdraw its occurrence. Recovery preserves this
 distinction through the existing durable operation owner. This establishes no
 deletion/recreation identity or individually selectable clause semantics.
 
 Pure exposure and model composition share the common presentation owner.
-The space bundle retains construction, assignment, admission and physical
-transitions. A configured modelling vocabulary remains the exact owner pin;
+The space class owner retains assignment, admission and physical transitions;
+the shared assertion hook initializes slots. A configured modelling vocabulary remains the exact owner pin;
 when none is composed, the root catalogue supplies the installed GUI vocabulary
 for presentation. Source policy still governs every reflected catalogue read.
 There is no client predicate identity type or domain-type selection branch.
 
 The presentation vocabulary imposes no population or display-text quota over
@@ -529,14 +505,14 @@
 historical reactions or manufacture new placement operations. A caller retaining
 an uncertain signed request resolves that exact operation through existing
 outcome resolution; absence or timeout is not rejection and must not trigger a
 fresh admission/withdrawal. Physical recovery additionally obeys current run
 fences, compatible checkpoints and custody described in [world.md](world.md).
-Creation destination selection uses the constructor and source-owned transform
-described under [Empty creation](#empty-creation). During construction, placement
-checks committed class policy through the shared construction scope; existing
-instances use committed instance policy. Installed desktop entry and recursive
+Creation destination selection uses the form and storing ontology's transform
+slot described under [Empty creation](#empty-creation). Until commit, the new
+instance uses committed class policy through its creation context; existing
+instances use committed membership and per-instance ACLs. Installed desktop entry and recursive
 rendering qualification are distinct from these server transitions and receipts.
 General transfer between independent simulations is outside this slice: atomic
 membership delete/add is insufficient and provides no authority-transfer claim.
 
 The production-owner tests are [quod_space_tests.erl](../test/quod_space_tests.erl).
@@ -545,18 +521,12 @@
 Physics resource selection is present during the no-allocation checks. The
 simulated integration is exercised through production owners in
 [quod_physics_tests.erl](../test/quod_physics_tests.erl).
 
 
-The `quod_space.pl` constructor declares optional `initial_occupants`. Its input
-is `part(initial_occupants,[attribute(entities,[entity_ref(Ns,Anchor,Id),...])])`.
-Every reference must be ground, exact and unique, and identify an existing
-unplaced entity in the same storage history as the new space. A cross-history
-occupant refuses with `initial_occupants_require_local_storage`: constructor
-authority belongs to the active assertion continuation in its actual owner.
-M1a places the existing A in its own account storage. Ordinary foreign storage
-creation remains supported; this part cannot import an occupant from another
-history. Construction places those entities through `space_place/3`
-before its assertion authorization ends. Source entry and destination admission
-still require committed policy; a part cannot grant itself permission. Failure
-rolls back the assertion and all placement participants. With no part, ordinary
-empty creation is unchanged. Loading or recovery never runs this constructor.
+A goal that creates a space and places existing occupants asserts the space and
+runs one `quod:space::goal(inside(NewSpace, OccupantRef, Pose))` per occupant in
+the same transaction. Each exact occupant may reside in any permitted storing
+ontology. Source entry and destination admission still require committed policy;
+new staged ACLs cannot authorize the placement. Failure rolls back the assertion
+and all placements. Loading and recovery restore the decided facts and do not
+repeat those actions.
```

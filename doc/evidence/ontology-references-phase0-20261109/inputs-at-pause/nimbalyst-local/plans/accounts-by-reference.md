---
planStatus:
  planId: plan-accounts-by-reference
  title: Space class lives only in quod:space; user ontologies assert instances of it
  status: blocked
  planType: system-design
  priority: high
  owner: Yan
  stakeholders: []
  tags:
    - architecture
    - ontologies
    - spaces
    - gui
    - signup
  created: "2026-11-08"
  startDate: "2026-11-09"
  updated: "2026-11-09T11:41:20+00:00"
  progress: 19
---

# Space class lives only in quod:space; user ontologies assert instances of it

Design only. No production code changes with this document; no deployment,
refound or data wipe is authorized by it. It reads `worktree/pearl-stone` at
0.7.282, the live fleet. `master` is at 0.7.275 and lacks this work.

Words used here: a **user's ontology** is the ontology founded for a human at
signup; it holds the human `me`, the personal agent `personal`, the first space
S0 and, from now on, nothing but facts, ACL clauses and the agent's reactions.
A **class owner** is the ontology defining a class: `quod:space` for `space`,
`quod:gui` for forms, questions and the HUD, `quod:user` for `human_user` and
`personal_agent`, `quod:agent` for `agent`. A **storing ontology** is the one
holding an instance's `instance_of` and slots. **Slot** means the pair
`have_attribute(Class, Key, Type, Default)` on the class and
`attribute(Instance, Key, Value)` on the instance. **ACL** means `can_invoke/4`,
`class_permission/3`, `class_requirement/3` and `instance_permission/3`.

## Implementation checklist

- [ ] **Phase 0 — independent small repairs** (live transaction path)
  - [x] `doc/spaces.md` placement sentence: 2 m in front along −Z plus half the space's depth (Yan, 2026-11-07).
  - [x] Icon byte allowance declared on the icon asset, consumed by the client exactly as model `resources/7` is; delete the client's `1<<20` constant.
  - [x] One icon lookup rule `menu_icon/2` beside `menu_vocabulary/2`; delete `space_icon/2` and the user-ontology `gui_icon/2` forwarder.
- [ ] **Phase 1 — the class in one place** (one cold coordinated release for the two engine changes, then live edits)
  - [ ] The operation guard runs with ordinary following on (its reads recorded); `no_follow(class_permission/3)` and `no_follow(class_requirement/3)` removed; an instance asserted in the current transaction is checked by its class policy; `'$quod_constructor_graph'` stops refusing a qualified class; constructor bodies and class-built parts are gone.
  - [ ] `quod:space`: class declarations and ACL defaults; `inside/3` and `unplaced/1` desired states with their actions; recipes, forms, menus, validators, near-agent pose; `space_instance/2`, `space_contains/2`, the contents projection and `world_view/3` moved in from `common_predicates.pl`; `space_template_hash/1`, `space_recipe/0`, the constructor body and `space_travel/5` deleted.
  - [ ] `quod:gui`: question lifecycle, HUD class and rules (kept in `quod:gui`, Yan 2026-11-08), recipes, writing through `::`.
  - [ ] `quod:agent`: hosting, custody and recovery actions, writing through `::`.
  - [ ] `quod:user`: `personal_agent` class, setup, navigation, controller and personal-menu recipes, personal-instruction rules, the facts, ACL clauses and the one reaction it writes into each new user's ontology; `signup_options/4` writes terms only; `user_source_directory/1`, `user_source_component/2`, `space_source_digest/1` deleted.
  - [ ] `gui_forms.pl`: a form owned by another ontology is compiled there; its goal runs where submitted, as today.
  - [ ] `quod_client_view.erl`: `navigation`, `controller_preferences`, `hud_commands` goal shapes point at the owner recipes.
  - [ ] Tests (§6) and docs (§2.5, §2.6).
- [ ] **Phase 2 — icon bytes in quod:gui** (live transaction path)
  - [ ] `gui_asset(Digest, Mime, Bytes)` facts in `quod:gui`, public read; 36 icons, 100,690 bytes today.
  - [ ] Client fetches by signed read, verifies the digest, caches by digest; `/assets/icons/` leaves the node image.

Activation clarification from Yan in this session (2026-11-09): backward
compatibility is unnecessary; the ledgers will be refounded. Implementation
therefore proceeds for that eventual activation. Running a refound, deployment
or live edit still requires Yan’s explicit go.

Phase 0 validation is blocked on Yan’s direction for the existing browser
adapters: their GUI decoder requires `asset/2`, so the signed HTTPS
lifecycle test rejects the new image shape. Verification and retained
failures are recorded in the
[Phase 0 report](../../doc/evidence/ontology-references-phase0-20261109/report.md).

## 1. Rulings

Yan, 2026-11-08:

1. A class is defined in one owner; other ontologies call it through `::`.
   ACLs are the only protection. `space` is defined in `quod:space` only. The
   signup paste of `quod_space.pl`, `user_instance.pl`, `agent_instance.pl`,
   `gui_instance.pl` is removed.
2. `space_template_hash/1`, `space_source_digest/1`, `user_source_component/2`
   are deleted with no replacement.
3. Icons, names and bytes, are predicates in `quod:gui`; changes propagate
   only through commit, then the dependent live views refresh.
4. Creating a thing is asserting it: `assert(instance_of(…))` in the storing
   ontology, under the user's identity and that ontology's ACL.
5. Slot values are stored with the instance, for every class.
6. A rule in one ontology writes into another through `::`; the target's ACL
   admits it or not. Nothing else decides (`test/quod_ask_tests.erl`:
   `pets::assertz(origin_callback_write)`; multiwrite "one foreign writer").
7. ACL edits are assert and retract of ACL facts; `set_instance_permission/3`
   is a helper. The ACL of a space is stored with the space. A space does not
   change its storing ontology; only references to it move.
8. Reactions (`react_on/2`) are stored clauses, Prolog like everything else,
   and are an agent's behaviour: the spec says the selected goal "enters the
   matching hosted actor's bounded queue and then the ordinary signed-goal
   path". Above reactions sits the `goal/1` and `action/3` pattern: putting an
   instance into a space is `quod:space::goal(inside(Space, Instance, Pose))`,
   with the action's prerequisites filling in what the caller left out.
10. Instances are asserted, by the user or by a form's goal; constructors do
    not build instances. An asserted instance is placed in the same
    transaction.
9. No follow-ups. Icon bytes by signed read. Existing users sign up again.

## 2. How it works

### 2.1 Creating a space, and placing it, in one transaction

The user, in the storing ontology, runs the Create form's goal:

```prolog
with_build_plan([attribute(name, Name), attribute(dimensions, D), attribute(exterior, E)],
                assert(instance_of(quod:space:space, B))),
quod:space::goal(inside(A, entity_ref(Ns, Anchor, B), Pose))
```

The storing ontology's own assertion step does what it does today, with one
difference: the class is at `quod:space`.

1. **Permission.** "May this actor create a `quod:space:space` here?" The
   shared guard walks the class tree with `isa/2`, collects
   `class_requirement/3` and `class_permission/3` from every class on the way,
   most specific wins, `instance_permission/3` overrides. `isa/2` already
   follows a qualified class into its owner ("Once a path reaches a foreign
   class, ask its owning ontology for the rest of the public isa/2 relation",
   `common_predicates.pl`). Two things stop the guard from using that
   inheritance, both put there for the paste model. **Change:** remove
   `no_follow(class_requirement/3)` and `no_follow(class_permission/3)`
   (`common_predicates.pl:331-332`, "Policy data is local to the target"), so a
   qualified class's defaults are found at its owner like its parents are; a
   plain local class name follows nothing, so a local denial never becomes a
   foreign grant. And run the operation guard
   (`quod_ask:committed_authorization_result/2`) in an ordinary read-only
   committed frame with following on and its reads recorded, instead of the
   committee-verdict frame where following is switched off
   (`quod_erlog_db_local_prove.erl:73`). `can_invoke/4`, custody and committee
   verdicts keep their frame; validators re-prove those without network.
   Writes stay forbidden in the guard.
2. **Id.** Allocated locally, as today.
3. **Slots.** Declarations read at `quod:space`
   (`'$quod_constructor_graph'` drops its `constructor_requires_local_class`
   refusal), defaults resolved, type checks run at the owner, values stored as
   `attribute(B, Key, Value)` in the storing ontology, as today for every class.
   `transform` is a slot with default origin.
4. **No constructor body.** Instances are asserted; constructors do not build
   instances or parts. The exterior-versus-dimensions check becomes
   `class_requirement(space, create, space_exterior_fits)` at the owner.
5. **Placement in the same transaction.** `goal(inside(A, B, Pose))` runs the
   `place` action (§2.2). A is committed: its admit ACL is checked as usual.
   B's `instance_of` is only staged: the guard checks B by its class policy,
   read through inheritance, as it already does inside a constructor
   ("checked as `construction(Class, Id, Inputs)` … uses class grants without
   staged instance overrides"). **Change:** that treatment applies to any
   instance whose membership was asserted in the current transaction, not only
   inside a constructor body. The actor who asserted it has already passed the
   class-level create check, so the class policy is the right authority for its
   first placement.
6. **ACL of the new space.** The same transaction may assert
   `instance_permission(B, space_admit, …)` and so on in the storing ontology.
   They apply from the next transaction.

One commit: B exists, placed in A.

### 2.2 Placing anything anywhere: `goal(inside(...))`

`quod:space` declares two desired states and their actions, using the existing
`goal/1`, `action/3`, `satisfy_prerequisites/2` machinery of
`common_predicates.pl`. Prerequisites are ordinary goals; they bind what the
caller left unbound (today's `action(initialize_agent_host(…), [current_principal(Administrator), …])`
binds `Administrator` the same way).

```prolog
%% inside(Space, Entity, Pose): Entity is placed in Space at Pose.
inside(entity_ref(SNs, SA, Space), entity_ref(ENs, EA, Entity), Pose) :-
    in_ontology(ENs, EA, (space_assignment(Entity, _, entity_ref(SNs, SA, Space)),
                          attribute(Entity, transform, Pose))).
unplaced(entity_ref(ENs, EA, Entity)) :- in_ontology(ENs, EA, space_assignment(Entity, _, none)).

action(place(Space, Entity, Pose),
       [goal(unplaced(Entity)),                              % leaves the current space first
        placement_pose(Space, Entity, Pose),                 % binds Pose when the caller left it open
        space_authorized(Entity, space_enter, Space, placement),
        space_authorized(Space, space_admit, Entity, placement)],
       inside(Space, Entity, Pose)).
action(withdraw(Entity),
       [current_assignment(Entity, Revision, Space),
        space_authorized(Entity, space_leave, Space, placement)],
       unplaced(Entity)).
```

`place/3` and `withdraw/1` write, through `::`, `space_assignment_state/3` and
`attribute(Entity, transform, Pose)` in the entity's storing ontology, and
`space_placement/3` in the space's storing ontology, plus the physical hook
when the destination is physical. Each write is admitted by that ontology's
`can_invoke/4` for the acting principal with `quod:space` in the call chain.
The ACL checks are the existing shared guard over the storing ontologies'
committed facts: `space_authorized/4` asks the entity's ontology and the
space's ontology through `::`. The revision counter stays inside
`space_assignment_state/3` as today. One `goal(inside(...))` is one atomic
transaction over every ontology it writes.

Every placement is this one goal:

- Create B near the agent: the form's goal asserts B and runs
  `quod:space::goal(inside(Current, B, _))`; `placement_pose/3` binds the pose
  2 m in front of the agent plus half B's depth.
- Create an avatar made of parts: the same form goal asserts the avatar space
  and each part with their slots, then one `goal(inside(Avatar, Part, Pose))`
  per part, whichever ontology stores them. Parts are asserted like anything
  else; no class builds them.
- Enter S1: the Enter form's goal is `quod:space::goal(inside(S1, personal, Pose))`;
  the `goal(unplaced(personal))` prerequisite runs `withdraw` first. This
  replaces `space_travel/5`.
- Leave: `quod:space::goal(unplaced(personal))`.
- Setup: one transaction hosts the agent, asserts S0 and runs
  `goal(inside(S0, personal, transform(0,0,0,0,0,0)))`; S0's admit ACL is its
  class policy, since S0 is asserted in that transaction.
- Display membership (`space_contain/2`, `space_remove/2`) becomes
  `goal(shown_in(Space, Entity))` and `goal(not_shown_in(…))` on the same
  pattern.

### 2.3 Reactions as the agent's behaviour

The personal agent's ontology holds one reaction, written at signup:

```prolog
react_on(assert(gui_question(Q, Source, Human, Actor, Revision, Submitted)), quod:gui::gui_complete(Q)) :-
    gui_completion_event(Q, Source, Human, Actor, Revision, Submitted).
```

It is today's question completion reaction with its goal at the class owner. A
reaction's goal runs through the hosted actor's queue as a signed operation
under ordinary ACLs. Reactions on events of another ontology use the existing
`from(Ns, Anchor, Pattern)` form with `subscribes/2`. Placement needs no
reaction: it happens in the creating transaction (§2.1).

### 2.4 Forms, menus, HUD, questions, hosting

Forms, menus and Eidolon recipes stay class-owned and are already evaluated at
their owner through `in_ontology/3`. A form owned by another ontology is
compiled there (the `form_ref` pattern questions already use); its goal runs
where submitted. Renaming, Show as and controller settings are forms whose goal
retracts and asserts the slot in the storing ontology; the diff reaches the
client through the existing live views.

The HUD is `instance_of(quod:gui:hud, my_hud)` asserted in the agent's ontology
with its slots and allowance. `quod:gui` holds the HUD rules
(`hud_contribute/2`, `hud_offer/2`, `gui_link_question/1`, …) and writes
`hud_contribution/4`, `hud_offered/4`, `gui_pending/2` into the agent's ontology
through `::`, admitted by its ACL. The HUD commands recipe at `quod:gui` reads
them back the same way. Questions: `quod:gui` holds the lifecycle
(`gui_open/2`, `gui_submit/4`, `gui_complete/1`, `gui_consume/1`, …) and writes
`gui_question/6` rows into the responding agent's ontology through `::`.
Hosting: `quod:agent` holds the actions (`initialize_agent_host`,
`assign_agent_host`, recovery, custody) and writes `agent_key/3`,
`agent_host/4` and recovery rows through `::`.

One exception the spec itself imposes: the node selects the agents an ontology
hosts in the "local installed-resource selection" context where "live queries,
scope calls, staging and reaction commands are forbidden". So the two
derivation clauses `agent_hosted/4` and `agent_hosting_projection/4` stay as
clauses in each hosting ontology, written at signup beside the hosting facts.
Everything else in `agent_instance.pl` moves to `quod:agent`.

### 2.5 `doc/proofs.md` sentences that change

Current text, then replacement; each needs Yan's decided-by annotation.

- "Checks must be pure committed Prolog: they cannot write, consult live
  services or open foreign scopes." → "Checks must be pure committed Prolog:
  they cannot write or consult live services. The class tree and class ACL
  declarations follow a qualified class into its owner, as `isa/2` does; those
  reads enter the plan's dependencies. `can_invoke/4`, custody and committee
  verdicts cannot follow."
- "Derived memberships and the entire ancestry consulted by the guard follow
  the same rule: a foreign-qualified parent is refused, not partially
  evaluated." → "…a foreign-qualified class is followed to its owner."
- "Compose class policy into its target ontology, as for other local
  authorization." → "The class owner declares the class's ACL defaults and
  compulsory requirements; the storing ontology declares per-instance ACL
  facts."
- "Class definitions and constructors are composed locally, like shared
  permission policy; a foreign-qualified parent is refused rather than silently
  skipped." → "Class declarations follow a qualified class to its owner.
  Constructors do not build instances or parts; a `constructor/3` clause at a
  foreign owner refuses."
- "The assertion hook alone supplies this scoped context; callers cannot
  supply that subject to the public guard or forge it with build inputs." →
  "An instance whose membership was asserted in the current transaction is
  checked by its class policy, without staged instance overrides, until it
  commits."
- "Classes author their own bodies and required parts." and "class code still
  constructs its required parts and explicitly passes overrides" → deleted;
  parts are asserted like any instance.
- Runtime: add to `doc/runtime-and-agents.md` "A reaction is an agent's
  behaviour: an ontology without a hosted agent can hold `react_on/2` clauses
  but nothing executes them."

### 2.6 Other sentences that change

`doc/spaces.md`: "`quod_space.pl` defines the shared space foundation and is
composed into the ontologies owning individual spaces … the shared
foundation's exact pin and source hash certify the composition" → "`quod:space`
defines the space class. A storing ontology holds
`instance_of(quod:space:space, Id)`, its slots and its ACL facts."; "Compose
`quod_space.pl` into that storage owner and A's ontology…" and "Compose
`quod_space.pl` and `gui_instance.pl` in the storage owner to offer **Create
space**…" → delete; "Creation and form definition check the unique anchored
`space_vocabulary/2` plus `space_source_digest/1` against the shared source's
`space_template_hash/1`…" → delete; "places it one metre along that frame's X
axis from A." → Phase 0; "Creation and placement use the existing assertion
savepoint and `space_place/3` transaction. Refused explicit placement rolls
back the instance and all admission writes" → "Creation asserts the space and runs `goal(inside(…))` in the same
transaction; a refused placement fails the transaction as today."; the
`space_place/3`, `space_withdraw/3`, `space_travel/5` and `initial_occupants`
paragraphs → the `inside/3` and `unplaced/1` actions; "Participant entries
cannot create or release a slot" stays true of `place/3` and `withdraw/1`.

`doc/runtime-and-agents.md`: the `setup_account/4` paragraph → the setup form
of §4.3. `doc/godot-foundation-contract.md` step 5 ("the frozen private
account source composition, `user_source_directory`…") → terms only; the
"places A in S0 through `space_place/3` during that active construction"
sentence → `goal(inside(S0, personal, origin))` after the assertion, same
transaction.
`doc/lifecycle-and-routing.md`: keep `source_file(Path, Sha256)` for the node
template; drop "This lets an authored recipe pin packaged components".

## 3. Phase 0 — independent small repairs

### 3.1 `spaces.md` placement sentence

Code and test already agree (`quod_space.pl:112-125`; lifecycle test expects
`{transform,0,0,-52000,0,0,0}` for the default 100 m box). Replace "places it
one metre along that frame's X axis from A." with "places it in front of A
along that frame's −Z axis: 2 m from A's position plus half the new space's
depth, so its near wall opens at arm's reach plus a step (Yan, 2026-11-07); an
infinite space uses half-depth zero."

### 3.2 Icon byte allowance from the authored asset

Models declare it: `gui_scene.pl:136` has `mesh_asset(asset(Digest, Mime),
Profile, scale, frame, resources(Transfer, Geometry, Vertices, Triangles,
Nodes, Materials, Pixels))`, authored per asset (`quod_controllers.pl:41`),
admitted by the client (`StaticGlb.Admit`, `Transport.Model(digest,
allowance)`). Icons declare nothing. Change the `image` property value from
`asset(Digest, Mime)` to `image(asset(Digest, Mime), resources(Transfer,
Pixels))` in `quod:gui`; `image_asset/1` and `optional_image_asset/1` accept
it; the 36 `gui_icon/2` facts carry byte length and pixel count measured from
the files. `Forms.cs`, `Menus.cs` and `Main.FetchIcon` pass the declared
allowance to `Transport.Icon`; the constant goes.

### 3.3 One icon lookup

In `common_predicates.pl` beside `menu_vocabulary/2`:

```prolog
no_follow(menu_icon/2).
menu_icon(Name, Icon) :- menu_vocabulary(Gui, Anchor), in_ontology(Gui, Anchor, gui_icon(Name, Icon)).
```

Delete `space_icon/2` and the user-ontology `gui_icon/2`; eleven callers use
`menu_icon/2`. Not named `gui_icon/2` because inside `quod:gui` that is the
fact table.

## 4. Phase 1

### 4.1 What each ontology holds afterwards

| Ontology | Holds |
| --- | --- |
| `quod:space` | `isa(space, thing)`, `isa(physical_space, space)`, `space_instance/2`, `space_contains/2`, the contents projection and `world_view/3` (moved out of `common_predicates.pl`), slots, `class_permission(space, create\|space_enter\|space_admit\|space_leave\|space_remove\|space_visit\|space_represent, allow)`, `class_requirement(space, create, space_exterior_fits)`, `inside/3`, `unplaced/1`, `shown_in/2` and their actions, `placement_pose/3`, `space_half_depth/2`, every recipe (solid, wireframe, matrix, contents, menu, hud), Create / Enter / Leave / Show as forms, `can_invoke` for its public reads and goals |
| `quod:gui` | vocabulary as today; question lifecycle; HUD rules and recipes; `ontology_interface/2`; Phase 2 bytes |
| `quod:agent` | `isa(agent, thing)`, `class_permission(agent, space_enter\|space_leave, allow)`, hosting, custody and recovery actions |
| `quod:user` | `isa(human_user, agent)`, `isa(personal_agent, quod:agent:agent)`, setup, navigation, personal menu, attention, controller recipes and forms, personal-instruction rules (`personal_instruction_accept/2`, `retain_personal_instruction/3`, lookups), `signup_options/4`, the terms it writes into a new user's ontology |
| user's ontology | facts: `user_namespace/1`, `instance_of(quod:user:human_user, me)`, `instance_of(quod:user:personal_agent, personal)`, `agent_key/3`, `agent_host/4`, `hosting_node/1`, `signup_origin/3`, the seven vocabulary pins, `account_setup/2`, `instance_of(quod:gui:hud, my_hud)`, `hud_allowance(my_hud, 12)`, `gui_pending_allowance(me, 8)`, `entity_scene(personal, playing\|edition, hidden)`; ACL clauses: `can_invoke/4` for U (all), for `personal` (the exact goals it may run here), for writes arriving through `::` from `quod:space`, `quod:gui`, `quod:agent`, `quod:user` under U's or A's identity, and for the node's signing reads; `instance_permission/3` facts on its spaces; reaction: the clause of §2.3; the two hosting derivation clauses of §2.4 |

### 4.2 Where every pasted rule goes

**owner** = lives in the class owner and is called by `::`; **fact** / **ACL**
/ **reaction** = written into the user's ontology at signup; **deleted**.

`quod_space.pl` (572 lines): `can_invoke`, `space_query` → owner only, the
`space_template_hash` query deleted. `isa/2`, slots, `have_part` → owner.
`space_recipe/0`, constructor body, `space_initial_occupants/2`,
`space_initial_local/3`, `space_place_initial/2`, `space_travel/5`,
`space_icon/2` → deleted. `space_place/3`, `space_accept_placement/3`,
`space_withdraw/3`, `space_release_placement/4`, `space_expected_assignment/3`,
`space_contain/2`, `space_remove/2`, `space_consent/4`,
`space_withdrawal_consent/4`, `space_removal_allowed/3` → owner, rewritten as
the `place/3`, `withdraw/1`, `show/2`, `hide/2` actions behind `inside/3`,
`unplaced/1`, `shown_in/2`. `space_assignment/3`, `space_location/2`,
`space_subject/2`, `space_authorized/4`, `space_change_physics/3`,
`space_physical_change/3` default, `space_represent/7` and helpers,
`space_representation_changed/2`, `space_near_location/3`,
`space_half_depth/2`, `space_millimetres/4`, `space_whole_mm/2`, all
validators, recipes, forms and menus → owner.

`user_instance.pl` (699 lines): `can_invoke(_, agent_instance_ref(Ns, _, I), _, Ns) :- instance_of(quod:user:human_user, I)`,
`can_invoke` for A's goals, callbacks and the instruction authority, the node
signing clauses, `can_prepare_agent_key/5`, `can_assign_agent_host/6`,
`hud_entry/2`, `hud_offer_entry/2` as `can_invoke` over the owner's relations
→ **ACL**. `human_user_owner/1`, `account_owner_policy/1`,
`ontology_source_mode/1` → **ACL** helpers (two lines). The seven
`class_permission` checks (`account_space_create/3`, `account_space_admit/3`,
`account_new_space_entry/3`, `account_agent_entry/3`, `account_agent_leave/3`,
`account_space_visit/3`, `account_space_represent/3`, `account_initial_entry/3`,
`account_personal_actor/2`, `space_travel_agent/1`, `controller_actor/3`,
`hud_answer_actor/3`) → replaced by `instance_permission/3` facts set at
creation and the owners' class defaults; what remains is "which goals may my
agent run here", an `can_invoke` matter → **ACL**. `gui_pending_allowance/2`,
`hud_allowance/2`, `instance_of(quod:gui:hud, my_hud)`,
`instance_of(quod:user:personal_agent, personal)`, `entity_scene(personal, …, hidden)`
→ **fact**. `account_setup_state/1`, `account_navigation/1,2`,
`account_setup_preparation/1`, `setup_account/4` (as the `setup` form),
`personal_menu` and helpers, `personal_agent_owner/1`, `personal_agent/2`,
`personal_agent_preparation/1`, `personal_instruction_accept/2`,
`can_instruct_personal_agent/2`, `personal_instruction_authorized/5`,
`can_sign_agent_request/3`, `can_request_agent_signature/3`,
`retain_personal_instruction/3`, `personal_instruction_retained/2`,
`personal_instruction_lookup/3`, `personal_instructions/1`, controller
preferences reads, forms and `controller_preferences_set/5` → owner
`quod:user`. `gui_unlink/2`, `gui_hud_entry/4`, `gui_pending_questions/1`,
`gui_select_receiver/3`, `gui_forget_receivers/1`, `gui_receiver_for/2`,
`gui_receiver_accept/3`, `gui_link_question/1`, `hud_commands/1`,
`hud_command/1`, the attention recipe, `hud_direct_contributor/1`,
`hud_contribute/2`, `hud_withdraw/2`, `hud_offer/2`, `hud_withdraw_offer/2`,
`hud_answer_offer/3`, the `answer_hud_offer` recipe and `hud_offers(H)` form,
`hud_offer_label/3` → owner `quod:gui`. `account_source_pins/1`,
`account_space_recipe/1` → deleted.

`agent_instance.pl` (284 lines): `agent_hosted/4`,
`agent_hosting_projection/4` → clauses in the hosting ontology (§2.4
exception); everything else → owner `quod:agent`. The node ontology's
`node_identity_template` and the lobby lose their copies the same way.

`gui_instance.pl` (379 lines): the question lifecycle, entry relations,
`gui_responder_for/4`, `gui_native_handler/5`, `gui_accept_question/1`,
`gui_accepting/1`, `gui_open/2`, `gui_open_definition/5`,
`gui_validate_submission/6`, `gui_form_projection/4`, `gui_continue/1`,
`ontology_interface/2` → owner `quod:gui`; the completion `react_on/2` →
**reaction**; `gui_completion_allowance/2`, `gui_pending_allowance/2` →
**fact** where authored; `gui_question_policy/3` stays an application fact
where an application composes it.

### 4.3 What signup writes

`signup_options/4` in `quod:user` returns
`[terms(Facts ++ Pins ++ Acl ++ Reactions), external_predicate_modules([quod_agent_predicates])]`,
nothing else. The ACL clauses and reactions are authored once in `quod:user` as
`account_policy_clause(Clause)` facts; about forty clauses. They are the user's
own ACL, editable by the user with owner authority.
`ontology_creation_allowed/3` validates that exact term list.
`user_source_directory/1`, `user_source_component/2`, `space_source_digest/1`
and the `space_template_hash/1` read are deleted.

Setup is the `human_user` class's `setup` form at `quod:user`; its goal runs in
the user's ontology:
`quod:agent::goal(agent_hosted(personal, Node, 1, Key))`, then the S0 assertion
with `attribute(owner, Owner)`, then
`quod:space::goal(inside(entity_ref(Ns, A, S0), entity_ref(Ns, A, personal), transform(0,0,0,0,0,0)))`,
then the `account_setup/2` fact flip and
`in_ontology(Signup, SignupAnchor, acknowledge_signup(Token, Owner))`. One
transaction, as today. The preparation read and `prepared_agent_key_custody/6` are
unchanged. The stored `complete(Result)` term is kept: it is the immutable
setup record the client recovers.

### 4.4 Engine and shared-file changes (one cold release)

- `quod_ask:committed_authorization_result/2`: the operation guard runs in an
  ordinary read-only committed frame with following on and reads recorded
  (§2.1 step 1); an instance asserted in the current transaction is checked by
  its class policy (§2.1 step 5). `can_invoke/4`, custody and verdict keep the
  committee-verdict frame.
- `construction.pl`: `'$quod_constructor_graph'` follows a qualified class to
  its owner for parents, `constructor_order/2` and slot declarations; a
  `constructor/3` clause at a foreign owner refuses; `have_part/2`,
  `build_plan_part/3` and part inputs are removed.
- `common_predicates.pl`: `no_follow(class_requirement/3)` and
  `no_follow(class_permission/3)` removed; `menu_icon/2`;
  `isa(ontology, quod:space:space)` replaces `isa(ontology, space)`;
  `isa(space, thing)`, `space_instance/2`, `space_contains/2`,
  `space_projection/3,4`, `space_contents_projection/2`,
  `space_exposure_projection/4`, `space_scene_parts/8` and the rest of the
  contents projection (lines 649-812), `world_view/3`,
  `entity_scene(Space, …)`, `space_simulation_domain/4` and
  `space_interior_boundary/2` defaults, `eidolon(space_contents, …)` leave for
  `quod:space` (Yan, 2026-11-08). `client_world_view/4`,
  `client_space_selection/3` and `scene_vocabulary/2` stay and call
  `quod:space` through `::` for the projection. Only `isa(ontology,
  quod:space:space)` stays, because the `ontology` class is declared there.
- `gui_forms.pl`: compile an operation form at the recipe owner.
- `quod_client_view.erl`: `navigation`, `controller_preferences`,
  `hud_commands` goal shapes point at the owner recipes.
- Godot client: `class_ref(quod:space, SA, space)` creation subject from the
  pies; qualified class names in the operations panel; Phase 0 allowance.

Production delta: −1,934 pasted lines per user ontology; the four files'
contents move to their owners once; `space_travel/5`, the constructor body, the
digest machinery and the `account_*` check rules are deleted. Exact numbers at
implementation.

## 5. Phase 2 — icon bytes in `quod:gui`

`quod:gui` holds `gui_asset(Digest, Mime, Bytes)` for each icon (36 facts,
100,690 bytes), `gui_query(gui_asset(_, _, _))` admits the read, `gui_icon/2`
names `image(asset(Digest, Mime), resources(Transfer, Pixels))`. The client
asks `quod:gui::gui_asset(Digest, Mime, Bytes)` once per digest through the
existing signed read, verifies the SHA-256, caches by digest. A renamed or
redrawn icon is one `quod:gui` commit; every view that read `gui_icon/2`
refreshes through the existing installed-change path. `/assets/icons/` leaves
the node image. Authoring: a signed execute `assertz(gui_asset(D, M, <<…>>))`
per icon under the node's root authority, not the text editor; the live release
tooling (`quod_source_release.erl`) gains a `terms` step. Material admission is
the existing `material_policy.pl` selection.

## 6. Tests (existing signed seams only)

- `test/quod_lifecycle_single_path_tests.erl`: `quod:user` founded without
  `Frozen` or `user_source_directory`; `m1a_signup` asserts terms only;
  `m1a_setup` through the `setup` form; `m2_spaces` keeps the `-52000` pose,
  foreign storage, destination denial, rollback and recovery; the
  `space_source_digest` case is deleted; `m3a_travel` through `goal(inside(…))`; restart and
  receipts unchanged.
- `test/quod_space_creation_tests.erl`: the `creation-space-template` ontology
  and `Recipe` terms go; storage and destination hold facts and ACL; new cases:
  a body at the owner refuses, class default plus storing-ontology ACL, a
  just-asserted instance placed by its class policy in the same transaction,
  `goal(inside)` idempotent when already inside, `goal(unplaced)` prerequisite
  chaining, a plain local class name follows nothing.
- `test/quod_space_tests.erl`: the transitions as actions; same assertions.
- `quod_gui_operations_tests`, `quod_gui_menu_tests`, `quod_gui_hud_tests`,
  `quod_gui_question_tests`: forms compiled at the owner, pies for
  `class_ref(quod:space, SA, space)`, HUD and question rules at `quod:gui`
  writing through `::` into the agent's ontology under its ACL.
- Constructor fixtures (`test/fixtures/constructors.pl`,
  `class-permissions.pl`): class read at owner.
- Permission frames: `can_invoke/4`, custody and verdict re-proofs still fail
  on any following; only the operation guard follows, and only for a qualified
  class.
- Client: `client/godot-tests` allowance parsing and asset shape;
  `client/godot/tests/ExportLifecycle.cs` headless journeys against a Phase 1
  node; `test/gui-stage1-browser.mjs`.

## 7. Deployment

- Phases 0 and 2: live transaction path, one evidence directory per release
  under `doc/evidence/live-ontology-release-<version>-<date>/`, the 0.7.282
  tooling plus a `terms` step, `live-verify.erl` read-backs, client export to
  `~/Games/quod` behind the launcher. Patch bump only.
- Phase 1: the engine and shared-file changes need the cold coordinated
  release of `system-ontology-acls.md` "Retained-history activation": stop,
  upgrade the image, start, then live-edit `quod:space`, `quod:gui`,
  `quod:agent`, `quod:user` in one atomic multi-ontology transaction including
  the deletions, read back every changed definition, run the §6 probes. No
  refound; root's catalogue is unchanged. Existing users' ontologies are left as
  they are; those users sign up again.
- Commit only when told; one patch digit per commit.

## 8. Decided 2026-11-08

- Creation is `assert(instance_of(quod:space:space, B))` in the storing
  ontology; the class is read at `quod:space`; slots stored with the instance.
- Placement, travel and display membership are `quod:space::goal(inside(…))`,
  `goal(unplaced(…))`, `goal(shown_in(…))`; prerequisites fill in what the
  caller omits; the actions write through `::` under the storing ontologies'
  ACLs.
- Instances are asserted and placed in the same transaction; a just-asserted
  instance is checked by its class policy, as inside a constructor today.
  Constructors build nothing; parts are asserted like any instance.
- The guard reaches the owner's class ACL through ordinary following, the way
  `isa/2` already does; two `no_follow` lines and the guard's frame change.
- The space display rules still baked in `common_predicates.pl`
  (`space_instance/2`, `space_contains/2`, the contents projection,
  `world_view/3`) move to `quod:space` as well; only `isa(ontology,
  quod:space:space)` stays baked, because `ontology` is declared there.
- The two hosting derivation clauses stay in each hosting ontology (resource
  selection forbids scope calls).
- Class rules live at their owners and write through `::`; nothing is pasted
  and nothing new is baked. The two hosting derivation clauses stay in the
  hosting ontology because the spec forbids scope calls in resource selection.
- The user's ontology holds facts, ACL clauses, per-instance ACL facts and its
  agent's one reaction, all written at signup by `quod:user`.
- Icon bytes by signed read. Forms live at the class owner; their goals run
  where submitted. Existing users sign up again. No follow-ups.

Numbers above that were not chosen here: 2 m and the half-depth (Yan,
2026-11-07), 8 pending questions and 12 HUD wedges (already authored), 36 icons
and 100,690 bytes (measured), 1,934 pasted lines (counted). No new limit.

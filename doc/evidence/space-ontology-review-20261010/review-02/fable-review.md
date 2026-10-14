Evidence gathered; writing the report now. All work was read-only on the frozen tree; no commands, builds or notifier were run.

# Spaces, objects and ontology ownership: Fable consultation

## Recommendation

**Keep "ontology" as the unit of authenticated state and history, and add it as a reflective class, not a runtime object.** The confusion Yan names is real but it is a vocabulary problem, not a runtime one. Two different things are called "space": a *class space* (a namespace of classes and rules, which is exactly what an ontology already is) and a *spatial space* (a domain subject that contains instances). Rename nothing in the runtime; make the taxonomy say it.

**For the physical-lobby gap, prefer a normally founded, explicitly linked physical-space ontology over mutable bridge membership.** The governed-physics-plan's "effective capability transition" should be withdrawn as the recommended default. It changes a consensus-safety invariant to solve a case the existing foreign-world reference already covers, and the cross-ontology composition it tries to avoid is required anyway for the missing case in section 3. For *new* lobbies, no new machinery at all: found them with `quod_physics_predicates` in the template.

**The concrete missing capability is small and Prolog-side:** bodies and marks in a physical space must be allowed to depict subjects owned by *another* anchored ontology, and the ordinary view must carry decorative and body-bound marks together. Everything else (adoption with exact provenance, atomic cross-ontology transitions, fences, recovery) exists.

## Conceptual model and where it is grounded

**Six relations, six owners.** Class inheritance supplies none of the other five.

| Relation | Meaning | Owner | Status |
| --- | --- | --- | --- |
| Classification | `isa/2`, `instance_of/2` | Declaring ontology; foreign classes reached as `Ns:Class` through `Ns::isa` | Exists (`common_predicates.pl:64-67`, `:118-122`) |
| Code lookup | Which rules interpret a class | Declaring ontology, entered by `Ns::Goal`; never executed locally | Exists (`proofs.md:19-25`) |
| Durable state | Facts about an instance | One ontology `{Ns, Anchor}` with its own committee and history | Exists (`quod_agent_ref.erl:3-13`) |
| Spatial containment | Which instances a space holds | The space's ontology | **Proposed vocabulary** |
| Physics authority | Who simulates a physical space | `physics_space(W, enabled, I)` in the space's ontology, one agent | Exists (`quod_physics.pl:63-68`, `:273-276`) |
| Visual representation | Eidolons per class | Class-selected recipes with anchored refs | Exists (`quod_lobby.pl:72-86`) |

**Is "ontology is an ordinary class" useful?** Yes, as reflection; no, as a runtime change. The code already treats `ontology` as a class token: `ontology_eidolons/1` asks `class_eidolon(ontology, ...)` (`common_predicates.pl:21-24`), and "code is an eidolon of every class" is literally the comment at `:6-12`. Root already holds the instance catalogue as `system_ontology/2`, node ontologies hold `hosts_ontology/4`, and `ontology_ref(Ns, Anchor)` is the instance term. What is missing is only the declaration that ties these together:

```prolog
isa(ontology, thing).
%% derived, read-only: never an asserted copy of root/node truth
instance_of(ontology, ontology_ref(Ns, Anchor)) :- quod:root::system_ontology(Ns, Anchor).
ontology_contact(ontology_ref(Ns, Anchor), Hosts) :- ... hosts_ontology/4 via the node ontology ...
ontology_interface(ontology_ref(Ns, Anchor), Shapes) :- Ns::(public_source_query(Q)), ...
```

These fields (namespace, anchor, hosts, source chunks via `system_prolog_introspection/2`, public query shapes, eidolons) exist scattered; a reflective class gathers them as derived predicates so lenses and policy can talk about ontologies as subjects. Asserting them as facts anywhere else would create the "second mutable truth" AGENTS.md forbids.

**What cannot become a class field.** An ontology is the boundary at which a proof is sealed, a plan is validated by its own committee, and a KB is never copied (`proofs.md:27-32`). A class fact is only trustworthy *because* some ontology's committee committed it, so "ontology as just another object" cannot dissolve the boundary that makes objects trustworthy. The minimum privileged bootstrap remains: `quod:root` pinned in node config, the `system_ontology/2` catalogue, the node actor's bootstrap pointer, and the genesis module manifest (`lifecycle-and-routing.md:3-10`, `:23-26`; `quod_committed_projection.erl:144-158`).

**Inheritance is inert by construction.** `'$quod_isa_path'` asks the foreign scope and qualifies answers back (`common_predicates.pl:118-122`); it installs nothing. `instance_of/2` is a plain per-ontology fact with no shared definition and no ancestry expansion (`lobby_instance.pl:47`, `quod_physics.pl:109`). Bridges arrive only through the immutable slot-1 manifest (`quod_commit_validation.erl:316-319`, `:739-740`). Rights arrive only through `can_invoke/4` and the per-domain `can_*` policy, every one of which defaults to `fail` in `quod_physics.pl:10-14`, `:72-75`, `:330-332`. Nothing in this proposal changes that.

**The missing case: an object owned by A placed in a physical space owned by B.** Trace it through the owners that exist:

| Question | Owner | Why |
| --- | --- | --- |
| Containment `located_in(subject(ANs,AAnchor,E), Space)` | B | Projection and the body set are B's read-only selections (`quod_runtime.erl:2534-2539`) |
| Adopted collider and body revision | B | Same pattern as `class_ref` door adoption: materialized locally with exact provenance, never re-resolved by the selector (`quod_physics.pl:325-353`) |
| Transient pose | B's simulator, registered on `world_ref(BNs,BAnchor,W)` (`quod_physics.erl:20`, `:647`) | One simulator per space, frames never cross ontologies |
| Control grants (`can_push_physics_body/3`, control bindings) | B's policy, which may consult `A::` as a certified read | Grants are world policy today |
| Recovery checkpoint | B (`physics_checkpoint(W, ...)` keyed by W and run fence) | Must restore with B's run |
| Durable identity, ownership, non-physical attributes | A | A's history is the subject's history |

Illustrative B-side vocabulary (proposed, not implemented):

```prolog
instance_of(physical_space, hall).
physics_space(hall, enabled, hall_physics).
located_in(subject(ANs, AAnchor, chair_17), hall).
physics_body(hall, 41, 7, dynamic, pose(...), box(220,450,220), 600).
physics_body_source(hall, 41, class_ref(ANs, AAnchor, oak_chair_shape, 3)).
mark(<<"chair-17">>, _, _, body_pose(41, 7), _, _, depicts(ANs, AAnchor, chair_17)).

action(place_in_space(Subject, Space, Source, Pose, Structure),
       [current_principal(P), can_place(Space, P, Subject),
        Subject = subject(Ns, Anchor, Entity),
        Ns::(current_ontology_identity(Ns, Anchor), can_be_placed(Entity, P)),
        physics_structure(Space, Structure)],
       located_in(Subject, Space)).
```

Authorization: B's policy decides placement; A's consent is a certified read dependency in the same proof, so a later A-side revocation conflicts through ordinary OCC rather than through messaging. No shadow KB: B stores an adopted descriptor with an exact `class_ref`, not A's facts. No per-tick writes: pose stays in B's simulator and only explicit checkpoints commit, in B. No request-time rebuild: view selection reads B's committed facts. No second simulator: every body in `hall` is B's.

**Smallest first slice versus the general model.** First slice: B-only containment, placement as a single-writer B transaction with a certified `A::` read, and the two restrictions below lifted. General model (later): A may also record whereabouts in the same atomic group when its policy needs it, and consequences that change the subject (chair breaks) commit as an A+B atomic group through the existing lane (`multiwrite-architecture.md:19-20`).

**Two concrete restrictions to lift.** `physics_view_bodies/5` requires every mark's `depicts(Ns, Anchor, _)` to equal the *world's* identity (`quod_physics.pl:236-237`), so a foreign subject cannot be projected at all today. And the client rejects any mark without a body or with a parent (`simulation.js:53-55`) and the shell switches whole views between lobby and physics (`World.tsx:119`, `:175`), so mixed scenes do not exist. These are the gaps, and both are small.

**Bridge membership, evaluated fairly.**

- *Same-world capability evolution (the plan).* Solves exactly one thing: Yan's existing lobby was founded with only `quod_agent_predicates` (`quod_lobby.pl:57`). Cost: it replaces the "every validator runs the same declared module set" invariant (`ontology-actor-architecture.md:353-357`) with a per-height effective set, needs registry rebuild inside canonical apply, and the archived ruling says a hot module facility must define installation and activation first (`:386-389`). That is deep runtime work to avoid a second ontology.
- *Normally founded, explicitly linked physical space.* Found one new ontology with the physics module; it owns the lobby's physical space; the lobby authors `physics_client_world(ontology_ref(Ns, Anchor))`, which the retained profile already documents as "a human ontology can author a foreign reference" (`physics-native.md:550-551`, `quod_physics.pl:16-20`). The lobby keeps its namespace, anchor and history untouched. This is not a refound. The plan's objection, that it "turns structure edits, authorization and withdrawal into cross-ontology composition," is correct, but that composition is the general model section 3 needs regardless. Making the lobby the first instance of it is the honest path.
- *Existing bridge path.* For new lobbies it suffices today: add the physics module and source to `lobby_options/2`. Zero server change.

Real tradeoffs of the linked option: two histories and two runtimes per physical lobby, both must be local for the single view (`quod_client_simulation.erl:45-58`), provisioning adds a founding, and every cross-placement is a cross-ontology proof. Hosting is Prolog policy so co-location is authorable.

## Walkthroughs, views and sequence

**Chair enters a room.** One B transaction (or A+B atomic if A records whereabouts): assert containment, materialize the adopted body at `Structure+1`, tag it, no checkpoint. The runtime's existing selection installs the body at a step boundary (`quod_runtime.erl:238-253`, `:2615-2616`). Frames carry B's fence and the new body revision.

**Chair leaves.** The inverse transaction retracts containment and body, advances structure, removes any `rest_v1` checkpoint. Late frames for body 41 at the old revision fail the fence at the client (`simulation.js:73-76`) and at any observation (`world.md:271-283`). Body ids are never recycled (`physics-native.md:255-258`).

**Changing physical form.** A changes `oak_chair_shape` version 3 to 4 in its own history. Nothing moves in B until an explicit re-adoption edit in B, exactly as later door-class edits do not change installed instances (`physics-native.md:371-373`). If A must force the change (chair destroyed), that is one A+B atomic group: A retracts or marks the subject, B retracts the body and advances structure.

**Crossing two physical spaces B1 to B2.** One atomic group with B1 and B2 as ordinary writers (`multiwrite-architecture.md:28-37`). B1 retracts and advances; B2 adopts and advances. The body id is per-world; continuity is the subject in A. A stale B1 pose cannot land in B2 because `world_ref` differs, and cannot land in B1 because structure advanced.

**Owner or authority failure.** B's physics agent follows the existing recovery chain (`agent_instance.pl:78-198`) and activates a fresh generation; the chair restores from B's compatible checkpoint or its adopted baseline. If A is unavailable, B's view and simulation continue; only placement or consent proofs return a reasoned failure. If B is unavailable, the client shows the space unavailable; A cannot and must not infer where the chair is.

**Revocation.** A withdraws `can_be_placed`. That cannot reach into B; it conflicts the *next* placement or grant proof through OCC. Physical removal is an explicit action in B whose policy accepts A's owner, or an A+B atomic group. Nothing is torn down by timeout.

**Uncertain writes.** Unchanged from today: at most one submitted occurrence awaiting resolution per stream, `outcome_unknown` with an anchored reference, never resubmit (`proofs.md:45-47`, `world.md:451-473`).

**Ordinary client views.**

| Situation | Behaviour |
| --- | --- |
| Mixed marks | One validated mark set; only marks with `body_pose/2` receive transforms; decorative marks keep authored transforms and parents. One projection writer, not `setMarks` from two effects |
| Observer, body, head | Three operations: observer camera only where view policy permits; commanded body travel through signed control; tracked head is view motion with clearance masking (`physics-native.md:224-239`) |
| Authored camera mount | `physics_viewpoint/6` in the body frame; desktop and XR share it |
| Nonphysical space | No allocation; observer travel if permitted |
| Physical, enabled, unavailable | Show status; pause body commands; no silent observer fallback |
| Occupied placement | `occupied` refusal; explicit `reposition` only if granted |
| Moving door | Current mechanics; stale previews cannot keep old geometry |
| Foreign subject in view | Mark depicts `(ANs, AAnchor, E)`; menu and eidolon lookup go to A via `::` |

**Bounded sequence.**

1. Vocabulary: `isa(space, thing)`, `isa(physical_space, space)`, `isa(ontology, thing)`, `located_in/2`, `physics_body_source/3`, derived `ontology_*` reflection. Prolog only.
2. Lift the same-identity restriction in `physics_view_bodies/5`; add a mixed-mark projection contract and one client mark writer.
3. Found new lobbies with the physics module in `lobby_options/2`.
4. Found and link one physical-space ontology for Yan's existing lobby after fresh signed identification of its current anchor; adopt console and roof colliders there with exact `class_ref` provenance.
5. Placement action and the first foreign chair, single-writer B with certified `A::` read.
6. Only if 4 and 5 prove inadequate, revisit root-governed capability transitions as its own architecture contract.

**Earlier plan claims.** Withdraw: the capability transition as the recommended default, and the claim that a separately founded authority "requires new world/reference semantics" (the reference exists; the composition is needed anyway). Retain: physical structure, checkpoints, fences, levels and occurrences in the world ontology; three different owners for "has physical semantics / is simulated / can run now"; the client behaviour table; no refound. Revise: "one simulated space per containing ontology" becomes "one authority per physical space, each space in exactly one ontology"; "a space is a subject, not the container" stays and now also names the ontology class explicitly.

**Unresolved decisions for Yan.**

1. Standardize on "physical space always in its own ontology", or "co-located by default, foreign allowed"? Uniformity versus two histories per user.
2. Does A ever record its object's whereabouts, or is B always the only containment owner? This decides whether placement is single-writer or atomic from the start.
3. Who may initiate physical removal: the space owner alone, the subject owner alone, or either?
4. Does the local single-view limit (`view_busy`, both ontologies local) stay for the first slice, or does the linked physical space require remote viewer forwarding first?
5. Is `isa(ontology, thing)` declared in root, in `quod:agent`, or in a new reflection vocabulary?

This is consultative. No architecture approval, runtime acceptance, deployment or live identity claim is made here.

# Define ontology-owned XR controller descriptions and input mappings

**Type**: task
**Issue Key**: QUO-59
**Status**: to-do
**Priority**: medium
**Tags**: vr, ontology, input, architecture
**Sync Status**: synced
**ID**: task_1793016031614_ib7hoa
**Updated**: 2026-10-27T12:40:51.696Z

---

Yan identified the need to represent left and right VR controllers in Quod's ontology model. This item is a bounded design task; filing it does not authorize implementing another domain or expanding stage-1 hardware acceptance.

Current evidence:
- client/src/world-scene.js:184 bindRadialControl discovers touchpad/thumbstick/squeeze components, then hardcodes handedness-specific behavior: left movement/snap/teleport, right action menu.
- A targeted search of packaged priv/ontologies sources found no XR controller/handedness vocabulary. Existing physical-agent control configuration, viewpoint policy and authorization already live in quod_physics.pl and must remain authoritative.
- doc/player-movement-plan.md distinguishes raw human tracking from physical agent configuration; doc/world.md keeps controller pose samples transient while governed attachment/consequence transitions use existing actions and transactions.

Proposed direction to evaluate:
- One reusable input-device/controller vocabulary, with distinct left and right controller instances or roles, capability/component descriptions, and explicit input-to-action mappings. Do not duplicate separate left/right implementations.
- Decide where those instances and persistent mappings live using existing human/personal-agent/ontology ownership and privacy. Two controllers do not by themselves require two separate ontology ledgers.
- Keep actual device discovery, current poses/button samples, tracking loss and connection lifetime with the browser/runtime owner. Do not ledger every frame or create a competing mutable copy of live tracking.
- Model durable preferences and domain meaning/authorization in Prolog. The adapter translates hardware observations using the selected mapping; controller possession or a rendered hand never grants an agent new capabilities.
- Distinguish a physical controller, a tracked bare hand, and an agent's virtual hand/tool. The held-object/embodiment use cases must reuse existing owners; they are not implied by selecting GUI controls.

Design acceptance:
1. Trace pointing/selecting, opening a menu and existing authorized movement through current GUI/action/control owners. Identify precisely which descriptions or mapping capabilities are missing before proposing machinery.
2. Specify identity versus handedness, capability detection, configurable bindings and gesture arbitration; handle missing components, unknown handedness, disconnect/reconnect, swapped roles and multiple devices without guessed inputs or stale authority.
3. Separate session observations, persistent configuration and authoritative agent/world effects. Specify authorization and privacy, reuse existing transactions/reactions/recovery where required, and avoid a new broker, executor or mirrored device-state inventory.
4. Present the smallest shared schema and replacement scope for agreement before implementation. This is not permission to begin space stages 2–3, grabbing/attachments, or new hand-tracking support.

Related: [QUO-24](nimbalyst://QUO-24) GUI, [QUO-25](nimbalyst://QUO-25) movement, [QUO-54](nimbalyst://QUO-54) Vive initiative. Coordinate later held-object semantics with [QUO-9](nimbalyst://QUO-9). The immediate production startup defects are [QUO-58](nimbalyst://QUO-58); controller modeling is not a prerequisite for correcting those failures or exercising existing controller GUI interaction.

Read [AGENTS.md](/home/yan/src/quod/AGENTS.md), [multiwrite architecture](/home/yan/src/quod/doc/multiwrite-architecture.md), [movement mappings](/home/yan/src/quod/doc/player-movement-plan.md:291), and the current [input adapter](/home/yan/src/quod/client/src/world-scene.js:184).
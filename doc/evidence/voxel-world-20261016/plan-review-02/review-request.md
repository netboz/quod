# Requested Claude Fable plan review

Yan explicitly requested this review. Use Claude Fable. Your advice is consultative; the parent will check it against the code and architecture. Review only: do not implement, edit files, run tests/builds, commit, deploy, found ontologies, invoke another reviewer, or initiate live requests. Read/Grep/Glob are the only tools enabled. Do not infer that this plan or any historical code is already approved for implementation.

Read `tree/quod/AGENTS.md` first and obey its architecture, policy ownership, transaction, retained-state, notification/deadline and verification invariants. Inputs are frozen under `tree/quod/` and `tree/bbsvx/`; use those paths rather than live absolute links in the documents. `source-manifest.json` identifies exact inputs. You may inspect all 49 frozen files, but no other project histories or credentials are needed.

Primary deliverables to review:

- `tree/quod/nimbalyst-local/plans/voxel-world-generation-ontology.md`
- `tree/quod/nimbalyst-local/plans/voxel-world-algorithm-research.md`
- The accompanying Excalidraw is illustrative; textual contracts govern.

## User requirements and accepted scope

The requested domain is a voxel-world ontology that follows Quod concepts and reuses GUI, collisions, actions, ordinary/multi-ontology transactions, recovery and reactions. Domain facts and policy stay in Prolog; pure Erlang/native arithmetic may accelerate generation. No independent world engine, queue/broker, duplicate authorization or speculative new execution path. Yan required asking before a necessary new path.

The user chose both smooth and cubic terrain, smooth first. Include caves, biome management, digging and varied user parameterization through existing GUI. Include both bounded worlds and unbounded worlds generated to view distance as the player moves. Aggregating different users' bounded worlds into a patchwork is a later feature. Yan asked us to inspect BBSvx; the research document records actual source findings, not benchmark results.

After a concrete explanation, Yan accepted the **design scope** of (1) generated triangle data through the existing Eidolon/mark renderer, (2) streamed collision coverage under the current physics owner that pauses motion at unavailable regions, and (3) movement-scoped interest updates on the current authorized view connection and coherent local-coordinate origins for travel far from the start. Pure numerical Erlang/NIF acceleration was already allowed. This does NOT authorize implementation/deployment and does NOT waive any existing guarantees or justify any unrelated architecture expansion.

The latest user context is in section 9.3: a user-owned flying lobby should later be instantiable in any generated voxel world and expose the world's governed controls. The user expressly said to stay focused on voxel worlds. Assess compatibility constraints without expanding this feature into flight, moving interiors, travel or patchworld implementation.

## Review questions

1. Trace the proposal through the actual existing code/specs before proposing alternatives. Are new capabilities limited to demonstrated gaps? Is any existing lifecycle duplicated, bypassed or needlessly replaced? In particular inspect `quod_physics.pl`, `quod_runtime.erl`, `quod_physics.erl`, `quod_client_view.erl`, the render/mark adapters, pure compiled primitives and their sealing contract.
2. Challenge the one logical terrain body with streamed constituent colliders. Does cache residency really remain distinct from authored structure without weakening body identity, negative observations, collision/contact completeness, run fences or signed consequences? What exact missing contract must be pinned before implementation? Distinguish a fixable planning omission from an implementation detail or a reason to reject this approach.
3. Check world edits: signed actions, authorization, expected revisions, predicate OCC including absent patches, halo closure, atomic receiver changes, checkpoints, cancellation and uncertain original operations. No splitting brushes to evade budgets, no repeated request resubmission, and no live native observation used to seal an ordinary durable diff.
4. Check the canonical field and numerical proposal: BBSvx-inspired fixed-point value noise, cubic/smooth interpretation, 3D caves and biomes, corrected MC33 vs greedy meshing, quantization, material ownership and versioned determinism. External publications are linked in the research but not bundled; distinguish your external algorithm knowledge from facts you actually verified in this code review. BBSvx comments/test names are not empirical proof.
5. Check unbounded residency and local-origin frames: all active bodies retain support even without a viewer; no missing region becomes air; demand is authorized/event-driven; state owners never block on network I/O; scoped notifications, stale completions, deadlines and consumer-lifetime retention hold. Does rebasing fit current pose/control/checkpoint/wire contracts, and are its invariants specific enough to guide implementation without hiding a second system?
6. Check budgets and repeated cost. Can unrelated changes avoid generation/triangulation/native replacement/history replay/disk writes? Are resource ownership, aggregate memory/output charges, genuine codec limits and the limitations of the current single-local-view physics profile stated honestly?
7. Assess implementation slices and acceptance coverage. Identify any concrete correctness blocker or premature promise, including cave connectivity, fill/regeneration safety, future lobby compatibility and future bounded-world aggregation. Do not ask for delivery of deferred features as a condition of this terrain plan.

## Required response

Return a Markdown review in your final answer, without writing files. Lead with `Verdict: ...` (approve for implementation planning, approve with required corrections, or changes required). List findings by severity with frozen file/line or section references, the concrete failure scenario and a minimal correction that respects the existing owners. Distinguish blockers, required clarifications and optional improvements. State whether the admitted extension scope is sufficient or a materially new capability would need another user decision. End with verification obligations and uncertainties. Do not claim to have run tests or validated current external dependencies.

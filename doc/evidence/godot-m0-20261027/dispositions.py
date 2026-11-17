#!/usr/bin/env python3
"""Explicit source dispositions; lexical callers are supporting evidence, not deletion authority."""
import json
from pathlib import Path

base=Path(__file__).resolve().parent
audit=json.loads((base/'ontology-audit.json').read_text())['sources']
# source: owner | final file | retained obligation (all paths below planned)
data='''agent_instance.pl|agent|agent_instance.pl|Hosting, custody, observation and monotonic recovery; agent_actions/agent_hosting/agent_recovery/failover suites
agent_recovery_policy.pl|agent|agent_instance.pl|Optional remote recovery thresholds and exact observations; recovery/observation_capacity/failover suites
animals.pl|test|test/fixtures/ontologies/animals.pl|Cross-ontology class/ask and genesis fixtures; ask_SUITE, ask, create_root, genesis
common_predicates.pl|runtime-common|common_predicates.pl|Actions, committed permission, source access and world-view wrappers; action_savepoint/class_semantics/operation_permissions/prolog_ontology/client_view
construction.pl|runtime-common|construction.pl|Defaults, inherited constructors and part/savepoint lifetime; constructor/assertion_construction/space_creation
controller_preferences.pl|user|user_instance.pl|Private preference facts/forms and U→A Save/Reset; controller/personal_agent tests
cross_benchmark_source.pl|test|test/fixtures/ontologies/cross_benchmark_source.pl|Configured benchmark source, not dead; deploy/quod.nomad and cross-ontology load scripts
cross_benchmark_target.pl|test|test/fixtures/ontologies/cross_benchmark_target.pl|Configured benchmark target/echo, not dead; deploy/quod.nomad and cross-ontology load scripts
fipa_request.pl|agent|agent_instance.pl|Atomic request/receiver/completion transitions and replay rules; agent_hosting tests
gui_hud.pl|user|user_instance.pl|Private receiver/HUD relationships and cleanup; gui_question/gui_examples/ask_SUITE
gui_instance.pl|gui|gui_instance.pl|Portable compilation, fields, exact revisions and binding; gui_components/gui_operations/gui_stage1/gui_question
gui_operation.pl|gui|gui_instance.pl|Offered operations, prebound-output refusal and original results; gui_operations/space_creation/controller
gui_question.pl|gui|gui_instance.pl|Genuine deferred questions and atomic continuation/cancel; gui_question/gui_examples/ask_SUITE
hinged_example_view.pl|test|test/fixtures/ontologies/hinged_example_view.pl|Diagnostic view, not required startup; physics hinge/contact/checkpoint fixtures
human_user_instance.pl|user|user_instance.pl|U authority, source privacy and lobby-to-S0 setup replacement; lifecycle_single_path/personal_agent/controller
instrument_configuration.pl|test|test/fixtures/ontologies/instrument_configuration.pl|Independent nonphysical form and continuation example; gui_examples
lobby_atmosphere.pl|test|test/fixtures/ontologies/lobby_atmosphere.pl|Atmosphere question example; preserve genuine question/default/typed-form obligations in gui_examples
lobby_instance.pl|user/space|user_instance.pl|Remove mandatory physical-lobby floor/pilot composition after ordinary S0 replaces it; retain physical grants/admission regressions in physics and space fixtures
lobby_worlds.pl|space|space_terrain.pl|Terrain create/library/arrival, budgets and occupied-world protections; gui_examples/voxel_world/physics. Not ordinary-space creation
material_policy.pl|runtime-common|material_policy.pl|Founding/plan/proof admission policy; material_admission/scope_session/sealing/OCC tests
node_execution.pl|node|node_instance.pl|Private node methods and hosting intention owner; node_actor/node_context/lifecycle/failover
personal_agent.pl|user|user_instance.pl|Distinct A key, attempt-now custody and original outcome association; personal_agent tests
pets.pl|test|test/fixtures/ontologies/pets.pl|Foreign class/follow/instance fixtures; ask/ask_SUITE/create_root
quod_agent.pl|agent|quod_agent.pl|Public agent class; agent_hosting/class_semantics/lobby vocabulary tests
quod_environment.pl|space|space_environment.pl|Optional sky/environment properties; rendering/lobby fixtures. No mandatory onboarding atmosphere
quod_environment_eidolons.pl|space|space_environment.pl|Optional panorama assets/Eidolons/digests; rendering/lobby fixtures
quod_gui.pl|gui|quod_gui.pl|Portable components/type validation and governed GUI native effects; gui_components/gui_operations/gui_question/gui_stage1
quod_hinged.pl|space|space_hinged.pl|Mechanical close/cancel/custody consequences; physics tests. Retain independently of entry
quod_human_user.pl|user|quod_user.pl|Human class vocabulary, merged with signup ACL explicitly; class_semantics/lobby tests
quod_lens.pl|gui|gui_tools.pl|Complete source and explicit predicate/policy/interfaces/routes lenses; lens/prolog_ontology/lobby tests. Broader editing remains separate
quod_licence.pl|root|root_licence.pl|Licence compatibility, notices, obligations; licence/lens tests. No new shared identity
quod_lobby.pl|controllers/space|quod_controllers.pl|Device/controller classes/bindings/appearance to controllers; optional building recipes to space_environment; remove lobby founding policy only after S0 replacement; controller/lobby/rendering
quod_material.pl|gui|gui_materials.pl|Material-property quantities use GUI exact measure pin; rendering/material tests
quod_material_eidolons.pl|gui|gui_materials.pl|Verified texture/surface recipes; rendering/lobby asset tests
quod_measure.pl|gui|gui_measure.pl|Complete exact unit/signature/rational conversion including material units; measure/space_creation/rendering
quod_modelling.pl|gui|gui_scene.pl|Pure model, shape bounds, placement/pivot/front/scoped occurrence paths; rendering/space/physics
quod_names.pl|user|user_names.pl|Optional naming pools and licence notice OGL-1.0a; names/names_SUITE/constructor/outcome_result. Ordinary space default remains stored literal
quod_node.pl|node|quod_node.pl|Protected open enrollment, allocations and executor-bound hosting; node_actor/lifecycle/join/failover
quod_physics.pl|space|space_physics.pl|Authority/run/custody/control/body admission and source delegates; physics/physics_control/coordinates suites, including new recursive domain mapping obligations
quod_prolog.pl|gui|gui_tools.pl|Guarded source compiler, complete baseline/conflict/atomic edit; prolog_ontology/lobby. Do not retire because broad editing is deferred
quod_prolog_eidolons.pl|gui|gui_tools.pl|Source/inspection recipes re-pin common selectors to GUI; lobby/lens/prolog_ontology
quod_rendering.pl|gui|gui_scene.pl|Complete mark/material/asset validation and resource policy; rendering/client marks/GLB tests. Extend portable wireframe vocabulary in M2
quod_root.pl|root|quod_root.pl|Creation/catalogue/source restrictions, resource policy; create_root/root_resource/lifecycle/system-source tests
quod_signup.pl|user|quod_user.pl|Private key-bound receipts and founding policy; lifecycle_single_path/lobby negative source access; rebind old lobby recipe to U/A/S0
space.pl|space|quod_space.pl|Ordinary/physical placement, exact extent/owner construction and atomic permissions; space/space_creation/constructor tests
space_gui.pl|space|quod_space.pl|Finite/infinite forms, exact storage/placement/results; gui_stage1/gui_operations/space_creation/browser fixture obligations
space_view.pl|space|quod_space.pl|Direct subjects/default cube/body_pose refusal; space/rendering/physics. Extend contents recursion and wireframe without alternate scene path
voxel_world.pl|space|space_terrain.pl|Terrain generation/overrides/lifecycle, explicit resource budgets and atomic edits; voxel_world/physics
voxel_world_gui.pl|space|space_terrain.pl|Existing voxel_generation form is reachable; gui_examples/voxel_world
voxel_world_view.pl|space|space_terrain.pl|Terrain source refs/render allowances and updates; voxel_world/physics/rendering
'''
mapping={row.split('|')[0]:row.split('|')[1:] for row in data.strip().splitlines()}
assert len(mapping)==50 and set(mapping)=={Path(r['path']).name for r in audit}
rows=[]
for source in audit:
    name=Path(source['path']).name; owner,target,obligation=mapping[name]
    keep=target==name
    destination=target if owner=='test' else 'priv/ontologies/'+target
    refs=source['explicit_file_callers']; lexical=source['predicate_name_callers']
    rows.append(dict(source=source['path'],sha256=source['sha256'],owner=owner,disposition='keep/refine' if keep else 'fold/archive' if owner!='test' else 'test-fixture/archive',final_destination=destination,
                     archive_destination=None if keep else 'outdated/ontologies/prolog/'+name,obligations=obligation,explicit_file_callers=refs,predicate_name_callers=lexical))
(base/'retirement-map.json').write_text(json.dumps(rows,indent=2)+'\n')
lines=['# Source disposition and caller obligations','',
       'All 50 baseline Prolog files are mapped. Destinations are a later replacement contract, not completed moves. `ontology-audit.json` retains every lexical reference and line; lexical absence is never dead-code proof. Runtime-owned common loading and frozen genesis composition are traced in the foundation contract. Before a move, recheck current source, generated deployment/source lists, ordinary authored uses and the named behavioral obligations.','',
       '| Current source | Owner / disposition | Final source | Archive destination | Caller and test obligations |','| --- | --- | --- | --- | --- |']
for r in rows:
    name=Path(r['source']).name
    callers=', '.join(sorted({x['path'] for x in r['explicit_file_callers']})) or 'No literal filename caller in indexed paths; inspect namespace/configured/authored use.'
    lines.append(f"| [{name}](../../../{r['source']}) | {r['owner']}; {r['disposition']} | `{r['final_destination']}` | `{r['archive_destination'] or 'retained in place'}` | {r['obligations']}. Literal callers: {callers} |")
lines+=['','## Erlang ontology-facing sources','',
        'No whole Erlang domain implementation is demonstrated obsolete by namespace consolidation. Retain the following existing owners and their callers. If a later replacement proves a source superseded, its exact archive destination is the listed path, outside compiler and packaged-resource roots. Do not move these during M0.','',
        '| Active source / owner | Tests/callers retained | Archive destination only if later superseded |','| --- | --- | --- |']
erlang={
'src/quod_ontology.erl':'root creation effects, namespace manager; genesis/create_root/lifecycle tests',
'src/quod_system_ontology.erl':'exact catalogue, namespace manager and client; system_ontology/lifecycle tests',
'src/quod_ontology_name.erl':'exact structured-name codec and parser; ontology_name tests',
'src/predicates/quod_ontology_predicates.erl':'governed source/founding bridge; lifecycle/prolog_ontology tests',
'src/predicates/quod_gui_predicates.erl':'governed prepare/activate bridge; gui_question/gui_presentation tests',
'src/quod_gui_presentation.erl':'installed presentation/receiver lifecycle; gui_presentation/gui_question tests',
'src/quod_terrain_wire.erl':'terrain transport profile; terrain_wire/voxel tests',
'src/predicates/quod_physics_predicates.erl':'existing physics service boundary; physics/control/custody tests',
'src/quod_physics.erl':'one native mutation owner per selected domain; physics suite',
'src/quod_physics_native.erl':'audited Rapier adapter; native and physics tests'}
for path,obligation in erlang.items():lines.append(f"| [{path}](../../../{path}) | {obligation} | `outdated/ontologies/erlang/{path.removeprefix('src/')}` |")
lines+=['','Compilation: keep archives outside `src`/configured source dirs. Application: regenerate/check active `.app` module lists and reject archived modules in founded predicate manifests. Packaging: no archives under `priv`; release/Docker package only active manifest. Bootstrap/runtime: update every component/source_file/template list; no archive fallback, glob or loader. Recheck literal and predicate callers, source-list builders, fixtures, external authored templates and release contents before each actual move.','',
        'Counts: planned 24 active packaged production Prolog files and seven test-source fixtures (31 live files); superseded originals retained separately. Archive line totals and test relocation do not count toward the ≤5,700 active production nonblank/noncomment-line target. Keep OGL and controller/asset notices. M0 relocations: zero.']
(base/'retirement-map.md').write_text('\n'.join(lines)+'\n')
print('Mapped',len(rows),'Prolog sources and',len(erlang),'retained Erlang owners')
